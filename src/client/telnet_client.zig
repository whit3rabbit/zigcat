// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Telnet client orchestration.
//!
//! This module provides high-level Telnet client functionality by combining:
//! - TelnetSetup (TTY/signal/window configuration)
//! - TelnetConnection (protocol processing from src/protocol/)
//! - Stream adapters (stream.Stream interface)
//! - TransferContext (bidirectional I/O with logging)
//!
//! Workflow:
//! 1. Initialize TelnetSetup (detect TTY, enable raw mode, install signal handlers)
//! 2. Create TelnetConnection with window size and TTY state
//! 3. Perform initial Telnet negotiation (WILL/DO option handshake)
//! 4. Run bidirectional transfer with IAC sequence processing
//! 5. Cleanup (restore terminal state and signal handlers)
//!
//! This module is the glue between low-level protocol handling (src/protocol/)
//! and high-level client orchestration (src/client/mod.zig).

const std = @import("std");
const posix = std.posix;
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const Connection = @import("../net/connection.zig").Connection;
const TelnetConnection = @import("../protocol/telnet_connection.zig").TelnetConnection;
const TelnetSetup = @import("./telnet_setup.zig").TelnetSetup;
const TransferContext = @import("./transfer_context.zig").TransferContext;
const adapters = @import("./stream_adapters.zig");
const tls = @import("../tls/tls.zig");

/// Run Telnet client with full protocol support.
///
/// This function orchestrates all Telnet client setup:
/// - TTY raw mode configuration
/// - Signal translation (SIGINT → Telnet IP, etc.)
/// - SIGWINCH tracking (terminal resize → Telnet NAWS)
/// - Initial Telnet negotiation
/// - Bidirectional data transfer with IAC processing
///
/// The underlying socket can be either raw TCP or TLS-encrypted.
/// The TelnetConnection handles protocol details transparently.
///
/// Parameters:
///   allocator: Memory allocator for TelnetConnection buffers
///   cfg: Configuration with telnet_signal_mode and telnet_edit_mode
///   raw_socket: Underlying socket (TCP or Unix socket)
///   tls_conn: Optional TLS connection (null for plain TCP)
///   transfer_ctx: Transfer context for bidirectional I/O
///
/// Returns: Error if setup, negotiation, or transfer fails
pub fn runTelnetClient(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    raw_socket: posix.socket_t,
    tls_conn: ?*tls.TlsConnection,
    transfer_ctx: *TransferContext,
) !void {
    // Step 1: Initialize Telnet setup (TTY, signals, window size)
    var telnet_setup = try TelnetSetup.init(allocator, cfg);
    defer telnet_setup.deinit();

    if (cfg.verbose) {
        if (telnet_setup.local_tty_state != null) {
            logging.logVerbose(cfg, "Telnet TTY raw mode enabled\n", .{});
        } else {
            logging.logVerbose(cfg, "Telnet TTY raw mode unavailable (not a TTY or platform unsupported)\n", .{});
        }

        if (telnet_setup.signal_translation_active) {
            logging.logVerbose(cfg, "Telnet signal translation active (remote mode)\n", .{});
        }

        if (telnet_setup.window_width) |width| {
            logging.logVerbose(
                cfg,
                "Telnet initial window size: {d}x{d}\n",
                .{ width, telnet_setup.window_height.? },
            );
        }
    }

    // Step 2: Create Connection wrapper for underlying socket/TLS
    const connection = if (tls_conn) |conn|
        Connection.fromTls(conn.*)
    else
        Connection.fromSocket(raw_socket);

    // Step 3: Create TelnetConnection with protocol processing
    var telnet_conn = try TelnetConnection.init(
        connection,
        allocator,
        null, // terminal_type (use default "UNKNOWN")
        telnet_setup.window_width,
        telnet_setup.window_height,
        telnet_setup.getLocalTtyPtr(),
        telnet_setup.signal_translation_active,
    );
    defer telnet_conn.deinit();

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Telnet protocol mode enabled, performing initial negotiation...\n", .{});
    }

    // Step 4: Perform initial Telnet negotiation (WILL/DO handshake)
    try telnet_conn.performInitialNegotiation();

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Telnet negotiation complete, starting data transfer...\n", .{});
    }

    // Step 5: Run bidirectional transfer with Telnet IAC processing
    const stream = adapters.telnetConnectionToStream(&telnet_conn);
    try transfer_ctx.runTransfer(allocator, stream, cfg);
}

/// Run Telnet client for Unix socket connections.
///
/// Unix socket variant that simplifies configuration:
/// - No TLS support (Unix sockets are local)
/// - No window size negotiation (typically not needed for local IPC)
/// - Signal translation still supported (if requested)
///
/// This function is used by unix_client.zig when --telnet flag is enabled.
///
/// Parameters:
///   allocator: Memory allocator for TelnetConnection buffers
///   cfg: Configuration with telnet options
///   unix_socket: Unix domain socket handle
///   transfer_ctx: Transfer context for bidirectional I/O
///
/// Returns: Error if setup, negotiation, or transfer fails
pub fn runUnixSocketTelnetClient(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    unix_socket: posix.socket_t,
    transfer_ctx: *TransferContext,
) !void {
    // Step 1: Initialize Telnet setup (simpler for Unix sockets)
    var telnet_setup = try TelnetSetup.init(allocator, cfg);
    defer telnet_setup.deinit();

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Telnet protocol mode enabled for Unix socket\n", .{});
    }

    // Step 2: Create Connection wrapper for Unix socket
    // Note: Unix sockets don't have peer address, so pass null
    const connection = Connection.fromUnixSocket(unix_socket, null);

    // Step 3: Create TelnetConnection (no window size for Unix sockets)
    var telnet_conn = try TelnetConnection.init(
        connection,
        allocator,
        null, // terminal_type
        null, // window_width (not needed for local IPC)
        null, // window_height (not needed for local IPC)
        telnet_setup.getLocalTtyPtr(),
        telnet_setup.signal_translation_active,
    );
    defer telnet_conn.deinit();

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Performing Telnet negotiation over Unix socket...\n", .{});
    }

    // Step 4: Perform initial Telnet negotiation
    try telnet_conn.performInitialNegotiation();

    // Step 5: Run bidirectional transfer
    const stream = adapters.telnetConnectionToStream(&telnet_conn);
    try transfer_ctx.runTransfer(allocator, stream, cfg);
}
