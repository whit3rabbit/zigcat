// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! DNS Cache Module
//!
//! Provides DNS resolution caching with TTL-based expiration to reduce
//! latency and DNS load for hostname-based access control rules.
//!
//! ## Features
//! - TTL-based caching (default 5 minutes)
//! - Automatic expiry and cleanup
//! - Failure caching (empty results cached to prevent repeated lookups)
//! - Forward DNS lookup (A and AAAA records)
//!
//! ## Performance Characteristics
//! - Cache hit: O(1) hash map lookup
//! - Cache miss: O(n) DNS lookup where n = network latency (10-100ms)
//! - Memory: O(n) where n = number of cached hostnames
//!
//! ## Security Considerations
//! - DNS results can be manipulated (cache poisoning, rebinding attacks)
//! - Short TTL reduces attack window but increases DNS load
//! - Consider using IP-based rules for security-critical access control
//!
//! ## Usage Example
//! ```zig
//! var cache = DnsCache.init(allocator, 300); // 5 minute TTL
//! defer cache.deinit();
//!
//! const addresses = try cache.resolve("example.com");
//! // Subsequent calls within TTL use cached result
//! ```

const std = @import("std");
const time = std.time;

/// DNS cache entry with expiry timestamp
const DnsCacheEntry = struct {
    addresses: []const std.Io.net.IpAddress,
    expiry: i64, // Unix timestamp in seconds
};

/// DNS cache with TTL-based expiration
pub const DnsCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(DnsCacheEntry),
    ttl_seconds: i64,

    /// Initialize DNS cache with TTL
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for cache storage
    /// - `ttl_seconds`: Time-to-live for cached entries (e.g., 300 = 5 minutes)
    ///
    /// ## Returns
    /// Empty DNS cache ready for use
    pub fn init(allocator: std.mem.Allocator, ttl_seconds: u64) DnsCache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(DnsCacheEntry).init(allocator),
            .ttl_seconds = @intCast(ttl_seconds),
        };
    }

    /// Free all cache resources
    ///
    /// ## Safety
    /// - Must call before discarding DnsCache
    /// - Frees all cached address lists
    /// - Deallocates hash map storage
    pub fn deinit(self: *DnsCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.addresses);
        }
        self.cache.deinit();
    }

    /// Resolve hostname to IP addresses with caching
    ///
    /// Performs DNS lookup (A and AAAA records) with automatic caching.
    /// Checks cache first, returns cached result if not expired.
    /// On cache miss or expiry, performs fresh DNS lookup.
    ///
    /// ## Parameters
    /// - `self`: DnsCache instance
    /// - `hostname`: Hostname to resolve (e.g., "google.com")
    ///
    /// ## Returns
    /// - Array of resolved addresses (both IPv4 and IPv6)
    /// - Result is owned by cache (DO NOT free)
    ///
    /// ## Errors
    /// - `error.OutOfMemory`: Cache allocation failed
    /// - `error.UnknownHostName`: DNS lookup failed
    /// - `error.TemporaryNameServerFailure`: DNS server unreachable
    ///
    /// ## Caching Behavior
    /// - Cache hit (not expired): O(1) hash map lookup
    /// - Cache miss: O(n) DNS lookup + cache store
    /// - Failed lookups: Cached as empty list to prevent repeated failures
    /// - Expiry: Automatic removal on access after TTL
    ///
    /// ## Performance
    /// - DNS lookup latency: 10-100ms typical
    /// - Can block for seconds on timeout
    /// - Cache reduces load and latency for repeated lookups
    ///
    /// ## Example
    /// ```zig
    /// const addresses = try cache.resolve("google.com");
    /// // addresses valid until next cache expiry/cleanup
    /// ```
    pub fn resolve(self: *DnsCache, hostname: []const u8, io: std.Io) ![]const std.Io.net.IpAddress {
        // Use Instant.now() for timestamp (Zig 0.16.0+)
        const instant = try time.Instant.now();
        const now = instant.timestamp.sec;

        if (self.cache.getEntry(hostname)) |entry| {
            if (entry.value_ptr.expiry > now) {
                return entry.value_ptr.addresses;
            } else {
                // Entry expired, remove it
                self.allocator.free(entry.value_ptr.addresses);
                _ = self.cache.remove(hostname);
            }
        }

        // Perform DNS lookup using IpAddress.resolve (port 0 for hostname-only resolution)
        const resolved_address = std.Io.net.IpAddress.resolve(io, hostname, 0) catch |err| {
            // Also cache failures to prevent repeated lookups for bad hostnames
            const expiry = now + self.ttl_seconds;
            const empty_slice = try self.allocator.alloc(std.Io.net.IpAddress, 0);
            const hostname_copy = try self.allocator.dupe(u8, hostname);
            errdefer self.allocator.free(hostname_copy);

            try self.cache.put(hostname_copy, .{
                .addresses = empty_slice,
                .expiry = expiry,
            });
            return err;
        };

        // Create single-element array with resolved address
        const address_list = try self.allocator.alloc(std.Io.net.IpAddress, 1);
        address_list[0] = resolved_address;
        defer self.allocator.free(address_list);

        const addresses = try self.allocator.alloc(std.Io.net.IpAddress, address_list.len);
        errdefer self.allocator.free(addresses);
        @memcpy(addresses, address_list);

        const expiry = now + self.ttl_seconds;
        const hostname_copy = try self.allocator.dupe(u8, hostname);
        errdefer {
            self.allocator.free(hostname_copy);
            self.allocator.free(addresses);
        }

        try self.cache.put(hostname_copy, .{
            .addresses = addresses,
            .expiry = expiry,
        });

        return addresses;
    }
};
