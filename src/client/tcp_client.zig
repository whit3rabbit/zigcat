// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! TCP/UDP/SCTP client connection establishment.
//!
//! This module handles socket creation and connection for all non-Unix modes:
//! - Direct TCP connection with optional source port binding
//! - UDP client socket creation
//! - SCTP connection (Linux only)
//! - Proxy connections (HTTP CONNECT, SOCKS4/5)
//!
//! All connections use non-blocking I/O with poll()-based timeout enforcement.

const std = @import("std");
const posix = std.posix;
const config = @import("../config.zig");
const net = @import("../net/socket.zig");
const tcp = @import("../net/tcp.zig");
const udp = @import("../net/udp.zig");
const sctp = @import("../net/sctp.zig");
const proxy = @import("../net/proxy/mod.zig");
const logging = @import("../util/logging.zig");

/// Connection result containing socket and optional proxy info.
pub const ConnectionResult = struct {
    socket: posix.socket_t,
    via_proxy: bool = false,
};

/// Establish TCP/UDP/SCTP connection to target host.
///
/// Connection methods (in order of precedence):
/// 1. Proxy: Use HTTP CONNECT, SOCKS4, or SOCKS5 proxy
/// 2. UDP: Create UDP client socket
/// 3. SCTP: Non-blocking connect with poll() timeout (Linux only)
/// 4. TCP: Non-blocking connect with poll() timeout
///
/// Timeout behavior:
/// - Uses cfg.wait_time if set via -w flag
/// - Falls back to cfg.connect_timeout (default 30s)
/// - All operations respect timeout for reliability
///
/// Parameters:
///   allocator: Memory allocator for proxy operations
///   cfg: Configuration with target, protocol, and connection options
///   host: Target hostname or IP address
///   port: Target port number
///
/// Returns: ConnectionResult with socket handle and proxy flag
///
/// Errors:
///   error.ConnectionTimeout: Connection timed out
///   error.ConnectionRefused: Target refused connection
///   error.NetworkUnreachable: Network unreachable
pub fn establishConnection(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
) !ConnectionResult {
    // Calculate timeout (use -w if set, else default)
    const timeout = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;

    // Check for proxy mode
    if (cfg.proxy) |_| {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Connecting via proxy...\n", .{});
        }

        const proxy_socket = try proxy.connectThroughProxy(allocator, cfg, host, port);

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Proxy connection established.\n", .{});
        }

        return ConnectionResult{
            .socket = proxy_socket,
            .via_proxy = true,
        };
    }

    // Direct connection (TCP/UDP/SCTP)
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Connecting to {s}:{d}...\n", .{ host, port });
    }

    const direct_socket = if (cfg.udp_mode)
        try udp.openUdpClient(host, port)
    else if (cfg.sctp_mode)
        try sctp.openSctpClient(host, port, @intCast(timeout))
    else blk: {
        // TCP mode with optional source port binding
        if (cfg.keep_source_port) {
            const src_port = cfg.source_port orelse 0;
            break :blk try tcp.openTcpClientWithSourcePort(host, port, timeout, src_port, cfg);
        } else {
            break :blk try tcp.openTcpClient(host, port, timeout, cfg);
        }
    };

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Connection established.\n", .{});
    }

    return ConnectionResult{
        .socket = direct_socket,
        .via_proxy = false,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "ConnectionResult struct" {
    const result = ConnectionResult{
        .socket = 42,
        .via_proxy = true,
    };

    try testing.expectEqual(@as(posix.socket_t, 42), result.socket);
    try testing.expect(result.via_proxy);
}

test "ConnectionResult default values" {
    const result = ConnectionResult{
        .socket = 10,
    };

    try testing.expectEqual(@as(posix.socket_t, 10), result.socket);
    try testing.expect(!result.via_proxy); // Default is false
}
