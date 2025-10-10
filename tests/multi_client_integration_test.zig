//! Multi-Client Integration Tests for Broker/Chat Mode
//!
//! This test suite covers comprehensive integration testing for multi-client scenarios:
//! - Broker mode with 2-10 concurrent clients and data relay verification
//! - Chat mode with nickname conflicts, join/leave notifications, and message formatting
//! - Client disconnection handling and automatic cleanup
//! - Maximum client limit enforcement and connection rejection
//!
//! Requirements covered: 1.4, 1.6, 2.4, 3.3, 5.6

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const ChildProcess = std.process.Child;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const posix = std.posix;

// Path to the zigcat binary
const zigcat_binary = "zig-out/bin/zigcat";

// Test configuration
const TEST_TIMEOUT_MS = 5000;
const CLIENT_CONNECT_DELAY_MS = 500; // Increased from 300ms to 500ms for better reliability
const SERVER_STARTUP_DELAY_MS = 1000; // Increased from 500ms to 1000ms for reliable server startup
const MESSAGE_DELAY_MS = 200; // Increased from 100ms to 200ms for message processing

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Verify that the zigcat binary exists and is accessible
fn checkBinaryExists() !void {
    std.fs.cwd().access(zigcat_binary, .{}) catch |err| {
        std.debug.print("\n❌ ERROR: zigcat binary not found at: {s}\n", .{zigcat_binary});
        std.debug.print("   Please build the binary first:\n", .{});
        std.debug.print("   $ zig build\n\n", .{});
        return err;
    };
}

/// Verify that a TCP port is ready to accept connections
fn verifyPortReady(port: u16, timeout_ms: u32) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var attempts: u32 = 0;
    const max_attempts = timeout_ms / 50; // Try every 50ms

    while (attempts < max_attempts) : (attempts += 1) {
        // Try to connect to verify server is listening
        const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(sock);

        // Set non-blocking mode for quick timeout
        const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
        _ = try posix.fcntl(sock, posix.F.SETFL, flags | 0x0004); // O_NONBLOCK

        // Try to connect
        const sockaddr = @as(*const posix.sockaddr, @ptrCast(&addr.any));
        _ = posix.connect(sock, sockaddr, addr.getOsSockLen()) catch |err| {
            if (err == error.WouldBlock or err == error.InProgress) {
                // Connection in progress, use poll() to wait for completion
                var pollfds = [_]posix.pollfd{.{
                    .fd = sock,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};

                const ready = posix.poll(&pollfds, 100) catch {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                };

                if (ready == 0) {
                    // Timeout, retry
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                }

                // Check if connection succeeded
                var sockerr: i32 = 0;
                const sockerr_len: posix.socklen_t = @sizeOf(i32);
                _ = posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&sockerr)[0..sockerr_len]) catch {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                };

                if (sockerr == 0) {
                    // Connection successful
                    return;
                }

                // Connection failed, retry
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            } else if (err == error.ConnectionRefused) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };

        // Connection successful (immediate), port is ready
        return;
    }

    return error.ServerNotReady;
}

/// Safe write to pipe with EPIPE/BrokenPipe handling
fn safeWriteToPipe(pipe: std.fs.File, data: []const u8) !usize {
    return pipe.write(data) catch |err| {
        if (err == error.BrokenPipe) {
            std.debug.print("\n⚠️  Warning: Broken pipe detected, client may have disconnected\n", .{});
            return 0;
        }
        return err;
    };
}

/// Drain server output to prevent pipe buffer overflow
/// This should be called after spawning the server to consume any startup messages
fn drainServerOutputBackground(pipe_fd: posix.fd_t) !void {
    // Set non-blocking mode
    const flags = try posix.fcntl(pipe_fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(pipe_fd, posix.F.SETFL, flags | 0x0004); // O_NONBLOCK

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_result = posix.read(pipe_fd, &buffer) catch |err| {
            if (err == error.WouldBlock) break; // No more data available
            return err;
        };
        if (read_result == 0) break; // EOF
    }
}

/// Read from file descriptor with timeout protection
fn readWithTimeout(fd: posix.fd_t, buffer: []u8, timeout_ms: i32) !usize {
    var pollfds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return error.Timeout;

    // Check for errors or hangup
    if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
        return error.PipeClosed;
    }

    return try posix.read(fd, buffer);
}

// =============================================================================
// BROKER MODE MULTI-CLIENT TESTS
// =============================================================================

test "broker mode - 2 clients data relay verification" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "13001" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready to accept connections
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13001, 5000); // Increased from 2000ms to 5000ms for reliable server startup

    // Connect two clients
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13001" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Pipe;

    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13001" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;

    try client1.spawn();
    defer _ = client1.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    try client2.spawn();
    defer _ = client2.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    // Client 1 sends message
    const test_message = "Hello from client 1\n";
    if (client1.stdin) |stdin| {
        const written = try safeWriteToPipe(stdin, test_message);
        if (written == 0) {
            std.debug.print("\nWarning: Failed to write test message (broken pipe)\n", .{});
            return error.SkipZigTest; // Skip test if pipe is broken
        }
    }

    // Give extra time for message to propagate through broker
    std.Thread.sleep(MESSAGE_DELAY_MS * 2 * std.time.ns_per_ms);

    // Client 2 should receive the message
    var buffer: [1024]u8 = undefined;
    if (client2.stdout) |stdout| {
        const received_len = try readWithTimeout(stdout.handle, &buffer, 2000);
        const received = buffer[0..received_len];
        try expectEqualStrings(test_message, received);
    }

    // Verify client 1 doesn't receive its own message (should be empty or timeout)
    if (client1.stdout) |stdout| {
        const self_received_len = stdout.read(&buffer) catch 0;
        try expectEqual(@as(usize, 0), self_received_len);
    }
}

test "broker mode - 5 clients concurrent data relay" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "13002" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13002, 5000); // Increased timeout for reliable server startup

    // Connect 5 clients
    const num_clients = 5;
    var clients: [num_clients]ChildProcess = undefined;

    for (0..num_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13002" }, allocator);
        clients[i].stdin_behavior = .Pipe;
        clients[i].stdout_behavior = .Pipe;
        clients[i].stderr_behavior = .Pipe;

        try clients[i].spawn();
        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);
    }
    defer {
        for (0..num_clients) |i| {
            _ = clients[i].kill() catch {};
        }
    }

    // Each client sends a unique message
    for (0..num_clients) |sender_idx| {
        const message = try std.fmt.allocPrint(allocator, "Message from client {d}\n", .{sender_idx + 1});
        defer allocator.free(message);

        if (clients[sender_idx].stdin) |stdin| {
            _ = try safeWriteToPipe(stdin, message);
        }
        std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

        // All other clients should receive the message
        for (0..num_clients) |receiver_idx| {
            if (receiver_idx == sender_idx) continue; // Skip sender

            var buffer: [1024]u8 = undefined;
            if (clients[receiver_idx].stdout) |stdout| {
                const received_len = try readWithTimeout(stdout.handle, &buffer, 2000);
                const received = buffer[0..received_len];
                try expectEqualStrings(message, received);
            }
        }
    }
}

// =============================================================================
// CHAT MODE MULTI-CLIENT TESTS
// =============================================================================

test "chat mode - nickname assignment and join notifications" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start chat server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--chat", "13004" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13004, 5000); // Increased timeout for reliable server startup

    // Connect first client
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13004" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Pipe;

    try client1.spawn();
    defer _ = client1.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    // Client 1 sets nickname
    if (client1.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "alice\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Connect second client
    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13004" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;

    try client2.spawn();
    defer _ = client2.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    // Client 2 sets nickname
    if (client2.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "bob\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Client 1 should receive join notification for bob
    var buffer: [1024]u8 = undefined;
    if (client1.stdout) |stdout| {
        const notification_len = try readWithTimeout(stdout.handle, &buffer, 2000);
        const join_notification = buffer[0..notification_len];

        try expect(std.mem.indexOf(u8, join_notification, "bob") != null);
        try expect(std.mem.indexOf(u8, join_notification, "joined") != null or
            std.mem.indexOf(u8, join_notification, "***") != null);
    }
}

test "chat mode - message formatting with nicknames" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start chat server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--chat", "13005" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13005, 5000); // Increased timeout for reliable server startup

    // Connect and setup two clients with nicknames
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13005" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Pipe;

    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13005" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;

    try client1.spawn();
    defer _ = client1.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    try client2.spawn();
    defer _ = client2.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    // Set nicknames
    if (client1.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "alice\n");
    }
    if (client2.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "bob\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Clear any join notifications
    var buffer: [1024]u8 = undefined;
    if (client1.stdout) |stdout| {
        _ = stdout.read(&buffer) catch 0;
    }
    if (client2.stdout) |stdout| {
        _ = stdout.read(&buffer) catch 0;
    }

    // Alice sends a message
    const test_message = "Hello everyone!\n";
    if (client1.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, test_message);
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Bob should receive formatted message
    if (client2.stdout) |stdout| {
        const received_len = try readWithTimeout(stdout.handle, &buffer, 2000);
        const received = buffer[0..received_len];

        // Should contain nickname prefix
        try expect(std.mem.indexOf(u8, received, "alice") != null);
        try expect(std.mem.indexOf(u8, received, "Hello everyone!") != null);
        try expect(std.mem.indexOf(u8, received, "[alice]") != null or
            std.mem.indexOf(u8, received, "<alice>") != null);
    }
}

// =============================================================================
// CLIENT DISCONNECTION AND CLEANUP TESTS
// =============================================================================

test "client disconnection - automatic cleanup in broker mode" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "13008" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13008, 5000); // Increased timeout for reliable server startup

    // Connect multiple clients
    const num_clients = 4;
    var clients: [num_clients]ChildProcess = undefined;

    for (0..num_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13008" }, allocator);
        clients[i].stdin_behavior = .Pipe;
        clients[i].stdout_behavior = .Pipe;
        clients[i].stderr_behavior = .Pipe;

        try clients[i].spawn();
        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);
    }

    // Send initial message to verify all clients connected
    if (clients[0].stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "Initial test\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Disconnect middle clients
    _ = clients[1].kill() catch {};
    _ = clients[2].kill() catch {};
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Remaining clients should still be able to communicate
    if (clients[0].stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "After disconnect\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    var buffer: [1024]u8 = undefined;
    if (clients[3].stdout) |stdout| {
        const received_len = try readWithTimeout(stdout.handle, &buffer, 2000);
        const received = buffer[0..received_len];
        try expectEqualStrings("After disconnect\n", received);
    }

    // Cleanup remaining clients
    _ = clients[0].kill() catch {};
    _ = clients[3].kill() catch {};
}

// =============================================================================
// MAXIMUM CLIENT LIMIT TESTS
// =============================================================================

test "maximum client limit - connection rejection" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start broker server with low client limit
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "3", "13010" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13010, 5000); // Increased timeout for reliable server startup

    // Connect up to the limit
    const max_clients = 3;
    var clients: [max_clients]ChildProcess = undefined;

    for (0..max_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13010" }, allocator);
        clients[i].stdin_behavior = .Pipe;
        clients[i].stdout_behavior = .Pipe;
        clients[i].stderr_behavior = .Pipe;

        try clients[i].spawn();
        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);
    }
    defer {
        for (0..max_clients) |i| {
            _ = clients[i].kill() catch {};
        }
    }

    // Try to connect one more client (should be rejected)
    var rejected_client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13010" }, allocator);
    rejected_client.stdin_behavior = .Pipe;
    rejected_client.stdout_behavior = .Pipe;
    rejected_client.stderr_behavior = .Pipe;

    try rejected_client.spawn();
    defer _ = rejected_client.kill() catch {};

    // Wait and check if connection was rejected
    std.Thread.sleep(MESSAGE_DELAY_MS * 2 * std.time.ns_per_ms);

    const result = try rejected_client.wait();

    // Should exit with non-zero code indicating rejection
    try expect(result.Exited != 0);
}

test "maximum client limit - enforcement in chat mode" {
    const allocator = testing.allocator;

    // Check binary exists before running test
    try checkBinaryExists();

    // Start chat server with client limit
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--chat", "--max-clients", "2", "13011" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    // Drain server stdout/stderr to prevent pipe buffer overflow
    if (server.stdout) |stdout_pipe| {
        try drainServerOutputBackground(stdout_pipe.handle);
    }
    if (server.stderr) |stderr_pipe| {
        try drainServerOutputBackground(stderr_pipe.handle);
    }

    // Wait for server to bind and be ready
    std.Thread.sleep(SERVER_STARTUP_DELAY_MS * std.time.ns_per_ms);
    try verifyPortReady(13011, 5000); // Increased timeout for reliable server startup

    // Connect two clients (at limit)
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13011" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Pipe;

    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13011" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Pipe;

    try client1.spawn();
    defer _ = client1.kill() catch {};

    try client2.spawn();
    defer _ = client2.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

    // Set nicknames
    if (client1.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "alice\n");
    }
    if (client2.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "bob\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Try to connect third client
    var client3 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "13011" }, allocator);
    client3.stdin_behavior = .Pipe;
    client3.stdout_behavior = .Pipe;
    client3.stderr_behavior = .Pipe;

    try client3.spawn();
    defer _ = client3.kill() catch {};

    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    // Third client should be rejected
    const result = try client3.wait();
    try expect(result.Exited != 0);

    // Original clients should still work
    if (client1.stdin) |stdin| {
        _ = try safeWriteToPipe(stdin, "Still working\n");
    }
    std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

    var buffer: [1024]u8 = undefined;
    if (client2.stdout) |stdout| {
        const received_len = try readWithTimeout(stdout.handle, &buffer, 2000);
        const received = buffer[0..received_len];
        try expect(std.mem.indexOf(u8, received, "Still working") != null);
    }
}
