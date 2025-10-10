const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const builtin = @import("builtin");

// Platform-aware O_NONBLOCK constant
// macOS: 0x0004, Linux: 0x0800, Windows: different mechanism
const O_NONBLOCK: u32 = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos => 0x0004,
    .linux => 0x0800,
    .windows => @compileError("O_NONBLOCK not applicable on Windows, use ioctlsocket"),
    else => 0x0004, // Default to BSD-style
};

// Self-contained zero-I/O mode tests
// These tests verify port scanning behavior (connect + immediate close)

fn scanPort(host: []const u8, port: u16, timeout_ms: i32) !bool {
    const addr = std.net.Address.parseIp4(host, port) catch {
        return error.InvalidAddress;
    };

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(sock);

    // Set non-blocking
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | O_NONBLOCK);

    // Attempt connection
    _ = posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| {
        if (err != error.WouldBlock) {
            posix.close(sock);
            return false;
        }
    };

    // Wait for connection with timeout
    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = posix.POLL.OUT,
        .revents = 0,
    }};

    const ready = try posix.poll(&pollfds, timeout_ms);
    defer posix.close(sock);

    if (ready == 0) {
        return false; // Timeout
    }

    // Check if connection succeeded
    var err: i32 = undefined;
    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err));

    return err == 0;
}

test "zero-I/O scan closed port" {
    // Scan a port that's likely closed
    const is_open = try scanPort("127.0.0.1", 54321, 1000);

    // Port should be closed
    try testing.expect(!is_open);
}

test "zero-I/O scan open port" {
    // Create a server socket to scan
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    // Get the actual port
    const port = server.listen_address.getPort();

    // Scan the open port
    const is_open = try scanPort("127.0.0.1", port, 1000);

    try testing.expect(is_open);
}

test "zero-I/O scan with timeout" {
    const start = std.time.milliTimestamp();

    // Scan non-routable IP (should timeout)
    const is_open = scanPort("192.0.2.1", 9999, 100) catch false;

    const elapsed = std.time.milliTimestamp() - start;

    // Should have timed out
    try testing.expect(!is_open);
    // Should be close to timeout value (within 50ms tolerance)
    try testing.expect(elapsed >= 80 and elapsed <= 200);
}

test "zero-I/O multiple port scan" {
    // Create server on random port
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const open_port = server.listen_address.getPort();

    // Scan multiple ports (one open, one closed)
    const ports = [_]u16{ open_port, 54322 };
    var open_count: usize = 0;

    for (ports) |p| {
        if (try scanPort("127.0.0.1", p, 1000)) {
            open_count += 1;
        }
    }

    // Should find exactly one open port
    try testing.expectEqual(@as(usize, 1), open_count);
}

test "zero-I/O port range scan simulation" {
    // Create server on random port
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const open_port = server.listen_address.getPort();

    // Scan a small range around the open port
    const start_port = if (open_port > 5) open_port - 5 else open_port;
    const end_port = start_port + 10;

    var found = false;
    var port = start_port;
    while (port < end_port) : (port += 1) {
        if (try scanPort("127.0.0.1", port, 100)) {
            if (port == open_port) {
                found = true;
            }
        }
    }

    // Should have found the open port
    try testing.expect(found);
}

test "zero-I/O timeout validation" {
    // Test different timeout values
    const timeouts = [_]i32{ 50, 100, 200 };

    for (timeouts) |timeout| {
        const start = std.time.milliTimestamp();
        _ = scanPort("192.0.2.1", 9999, timeout) catch {};
        const elapsed = std.time.milliTimestamp() - start;

        // Should timeout close to the specified value (±50ms tolerance)
        try testing.expect(elapsed >= timeout - 50 and elapsed <= timeout + 100);
    }
}
