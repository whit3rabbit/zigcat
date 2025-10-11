//! # Session Timeout Tracker
//!
//! This module provides a `TimeoutTracker` struct, a utility for managing multiple
//! time-based deadlines within a single session, such as a command execution
//! (`--exec`) session. It is designed to be polled periodically within an event
//! loop to check if any configured timeouts have been exceeded.
//!
//! ## Monitored Timeouts
//!
//! The tracker manages three distinct timeouts, all configured in milliseconds:
//!
//! 1.  **Execution Timeout (`execution_ms`)**: A hard deadline for the total
//!     duration of the session. The session is terminated if it runs longer
//!     than this value, regardless of activity. A value of 0 disables this timeout.
//!
//! 2.  **Idle Timeout (`idle_ms`)**: A deadline for inactivity. This timer is reset
//!     every time `markActivity()` is called. If the time since the last activity
//!     exceeds this value, the session is terminated. This is useful for cleaning
//!     up stalled or abandoned connections. A value of 0 disables this timeout.
//!
//! 3.  **Connection Timeout (`connection_ms`)**: A deadline for the initial phase
//!     of a connection. It measures the time from the start of the session until
//!     the first call to `markActivity()` or `markConnectionEstablished()`. This
//!     is useful for preventing sessions from hanging indefinitely if the client
//!     connects but never sends any data. A value of 0 disables this timeout.
//!
//! ## Usage in Event Loops
//!
//! The `TimeoutTracker` is intended to be integrated into an event loop (e.g., one
//! using `poll()` or `io_uring`).
//!
//! -   **`check()`**: In each iteration of the loop, `check()` is called to see if any
//!     timeout has occurred. If it returns an event other than `.none`, the loop
//!     should terminate the session.
//! -   **`nextPollTimeout()`**: This helper function calculates the maximum time (in ms)
//!     the event loop can safely sleep before the next timeout is scheduled to occur.
//!     This allows the event loop to be efficient by sleeping as long as possible
//!     without missing a deadline.
//! -   **`markActivity()`**: This should be called whenever data is successfully
//!     read from or written to the session's underlying connection.

const std = @import("std");

/// Timeout configuration (milliseconds).
pub const TimeoutConfig = struct {
    /// Maximum total execution time (0 = unlimited)
    execution_ms: u32 = 0,
    /// Maximum idle duration without I/O activity (0 = unlimited)
    idle_ms: u32 = 0,
    /// Deadline for initial connection activity (0 = unlimited)
    connection_ms: u32 = 0,
};

/// Timeout events reported by the tracker.
pub const TimeoutEvent = enum {
    /// No timeout triggered
    none,
    /// Total execution time exceeded
    execution,
    /// Idle timeout triggered
    idle,
    /// Connection timeout triggered
    connection,
};

/// Tracks execution, idle, and connection timeouts for exec sessions.
pub const TimeoutTracker = struct {
    config: TimeoutConfig,
    start_ms: i64,
    last_activity_ms: i64,
    connection_established: bool = false,

    /// Initialize tracker with current timestamp.
    pub fn init(config: TimeoutConfig) TimeoutTracker {
        const now = std.time.milliTimestamp();
        return .{
            .config = config,
            .start_ms = now,
            .last_activity_ms = now,
        };
    }

    /// Mark that I/O activity occurred.
    pub fn markActivity(self: *TimeoutTracker) void {
        const now = std.time.milliTimestamp();
        self.last_activity_ms = now;
        self.connection_established = true;
    }

    /// Mark that connection is fully established without recording activity.
    pub fn markConnectionEstablished(self: *TimeoutTracker) void {
        self.connection_established = true;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Check if any timeout has been reached.
    pub fn check(self: *const TimeoutTracker) TimeoutEvent {
        const now = std.time.milliTimestamp();

        if (self.config.execution_ms > 0) {
            const elapsed = elapsedSince(self.start_ms, now);
            if (elapsed >= self.config.execution_ms) {
                return .execution;
            }
        }

        if (self.config.connection_ms > 0 and !self.connection_established) {
            const elapsed = elapsedSince(self.start_ms, now);
            if (elapsed >= self.config.connection_ms) {
                return .connection;
            }
        }

        if (self.config.idle_ms > 0) {
            const idle_elapsed = elapsedSince(self.last_activity_ms, now);
            if (idle_elapsed >= self.config.idle_ms) {
                return .idle;
            }
        }

        return .none;
    }

    /// Determine poll timeout until next deadline in milliseconds.
    pub fn nextPollTimeout(self: *const TimeoutTracker, base_timeout_ms: ?u32) ?u32 {
        const now = std.time.milliTimestamp();
        var minimum: ?u64 = if (base_timeout_ms) |base| @as(u64, base) else null;

        if (self.config.execution_ms > 0) {
            const elapsed = elapsedSince(self.start_ms, now);
            const remaining = if (elapsed >= self.config.execution_ms)
                0
            else
                @as(u64, self.config.execution_ms - elapsed);
            updateMinimum(&minimum, remaining);
        }

        if (self.config.connection_ms > 0 and !self.connection_established) {
            const elapsed = elapsedSince(self.start_ms, now);
            const remaining = if (elapsed >= self.config.connection_ms)
                0
            else
                @as(u64, self.config.connection_ms - elapsed);
            updateMinimum(&minimum, remaining);
        }

        if (self.config.idle_ms > 0) {
            const elapsed = elapsedSince(self.last_activity_ms, now);
            const remaining = if (elapsed >= self.config.idle_ms)
                0
            else
                @as(u64, self.config.idle_ms - elapsed);
            updateMinimum(&minimum, remaining);
        }

        return @intCast(minimum orelse (base_timeout_ms orelse 0));
    }
};

/// Compute elapsed milliseconds between timestamps, clamping to zero.
fn elapsedSince(start_ms: i64, now_ms: i64) u64 {
    if (now_ms <= start_ms) return 0;
    return @intCast(now_ms - start_ms);
}

/// Update minimum remaining time helper.
fn updateMinimum(current: *?u64, candidate: u64) void {
    if (current.*) |existing| {
        if (candidate < existing) {
            current.* = candidate;
        }
    } else {
        current.* = candidate;
    }
}

test "TimeoutTracker execution timeout" {
    const cfg = TimeoutConfig{
        .execution_ms = 50,
        .idle_ms = 0,
        .connection_ms = 0,
    };
    var tracker = TimeoutTracker.init(cfg);

    // Simulate time passing by sleeping
    std.Thread.sleep(60 * std.time.ns_per_ms);

    const event = tracker.check();
    try std.testing.expect(event == .execution);
}

test "TimeoutTracker idle timeout resets on activity" {
    const cfg = TimeoutConfig{
        .execution_ms = 1000,
        .idle_ms = 50,
        .connection_ms = 0,
    };
    var tracker = TimeoutTracker.init(cfg);

    std.Thread.sleep(30 * std.time.ns_per_ms);
    tracker.markActivity();
    std.Thread.sleep(30 * std.time.ns_per_ms);
    const event = tracker.check();
    try std.testing.expect(event == .none);
}
