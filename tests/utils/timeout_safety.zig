//! Timeout Safety Utilities for Test Suite
//!
//! This module provides timeout protection wrappers for all test operations
//! to prevent test hangs. Every network operation and I/O operation should
//! use these wrappers to ensure tests never block indefinitely.
//!
//! USAGE:
//!   const safety = @import("utils/timeout_safety.zig");
//!   const result = try safety.withTimeout(my_operation, timeout_ms);

const std = @import("std");
const posix = std.posix;

/// Maximum allowed timeout for any test operation (5 minutes)
pub const MAX_TEST_TIMEOUT_MS: i32 = 5 * 60 * 1000;

/// Default timeout for test operations (30 seconds)
pub const DEFAULT_TEST_TIMEOUT_MS: i32 = 30 * 1000;

/// Minimum timeout to prevent instant failures (10ms)
pub const MIN_TIMEOUT_MS: i32 = 10;

/// Timeout error for test operations
pub const TimeoutError = error{
    TestTimeout,
    OperationTimeout,
    PollFailed,
};

/// Validate and clamp timeout value to safe range
pub fn validateTimeout(timeout_ms: i32) i32 {
    return @max(MIN_TIMEOUT_MS, @min(timeout_ms, MAX_TEST_TIMEOUT_MS));
}

/// Socket timeout wrapper - ensures socket operation has timeout protection
pub fn socketWithTimeout(
    sock: posix.socket_t,
    timeout_ms: i32,
    operation: enum { read, write, both },
) !void {
    const safe_timeout = validateTimeout(timeout_ms);

    const timeout_val = posix.timeval{
        .tv_sec = @divTrunc(safe_timeout, 1000),
        .tv_usec = @rem(safe_timeout, 1000) * 1000,
    };

    switch (operation) {
        .read, .both => {
            try posix.setsockopt(
                sock,
                posix.SOL.SOCKET,
                posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout_val),
            );
        },
        .write, .both => {
            try posix.setsockopt(
                sock,
                posix.SOL.SOCKET,
                posix.SO.SNDTIMEO,
                std.mem.asBytes(&timeout_val),
            );
        },
    }
}

/// Poll-based timeout wrapper for socket operations
pub fn pollWithTimeout(
    fds: []posix.pollfd,
    timeout_ms: i32,
) TimeoutError!usize {
    const safe_timeout = validateTimeout(timeout_ms);

    const ready = posix.poll(fds, safe_timeout) catch |err| {
        std.debug.print("Poll failed: {}\n", .{err});
        return TimeoutError.PollFailed;
    };

    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    return ready;
}

/// TCP connect with guaranteed timeout
pub fn tcpConnectWithTimeout(
    host: []const u8,
    port: u16,
    timeout_ms: i32,
) !posix.socket_t {
    const safe_timeout = validateTimeout(timeout_ms);

    const addr = try std.net.Address.parseIp4(host, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(sock);

    // Set non-blocking for timeout support
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | @as(u32, 0x0004)); // O_NONBLOCK

    // Attempt connection
    _ = posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock and err != error.InProgress) {
            return err;
        }
    };

    // Wait for connection with timeout
    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};

    const ready = try pollWithTimeout(&pollfds, safe_timeout);
    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    // Check if connection succeeded
    var connect_err: i32 = undefined;
    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&connect_err));

    if (connect_err != 0) {
        return error.ConnectionFailed;
    }

    return sock;
}

/// UDP receive with guaranteed timeout
pub fn udpRecvWithTimeout(
    sock: posix.socket_t,
    buffer: []u8,
    timeout_ms: i32,
) !usize {
    const safe_timeout = validateTimeout(timeout_ms);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try pollWithTimeout(&pollfds, safe_timeout);
    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    return try posix.recvfrom(sock, buffer, 0, null, null);
}

/// Read from socket with timeout protection
pub fn readWithTimeout(
    sock: posix.socket_t,
    buffer: []u8,
    timeout_ms: i32,
) !usize {
    const safe_timeout = validateTimeout(timeout_ms);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try pollWithTimeout(&pollfds, safe_timeout);
    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    return try posix.read(sock, buffer);
}

/// Write to socket with timeout protection
pub fn writeWithTimeout(
    sock: posix.socket_t,
    data: []const u8,
    timeout_ms: i32,
) !usize {
    const safe_timeout = validateTimeout(timeout_ms);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};

    const ready = try pollWithTimeout(&pollfds, safe_timeout);
    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    return try posix.write(sock, data);
}

/// Accept connection with timeout protection
pub fn acceptWithTimeout(
    listen_sock: posix.socket_t,
    timeout_ms: i32,
) !posix.socket_t {
    const safe_timeout = validateTimeout(timeout_ms);

    var pollfds = [_]posix.pollfd{.{
        .fd = listen_sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try pollWithTimeout(&pollfds, safe_timeout);
    if (ready == 0) {
        return TimeoutError.OperationTimeout;
    }

    return try posix.accept(listen_sock, null, null, 0);
}

/// Timer for measuring test execution time
pub const TestTimer = struct {
    start_time: i64,

    pub fn start() TestTimer {
        return .{
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn elapsed(self: *const TestTimer) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }

    /// Assert that operation took approximately the expected time
    pub fn assertTimedOut(self: *const TestTimer, expected_ms: i32, tolerance_ms: i32) !void {
        const elapsed_time = self.elapsed();
        const min_time = expected_ms - tolerance_ms;
        const max_time = expected_ms + tolerance_ms;

        if (elapsed_time < min_time or elapsed_time > max_time) {
            std.debug.print(
                "Timeout assertion failed: expected {}ms (±{}ms), got {}ms\n",
                .{ expected_ms, tolerance_ms, elapsed_time },
            );
            return error.TimeoutMismatch;
        }
    }
};

/// Test helper: Expect a timeout error
pub fn expectTimeout(err: anyerror) !void {
    const is_timeout = err == error.Timeout or
        err == error.ConnectionTimeout or
        err == error.WouldBlock or
        err == TimeoutError.OperationTimeout or
        err == TimeoutError.TestTimeout;

    if (!is_timeout) {
        std.debug.print("Expected timeout error, got: {}\n", .{err});
        return error.UnexpectedError;
    }
}

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;

test "validateTimeout - clamps to valid range" {
    try testing.expectEqual(@as(i32, MIN_TIMEOUT_MS), validateTimeout(0));
    try testing.expectEqual(@as(i32, MIN_TIMEOUT_MS), validateTimeout(-100));
    try testing.expectEqual(@as(i32, 1000), validateTimeout(1000));
    try testing.expectEqual(MAX_TEST_TIMEOUT_MS, validateTimeout(999999999));
}

test "TestTimer - measures elapsed time" {
    var timer = TestTimer.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);
    const elapsed_time = timer.elapsed();

    // Should be close to 100ms (±50ms tolerance)
    try testing.expect(elapsed_time >= 80 and elapsed_time <= 200);
}

test "pollWithTimeout - timeout on no activity" {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(sock);

    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const result = pollWithTimeout(&pollfds, 100);

    // Should timeout
    try testing.expectError(TimeoutError.OperationTimeout, result);
}
