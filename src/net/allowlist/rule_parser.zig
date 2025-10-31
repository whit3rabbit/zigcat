// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! IP Rule Parser Module
//!
//! Provides rule type definitions and parsing logic for IP access control.
//! Supports single IPs, CIDR ranges, and hostnames for both IPv4 and IPv6.
//!
//! ## Supported Rule Formats
//! - Single IPv4: "192.168.1.1", "10.0.0.1", "127.0.0.1"
//! - Single IPv6: "2001:db8::1", "::1", "fe80::1"
//! - IPv4 CIDR: "192.168.1.0/24", "10.0.0.0/8", "0.0.0.0/0"
//! - IPv6 CIDR: "2001:db8::/32", "::/0", "fe80::/10"
//! - Hostname: "example.com", "localhost", "server.local"
//!
//! ## Parsing Strategy
//! Uses greedy parsing with fallback:
//! 1. Check for "/" character (CIDR notation)
//! 2. Try IPv4 CIDR, then IPv6 CIDR
//! 3. Try single IPv4, then single IPv6
//! 4. Treat as hostname (any valid string)
//!
//! ## Memory Management
//! - Single IP and CIDR rules: Stack-allocated (no cleanup needed)
//! - Hostname rules: Heap-allocated string (must call IpRule.deinit())
//!
//! ## Usage Example
//! ```zig
//! const rule1 = try parseRule(allocator, "192.168.1.0/24");
//! // Returns: IpRule{ .cidr_v4 = .{ .addr = ..., .prefix_len = 24 }}
//!
//! const rule2 = try parseRule(allocator, "2001:db8::1");
//! // Returns: IpRule{ .single_ipv6 = ... }
//!
//! var rule3 = try parseRule(allocator, "example.com");
//! defer rule3.deinit(allocator);
//! // Returns: IpRule{ .hostname = "example.com" }
//! ```

const std = @import("std");

/// IP access control rule
///
/// Represents a single access control rule that can match:
/// - Single IPv4/IPv6 addresses (exact match)
/// - CIDR ranges with prefix length (subnet match)
/// - Hostnames (parsed but not matched - requires DNS resolution)
///
/// ## Memory Management
/// - Single IP rules: Stack-allocated (no cleanup needed)
/// - CIDR rules: Stack-allocated (no cleanup needed)
/// - Hostname rules: Heap-allocated string (must call deinit())
///
/// ## Example
/// ```zig
/// // Single IPv4 rule
/// const rule1 = IpRule{ .single_ipv4 = try std.net.Ip4Address.parse("192.168.1.1", 0) };
///
/// // CIDR rule
/// const rule2 = IpRule{ .cidr_v4 = .{
///     .addr = try std.net.Ip4Address.parse("192.168.0.0", 0),
///     .prefix_len = 24,  // 192.168.0.0/24
/// }};
///
/// // Hostname rule (heap-allocated)
/// var rule3 = IpRule{ .hostname = try allocator.dupe(u8, "example.com") };
/// defer rule3.deinit(allocator);
/// ```
pub const IpRule = union(enum) {
    /// Single IPv4 address (exact match)
    single_ipv4: std.Io.net.Ip4Address,

    /// Single IPv6 address (exact match)
    single_ipv6: std.Io.net.Ip6Address,

    /// IPv4 CIDR range with subnet mask
    cidr_v4: struct {
        addr: std.Io.net.Ip4Address,
        prefix_len: u8, // 0-32 (0 = match all, 32 = single host)
    },

    /// IPv6 CIDR range with prefix length
    cidr_v6: struct {
        addr: std.Io.net.Ip6Address,
        prefix_len: u8, // 0-128 (0 = match all, 128 = single host)
    },

    /// Hostname (DNS forward lookup - A/AAAA records)
    /// WARNING: Hostname matching uses DNS which can be manipulated.
    /// Use IP-based rules for production security-critical access control.
    /// DNS lookups add 10-100ms latency per connection.
    hostname: []const u8,

    /// Free heap-allocated memory (hostnames only)
    ///
    /// ## Parameters
    /// - `self`: Rule to clean up (modified in-place)
    /// - `allocator`: Allocator used to create hostname string
    ///
    /// ## Safety
    /// - Safe to call multiple times (idempotent)
    /// - Safe to call on non-hostname rules (no-op)
    /// - Must use same allocator that created the hostname
    pub fn deinit(self: *IpRule, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .hostname => |h| allocator.free(h),
            else => {},
        }
    }
};

/// Parse rule string into structured IpRule
///
/// Attempts to parse the input string as various rule types in order:
/// 1. CIDR notation (IPv4 or IPv6 with "/" prefix length)
/// 2. Single IPv4 address
/// 3. Single IPv6 address
/// 4. Hostname (fallback - any string)
///
/// ## Supported Formats
/// - IPv4 single: "192.168.1.1", "10.0.0.1", "127.0.0.1"
/// - IPv4 CIDR: "192.168.1.0/24", "10.0.0.0/8", "0.0.0.0/0"
/// - IPv6 single: "2001:db8::1", "::1", "fe80::1"
/// - IPv6 CIDR: "2001:db8::/32", "::/0", "fe80::/10"
/// - Hostname: "example.com", "localhost", "server.local"
///
/// ## Parameters
/// - `allocator`: Memory allocator for hostname strings (heap-allocated)
/// - `rule_str`: Input string to parse
///
/// ## Returns
/// - Parsed IpRule (single_ipv4, single_ipv6, cidr_v4, cidr_v6, or hostname)
///
/// ## Errors
/// - `error.InvalidPrefixLength`: CIDR prefix out of valid range
///   - IPv4: Must be 0-32
///   - IPv6: Must be 0-128
/// - `error.InvalidCidrAddress`: CIDR base address parsing failed
/// - `error.OutOfMemory`: Hostname string allocation failed
///
/// ## CIDR Prefix Length Validation
/// - IPv4: 0-32 bits
///   - /0 = 0.0.0.0/0 (entire IPv4 space)
///   - /8 = Class A network (16.7M hosts)
///   - /16 = Class B network (65K hosts)
///   - /24 = Class C network (254 hosts)
///   - /32 = Single host
/// - IPv6: 0-128 bits
///   - /0 = ::/0 (entire IPv6 space)
///   - /32 = Typical ISP allocation
///   - /48 = Typical site allocation
///   - /64 = Single subnet
///   - /128 = Single host
///
/// ## Parsing Strategy
/// Uses greedy parsing with fallback:
/// 1. Check for "/" character (CIDR notation)
/// 2. Try IPv4 CIDR, then IPv6 CIDR
/// 3. Try single IPv4, then single IPv6
/// 4. Treat as hostname (any valid string)
///
/// ## Example
/// ```zig
/// const rule1 = try parseRule(allocator, "192.168.1.0/24");
/// // Returns: IpRule{ .cidr_v4 = .{ .addr = ..., .prefix_len = 24 }}
///
/// const rule2 = try parseRule(allocator, "2001:db8::1");
/// // Returns: IpRule{ .single_ipv6 = ... }
///
/// const rule3 = try parseRule(allocator, "example.com");
/// // Returns: IpRule{ .hostname = "example.com" }
/// ```
///
/// ## Security: Hostname vs. IP Rules
/// Using hostname-based rules has significant security implications. DNS records
/// can be manipulated through various attacks (e.g., DNS spoofing, cache poisoning),
/// potentially allowing an unauthorized client to gain access by impersonating a
/// legitimate hostname.
///
/// For security-sensitive applications, it is **strongly recommended** to use
/// IP-based rules (`single_ipv4`, `cidr_v4`, etc.) which are not subject to
/// DNS manipulation. Hostname rules are provided for convenience but should be
/// used with caution in untrusted environments.
pub fn parseRule(allocator: std.mem.Allocator, rule_str: []const u8) !IpRule {
    // Check for CIDR notation
    if (std.mem.indexOf(u8, rule_str, "/")) |slash_pos| {
        const addr_str = rule_str[0..slash_pos];
        const prefix_str = rule_str[slash_pos + 1 ..];
        const prefix_len = try std.fmt.parseInt(u8, prefix_str, 10);

        // Try to parse address (will determine IPv4 vs IPv6)
        if (std.Io.net.IpAddress.parse(addr_str, 0)) |parsed_addr| {
            switch (parsed_addr) {
                .ip4 => |ipv4| {
                    if (prefix_len > 32) return error.InvalidPrefixLength;
                    return IpRule{ .cidr_v4 = .{
                        .addr = ipv4,
                        .prefix_len = prefix_len,
                    } };
                },
                .ip6 => |ipv6| {
                    if (prefix_len > 128) return error.InvalidPrefixLength;
                    return IpRule{ .cidr_v6 = .{
                        .addr = ipv6,
                        .prefix_len = prefix_len,
                    } };
                },
            }
        } else |_| {
            return error.InvalidCidrAddress;
        }
    }

    // Try to parse as single IP address (IPv4 or IPv6)
    if (std.Io.net.IpAddress.parse(rule_str, 0)) |parsed_addr| {
        switch (parsed_addr) {
            .ip4 => |ipv4| {
                return IpRule{ .single_ipv4 = ipv4 };
            },
            .ip6 => |ipv6| {
                return IpRule{ .single_ipv6 = ipv6 };
            },
        }
    } else |_| {
        // Treat as hostname
        const hostname = try allocator.dupe(u8, rule_str);
        return IpRule{ .hostname = hostname };
    }
}
