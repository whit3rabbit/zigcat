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

// DTLS is currently only available with OpenSSL backend
// wolfSSL support for DTLS is not yet implemented
const build_options = @import("build_options");
const dtls_enabled = build_options.enable_tls and (!@hasDecl(build_options, "use_wolfssl") or !build_options.use_wolfssl);
const dtls = if (dtls_enabled) @import("tls/dtls/dtls.zig") else struct {
    // Stub DtlsConnection that has compatible methods for defer blocks
    pub const DtlsConnection = struct {
        pub fn deinit(_: *DtlsConnection) void {}
        pub fn close(_: *DtlsConnection) void {}
        pub fn read(_: *DtlsConnection, _: []u8) !usize {
            return error.DtlsNotAvailableWithWolfSSL;
        }
        pub fn write(_: *DtlsConnection, _: []const u8) !usize {
            return error.DtlsNotAvailableWithWolfSSL;
        }
        pub fn getSocket(_: *DtlsConnection) posix.socket_t {
            return 0;
        }
    };
    pub const DtlsConfig = struct {
        verify_peer: bool = true,
        server_name: ?[]const u8 = null,
        trust_file: ?[]const u8 = null,
        crl_file: ?[]const u8 = null,
        alpn_protocols: ?[]const u8 = null,
        cipher_suites: ?[]const u8 = null,
        mtu: u16 = 1200,
        initial_timeout_ms: u32 = 1000,
        replay_window: u64 = 64,
    };
    pub fn connectDtls(_: std.mem.Allocator, _: []const u8, _: u16, _: DtlsConfig) !*DtlsConnection {
        return error.DtlsNotAvailableWithWolfSSL;
    }
};

const transfer = @import("io/transfer.zig");
const stream = @import("io/stream.zig");
const output = @import("io/output.zig");
const hexdump = @import("io/hexdump.zig");
const proxy = @import("net/proxy/mod.zig");
const logging = @import("util/logging.zig");
const portscan = @import("util/portscan.zig");
const Connection = @import("net/connection.zig").Connection;
const TelnetConnection = @import("protocol/telnet_connection.zig").TelnetConnection;

inline fn contextToPtr(comptime T: type, context: *anyopaque) *T {
    const aligned_ctx: *align(@alignOf(T)) anyopaque = @alignCast(context);
    return @ptrCast(aligned_ctx);
}

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
    const port_spec = cfg.positional_args[1];

    // Handle zero-I/O mode (port scanning) BEFORE attempting connection
    if (cfg.zero_io) {
        const timeout = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;

        // Parse port specification (single port or range)
        const port_range = try portscan.PortRange.parse(port_spec);

        if (port_range.isSinglePort()) {
            // Single port scan
            const is_open = try portscan.scanPort(allocator, host, port_range.start, timeout);
            std.debug.print("{s}:{d} - {s}\n", .{ host, port_range.start, if (is_open) "open" else "closed" });
        } else {
            // Port range scan
            if (cfg.scan_parallel) {
                // Parallel scanning
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Scanning {s}:{d}-{d} with {d} workers (parallel mode)\n", .{
                        host,
                        port_range.start,
                        port_range.end,
                        cfg.scan_workers,
                    });
                }
                try portscan.scanPortRangeParallel(allocator, host, port_range.start, port_range.end, timeout, cfg.scan_workers, cfg.scan_randomize, cfg.scan_delay_ms);
            } else {
                // Sequential scanning
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Scanning {s}:{d}-{d} (sequential mode)\n", .{ host, port_range.start, port_range.end });
                }
                try portscan.scanPortRange(allocator, host, port_range.start, port_range.end, timeout);
            }
        }

        // Port scanning complete, exit
        return;
    }

    // For non-scanning modes, parse as single port
    const port = try std.fmt.parseInt(u16, port_spec, 10);

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
    // NOTE: DTLS creates its own UDP socket, so we skip socket creation if DTLS is enabled
    const raw_socket = blk: {
        // DTLS mode will create its own socket later
        if ((cfg.ssl or cfg.dtls) and (cfg.udp_mode or cfg.dtls)) {
            // Return dummy socket (0), DTLS will create its own
            break :blk @as(posix.socket_t, 0);
        }

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
                break :blk try sctp.openSctpClient(host, port, @intCast(timeout));
            } else {
                // Use wait_time if set via -w, otherwise fall back to connect_timeout default
                const timeout = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;

                // Handle --keep-source-port flag
                if (cfg.keep_source_port) {
                    const src_port = cfg.source_port orelse 0;
                    break :blk try tcp.openTcpClientWithSourcePort(host, port, timeout, src_port, cfg);
                } else {
                    break :blk try tcp.openTcpClient(host, port, timeout, cfg);
                }
            }
        }
    };

    // Ensure socket is cleaned up on error (skip dummy socket 0 for DTLS)
    errdefer if (raw_socket != 0) net.closeSocket(raw_socket);

    if (cfg.verbose and raw_socket != 0) {
        logging.logVerbose(cfg, "Connection established.\n", .{});
    }

    // 3. Optional TLS/DTLS handshake
    var tls_connection: ?tls.TlsConnection = null;
    var dtls_connection: ?*dtls.DtlsConnection = null;
    defer {
        if (tls_connection) |*conn| conn.deinit();
        if (dtls_connection) |conn| {
            conn.deinit();
            allocator.destroy(conn);
        }
    }

    if (cfg.ssl or cfg.dtls) {
        // Security warning if certificate verification is disabled
        if (!cfg.ssl_verify) {
            logging.logWarning("⚠️  Certificate verification is DISABLED. Connection is NOT secure!", .{});
            logging.logWarning("⚠️  Use --ssl-verify to enable certificate validation.", .{});
        }

        if (cfg.udp_mode or cfg.dtls) {
            // DTLS mode (TLS over UDP)
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Starting DTLS handshake...\n", .{});
            }

            const dtls_config = dtls.DtlsConfig{
                .verify_peer = cfg.ssl_verify,
                .server_name = cfg.ssl_servername orelse host,
                .trust_file = cfg.ssl_trustfile,
                .crl_file = cfg.ssl_crl,
                .alpn_protocols = cfg.ssl_alpn,
                .cipher_suites = cfg.ssl_ciphers,
                .mtu = cfg.dtls_mtu,
                .initial_timeout_ms = cfg.dtls_timeout,
                .replay_window = cfg.dtls_replay_window,
            };

            dtls_connection = try dtls.connectDtls(allocator, host, port, dtls_config);

            if (cfg.verbose) {
                logging.logVerbose(cfg, "DTLS handshake complete.\n", .{});
            }
        } else {
            // TLS mode (TLS over TCP)
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
        }
    }

    // 4. Execute command if specified
    if (cfg.exec_command) |cmd| {
        defer {
            if (tls_connection) |*conn| {
                conn.close();
            }
            if (dtls_connection) |conn| {
                conn.close();
            }
            if (raw_socket != 0) net.closeSocket(raw_socket);
        }
        try executeCommand(allocator, raw_socket, cmd, cfg);
        return;
    }

    // 6. Bidirectional data transfer
    defer {
        if (tls_connection) |*conn| {
            conn.close();
        }
        if (dtls_connection) |conn| {
            conn.close();
        }
        if (raw_socket != 0) net.closeSocket(raw_socket);
    }

    // Initialize output logger and hex dumper (automatically selects io_uring if available)
    var output_logger = try output.OutputLoggerAuto.init(allocator, cfg.output_file, cfg.append_output);
    defer output_logger.deinit();

    var hex_dumper = try hexdump.HexDumperAuto.init(allocator, cfg.hex_dump_file);
    defer hex_dumper.deinit();

    // Handle Telnet protocol mode
    if (cfg.telnet) {
        // DTLS does not support Telnet protocol (datagram-based)
        if (dtls_connection != null) {
            logging.logError(error.InvalidConfiguration, "Telnet protocol mode is not supported with DTLS (datagram-based)");
            return error.InvalidConfiguration;
        }

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
        const s = telnetConnectionToStream(&telnet_conn);
        try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
    } else {
        // Standard transfer without Telnet processing
        if (dtls_connection) |conn| {
            // DTLS connection (datagram-based)
            const s = dtlsConnectionToStream(conn);
            try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
        } else if (tls_connection) |*conn| {
            // TLS connection (stream-based)
            const s = tlsConnectionToStream(conn);
            try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
        } else {
            // Plain socket connection
            const net_stream = std.net.Stream{ .handle = raw_socket };
            const s = netStreamToStream(net_stream);
            try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
        }
    }
}

pub fn telnetConnectionToStream(telnet_conn: *TelnetConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(telnet_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(TelnetConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(TelnetConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(TelnetConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(TelnetConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

pub fn tlsConnectionToStream(tls_conn: *tls.TlsConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(tls_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(tls.TlsConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

pub fn dtlsConnectionToStream(dtls_conn: *dtls.DtlsConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(dtls_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(dtls.DtlsConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

pub fn netStreamToStream(net_stream: std.net.Stream) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(@constCast(&net_stream)),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const s = contextToPtr(std.net.Stream, context);
                return s.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const s = contextToPtr(std.net.Stream, context);
                return s.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const s = contextToPtr(std.net.Stream, context);
                s.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const s = contextToPtr(std.net.Stream, context);
                return s.handle;
            }
        }.handle,
    };
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
    // Initialize output logger and hex dumper (automatically selects io_uring if available)
    var output_logger = try output.OutputLoggerAuto.init(allocator, cfg.output_file, cfg.append_output);
    defer output_logger.deinit();

    var hex_dumper = try hexdump.HexDumperAuto.init(allocator, cfg.hex_dump_file);
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
        const s = telnetConnectionToStream(&telnet_conn);
        try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
    } else {
        // Use standard bidirectional transfer with Unix socket
        const net_stream = std.net.Stream{ .handle = unix_client.getSocket() };
        const s = netStreamToStream(net_stream);
        try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
    }
}
