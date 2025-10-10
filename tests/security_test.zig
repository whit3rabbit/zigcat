const std = @import("std");
const allowlist = @import("../src/net/allowlist.zig");
const listen = @import("../src/server/listen.zig");

test "CIDR IPv4 matching - single IP in range" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    try access_list.addAllowRule("192.168.1.0/24");

    // Test IP in range
    const addr_in = std.net.Address.initIp4([_]u8{ 192, 168, 1, 5 }, 0);
    try std.testing.expect(access_list.isAllowed(addr_in));

    // Test IP out of range
    const addr_out = std.net.Address.initIp4([_]u8{ 192, 168, 2, 5 }, 0);
    try std.testing.expect(!access_list.isAllowed(addr_out));
}

test "CIDR IPv4 matching - edge cases" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    try access_list.addAllowRule("10.0.0.0/8");

    // First address in range
    const first = std.net.Address.initIp4([_]u8{ 10, 0, 0, 0 }, 0);
    try std.testing.expect(access_list.isAllowed(first));

    // Last address in range
    const last = std.net.Address.initIp4([_]u8{ 10, 255, 255, 255 }, 0);
    try std.testing.expect(access_list.isAllowed(last));

    // Just outside range
    const outside = std.net.Address.initIp4([_]u8{ 11, 0, 0, 0 }, 0);
    try std.testing.expect(!access_list.isAllowed(outside));
}

test "CIDR IPv6 matching - basic range" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    try access_list.addAllowRule("2001:db8::/32");

    // Test IP in range
    const addr_in = try std.net.Address.parseIp6("2001:db8::1", 0);
    try std.testing.expect(access_list.isAllowed(addr_in));

    // Test IP out of range
    const addr_out = try std.net.Address.parseIp6("2001:db9::1", 0);
    try std.testing.expect(!access_list.isAllowed(addr_out));
}

test "Deny takes precedence over allow" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Allow entire 192.168.0.0/16 network
    try access_list.addAllowRule("192.168.0.0/16");

    // But deny 192.168.1.0/24 subnet
    try access_list.addDenyRule("192.168.1.0/24");

    // Should be allowed (in 192.168.0.0/16 but not in denied subnet)
    const allowed = std.net.Address.initIp4([_]u8{ 192, 168, 2, 1 }, 0);
    try std.testing.expect(access_list.isAllowed(allowed));

    // Should be denied (in denied subnet)
    const denied = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    try std.testing.expect(!access_list.isAllowed(denied));
}

test "Empty allow list allows all (except denied)" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // No allow rules, but one deny rule
    try access_list.addDenyRule("10.0.0.0/8");

    // Should be allowed (not in deny list, allow list empty)
    const allowed = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    try std.testing.expect(access_list.isAllowed(allowed));

    // Should be denied
    const denied = std.net.Address.initIp4([_]u8{ 10, 0, 0, 1 }, 0);
    try std.testing.expect(!access_list.isAllowed(denied));
}

test "Single IP allow/deny" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    try access_list.addAllowRule("192.168.1.100");

    // Exact IP should be allowed
    const exact = std.net.Address.initIp4([_]u8{ 192, 168, 1, 100 }, 0);
    try std.testing.expect(access_list.isAllowed(exact));

    // Different IP should be denied
    const different = std.net.Address.initIp4([_]u8{ 192, 168, 1, 101 }, 0);
    try std.testing.expect(!access_list.isAllowed(different));
}

test "Multiple overlapping CIDR ranges" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Allow broad range
    try access_list.addAllowRule("10.0.0.0/8");
    // Allow narrower range (redundant but valid)
    try access_list.addAllowRule("10.1.0.0/16");

    // Should be allowed by first rule
    const addr1 = std.net.Address.initIp4([_]u8{ 10, 2, 3, 4 }, 0);
    try std.testing.expect(access_list.isAllowed(addr1));

    // Should be allowed by both rules
    const addr2 = std.net.Address.initIp4([_]u8{ 10, 1, 2, 3 }, 0);
    try std.testing.expect(access_list.isAllowed(addr2));
}

test "Integration test - unauthorized connection rejected" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Only allow localhost
    try access_list.addAllowRule("127.0.0.1");

    // Simulate connection from localhost - should be allowed
    const localhost = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    try std.testing.expect(access_list.isAllowed(localhost));

    // Simulate connection from external IP - should be denied
    const external = std.net.Address.initIp4([_]u8{ 8, 8, 8, 8 }, 0);
    try std.testing.expect(!access_list.isAllowed(external));
}

test "IPv6 link-local addresses" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Allow link-local addresses (fe80::/10)
    try access_list.addAllowRule("fe80::/10");

    const link_local = try std.net.Address.parseIp6("fe80::1", 0);
    try std.testing.expect(access_list.isAllowed(link_local));

    const global = try std.net.Address.parseIp6("2001:db8::1", 0);
    try std.testing.expect(!access_list.isAllowed(global));
}

test "Deny all with 0.0.0.0/0" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Deny everything
    try access_list.addDenyRule("0.0.0.0/0");

    // Even with allow rules, deny should take precedence
    try access_list.addAllowRule("192.168.1.0/24");

    const addr = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    try std.testing.expect(!access_list.isAllowed(addr));
}

test "Complex access control scenario" {
    const allocator = std.testing.allocator;
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Allow private networks
    try access_list.addAllowRule("192.168.0.0/16");
    try access_list.addAllowRule("10.0.0.0/8");
    try access_list.addAllowRule("172.16.0.0/12");

    // Deny specific problematic subnet
    try access_list.addDenyRule("192.168.13.0/24");

    // Allowed: private network, not in denied subnet
    const allowed1 = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    try std.testing.expect(access_list.isAllowed(allowed1));

    const allowed2 = std.net.Address.initIp4([_]u8{ 10, 1, 1, 1 }, 0);
    try std.testing.expect(access_list.isAllowed(allowed2));

    // Denied: in problematic subnet
    const denied = std.net.Address.initIp4([_]u8{ 192, 168, 13, 100 }, 0);
    try std.testing.expect(!access_list.isAllowed(denied));

    // Denied: not in allow list
    const denied2 = std.net.Address.initIp4([_]u8{ 8, 8, 8, 8 }, 0);
    try std.testing.expect(!access_list.isAllowed(denied2));
}
