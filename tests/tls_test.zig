const std = @import("std");
const testing = std.testing;
const tls = @import("../src/tls/tls.zig");
const TlsConfig = tls.TlsConfig;
const TlsVersion = tls.TlsVersion;
const build_options = @import("build_options");

test "TLS configuration initialization" {
    const config = TlsConfig{
        .server_name = "example.com",
        .verify_peer = true,
        .min_version = .tls_1_2,
        .max_version = .tls_1_3,
    };

    try testing.expect(config.verify_peer == true);
    try testing.expectEqualStrings("example.com", config.server_name.?);
    try testing.expect(config.min_version == .tls_1_2);
    try testing.expect(config.max_version == .tls_1_3);
}

test "TLS version ordering" {
    const v10 = TlsVersion.tls_1_0;
    const v11 = TlsVersion.tls_1_1;
    const v12 = TlsVersion.tls_1_2;
    const v13 = TlsVersion.tls_1_3;

    try testing.expect(@intFromEnum(v10) < @intFromEnum(v11));
    try testing.expect(@intFromEnum(v11) < @intFromEnum(v12));
    try testing.expect(@intFromEnum(v12) < @intFromEnum(v13));
}

test "TLS enabled check" {
    const enabled = tls.isTlsEnabled();
    if (build_options.enable_tls) {
        try testing.expect(enabled == true);
    } else {
        try testing.expect(enabled == false);
    }
}

test "TLS config with SNI" {
    const config = TlsConfig{
        .server_name = "secure.example.com",
        .verify_peer = true,
    };

    try testing.expect(config.server_name != null);
    try testing.expectEqualStrings("secure.example.com", config.server_name.?);
}

test "TLS config with custom cipher suites" {
    const config = TlsConfig{
        .cipher_suites = "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
        .min_version = .tls_1_3,
    };

    try testing.expect(config.cipher_suites != null);
    try testing.expect(config.min_version == .tls_1_3);
}

test "TLS config server mode" {
    const config = TlsConfig{
        .cert_file = "/path/to/cert.pem",
        .key_file = "/path/to/key.pem",
        .verify_peer = false,
    };

    try testing.expect(config.cert_file != null);
    try testing.expect(config.key_file != null);
    try testing.expectEqualStrings("/path/to/cert.pem", config.cert_file.?);
    try testing.expectEqualStrings("/path/to/key.pem", config.key_file.?);
}

test "TLS config with ALPN" {
    const config = TlsConfig{
        .alpn_protocols = "h2,http/1.1",
        .server_name = "api.example.com",
    };

    try testing.expect(config.alpn_protocols != null);
    try testing.expectEqualStrings("h2,http/1.1", config.alpn_protocols.?);
}

test "TLS config trust store" {
    const config = TlsConfig{
        .trust_file = "/etc/ssl/certs/ca-certificates.crt",
        .verify_peer = true,
    };

    try testing.expect(config.trust_file != null);
    try testing.expect(config.verify_peer);
}

// Integration test placeholder - would need actual server
test "TLS handshake mock" {
    if (!build_options.enable_tls) {
        return error.SkipZigTest;
    }

    // This would require a mock TLS server or integration with openssl s_client
    // For now, just verify the interface compiles
    const config = TlsConfig{
        .server_name = "localhost",
        .verify_peer = false,
    };

    try testing.expect(config.server_name != null);
}
