// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Unix socket client mode - connect to Unix domain socket.
//!
//! Unix socket client workflow:
//! 1. Validate Unix socket support on current platform
//! 2. Create Unix socket client and connect to server
//! 3. Handle special modes (zero-I/O, exec)
//! 4. Bidirectional data transfer with logging
//!
//! Unix socket specific behavior:
//! - No TLS support (local communication doesn't need encryption)
//! - No proxy support (Unix sockets are local only)
//! - Uses filesystem permissions for access control
//! - Faster than TCP for local communication
//! - No network timeouts, but connection timeout still applies

const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const unixsock = @import("../net/unixsock.zig");
const Connection = @import("../net/connection.zig").Connection;
const TelnetConnection = @import("../protocol/telnet_connection.zig").TelnetConnection;
const adapters = @import("./stream_adapters.zig");
const TransferContext = @import("./transfer_context.zig").TransferContext;

/// Run Unix socket client mode - connect to Unix domain socket.
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   cfg: Configuration with Unix socket and connection options
///   socket_path: Path to Unix domain socket to connect to
///
/// Returns: Error if connection fails or I/O error occurs
///
/// Errors:
///   error.UnixSocketsNotSupported: Platform doesn't support Unix sockets
///   error.InvalidConfiguration: Conflicting options (TLS, UDP, proxy)
///   error.FileNotFound: Socket file doesn't exist
///   error.ConnectionRefused: Server not listening
///   error.PermissionDenied: Insufficient permissions
pub fn runUnixSocketClient(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    socket_path: []const u8,
) !void {
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
        // Forward to exec module (will be implemented in Phase 2)
        const executeCommand = @import("./exec_client.zig").executeCommand;
        try executeCommand(allocator, unix_client.getSocket(), cmd, cfg);
        return;
    }

    // 8. Bidirectional data transfer
    var transfer_ctx = try TransferContext.init(allocator, cfg);
    defer transfer_ctx.deinit();

    // Handle Telnet protocol mode for Unix sockets
    if (cfg.telnet) {
        // Create Connection wrapper for Unix socket
        const connection = Connection.fromUnixSocket(unix_client.getSocket(), null);

        // Wrap with TelnetConnection for protocol processing
        var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null, null, false);
        defer telnet_conn.deinit();

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Telnet protocol mode enabled for Unix socket, performing initial negotiation...\n", .{});
        }

        // Perform initial Telnet negotiation
        try telnet_conn.performInitialNegotiation();

        // Use TelnetConnection for bidirectional transfer
        const s = adapters.telnetConnectionToStream(&telnet_conn);
        try transfer_ctx.runTransfer(allocator, s, cfg);
    } else {
        // Use standard bidirectional transfer with Unix socket
        const net_stream = std.net.Stream{ .handle = unix_client.getSocket() };
        const s = adapters.netStreamToStream(net_stream);
        try transfer_ctx.runTransfer(allocator, s, cfg);
    }
}
