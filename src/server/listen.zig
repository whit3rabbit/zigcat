//! Server connection acceptance with IP-based access control.
//!
//! This module provides server-side utilities for:
//! - Accepting connections with allow/deny list filtering
//! - Loading access control rules from files
//! - Creating AccessList from configuration
//!
//! Access control logic:
//! - Deny list checked first (explicit block)
//! - Allow list checked second (explicit permit)
//! - If neither matches, default policy applies
//! - Denied connections are closed immediately
//!
//! File format for allow/deny files:
//! ```
//! # Comments start with #
//! 192.168.0.0/16    # Private network
//! 10.0.0.0/8        # Another private range
//! 172.16.1.100      # Specific host
//! ```

const std = @import("std");
const allowlist = @import("../net/allowlist.zig");
const logging = @import("../util/logging.zig");
const path_safety = @import("../util/path_safety.zig");

/// Accept connection with access control filtering.
///
/// Implements access-controlled accept loop with DoS mitigation:
/// 1. Accept incoming connection
/// 2. Check client IP against access list
/// 3. If denied: close connection, apply rate limiting, and retry
/// 4. If allowed: return connection to caller
///
/// **DoS Mitigation** (SECURITY FIX 2025-10-10):
/// - Tracks consecutive denials per thread
/// - Applies exponential backoff after 5 consecutive denials
/// - Prevents tight spin loop consuming 100% CPU during flood attacks
/// - Backoff: 10ms * 2^(denials-5), capped at 1000ms
///
/// Loop behavior:
/// - Continues accepting until allowed connection found
/// - Logs denied connections if verbose enabled
/// - Never returns a denied connection
/// - Resets rate limiting counter when legitimate connection accepted
///
/// Parameters:
///   listener: Server socket from std.net.Address.listen()
///   access_list: Configured allow/deny rules
///   verbose: Enable logging of denied connections
///
/// Returns: Accepted and allowed connection
pub fn acceptWithAccessControl(
    listener: *std.net.Server,
    access_list: *const allowlist.AccessList,
    verbose: bool,
) !std.net.Server.Connection {
    // SECURITY: Rate limiting state to prevent DoS via denied connection floods
    // Per-thread state (no cross-thread coordination needed)
    var consecutive_denials: u32 = 0;
    const max_consecutive_before_delay: u32 = 5;
    const initial_delay_ms: u64 = 10;
    const max_delay_ms: u64 = 1000;

    while (true) {
        const conn = try listener.accept();

        // Check if client IP is allowed
        if (!access_list.isAllowed(conn.address)) {
            if (verbose) {
                logging.logVerbose(null, "Access denied from: {any}\n", .{conn.address});
            }
            conn.stream.close();

            consecutive_denials += 1;

            // SECURITY FIX: Apply exponential backoff after threshold to prevent CPU exhaustion
            // Without this, an attacker from a denied IP can force 100% CPU with connection floods
            if (consecutive_denials > max_consecutive_before_delay) {
                const excess = consecutive_denials - max_consecutive_before_delay;
                // Exponential: delay = initial * 2^excess, capped at max
                const delay_ms = @min(
                    initial_delay_ms * (@as(u64, 1) << @min(excess, 10)), // Cap shift to prevent overflow
                    max_delay_ms,
                );

                if (verbose) {
                    logging.logVerbose(
                        null,
                        "Rate limiting: {d} consecutive denials, sleeping {d}ms\n",
                        .{ consecutive_denials, delay_ms },
                    );
                }

                const delay_ns = delay_ms * std.time.ns_per_ms;
                std.Thread.sleep(delay_ns);
            }

            continue;
        }

        // Connection accepted - reset denial counter
        consecutive_denials = 0;

        if (verbose) {
            logging.logVerbose(null, "Connection accepted from: {any}\n", .{conn.address});
        }

        return conn;
    }
}

/// Create access list from configuration.
///
/// Consolidates access rules from multiple sources:
/// 1. CLI allow list (--allow-ip)
/// 2. CLI deny list (--deny-ip)
/// 3. Allow file rules (--allow-file)
/// 4. Deny file rules (--deny-file)
///
/// Memory management:
/// - Returned AccessList owns all rule data
/// - Caller must call access_list.deinit() when done
/// - errdefer ensures cleanup on partial initialization failure
///
/// Parameters:
///   allocator: For rule allocation
///   cfg: Configuration with access control settings
///
/// Returns: Populated AccessList or allocation error
pub fn createAccessListFromConfig(
    allocator: std.mem.Allocator,
    cfg: anytype,
) !allowlist.AccessList {
    var access_list = allowlist.AccessList.init(allocator);
    errdefer access_list.deinit();

    // Add IP-based allow rules
    for (cfg.allow_list.items) |rule_str| {
        try access_list.addAllowRule(rule_str);
    }

    // Add IP-based deny rules
    for (cfg.deny_list.items) |rule_str| {
        try access_list.addDenyRule(rule_str);
    }

    // Load allow rules from file if specified
    if (cfg.allow_file) |file_path| {
        try loadRulesFromFile(allocator, file_path, &access_list, true);
    }

    // Load deny rules from file if specified
    if (cfg.deny_file) |file_path| {
        try loadRulesFromFile(allocator, file_path, &access_list, false);
    }

    return access_list;
}

/// Load access control rules from a file.
///
/// File format:
/// - One rule per line (IP address or CIDR notation)
/// - Lines starting with # are comments
/// - Empty lines ignored
/// - Whitespace trimmed from each line
///
/// Example file:
/// ```
/// # Allow local networks
/// 192.168.0.0/16
/// 10.0.0.0/8
///
/// # Specific trusted host
/// 172.16.1.100
/// ```
///
/// Parameters:
///   allocator: Memory allocator for file content
///   file_path: Path to rules file
///   access_list: AccessList to add rules to
///   is_allow: true for allow rules, false for deny rules
///
/// Returns: Error if file cannot be read or rules are invalid
fn loadRulesFromFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    access_list: *allowlist.AccessList,
    is_allow: bool,
) !void {
    if (!path_safety.isSafePath(file_path)) {
        logging.logError(error.PathTraversalDetected, "access control file validation");
        std.debug.print("Error: Access control file '{s}' contains forbidden traversal sequences\n", .{file_path});
        return error.PathTraversalDetected;
    }

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const max_file_size = 1024 * 1024; // 1MB max
    const content = try file.readToEndAlloc(allocator, max_file_size);
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Add rule
        if (is_allow) {
            try access_list.addAllowRule(trimmed);
        } else {
            try access_list.addDenyRule(trimmed);
        }
    }
}

/// Create a TCP server with access control
pub fn createServer(
    allocator: std.mem.Allocator,
    address: std.net.Address,
    cfg: anytype,
) !struct {
    server: std.net.Server,
    access_list: allowlist.AccessList,
} {
    const server = try address.listen(.{
        .reuse_address = true,
        .reuse_port = false,
    });

    const access_list = try createAccessListFromConfig(allocator, cfg);

    return .{
        .server = server,
        .access_list = access_list,
    };
}

test "createAccessListFromConfig with allow list" {
    const allocator = std.testing.allocator;

    // Mock config - Fix for Zig 0.15.1 ArrayList API
    // fromOwnedSlice expects a slice, not an allocator
    const allow_items: []const []const u8 = &[_][]const u8{"192.168.1.0/24"};
    var allow_list = std.ArrayList([]const u8).fromOwnedSlice(try allocator.dupe([]const u8, allow_items));
    defer allow_list.deinit(allocator);

    const deny_items: []const []const u8 = &[_][]const u8{};
    var deny_list = std.ArrayList([]const u8).fromOwnedSlice(try allocator.dupe([]const u8, deny_items));
    defer deny_list.deinit(allocator);

    const mock_cfg = struct {
        allow_list: std.ArrayList([]const u8),
        deny_list: std.ArrayList([]const u8),
        allow_file: ?[]const u8 = null,
        deny_file: ?[]const u8 = null,
    }{
        .allow_list = allow_list,
        .deny_list = deny_list,
    };

    var access_list = try createAccessListFromConfig(allocator, mock_cfg);
    defer access_list.deinit();

    try std.testing.expectEqual(@as(usize, 1), access_list.allow_rules.items.len);
}
