// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Client mode orchestrator.
//!
//! This module provides the main entry point for client mode and coordinates
//! all client-side functionality:
//! - Mode dispatch (gsocket, Unix socket, TCP/UDP/SCTP)
//! - Port scanning (zero-I/O mode)
//! - Connection establishment (via tcp_client)
//! - TLS/DTLS handshake (via tls_client)
//! - Bidirectional data transfer (via transfer_context)
//! - Telnet protocol support
//!
//! Architecture:
//! This module serves as a thin orchestration layer that delegates to
//! specialized modules for each concern, following the refactored pattern
//! used by src/server/exec_session/.

const std = @import("std");
const posix = std.posix;
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const portscan = @import("../util/portscan.zig");
const net = @import("../net/socket.zig");

// Check if TLS is enabled for conditional gsocket import
const build_options = @import("build_options");

// Client mode modules
// Only import gsocket_client when using OpenSSL backend (wolfSSL doesn't support SRP)
const gsocket_client = if (build_options.enable_tls and std.mem.eql(u8, build_options.tls_backend, "openssl"))
    @import("./gsocket_client.zig")
else
    struct {};
const unix_client = @import("./unix_client.zig");
const tcp_client = @import("./tcp_client.zig");
const tls_client = @import("./tls_client.zig");
const telnet_client = @import("./telnet_client.zig");
const adapters = @import("./stream_adapters.zig");
const TransferContext = @import("./transfer_context.zig").TransferContext;
const exec_client = @import("./exec_client.zig");

// Re-export stream adapters for use by server mode
pub const telnetConnectionToStream = adapters.telnetConnectionToStream;
pub const tlsConnectionToStream = adapters.tlsConnectionToStream;
pub const srpConnectionToStream = adapters.srpConnectionToStream;
pub const dtlsConnectionToStream = adapters.dtlsConnectionToStream;
pub const netStreamToStream = adapters.netStreamToStream;

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
/// - gsocket: NAT-traversal via GSRN relay with SRP encryption
/// - Unix socket: Connect to local Unix domain socket
/// - Proxy: Use HTTP CONNECT, SOCKS4, or SOCKS5 proxy
/// - UDP: Create UDP client socket
/// - TCP: Non-blocking connect with poll() timeout
///
/// Timeout behavior:
/// - Uses cfg.wait_time if set via -w flag
/// - Falls back to cfg.connect_timeout (default 30s)
/// - All operations respect timeout for reliability
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   cfg: Configuration with target, protocol, and connection options
///
/// Returns: Error if connection fails or I/O error occurs
pub fn runClient(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    // 1. Check for gsocket mode (NAT-traversal via GSRN relay)
    // Only compile this path when OpenSSL backend is available
    if (comptime (build_options.enable_tls and std.mem.eql(u8, build_options.tls_backend, "openssl"))) {
        if (cfg.gsocket_secret) |secret| {
            return gsocket_client.runGsocketClient(allocator, cfg, secret);
        }
    } else {
        // If user somehow has gsocket_secret set but we don't have OpenSSL, error out
        if (cfg.gsocket_secret != null) {
            std.debug.print("ERROR: gsocket mode requires OpenSSL backend for SRP encryption.\n", .{});
            if (build_options.enable_tls) {
                std.debug.print("Current backend: wolfSSL (does not support SRP)\n", .{});
                std.debug.print("Please rebuild zigcat with -Dtls-backend=openssl or use a different connection mode.\n", .{});
            } else {
                std.debug.print("TLS is disabled.\n", .{});
                std.debug.print("Please rebuild zigcat with -Dtls=true -Dtls-backend=openssl or use a different connection mode.\n", .{});
            }
            return error.GsocketNotAvailable;
        }
    }

    // 2. Check for Unix socket mode (local IPC)
    if (cfg.unix_socket_path) |socket_path| {
        return unix_client.runUnixSocketClient(allocator, cfg, socket_path);
    }

    // 3. Parse target host:port for TCP/UDP/SCTP
    if (cfg.positional_args.len < 2) {
        logging.logError(error.MissingArguments, "client mode requires <host> <port> or Unix socket path (-U)");
        return error.MissingArguments;
    }

    const host = cfg.positional_args[0];
    const port_spec = cfg.positional_args[1];

    // 4. Handle zero-I/O mode (port scanning) BEFORE attempting connection
    if (cfg.zero_io) {
        return handlePortScanning(allocator, cfg, host, port_spec);
    }

    // 5. For non-scanning modes, parse as single port
    const port = try std.fmt.parseInt(u16, port_spec, 10);

    // 6. Log configuration
    if (cfg.verbose) {
        logClientConfiguration(cfg, host, port);
    }

    // 7. Establish connection (TCP/UDP/SCTP/Proxy)
    const conn_result = try tcp_client.establishConnection(allocator, cfg, host, port);
    const raw_socket = conn_result.socket;

    // Ensure socket is cleaned up on error
    errdefer net.closeSocket(raw_socket);

    // 8. Optional TLS/DTLS handshake
    if (cfg.ssl or cfg.dtls) {
        return runTlsMode(allocator, cfg, host, port, raw_socket);
    }

    // 9. Execute command if specified (client-side exec)
    if (cfg.exec_command) |cmd| {
        defer net.closeSocket(raw_socket);
        return executeCommand(allocator, raw_socket, cmd, cfg);
    }

    // 10. Bidirectional data transfer (plain socket, no TLS)
    defer net.closeSocket(raw_socket);
    return runBidirectionalTransfer(allocator, cfg, raw_socket, null, null);
}

// ============================================================================
// Port Scanning (Zero-I/O Mode)
// ============================================================================

/// Handle zero-I/O mode (port scanning).
///
/// Supports both single port and port range scanning.
/// Uses parallel or sequential scanning based on --scan-parallel flag.
fn handlePortScanning(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port_spec: []const u8,
) !void {
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
}

// ============================================================================
// TLS Mode (TLS/DTLS with optional Telnet)
// ============================================================================

/// Run client in TLS/DTLS mode.
///
/// This handles the complex case where TLS/DTLS is enabled.
/// DTLS creates its own socket, so raw_socket may be a dummy (0).
fn runTlsMode(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
    raw_socket: posix.socket_t,
) !void {
    // Establish TLS/DTLS connection
    var tls_result = try tls_client.establishTlsConnection(allocator, cfg, host, port, raw_socket);
    defer tls_result.deinit(allocator);

    // Handle exec mode
    if (cfg.exec_command) |cmd| {
        defer {
            tls_result.close();
            if (raw_socket != 0) net.closeSocket(raw_socket);
        }
        return executeCommand(allocator, tls_result.getSocket(), cmd, cfg);
    }

    // Bidirectional transfer
    defer {
        tls_result.close();
        if (raw_socket != 0) net.closeSocket(raw_socket);
    }

    // Determine which variant we have (TLS or DTLS)
    switch (tls_result) {
        .tls => |*tls_conn| {
            return runBidirectionalTransfer(allocator, cfg, raw_socket, tls_conn, null);
        },
        .dtls => |dtls_conn| {
            // DTLS does not support Telnet protocol (datagram-based)
            if (cfg.telnet) {
                logging.logError(error.InvalidConfiguration, "Telnet protocol mode is not supported with DTLS (datagram-based)");
                return error.InvalidConfiguration;
            }
            return runBidirectionalTransfer(allocator, cfg, raw_socket, null, dtls_conn);
        },
    }
}

// ============================================================================
// Bidirectional Transfer
// ============================================================================

/// Run bidirectional data transfer with optional TLS and Telnet support.
///
/// Parameters:
///   allocator: Memory allocator
///   cfg: Configuration
///   raw_socket: Raw socket handle (may be 0 for DTLS)
///   tls_conn: Optional TLS connection (mutually exclusive with dtls_conn)
///   dtls_conn: Optional DTLS connection (mutually exclusive with tls_conn)
fn runBidirectionalTransfer(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    raw_socket: posix.socket_t,
    tls_conn: ?*@import("../tls/tls.zig").TlsConnection,
    dtls_conn: anytype, // ?*dtls.DtlsConnection (type varies by backend)
) !void {
    // Initialize transfer context (output logger + hex dumper)
    var transfer_ctx = try TransferContext.init(allocator, cfg);
    defer transfer_ctx.deinit();

    // Handle Telnet protocol mode
    // Note: Telnet/DTLS incompatibility is checked in runTlsMode() before calling this function
    if (cfg.telnet) {
        return runTelnetTransfer(allocator, cfg, raw_socket, tls_conn, &transfer_ctx);
    }

    // Standard transfer without Telnet processing
    // Note: dtls_conn is anytype - check if it's a pointer type vs null
    const DtlsConnType = @TypeOf(dtls_conn);
    if (DtlsConnType != @TypeOf(null)) {
        // DTLS connection (datagram-based) - dtls_conn is a pointer
        const s = adapters.dtlsConnectionToStream(dtls_conn);
        try transfer_ctx.runTransfer(allocator, s, cfg);
    } else if (tls_conn) |conn| {
        // TLS connection (stream-based)
        const s = adapters.tlsConnectionToStream(conn);
        try transfer_ctx.runTransfer(allocator, s, cfg);
    } else {
        // Plain socket connection
        const net_stream = std.net.Stream{ .handle = raw_socket };
        const s = adapters.netStreamToStream(net_stream);
        try transfer_ctx.runTransfer(allocator, s, cfg);
    }
}

// ============================================================================
// Telnet Protocol Support
// ============================================================================

/// Run bidirectional transfer with Telnet protocol processing.
///
/// Delegates to telnet_client module for full Telnet functionality:
/// - TTY raw mode configuration
/// - Signal translation (SIGINT → Telnet IP, etc.)
/// - SIGWINCH tracking (window resize → Telnet NAWS)
/// - Initial Telnet negotiation
/// - Bidirectional transfer with IAC processing
///
/// This function is a thin wrapper that maintains API compatibility while
/// delegating to the specialized telnet_client module.
fn runTelnetTransfer(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    raw_socket: posix.socket_t,
    tls_conn: ?*@import("../tls/tls.zig").TlsConnection,
    transfer_ctx: *TransferContext,
) !void {
    return telnet_client.runTelnetClient(allocator, cfg, raw_socket, tls_conn, transfer_ctx);
}

// ============================================================================
// Exec Mode (Client-Side Command Execution)
// ============================================================================

fn executeCommand(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    cmd: []const u8,
    cfg: *const config.Config,
) !void {
    try exec_client.executeCommand(allocator, socket, cmd, cfg);
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Log client configuration (verbose mode).
fn logClientConfiguration(cfg: *const config.Config, host: []const u8, port: u16) void {
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
