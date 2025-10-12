// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Flow control state machine for exec session buffers.
//!
//! Implements a pause/resume mechanism to prevent unbounded memory growth when
//! one side of the connection produces data faster than the other can consume it.
const std = @import("std");

/// Flow control state machine for exec session buffers.
///
/// When the total buffered bytes exceed `pause_threshold_bytes`, reading from
/// both socket and child process is paused. Reading resumes when buffered bytes
/// drop below `resume_threshold_bytes`.
pub const FlowState = struct {
    pause_threshold_bytes: usize,
    resume_threshold_bytes: usize,
    paused: bool = false,

    /// Update state based on current buffered byte count.
    pub fn update(self: *FlowState, buffered_bytes: usize) void {
        if (!self.paused and buffered_bytes >= self.pause_threshold_bytes) {
            self.paused = true;
        } else if (self.paused and buffered_bytes <= self.resume_threshold_bytes) {
            self.paused = false;
        }
    }

    /// Whether flow control currently pauses new reads.
    pub fn shouldPause(self: *const FlowState) bool {
        return self.paused;
    }
};

/// Compute flow control threshold in bytes from percentage.
///
/// Converts a percentage (0.0-1.0) of max_total bytes into an absolute byte count.
/// Clamps result to valid range [0, max_total].
pub fn computeThresholdBytes(max_total: usize, percent: f32) usize {
    if (max_total == 0) return 0;

    // Clamp percentage to [0.0, 1.0]
    var clamped = percent;
    if (clamped < 0.0) clamped = 0.0;
    if (clamped > 1.0) clamped = 1.0;

    const total_f64 = @as(f64, @floatFromInt(max_total));
    const raw = total_f64 * @as(f64, clamped);
    var threshold: usize = @intFromFloat(raw);

    // Ensure at least 1 byte if percent > 0
    if (threshold == 0 and clamped > 0.0) threshold = 1;

    // Cap at max_total
    if (threshold > max_total) threshold = max_total;

    return threshold;
}

// ========================================================================
// Tests
// ========================================================================

test "FlowState pauses at threshold" {
    const testing = std.testing;
    var flow = FlowState{
        .pause_threshold_bytes = 100,
        .resume_threshold_bytes = 50,
    };

    // Below threshold - not paused
    flow.update(99);
    try testing.expect(!flow.shouldPause());

    // At threshold - paused
    flow.update(100);
    try testing.expect(flow.shouldPause());

    // Above threshold - still paused
    flow.update(150);
    try testing.expect(flow.shouldPause());

    // Drop to resume threshold - resumes (no hysteresis, == triggers resume)
    flow.update(50);
    try testing.expect(!flow.shouldPause());

    // Drop below resume threshold - resumed
    flow.update(49);
    try testing.expect(!flow.shouldPause());
}

test "computeThresholdBytes valid percentages" {
    const testing = std.testing;

    // 0% of 100 = 0
    try testing.expectEqual(@as(usize, 0), computeThresholdBytes(100, 0.0));

    // 50% of 100 = 50
    try testing.expectEqual(@as(usize, 50), computeThresholdBytes(100, 0.5));

    // 100% of 100 = 100
    try testing.expectEqual(@as(usize, 100), computeThresholdBytes(100, 1.0));

    // 85% of 256KB = 222822 (0.85 * 262144)
    try testing.expectEqual(@as(usize, 222822), computeThresholdBytes(256 * 1024, 0.85));
}

test "computeThresholdBytes clamps invalid percentages" {
    const testing = std.testing;

    // Negative percent clamped to 0
    try testing.expectEqual(@as(usize, 0), computeThresholdBytes(100, -0.5));

    // > 1.0 percent clamped to max_total
    try testing.expectEqual(@as(usize, 100), computeThresholdBytes(100, 1.5));
}

test "computeThresholdBytes zero max_total" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), computeThresholdBytes(0, 0.5));
}

test "computeThresholdBytes ensures minimum 1 byte for non-zero percent" {
    const testing = std.testing;

    // Very small max with non-zero percent should return at least 1
    try testing.expectEqual(@as(usize, 1), computeThresholdBytes(10, 0.01));
}
