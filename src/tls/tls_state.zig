//! TLS connection state management with atomic thread-safe operations.
//!
//! This module provides state tracking for TLS connections with:
//! - State machine validation to prevent invalid transitions
//! - Atomic operations for thread-safe state updates
//! - State history logging for debugging handshake failures
//! - Integration with existing OpenSSL TLS implementation
//!
//! State Machine:
//! ```
//! uninitialized → handshaking → connected → closed
//!                       ↓
//!                   error_state
//! ```
//!
//! Thread Safety:
//! - Uses std.atomic.Value for lock-free state updates
//! - All transitions validated atomically via compareAndSwap
//! - Safe for concurrent reads and single-writer scenarios

const std = @import("std");
const logging = @import("../util/logging.zig");

/// TLS connection lifecycle states.
///
/// State transitions:
/// - uninitialized: Initial state, no SSL context created
/// - handshaking: TLS handshake in progress (SSL_connect/SSL_accept)
/// - connected: Handshake complete, ready for encrypted I/O
/// - error_state: Irrecoverable error (cert verification failed, etc.)
/// - closed: Connection closed gracefully (close_notify sent)
pub const TlsState = enum(u8) {
    uninitialized = 0,
    handshaking = 1,
    connected = 2,
    error_state = 3,
    closed = 4,

    /// Get human-readable state name for logging.
    pub fn toString(self: TlsState) []const u8 {
        return switch (self) {
            .uninitialized => "uninitialized",
            .handshaking => "handshaking",
            .connected => "connected",
            .error_state => "error",
            .closed => "closed",
        };
    }
};

/// TLS connection state tracker with atomic thread-safe operations.
///
/// **Usage:**
/// ```zig
/// var state_tracker = TlsConnectionState.init();
/// try state_tracker.transition(.uninitialized, .handshaking);
/// // ... perform handshake ...
/// try state_tracker.transition(.handshaking, .connected);
/// ```
///
/// **Thread Safety:**
/// Uses std.atomic.Value for lock-free concurrent access.
/// Safe for multiple readers and single writer pattern.
///
/// **History Tracking:**
/// Maintains last 8 state transitions for debugging.
/// Access via getHistory() for failure analysis.
pub const TlsConnectionState = struct {
    /// Current state (atomic for thread safety)
    current: std.atomic.Value(TlsState),

    /// State transition history (circular buffer, last 8 transitions)
    history: [8]StateTransition,
    history_index: usize,

    /// State transition record for debugging
    const StateTransition = struct {
        from: TlsState,
        to: TlsState,
        timestamp_ns: i128,
    };

    /// Initialize state tracker in uninitialized state.
    pub fn init() TlsConnectionState {
        return .{
            .current = std.atomic.Value(TlsState).init(.uninitialized),
            .history = [_]StateTransition{.{
                .from = .uninitialized,
                .to = .uninitialized,
                .timestamp_ns = 0,
            }} ** 8,
            .history_index = 0,
        };
    }

    /// Get current state (atomic read).
    ///
    /// **Thread Safety:** Safe for concurrent reads.
    pub fn get(self: *const TlsConnectionState) TlsState {
        return self.current.load(.acquire);
    }

    /// Attempt state transition with validation.
    ///
    /// **Parameters:**
    /// - expected: State we expect to transition from
    /// - new_state: State we want to transition to
    ///
    /// **Returns:**
    /// - error.InvalidStateTransition: Current state != expected
    /// - error.StateTransitionFailed: Concurrent modification detected
    ///
    /// **Thread Safety:**
    /// Uses compareAndSwap for atomic validation and update.
    /// Only one transition can succeed if multiple threads attempt.
    ///
    /// **Valid Transitions:**
    /// - uninitialized → handshaking
    /// - handshaking → connected
    /// - handshaking → error_state
    /// - connected → closed
    /// - connected → error_state
    /// - Any state → error_state (emergency fallback)
    pub fn transition(self: *TlsConnectionState, expected: TlsState, new_state: TlsState) !void {
        // Validate transition is allowed
        if (!isValidTransition(expected, new_state)) {
            logging.logDebug("Invalid TLS state transition: {s} → {s}\n", .{
                expected.toString(),
                new_state.toString(),
            });
            return error.InvalidStateTransition;
        }

        // Atomic compare-and-swap to ensure expected state
        const result = self.current.cmpxchgWeak(
            expected,
            new_state,
            .acq_rel, // Success ordering: acquire on read, release on write
            .acquire, // Failure ordering: acquire to read current value
        );

        if (result != null) {
            // Transition failed, state was not as expected
            const actual = result.?;
            logging.logDebug("TLS state transition failed: expected {s}, actual {s}\n", .{
                expected.toString(),
                actual.toString(),
            });
            return error.StateTransitionFailed;
        }

        // Record transition in history
        self.recordTransition(expected, new_state);

        logging.logDebug("TLS state transition: {s} → {s}\n", .{
            expected.toString(),
            new_state.toString(),
        });
    }

    /// Force state change without validation (use with caution).
    ///
    /// **Warning:** Bypasses state machine validation.
    /// Only use for error recovery or initialization.
    ///
    /// **Thread Safety:** Atomic write.
    pub fn set(self: *TlsConnectionState, new_state: TlsState) void {
        const old_state = self.current.swap(new_state, .acq_rel);
        self.recordTransition(old_state, new_state);

        logging.logDebug("TLS state forced: {s} → {s}\n", .{
            old_state.toString(),
            new_state.toString(),
        });
    }

    /// Check if state transition is valid according to state machine.
    fn isValidTransition(from: TlsState, to: TlsState) bool {
        // Allow any state → error_state (emergency fallback)
        if (to == .error_state) {
            return true;
        }

        return switch (from) {
            .uninitialized => to == .handshaking,
            .handshaking => to == .connected or to == .error_state,
            .connected => to == .closed or to == .error_state,
            .error_state => to == .closed, // Allow cleanup after error
            .closed => false, // Terminal state
        };
    }

    /// Record state transition in history buffer (circular).
    fn recordTransition(self: *TlsConnectionState, from: TlsState, to: TlsState) void {
        const index = self.history_index % self.history.len;
        self.history[index] = .{
            .from = from,
            .to = to,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
        self.history_index += 1;
    }

    /// Get state transition history for debugging.
    ///
    /// **Returns:** Slice of recent transitions (up to 8).
    ///
    /// **Usage:**
    /// ```zig
    /// const history = state_tracker.getHistory();
    /// for (history) |transition| {
    ///     logging.logDebug("  {s} → {s} at {d}ns\n", .{
    ///         transition.from.toString(),
    ///         transition.to.toString(),
    ///         transition.timestamp_ns,
    ///     });
    /// }
    /// ```
    pub fn getHistory(self: *const TlsConnectionState) []const StateTransition {
        const count = @min(self.history_index, self.history.len);
        if (count == 0) {
            return &[_]StateTransition{};
        }

        // Return most recent transitions (circular buffer)
        const start = if (self.history_index >= self.history.len)
            (self.history_index % self.history.len)
        else
            0;

        return self.history[start..][0..count];
    }

    /// Log current state and history for debugging.
    pub fn logState(self: *const TlsConnectionState) void {
        const current_state = self.get();
        logging.logDebug("TLS State: {s}\n", .{current_state.toString()});

        const history = self.getHistory();
        if (history.len > 0) {
            logging.logDebug("Recent transitions:\n", .{});
            for (history) |t| {
                logging.logDebug("  {s} → {s} at {d}ns\n", .{
                    t.from.toString(),
                    t.to.toString(),
                    t.timestamp_ns,
                });
            }
        }
    }
};

// Unit tests
const testing = std.testing;

test "TlsState toString" {
    try testing.expectEqualStrings("uninitialized", TlsState.uninitialized.toString());
    try testing.expectEqualStrings("handshaking", TlsState.handshaking.toString());
    try testing.expectEqualStrings("connected", TlsState.connected.toString());
    try testing.expectEqualStrings("error", TlsState.error_state.toString());
    try testing.expectEqualStrings("closed", TlsState.closed.toString());
}

test "TlsConnectionState init" {
    var state = TlsConnectionState.init();
    try testing.expectEqual(TlsState.uninitialized, state.get());
}

test "TlsConnectionState valid transitions" {
    var state = TlsConnectionState.init();

    // Valid: uninitialized → handshaking
    try state.transition(.uninitialized, .handshaking);
    try testing.expectEqual(TlsState.handshaking, state.get());

    // Valid: handshaking → connected
    try state.transition(.handshaking, .connected);
    try testing.expectEqual(TlsState.connected, state.get());

    // Valid: connected → closed
    try state.transition(.connected, .closed);
    try testing.expectEqual(TlsState.closed, state.get());
}

test "TlsConnectionState invalid transition" {
    var state = TlsConnectionState.init();

    // Invalid: uninitialized → connected (skip handshaking)
    const result = state.transition(.uninitialized, .connected);
    try testing.expectError(error.InvalidStateTransition, result);
    try testing.expectEqual(TlsState.uninitialized, state.get());
}

test "TlsConnectionState error state transition" {
    var state = TlsConnectionState.init();

    // Any state → error_state is allowed
    try state.transition(.uninitialized, .error_state);
    try testing.expectEqual(TlsState.error_state, state.get());
}

test "TlsConnectionState concurrent modification" {
    var state = TlsConnectionState.init();

    // Transition to handshaking
    try state.transition(.uninitialized, .handshaking);

    // Try to transition from wrong state (simulates concurrent modification)
    const result = state.transition(.uninitialized, .connected);
    try testing.expectError(error.StateTransitionFailed, result);
    try testing.expectEqual(TlsState.handshaking, state.get());
}

test "TlsConnectionState history tracking" {
    var state = TlsConnectionState.init();

    // Perform some transitions
    try state.transition(.uninitialized, .handshaking);
    try state.transition(.handshaking, .connected);

    const history = state.getHistory();
    try testing.expect(history.len >= 2);
    try testing.expectEqual(TlsState.uninitialized, history[0].from);
    try testing.expectEqual(TlsState.handshaking, history[0].to);
    try testing.expectEqual(TlsState.handshaking, history[1].from);
    try testing.expectEqual(TlsState.connected, history[1].to);
}

test "TlsConnectionState force set" {
    var state = TlsConnectionState.init();

    // Force set to connected (bypasses validation)
    state.set(.connected);
    try testing.expectEqual(TlsState.connected, state.get());

    // Verify history recorded the forced transition
    const history = state.getHistory();
    try testing.expect(history.len > 0);
}
