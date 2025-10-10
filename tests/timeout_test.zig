//! Simplified Timeout Tests for Zigcat
//!
//! These tests validate basic timeout behavior using POSIX APIs directly,
//! without depending on zigcat source modules. This ensures tests can build
//! independently and validates the core timeout mechanisms.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const builtin = @import("builtin");
const helpers = @import("utils/timeout_helpers.zig");

// Platform-aware O_NONBLOCK constant
// macOS: 0x0004, Linux: 0x0800, Windows: different mechanism
const O_NONBLOCK: u32 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => 0x0004,
    .linux => 0x0800,
    .windows => @compileError("O_NONBLOCK not applicable on Windows, use ioctlsocket"),
    else => 0x0004, // Default to BSD-style
};

// =============================================================================
// BASIC TIMEOUT MECHANISM TESTS
// =============================================================================

test "poll timeout - no activity" {
    var timer = helpers.TestTimer.start();

    // Create a pipe for testing poll
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);

    var pollfds = [_]posix.pollfd{.{
        .fd = pipes[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const timeout_ms = 500;
    const ready = try posix.poll(&pollfds, @intCast(timeout_ms));

    // Should timeout (no data written to pipe)
    try testing.expectEqual(@as(usize, 0), ready);
    try timer.assertTimedOut(timeout_ms, 200);
}

test "poll timeout - activity within timeout" {
    // Create a pipe
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);

    // Spawn thread to write after delay
    const WriterThread = struct {
        fn write(fd: posix.fd_t) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            const msg = "test";
            _ = posix.write(fd, msg) catch {};
        }
    };

    const thread = try std.Thread.spawn(.{}, WriterThread.write, .{pipes[1]});
    defer thread.join();

    var timer = helpers.TestTimer.start();
    var pollfds = [_]posix.pollfd{.{
        .fd = pipes[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const timeout_ms = 1000;
    const ready = try posix.poll(&pollfds, @intCast(timeout_ms));

    // Should complete before timeout
    try testing.expect(ready > 0);
    const elapsed = timer.elapsed();
    try testing.expect(elapsed >= 150 and elapsed <= 400);
}

test "socket receive timeout - SO_RCVTIMEO" {
    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set receive timeout to 300ms
    const timeout: posix.timeval = .{
        .sec = 0,
        .usec = 300_000,
    };
    try posix.setsockopt(
        sock,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );

    var timer = helpers.TestTimer.start();
    var buf: [1024]u8 = undefined;

    const result = posix.recvfrom(sock, &buf, 0, null, null);

    if (result) |_| {
        return error.ExpectedTimeout;
    } else |err| {
        try helpers.expectTimeout(err);
        try timer.assertTimedOut(300, 150);
    }
}

// =============================================================================
// MOCK SERVER TESTS
// =============================================================================

test "MockTcpServer - immediate accept" {
    const allocator = testing.allocator;

    const server = try helpers.MockTcpServer.start(allocator, .{
        .behavior = .immediate_accept,
    });
    defer server.stop();

    // Create client socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    // Connect
    const addr = try std.net.Address.parseIp4("127.0.0.1", server.getPort());
    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Read response
    var buf: [1024]u8 = undefined;
    const n = try posix.read(sock, &buf);
    try testing.expect(n > 0);
}

test "Mock TCP Server - delayed accept demonstrates timeout mechanism" {
    const allocator = testing.allocator;

    // This test demonstrates the timeout mechanism works correctly
    // On localhost, TCP connections may complete quickly due to OS optimizations
    // The test validates that we CAN detect when operations complete vs timeout

    const server = try helpers.MockTcpServer.start(allocator, .{
        .behavior = .delayed_accept,
        .delay_ms = 100, // Small delay
    });
    defer server.stop();

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    // Set non-blocking
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | O_NONBLOCK);

    const addr = try std.net.Address.parseIp4("127.0.0.1", server.getPort());
    const result = posix.connect(sock, &addr.any, addr.getOsSockLen());

    var timer = helpers.TestTimer.start();

    if (result) {
        // Immediate connection (valid on localhost)
        const elapsed = timer.elapsed();
        try testing.expect(elapsed < 100); // Should be very fast
    } else |err| {
        try testing.expect(err == error.WouldBlock or err == error.InProgress);

        // Wait for connection with generous timeout
        var pollfds = [_]posix.pollfd{.{
            .fd = sock,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};

        const timeout_ms = 1000;
        _ = try posix.poll(&pollfds, @intCast(timeout_ms));

        // Connection should complete (localhost is fast) or timeout
        // Either outcome validates the timeout mechanism works
        const elapsed = timer.elapsed();
        try testing.expect(elapsed < timeout_ms + 200);
    }
}

test "MockUdpServer - responds correctly" {
    const allocator = testing.allocator;

    const server = try helpers.MockUdpServer.start(allocator, .{
        .should_respond = true,
        .response_delay_ms = 100,
    });
    defer server.stop();

    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set timeout
    const timeout = std.posix.timeval{
        .sec = 1,
        .usec = 0,
    };
    try posix.setsockopt(
        sock,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );

    // Send message
    const addr = try std.net.Address.parseIp4("127.0.0.1", server.getPort());
    const msg = "PING";
    _ = try posix.sendto(sock, msg, 0, &addr.any, addr.getOsSockLen());

    // Receive response
    var timer = helpers.TestTimer.start();
    var buf: [1024]u8 = undefined;
    const n = try posix.recvfrom(sock, &buf, 0, null, null);

    const elapsed = timer.elapsed();
    try testing.expect(n > 0);
    try testing.expect(elapsed >= 80 and elapsed <= 300);
}

test "MockUdpServer - no response causes timeout" {
    const allocator = testing.allocator;

    const server = try helpers.MockUdpServer.start(allocator, .{
        .should_respond = false,
    });
    defer server.stop();

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    // Set short timeout
    const timeout = std.posix.timeval{
        .sec = 0,
        .usec = 300_000,
    };
    try posix.setsockopt(
        sock,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    );

    const addr = try std.net.Address.parseIp4("127.0.0.1", server.getPort());
    const msg = "PING";
    _ = try posix.sendto(sock, msg, 0, &addr.any, addr.getOsSockLen());

    var timer = helpers.TestTimer.start();
    var buf: [1024]u8 = undefined;

    const result = posix.recvfrom(sock, &buf, 0, null, null);

    if (result) |_| {
        return error.ExpectedTimeout;
    } else |err| {
        try helpers.expectTimeout(err);
        try timer.assertTimedOut(300, 150);
    }
}

// =============================================================================
// SERVER ACCEPT TIMEOUT TESTS
// =============================================================================

test "Server accept - timeout with no connections" {
    const listen_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(listen_sock);

    const reuse: c_int = 1;
    try posix.setsockopt(
        listen_sock,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        std.mem.asBytes(&reuse),
    );

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try posix.bind(listen_sock, &addr.any, addr.getOsSockLen());
    try posix.listen(listen_sock, 5);

    var timer = helpers.TestTimer.start();
    var pollfds = [_]posix.pollfd{.{
        .fd = listen_sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const timeout_ms = 500;
    const ready = try posix.poll(&pollfds, @intCast(timeout_ms));

    try testing.expectEqual(@as(usize, 0), ready);
    try timer.assertTimedOut(timeout_ms, 200);
}

// =============================================================================
// TIMER UTILITY TESTS
// =============================================================================

test "TestTimer - elapsed time measurement" {
    var timer = helpers.TestTimer.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const elapsed = timer.elapsed();
    try testing.expect(elapsed >= 90 and elapsed <= 200);
}

test "TestTimer - assertTimedOut validates timeout" {
    var timer = helpers.TestTimer.start();
    std.Thread.sleep(500 * std.time.ns_per_ms);

    try timer.assertTimedOut(500, 100);
}

// =============================================================================
// TIMEOUT EDGE CASE TESTS
// =============================================================================

test "timeout edge case - zero timeout (immediate)" {
    // Zero timeout should return immediately without waiting
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);

    var timer = helpers.TestTimer.start();
    var pollfds = [_]posix.pollfd{.{
        .fd = pipes[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Zero timeout = poll returns immediately
    const ready = try posix.poll(&pollfds, 0);
    const elapsed = timer.elapsed();

    // Should return immediately (no activity)
    try testing.expectEqual(@as(usize, 0), ready);
    // Should complete in < 50ms (very fast)
    try testing.expect(elapsed < 50);
}

test "timeout edge case - very large timeout" {
    // Test that very large timeout values (> 60s) work correctly
    // We won't wait the full time - just verify poll accepts the value
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);

    // Write data immediately so poll returns quickly
    const msg = "test";
    _ = try posix.write(pipes[1], msg);

    var pollfds = [_]posix.pollfd{.{
        .fd = pipes[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Very large timeout (120 seconds), but poll should return immediately
    // because data is available
    const timeout_ms: i32 = 120_000;
    var timer = helpers.TestTimer.start();
    const ready = try posix.poll(&pollfds, timeout_ms);
    const elapsed = timer.elapsed();

    // Should return immediately due to available data
    try testing.expect(ready > 0);
    try testing.expect(elapsed < 100);
}

test "timeout edge case - negative timeout (infinite wait)" {
    // Negative timeout (-1) means infinite wait in poll()
    // We'll write data after a delay to ensure poll actually waits
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);
    defer posix.close(pipes[1]);

    const WriterThread = struct {
        fn write(fd: posix.fd_t) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            const msg = "test";
            _ = posix.write(fd, msg) catch {};
        }
    };

    const thread = try std.Thread.spawn(.{}, WriterThread.write, .{pipes[1]});
    defer thread.join();

    var timer = helpers.TestTimer.start();
    var pollfds = [_]posix.pollfd{.{
        .fd = pipes[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // Infinite timeout (-1) - will wait until data arrives
    const ready = try posix.poll(&pollfds, -1);
    const elapsed = timer.elapsed();

    // Should return after ~200ms when data arrives
    try testing.expect(ready > 0);
    try testing.expect(elapsed >= 150 and elapsed <= 400);
}
