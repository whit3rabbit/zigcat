//! Unix Domain Socket server implementation.
//!
//! Handles server-side Unix socket operations including initialization,
//! binding, listening, and accepting connections.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_mod = @import("../socket.zig");
const utils = @import("utils.zig");
const logging = @import("../../util/logging.zig");

/// Unix socket server structure.
pub const UnixServer = struct {
    socket: socket_mod.Socket,
    path: []const u8,
    allocator: std.mem.Allocator,
    path_owned: bool,

    /// Initialize Unix socket server. Creates parent directories and removes
    /// existing socket files as needed. Automatically starts listening.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !UnixServer {
        if (!utils.unix_socket_supported) {
            return error.NotSupported;
        }

        if (path.len == 0) return error.InvalidPath;
        if (path.len >= 108) return error.PathTooLong;

        // Create parent directory if needed
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Handle existing socket file (uses connect-before-delete to avoid TOCTTOU)
        try utils.handleExistingSocketFile(path);

        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer socket_mod.closeSocket(sock);

        const addr = try utils.UnixAddress.fromPath(path);

        // SECURITY: Set restrictive umask before creating socket file
        // This prevents brief exposure with permissive default umask permissions
        // Socket file will be created with 0o700 (rwx------) permissions
        // Platform-specific umask handling
        var old_umask: std.posix.mode_t = undefined;
        if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd) {
            // Use system call directly on Unix-like systems
            old_umask = std.posix.system.umask(0o077);
        }
        defer {
            if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd) {
                _ = std.posix.system.umask(old_umask);
            }
        }

        try posix.bind(sock, @ptrCast(&addr), addr.getLen());
        errdefer std.fs.cwd().deleteFile(path) catch {};

        try posix.listen(sock, 128);

        // SECURITY: Validate socket file permissions before accepting connections
        const security = @import("../../util/security.zig");
        security.validateUnixSocketPermissions(path) catch |err| {
            // Log validation errors but don't fail server startup
            // FileNotFound is expected on some platforms/race conditions
            if (err != error.FileNotFound and err != error.AccessDenied) {
                logging.logWarning("Socket permission validation failed: {any}\n", .{err});
            }
        };

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return UnixServer{
            .socket = sock,
            .path = owned_path,
            .allocator = allocator,
            .path_owned = true,
        };
    }

    /// Accept incoming connection. Returns new socket representing the client.
    pub fn accept(self: *UnixServer) !socket_mod.Socket {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        return try posix.accept(self.socket, &addr, &addr_len, 0);
    }

    /// Close socket without removing socket file. Use cleanup() for full cleanup.
    pub fn close(self: *UnixServer) void {
        socket_mod.closeSocket(self.socket);
        if (self.path_owned) {
            self.allocator.free(self.path);
        }
    }

    /// Close socket and remove socket file with comprehensive error handling.
    pub fn cleanup(self: *UnixServer) void {
        utils.cleanupUnixSocketResources(
            self.socket,
            self.path,
            true, // is_server
            self.path_owned,
            false, // force_cleanup
            false, // verbose
        );
        if (self.path_owned) {
            self.allocator.free(self.path);
        }
    }

    /// Close socket and remove socket file with detailed error reporting.
    pub fn cleanupVerbose(self: *UnixServer, force_cleanup: bool) void {
        utils.cleanupUnixSocketResources(
            self.socket,
            self.path,
            true, // is_server
            self.path_owned,
            force_cleanup,
            true, // verbose
        );
        if (self.path_owned) {
            self.allocator.free(self.path);
        }
    }

    /// Set socket to non-blocking mode.
    pub fn setNonBlocking(self: *UnixServer) !void {
        try socket_mod.setNonBlocking(self.socket);
    }

    /// Get underlying socket descriptor.
    pub fn getSocket(self: *const UnixServer) socket_mod.Socket {
        return self.socket;
    }

    /// Get socket path.
    pub fn getPath(self: *const UnixServer) []const u8 {
        return self.path;
    }
};
