// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! gsocket client mode - NAT-traversal connection via GSRN relay.
//!
//! gsocket client workflow:
//! 1. Establish GSRN tunnel to relay server (gs.thc.org:443)
//! 2. Perform SRP handshake for end-to-end encryption
//! 3. Bidirectional data transfer with logging
//!
//! gsocket specific behavior:
//! - No TLS support (has its own SRP encryption)
//! - No proxy support (has its own NAT traversal)
//! - Connects through GSRN relay network
//! - End-to-end encrypted with SRP-AES-256-CBC-SHA
//!
//! Protocol details:
//! - Secret → GS-Address (SHA256-based derivation)
//! - Secret → SRP password (32 hex chars + null)
//! - Client/server role determined by GsStart.flags from relay

const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const gsocket = @import("../net/gsocket.zig");
const srp = @import("../tls/srp_openssl.zig");
const adapters = @import("./stream_adapters.zig");
const TransferContext = @import("./transfer_context.zig").TransferContext;

/// Run gsocket client or server mode (determined by -l flag and relay response).
///
/// Workflow:
/// 1. Establish GSRN tunnel through relay server
/// 2. Perform SRP handshake (client or server based on cfg.listen_mode)
/// 3. Handle zero-I/O mode (connection test)
/// 4. Run bidirectional data transfer with logging
///
/// Parameters:
///   allocator: Memory allocator for dynamic allocations
///   cfg: Configuration with gsocket secret and connection options
///   secret: Shared secret for GSRN address derivation and SRP auth
///
/// Returns: Error if connection fails or I/O error occurs
///
/// Errors:
///   error.HandshakeFailed: SRP handshake failed
///   error.InvalidSecret: Secret too short (< 8 bytes)
///   error.ConnectionTimeout: GSRN tunnel establishment timed out
pub fn runGsocketClient(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    secret: []const u8,
) !void {
    if (cfg.verbose) {
        logging.logVerbose(cfg, "gsocket mode enabled\n", .{});
        logging.logVerbose(cfg, "  Mode: {s}\n", .{if (cfg.listen_mode) "listen" else "connect"});
    }

    // 1. Establish GSRN tunnel through relay and get the assigned role
    //    Connect to gs.thc.org:443, send GsListen/GsConnect packet,
    //    wait for GsStart response, return raw TCP tunnel + role from relay
    const tunnel_result = try gsocket.establishGsrnTunnel(allocator, cfg);
    defer tunnel_result.stream.close();

    // 2. Perform SRP handshake over tunnel
    //    Use -w timeout if set, otherwise connect_timeout
    const timeout_ms = if (cfg.wait_time > 0) cfg.wait_time else cfg.connect_timeout;

    // *** FIX: Use the role returned from the relay (NOT cfg.listen_mode) ***
    // This allows both users to run the same command without coordination.
    // The first peer to connect becomes the server, second becomes client.
    var srp_conn = switch (tunnel_result.role) {
        .Server => try srp.SrpConnection.initServer(allocator, tunnel_result.stream, secret, timeout_ms),
        .Client => try srp.SrpConnection.initClient(allocator, tunnel_result.stream, secret, timeout_ms),
    };

    defer {
        srp_conn.close(); // Send TLS close_notify
        srp_conn.deinit(allocator); // Free OpenSSL resources AND heap-allocated struct
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "gsocket connection established (encrypted with SRP)\n", .{});
    }

    // 3. Handle zero-I/O mode (connection test)
    if (cfg.zero_io) {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Zero-I/O mode (-z): gsocket connection test successful, closing.\n", .{});
        }
        return;
    }

    // 4. Bidirectional data transfer with logging
    var transfer_ctx = try TransferContext.init(allocator, cfg);
    defer transfer_ctx.deinit();

    // Wrap SRP connection in Stream interface for bidirectionalTransfer()
    const s = adapters.srpConnectionToStream(srp_conn);
    try transfer_ctx.runTransfer(allocator, s, cfg);
}
