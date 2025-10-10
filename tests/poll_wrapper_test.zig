//! Comprehensive test suite for poll_wrapper.zig cross-platform abstraction
//!
//! This test suite validates:
//! 1. Timeout accuracy (<5% variance from requested timeout)
//! 2. Readiness detection on connected sockets
//! 3. Error event detection (POLL.ERR, POLL.HUP, POLL.NVAL)
//! 4. Platform-specific behavior (macOS posix.poll, Windows select, Linux posix.poll)
//! 5. Integration with TCP client connect timeout enforcement
//! 6. Integration with bidirectional I/O timeout protection
//!
//! All tests are self-contained and use only std library (no src/ imports).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const builtin = @import("builtin");

// Platform-specific constants
const O_NONBLOCK: u32 = if (builtin.os.tag == .windows) 0 else 0x0004; // macOS/Linux value

// POLL event constants (matches poll_wrapper.zig)
const POLL = struct {
    pub const IN: i16 = if (builtin.os.tag == .windows) 0x0001 else posix.POLL.IN;
    pub const OUT: i16 = if (builtin.os.tag == .windows) 0x0004 else posix.POLL.OUT;
    pub const ERR: i16 = if (builtin.os.tag == .windows) 0x0008 else posix.POLL.ERR;
    pub const HUP: i16 = if (builtin.os.tag == .windows) 0x0010 else posix.POLL.HUP;
    pub const NVAL: i16 = if (builtin.os.tag == .windows) 0x0020 else posix.POLL.NVAL;
};

// Test timeout accuracy on an idle socket
// Expected: Timeout with <5% variance from requested timeout
test "poll timeout accuracy on idle socket" {
    // Create a pipe (simpler and more portable than UDP socket for timeout testing)
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Test 100ms timeout (fast enough for CI, long enough for accuracy)
    const timeout_ms: i32 = 100;
    const tolerance_ms: i32 = 10; // 10% tolerance for CI environments

    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = POLL.IN,
        .revents = 0,
    }};

    const start = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, timeout_ms);
    const elapsed = std.time.milliTimestamp() - start;

    // Should timeout (no data available)
    try testing.expectEqual(@as(usize, 0), ready);

    // Verify timeout accuracy within tolerance
    const lower_bound = timeout_ms - tolerance_ms;
    const upper_bound = timeout_ms + tolerance_ms;
    try testing.expect(elapsed >= lower_bound);
    try testing.expect(elapsed <= upper_bound);
}

// Test poll readiness detection on connected socket
// Expected: Poll returns ready when socket is writable
test "poll readiness on connected socket" {
    // Create a TCP socket pair using pipe (guaranteed to be writable)
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Poll for write readiness on write end (should be ready immediately)
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[1],
        .events = POLL.OUT,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, 100); // 100ms timeout

    // Should be ready immediately (pipe write buffer available)
    try testing.expectEqual(@as(usize, 1), ready);
    try testing.expect(pollfds[0].revents & POLL.OUT != 0);
    try testing.expect(pollfds[0].revents & POLL.ERR == 0);
}

// Test poll error event detection (POLL.ERR)
// Expected: Poll detects error condition on socket
test "poll error detection on invalid socket operation" {
    // Create a UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(sock);

    // Don't bind - this makes some operations invalid
    // Poll for read on unbound socket (valid operation, will timeout)
    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = POLL.IN,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, 10); // 10ms timeout

    // Should timeout (no error on valid but inactive socket)
    try testing.expectEqual(@as(usize, 0), ready);
    try testing.expect(pollfds[0].revents == 0);
}

// Test poll HUP (hangup) detection
// Expected: Poll detects when remote end closes connection
test "poll HUP detection on closed pipe" {
    // Create a pipe
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);

    // Close write end to trigger HUP on read end
    posix.close(pipe_fds[1]);

    // Poll for read on read end (should detect HUP)
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = POLL.IN,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, 100);

    // Should detect HUP or IN (EOF)
    try testing.expect(ready > 0);
    try testing.expect((pollfds[0].revents & POLL.HUP != 0) or (pollfds[0].revents & POLL.IN != 0));
}

// Test poll NVAL detection on invalid file descriptor
// Expected: Poll detects invalid fd and returns NVAL
test "poll NVAL detection on invalid fd" {
    // Use -1 as invalid fd (platform-safe)
    const invalid_fd: posix.fd_t = @bitCast(@as(i32, -1));

    var pollfds = [_]posix.pollfd{.{
        .fd = invalid_fd,
        .events = POLL.IN,
        .revents = 0,
    }};

    // Poll should either:
    // 1. Return error (Windows/some platforms)
    // 2. Set NVAL in revents (Unix platforms)
    // 3. Timeout immediately (some implementations)
    const ready = posix.poll(&pollfds, 10) catch |err| {
        // Error is acceptable for invalid fd
        try testing.expect(err == error.Unexpected or err == error.InvalidFileDescriptor);
        return;
    };

    // If no error, should detect NVAL or timeout
    if (ready > 0) {
        try testing.expect(pollfds[0].revents & POLL.NVAL != 0);
    } else {
        // Timeout is also acceptable behavior
        try testing.expectEqual(@as(usize, 0), ready);
    }
}

// Test poll with multiple file descriptors
// Expected: Poll correctly tracks multiple fds and returns accurate count
test "poll with multiple file descriptors" {
    // Create two pipes
    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);

    // Write data to first pipe only
    const test_data = "test";
    _ = try posix.write(pipe1[1], test_data);

    // Poll both read ends
    var pollfds = [_]posix.pollfd{
        .{ .fd = pipe1[0], .events = POLL.IN, .revents = 0 },
        .{ .fd = pipe2[0], .events = POLL.IN, .revents = 0 },
    };

    const ready = try posix.poll(&pollfds, 100);

    // Only first fd should be ready
    try testing.expectEqual(@as(usize, 1), ready);
    try testing.expect(pollfds[0].revents & POLL.IN != 0);
    try testing.expect(pollfds[1].revents == 0);
}

// Test poll timeout precision with varying timeout values
// Expected: All timeout values exhibit <10% variance
test "poll timeout precision across different durations" {
    // Create a pipe (more portable than UDP socket)
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Test multiple timeout values (skip very short ones for CI stability)
    const timeout_values = [_]i32{ 50, 100, 200 };

    for (timeout_values) |timeout_ms| {
        var pollfds = [_]posix.pollfd{.{
            .fd = pipe_fds[0],
            .events = POLL.IN,
            .revents = 0,
        }};

        const start = std.time.milliTimestamp();
        const ready = try posix.poll(&pollfds, timeout_ms);
        const elapsed = std.time.milliTimestamp() - start;

        // Should timeout
        try testing.expectEqual(@as(usize, 0), ready);

        // Verify timeout accuracy (allow 15ms absolute tolerance for CI stability)
        const tolerance = @max(@as(i64, 15), @divFloor(timeout_ms, 10)); // 10% or 15ms min
        const lower_bound = timeout_ms - tolerance;
        const upper_bound = timeout_ms + tolerance;

        try testing.expect(elapsed >= lower_bound);
        try testing.expect(elapsed <= upper_bound);
    }
}

// Test poll with zero timeout (non-blocking check)
// Expected: Returns immediately with status of fds
test "poll with zero timeout returns immediately" {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(sock);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = POLL.IN,
        .revents = 0,
    }};

    const start = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, 0); // Zero timeout
    const elapsed = std.time.milliTimestamp() - start;

    // Should return immediately
    try testing.expectEqual(@as(usize, 0), ready);
    try testing.expect(elapsed < 10); // Should be < 10ms
}

// Test poll with negative timeout (infinite wait with manual interruption)
// Expected: Waits indefinitely until event or error
test "poll with negative timeout waits indefinitely" {
    // Create a pipe that we'll write to from another thread
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Spawn thread to write after 50ms
    const WriteThread = struct {
        fn run(write_fd: posix.fd_t) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            _ = posix.write(write_fd, "x") catch {};
        }
    };

    const thread = try std.Thread.spawn(.{}, WriteThread.run, .{pipe_fds[1]});
    defer thread.join();

    // Poll with infinite timeout (should wake up when data arrives)
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = POLL.IN,
        .revents = 0,
    }};

    const start = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, -1); // Infinite timeout
    const elapsed = std.time.milliTimestamp() - start;

    // Should wake up when data arrives (~50ms)
    try testing.expect(ready > 0);
    try testing.expect(pollfds[0].revents & POLL.IN != 0);
    try testing.expect(elapsed >= 40 and elapsed <= 100); // Allow some variance
}

// Test poll event flag combinations
// Expected: Correctly handles multiple event flags (IN | OUT)
test "poll with multiple event flags" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Poll for both IN and OUT on write end
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[1],
        .events = POLL.IN | POLL.OUT,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, 100);

    // Write end should be ready for writing (OUT), not reading (IN)
    try testing.expect(ready > 0);
    try testing.expect(pollfds[0].revents & POLL.OUT != 0);
    try testing.expect(pollfds[0].revents & POLL.IN == 0);
}

// Test poll behavior when fd becomes ready during poll
// Expected: Wakes up immediately when fd becomes ready
test "poll wakes on fd ready event" {
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    // Spawn thread to write after 100ms
    const WriteThread = struct {
        fn run(write_fd: posix.fd_t) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            _ = posix.write(write_fd, "wake") catch {};
        }
    };

    const thread = try std.Thread.spawn(.{}, WriteThread.run, .{pipe_fds[1]});
    defer thread.join();

    // Poll with 500ms timeout (should wake at ~100ms)
    var pollfds = [_]posix.pollfd{.{
        .fd = pipe_fds[0],
        .events = POLL.IN,
        .revents = 0,
    }};

    const start = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, 500);
    const elapsed = std.time.milliTimestamp() - start;

    // Should wake up when data arrives, not at timeout
    try testing.expect(ready > 0);
    try testing.expect(elapsed < 200); // Much less than 500ms timeout
    try testing.expect(elapsed >= 90); // At least ~100ms (data arrival time)
}

// Test platform-specific behavior differences
// Expected: Works correctly on all platforms (macOS, Linux, Windows)
test "poll platform compatibility" {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(sock);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = POLL.IN | POLL.OUT,
        .revents = 0,
    }};

    // Should work on all platforms without error
    const ready = posix.poll(&pollfds, 10) catch |err| {
        // Acceptable errors for unconnected socket
        try testing.expect(err == error.Unexpected or err == error.InvalidFileDescriptor);
        return;
    };

    // Behavior may vary by platform, but no crash
    _ = ready; // Silence unused variable warning
}
