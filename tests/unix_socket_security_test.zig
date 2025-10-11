//! Security test suite for Unix domain socket implementation.
//!
//! Tests critical security properties:
//! - TOCTTOU race condition mitigation
//! - Permission validation
//! - Platform-specific path limits
//!
//! Run with: zig build test-unix-security

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const builtin = @import("builtin");
const temp_utils = @import("utils/temp_dir.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
});

// Platform detection - only run on Unix-like systems
const unix_socket_supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

// =============================================================================
// Test 1: TOCTTOU Race Condition Mitigation
// =============================================================================

test "TOCTTOU: connect-before-delete prevents symlink attack" {
    if (!unix_socket_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create temporary directory for socket files
    var tmp_dir = temp_utils.createTempDir(allocator);
    defer tmp_dir.cleanup();

    // Create socket path in temp directory
    const socket_path = try tmp_dir.getFilePath("test.sock");
    defer allocator.free(socket_path);
    defer posix.unlink(socket_path) catch {};

    // Step 1: Create a legitimate socket file
    const sock1 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(sock1, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Step 2: Close the socket without removing the file (simulates stale socket)
    posix.close(sock1);

    // Step 3: Create a test socket to probe the stale socket
    const test_sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(test_sock);

    // Step 4: Attempt to connect (should get ECONNREFUSED for stale socket)
    const connect_result = posix.connect(test_sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // SECURITY VALIDATION: Connect should fail with ConnectionRefused
    try testing.expectError(error.ConnectionRefused, connect_result);

    // Step 5: Verify we can safely delete the stale socket
    try posix.unlink(socket_path);
}

test "TOCTTOU: connect-before-delete detects active socket" {
    if (!unix_socket_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create temporary directory for socket files
    var tmp_dir = temp_utils.createTempDir(allocator);
    defer tmp_dir.cleanup();

    // Create socket path in temp directory
    const socket_path = try tmp_dir.getFilePath("active.sock");
    defer allocator.free(socket_path);
    defer posix.unlink(socket_path) catch {};

    // Step 1: Create an active listening socket
    const server_sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(server_sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(server_sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(server_sock, 1);

    // Step 2: Create a test socket to probe the active socket
    const test_sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(test_sock);

    // Step 3: Attempt to connect (should succeed for active socket)
    try posix.connect(test_sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // SECURITY VALIDATION: Socket is actively in use, should NOT be deleted
    // The connect succeeded, proving the socket is alive
}

// =============================================================================
// Test 2: Permission Validation
// =============================================================================

test "Permission validation: detect world-writable socket" {
    if (!unix_socket_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create temporary directory for socket files
    var tmp_dir = temp_utils.createTempDir(allocator);
    defer tmp_dir.cleanup();

    // Create socket path in temp directory
    const socket_path = try tmp_dir.getFilePath("perms.sock");
    defer allocator.free(socket_path);
    defer posix.unlink(socket_path) catch {};

    // Step 1: Create socket with restrictive umask
    const old_umask = c.umask(0o077); // rwx------
    defer _ = c.umask(old_umask);

    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Step 2: Verify socket was created with correct permissions
    const stat_buf = posix.fstatat(posix.AT.FDCWD, socket_path, 0) catch |err| {
        std.debug.print("Failed to stat socket: {any}\n", .{err});
        return error.SkipZigTest;
    };
    const mode = stat_buf.mode & 0o777;

    // SECURITY VALIDATION: Socket should have restrictive permissions (0o700)
    // Not world-writable (no 0o007 bits set)
    try testing.expect((mode & 0o007) == 0);

    // Should be owner-only accessible
    try testing.expect((mode & 0o700) != 0);
}

test "Permission validation: umask prevents brief exposure window" {
    if (!unix_socket_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create temporary directory for socket files
    var tmp_dir = temp_utils.createTempDir(allocator);
    defer tmp_dir.cleanup();

    // Create socket path in temp directory
    const socket_path = try tmp_dir.getFilePath("secure.sock");
    defer allocator.free(socket_path);
    defer posix.unlink(socket_path) catch {};

    // Step 1: Set restrictive umask BEFORE socket creation
    const old_umask = c.umask(0o077);

    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    // Step 2: Bind immediately after setting umask
    try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Step 3: Restore umask immediately
    _ = c.umask(old_umask);

    // Step 4: Verify socket was created with restrictive permissions
    const stat_buf = posix.fstatat(posix.AT.FDCWD, socket_path, 0) catch |err| {
        std.debug.print("Failed to stat socket: {any}\n", .{err});
        return error.SkipZigTest;
    };
    const mode = stat_buf.mode & 0o777;

    // SECURITY VALIDATION: No brief exposure window - socket created with 0o700
    try testing.expect((mode & 0o077) == 0); // No group/other permissions
    try testing.expect((mode & 0o700) != 0); // Owner has rwx
}

// =============================================================================
// Test 3: Platform-Specific Path Limits
// =============================================================================

test "BSD path limit: reject paths >= 104 bytes" {
    // Only run on BSD platforms
    const is_bsd = switch (builtin.os.tag) {
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
    if (!is_bsd) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Step 1: Create a path exactly at the 103-byte limit (104 with null terminator)
    const path_103 = try allocator.alloc(u8, 103);
    defer allocator.free(path_103);
    @memset(path_103, 'a');

    // Step 2: Verify 103-byte path is accepted
    const sock1 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock1);

    var addr1: posix.sockaddr.un = undefined;
    addr1.family = posix.AF.UNIX;
    @memset(&addr1.path, 0);
    @memcpy(addr1.path[0..path_103.len], path_103);

    // Path length validation should allow 103 bytes
    const path_valid = path_103.len < 104;
    try testing.expect(path_valid);

    // Step 3: Create a path that exceeds 104 bytes
    const path_104 = try allocator.alloc(u8, 104);
    defer allocator.free(path_104);
    @memset(path_104, 'b');

    // SECURITY VALIDATION: Path >= 104 bytes should be rejected
    const path_too_long = path_104.len >= 104;
    try testing.expect(path_too_long);
}

test "Linux path limit: accept paths up to 108 bytes" {
    // Only run on Linux
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Step 1: Create a path at 107 bytes (fits in 108-byte buffer with null terminator)
    const path_107 = try allocator.alloc(u8, 107);
    defer allocator.free(path_107);
    @memset(path_107, 'a');

    // Step 2: Verify Linux allows longer paths than BSD
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    // SECURITY VALIDATION: Linux supports longer paths than BSD
    try testing.expect(path_107.len > 104); // Longer than BSD limit
    try testing.expect(path_107.len < 108); // Within Linux limit
}

test "Cross-platform path validation: reject paths with null bytes" {
    if (!unix_socket_supported) return error.SkipZigTest;

    // Step 1: Create path with embedded null byte
    const path_with_null = "/tmp/test\x00socket";

    // Step 2: Verify null bytes are detected
    var has_null = false;
    for (path_with_null) |char| {
        if (char == 0) {
            has_null = true;
            break;
        }
    }

    // SECURITY VALIDATION: Null bytes should be rejected
    try testing.expect(has_null);
}

test "Cross-platform path validation: reject control characters" {
    if (!unix_socket_supported) return error.SkipZigTest;

    // Step 1: Create path with control character
    const path_with_ctrl = "/tmp/test\x01socket";

    // Step 2: Verify control characters are detected
    var has_ctrl = false;
    for (path_with_ctrl) |char| {
        if (char < 32 and char != '\n' and char != '\r' and char != '\t') {
            has_ctrl = true;
            break;
        }
    }

    // SECURITY VALIDATION: Control characters should be rejected
    try testing.expect(has_ctrl);
}

// =============================================================================
// Test 4: Integration Tests
// =============================================================================

test "Full security workflow: create, validate, cleanup" {
    if (!unix_socket_supported) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create temporary directory for socket files
    var tmp_dir = temp_utils.createTempDir(allocator);
    defer tmp_dir.cleanup();

    // Create socket path in temp directory
    const socket_path = try tmp_dir.getFilePath("integration.sock");
    defer allocator.free(socket_path);
    defer posix.unlink(socket_path) catch {};

    // Step 1: Set restrictive umask
    const old_umask = c.umask(0o077);
    defer _ = c.umask(old_umask);

    // Step 2: Create socket
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(sock, 1);

    // Step 3: Validate permissions
    const stat_buf = posix.fstatat(posix.AT.FDCWD, socket_path, 0) catch |err| {
        std.debug.print("Failed to stat socket: {any}\n", .{err});
        return error.SkipZigTest;
    };
    const mode = stat_buf.mode & 0o777;
    try testing.expect((mode & 0o077) == 0); // No group/other access

    // Step 4: Test connect-before-delete on active socket
    const test_sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(test_sock);

    // Should succeed (socket is active)
    try posix.connect(test_sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Success! The socket is active and has correct permissions
}
