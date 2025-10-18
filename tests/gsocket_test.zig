const std = @import("std");
const testing = std.testing;
const zigcat = @import("zigcat");
const gsocket = zigcat.gsocket;
const srp_openssl = zigcat.srp_openssl;
const build_options = zigcat.build_options;

// ============================================================================
// Secret Derivation Tests (already covered in gsocket.zig, but duplicated here for integration context)
// ============================================================================

test "gsocket secret derivation - deterministic" {
    const secret = "integration_test_secret";

    const addr1 = gsocket.deriveAddress(secret);
    const addr2 = gsocket.deriveAddress(secret);
    const pass1 = gsocket.deriveSrpPassword(secret);
    const pass2 = gsocket.deriveSrpPassword(secret);

    // Same secret must always produce same address and password
    try testing.expectEqualSlices(u8, &addr1, &addr2);
    try testing.expectEqualSlices(u8, &pass1, &pass2);
}

test "gsocket secret derivation - different secrets" {
    const secret1 = "secret_client";
    const secret2 = "secret_server";

    const addr1 = gsocket.deriveAddress(secret1);
    const addr2 = gsocket.deriveAddress(secret2);
    const pass1 = gsocket.deriveSrpPassword(secret1);
    const pass2 = gsocket.deriveSrpPassword(secret2);

    // Different secrets must produce different addresses and passwords
    try testing.expect(!std.mem.eql(u8, &addr1, &addr2));
    try testing.expect(!std.mem.eql(u8, &pass1, &pass2));
}

test "gsocket SRP password format validation" {
    const secret = "test_format";
    const pass = gsocket.deriveSrpPassword(secret);

    // Validate password is exactly 33 bytes (32 hex chars + null)
    try testing.expectEqual(@as(usize, 33), pass.len);

    // Validate null terminator
    try testing.expectEqual(@as(u8, 0), pass[32]);

    // Validate all characters are lowercase hex
    for (pass[0..32]) |char| {
        const is_hex = (char >= '0' and char <= '9') or
            (char >= 'a' and char <= 'f');
        try testing.expect(is_hex);
    }
}

// ============================================================================
// SRP Connection Interface Tests
// ============================================================================

test "SRP connection initialization structure" {
    if (!build_options.enable_tls) {
        return error.SkipZigTest;
    }

    // Verify SrpConnection compiles and has expected fields
    const conn = srp_openssl.SrpConnection{
        .allocator = testing.allocator,
        .stream = undefined,
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
        .srp_client_ctx = null,
        .srp_server_ctx = null,
    };

    try testing.expectEqual(srp_openssl.SrpConnection.ConnectionState.initial, conn.state);
    try testing.expect(conn.is_client);
    try testing.expectEqual(@as(?*srp_openssl.c.SSL_CTX, null), conn.ssl_ctx);
    try testing.expectEqual(@as(?*srp_openssl.c.SSL, null), conn.ssl);
}

test "SRP error handling - invalid state" {
    if (!build_options.enable_tls) {
        return error.SkipZigTest;
    }

    var conn = srp_openssl.SrpConnection{
        .allocator = testing.allocator,
        .stream = undefined,
        .ssl_ctx = null,
        .ssl = null,
        .state = .closed,
        .is_client = true,
        .srp_client_ctx = null,
        .srp_server_ctx = null,
    };

    var buffer: [1024]u8 = undefined;

    // Reading from a closed connection should return InvalidState
    const read_result = conn.read(&buffer);
    try testing.expectError(srp_openssl.SrpError.InvalidState, read_result);

    // Writing to a closed connection should return InvalidState
    const write_result = conn.write("test data");
    try testing.expectError(srp_openssl.SrpError.InvalidState, write_result);
}

test "gsocket packet structure sizes" {
    // Verify packet structures have correct sizes for wire protocol
    try testing.expectEqual(128, @sizeOf(gsocket.GsListen));
    try testing.expectEqual(128, @sizeOf(gsocket.GsConnect));
    try testing.expectEqual(32, @sizeOf(gsocket.GsStart));
}

test "gsocket protocol constants" {
    // Verify protocol constants match gsocket specification
    try testing.expectEqual(@as(u8, 0x01), gsocket.GS_PKT_TYPE_LISTEN);
    try testing.expectEqual(@as(u8, 0x02), gsocket.GS_PKT_TYPE_CONNECT);
    try testing.expectEqual(@as(u8, 0x05), gsocket.GS_PKT_TYPE_START);

    try testing.expectEqual(@as(u8, 1), gsocket.GS_PKT_PROTO_VERSION_MAJOR);
    try testing.expectEqual(@as(u8, 3), gsocket.GS_PKT_PROTO_VERSION_MINOR);
}

test "gsocket GsListen packet initialization" {
    const test_addr: gsocket.GsAddress = gsocket.deriveAddress("test_listen");

    const pkt = gsocket.GsListen{ .addr = test_addr };

    try testing.expectEqual(gsocket.GS_PKT_TYPE_LISTEN, pkt.type);
    try testing.expectEqual(gsocket.GS_PKT_PROTO_VERSION_MAJOR, pkt.version_major);
    try testing.expectEqual(gsocket.GS_PKT_PROTO_VERSION_MINOR, pkt.version_minor);
    try testing.expectEqual(gsocket.GS_FL_PROTO_LOW_LATENCY, pkt.flags);
    try testing.expectEqualSlices(u8, &test_addr, &pkt.addr);
}

test "gsocket GsConnect packet initialization" {
    const test_addr: gsocket.GsAddress = gsocket.deriveAddress("test_connect");

    const pkt = gsocket.GsConnect{ .addr = test_addr };

    try testing.expectEqual(gsocket.GS_PKT_TYPE_CONNECT, pkt.type);
    try testing.expectEqual(gsocket.GS_PKT_PROTO_VERSION_MAJOR, pkt.version_major);
    try testing.expectEqual(gsocket.GS_PKT_PROTO_VERSION_MINOR, pkt.version_minor);
    try testing.expectEqual(gsocket.GS_FL_PROTO_LOW_LATENCY, pkt.flags);
    try testing.expectEqualSlices(u8, &test_addr, &pkt.addr);
}

// ============================================================================
// Integration Test Placeholders
// ============================================================================

test "gsocket full handshake mock - client role" {
    if (!build_options.enable_tls) {
        return error.SkipZigTest;
    }

    // This would require a real GSRN relay or mock server
    // For now, verify the client initialization interface compiles
    const secret = "integration_test_client";
    const addr = gsocket.deriveAddress(secret);
    const pass = gsocket.deriveSrpPassword(secret);

    try testing.expectEqual(@as(usize, 16), addr.len);
    try testing.expectEqual(@as(usize, 33), pass.len);
    try testing.expectEqual(@as(u8, 0), pass[32]);
}

test "gsocket full handshake mock - server role" {
    if (!build_options.enable_tls) {
        return error.SkipZigTest;
    }

    // This would require a real GSRN relay or mock server
    // For now, verify the server initialization interface compiles
    const secret = "integration_test_server";
    const addr = gsocket.deriveAddress(secret);
    const pass = gsocket.deriveSrpPassword(secret);

    try testing.expectEqual(@as(usize, 16), addr.len);
    try testing.expectEqual(@as(usize, 33), pass.len);
    try testing.expectEqual(@as(u8, 0), pass[32]);
}

test "gsocket secret mismatch detection" {
    // Verify that different secrets produce different addresses
    // (ensuring connection will fail if secrets don't match)
    const server_secret = "correct_secret";
    const client_secret = "wrong_secret";

    const server_addr = gsocket.deriveAddress(server_secret);
    const client_addr = gsocket.deriveAddress(client_secret);

    // Different secrets should produce different addresses
    // This ensures GSRN relay won't match peers with wrong secrets
    try testing.expect(!std.mem.eql(u8, &server_addr, &client_addr));
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "gsocket default configuration" {
    // Verify default GSRN relay settings
    try testing.expectEqualStrings("gs.thc.org", gsocket.GSRN_DEFAULT_HOST);
    try testing.expectEqual(@as(u16, 443), gsocket.GSRN_DEFAULT_PORT);
}
