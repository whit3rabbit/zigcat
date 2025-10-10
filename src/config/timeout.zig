//! Unified timeout selection for consistent behavior across all server modes.
//!
//! This module provides centralized timeout logic that respects the priority:
//! 1. Explicit user configuration (--idle-timeout flag)
//! 2. Server mode defaults (protocol-specific)
//! 3. TTY detection (interactive vs automated)
//! 4. Platform fallback (Windows always 30s, POSIX TTY-dependent)

const std = @import("std");
const posix = std.posix;
const Config = @import("config_struct.zig").Config;

/// Context for timeout selection - determines which defaults to use.
pub const TimeoutContext = enum {
    /// Client mode: wait indefinitely for server
    client_mode,
    /// TCP server: TTY-aware (infinite for interactive, 30s for automated)
    tcp_server,
    /// UDP server: 30s default (stateless protocol, short-lived connections)
    udp_server,
    /// Unix socket server: TTY-aware (same as TCP)
    unix_server,
};

/// Get timeout for bidirectional I/O based on configuration and context.
///
/// This function implements a unified timeout selection strategy that respects
/// user intent while providing sensible defaults for different server modes.
///
/// **Priority** (highest to lowest):
/// 1. **Explicit user configuration**: cfg.idle_timeout > 0 (ALWAYS honored)
/// 2. **Server mode defaults**: Protocol-specific defaults (UDP=30s, TCP/Unix=TTY-aware)
/// 3. **TTY detection**: Interactive (-1) vs automated (30s)
/// 4. **Platform fallback**: Windows always 30s (no TTY detection)
///
/// **Return Values**:
/// - `-1`: Infinite timeout (wait indefinitely)
/// - `0+`: Finite timeout in milliseconds
///
/// **Examples**:
/// ```zig
/// // Explicit timeout ALWAYS wins:
/// cfg.idle_timeout = 5000;
/// const timeout = getConnectionTimeout(cfg, .tcp_server, stdin.handle);
/// // Result: 5000 (user specified 5 seconds)
///
/// // TCP server with TTY (no explicit timeout):
/// cfg.idle_timeout = 0;
/// const timeout = getConnectionTimeout(cfg, .tcp_server, tty_handle);
/// // Result: -1 (infinite for interactive use)
///
/// // TCP server without TTY (automated):
/// cfg.idle_timeout = 0;
/// const timeout = getConnectionTimeout(cfg, .tcp_server, pipe_handle);
/// // Result: 30000 (30s deadlock prevention)
///
/// // UDP server (no explicit timeout):
/// cfg.idle_timeout = 0;
/// const timeout = getConnectionTimeout(cfg, .udp_server, null);
/// // Result: 30000 (30s for stateless protocol)
/// ```
///
/// Parameters:
/// - cfg: Configuration with idle_timeout field
/// - context: Server/client mode context (determines defaults)
/// - stdin_handle: Optional stdin handle for TTY detection (server modes only)
///
/// Returns: Timeout in milliseconds (-1 for infinite, 0+ for finite)
pub fn getConnectionTimeout(
    cfg: *const Config,
    context: TimeoutContext,
    stdin_handle: ?posix.fd_t,
) i32 {
    // Priority 1: Explicit user configuration ALWAYS wins
    // If user specifies --idle-timeout, use it regardless of mode/TTY
    if (cfg.idle_timeout > 0) {
        return @intCast(cfg.idle_timeout);
    }

    // Priority 2: Mode-specific defaults
    return switch (context) {
        // Client mode: wait indefinitely for server response
        .client_mode => -1,

        // TCP server: TTY-aware (interactive vs automated)
        .tcp_server => getTtyBasedTimeout(stdin_handle),

        // UDP server: 30s default (stateless, short-lived)
        // Changed from 1s to match TCP behavior
        .udp_server => 30000,

        // Unix socket server: TTY-aware (same as TCP)
        .unix_server => getTtyBasedTimeout(stdin_handle),
    };
}

/// Get TTY-aware timeout for server modes.
///
/// This function implements the TTY detection heuristic:
/// - **TTY (interactive)**: Infinite timeout (-1) for better UX
/// - **Non-TTY (automated)**: 30s timeout for deadlock prevention
///
/// **Rationale**:
/// - Interactive terminals: Users expect to type commands and wait indefinitely
/// - Automated scripts: Risk of deadlock if peer stops sending, cap at 30s
/// - Windows: No reliable TTY detection, always use 30s (safer default)
///
/// Parameters:
/// - stdin_handle: Optional stdin file descriptor for isatty() check
///
/// Returns: -1 for TTY (infinite), 30000 for non-TTY (30 seconds)
fn getTtyBasedTimeout(stdin_handle: ?posix.fd_t) i32 {
    if (stdin_handle) |fd| {
        const is_tty = switch (@import("builtin").os.tag) {
            .linux, .macos => posix.isatty(fd),
            .windows => false, // Windows: always treat as non-TTY (safer)
            else => false, // Other platforms: conservative default
        };
        return if (is_tty) -1 else 30000;
    }
    // No stdin handle provided: assume non-interactive
    return 30000;
}

// ============================================================================
// Tests
// ============================================================================

test "getConnectionTimeout respects explicit cfg.idle_timeout" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // User specifies 5 second timeout
    cfg.idle_timeout = 5000;

    // Should use explicit value regardless of context or TTY
    try testing.expectEqual(@as(i32, 5000), getConnectionTimeout(&cfg, .client_mode, null));
    try testing.expectEqual(@as(i32, 5000), getConnectionTimeout(&cfg, .tcp_server, null));
    try testing.expectEqual(@as(i32, 5000), getConnectionTimeout(&cfg, .udp_server, null));
    try testing.expectEqual(@as(i32, 5000), getConnectionTimeout(&cfg, .unix_server, null));
}

test "getConnectionTimeout uses mode-specific defaults" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // No explicit timeout set
    cfg.idle_timeout = 0;

    // Client mode: infinite
    try testing.expectEqual(@as(i32, -1), getConnectionTimeout(&cfg, .client_mode, null));

    // UDP server: 30s (changed from 1s)
    try testing.expectEqual(@as(i32, 30000), getConnectionTimeout(&cfg, .udp_server, null));

    // TCP/Unix server with no stdin: 30s
    try testing.expectEqual(@as(i32, 30000), getConnectionTimeout(&cfg, .tcp_server, null));
    try testing.expectEqual(@as(i32, 30000), getConnectionTimeout(&cfg, .unix_server, null));
}

test "getTtyBasedTimeout returns correct values" {
    const testing = std.testing;

    // No stdin handle: assume non-interactive
    try testing.expectEqual(@as(i32, 30000), getTtyBasedTimeout(null));

    // With stdin handle: depends on platform
    // On POSIX, real TTY detection would run
    // On Windows, always returns 30000
    const stdin = std.fs.File.stdin();
    const timeout = getTtyBasedTimeout(stdin.handle);

    // Timeout should be either -1 (TTY) or 30000 (non-TTY)
    try testing.expect(timeout == -1 or timeout == 30000);
}
