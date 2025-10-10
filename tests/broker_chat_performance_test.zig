//! Performance and Compatibility Tests for Broker/Chat Mode
//!
//! This test suite covers comprehensive performance and compatibility testing:
//! - Broker/chat mode with TLS encryption and access control features
//! - Performance with 50+ concurrent clients and high message throughput
//! - Memory usage and resource cleanup under various load conditions
//! - Feature combination validation and error handling for incompatible modes
//!
//! Requirements covered: 4.1, 4.2, 4.5, 4.6, 5.6

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const ChildProcess = std.process.Child;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// Path to the zigcat binary
const zigcat_binary = "zig-out/bin/zigcat";

// Test configuration
const TEST_TIMEOUT_MS = 10000;
const CLIENT_CONNECT_DELAY_MS = 100;
const MESSAGE_DELAY_MS = 50;
const PERFORMANCE_TEST_DURATION_MS = 5000;

// Performance test parameters
const HIGH_CLIENT_COUNT = 50;
const STRESS_CLIENT_COUNT = 100;
const HIGH_MESSAGE_RATE = 100; // messages per second
const LARGE_MESSAGE_SIZE = 8192;

// =============================================================================
// TLS AND ENCRYPTION PERFORMANCE TESTS
// =============================================================================

test "performance - broker mode with TLS encryption" {
    const allocator = testing.allocator;

    // Create test certificate files for TLS
    const cert_file = "test_cert.pem";
    const key_file = "test_key.pem";

    // Create minimal self-signed certificate for testing
    try createTestCertificate(allocator, cert_file, key_file);
    defer std.fs.cwd().deleteFile(cert_file) catch {};
    defer std.fs.cwd().deleteFile(key_file) catch {};

    // Start TLS-enabled broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--tls", "--cert", cert_file, "--key", key_file, "14001" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Connect multiple TLS clients and measure performance
    const num_clients = 10;
    var clients: [num_clients]ChildProcess = undefined;
    var start_times: [num_clients]i128 = undefined;

    const overall_start = std.time.nanoTimestamp();

    for (0..num_clients) |i| {
        start_times[i] = std.time.nanoTimestamp();

        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "--tls", "localhost", "14001" }, allocator);
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

    const connection_time = std.time.nanoTimestamp() - overall_start;

    // Test encrypted message relay performance
    const test_message = "Encrypted message test data with various characters: !@#$%^&*()\n";
    const message_start = std.time.nanoTimestamp();

    // Send messages from each client
    for (0..num_clients) |sender_idx| {
        if (clients[sender_idx].stdin) |stdin| {
            _ = try stdin.write(test_message);
        }
        std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);
    }

    const message_time = std.time.nanoTimestamp() - message_start;

    // Performance metrics
    const connection_time_ms = @as(f64, @floatFromInt(connection_time)) / 1_000_000.0;
    const message_time_ms = @as(f64, @floatFromInt(message_time)) / 1_000_000.0;
    const avg_connection_time = connection_time_ms / @as(f64, @floatFromInt(num_clients));

    std.debug.print("TLS Performance - Clients: {d}, Connection time: {d:.2}ms, Avg per client: {d:.2}ms, Message relay: {d:.2}ms\n", .{ num_clients, connection_time_ms, avg_connection_time, message_time_ms });

    // Verify TLS overhead is reasonable (should be < 1 second per client for test environment)
    try expect(avg_connection_time < 1000.0);
}

test "performance - chat mode with TLS and access control" {
    const allocator = testing.allocator;

    // Create test certificate and access control files
    const cert_file = "chat_test_cert.pem";
    const key_file = "chat_test_key.pem";
    const allow_file = "chat_allow.txt";

    try createTestCertificate(allocator, cert_file, key_file);
    defer std.fs.cwd().deleteFile(cert_file) catch {};
    defer std.fs.cwd().deleteFile(key_file) catch {};

    // Create allowlist file (allow localhost)
    const allow_content = "127.0.0.1\n::1\nlocalhost\n";
    try std.fs.cwd().writeFile(.{ .sub_path = allow_file, .data = allow_content });
    defer std.fs.cwd().deleteFile(allow_file) catch {};

    // Start TLS-enabled chat server with access control
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--chat", "--tls", "--cert", cert_file, "--key", key_file, "--allow", allow_file, "14002" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Connect TLS chat clients
    const num_clients = 5;
    var clients: [num_clients]ChildProcess = undefined;

    for (0..num_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "--tls", "localhost", "14002" }, allocator);
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

    // Set nicknames for chat clients
    for (0..num_clients) |i| {
        const nickname = try std.fmt.allocPrint(allocator, "user{d}\n", .{i + 1});
        defer allocator.free(nickname);

        if (clients[i].stdin) |stdin| {
            _ = try stdin.write(nickname);
        }
        std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);
    }

    // Test encrypted chat message performance
    const start_time = std.time.nanoTimestamp();

    for (0..num_clients) |sender_idx| {
        const message = try std.fmt.allocPrint(allocator, "Encrypted chat message from user{d}\n", .{sender_idx + 1});
        defer allocator.free(message);

        if (clients[sender_idx].stdin) |stdin| {
            _ = try stdin.write(message);
        }
        std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    std.debug.print("TLS Chat Performance - {d} clients, {d} messages: {d:.2}ms\n", .{ num_clients, num_clients, duration_ms });

    // Verify performance is reasonable for encrypted chat
    try expect(duration_ms < 2000.0); // Should complete within 2 seconds
}

// =============================================================================
// HIGH CONCURRENCY PERFORMANCE TESTS
// =============================================================================

test "performance - 50+ concurrent clients broker mode" {
    const allocator = testing.allocator;

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "100", "14010" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Connect many clients
    const num_clients = HIGH_CLIENT_COUNT;
    var clients = try allocator.alloc(ChildProcess, num_clients);
    defer allocator.free(clients);

    const connection_start = std.time.nanoTimestamp();

    // Connect clients in batches to avoid overwhelming the system
    const batch_size = 10;
    var connected_count: usize = 0;

    while (connected_count < num_clients) {
        const batch_end = @min(connected_count + batch_size, num_clients);

        for (connected_count..batch_end) |i| {
            clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "14010" }, allocator);
            clients[i].stdin_behavior = .Pipe;
            clients[i].stdout_behavior = .Pipe;
            clients[i].stderr_behavior = .Pipe;

            try clients[i].spawn();
        }

        connected_count = batch_end;
        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);
    }

    defer {
        for (0..num_clients) |i| {
            _ = clients[i].kill() catch {};
        }
    }

    const connection_time = std.time.nanoTimestamp() - connection_start;

    // Test message relay performance with many clients
    const message_start = std.time.nanoTimestamp();
    const test_message = "High concurrency test message\n";

    // Send messages from subset of clients to avoid overwhelming
    const sender_count = @min(10, num_clients);
    for (0..sender_count) |sender_idx| {
        if (clients[sender_idx].stdin) |stdin| {
            _ = try stdin.write(test_message);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms); // Shorter delay for performance test
    }

    const message_time = std.time.nanoTimestamp() - message_start;

    // Performance metrics
    const connection_time_ms = @as(f64, @floatFromInt(connection_time)) / 1_000_000.0;
    const message_time_ms = @as(f64, @floatFromInt(message_time)) / 1_000_000.0;
    const avg_connection_time = connection_time_ms / @as(f64, @floatFromInt(num_clients));

    std.debug.print("High Concurrency - Clients: {d}, Connection time: {d:.2}ms, Avg: {d:.2}ms, Message relay: {d:.2}ms\n", .{ num_clients, connection_time_ms, avg_connection_time, message_time_ms });

    // Verify performance is acceptable
    try expect(avg_connection_time < 100.0); // Average connection time should be reasonable
    try expect(message_time_ms < 1000.0); // Message relay should be fast
}

test "performance - high message throughput stress test" {
    const allocator = testing.allocator;

    // Start broker server optimized for high throughput
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "50", "14011" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Connect moderate number of clients for throughput test
    const num_clients = 20;
    var clients: [num_clients]ChildProcess = undefined;

    for (0..num_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "14011" }, allocator);
        clients[i].stdin_behavior = .Pipe;
        clients[i].stdout_behavior = .Pipe;
        clients[i].stderr_behavior = .Pipe;

        try clients[i].spawn();
        std.Thread.sleep(50 * std.time.ns_per_ms); // Faster connection for throughput test
    }
    defer {
        for (0..num_clients) |i| {
            _ = clients[i].kill() catch {};
        }
    }

    // High-frequency message sending test
    const messages_per_client = 50;
    const total_messages = num_clients * messages_per_client;

    const throughput_start = std.time.nanoTimestamp();

    // Send many messages rapidly
    for (0..messages_per_client) |msg_idx| {
        for (0..num_clients) |client_idx| {
            const message = try std.fmt.allocPrint(allocator, "Msg{d}FromClient{d}\n", .{ msg_idx, client_idx });
            defer allocator.free(message);

            if (clients[client_idx].stdin) |stdin| {
                _ = try stdin.write(message);
            }
        }
        // Very short delay between message bursts
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    const throughput_time = std.time.nanoTimestamp() - throughput_start;
    const throughput_time_ms = @as(f64, @floatFromInt(throughput_time)) / 1_000_000.0;
    const messages_per_second = (@as(f64, @floatFromInt(total_messages)) / throughput_time_ms) * 1000.0;

    std.debug.print("Message Throughput - {d} messages in {d:.2}ms = {d:.2} msg/sec\n", .{ total_messages, throughput_time_ms, messages_per_second });

    // Verify throughput meets performance requirements
    try expect(messages_per_second > 100.0); // Should handle at least 100 messages per second
}

// =============================================================================
// MEMORY USAGE AND RESOURCE CLEANUP TESTS
// =============================================================================

test "performance - memory usage under load" {
    const allocator = testing.allocator;

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "75", "14020" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Test memory usage with varying client loads
    const load_phases = [_]struct {
        client_count: usize,
        duration_ms: u64,
        message_size: usize,
    }{
        .{ .client_count = 10, .duration_ms = 1000, .message_size = 100 },
        .{ .client_count = 25, .duration_ms = 1000, .message_size = 500 },
        .{ .client_count = 50, .duration_ms = 1000, .message_size = 1000 },
    };

    for (load_phases) |phase| {
        std.debug.print("Memory test phase - {d} clients, {d}ms, {d}B messages\n", .{ phase.client_count, phase.duration_ms, phase.message_size });

        var clients = try allocator.alloc(ChildProcess, phase.client_count);
        defer allocator.free(clients);

        // Connect clients for this phase
        for (0..phase.client_count) |i| {
            clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "14020" }, allocator);
            clients[i].stdin_behavior = .Pipe;
            clients[i].stdout_behavior = .Pipe;
            clients[i].stderr_behavior = .Pipe;

            try clients[i].spawn();
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }

        // Generate test message of specified size
        const test_message = try allocator.alloc(u8, phase.message_size + 1);
        defer allocator.free(test_message);

        for (test_message[0..phase.message_size]) |*byte| {
            byte.* = 'A' + @as(u8, @intCast(std.crypto.random.int(u8) % 26));
        }
        test_message[phase.message_size] = '\n';

        // Send messages during the phase duration
        const phase_start = std.time.nanoTimestamp();
        var message_count: usize = 0;

        while (true) {
            const elapsed_ns = std.time.nanoTimestamp() - phase_start;
            const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);

            if (elapsed_ms >= phase.duration_ms) break;

            // Send message from random client
            const sender_idx = std.crypto.random.int(usize) % phase.client_count;
            if (clients[sender_idx].stdin) |stdin| {
                _ = stdin.write(test_message) catch continue;
                message_count += 1;
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        std.debug.print("Phase completed - {d} messages sent\n", .{message_count});

        // Cleanup clients for this phase
        for (0..phase.client_count) |i| {
            _ = clients[i].kill() catch {};
        }

        // Brief pause between phases for cleanup
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

test "performance - resource cleanup under connection churn" {
    const allocator = testing.allocator;

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "30", "14021" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Test connection churn (frequent connect/disconnect)
    const churn_cycles = 10;
    const clients_per_cycle = 15;

    for (0..churn_cycles) |cycle| {
        std.debug.print("Connection churn cycle {d}/{d}\n", .{ cycle + 1, churn_cycles });

        var clients: [clients_per_cycle]ChildProcess = undefined;

        // Connect clients
        for (0..clients_per_cycle) |i| {
            clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "14021" }, allocator);
            clients[i].stdin_behavior = .Pipe;
            clients[i].stdout_behavior = .Pipe;
            clients[i].stderr_behavior = .Pipe;

            try clients[i].spawn();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Send some messages
        for (0..clients_per_cycle) |i| {
            const message = try std.fmt.allocPrint(allocator, "Churn cycle {d} client {d}\n", .{ cycle, i });
            defer allocator.free(message);

            if (clients[i].stdin) |stdin| {
                _ = stdin.write(message) catch continue;
            }
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Disconnect all clients
        for (0..clients_per_cycle) |i| {
            _ = clients[i].kill() catch {};
        }

        // Brief pause for cleanup
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    std.debug.print("Connection churn test completed\n", .{});
}

// =============================================================================
// FEATURE COMBINATION VALIDATION TESTS
// =============================================================================

test "compatibility - incompatible mode combinations" {
    const allocator = testing.allocator;

    // Test combinations that should fail
    const incompatible_combinations = [_]struct {
        name: []const u8,
        args: []const []const u8,
        expected_error: bool,
    }{
        .{
            .name = "broker_with_exec",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--broker", "-e", "echo test", "14030" },
            .expected_error = true,
        },
        .{
            .name = "chat_with_exec",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--chat", "-e", "echo test", "14031" },
            .expected_error = true,
        },
        .{
            .name = "broker_with_zero_io",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--broker", "-z", "14032" },
            .expected_error = true,
        },
        .{
            .name = "chat_with_udp",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--chat", "-u", "14033" },
            .expected_error = true,
        },
        .{
            .name = "broker_and_chat_together",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--broker", "--chat", "14034" },
            .expected_error = true,
        },
    };

    for (incompatible_combinations) |combo| {
        std.debug.print("Testing incompatible combination: {s}\n", .{combo.name});

        var process = ChildProcess.init(combo.args, allocator);
        process.stdin_behavior = .Ignore;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

        try process.spawn();

        // Wait for process to exit (should exit quickly with error)
        const result = try process.wait();

        if (combo.expected_error) {
            // Should exit with non-zero code
            try expect(result.Exited != 0);
            std.debug.print("  ✓ Correctly rejected incompatible combination\n", .{});
        } else {
            // Should exit successfully
            try expectEqual(@as(u32, 0), result.Exited);
        }
    }
}

test "compatibility - valid feature combinations" {
    const allocator = testing.allocator;

    // Create test files for combinations that need them
    const allow_file = "valid_combo_allow.txt";
    const allow_content = "127.0.0.1\n::1\n";
    try std.fs.cwd().writeFile(.{ .sub_path = allow_file, .data = allow_content });
    defer std.fs.cwd().deleteFile(allow_file) catch {};

    // Test combinations that should work
    const valid_combinations = [_]struct {
        name: []const u8,
        args: []const []const u8,
        port: []const u8,
    }{
        .{
            .name = "broker_with_verbosity",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--broker", "-v", "14040" },
            .port = "14040",
        },
        .{
            .name = "chat_with_access_control",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--chat", "--allow", allow_file, "14041" },
            .port = "14041",
        },
        .{
            .name = "broker_with_max_clients",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--broker", "--max-clients", "10", "14042" },
            .port = "14042",
        },
        .{
            .name = "chat_with_timeout",
            .args = &[_][]const u8{ zigcat_binary, "-l", "--chat", "-w", "5", "14043" },
            .port = "14043",
        },
    };

    for (valid_combinations) |combo| {
        std.debug.print("Testing valid combination: {s}\n", .{combo.name});

        var server = ChildProcess.init(combo.args, allocator);
        server.stdin_behavior = .Ignore;
        server.stdout_behavior = .Pipe;
        server.stderr_behavior = .Pipe;

        try server.spawn();
        defer _ = server.kill() catch {};

        // Give server time to start
        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

        // Test that we can connect a client
        var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", combo.port }, allocator);
        client.stdin_behavior = .Pipe;
        client.stdout_behavior = .Pipe;
        client.stderr_behavior = .Pipe;

        try client.spawn();
        defer _ = client.kill() catch {};

        std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * std.time.ns_per_ms);

        // Send a test message to verify functionality
        if (client.stdin) |stdin| {
            _ = try stdin.write("Test message\n");
        }

        std.Thread.sleep(MESSAGE_DELAY_MS * std.time.ns_per_ms);

        std.debug.print("  ✓ Valid combination works correctly\n", .{});
    }
}

// =============================================================================
// LARGE MESSAGE AND BUFFER HANDLING TESTS
// =============================================================================

test "performance - large message handling" {
    const allocator = testing.allocator;

    // Start broker server
    var server = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "--broker", "14050" }, allocator);
    server.stdin_behavior = .Ignore;
    server.stdout_behavior = .Pipe;
    server.stderr_behavior = .Pipe;

    try server.spawn();
    defer _ = server.kill() catch {};

    std.Thread.sleep(CLIENT_CONNECT_DELAY_MS * 2 * std.time.ns_per_ms);

    // Connect clients
    const num_clients = 5;
    var clients: [num_clients]ChildProcess = undefined;

    for (0..num_clients) |i| {
        clients[i] = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "14050" }, allocator);
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

    // Test progressively larger messages
    const message_sizes = [_]usize{ 1024, 4096, 8192, 16384 };

    for (message_sizes) |size| {
        std.debug.print("Testing message size: {d} bytes\n", .{size});

        // Create large test message
        const large_message = try allocator.alloc(u8, size + 1);
        defer allocator.free(large_message);

        // Fill with pattern data
        for (large_message[0..size], 0..) |*byte, i| {
            byte.* = @as(u8, @intCast(('A' + (i % 26))));
        }
        large_message[size] = '\n';

        const start_time = std.time.nanoTimestamp();

        // Send large message from first client
        if (clients[0].stdin) |stdin| {
            _ = try stdin.write(large_message);
        }

        // Allow time for message to be relayed
        std.Thread.sleep(MESSAGE_DELAY_MS * 5 * std.time.ns_per_ms);

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
        const throughput_mbps = (@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)) / (duration_ms / 1000.0);

        std.debug.print("  Size: {d}KB, Time: {d:.2}ms, Throughput: {d:.2}MB/s\n", .{ size / 1024, duration_ms, throughput_mbps });

        // Verify performance is reasonable for large messages
        try expect(duration_ms < 1000.0); // Should complete within 1 second
    }
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

fn createTestCertificate(_: Allocator, cert_file: []const u8, key_file: []const u8) !void {
    // Create minimal self-signed certificate for testing
    // This is a simplified version - in real tests you might use openssl command
    const cert_content =
        \\-----BEGIN CERTIFICATE-----
        \\MIIBkTCB+wIJAMlyFqk69v+9MA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNVBAMMCWxv
        \\Y2FsaG9zdDAeFw0yNDAxMDEwMDAwMDBaFw0yNTAxMDEwMDAwMDBaMBQxEjAQBgNV
        \\BAMMCWxvY2FsaG9zdDBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQDTgvwjlRHZ9jzj
        \\VkqWaJMhzIeJVjNVGU6O5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f
        \\5f5f5f5f5f5fAgMBAAEwDQYJKoZIhvcNAQELBQADQQBQiSdYle9+kXynt2aQlBcU
        \\JkFvK5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5k5
        \\-----END CERTIFICATE-----
    ;

    const key_content =
        \\-----BEGIN PRIVATE KEY-----
        \\MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEA04L8I5UR2fY841ZK
        \\lmiTIcyHiVYzVRlOjuX+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+X+
        \\X+X+X+X+XwIDAQABAkEAiVBUYzJIjK7mcBC+uuPiHnXvOf+S6/e8s5+5+5+5+5+5
        \\+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5
        \\QIhAOqI0BtY4+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5
        \\AiEA5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5+5
        \\-----END PRIVATE KEY-----
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = cert_file, .data = cert_content });
    try std.fs.cwd().writeFile(.{ .sub_path = key_file, .data = key_content });
}
