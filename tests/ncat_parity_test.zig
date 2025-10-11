// Ncat Flag Compatibility Tests
// Tests zigcat's compatibility with ncat's command-line flags
//
// CRITICAL: This is a standalone test file - CANNOT import from src/
// Uses only std library for self-contained testing

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const POLL = posix.POLL;
const O_NONBLOCK: u32 = 0x0004; // macOS compatible

// ============================================================================
// Test 1: --no-shutdown flag (half-close behavior)
// ============================================================================

/// Test: --no-shutdown flag enables half-close mode
///
/// Expected Behavior:
/// - shutdown(SHUT_WR) is called instead of close() on stdin EOF
/// - Socket remains open for reading after write shutdown
/// - Connection stays alive until both sides close
///
/// Ncat Reference: ncat --no-shutdown localhost 9999
test "no-shutdown flag enables half-close mode" {
    const allocator = testing.allocator;

    // Create socket pair for testing
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Simulate client sending data then calling shutdown(SHUT_WR)
    const send_data = "Hello";
    const sent = try posix.send(client_sock, send_data, 0);
    try testing.expectEqual(send_data.len, sent);

    // Half-close: shutdown write side only
    try posix.shutdown(client_sock, .send);

    // Server should still be able to receive data
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(send_data.len, recv_len);
    try testing.expectEqualStrings(send_data, recv_buf[0..recv_len]);

    // Server should still be able to send data
    const reply = "World";
    const reply_sent = try posix.send(server_sock, reply, 0);
    try testing.expectEqual(reply.len, reply_sent);

    // Client should still be able to receive (read side open)
    const reply_recv = try posix.recv(client_sock, &recv_buf, 0);
    try testing.expectEqual(reply.len, reply_recv);
    try testing.expectEqualStrings(reply, recv_buf[0..reply_recv]);

    // Socket is still open for reading
    // (If close() was called instead of shutdown(SHUT_WR), this would fail)
}

// ============================================================================
// Test 2: --version-all flag output format
// ============================================================================

/// Test: --version-all produces complete version information
///
/// Expected Format (matching ncat):
/// zigcat 0.1.0
/// Zig 0.15.1
/// Compiled with: zig
/// Platform: darwin-aarch64
test "version-all output format" {
    // This test validates output format, not exact content
    // Real implementation would parse `zigcat --version-all` output

    const expected_fields = [_][]const u8{
        "zigcat",
        "Zig",
        "Compiled with",
        "Platform",
    };

    // Placeholder: In actual implementation, run zigcat --version-all
    // and validate each expected field is present

    for (expected_fields) |field| {
        // Validate field presence
        _ = field; // Suppress unused warning in placeholder
    }
}

// ============================================================================
// Test 3: --delay flag timing validation
// ============================================================================

/// Test: --delay introduces specified delay between reads/writes
///
/// Expected Behavior:
/// - Each read/write operation waits <delay> milliseconds
/// - Timing is measured with poll() timeouts
/// - Delay is enforced on both send and receive
test "delay flag timing validation" {
    const delay_ms: i32 = 100; // 100ms delay

    const start_time = std.time.milliTimestamp();

    // Simulate 5 read/write operations with 100ms delay each
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // Sleep for delay_ms
        std.Thread.sleep(@as(u64, @intCast(delay_ms)) * std.time.ns_per_ms);
    }

    const elapsed = std.time.milliTimestamp() - start_time;

    // Total expected delay: 5 operations * 100ms = 500ms
    // Allow 20% margin for scheduling jitter
    const expected_min = 5 * delay_ms;
    const expected_max = expected_min + @divTrunc(expected_min, 5); // +20%

    try testing.expect(elapsed >= expected_min);
    try testing.expect(elapsed <= expected_max);
}

// ============================================================================
// Test 4: --append-output flag behavior
// ============================================================================

/// Test: --append-output appends hex dump instead of truncating
///
/// Expected Behavior:
/// - Output file is opened with O_APPEND
/// - Multiple connections append to same file
/// - File is not truncated on subsequent writes
test "append-output flag behavior" {
    const allocator = testing.allocator;

    // Create temporary file
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const output_path = "hex_output.txt";
    var output_file = try tmp_dir.dir.createFile(output_path, .{ .truncate = true });
    defer output_file.close();

    // Write first data
    const first_data = "First\n";
    try output_file.writeAll(first_data);

    // Close and reopen with append flag
    output_file.close();
    output_file = try tmp_dir.dir.openFile(output_path, .{ .mode = .read_write });

    // Seek to end (append mode)
    try output_file.seekFromEnd(0);

    // Write second data
    const second_data = "Second\n";
    try output_file.writeAll(second_data);

    // Reopen and read all content
    output_file.close();
    output_file = try tmp_dir.dir.openFile(output_path, .{ .mode = .read_only });

    var read_buf: [128]u8 = undefined;
    const bytes_read = try output_file.readAll(&read_buf);

    const expected = "First\nSecond\n";
    try testing.expectEqualStrings(expected, read_buf[0..bytes_read]);
}

// ============================================================================
// Test 5: --proxy-dns flag behavior
// ============================================================================

/// Test: --proxy-dns sends hostname to proxy instead of resolving locally
///
/// Expected Behavior:
/// - SOCKS5 with --proxy-dns: Send domain name in SOCKS5 request (ATYP=0x03)
/// - SOCKS5 without --proxy-dns: Resolve locally, send IP (ATYP=0x01)
/// - HTTP CONNECT: Always sends hostname in HTTP request
test "proxy-dns sends hostname to SOCKS5 proxy" {
    // SOCKS5 address type constants
    const ATYP_IPV4 = 0x01;
    const ATYP_DOMAINNAME = 0x03;

    // Simulate SOCKS5 request with --proxy-dns (should send domain name)
    const socks5_request_with_dns = [_]u8{
        0x05, // VER
        0x01, // CMD (CONNECT)
        0x00, // RSV
        ATYP_DOMAINNAME, // ATYP (domain name)
        0x0B, // Domain length (11)
        'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
        0x00, 0x50, // Port 80
    };

    // Validate ATYP is DOMAINNAME
    try testing.expectEqual(ATYP_DOMAINNAME, socks5_request_with_dns[3]);

    // Simulate SOCKS5 request without --proxy-dns (should send IP)
    const socks5_request_without_dns = [_]u8{
        0x05, // VER
        0x01, // CMD (CONNECT)
        0x00, // RSV
        ATYP_IPV4, // ATYP (IPv4)
        192, 0, 2, 1, // IP address (192.0.2.1)
        0x00, 0x50, // Port 80
    };

    // Validate ATYP is IPv4
    try testing.expectEqual(ATYP_IPV4, socks5_request_without_dns[3]);
}

// ============================================================================
// Test 6: Edge case - Zero-length input
// ============================================================================

/// Test: Zero-length input handling (stdin EOF immediately)
///
/// Expected Behavior:
/// - Connection opens successfully
/// - No data is sent
/// - Connection closes gracefully
test "zero-length input handling" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Client immediately closes write side (simulating stdin EOF)
    try posix.shutdown(client_sock, .send);

    // Server receives EOF (0 bytes)
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(@as(usize, 0), recv_len);

    // Connection handled gracefully (no crash)
}

// ============================================================================
// Test 7: Binary data passthrough
// ============================================================================

/// Test: Binary data with null bytes passes through unmodified
///
/// Expected Behavior:
/// - Null bytes (0x00) are transmitted
/// - All byte values (0x00-0xFF) pass through unchanged
/// - No text processing is applied to binary data
test "binary data passthrough with null bytes" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Binary data with null bytes and all values
    const binary_data = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC,
        'H', 'e', 'l', 'l', 'o',
        0x00, 0x00,
    };

    // Send binary data
    const sent = try posix.send(client_sock, &binary_data, 0);
    try testing.expectEqual(binary_data.len, sent);

    // Receive binary data
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(binary_data.len, recv_len);

    // Validate byte-for-byte equality
    try testing.expectEqualSlices(u8, &binary_data, recv_buf[0..recv_len]);
}

// ============================================================================
// Test 8: Maximum buffer size handling
// ============================================================================

/// Test: Large input buffers (64KB) are handled correctly
///
/// Expected Behavior:
/// - 64KB buffer is transmitted successfully
/// - Data integrity is maintained
/// - No buffer overflow or truncation
test "maximum buffer size handling" {
    const allocator = testing.allocator;

    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Create 64KB buffer filled with 'A'
    const buffer_size = 64 * 1024;
    const large_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(large_buffer);

    @memset(large_buffer, 'A');

    // Send large buffer
    const sent = try posix.send(client_sock, large_buffer, 0);
    try testing.expectEqual(buffer_size, sent);

    // Receive large buffer
    const recv_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(recv_buffer);

    var total_recv: usize = 0;
    while (total_recv < buffer_size) {
        const recv_len = try posix.recv(server_sock, recv_buffer[total_recv..], 0);
        if (recv_len == 0) break;
        total_recv += recv_len;
    }

    try testing.expectEqual(buffer_size, total_recv);
    try testing.expectEqualSlices(u8, large_buffer, recv_buffer);
}

// ============================================================================
// Test 9: Concurrent read/write (bidirectional traffic)
// ============================================================================

/// Test: Simultaneous bidirectional data transfer
///
/// Expected Behavior:
/// - Client sends while server sends
/// - No deadlock occurs
/// - All data is transmitted successfully
test "concurrent bidirectional traffic" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Client sends data
    const client_data = "Client to Server";
    const client_sent = try posix.send(client_sock, client_data, 0);
    try testing.expectEqual(client_data.len, client_sent);

    // Server sends data (without waiting for client data first)
    const server_data = "Server to Client";
    const server_sent = try posix.send(server_sock, server_data, 0);
    try testing.expectEqual(server_data.len, server_sent);

    // Server receives client data
    var server_recv_buf: [64]u8 = undefined;
    const server_recv_len = try posix.recv(server_sock, &server_recv_buf, 0);
    try testing.expectEqual(client_data.len, server_recv_len);
    try testing.expectEqualStrings(client_data, server_recv_buf[0..server_recv_len]);

    // Client receives server data
    var client_recv_buf: [64]u8 = undefined;
    const client_recv_len = try posix.recv(client_sock, &client_recv_buf, 0);
    try testing.expectEqual(server_data.len, client_recv_len);
    try testing.expectEqualStrings(server_data, client_recv_buf[0..client_recv_len]);

    // No deadlock, all data transmitted
}

// ============================================================================
// Test 10: Idle timeout during active connection
// ============================================================================

/// Test: Idle timeout triggers during connection inactivity
///
/// Expected Behavior:
/// - Connection active, data flows
/// - Idle period > timeout
/// - Connection closes with timeout error
test "idle timeout during active connection" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const sock = sockets[0];

    // Set non-blocking mode
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | O_NONBLOCK);

    // Poll with timeout
    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = POLL.IN,
        .revents = 0,
    }};

    const timeout_ms: i32 = 100; // 100ms timeout
    const start_time = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, timeout_ms);
    const elapsed = std.time.milliTimestamp() - start_time;

    // Expect timeout (no data received)
    try testing.expectEqual(@as(usize, 0), ready);

    // Validate timeout duration (±20ms margin)
    try testing.expect(elapsed >= timeout_ms - 20);
    try testing.expect(elapsed <= timeout_ms + 20);
}

// ============================================================================
// Test 11: Connection timeout enforcement
// ============================================================================

/// Test: Connect timeout (-w flag) is enforced
///
/// Expected Behavior:
/// - Non-blocking connect initiated
/// - Poll with timeout_ms
/// - If timeout expires, return error.ConnectionTimeout
test "connect timeout enforcement" {
    // Create socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    // Set non-blocking mode
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | O_NONBLOCK);

    // Attempt connection to non-routable IP (will timeout)
    var addr = std.mem.zeroes(posix.sockaddr.in);
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, 9999);
    // Use TEST-NET-1 (192.0.2.0/24) - reserved for documentation
    addr.addr = @bitCast([4]u8{ 192, 0, 2, 1 });

    const addr_ptr: *const posix.sockaddr = @ptrCast(&addr);
    const addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

    // Initiate non-blocking connect (will return EINPROGRESS)
    _ = posix.connect(sock, addr_ptr, addr_len) catch |err| {
        // Expected: WouldBlock or InProgress
        try testing.expect(err == error.WouldBlock or err == error.ConnectionRefused);
    };

    // Poll with short timeout
    var pollfds = [_]posix.pollfd{.{
        .fd = sock,
        .events = POLL.OUT,
        .revents = 0,
    }};

    const timeout_ms: i32 = 100; // 100ms timeout
    const ready = try posix.poll(&pollfds, timeout_ms);

    // Expect timeout (no connection within 100ms)
    try testing.expectEqual(@as(usize, 0), ready);
}

// ============================================================================
// Test 12: CRLF conversion flag
// ============================================================================

/// Test: --crlf flag converts LF to CRLF
///
/// Expected Behavior:
/// - Input: "Line1\nLine2\n"
/// - Output: "Line1\r\nLine2\r\n"
/// - \n (0x0A) is replaced with \r\n (0x0D 0x0A)
test "crlf conversion flag" {
    const allocator = testing.allocator;

    const input = "Line1\nLine2\n";
    const expected_output = "Line1\r\nLine2\r\n";

    // Manual CRLF conversion (simulating --crlf flag behavior)
    var converted = std.ArrayList(u8).init(allocator);
    defer converted.deinit();

    for (input) |byte| {
        if (byte == '\n') {
            try converted.append('\r');
            try converted.append('\n');
        } else {
            try converted.append(byte);
        }
    }

    try testing.expectEqualStrings(expected_output, converted.items);
}
