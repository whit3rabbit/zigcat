// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! TLS/DTLS client handshake and connection management.
//!
//! This module handles:
//! - TLS handshake for TCP connections (OpenSSL/wolfSSL)
//! - DTLS handshake for UDP connections (OpenSSL only)
//! - Certificate verification warnings
//! - TLS configuration from command-line flags
//!
//! Security notes:
//! - Certificate verification disabled by default (warns user)
//! - Supports custom trust files, CRL, ALPN, cipher suites
//! - DTLS only available with OpenSSL backend (wolfSSL uses stub)

const std = @import("std");
const posix = std.posix;
const config = @import("../config.zig");
const tls = @import("../tls/tls.zig");
const logging = @import("../util/logging.zig");

// DTLS support (conditional compilation)
const build_options = @import("build_options");
const dtls_enabled = build_options.enable_tls and (!@hasDecl(build_options, "use_wolfssl") or !build_options.use_wolfssl);
const dtls = if (dtls_enabled) @import("../tls/dtls/dtls.zig") else struct {
    // Use shared stub to ensure type consistency across modules
    pub const DtlsConnection = @import("../tls/dtls/dtls_stub.zig").DtlsConnection;

    /// DTLS configuration (stub - matches real DtlsConfig for compile-time compatibility).
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

    /// DTLS connection stub - always returns error.DtlsNotAvailableWithWolfSSL.
    /// This is the primary guard preventing DTLS usage with wolfSSL backend.
    pub fn connectDtls(_: std.mem.Allocator, _: []const u8, _: u16, _: DtlsConfig) !*DtlsConnection {
        // Print user-friendly error message before returning error
        std.debug.print("\n", .{});
        std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ⚠️  DTLS NOT AVAILABLE                                  ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  DTLS (Datagram TLS) is only supported when zigcat is    ║\n", .{});
        std.debug.print("║  built with OpenSSL backend.                             ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Current build: wolfSSL backend (DTLS not supported)     ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Solutions:                                               ║\n", .{});
        std.debug.print("║  • Rebuild with OpenSSL: zig build -Duse-wolfssl=false   ║\n", .{});
        std.debug.print("║  • Use regular TLS over TCP instead of DTLS over UDP     ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Example (TLS over TCP):                                 ║\n", .{});
        std.debug.print("║    zigcat --ssl <host> <port>                            ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        return error.DtlsNotAvailableWithWolfSSL;
    }
};

/// TLS connection result (either TLS or DTLS).
pub const TlsConnectionResult = union(enum) {
    tls: tls.TlsConnection,
    dtls: *dtls.DtlsConnection,

    /// Get the underlying socket handle.
    pub fn getSocket(self: *const TlsConnectionResult) posix.socket_t {
        return switch (self.*) {
            .tls => |conn| @constCast(&conn).getSocket(),
            .dtls => |conn| conn.getSocket(),
        };
    }

    /// Close the TLS/DTLS connection.
    pub fn close(self: *TlsConnectionResult) void {
        switch (self.*) {
            .tls => |*conn| conn.close(),
            .dtls => |conn| conn.close(),
        }
    }

    /// Free TLS/DTLS resources.
    pub fn deinit(self: *TlsConnectionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tls => |*conn| conn.deinit(),
            .dtls => |conn| {
                conn.deinit();
                allocator.destroy(conn);
            },
        }
    }
};

/// Establish TLS or DTLS connection based on configuration.
///
/// Handles both:
/// - TLS over TCP: Wraps existing socket with TLS
/// - DTLS over UDP: Creates new UDP socket and wraps with DTLS
///
/// Parameters:
///   allocator: Memory allocator for DTLS connection
///   cfg: Configuration with TLS/DTLS settings
///   host: Target hostname (for SNI)
///   port: Target port number
///   raw_socket: Existing TCP socket (ignored for DTLS, DTLS creates own socket)
///
/// Returns: TlsConnectionResult (either TLS or DTLS)
///
/// Errors:
///   error.HandshakeFailed: TLS/DTLS handshake failed
///   error.DtlsNotAvailableWithWolfSSL: DTLS requested but not supported
pub fn establishTlsConnection(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
    raw_socket: posix.socket_t,
) !TlsConnectionResult {
    // Security warning if certificate verification is disabled
    if (!cfg.ssl_verify and cfg.insecure) {
        logging.logWarning("⚠️  Certificate verification is DISABLED. Connection is NOT secure!\n", .{});
        logging.logWarning("⚠️  Remove --insecure or add --ssl-verify to enable certificate validation.\n", .{});
    }

    if (cfg.udp_mode or cfg.dtls) {
        // DTLS mode (TLS over UDP)
        return try establishDtlsConnection(allocator, cfg, host, port);
    } else {
        // TLS mode (TLS over TCP)
        return try establishTlsTcpConnection(allocator, cfg, host, port, raw_socket);
    }
}

/// Establish TLS connection over TCP.
///
/// Wraps an existing TCP socket with TLS encryption.
///
/// Parameters:
///   allocator: Memory allocator
///   cfg: Configuration with TLS settings
///   host: Target hostname (for SNI)
///   port: Target port number (unused, for API consistency)
///   raw_socket: Existing TCP socket to wrap
///
/// Returns: TlsConnectionResult.tls
fn establishTlsTcpConnection(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
    raw_socket: posix.socket_t,
) !TlsConnectionResult {
    _ = port; // Unused for TLS (socket already connected)

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

    const tls_connection = try tls.connectTls(allocator, raw_socket, tls_config);

    if (cfg.verbose) {
        logging.logVerbose(cfg, "TLS handshake complete.\n", .{});
    }

    return TlsConnectionResult{ .tls = tls_connection };
}

/// Establish DTLS connection over UDP.
///
/// Creates a new UDP socket and wraps it with DTLS encryption.
///
/// Note: DTLS is only available with OpenSSL backend. wolfSSL builds
/// will return error.DtlsNotAvailableWithWolfSSL.
///
/// Parameters:
///   allocator: Memory allocator for DTLS connection
///   cfg: Configuration with DTLS settings
///   host: Target hostname
///   port: Target port number
///
/// Returns: TlsConnectionResult.dtls
fn establishDtlsConnection(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
) !TlsConnectionResult {
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

    const dtls_connection = try dtls.connectDtls(allocator, host, port, dtls_config);

    if (cfg.verbose) {
        logging.logVerbose(cfg, "DTLS handshake complete.\n", .{});
    }

    return TlsConnectionResult{ .dtls = dtls_connection };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "TlsConnectionResult union" {
    // This is a compile-time test to ensure the union is well-formed
    // Verify union discriminant
    const tls_variant = TlsConnectionResult{ .tls = undefined };
    const dtls_variant = TlsConnectionResult{ .dtls = undefined };

    try testing.expect(@intFromEnum(std.meta.activeTag(tls_variant)) == 0);
    try testing.expect(@intFromEnum(std.meta.activeTag(dtls_variant)) == 1);
}
