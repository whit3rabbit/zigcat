//! Client mode implementation for zigcat.
//!
//! This module handles all client-side functionality including:
//! - TCP/UDP connection establishment with timeout
//! - Proxy connections (HTTP CONNECT, SOCKS4/5)
//! - TLS/SSL handshake and encrypted communication
//! - Bidirectional data transfer with I/O control
//! - Zero-I/O mode for port scanning
//! - Command execution (exec mode)
//!
//! Client workflow:
//! 1. Parse target host:port from positional arguments
//! 2. Establish connection (direct or via proxy)
//! 3. Optional TLS handshake
//! 4. Handle zero-I/O mode (connect and close immediately)
//! 5. Execute command (-e flag) or bidirectional transfer
//!
//! Timeout enforcement:
//! - Uses wait_time (-w flag) if set, else connect_timeout
//! - All connections use poll()-based non-blocking I/O
//! - See TIMEOUT_SAFETY.md for timeout patterns

const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const net = @import("net/socket.zig");
const tcp = @import("net/tcp.zig");
const udp = @import("net/udp.zig");
const sctp = @import("net/sctp.zig");
const unixsock = @import("net/unixsock.zig");
const tls = @import("tls/tls.zig");
const transfer = @import("io/transfer.zig");
const tls_transfer = @import("io/tls_transfer.zig");
const output = @import("io/output.zig");
const hexdump = @import("io/hexdump.zig");
const proxy = @import("net/proxy/mod.zig");
const logging = @import("util/logging.zig");
const Connection = @import("net/connection.zig").Connection;
const TelnetConnection = @import("protocol/telnet_connection.zig").TelnetConnection;

/// Run client mode - connect to remote host and transfer data.
///
/// Client mode workflow:
/// 1. Parse host and port from positional arguments (or use Unix socket path)
/// 2. Connect to target (direct TCP/UDP, Unix socket, or via proxy)
/// 3. Optional TLS handshake for encryption (not supported with Unix sockets)
/// 4. Handle special modes (zero-I/O, exec)
/// 5. Bidirectional data transfer with logging
///
/// Connection methods (in order of precedence):
/// - Unix socket: Connect to local Unix domain socket
/// - Proxy: Use HTTP CONNECT, SOCKS4, or SOCKS5 proxy
/// - UDP: Create UDP client socket
/// - TCP: Non-blocking connect with poll() timeout
///
/// Timeout behavior:
/// - Uses cfg.wait_time if set via -w flag
/// - Falls back to cfg.connect_timeout (default 30s)
/// - All operations respect timeout for reliability
/// - Unix sockets use same timeout for connection establishment
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   cfg: Configuration with target, protocol, and connection options
///
/// Returns: Error if connection fails or I/O error occurs
pub fn runClient(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    // Check for Unix socket mode first
    if (cfg.unix_socket_path) |socket_path| {
        return runUnixSocketClient(allocator, cfg, socket_path);
    }

    // 1. Parse target host:port for TCP/UDP
    if (cfg.positional_args.len < 2) {
        logging.logError(error.MissingArguments, "client mode requires <host> <port> or Unix socket path (-U)");
        return error.MissingArguments;
    }

    const host = cfg.positional_args[0];
    const port = try std.fmt.parseInt(u16, cfg.positional_args[1], 10);

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Client mode configuration:\n", .{});
        logging.logVerbose(cfg, "  Target: {s}:{d}\n", .{ host, port });
        logging.logVerbose(cfg, "  Protocol: {s}\n", .{if (cfg.udp_mode) "UDP" else "TCP"});
        if (cfg.proxy) |proxy_addr| {
            logging.logVerbose(cfg, "  Proxy: {s} (type: {})\n", .{ proxy_addr, cfg.proxy_type });
        }
        if (cfg.ssl) {
            logging.logVerbose(cfg, "  TLS: enabled (verify: {})\n", .{cfg.ssl_verify});
        }
    }

    // 2. Connect to target (direct or via proxy)
    const raw_socket = blk: {
        if (cfg.proxy) |_| {
            // Connect through proxy
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Connecting via proxy...\n", .{});
            }
            break :blk try proxy.connectThroughProxy(allocator, cfg, host, port);
        } else {
            // Direct connection
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Connecting to {s}:{d}...\n", .{ host, port });
            }

            if (cfg.udp_mode) {
                break :blk try udp.openUdpClient(host, port);
            } else if (cfg.sctp_mode) {
                const timeout = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;
                break :blk try sctp.openSctpClient(host, port, timeout);
            } else {
                // Use wait_time if set via -w, otherwise fall back to connect_timeout default
                const timeout = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;

                // Handle --keep-source-port flag
                if (cfg.keep_source_port) {
                    const src_port = cfg.source_port orelse 0;
                    break :blk try tcp.openTcpClientWithSourcePort(host, port, timeout, src_port);
                } else {
                    break :blk try tcp.openTcpClient(host, port, timeout);
                }
            }
        }
    };

    // Ensure socket is cleaned up on error
    errdefer net.closeSocket(raw_socket);

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Connection established.\n", .{});
    }

    // 3. Optional TLS handshake (not supported for UDP)
    var tls_connection: ?tls.TlsConnection = null;
    defer if (tls_connection) |*conn| conn.deinit();

    if (cfg.ssl and !cfg.udp_mode) {
        // Security warning if certificate verification is disabled
        if (!cfg.ssl_verify) {
            logging.logWarn("⚠️  SSL certificate verification is DISABLED. Connection is NOT secure!", .{});
            logging.logWarn("⚠️  Use --ssl-verify to enable certificate validation.", .{});
        }

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Starting TLS handshake...\n", .{});
        }

        const tls_config = tls.TlsConfig{
            .verify_peer = cfg.ssl_verify,
            .server_name = cfg.ssl_servername orelse host,
            .trust_file = cfg.ssl_trustfile,
            .crl_file = cfg.ssl_crl,
            .alpn_protocols = cfg.ssl_alpn,
            .cipher_suites = cfg.ssl_ciphers,
        };

        tls_connection = try tls.connectTls(allocator, raw_socket, tls_config);

        if (cfg.verbose) {
            logging.logVerbose(cfg, "TLS handshake complete.\n", .{});
        }
    } else if (cfg.ssl and cfg.udp_mode) {
        logging.logWarn("TLS not supported with UDP, continuing without encryption", .{});
    }

    // 4. Handle zero-I/O mode (connection test)
    if (cfg.zero_io) {
        // Zero-I/O mode: just test connection and close
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Zero-I/O mode (-z): connection test successful, closing.\n", .{});
        }
        if (tls_connection) |*conn| {
            conn.close();
        }
        net.closeSocket(raw_socket);
        return;
    }

    // 5. Execute command if specified
    if (cfg.exec_command) |cmd| {
        defer {
            if (tls_connection) |*conn| {
                conn.close();
            }
            net.closeSocket(raw_socket);
        }
        try executeCommand(allocator, raw_socket, cmd, cfg);
        return;
    }

    // 6. Bidirectional data transfer
    defer {
        if (tls_connection) |*conn| {
            conn.close();
        }
        net.closeSocket(raw_socket);
    }

    // Initialize output logger and hex dumper
    var output_logger = try output.OutputLogger.init(allocator, cfg.output_file, cfg.append_output);
    defer output_logger.deinit();

    var hex_dumper = try hexdump.HexDumper.init(allocator, cfg.hex_dump_file);
    defer hex_dumper.deinit();

    // Handle Telnet protocol mode
    if (cfg.telnet) {
        // Create Connection wrapper for the underlying socket/TLS connection
        const connection = if (tls_connection) |*conn|
            Connection.fromTls(conn.*)
        else
            Connection.fromSocket(raw_socket);

        // Wrap with TelnetConnection for protocol processing
        var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null);
        defer telnet_conn.deinit();

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Telnet protocol mode enabled, performing initial negotiation...\n", .{});
        }

        // Perform initial Telnet negotiation
        try telnet_conn.performInitialNegotiation();

        // Use TelnetConnection for bidirectional transfer
        try transferWithTelnetConnection(allocator, &telnet_conn, cfg, &output_logger, &hex_dumper);
    } else {
        // Standard transfer without Telnet processing
        if (tls_connection) |*conn| {
            try tls_transfer.tlsBidirectionalTransfer(allocator, conn, cfg, &output_logger, &hex_dumper);
        } else {
            const stream = std.net.Stream{ .handle = raw_socket };
            try transfer.bidirectionalTransfer(allocator, stream, cfg, &output_logger, &hex_dumper);
        }
    }
}

/// Print data as hex dump to stdout with ASCII sidebar.
///
/// Format (16 bytes per line):
/// 00000000: 48 65 6c 6c 6f 20 57 6f 72 6c 64 0a             |Hello World.|
///
/// Used as fallback when HexDumper is not available.
///
/// Parameters:
///   data: Binary data to display in hex format
fn printHexDump(cfg: *const config.Config, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        logging.logTrace(cfg, "{x:0>8}: ", .{i});

        // Hex bytes
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                logging.logTrace(cfg, "{x:0>2} ", .{data[i + j]});
            } else {
                logging.logTrace(cfg, "   ", .{});
            }
        }

        logging.logTrace(cfg, " |", .{});

        // ASCII representation
        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (c >= 32 and c <= 126) {
                logging.logTrace(cfg, "{c}", .{c});
            } else {
                logging.logTrace(cfg, ".", .{});
            }
        }

        logging.logTrace(cfg, "|\n", .{});
    }
}

/// Execute command with socket connected to stdin/stdout (not yet implemented).
///
/// Planned functionality:
/// - Fork/exec child process with given command
/// - Redirect child stdin/stdout to socket
/// - Bidirectional I/O between socket and child process
/// - Proper signal handling and cleanup
///
/// Security note:
/// - Client-side exec is less dangerous than server-side
/// - Still requires proper command validation
/// - Should sanitize environment variables
///
/// Parameters:
///   allocator: For command parsing and buffer allocation
///   socket: Connected socket to use for child I/O
///   cmd: Command to execute
///   cfg: Configuration for verbose logging and options
fn executeCommand(allocator: std.mem.Allocator, socket: posix.socket_t, cmd: []const u8, cfg: *const config.Config) !void {
    _ = allocator;
    _ = socket;
    _ = cmd;
    _ = cfg;
    logging.logWarning("Command execution not yet implemented\n", .{});
    return error.NotImplemented;
}

/// Run Unix socket client mode - connect to Unix domain socket.
///
/// Unix socket client workflow:
/// 1. Validate Unix socket support on current platform
/// 2. Create Unix socket client and connect to server
/// 3. Handle special modes (zero-I/O, exec)
/// 4. Bidirectional data transfer with logging
///
/// Unix socket specific behavior:
/// - No TLS support (local communication doesn't need encryption)
/// - No proxy support (Unix sockets are local only)
/// - Uses filesystem permissions for access control
/// - Faster than TCP for local communication
/// - No network timeouts, but connection timeout still applies
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   cfg: Configuration with Unix socket and connection options
///   socket_path: Path to Unix domain socket to connect to
///
/// Returns: Error if connection fails or I/O error occurs
fn runUnixSocketClient(allocator: std.mem.Allocator, cfg: *const config.Config, socket_path: []const u8) !void {
    // 1. Check platform support
    if (!unixsock.unix_socket_supported) {
        logging.logError(error.UnixSocketsNotSupported, "Unix domain sockets are not supported on this platform");
        return error.UnixSocketsNotSupported;
    }

    // 2. Validate configuration conflicts
    if (cfg.ssl) {
        logging.logError(error.InvalidConfiguration, "TLS is not meaningful with Unix domain sockets (local communication)");
        return error.InvalidConfiguration;
    }

    if (cfg.udp_mode) {
        logging.logError(error.InvalidConfiguration, "UDP mode is not supported with Unix domain sockets");
        return error.InvalidConfiguration;
    }

    if (cfg.proxy != null) {
        logging.logError(error.InvalidConfiguration, "Proxy connections are not supported with Unix domain sockets");
        return error.InvalidConfiguration;
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Unix socket client configuration:\n", .{});
        logging.logVerbose(cfg, "  Socket path: {s}\n", .{socket_path});
        if (cfg.exec_command) |cmd| {
            logging.logVerbose(cfg, "  Exec command: {s}\n", .{cmd});
        }
    }

    // 3. Validate socket path
    try unixsock.validatePath(socket_path);

    // 4. Create Unix socket client
    var unix_client = unixsock.UnixSocket.initClient(allocator, socket_path) catch |err| {
        logging.logError(err, "creating Unix socket client");
        logging.logWarning("  Check path format and system resources for: {s}\n", .{socket_path});
        return err;
    };
    defer unix_client.close();

    // 5. Connect to Unix socket server
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Connecting to Unix socket: {s}\n", .{socket_path});
    }

    unix_client.connect() catch |err| {
        switch (err) {
            error.FileNotFound => {
                logging.logError(err, "Unix socket not found");
                logging.logWarning("  Socket path: {s}\n", .{socket_path});
                logging.logWarning("  Make sure the server is running and the path is correct\n", .{});
            },
            error.ConnectionRefused => {
                logging.logError(err, "Connection refused to Unix socket");
                logging.logWarning("  Socket path: {s}\n", .{socket_path});
                logging.logWarning("  The socket exists but no server is listening\n", .{});
            },
            error.PermissionDenied => {
                logging.logError(err, "Permission denied connecting to Unix socket");
                logging.logWarning("  Socket path: {s}\n", .{socket_path});
                logging.logWarning("  Check socket file permissions\n", .{});
            },
            else => {
                logging.logError(err, "connecting to Unix socket");
                logging.logWarning("  Socket path: {s}\n", .{socket_path});
            },
        }
        return err;
    };

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Connected to Unix socket.\n", .{});
    }

    // 6. Handle zero-I/O mode (connection test)
    if (cfg.zero_io) {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Zero-I/O mode (-z): Unix socket connection test successful, closing.\n", .{});
        }
        return;
    }

    // 7. Execute command if specified
    if (cfg.exec_command) |cmd| {
        try executeCommand(allocator, unix_client.getSocket(), cmd, cfg);
        return;
    }

    // 8. Bidirectional data transfer
    // Initialize output logger and hex dumper
    var output_logger = try output.OutputLogger.init(allocator, cfg.output_file, cfg.append_output);
    defer output_logger.deinit();

    var hex_dumper = try hexdump.HexDumper.init(allocator, cfg.hex_dump_file);
    defer hex_dumper.deinit();

    // Handle Telnet protocol mode for Unix sockets
    if (cfg.telnet) {
        // Create Connection wrapper for Unix socket
        const connection = Connection.fromUnixSocket(unix_client.getSocket(), null);

        // Wrap with TelnetConnection for protocol processing
        var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null);
        defer telnet_conn.deinit();

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Telnet protocol mode enabled for Unix socket, performing initial negotiation...\n", .{});
        }

        // Perform initial Telnet negotiation
        try telnet_conn.performInitialNegotiation();

        // Use TelnetConnection for bidirectional transfer
        try transferWithTelnetConnection(allocator, &telnet_conn, cfg, &output_logger, &hex_dumper);
    } else {
        // Use standard bidirectional transfer with Unix socket
        const stream = std.net.Stream{ .handle = unix_client.getSocket() };
        try transfer.bidirectionalTransfer(allocator, stream, cfg, &output_logger, &hex_dumper);
    }
}

/// Bidirectional data transfer using TelnetConnection.
/// Handles Telnet protocol processing while maintaining compatibility with existing I/O control features.
///
/// This function provides the same functionality as the standard bidirectional transfer
/// but processes data through the Telnet protocol layer for IAC sequence handling and
/// option negotiation.
///
/// Parameters:
///   allocator: Memory allocator for buffers and temporary data
///   telnet_conn: TelnetConnection handling protocol processing
///   cfg: Configuration with I/O control, timeouts, and logging options
///   output_logger: Logger for output file writing
///   hex_dumper: Hex dump formatter for debugging output
fn transferWithTelnetConnection(
    allocator: std.mem.Allocator,
    telnet_conn: *TelnetConnection,
    cfg: *const config.Config,
    output_logger: *output.OutputLogger,
    hex_dumper: *hexdump.HexDumper,
) !void {
    // Use the same transfer logic as the standard bidirectional transfer,
    // but create a wrapper that uses TelnetConnection's read/write methods
    const TelnetStream = struct {
        telnet_conn: *TelnetConnection,

        const Self = @This();

        pub fn read(self: Self, buffer: []u8) !usize {
            return self.telnet_conn.read(buffer);
        }

        pub fn write(self: Self, data: []const u8) !usize {
            return self.telnet_conn.write(data);
        }

        pub fn close(self: Self) void {
            self.telnet_conn.close();
        }
    };

    const telnet_stream = TelnetStream{ .telnet_conn = telnet_conn };

    // Create a std.net.Stream-compatible wrapper for the transfer function
    // Note: This is a bit of a hack since std.net.Stream expects a file handle,
    // but we need to use our TelnetConnection methods instead.
    // We'll need to implement our own transfer logic here.

    try telnetBidirectionalTransfer(allocator, telnet_stream, cfg, output_logger, hex_dumper);
}

/// Telnet-aware bidirectional data transfer between stdin/stdout and Telnet connection.
///
/// This function replicates the core logic of bidirectionalTransfer but uses
/// TelnetConnection methods for network I/O to ensure proper Telnet protocol handling.
///
/// Features:
/// - Telnet protocol processing (IAC sequences, option negotiation)
/// - I/O control modes (send-only, recv-only)
/// - Timeout handling with poll()
/// - Output logging and hex dump support
/// - Graceful shutdown on EOF or timeout
///
/// Parameters:
///   allocator: Memory allocator for buffers
///   telnet_stream: Wrapper around TelnetConnection
///   cfg: Configuration with I/O control and timeout settings
///   output_logger: Logger for output file writing
///   hex_dumper: Hex dump formatter for debugging
pub fn telnetBidirectionalTransfer(
    allocator: std.mem.Allocator,
    telnet_stream: anytype,
    cfg: *const config.Config,
    output_logger: *output.OutputLogger,
    hex_dumper: *hexdump.HexDumper,
) !void {
    _ = allocator; // May be used for future buffer allocation

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var buffer: [8192]u8 = undefined;
    const should_continue = true;

    // Get socket for poll operations
    const socket = telnet_stream.telnet_conn.getSocket();

    while (should_continue) {
        // Set up poll for both stdin and socket
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 },
        };

        // Apply I/O control modes
        if (cfg.recv_only) {
            poll_fds[0].events = 0; // Don't poll stdin in recv-only mode
        }
        if (cfg.send_only) {
            poll_fds[1].events = 0; // Don't poll socket in send-only mode
        }

        // Poll with timeout
        const timeout_ms: i32 = if (cfg.idle_timeout > 0) @intCast(cfg.idle_timeout) else -1;
        const poll_result = std.posix.poll(&poll_fds, timeout_ms) catch |err| {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Poll error: {}\n", .{err});
            }
            break;
        };

        if (poll_result == 0) {
            // Timeout
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Idle timeout reached, closing connection.\n", .{});
            }
            break;
        }

        // Handle stdin data (send to network)
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const bytes_read = stdin.read(&buffer) catch |err| {
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Stdin read error: {}\n", .{err});
                }
                break;
            };

            if (bytes_read == 0) {
                // EOF on stdin
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "EOF on stdin\n", .{});
                }
                if (cfg.close_on_eof) {
                    break;
                }
                // Continue reading from network even after stdin EOF
                poll_fds[0].events = 0;
            } else {
                var data_to_send = buffer[0..bytes_read];

                // Apply CRLF conversion if enabled
                var crlf_buffer: [16384]u8 = undefined;
                if (cfg.crlf) {
                    var crlf_len: usize = 0;
                    for (data_to_send) |byte| {
                        if (byte == '\n' and crlf_len < crlf_buffer.len - 1) {
                            crlf_buffer[crlf_len] = '\r';
                            crlf_len += 1;
                        }
                        if (crlf_len < crlf_buffer.len) {
                            crlf_buffer[crlf_len] = byte;
                            crlf_len += 1;
                        }
                    }
                    data_to_send = crlf_buffer[0..crlf_len];
                }

                // Send through Telnet connection
                const bytes_written = telnet_stream.telnet_conn.write(data_to_send) catch |err| {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Network write error: {}\n", .{err});
                    }
                    break;
                };

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Sent {} bytes to network\n", .{bytes_written});
                }

                // Log to hex dump if enabled
                try hex_dumper.dump(data_to_send[0..bytes_written]);
            }
        }

        // Handle network data (send to stdout)
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const bytes_read = telnet_stream.telnet_conn.read(&buffer) catch |err| {
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Network read error: {}\n", .{err});
                }
                break;
            };

            if (bytes_read == 0) {
                // EOF on network
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "EOF on network connection\n", .{});
                }
                break;
            } else {
                const data_received = buffer[0..bytes_read];

                // Write to stdout
                _ = stdout.write(data_received) catch |err| {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Stdout write error: {}\n", .{err});
                    }
                    break;
                };

                // Log to output file if enabled
                try output_logger.write(data_received);

                // Log to hex dump if enabled
                try hex_dumper.dump(data_received);

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Received {} bytes from network\n", .{bytes_read});
                }
            }
        }

        // Check for error conditions
        if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Stdin error condition\n", .{});
            }
            break;
        }

        if (poll_fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Network error condition\n", .{});
            }
            break;
        }
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Telnet transfer completed\n", .{});
    }
}
