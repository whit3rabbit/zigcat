// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


// DTLS connection interface
// Provides abstract interface for DTLS connections with multiple backend support

const std = @import("std");
const posix = std.posix;
const net = std.net;

/// DTLS protocol version
pub const DtlsVersion = enum {
    dtls_1_0, // DTLS 1.0 (based on TLS 1.1)
    dtls_1_2, // DTLS 1.2 (based on TLS 1.2)
    dtls_1_3, // DTLS 1.3 (based on TLS 1.3, OpenSSL 3.2+)

    /// Get minimum OpenSSL version required for this DTLS version
    pub fn minOpenSslVersion(self: DtlsVersion) u32 {
        return switch (self) {
            .dtls_1_0, .dtls_1_2 => 0x1000200f, // OpenSSL 1.0.2
            .dtls_1_3 => 0x30200000, // OpenSSL 3.2.0
        };
    }

    /// Check if this version is at least the specified version
    pub fn isAtLeast(self: DtlsVersion, other: DtlsVersion) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    /// Check if this is a DTLS version (always true for this enum)
    pub fn isDtls(self: DtlsVersion) bool {
        _ = self;
        return true;
    }
};

/// DTLS connection configuration
pub const DtlsConfig = struct {
    // Certificate and key files
    cert_file: ?[]const u8 = null, // Server certificate (PEM)
    key_file: ?[]const u8 = null, // Private key (PEM)

    // Peer verification
    verify_peer: bool = true, // Verify peer certificate
    trust_file: ?[]const u8 = null, // CA bundle for verification
    crl_file: ?[]const u8 = null, // Certificate revocation list
    server_name: ?[]const u8 = null, // Expected server hostname (SNI)

    // Protocol configuration
    alpn_protocols: ?[]const u8 = null, // ALPN protocol list
    cipher_suites: ?[]const u8 = null, // Allowed cipher suites
    min_version: DtlsVersion = .dtls_1_2, // Minimum DTLS version
    max_version: DtlsVersion = .dtls_1_2, // Maximum DTLS version (1.3 requires OpenSSL 3.2+)

    // DTLS-specific configuration
    mtu: u16 = 1200, // Path MTU (conservative default to avoid fragmentation)
    initial_timeout_ms: u32 = 1000, // Initial retransmission timeout
    cookie_secret: ?[]const u8 = null, // Server cookie secret (auto-generated if null)
    replay_window: u32 = 64, // Anti-replay window size

    /// Validate configuration
    pub fn validate(self: DtlsConfig) !void {
        // Version validation
        if (!self.min_version.isAtLeast(self.max_version) and
            @intFromEnum(self.min_version) > @intFromEnum(self.max_version))
        {
            return error.InvalidVersionRange;
        }

        // MTU validation (RFC 6347: minimum 296 bytes, practical max 65507)
        if (self.mtu < 296 or self.mtu > 65507) {
            return error.InvalidMtu;
        }

        // Server mode validation
        if (self.cert_file != null and self.key_file == null) {
            return error.MissingPrivateKey;
        }
        if (self.key_file != null and self.cert_file == null) {
            return error.MissingCertificate;
        }
    }
};

/// DTLS connection state
pub const DtlsState = enum {
    initial, // Connection created, not yet started
    cookie_exchange, // Server: waiting for client cookie
    handshake, // Performing DTLS handshake
    connected, // Handshake complete, ready for data
    closing, // Shutdown initiated
    closed, // Connection closed
};

/// DTLS connection statistics
pub const DtlsStats = struct {
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    datagrams_sent: u64 = 0,
    datagrams_received: u64 = 0,
    retransmissions: u64 = 0,
    handshake_time_ms: u64 = 0,
};

/// Backend-agnostic DTLS connection interface
pub const DtlsConnection = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    pub const Backend = union(enum) {
        dtls_openssl: *anyopaque, // Will be *OpenSslDtls when implemented
        disabled: void,
    };

    /// Read decrypted data from DTLS connection
    /// Returns number of bytes read, preserves datagram boundaries
    pub fn read(self: *DtlsConnection, buffer: []u8) !usize {
        return switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                return dtls.read(buffer);
            },
            .disabled => error.DtlsNotAvailable,
        };
    }

    /// Write data to DTLS connection (encrypts and sends as datagram)
    /// Each write creates one DTLS record (atomic datagram)
    pub fn write(self: *DtlsConnection, data: []const u8) !usize {
        return switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                return dtls.write(data);
            },
            .disabled => error.DtlsNotAvailable,
        };
    }

    /// Close DTLS connection gracefully (sends close_notify)
    pub fn close(self: *DtlsConnection) void {
        switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                dtls.close();
            },
            .disabled => {},
        }
    }

    /// Free all resources
    pub fn deinit(self: *DtlsConnection) void {
        switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                dtls.deinit();
            },
            .disabled => {},
        }
        self.allocator.destroy(self);
    }

    /// Get underlying UDP socket
    pub fn getSocket(self: *DtlsConnection) posix.socket_t {
        return switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                return dtls.socket;
            },
            .disabled => @as(posix.socket_t, 0),
        };
    }

    /// Get current connection state
    pub fn getState(self: *DtlsConnection) DtlsState {
        return switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                return dtls.state;
            },
            .disabled => .closed,
        };
    }

    /// Get connection statistics
    pub fn getStats(self: *DtlsConnection) DtlsStats {
        return switch (self.backend) {
            .dtls_openssl => |ptr| {
                const OpenSslDtls = @import("dtls_openssl.zig").OpenSslDtls;
                const dtls = @as(*OpenSslDtls, @ptrCast(@alignCast(ptr)));
                return dtls.stats;
            },
            .disabled => .{},
        };
    }
};

// ============================================================================
// Unit Tests (run via: zig build test)
// ============================================================================

const testing = std.testing;

test "DTLS: Valid configuration with defaults" {
    const config = DtlsConfig{};
    try config.validate();
}

test "DTLS: Invalid MTU - too small" {
    const config = DtlsConfig{
        .mtu = 200, // Minimum is 296
    };
    try testing.expectError(error.InvalidMtu, config.validate());
}

test "DTLS: Invalid version range - min > max" {
    const config = DtlsConfig{
        .min_version = .dtls_1_3,
        .max_version = .dtls_1_2,
    };
    try testing.expectError(error.InvalidVersionRange, config.validate());
}

test "DTLS: Version comparison" {
    try testing.expect(DtlsVersion.dtls_1_2.isAtLeast(.dtls_1_0));
    try testing.expect(!DtlsVersion.dtls_1_0.isAtLeast(.dtls_1_2));
}

test "DTLS: Version isDtls()" {
    try testing.expect(DtlsVersion.dtls_1_2.isDtls());
}

test "DTLS: State enum" {
    const state: DtlsState = .initial;
    try testing.expectEqual(DtlsState.initial, state);
}

test "DTLS: Stats initialization" {
    const stats = DtlsStats{};
    try testing.expectEqual(@as(u64, 0), stats.bytes_sent);
}
