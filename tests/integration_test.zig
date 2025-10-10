// Integration Tests
// End-to-end tests for complete netcat scenarios

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const ChildProcess = std.ChildProcess;

// Path to the zig-nc binary (will be set by test runner)
const zigcat_binary = "zig-out/bin/zig-nc";

// =============================================================================
// BASIC CONNECT/LISTEN TESTS
// =============================================================================

test "integration - basic TCP echo server" {
    const allocator = testing.allocator;

    // Start listener: zig-nc -l 12345
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12345" }, allocator);
    listener.stdin_behavior = .Pipe;
    listener.stdout_behavior = .Pipe;
    listener.stderr_behavior = .Ignore;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    // Give listener time to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect: zig-nc localhost 12345
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12345" }, allocator);
    client.stdin_behavior = .Pipe;
    client.stdout_behavior = .Pipe;
    client.stderr_behavior = .Ignore;

    try client.spawn();
    defer _ = client.kill() catch {};

    // Send data from client
    const test_data = "Hello, World!\n";
    _ = try client.stdin.?.write(test_data);

    // Read on server side
    var buffer: [1024]u8 = undefined;
    const received = try listener.stdout.?.read(&buffer);

    try expectEqualStrings(test_data, buffer[0..received]);
}

test "integration - file transfer via pipe" {
    const allocator = testing.allocator;

    // Test: cat file | zig-nc -l 12346 &
    //       zig-nc localhost 12346 > received_file

    const test_data = "This is test file data\nWith multiple lines\n";

    // Start receiver: zig-nc localhost 12346 > output
    var receiver = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12346" }, allocator);
    receiver.stdin_behavior = .Ignore;
    receiver.stdout_behavior = .Pipe;
    receiver.stderr_behavior = .Ignore;

    // Start sender: zig-nc -l 12346
    var sender = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12346" }, allocator);
    sender.stdin_behavior = .Pipe;
    sender.stdout_behavior = .Ignore;
    sender.stderr_behavior = .Ignore;

    try sender.spawn();
    defer _ = sender.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    try receiver.spawn();
    defer _ = receiver.kill() catch {};

    // Send data
    _ = try sender.stdin.?.write(test_data);
    sender.stdin.?.close();

    // Receive data
    var buffer: [1024]u8 = undefined;
    const received = try receiver.stdout.?.read(&buffer);

    try expectEqualStrings(test_data, buffer[0..received]);
}

// =============================================================================
// UDP TESTS
// =============================================================================

test "integration - UDP echo" {
    const allocator = testing.allocator;

    // Start UDP listener: zig-nc -u -l 12347
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-u", "-l", "12347" }, allocator);
    listener.stdin_behavior = .Pipe;
    listener.stdout_behavior = .Pipe;
    listener.stderr_behavior = .Ignore;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Send UDP message: echo "test" | zig-nc -u localhost 12347
    var sender = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-u", "localhost", "12347" }, allocator);
    sender.stdin_behavior = .Pipe;
    sender.stdout_behavior = .Pipe;
    sender.stderr_behavior = .Ignore;

    try sender.spawn();
    defer _ = sender.kill() catch {};

    const test_data = "UDP test message\n";
    _ = try sender.stdin.?.write(test_data);

    // Read on listener
    var buffer: [1024]u8 = undefined;
    const received = try listener.stdout.?.read(&buffer);

    try expectEqualStrings(test_data, buffer[0..received]);
}

// =============================================================================
// KEEP-OPEN MODE TESTS
// =============================================================================

test "integration - keep-open accepts multiple clients" {
    const allocator = testing.allocator;

    // Start listener with -k: zig-nc -l -k 12348
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "-k", "12348" }, allocator);
    listener.stdin_behavior = .Ignore;
    listener.stdout_behavior = .Pipe;
    listener.stderr_behavior = .Ignore;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // First client
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12348" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;
    client1.stderr_behavior = .Ignore;

    try client1.spawn();

    _ = try client1.stdin.?.write("Client 1\n");
    client1.stdin.?.close();

    _ = try client1.wait();

    // Second client - should also connect since -k is set
    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12348" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;
    client2.stderr_behavior = .Ignore;

    try client2.spawn();

    _ = try client2.stdin.?.write("Client 2\n");
    client2.stdin.?.close();

    _ = try client2.wait();

    // Listener should still be running
    // (Would need timeout-based check in real implementation)
}

// =============================================================================
// ZERO-I/O MODE (PORT SCANNING) TESTS
// =============================================================================

test "integration - zero-io port scanning - open port" {
    const allocator = testing.allocator;

    // Start listener on port 12349
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12349" }, allocator);
    listener.stdin_behavior = .Ignore;
    listener.stdout_behavior = .Ignore;
    listener.stderr_behavior = .Ignore;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Scan with -z: zig-nc -z localhost 12349
    var scanner = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-z", "localhost", "12349" }, allocator);
    scanner.stdin_behavior = .Ignore;
    scanner.stdout_behavior = .Ignore;
    scanner.stderr_behavior = .Ignore;

    try scanner.spawn();

    const result = try scanner.wait();

    // Exit code 0 means port is open
    try expectEqual(@as(u32, 0), result.Exited);
}

test "integration - zero-io port scanning - closed port" {
    const allocator = testing.allocator;

    // Scan port with no listener: zig-nc -z localhost 1
    var scanner = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-z", "localhost", "1" }, allocator);
    scanner.stdin_behavior = .Ignore;
    scanner.stdout_behavior = .Ignore;
    scanner.stderr_behavior = .Ignore;

    try scanner.spawn();

    const result = try scanner.wait();

    // Non-zero exit code means port is closed
    try expect(result.Exited != 0);
}

test "integration - zero-io scan multiple ports" {
    const allocator = testing.allocator;

    // Start listeners on multiple ports
    var listener1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12350" }, allocator);
    try listener1.spawn();
    defer _ = listener1.kill() catch {};

    var listener2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12351" }, allocator);
    try listener2.spawn();
    defer _ = listener2.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Scan range (would need loop in shell script, but shows concept)
    const ports = [_][]const u8{ "12350", "12351", "12352" };

    for (ports) |port| {
        var scanner = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-z", "localhost", port }, allocator);
        try scanner.spawn();

        const result = try scanner.wait();

        if (std.mem.eql(u8, port, "12350") or std.mem.eql(u8, port, "12351")) {
            try expectEqual(@as(u32, 0), result.Exited); // Open
        } else {
            try expect(result.Exited != 0); // Closed
        }
    }
}

// =============================================================================
// TIMEOUT TESTS
// =============================================================================

test "integration - connect timeout on unresponsive host" {
    const allocator = testing.allocator;

    // Try to connect to non-routable address with timeout
    // zig-nc -w 1 192.0.2.1 80
    var client = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-w",
        "1",
        "192.0.2.1",
        "80",
    }, allocator);

    const start_time = std.time.milliTimestamp();

    try client.spawn();
    _ = try client.wait();

    const elapsed = std.time.milliTimestamp() - start_time;

    // Should timeout in ~1 second (allow some margin)
    try expect(elapsed < 2000);
    try expect(elapsed >= 900);
}

test "integration - idle timeout closes connection" {
    const allocator = testing.allocator;

    // Start listener with idle timeout: zig-nc -l -i 2 12353
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "-i", "2", "12353" }, allocator);
    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect but don't send data
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12353" }, allocator);
    try client.spawn();

    const start_time = std.time.milliTimestamp();

    // Connection should close after 2 seconds of inactivity
    _ = try client.wait();

    const elapsed = std.time.milliTimestamp() - start_time;

    // Should close in ~2 seconds
    try expect(elapsed < 3000);
    try expect(elapsed >= 1900);
}

test "integration - quit-after-eof delay" {
    const allocator = testing.allocator;

    // Start listener: zig-nc -l 12354
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "12354" }, allocator);
    listener.stdin_behavior = .Ignore;
    listener.stdout_behavior = .Ignore;
    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect with -q 2 (wait 2 seconds after EOF)
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-q", "2", "localhost", "12354" }, allocator);
    client.stdin_behavior = .Pipe;
    try client.spawn();

    // Send data and close stdin
    _ = try client.stdin.?.write("test\n");
    client.stdin.?.close();

    const start_time = std.time.milliTimestamp();

    _ = try client.wait();

    const elapsed = std.time.milliTimestamp() - start_time;

    // Should wait ~2 seconds after EOF
    try expect(elapsed < 3000);
    try expect(elapsed >= 1900);
}

// =============================================================================
// EXEC MODE TESTS
// =============================================================================

test "integration - exec spawns command on connect" {
    if (std.Target.current.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Start listener with exec: zig-nc -l -e /bin/cat 12355
    var listener = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-l",
        "-e",
        "/bin/cat",
        "12355",
    }, allocator);

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect and send data
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12355" }, allocator);
    client.stdin_behavior = .Pipe;
    client.stdout_behavior = .Pipe;

    try client.spawn();

    const test_data = "echo test\n";
    _ = try client.stdin.?.write(test_data);

    // /bin/cat should echo it back
    var buffer: [1024]u8 = undefined;
    const received = try client.stdout.?.read(&buffer);

    try expectEqualStrings(test_data, buffer[0..received]);

    client.stdin.?.close();
    _ = try client.wait();
}

test "integration - exec security warning logged" {
    const allocator = testing.allocator;

    // When using -e, a warning should be printed to stderr
    var listener = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-l",
        "-e",
        "/bin/cat",
        "12356",
    }, allocator);
    listener.stderr_behavior = .Pipe;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Read stderr
    var buffer: [4096]u8 = undefined;
    const stderr_output = try listener.stderr.?.read(&buffer);

    // Should contain warning about -e being dangerous
    try expect(std.mem.indexOf(u8, buffer[0..stderr_output], "WARNING") != null);
}

// =============================================================================
// BROKER/CHAT MODE TESTS
// =============================================================================

test "integration - broker mode relays between clients" {
    const allocator = testing.allocator;

    // Start broker: zig-nc -l --broker 12357
    var broker = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-l",
        "--broker",
        "12357",
    }, allocator);

    try broker.spawn();
    defer _ = broker.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect client 1
    var client1 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12357" }, allocator);
    client1.stdin_behavior = .Pipe;
    client1.stdout_behavior = .Pipe;

    try client1.spawn();
    defer _ = client1.kill() catch {};

    // Connect client 2
    var client2 = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12357" }, allocator);
    client2.stdin_behavior = .Pipe;
    client2.stdout_behavior = .Pipe;

    try client2.spawn();
    defer _ = client2.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Client 1 sends message
    const msg = "Hello from client 1\n";
    _ = try client1.stdin.?.write(msg);

    // Client 2 should receive it
    var buffer: [1024]u8 = undefined;
    const received = try client2.stdout.?.read(&buffer);

    try expectEqualStrings(msg, buffer[0..received]);
}

// =============================================================================
// ACCESS CONTROL TESTS
// =============================================================================

test "integration - allow list permits connection" {
    const allocator = testing.allocator;

    // Start listener with allow list: zig-nc -l --allow 127.0.0.1 12358
    var listener = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-l",
        "--allow",
        "127.0.0.1",
        "12358",
    }, allocator);

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect from localhost (should be allowed)
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12358" }, allocator);
    client.stdin_behavior = .Pipe;

    try client.spawn();

    _ = try client.stdin.?.write("test\n");

    const result = try client.wait();

    // Should succeed (exit code 0)
    try expectEqual(@as(u32, 0), result.Exited);
}

test "integration - deny list blocks connection" {
    const allocator = testing.allocator;

    // Start listener with deny list: zig-nc -l --deny 127.0.0.1 12359
    var listener = ChildProcess.init(&[_][]const u8{
        zigcat_binary,
        "-l",
        "--deny",
        "127.0.0.1",
        "12359",
    }, allocator);

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect from localhost (should be denied)
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12359" }, allocator);

    try client.spawn();

    const result = try client.wait();

    // Should fail (non-zero exit code)
    try expect(result.Exited != 0);
}

// =============================================================================
// VERBOSE MODE TESTS
// =============================================================================

test "integration - verbose output shows connection info" {
    const allocator = testing.allocator;

    // Start listener with -v: zig-nc -l -v 12360
    var listener = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-l", "-v", "12360" }, allocator);
    listener.stderr_behavior = .Pipe;

    try listener.spawn();
    defer _ = listener.kill() catch {};

    std.time.sleep(100 * std.time.ns_per_ms);

    // Connect
    var client = ChildProcess.init(&[_][]const u8{ zigcat_binary, "localhost", "12360" }, allocator);
    try client.spawn();

    std.time.sleep(100 * std.time.ns_per_ms);

    _ = try client.kill();

    // Read stderr for verbose output
    var buffer: [4096]u8 = undefined;
    const stderr_output = try listener.stderr.?.read(&buffer);

    // Should contain connection information
    try expect(std.mem.indexOf(u8, buffer[0..stderr_output], "Connection") != null or
        std.mem.indexOf(u8, buffer[0..stderr_output], "127.0.0.1") != null);
}

// =============================================================================
// HELP AND VERSION TESTS
// =============================================================================

test "integration - help flag shows usage" {
    const allocator = testing.allocator;

    var help = ChildProcess.init(&[_][]const u8{ zigcat_binary, "-h" }, allocator);
    help.stdout_behavior = .Pipe;

    try help.spawn();

    var buffer: [8192]u8 = undefined;
    const output = try help.stdout.?.read(&buffer);

    _ = try help.wait();

    // Should contain usage information
    try expect(std.mem.indexOf(u8, buffer[0..output], "Usage:") != null);
    try expect(std.mem.indexOf(u8, buffer[0..output], "zig-nc") != null);
}

test "integration - version flag shows version" {
    const allocator = testing.allocator;

    var version = ChildProcess.init(&[_][]const u8{ zigcat_binary, "--version" }, allocator);
    version.stdout_behavior = .Pipe;

    try version.spawn();

    var buffer: [1024]u8 = undefined;
    const output = try version.stdout.?.read(&buffer);

    _ = try version.wait();

    // Should contain version number
    try expect(std.mem.indexOf(u8, buffer[0..output], "zig-nc") != null);
    try expect(output > 0);
}
