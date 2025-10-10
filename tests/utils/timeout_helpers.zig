//! Timeout Test Helper Utilities
//! Provides utilities for testing timeout behavior in Zigcat
//!
//! This module offers:
//! - Test timeout wrappers to prevent hanging tests
//! - Mock servers with configurable delays
//! - Timer utilities for duration measurements
//! - Timeout assertion helpers

const std = @import("std");
const posix = std.posix;
const testing = std.testing;

/// Maximum time allowed for any single test (safety timeout)
pub const DEFAULT_TEST_TIMEOUT_MS: u32 = 10_000; // 10 seconds

/// Test timeout error
pub const TimeoutError = error{
    TestTimeout,
    SetupFailed,
    TeardownFailed,
};

/// Timer for measuring operation duration
pub const TestTimer = struct {
    start_time: i64,

    /// Start a new timer
    pub fn start() TestTimer {
        return .{
            .start_time = std.time.milliTimestamp(),
        };
    }

    /// Get elapsed time in milliseconds
    pub fn elapsed(self: *const TestTimer) u64 {
        const now = std.time.milliTimestamp();
        return @intCast(now - self.start_time);
    }

    /// Assert that operation completed within expected time
    pub fn assertWithinTimeout(self: *const TestTimer, expected_ms: u64, tolerance_ms: u64) !void {
        const actual_ms = self.elapsed();
        if (actual_ms < expected_ms - tolerance_ms or actual_ms > expected_ms + tolerance_ms) {
            std.debug.print(
                "Timing assertion failed: expected {}ms ± {}ms, got {}ms\n",
                .{ expected_ms, tolerance_ms, actual_ms },
            );
            return error.TimingMismatch;
        }
    }

    /// Assert that operation timed out as expected
    pub fn assertTimedOut(self: *const TestTimer, expected_timeout_ms: u64, tolerance_ms: u64) !void {
        const actual_ms = self.elapsed();
        const min_time = expected_timeout_ms - tolerance_ms;
        const max_time = expected_timeout_ms + tolerance_ms;

        if (actual_ms < min_time or actual_ms > max_time) {
            std.debug.print(
                "Timeout assertion failed: expected ~{}ms (±{}ms), got {}ms\n",
                .{ expected_timeout_ms, tolerance_ms, actual_ms },
            );
            return error.TimeoutMismatch;
        }
    }
};

/// Mock TCP server that can simulate various timeout scenarios
pub const MockTcpServer = struct {
    allocator: std.mem.Allocator,
    server_socket: posix.socket_t,
    server_thread: ?std.Thread,
    port: u16,
    behavior: ServerBehavior,
    should_stop: std.atomic.Value(bool),

    pub const ServerBehavior = enum {
        /// Accept connections immediately
        immediate_accept,
        /// Delay before accepting connection
        delayed_accept,
        /// Never accept (simulate hanging server)
        never_accept,
        /// Accept but never send data
        accept_no_send,
        /// Accept and send after delay
        accept_delayed_send,
        /// Accept, receive data but never respond
        accept_no_response,
    };

    pub const Config = struct {
        behavior: ServerBehavior = .immediate_accept,
        delay_ms: u32 = 0,
        bind_addr: []const u8 = "127.0.0.1",
    };

    /// Start a mock server on a random port
    pub fn start(allocator: std.mem.Allocator, cfg: Config) !*MockTcpServer {
        const server = try allocator.create(MockTcpServer);
        errdefer allocator.destroy(server);

        // Create listening socket
        server.server_socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(server.server_socket);

        // Set SO_REUSEADDR
        const reuse: c_int = 1;
        try posix.setsockopt(
            server.server_socket,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&reuse),
        );

        // Bind to port 0 (let OS choose)
        const addr = try std.net.Address.parseIp(cfg.bind_addr, 0);
        try posix.bind(server.server_socket, &addr.any, addr.getOsSockLen());

        // Get assigned port
        var sockaddr: std.net.Address = undefined;
        var sockaddr_len: posix.socklen_t = @sizeOf(std.net.Address);
        try posix.getsockname(server.server_socket, &sockaddr.any, &sockaddr_len);
        server.port = sockaddr.getPort();

        // Listen
        try posix.listen(server.server_socket, 5);

        // Initialize server
        server.* = .{
            .allocator = allocator,
            .server_socket = server.server_socket,
            .server_thread = null,
            .port = server.port,
            .behavior = cfg.behavior,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        // Start server thread
        server.server_thread = try std.Thread.spawn(.{}, serverLoop, .{ server, cfg.delay_ms });

        // Give server time to start
        std.Thread.sleep(50 * std.time.ns_per_ms);

        return server;
    }

    /// Server loop (runs in separate thread)
    fn serverLoop(self: *MockTcpServer, delay_ms: u32) void {
        while (!self.should_stop.load(.acquire)) {
            // Set timeout for accept
            var pollfds = [_]posix.pollfd{.{
                .fd = self.server_socket,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&pollfds, 100) catch continue;
            if (ready == 0) continue; // Timeout, check should_stop

            // CRITICAL: Check should_stop BEFORE accept() to prevent BADF panic
            // Socket might be closed between poll() and accept()
            if (self.should_stop.load(.acquire)) break;

            switch (self.behavior) {
                .immediate_accept => {
                    self.handleImmediateAccept() catch {};
                },
                .delayed_accept => {
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    self.handleImmediateAccept() catch {};
                },
                .never_accept => {
                    // Don't accept, just continue
                    continue;
                },
                .accept_no_send => {
                    const client = posix.accept(self.server_socket, null, null, 0) catch continue;
                    defer posix.close(client);
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                },
                .accept_delayed_send => {
                    const client = posix.accept(self.server_socket, null, null, 0) catch continue;
                    defer posix.close(client);
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    const msg = "OK\n";
                    _ = posix.write(client, msg) catch {};
                },
                .accept_no_response => {
                    const client = posix.accept(self.server_socket, null, null, 0) catch continue;
                    defer posix.close(client);
                    var buf: [1024]u8 = undefined;
                    _ = posix.read(client, &buf) catch {};
                    // Don't send response
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                },
            }
        }
    }

    fn handleImmediateAccept(self: *MockTcpServer) !void {
        // Check if server is being shut down before attempting accept
        // This prevents race condition where socket is closed between poll() and accept()
        if (self.should_stop.load(.acquire)) {
            return error.SocketClosed;
        }

        // CRITICAL: Cannot catch BADF error - posix.accept() marks it as unreachable
        // The should_stop check above prevents the race condition
        const client = try posix.accept(self.server_socket, null, null, 0);
        defer posix.close(client);

        const msg = "HELLO\n";
        _ = try posix.write(client, msg);
    }

    /// Stop the server and clean up
    pub fn stop(self: *MockTcpServer) void {
        // Signal thread to stop
        self.should_stop.store(true, .release);

        // Interrupt poll() by closing the socket before joining thread
        // This prevents race condition where thread is stuck in poll()
        posix.close(self.server_socket);

        // Wait for thread to complete with timeout protection
        if (self.server_thread) |thread| {
            // Thread should exit within ~100ms (poll timeout)
            // If it takes longer, there's a bug in the server loop
            thread.join();
        }

        self.allocator.destroy(self);
    }

    /// Get the server's listening port
    pub fn getPort(self: *const MockTcpServer) u16 {
        return self.port;
    }
};

/// Mock UDP server for testing UDP timeouts
pub const MockUdpServer = struct {
    allocator: std.mem.Allocator,
    server_socket: posix.socket_t,
    server_thread: ?std.Thread,
    port: u16,
    should_respond: bool,
    response_delay_ms: u32,
    should_stop: std.atomic.Value(bool),

    pub const Config = struct {
        should_respond: bool = true,
        response_delay_ms: u32 = 0,
        bind_addr: []const u8 = "127.0.0.1",
    };

    pub fn start(allocator: std.mem.Allocator, cfg: Config) !*MockUdpServer {
        const server = try allocator.create(MockUdpServer);
        errdefer allocator.destroy(server);

        // Create UDP socket
        server.server_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(server.server_socket);

        // Set SO_REUSEADDR
        const reuse: c_int = 1;
        try posix.setsockopt(
            server.server_socket,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&reuse),
        );

        // Bind to port 0
        const addr = try std.net.Address.parseIp(cfg.bind_addr, 0);
        try posix.bind(server.server_socket, &addr.any, addr.getOsSockLen());

        // Get assigned port
        var sockaddr: std.net.Address = undefined;
        var sockaddr_len: posix.socklen_t = @sizeOf(std.net.Address);
        try posix.getsockname(server.server_socket, &sockaddr.any, &sockaddr_len);
        server.port = sockaddr.getPort();

        server.* = .{
            .allocator = allocator,
            .server_socket = server.server_socket,
            .server_thread = null,
            .port = server.port,
            .should_respond = cfg.should_respond,
            .response_delay_ms = cfg.response_delay_ms,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        // Start server thread
        server.server_thread = try std.Thread.spawn(.{}, udpServerLoop, .{server});

        std.Thread.sleep(50 * std.time.ns_per_ms);

        return server;
    }

    fn udpServerLoop(self: *MockUdpServer) void {
        var buf: [4096]u8 = undefined;

        while (!self.should_stop.load(.acquire)) {
            var pollfds = [_]posix.pollfd{.{
                .fd = self.server_socket,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&pollfds, 100) catch continue;
            if (ready == 0) continue;

            var src_addr: std.net.Address = undefined;
            var src_len: posix.socklen_t = @sizeOf(std.net.Address);

            const n = posix.recvfrom(
                self.server_socket,
                &buf,
                0,
                &src_addr.any,
                &src_len,
            ) catch continue;

            if (!self.should_respond) continue;

            if (self.response_delay_ms > 0) {
                std.Thread.sleep(self.response_delay_ms * std.time.ns_per_ms);
            }

            // Echo back
            _ = posix.sendto(
                self.server_socket,
                buf[0..n],
                0,
                &src_addr.any,
                src_len,
            ) catch {};
        }
    }

    pub fn stop(self: *MockUdpServer) void {
        self.should_stop.store(true, .release);

        if (self.server_thread) |thread| {
            thread.join();
        }

        posix.close(self.server_socket);
        self.allocator.destroy(self);
    }

    pub fn getPort(self: *const MockUdpServer) u16 {
        return self.port;
    }
};

/// Wrapper to run a test function with a timeout
pub fn runWithTimeout(
    comptime testFn: anytype,
    timeout_ms: u32,
) !void {
    const TestResult = struct {
        result: ?anyerror,
        finished: std.atomic.Value(bool),
    };

    var test_result = TestResult{
        .result = null,
        .finished = std.atomic.Value(bool).init(false),
    };

    const TestRunner = struct {
        fn run(result: *TestResult) void {
            testFn() catch |err| {
                result.result = err;
            };
            result.finished.store(true, .release);
        }
    };

    const thread = try std.Thread.spawn(.{}, TestRunner.run, .{&test_result});

    const start = std.time.milliTimestamp();
    while (!test_result.finished.load(.acquire)) {
        std.Thread.sleep(10 * std.time.ns_per_ms);

        const elapsed = std.time.milliTimestamp() - start;
        if (elapsed > timeout_ms) {
            // Test timed out
            return TimeoutError.TestTimeout;
        }
    }

    thread.join();

    if (test_result.result) |err| {
        return err;
    }
}

/// Assert that a timeout error occurred
pub fn expectTimeout(err: anyerror) !void {
    if (err != error.ConnectionTimeout and
        err != error.Timeout and
        err != error.WouldBlock and
        err != error.TimedOut)
    {
        std.debug.print("Expected timeout error, got: {}\n", .{err});
        return error.ExpectedTimeout;
    }
}

/// Assert operation completes within expected time
pub fn assertCompletesWithin(
    comptime operation: anytype,
    expected_ms: u64,
    tolerance_ms: u64,
) !void {
    var timer = TestTimer.start();
    try operation();
    try timer.assertWithinTimeout(expected_ms, tolerance_ms);
}

/// Assert operation times out as expected
pub fn assertTimesOut(
    comptime operation: anytype,
    expected_timeout_ms: u64,
    tolerance_ms: u64,
) !void {
    var timer = TestTimer.start();
    const result = operation();
    if (result) |_| {
        return error.ExpectedTimeout;
    } else |err| {
        try expectTimeout(err);
        try timer.assertTimedOut(expected_timeout_ms, tolerance_ms);
    }
}
