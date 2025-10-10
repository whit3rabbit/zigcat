const std = @import("std");
const testing = std.testing;
const proxy_mod = @import("../src/net/proxy/mod.zig");
const http_connect = @import("../src/net/proxy/http_connect.zig");
const socks5 = @import("../src/net/proxy/socks5.zig");
const socks4 = @import("../src/net/proxy/socks4.zig");

test "parse proxy address - valid" {
    const allocator = testing.allocator;

    const result = try http_connect.parseProxyAddress(allocator, "localhost:8080");
    try testing.expectEqualStrings("localhost", result.host);
    try testing.expectEqual(@as(u16, 8080), result.port);

    const result2 = try http_connect.parseProxyAddress(allocator, "proxy.example.com:3128");
    try testing.expectEqualStrings("proxy.example.com", result2.host);
    try testing.expectEqual(@as(u16, 3128), result2.port);
}

test "parse proxy address - IPv6" {
    const allocator = testing.allocator;

    const result = try http_connect.parseProxyAddress(allocator, "[::1]:8080");
    try testing.expectEqualStrings("[::1]", result.host);
    try testing.expectEqual(@as(u16, 8080), result.port);
}

test "parse proxy address - invalid format" {
    const allocator = testing.allocator;

    const result = http_connect.parseProxyAddress(allocator, "invalid");
    try testing.expectError(error.InvalidProxyFormat, result);

    const result2 = http_connect.parseProxyAddress(allocator, "localhost:abc");
    try testing.expectError(error.InvalidCharacter, result2);
}

test "parse proxy auth - valid" {
    const allocator = testing.allocator;

    const result = try http_connect.parseProxyAuth(allocator, "user:pass");
    try testing.expectEqualStrings("user", result.username);
    try testing.expectEqualStrings("pass", result.password);

    const result2 = try http_connect.parseProxyAuth(allocator, "admin:secret123");
    try testing.expectEqualStrings("admin", result2.username);
    try testing.expectEqualStrings("secret123", result2.password);
}

test "parse proxy auth - with colon in password" {
    const allocator = testing.allocator;

    const result = try http_connect.parseProxyAuth(allocator, "user:pass:with:colons");
    try testing.expectEqualStrings("user", result.username);
    try testing.expectEqualStrings("pass:with:colons", result.password);
}

test "parse proxy auth - invalid format" {
    const allocator = testing.allocator;

    const result = http_connect.parseProxyAuth(allocator, "nocolon");
    try testing.expectError(error.InvalidAuthFormat, result);
}

// Integration tests (require actual proxy servers)
// These are commented out by default but can be enabled for manual testing

// test "HTTP CONNECT proxy connection" {
//     const allocator = testing.allocator;
//
//     // Start a local proxy: squid -N -f squid.conf
//     const sock = try http_connect.connect(
//         allocator,
//         "localhost",
//         3128,
//         "example.com",
//         80,
//         null,
//         5000,
//     );
//     defer std.posix.close(sock);
// }

// test "SOCKS5 proxy connection" {
//     const allocator = testing.allocator;
//
//     // Start SOCKS5 proxy: ssh -D 1080 user@host
//     const sock = try socks5.connect(
//         allocator,
//         "localhost",
//         1080,
//         "example.com",
//         80,
//         null,
//         5000,
//     );
//     defer std.posix.close(sock);
// }

// test "SOCKS5 with authentication" {
//     const allocator = testing.allocator;
//
//     const auth = http_connect.ProxyAuth{
//         .username = "user",
//         .password = "pass",
//     };
//
//     const sock = try socks5.connect(
//         allocator,
//         "localhost",
//         1080,
//         "example.com",
//         80,
//         auth,
//         5000,
//     );
//     defer std.posix.close(sock);
// }
