//! Unix Domain Sockets implementation for local inter-process communication.
//!
//! This module provides a unified interface for Unix socket operations by
//! re-exporting specialized client, server, and utility modules.
//!
//! Platform support: Linux, macOS, BSD variants (not Windows)
//!
//! ## Module Organization
//!
//! - `client.zig` - Client-side operations (connect)
//! - `server.zig` - Server-side operations (bind, listen, accept)
//! - `utils.zig` - Shared utilities (validation, error handling, cleanup)

const std = @import("std");
const client = @import("unixsock/client.zig");
const server = @import("unixsock/server.zig");
const utils = @import("unixsock/utils.zig");

// Re-export public types
pub const UnixSocket = struct {
    inner: union(enum) {
        client: client.UnixClient,
        server: server.UnixServer,
    },

    /// Initialize Unix socket client for connecting to existing socket.
    pub fn initClient(allocator: std.mem.Allocator, path: []const u8) !UnixSocket {
        return UnixSocket{
            .inner = .{ .client = try client.UnixClient.init(allocator, path) },
        };
    }

    /// Initialize Unix socket server. Creates parent directories and removes
    /// existing socket files as needed. Automatically starts listening.
    pub fn initServer(allocator: std.mem.Allocator, path: []const u8) !UnixSocket {
        return UnixSocket{
            .inner = .{ .server = try server.UnixServer.init(allocator, path) },
        };
    }

    /// Connect to Unix socket server (client mode only).
    pub fn connect(self: *UnixSocket) !void {
        switch (self.inner) {
            .client => |*c| try c.connect(),
            .server => return error.InvalidOperation,
        }
    }

    /// Accept incoming connection (server mode only).
    /// Returns new socket representing the client connection.
    pub fn accept(self: *UnixSocket) !UnixSocket {
        switch (self.inner) {
            .server => |*s| {
                const sock = try s.accept();
                return UnixSocket{
                    .inner = .{ .client = client.UnixClient{
                        .socket = sock,
                        .path = "",
                        .allocator = s.allocator,
                        .path_owned = false,
                    } },
                };
            },
            .client => return error.InvalidOperation,
        }
    }

    /// Close socket without removing socket file. Use cleanup() for servers.
    pub fn close(self: *UnixSocket) void {
        switch (self.inner) {
            .client => |*c| c.close(),
            .server => |*s| s.close(),
        }
    }

    /// Close socket and remove socket file (server mode) with comprehensive error handling.
    pub fn cleanup(self: *UnixSocket) void {
        switch (self.inner) {
            .server => |*s| s.cleanup(),
            .client => |*c| c.close(),
        }
    }

    /// Close socket and remove socket file with detailed error reporting.
    pub fn cleanupVerbose(self: *UnixSocket, force_cleanup: bool) void {
        switch (self.inner) {
            .server => |*s| s.cleanupVerbose(force_cleanup),
            .client => |*c| c.close(),
        }
    }

    pub fn setNonBlocking(self: *UnixSocket) !void {
        switch (self.inner) {
            .client => |*c| try c.setNonBlocking(),
            .server => |*s| try s.setNonBlocking(),
        }
    }

    pub fn getSocket(self: *const UnixSocket) @import("socket.zig").Socket {
        return switch (self.inner) {
            .client => |*c| c.getSocket(),
            .server => |*s| s.getSocket(),
        };
    }

    pub fn getPath(self: *const UnixSocket) []const u8 {
        return switch (self.inner) {
            .client => |*c| c.getPath(),
            .server => |*s| s.getPath(),
        };
    }

    pub fn isServer(self: *const UnixSocket) bool {
        return switch (self.inner) {
            .server => true,
            .client => false,
        };
    }
};

// Re-export utilities
pub const unix_socket_supported = utils.unix_socket_supported;
pub const UnixSocketError = utils.UnixSocketError;
pub const UnixAddress = utils.UnixAddress;
pub const validatePath = utils.validatePath;
pub const checkSupport = utils.checkSupport;
pub const handleSocketError = utils.handleSocketError;
pub const getErrorMessage = utils.getErrorMessage;
pub const handleUnixSocketError = utils.handleUnixSocketError;
pub const validateUnixSocketConfiguration = utils.validateUnixSocketConfiguration;
pub const createTempPath = utils.createTempPath;

// =============================================================================
// Comprehensive Error Handling Tests
// =============================================================================

const testing = std.testing;

test "Unix socket error mapping and messages" {
    // Test error message generation
    const path_msg = getErrorMessage(UnixSocketError.PathTooLong, "/test/path", "create");
    try testing.expect(path_msg.len > 0);

    const perm_msg = getErrorMessage(UnixSocketError.PermissionDenied, "/test/path", "connect");
    try testing.expect(perm_msg.len > 0);

    const platform_msg = getErrorMessage(UnixSocketError.PlatformNotSupported, "/test/path", "init");
    try testing.expect(platform_msg.len > 0);
}

test "Unix socket error handling" {
    // Test error handling function doesn't crash
    handleUnixSocketError(UnixSocketError.PathTooLong, "/test/path", "test", true);
    handleUnixSocketError(UnixSocketError.PermissionDenied, "/test/path", "test", false);
    handleUnixSocketError(UnixSocketError.PlatformNotSupported, "/test/path", "test", true);
}

test "Unix socket path validation comprehensive" {
    // Test empty path
    try testing.expectError(UnixSocketError.InvalidPath, validatePath(""));

    // Test path too long
    const long_path = "a" ** 110;
    try testing.expectError(UnixSocketError.PathTooLong, validatePath(long_path));

    // Test path with null bytes
    const null_path = "/tmp/test\x00socket";
    try testing.expectError(UnixSocketError.PathContainsNull, validatePath(null_path));

    // Test path with control characters
    const ctrl_path = "/tmp/test\x01socket";
    try testing.expectError(UnixSocketError.InvalidPathCharacters, validatePath(ctrl_path));

    // Test valid path (may fail if directory doesn't exist, but shouldn't crash)
    validatePath("/tmp/test.sock") catch {};
}

test "Unix socket configuration validation" {
    const config = @import("../config.zig");
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test valid configuration
    validateUnixSocketConfiguration("/tmp/test.sock", &cfg, false) catch {};

    // Test with verbose mode
    validateUnixSocketConfiguration("/tmp/test.sock", &cfg, true) catch {};

    // Test invalid path
    validateUnixSocketConfiguration("", &cfg, true) catch {};
}

test "Unix socket error recovery" {
    // Test socket error mapping
    const mapped_err = handleSocketError(error.AccessDenied, "test");
    try testing.expectEqual(UnixSocketError.PermissionDenied, mapped_err);

    const network_err = handleSocketError(error.ConnectionRefused, "test");
    try testing.expectEqual(UnixSocketError.ConnectionRefused, network_err);

    const resource_err = handleSocketError(error.SystemResources, "test");
    try testing.expectEqual(UnixSocketError.ResourceExhausted, resource_err);
}

test "Unix socket support detection" {
    const builtin = @import("builtin");
    // Test platform support detection
    const expected_support = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };

    try testing.expectEqual(expected_support, unix_socket_supported);

    // Test support check function
    if (unix_socket_supported) {
        try checkSupport();
    } else {
        try testing.expectError(UnixSocketError.PlatformNotSupported, checkSupport());
    }
}
