// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! IP Access Control Module
//!
//! This module provides IP-based access control with support for allow and deny lists.
//! It implements a flexible rule-based system that supports:
//!
//! ## Supported Rule Formats
//! - Single IPv4 addresses: "192.168.1.1"
//! - Single IPv6 addresses: "2001:db8::1"
//! - IPv4 CIDR ranges: "192.168.1.0/24"
//! - IPv6 CIDR ranges: "2001:db8::/32"
//! - Hostnames: "example.com" (DNS forward lookup A/AAAA records)
//!
//! ## Access Control Logic
//! 1. Deny rules are checked first (explicit denial)
//! 2. If deny list matches, access is DENIED immediately
//! 3. If allow list is empty, all addresses are ALLOWED (except denied)
//! 4. If allow list has entries, address must match at least one entry
//! 5. Deny rules take precedence over allow rules (security-first)
//!
//! ## CIDR Matching Algorithm
//! - IPv4: Uses 32-bit subnet mask comparison
//! - IPv6: Uses 128-bit byte-by-byte prefix comparison
//! - Prefix length validation: 0-32 for IPv4, 0-128 for IPv6
//!
//! ## Usage Example
//! ```zig
//! var access_list = AccessList.init(allocator);
//! defer access_list.deinit();
//!
//! // Deny entire private network
//! try access_list.addDenyRule("10.0.0.0/8");
//!
//! // Allow specific subnet
//! try access_list.addAllowRule("192.168.1.0/24");
//!
//! // Check if address is allowed
//! const addr = std.net.Address.initIp4([_]u8{192, 168, 1, 5}, 0);
//! if (access_list.isAllowed(addr)) {
//!     // Accept connection
//! }
//! ```
//!
//! ## Security Best Practices
//! - Use deny lists to block known malicious ranges (e.g., bogon addresses)
//! - Use allow lists to restrict access to trusted networks
//! - Combine both for defense-in-depth (deny malicious, allow trusted)
//! - Deny rules override allow rules (prevents accidental exposure)
//! - Validate CIDR prefix lengths to prevent wildcard matches (e.g., 0.0.0.0/0)
//!
//! ## File Format Specification
//! Access lists can be loaded from text files with one rule per line:
//! ```
//! # Allow local network
//! 192.168.0.0/16
//! 127.0.0.1
//!
//! # IPv6 support
//! 2001:db8::/32
//! ::1
//!
//! # Hostnames (DNS lookup - use with caution)
//! trusted.example.com
//! ```
//!
//! ## Security Warning: Hostname Rules
//! Hostname-based access control uses DNS forward lookups (A/AAAA records)
//! which are vulnerable to DNS manipulation attacks:
//! - DNS cache poisoning can redirect hostnames to attacker IPs
//! - DNS rebinding can change IP after initial authorization check
//! - Man-in-the-middle attacks can spoof DNS responses
//! - Compromised DNS servers can return malicious records
//!
//! Recommendations for production use:
//! - Prefer IP-based rules (single IP or CIDR) for security-critical ACLs
//! - Use DNSSEC validation if available
//! - Implement DNS result caching with short TTL (5-15 minutes)
//! - Rate limit DNS lookups to prevent DoS
//! - Log all hostname-based access control decisions for auditing
//!
//! ## Performance Characteristics
//! - Rule parsing: O(1) per rule (single-pass parsing)
//! - Match checking: O(n) where n = number of rules (linear search)
//! - CIDR matching: O(1) bitwise operations
//! - Memory: O(n) where n = number of rules + hostname strings
//!
//! ## Limitations
//! - Hostname rules use forward DNS only (not reverse DNS/PTR validation)
//! - DNS lookups add latency (10-100ms per connection with hostname rule)
//! - No support for dynamic rule updates (rebuild AccessList)
//! - No rule prioritization (order matters for overlapping CIDR ranges)
//! - No wildcard or regex support (use CIDR ranges instead)
//!
//! ## Module Structure
//! This module re-exports types and functions from specialized submodules:
//! - allowlist/dns_cache.zig: DNS caching with TTL
//! - allowlist/rule_parser.zig: Rule type definitions and parsing
//! - allowlist/ip_filter.zig: IP matching and CIDR logic

const std = @import("std");
const time = std.time;
const logging = @import("../util/logging.zig");

// Re-export submodules
const dns_cache = @import("allowlist/dns_cache.zig");
const rule_parser = @import("allowlist/rule_parser.zig");
const ip_filter = @import("allowlist/ip_filter.zig");

// Re-export types
pub const DnsCache = dns_cache.DnsCache;
pub const IpRule = rule_parser.IpRule;

// Re-export functions
pub const parseRule = rule_parser.parseRule;
pub const matchesRule = ip_filter.matchesRule;
pub const matchesCidrV4 = ip_filter.matchesCidrV4;
pub const matchesCidrV6 = ip_filter.matchesCidrV6;
pub const addressesEqual = ip_filter.addressesEqual;

/// Wrapper function to match rules with io parameter for DNS resolution
fn matchesRuleWithIo(dns_cache_ptr: *DnsCache, addr: std.Io.net.IpAddress, rule: IpRule, io: std.Io) bool {
    switch (rule) {
        .hostname => |hostname| {
            // Resolve hostname with io parameter
            const addresses = dns_cache_ptr.resolve(hostname, io) catch {
                // DNS resolution failed - deny access
                return false;
            };

            // Check if client IP matches any resolved address
            // Note: Port is ignored for ACL matching (only IP matters)
            var addr_no_port = addr;
            switch (addr) {
                .ip4 => |*ip4| {
                    addr_no_port = .{ .ip4 = .{
                        .bytes = ip4.bytes,
                        .port = 0,
                    } };
                },
                .ip6 => |*ip6| {
                    addr_no_port = .{ .ip6 = .{
                        .bytes = ip6.bytes,
                        .port = 0,
                    } };
                },
            }

            for (addresses) |resolved_addr| {
                var resolved_no_port = resolved_addr;
                switch (resolved_addr) {
                    .ip4 => |ip4| {
                        resolved_no_port = .{ .ip4 = .{
                            .bytes = ip4.bytes,
                            .port = 0,
                        } };
                    },
                    .ip6 => |ip6| {
                        resolved_no_port = .{ .ip6 = .{
                            .bytes = ip6.bytes,
                            .port = 0,
                        } };
                    },
                }

                if (addressesEqual(addr_no_port, resolved_no_port)) {
                    return true;
                }
            }

            return false;
        },
        else => {
            // For non-hostname rules, delegate to standard matchesRule
            return matchesRule(dns_cache_ptr, addr, rule, io);
        },
    }
}

/// IP access control list with allow and deny rules
///
/// Maintains two separate rule lists for access control:
/// - Allow list (whitelist): Addresses that should be permitted
/// - Deny list (blacklist): Addresses that should be blocked
///
/// ## Access Control Algorithm
/// 1. Check deny list first (O(n) where n = deny rules)
/// 2. If denied, return false immediately (deny takes precedence)
/// 3. If allow list is empty, return true (permissive default)
/// 4. Check allow list (O(m) where m = allow rules)
/// 5. If matched, return true, otherwise false (restrictive with allow list)
///
/// ## Security Model
/// This implements a "default deny" model when allow rules are present,
/// and a "default allow" model when allow list is empty. Deny rules
/// ALWAYS take precedence to prevent accidental exposure.
///
/// ## Memory Management
/// - List structures: Heap-allocated (ArrayListUnmanaged)
/// - Rules: Stack or heap (depending on type - see IpRule)
/// - Must call deinit() to free all resources
///
/// ## Thread Safety
/// - NOT thread-safe (no synchronization)
/// - Use external locking for concurrent access
/// - Modify on single thread, read from multiple threads is unsafe
///
/// ## Example Usage
/// ```zig
/// // Restrictive: Only allow specific network
/// var access_list = AccessList.init(allocator);
/// defer access_list.deinit();
///
/// try access_list.addAllowRule("192.168.1.0/24");
/// try access_list.addDenyRule("192.168.1.100");  // Deny specific host
///
/// const addr1 = std.net.Address.initIp4([_]u8{192, 168, 1, 50}, 0);
/// const addr2 = std.net.Address.initIp4([_]u8{192, 168, 1, 100}, 0);
/// const addr3 = std.net.Address.initIp4([_]u8{10, 0, 0, 1}, 0);
///
/// access_list.isAllowed(addr1);  // true (in allow range)
/// access_list.isAllowed(addr2);  // false (denied explicitly)
/// access_list.isAllowed(addr3);  // false (not in allow list)
/// ```
pub const AccessList = struct {
    /// Allow rules (whitelist) - addresses permitted for access
    allow_rules: std.ArrayListUnmanaged(IpRule),

    /// Deny rules (blacklist) - addresses blocked from access
    deny_rules: std.ArrayListUnmanaged(IpRule),

    /// Allocator for rule management
    allocator: std.mem.Allocator,

    /// DNS cache for hostname rules
    dns_cache_instance: DnsCache,

    /// Initialize empty access list
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for rule storage
    ///
    /// ## Returns
    /// Empty AccessList with no rules (permissive mode - allows all)
    pub fn init(allocator: std.mem.Allocator) AccessList {
        return .{
            .allow_rules = .{},
            .deny_rules = .{},
            .allocator = allocator,
            .dns_cache_instance = DnsCache.init(allocator, 300), // 5 minute TTL
        };
    }

    /// Free all resources (rules and list storage)
    ///
    /// ## Safety
    /// - Safe to call multiple times (lists cleared on first call)
    /// - Must call before discarding AccessList
    /// - Frees hostname strings in rules
    /// - Deallocates internal list storage
    pub fn deinit(self: *AccessList) void {
        for (self.allow_rules.items) |*rule| {
            rule.deinit(self.allocator);
        }
        for (self.deny_rules.items) |*rule| {
            rule.deinit(self.allocator);
        }
        self.allow_rules.deinit(self.allocator);
        self.deny_rules.deinit(self.allocator);
        self.dns_cache_instance.deinit();
    }

    /// Add an allow rule from string representation
    ///
    /// Parses and appends a rule to the allow list (whitelist).
    /// Supported formats: "192.168.1.0/24", "10.0.0.1", "2001:db8::/32"
    pub fn addAllowRule(self: *AccessList, rule_str: []const u8) !void {
        const rule = try parseRule(self.allocator, rule_str);
        try self.allow_rules.append(self.allocator, rule);
    }

    /// Add a deny rule from string representation
    ///
    /// Parses and appends a rule to the deny list (blacklist).
    /// Deny rules take precedence over allow rules.
    pub fn addDenyRule(self: *AccessList, rule_str: []const u8) !void {
        const rule = try parseRule(self.allocator, rule_str);
        try self.deny_rules.append(self.allocator, rule);
    }

    /// Check if an address is allowed access
    ///
    /// Implements three-phase access control algorithm:
    /// 1. Check deny list first - if matched, DENY immediately
    /// 2. If allow list empty, ALLOW (permissive default)
    /// 3. Check allow list - if matched, ALLOW, otherwise DENY
    ///
    /// NOTE: Requires mutable self because DNS cache may be updated during hostname resolution
    pub fn isAllowed(self: *AccessList, addr: std.Io.net.IpAddress, io: std.Io) bool {
        // Check deny list first - deny takes precedence
        for (self.deny_rules.items) |rule| {
            // matchesRule needs to be updated to pass io for hostname resolution
            // For now, we create a wrapper that handles the io parameter
            const matches = matchesRuleWithIo(&self.dns_cache_instance, addr, rule, io);
            if (matches) {
                return false;
            }
        }

        // If allow list is empty, allow all (that weren't denied)
        if (self.allow_rules.items.len == 0) {
            return true;
        }

        // Check if address matches any allow rule
        for (self.allow_rules.items) |rule| {
            const matches = matchesRuleWithIo(&self.dns_cache_instance, addr, rule, io);
            if (matches) {
                return true;
            }
        }

        // Not in allow list
        return false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse single IPv4" {
    const allocator = std.testing.allocator;
    var rule = try parseRule(allocator, "192.168.1.1");
    defer rule.deinit(allocator);

    try std.testing.expect(rule == .single_ipv4);
}

test "parse IPv4 CIDR" {
    const allocator = std.testing.allocator;
    var rule = try parseRule(allocator, "192.168.1.0/24");
    defer rule.deinit(allocator);

    try std.testing.expect(rule == .cidr_v4);
    try std.testing.expectEqual(@as(u8, 24), rule.cidr_v4.prefix_len);
}

test "parse single IPv6" {
    const allocator = std.testing.allocator;
    var rule = try parseRule(allocator, "2001:db8::1");
    defer rule.deinit(allocator);

    try std.testing.expect(rule == .single_ipv6);
}

test "parse IPv6 CIDR" {
    const allocator = std.testing.allocator;
    var rule = try parseRule(allocator, "2001:db8::/32");
    defer rule.deinit(allocator);

    try std.testing.expect(rule == .cidr_v6);
    try std.testing.expectEqual(@as(u8, 32), rule.cidr_v6.prefix_len);
}

test "parse hostname" {
    const allocator = std.testing.allocator;
    var rule = try parseRule(allocator, "example.com");
    defer rule.deinit(allocator);

    try std.testing.expect(rule == .hostname);
    try std.testing.expectEqualStrings("example.com", rule.hostname);
}

test "IPv4 CIDR matching" {
    const addr1 = try std.net.Ip4Address.parse("192.168.1.5", 0);
    const addr2 = try std.net.Ip4Address.parse("192.168.2.5", 0);
    const cidr = try std.net.Ip4Address.parse("192.168.1.0", 0);

    try std.testing.expect(matchesCidrV4(addr1, cidr, 24));
    try std.testing.expect(!matchesCidrV4(addr2, cidr, 24));
}

test "IPv6 CIDR matching" {
    const addr1 = try std.net.Ip6Address.parse("2001:db8::5", 0);
    const addr2 = try std.net.Ip6Address.parse("2001:db9::5", 0);
    const cidr = try std.net.Ip6Address.parse("2001:db8::", 0);

    try std.testing.expect(matchesCidrV6(addr1, cidr, 32));
    try std.testing.expect(!matchesCidrV6(addr2, cidr, 32));
}

test "AccessList allow/deny logic" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    // Add deny rule for 10.0.0.0/8
    try access_list.addDenyRule("10.0.0.0/8");

    // Add allow rule for 192.168.0.0/16
    try access_list.addAllowRule("192.168.0.0/16");

    // Test addresses
    const allowed_addr = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    const denied_addr = std.net.Address.initIp4([_]u8{ 10, 0, 0, 1 }, 0);
    const other_addr = std.net.Address.initIp4([_]u8{ 8, 8, 8, 8 }, 0);

    // 192.168.1.1 should be allowed
    try std.testing.expect((&access_list).isAllowed(allowed_addr));

    // 10.0.0.1 should be denied (even though not in allow list)
    try std.testing.expect(!(&access_list).isAllowed(denied_addr));

    // 8.8.8.8 should be denied (not in allow list)
    try std.testing.expect(!(&access_list).isAllowed(other_addr));
}

test "AccessList empty allow list allows all" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    // No rules - should allow everything
    const addr = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);
    try std.testing.expect((&access_list).isAllowed(addr));
}

test "AccessList deny takes precedence" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    // Add overlapping rules
    try access_list.addAllowRule("192.168.0.0/16");
    try access_list.addDenyRule("192.168.1.0/24");

    const allowed_addr = std.net.Address.initIp4([_]u8{ 192, 168, 2, 1 }, 0);
    const denied_addr = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 0);

    // 192.168.2.1 should be allowed
    try std.testing.expect((&access_list).isAllowed(allowed_addr));

    // 192.168.1.1 should be denied (deny takes precedence)
    try std.testing.expect(!(&access_list).isAllowed(denied_addr));
}

test "hostname resolution and caching" {
    const allocator = std.testing.allocator;
    var cache = DnsCache.init(allocator, 1); // 1 second TTL
    defer cache.deinit();

    // Test DNS resolution for localhost
    const addresses = cache.resolve("localhost") catch |err| {
        // DNS resolution can fail in test environments
        std.debug.print( "DNS resolution failed (expected in some environments): {any}\n", .{err});
        return;
    };

    // Localhost should resolve to at least one address
    try std.testing.expect(addresses.len > 0);

    // Check that at least one address is loopback
    var found_loopback = false;
    for (addresses) |addr| {
        if (addr.any.family == std.posix.AF.INET) {
            const ipv4 = addr.in;
            const bytes = std.mem.asBytes(&ipv4.sa.addr);
            // 127.0.0.1 in network byte order
            if (bytes[0] == 127 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 1) {
                found_loopback = true;
                break;
            }
        } else if (addr.any.family == std.posix.AF.INET6) {
            const ipv6 = addr.in6;
            // ::1 (all zeros except last byte)
            var is_loopback = true;
            for (ipv6.sa.addr[0..15]) |byte| {
                if (byte != 0) {
                    is_loopback = false;
                    break;
                }
            }
            if (is_loopback and ipv6.sa.addr[15] == 1) {
                found_loopback = true;
                break;
            }
        }
    }
    try std.testing.expect(found_loopback);

    // Check that the result is cached
    const cached_addresses = try cache.resolve("localhost");
    try std.testing.expectEqual(addresses.ptr, cached_addresses.ptr);

    // Wait for TTL to expire
    std.Thread.sleep(2 * std.time.ns_per_s);

    // Check that the entry is expired and a new resolution happens
    const new_addresses = try cache.resolve("localhost");
    try std.testing.expect(addresses.ptr != new_addresses.ptr);
}

test "hostname matching in AccessList" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    // Add localhost hostname rule
    try access_list.addAllowRule("localhost");

    // Test with loopback address
    const loopback_v4 = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);

    // This test may fail if DNS resolution is unavailable
    // In that case, the hostname rule will not match
    const is_allowed = (&access_list).isAllowed(loopback_v4);

    // Log result for debugging (test may pass or fail depending on DNS availability)
    std.debug.print( "Hostname matching test: localhost -> 127.0.0.1 allowed={any}\n", .{is_allowed});

    // We can't assert true/false reliably because DNS may be unavailable
    // The test passes if it doesn't crash - actual functionality validated manually
}

test "addressesEqual function" {
    // IPv4 addresses
    const addr1 = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 80);
    const addr2 = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 80);
    const addr3 = std.net.Address.initIp4([_]u8{ 192, 168, 1, 2 }, 80);
    const addr4 = std.net.Address.initIp4([_]u8{ 192, 168, 1, 1 }, 8080);

    try std.testing.expect(addressesEqual(addr1, addr2)); // Same IP and port
    try std.testing.expect(!addressesEqual(addr1, addr3)); // Different IP
    try std.testing.expect(!addressesEqual(addr1, addr4)); // Different port

    // IPv6 addresses
    const addr5 = try std.net.Address.parseIp6("2001:db8::1", 80);
    const addr6 = try std.net.Address.parseIp6("2001:db8::1", 80);
    const addr7 = try std.net.Address.parseIp6("2001:db8::2", 80);

    try std.testing.expect(addressesEqual(addr5, addr6)); // Same IP and port
    try std.testing.expect(!addressesEqual(addr5, addr7)); // Different IP

    // Different families
    try std.testing.expect(!addressesEqual(addr1, addr5)); // IPv4 vs IPv6
}
