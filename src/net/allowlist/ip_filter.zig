//! IP Filtering and Matching Module
//!
//! Provides IP address matching logic for access control rules including:
//! - Single IPv4/IPv6 address matching (exact comparison)
//! - CIDR range matching for both IPv4 and IPv6
//! - Hostname matching via DNS resolution with caching
//! - Address comparison utilities
//!
//! ## Matching Algorithm
//! - Single IP: Byte-by-byte comparison (O(1) for IPv4, O(1) for IPv6)
//! - CIDR IPv4: Subnet mask bitwise comparison (O(1))
//! - CIDR IPv6: Byte-by-byte prefix comparison (O(n) where n ≤ 16)
//! - Hostname: DNS lookup + comparison against all resolved IPs
//!
//! ## Performance Characteristics
//! - Single IP match: O(1) - Constant time byte comparison
//! - CIDR IPv4 match: O(1) - Bitwise operations
//! - CIDR IPv6 match: O(n) - n = prefix_len / 8 (max 16 bytes)
//! - Hostname match: O(m) - m = number of resolved addresses + DNS latency
//!
//! ## Usage Example
//! ```zig
//! const addr = std.net.Address.initIp4([_]u8{192, 168, 1, 100}, 0);
//! const cidr = try std.net.Ip4Address.parse("192.168.1.0", 0);
//!
//! if (matchesCidrV4(addr.in, cidr, 24)) {
//!     // Address is in 192.168.1.0/24 range
//! }
//! ```

const std = @import("std");
const rule_parser = @import("rule_parser.zig");
const dns_cache = @import("dns_cache.zig");

const IpRule = rule_parser.IpRule;
const DnsCache = dns_cache.DnsCache;

/// Check if an address matches an IP rule
///
/// Dispatches to appropriate matching function based on rule type:
/// - single_ipv4/single_ipv6: Exact address comparison
/// - cidr_v4/cidr_v6: CIDR range matching
/// - hostname: DNS resolution + comparison
///
/// ## Parameters
/// - `dns_cache_ptr`: DNS cache for hostname resolution
/// - `addr`: Address to test
/// - `rule`: Rule to match against
///
/// ## Returns
/// - `true`: Address matches the rule
/// - `false`: Address does not match
///
/// ## Performance
/// - Single IP: O(1) byte comparison
/// - CIDR: O(1) for IPv4, O(n) for IPv6 where n ≤ 16
/// - Hostname: O(m) + DNS latency where m = resolved addresses
///
/// ## Security Note
/// Hostname matching uses DNS which can be manipulated.
/// DNS resolution failures result in false (deny access).
///
/// ## Rule Precedence
/// This function only checks if a single rule matches. The calling logic (e.g.,
/// in `config/security.zig`) is responsible for enforcing precedence. The
/// standard behavior is:
/// 1. Check all **deny** rules first. If any deny rule matches, access is
///    immediately denied.
/// 2. If no deny rules match, check all **allow** rules. If any allow rule
///    matches, access is granted.
/// 3. If no rules match, the default policy (typically deny) is applied.
///
/// This "deny-first" approach ensures that specific exclusions always override
/// broader permissions.
pub fn matchesRule(dns_cache_ptr: *DnsCache, addr: std.net.Address, rule: IpRule) bool {
    switch (rule) {
        .single_ipv4 => |rule_addr| {
            if (addr.any.family == std.posix.AF.INET) {
                const addr_v4 = addr.in;
                // Convert u32 to [4]u8 for comparison
                const rule_bytes = std.mem.asBytes(&rule_addr.sa.addr);
                const addr_bytes = std.mem.asBytes(&addr_v4.sa.addr);
                return std.mem.eql(u8, rule_bytes, addr_bytes);
            }
            return false;
        },
        .single_ipv6 => |rule_addr| {
            if (addr.any.family == std.posix.AF.INET6) {
                const addr_v6 = addr.in6;
                return std.mem.eql(u8, &rule_addr.sa.addr, &addr_v6.sa.addr);
            }
            return false;
        },
        .cidr_v4 => |cidr| {
            if (addr.any.family == std.posix.AF.INET) {
                const addr_v4 = addr.in;
                return matchesCidrV4(addr_v4, cidr.addr, cidr.prefix_len);
            }
            return false;
        },
        .cidr_v6 => |cidr| {
            if (addr.any.family == std.posix.AF.INET6) {
                const addr_v6 = addr.in6;
                return matchesCidrV6(addr_v6, cidr.addr, cidr.prefix_len);
            }
            return false;
        },
        .hostname => |hostname| {
            // Resolve hostname to IP addresses via DNS
            const addresses = dns_cache_ptr.resolve(hostname) catch {
                // DNS resolution failed - deny access
                // In production, consider logging this event for security auditing
                return false;
            };

            // Check if client IP matches any resolved address
            // Note: Port is ignored for ACL matching (only IP matters)
            var addr_no_port = addr;
            if (addr.any.family == std.posix.AF.INET) {
                addr_no_port.in.sa.port = 0;
            } else if (addr.any.family == std.posix.AF.INET6) {
                addr_no_port.in6.sa.port = 0;
            }

            for (addresses) |resolved_addr| {
                var resolved_no_port = resolved_addr;
                if (resolved_addr.any.family == std.posix.AF.INET) {
                    resolved_no_port.in.sa.port = 0;
                } else if (resolved_addr.any.family == std.posix.AF.INET6) {
                    resolved_no_port.in6.sa.port = 0;
                }

                if (addressesEqual(addr_no_port, resolved_no_port)) {
                    return true;
                }
            }

            return false;
        },
    }
}

/// Check if an IPv4 address matches a CIDR range
///
/// Uses subnet mask comparison to determine if an address falls within
/// a CIDR network range. Implements RFC 4632 CIDR notation.
///
/// ## Parameters
/// - `addr`: IPv4 address to test
/// - `cidr_addr`: Base address of the CIDR range
/// - `prefix_len`: Prefix length (0-32 bits)
///
/// ## Returns
/// - `true`: Address is within the CIDR range
/// - `false`: Address is outside the CIDR range
///
/// ## Algorithm
/// 1. Special case: prefix_len = 0 matches everything (0.0.0.0/0)
/// 2. Create subnet mask from prefix length
/// 3. Convert addresses to 32-bit big-endian integers
/// 4. Apply mask to both addresses
/// 5. Compare masked network portions
///
/// ## Subnet Mask Calculation
/// ```
/// mask = 0xFFFFFFFF << (32 - prefix_len)
///
/// Examples:
/// /24: 0xFFFFFF00 (255.255.255.0)
/// /16: 0xFFFF0000 (255.255.0.0)
/// /8:  0xFF000000 (255.0.0.0)
/// ```
///
/// ## CIDR Range Examples
/// - 192.168.1.0/24: 192.168.1.0 - 192.168.1.255 (254 hosts)
/// - 10.0.0.0/8: 10.0.0.0 - 10.255.255.255 (16.7M hosts)
/// - 172.16.0.0/12: 172.16.0.0 - 172.31.255.255 (1M hosts)
///
/// ## Edge Cases
/// - /0: Matches all IPv4 addresses (0.0.0.0/0)
/// - /32: Matches single host (equivalent to exact match)
/// - Base address host bits set: Mask clears them (192.168.1.5/24 = 192.168.1.0/24)
///
/// ## Performance
/// - Time complexity: O(1) (constant bitwise operations)
/// - No allocations (stack-only computation)
///
/// ## Example
/// ```zig
/// const addr = try std.net.Ip4Address.parse("192.168.1.100", 0);
/// const cidr = try std.net.Ip4Address.parse("192.168.1.0", 0);
///
/// matchesCidrV4(addr, cidr, 24);  // true (192.168.1.100 in 192.168.1.0/24)
/// matchesCidrV4(addr, cidr, 25);  // true (192.168.1.100 in 192.168.1.0/25)
/// matchesCidrV4(addr, cidr, 26);  // false (192.168.1.100 not in 192.168.1.0/26)
/// ```
pub fn matchesCidrV4(addr: std.net.Ip4Address, cidr_addr: std.net.Ip4Address, prefix_len: u8) bool {
    if (prefix_len == 0) {
        // 0.0.0.0/0 matches everything
        return true;
    }

    // Create network mask
    const mask: u32 = if (prefix_len >= 32)
        0xFFFFFFFF
    else
        @as(u32, 0xFFFFFFFF) << @intCast(32 - prefix_len);

    // Convert u32 addresses to [4]u8 arrays for readInt
    const addr_bytes = std.mem.asBytes(&addr.sa.addr);
    const cidr_bytes = std.mem.asBytes(&cidr_addr.sa.addr);

    // Extract IP addresses as u32 (big-endian)
    const addr_bits = std.mem.readInt(u32, addr_bytes[0..4], .big);
    const cidr_bits = std.mem.readInt(u32, cidr_bytes[0..4], .big);

    // Compare network portions
    return (addr_bits & mask) == (cidr_bits & mask);
}

/// Check if an IPv6 address matches a CIDR range
///
/// Uses byte-by-byte prefix comparison to determine if an IPv6 address
/// falls within a CIDR network range. Implements RFC 4291 IPv6 addressing.
///
/// ## Parameters
/// - `addr`: IPv6 address to test
/// - `cidr_addr`: Base address of the CIDR range
/// - `prefix_len`: Prefix length (0-128 bits)
///
/// ## Returns
/// - `true`: Address is within the CIDR range
/// - `false`: Address is outside the CIDR range
///
/// ## Algorithm
/// 1. Special case: prefix_len = 0 matches everything (::/0)
/// 2. Calculate full bytes and remainder bits from prefix length
/// 3. Compare full bytes (8-bit chunks) for equality
/// 4. If remainder bits exist, compare partial byte with mask
/// 5. Return true if all comparisons match
///
/// ## Byte-wise Comparison Strategy
/// IPv6 addresses are 128 bits (16 bytes). Instead of bitwise operations
/// on 128-bit integers (not supported), we compare bytes individually:
///
/// ```
/// prefix_len = 40 bits
/// full_bytes = 40 / 8 = 5 bytes
/// remainder_bits = 40 % 8 = 0 bits
///
/// Compare bytes 0-4 for exact equality
/// ```
///
/// ## Partial Byte Masking
/// For prefix lengths not aligned to byte boundaries:
/// ```
/// prefix_len = 42 bits
/// full_bytes = 5, remainder_bits = 2
///
/// Compare bytes 0-4 exactly
/// Compare byte 5 with mask: 0xFF << (8 - 2) = 0xC0
///
/// Example:
/// addr[5]     = 0b10110101 (0xB5)
/// cidr_addr[5] = 0b10100000 (0xA0)
/// mask        = 0b11000000 (0xC0)
///
/// addr[5] & mask     = 0b10000000
/// cidr_addr[5] & mask = 0b10000000
/// Match!
/// ```
///
/// ## Common IPv6 Prefix Lengths
/// - /0: Entire IPv6 space (::/0)
/// - /32: ISP allocation (65K /48 sites)
/// - /48: Site allocation (65K /64 subnets)
/// - /64: Single subnet (standard for LANs)
/// - /128: Single host (exact match)
///
/// ## CIDR Range Examples
/// - 2001:db8::/32: 2001:db8:: - 2001:db8:ffff:ffff:ffff:ffff:ffff:ffff
/// - fe80::/10: Link-local addresses
/// - fc00::/7: Unique local addresses (ULA)
///
/// ## Performance
/// - Time complexity: O(n) where n = prefix_len / 8 (max 16 bytes)
/// - Best case: O(1) for prefix_len = 0
/// - Worst case: O(16) for prefix_len = 128
/// - No allocations (stack-only computation)
///
/// ## Edge Cases
/// - /0: Matches all IPv6 addresses (::/0)
/// - /128: Matches single host (equivalent to exact match)
/// - Host bits set in base address: Ignored by prefix comparison
///
/// ## Example
/// ```zig
/// const addr = try std.net.Ip6Address.parse("2001:db8::100", 0);
/// const cidr = try std.net.Ip6Address.parse("2001:db8::", 0);
///
/// matchesCidrV6(addr, cidr, 32);   // true (in 2001:db8::/32)
/// matchesCidrV6(addr, cidr, 64);   // true (in 2001:db8::/64)
/// matchesCidrV6(addr, cidr, 120);  // false (different /120 subnet)
/// ```
pub fn matchesCidrV6(addr: std.net.Ip6Address, cidr_addr: std.net.Ip6Address, prefix_len: u8) bool {
    if (prefix_len == 0) {
        // ::/0 matches everything
        return true;
    }

    // IPv6 addresses are 128 bits (16 bytes)
    // We'll compare byte by byte
    const full_bytes = prefix_len / 8;
    const remainder_bits = prefix_len % 8;

    // Compare full bytes
    var i: usize = 0;
    while (i < full_bytes) : (i += 1) {
        if (addr.sa.addr[i] != cidr_addr.sa.addr[i]) {
            return false;
        }
    }

    // Compare remaining bits if any
    if (remainder_bits > 0 and full_bytes < 16) {
        const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remainder_bits);
        const addr_byte = addr.sa.addr[full_bytes];
        const cidr_byte = cidr_addr.sa.addr[full_bytes];
        if ((addr_byte & mask) != (cidr_byte & mask)) {
            return false;
        }
    }

    return true;
}

/// Compare two addresses for equality (both IP and port)
///
/// ## Parameters
/// - `addr1`: First address to compare
/// - `addr2`: Second address to compare
///
/// ## Returns
/// - `true`: Both IP and port are equal
/// - `false`: Different IP family, IP address, or port
///
/// ## Performance
/// - IPv4: O(1) - 4 byte comparison + port
/// - IPv6: O(1) - 16 byte comparison + port
///
/// ## Usage
/// Primarily used for hostname matching where resolved addresses
/// need to be compared against client addresses (with ports normalized).
pub fn addressesEqual(addr1: std.net.Address, addr2: std.net.Address) bool {
    // Different address families can't be equal
    if (addr1.any.family != addr2.any.family) {
        return false;
    }

    if (addr1.any.family == std.posix.AF.INET) {
        // IPv4 comparison
        const a1 = addr1.in;
        const a2 = addr2.in;

        // Compare port
        if (a1.sa.port != a2.sa.port) {
            return false;
        }

        // Compare IP address (4 bytes)
        const bytes1 = std.mem.asBytes(&a1.sa.addr);
        const bytes2 = std.mem.asBytes(&a2.sa.addr);
        return std.mem.eql(u8, bytes1, bytes2);
    } else if (addr1.any.family == std.posix.AF.INET6) {
        // IPv6 comparison
        const a1 = addr1.in6;
        const a2 = addr2.in6;

        // Compare port
        if (a1.sa.port != a2.sa.port) {
            return false;
        }

        // Compare IP address (16 bytes)
        return std.mem.eql(u8, &a1.sa.addr, &a2.sa.addr);
    }

    // Unknown family
    return false;
}
