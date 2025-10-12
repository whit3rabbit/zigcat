// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


// DTLS public API
// Factory functions for creating DTLS client and server connections

const std = @import("std");
const posix = std.posix;
const net = std.net;
const dtls_iface = @import("dtls_iface.zig");

pub const DtlsConnection = dtls_iface.DtlsConnection;
pub const DtlsConfig = dtls_iface.DtlsConfig;
pub const DtlsVersion = dtls_iface.DtlsVersion;
pub const DtlsState = dtls_iface.DtlsState;
pub const DtlsStats = dtls_iface.DtlsStats;

/// Check if DTLS support is available
pub fn isDtlsAvailable() bool {
    // DTLS requires OpenSSL 1.0.2+ for DTLS 1.2
    // Check at compile time if OpenSSL is available
    const builtin = @import("builtin");
    return builtin.link_libc and @hasDecl(@import("root"), "c");
}

/// Connect to DTLS server (client mode)
/// Creates UDP socket, performs DTLS handshake, returns established connection
pub fn connectDtls(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    config: DtlsConfig,
) !*DtlsConnection {
    // Validate configuration
    try config.validate();

    // Check if DTLS is available at runtime
    if (!isDtlsAvailable()) {
        return error.DtlsNotAvailable;
    }

    // Use OpenSSL backend
    const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
    const dtls = try OpenSslDtls.initClient(allocator, host, port, config);
    errdefer dtls.deinit();

    // Wrap in DtlsConnection interface
    const conn = try allocator.create(DtlsConnection);
    errdefer allocator.destroy(conn);

    conn.* = .{
        .allocator = allocator,
        .backend = .{ .dtls_openssl = dtls },
    };

    return conn;
}

/// Accept DTLS connection from client (server mode)
/// Performs cookie exchange and DTLS handshake for given client address
pub fn acceptDtls(
    allocator: std.mem.Allocator,
    listen_socket: posix.socket_t,
    client_addr: net.Address,
    config: DtlsConfig,
) !*DtlsConnection {
    // Validate configuration
    try config.validate();

    // Server mode requires certificate and key
    if (config.cert_file == null or config.key_file == null) {
        return error.MissingServerCredentials;
    }

    // Check if DTLS is available at runtime
    if (!isDtlsAvailable()) {
        return error.DtlsNotAvailable;
    }

    // Use OpenSSL backend
    const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
    const dtls = try OpenSslDtls.initServer(allocator, listen_socket, client_addr, config);
    errdefer dtls.deinit();

    // Wrap in DtlsConnection interface
    const conn = try allocator.create(DtlsConnection);
    errdefer allocator.destroy(conn);

    conn.* = .{
        .allocator = allocator,
        .backend = .{ .dtls_openssl = dtls },
    };

    return conn;
}

/// Wrap existing UDP socket with DTLS (advanced usage)
/// Caller must have already created and connected UDP socket
pub fn wrapSocketDtls(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    peer_addr: net.Address,
    config: DtlsConfig,
    is_server: bool,
) !*DtlsConnection {
    // Validate configuration
    try config.validate();

    // Check if DTLS is available at runtime
    if (!isDtlsAvailable()) {
        return error.DtlsNotAvailable;
    }

    // Use OpenSSL backend
    const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
    const dtls = if (is_server)
        try OpenSslDtls.initServerWithSocket(allocator, socket, peer_addr, config)
    else
        try OpenSslDtls.initClientWithSocket(allocator, socket, peer_addr, config);
    errdefer dtls.deinit();

    // Wrap in DtlsConnection interface
    const conn = try allocator.create(DtlsConnection);
    errdefer allocator.destroy(conn);

    conn.* = .{
        .allocator = allocator,
        .backend = .{ .dtls_openssl = dtls },
    };

    return conn;
}

test "DTLS configuration validation" {
    const testing = std.testing;

    // Valid configuration
    const valid_config = DtlsConfig{
        .mtu = 1200,
        .min_version = .dtls_1_2,
        .max_version = .dtls_1_2,
    };
    try valid_config.validate();

    // Invalid MTU (too small)
    const invalid_mtu_small = DtlsConfig{
        .mtu = 100,
    };
    try testing.expectError(error.InvalidMtu, invalid_mtu_small.validate());

    // Invalid MTU (too large)
    const invalid_mtu_large = DtlsConfig{
        .mtu = 70000,
    };
    try testing.expectError(error.InvalidMtu, invalid_mtu_large.validate());

    // Invalid version range
    const invalid_version = DtlsConfig{
        .min_version = .dtls_1_3,
        .max_version = .dtls_1_2,
    };
    try testing.expectError(error.InvalidVersionRange, invalid_version.validate());
}

test "DTLS version comparison" {
    const testing = std.testing;

    try testing.expect(DtlsVersion.dtls_1_2.isAtLeast(.dtls_1_0));
    try testing.expect(DtlsVersion.dtls_1_3.isAtLeast(.dtls_1_2));
    try testing.expect(!DtlsVersion.dtls_1_0.isAtLeast(.dtls_1_2));
}
