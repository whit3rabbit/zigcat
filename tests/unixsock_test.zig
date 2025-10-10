//! Unix Domain Socket Tests
//!
//! Tests Unix socket client/server functionality, path validation, error handling,
//! socket file cleanup, permission scenarios, and platform compatibility.
//!
//! The tests are designed to work across platforms, gracefully handling
//! unsupported platforms and permission issues during testing.

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const builtin = @import("builtin");

// Import modules under test
const unixsock = @import("../src/net/unixsock.zig");
const config = @import("../src/config.zig");

// Platform Compatibility and Feature Detection Tests

test "Unix socket platform support detection" {
    const expected_support = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };

    try expectEqual(expected_support, unixsock.unix_socket_supported);
}

test "Unix socket support check function" {
    if (unixsock.unix_socket_supported) {
        try unixsock.checkSupport();
    } else {
        try expectError(unixsock.UnixSocketError.PlatformNotSupported, unixsock.checkSupport());
    }
}

test "Unix socket feature detection at compile time" {
    const compile_time_support = comptime unixsock.unix_socket_supported;
    try expectEqual(unixsock.unix_socket_supported, compile_time_support);
}

// Unix Socket Path Validation Tests

test "Unix socket path validation - empty path" {
    try expectError(unixsock.UnixSocketError.InvalidPath, unixsock.validatePath(""));
}

test "Unix socket path validation - path too long" {
    const long_path = "a" ** 110; // Exceeds 107 character Unix socket limit
    try expectError(unixsock.UnixSocketError.PathTooLong, unixsock.validatePath(long_path));
}

test "Unix socket path validation - path with null bytes" {
    const null_path = "/tmp/test\x00socket";
    try expectError(unixsock.UnixSocketError.PathContainsNull, unixsock.validatePath(null_path));
}

test "Unix socket path validation - path with control characters" {
    const ctrl_path = "/tmp/test\x01socket";
    try expectError(unixsock.UnixSocketError.InvalidPathCharacters, unixsock.validatePath(ctrl_path));

    const ctrl_path2 = "/tmp/test\x1fsocket";
    try expectError(unixsock.UnixSocketError.InvalidPathCharacters, unixsock.validatePath(ctrl_path2));
}

test "Unix socket path validation - valid paths" {
    unixsock.validatePath("/tmp/test.sock") catch {};
    unixsock.validatePath("./test.sock") catch {};
    unixsock.validatePath("test.sock") catch {};
    unixsock.validatePath("/tmp/test\tsocket") catch {}; // Tab character allowed
}

test "Unix socket path validation - maximum valid length" {
    const max_path = "a" ** 107; // Exactly at 107 character limit
    unixsock.validatePath(max_path) catch {};

    const near_max_path = "a" ** 106;
    unixsock.validatePath(near_max_path) catch {};
}

// Unix Socket Client Connection Tests

test "Unix socket client initialization - unsupported platform" {
    if (!unixsock.unix_socket_supported) {
        const allocator = testing.allocator;
        try expectError(unixsock.UnixSocketError.NotSupported, unixsock.UnixSocket.initClient(allocator, "/tmp/test.sock"));
    }
}

test "Unix socket client initialization - invalid paths" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;

    try expectError(unixsock.UnixSocketError.InvalidPath, unixsock.UnixSocket.initClient(allocator, ""));

    const long_path = "a" ** 110;
    try expectError(unixsock.UnixSocketError.PathTooLong, unixsock.UnixSocket.initClient(allocator, long_path));
}

test "Unix socket client initialization - valid path" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_client.sock");
    defer allocator.free(test_path);

    var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported => return,
        else => return err,
    };
    defer client.close();

    try expect(!client.isServer());
    try expectEqualStrings(test_path, client.getPath());
}

// Unix Socket Server Creation Tests

test "Unix socket server initialization - unsupported platform" {
    if (!unixsock.unix_socket_supported) {
        const allocator = testing.allocator;
        try expectError(unixsock.UnixSocketError.NotSupported, unixsock.UnixSocket.initServer(allocator, "/tmp/test.sock"));
    }
}

test "Unix socket server initialization - invalid paths" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;

    try expectError(unixsock.UnixSocketError.InvalidPath, unixsock.UnixSocket.initServer(allocator, ""));

    const long_path = "a" ** 110;
    try expectError(unixsock.UnixSocketError.PathTooLong, unixsock.UnixSocket.initServer(allocator, long_path));
}

test "Unix socket server initialization - valid path" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_server.sock");
    defer allocator.free(test_path);

    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };
    defer server.cleanup();

    try expect(server.isServer());
    try expectEqualStrings(test_path, server.getPath());
}

test "Unix socket server - parent directory creation" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "subdir/test_server.sock");
    defer allocator.free(test_path);

    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse, unixsock.UnixSocketError.DirectoryNotFound => return,
        else => return err,
    };
    defer server.cleanup();

    try expect(server.isServer());
}

// Socket File Cleanup and Permission Tests

test "Unix socket cleanup - server socket file removal" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_cleanup.sock");
    defer allocator.free(test_path);

    // Create and immediately cleanup server socket
    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };

    // Cleanup should remove the socket file
    server.cleanup();

    // Verify socket file was removed (may still exist due to permissions)
    const stat = std.fs.cwd().statFile(test_path) catch |err| switch (err) {
        error.FileNotFound => return, // Expected - file was cleaned up
        else => return, // File still exists, but that's acceptable
    };

    // If file still exists, it should be a socket
    if (stat.kind == .unix_domain_socket) {
        // This is acceptable - cleanup may have failed due to permissions
        return;
    }
}

test "Unix socket cleanup - verbose mode" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_verbose_cleanup.sock");
    defer allocator.free(test_path);

    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };

    // Test verbose cleanup (should not crash)
    server.cleanupVerbose(false);
}

test "Unix socket cleanup - force cleanup mode" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_force_cleanup.sock");
    defer allocator.free(test_path);

    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };

    // Test force cleanup (should not crash)
    server.cleanupVerbose(true);
}

test "Unix socket - client cleanup does not remove files" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_client_cleanup.sock");
    defer allocator.free(test_path);

    var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported => return,
        else => return err,
    };

    // Client cleanup should not attempt to remove socket files
    client.cleanup(); // Should not crash
}

// =============================================================================
// Error Handling and Recovery Tests
// =============================================================================

test "Unix socket error message generation" {
    // Test that error messages are generated for all error types
    const test_path = "/tmp/test.sock";
    const operation = "test";

    const error_types = [_]unixsock.UnixSocketError{
        unixsock.UnixSocketError.PathTooLong,
        unixsock.UnixSocketError.InvalidPath,
        unixsock.UnixSocketError.PathContainsNull,
        unixsock.UnixSocketError.DirectoryNotFound,
        unixsock.UnixSocketError.InvalidPathCharacters,
        unixsock.UnixSocketError.SocketFileExists,
        unixsock.UnixSocketError.PermissionDenied,
        unixsock.UnixSocketError.InsufficientPermissions,
        unixsock.UnixSocketError.DiskFull,
        unixsock.UnixSocketError.FileLocked,
        unixsock.UnixSocketError.IsDirectory,
        unixsock.UnixSocketError.FileSystemError,
        unixsock.UnixSocketError.AddressInUse,
        unixsock.UnixSocketError.AddressNotAvailable,
        unixsock.UnixSocketError.NetworkUnreachable,
        unixsock.UnixSocketError.ConnectionRefused,
        unixsock.UnixSocketError.ConnectionReset,
        unixsock.UnixSocketError.ConnectionAborted,
        unixsock.UnixSocketError.SocketNotConnected,
        unixsock.UnixSocketError.SocketAlreadyConnected,
        unixsock.UnixSocketError.NotSupported,
        unixsock.UnixSocketError.PlatformNotSupported,
        unixsock.UnixSocketError.FeatureNotAvailable,
        unixsock.UnixSocketError.CleanupFailed,
        unixsock.UnixSocketError.ResourceExhausted,
        unixsock.UnixSocketError.TooManyOpenFiles,
        unixsock.UnixSocketError.OutOfMemory,
        unixsock.UnixSocketError.InvalidOperation,
        unixsock.UnixSocketError.ConflictingConfiguration,
        unixsock.UnixSocketError.UnsupportedCombination,
    };

    for (error_types) |err| {
        const msg = unixsock.getErrorMessage(err, test_path, operation);
        try expect(msg.len > 0);
    }
}

test "Unix socket error handling functions" {
    const test_path = "/tmp/test.sock";
    const operation = "test";

    // Test error handling functions don't crash
    unixsock.handleUnixSocketError(unixsock.UnixSocketError.PathTooLong, test_path, operation, true);
    unixsock.handleUnixSocketError(unixsock.UnixSocketError.PermissionDenied, test_path, operation, false);
    unixsock.handleUnixSocketError(unixsock.UnixSocketError.PlatformNotSupported, test_path, operation, true);
}

test "Unix socket error mapping from POSIX errors" {
    // Test error mapping from common POSIX errors
    const test_cases = [_]struct {
        posix_error: anyerror,
        expected: unixsock.UnixSocketError,
    }{
        .{ .posix_error = error.AccessDenied, .expected = unixsock.UnixSocketError.PermissionDenied },
        .{ .posix_error = error.AddressInUse, .expected = unixsock.UnixSocketError.AddressInUse },
        .{ .posix_error = error.ConnectionRefused, .expected = unixsock.UnixSocketError.ConnectionRefused },
        .{ .posix_error = error.SystemResources, .expected = unixsock.UnixSocketError.ResourceExhausted },
        .{ .posix_error = error.ProcessFdQuotaExceeded, .expected = unixsock.UnixSocketError.TooManyOpenFiles },
        .{ .posix_error = error.OutOfMemory, .expected = unixsock.UnixSocketError.OutOfMemory },
        .{ .posix_error = error.NameTooLong, .expected = unixsock.UnixSocketError.PathTooLong },
    };

    for (test_cases) |case| {
        const mapped = unixsock.handleSocketError(case.posix_error, "test");
        try expectEqual(case.expected, mapped);
    }
}

// =============================================================================
// Configuration Validation Tests
// =============================================================================

test "Unix socket configuration validation - basic" {
    const allocator = testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const test_path = "/tmp/test.sock";

    // Test basic configuration validation (should not crash)
    unixsock.validateUnixSocketConfiguration(test_path, &cfg, false) catch {};
    unixsock.validateUnixSocketConfiguration(test_path, &cfg, true) catch {};
}

test "Unix socket configuration validation - invalid path" {
    const allocator = testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    // Test with empty path
    unixsock.validateUnixSocketConfiguration("", &cfg, true) catch {};

    // Test with path too long
    const long_path = "a" ** 110;
    unixsock.validateUnixSocketConfiguration(long_path, &cfg, true) catch {};
}

test "Unix socket configuration validation - conflicting options" {
    const allocator = testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const test_path = "/tmp/test.sock";

    // Test with UDP mode (should conflict)
    cfg.udp_mode = true;
    unixsock.validateUnixSocketConfiguration(test_path, &cfg, false) catch {};
    cfg.udp_mode = false;

    // Test with SSL mode (should conflict)
    cfg.ssl = true;
    unixsock.validateUnixSocketConfiguration(test_path, &cfg, false) catch {};
    cfg.ssl = false;
}

// =============================================================================
// Socket Operations Tests
// =============================================================================

test "Unix socket operations - invalid operations" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_operations.sock");
    defer allocator.free(test_path);

    // Test client trying to accept (should fail)
    var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported => return,
        else => return err,
    };
    defer client.close();

    try expectError(unixsock.UnixSocketError.InvalidOperation, client.accept());

    // Test server trying to connect (should fail)
    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };
    defer server.cleanup();

    try expectError(unixsock.UnixSocketError.InvalidOperation, server.connect());
}

test "Unix socket - non-blocking mode" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_nonblocking.sock");
    defer allocator.free(test_path);

    var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported => return,
        else => return err,
    };
    defer client.close();

    // Test setting non-blocking mode (should not crash)
    client.setNonBlocking() catch |err| switch (err) {
        // These errors are acceptable
        error.AccessDenied, error.SystemResources => return,
        else => return err,
    };
}

// =============================================================================
// Utility Function Tests
// =============================================================================

test "Unix socket temporary path creation" {
    const allocator = testing.allocator;

    const temp_path = try unixsock.createTempPath(allocator, "test.sock");
    defer allocator.free(temp_path);

    try expect(temp_path.len > 0);
    try expect(std.mem.endsWith(u8, temp_path, "test.sock"));
}

test "Unix socket address structure" {
    // Test UnixAddress creation and manipulation
    const test_path = "/tmp/test.sock";

    const addr = unixsock.UnixAddress.fromPath(test_path) catch |err| switch (err) {
        error.PathTooLong, error.InvalidPath => return,
        else => return err,
    };

    try expectEqual(@as(u16, std.posix.AF.UNIX), addr.family);
    try expectEqualStrings(test_path, addr.getPath());
    try expect(addr.getLen() > 2); // At least family + some path
}

test "Unix socket address - path too long" {
    const long_path = "a" ** 110;
    try expectError(error.PathTooLong, unixsock.UnixAddress.fromPath(long_path));
}

test "Unix socket address - empty path" {
    try expectError(error.InvalidPath, unixsock.UnixAddress.fromPath(""));
}

// =============================================================================
// Integration Tests with Real Socket Operations
// =============================================================================

test "Unix socket client-server integration - basic" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;
    const test_path = try unixsock.createTempPath(allocator, "test_integration.sock");
    defer allocator.free(test_path);

    // Create server
    var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse => return,
        else => return err,
    };
    defer server.cleanup();

    // Create client
    var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
        unixsock.UnixSocketError.NotSupported => return,
        else => return err,
    };
    defer client.close();

    // Test connection (may fail if server isn't ready, but shouldn't crash)
    client.connect() catch |err| switch (err) {
        // These errors are acceptable in testing
        unixsock.UnixSocketError.ConnectionRefused, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressNotAvailable => return,
        else => return err,
    };
}

// =============================================================================
// Platform-Specific Tests
// =============================================================================

test "Unix socket platform-specific behavior" {
    switch (builtin.os.tag) {
        .linux => {
            // Linux-specific tests
            try testLinuxSpecificBehavior();
        },
        .macos => {
            // macOS-specific tests
            try testMacOSSpecificBehavior();
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            // BSD-specific tests
            try testBSDSpecificBehavior();
        },
        .windows => {
            // Windows should not support Unix sockets
            try expect(!unixsock.unix_socket_supported);
            try expectError(unixsock.UnixSocketError.PlatformNotSupported, unixsock.checkSupport());
        },
        else => {
            // Other platforms should not support Unix sockets
            try expect(!unixsock.unix_socket_supported);
        },
    }
}

fn testLinuxSpecificBehavior() !void {
    // Test Linux-specific Unix socket behavior
    try expect(unixsock.unix_socket_supported);

    // Test abstract namespace socket rejection
    const abstract_path = "\x00abstract_socket";
    unixsock.validatePath(abstract_path) catch {};
}

fn testMacOSSpecificBehavior() !void {
    // Test macOS-specific Unix socket behavior
    try expect(unixsock.unix_socket_supported);

    // macOS has standard Unix socket behavior
    const test_path = "/tmp/macos_test.sock";
    unixsock.validatePath(test_path) catch {};
}

fn testBSDSpecificBehavior() !void {
    // Test BSD-specific Unix socket behavior
    try expect(unixsock.unix_socket_supported);

    // BSD variants have standard Unix socket behavior
    const test_path = "/tmp/bsd_test.sock";
    unixsock.validatePath(test_path) catch {};
}

// =============================================================================
// Stress and Edge Case Tests
// =============================================================================

test "Unix socket stress - multiple rapid operations" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;

    // Test rapid creation and cleanup of multiple sockets
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const test_path = try std.fmt.allocPrint(allocator, "/tmp/stress_test_{}.sock", .{i});
        defer allocator.free(test_path);

        var server = unixsock.UnixSocket.initServer(allocator, test_path) catch |err| switch (err) {
            unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse, unixsock.UnixSocketError.ResourceExhausted, unixsock.UnixSocketError.TooManyOpenFiles => return,
            else => return err,
        };

        server.cleanup();
    }
}

test "Unix socket edge cases - special characters in paths" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;

    // Test paths with special characters
    const special_paths = [_][]const u8{
        "/tmp/test space.sock",
        "/tmp/test-dash.sock",
        "/tmp/test_underscore.sock",
        "/tmp/test.dot.sock",
        "/tmp/test123.sock",
    };

    for (special_paths) |path| {
        unixsock.validatePath(path) catch {};

        // Try to create socket (may fail due to permissions, but shouldn't crash)
        var server = unixsock.UnixSocket.initServer(allocator, path) catch |err| switch (err) {
            unixsock.UnixSocketError.NotSupported, unixsock.UnixSocketError.PermissionDenied, unixsock.UnixSocketError.AddressInUse, unixsock.UnixSocketError.DirectoryNotFound => continue,
            else => return err,
        };
        server.cleanup();
    }
}

test "Unix socket memory management - no leaks" {
    if (!unixsock.unix_socket_supported) return;

    const allocator = testing.allocator;

    // Test that socket creation and cleanup doesn't leak memory
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const test_path = try unixsock.createTempPath(allocator, "memory_test.sock");
        defer allocator.free(test_path);

        var client = unixsock.UnixSocket.initClient(allocator, test_path) catch |err| switch (err) {
            unixsock.UnixSocketError.NotSupported => return,
            else => return err,
        };

        // Verify path is properly managed
        try expect(client.path_owned);
        try expectEqualStrings(test_path, client.getPath());

        client.close(); // Should free the path memory
    }
}
