//! Unix Domain Socket client implementation.
//!
//! Handles client-side Unix socket operations including initialization
//! and connection establishment.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_mod = @import("../socket.zig");
const utils = @import("utils.zig");
const logging = @import("../../util/logging.zig");

/// Unix socket client structure.
pub const UnixClient = struct {
    socket: socket_mod.Socket,
    path: []const u8,
    allocator: std.mem.Allocator,
    path_owned: bool,

    /// Initialize Unix socket client for connecting to existing socket.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !UnixClient {
        if (!utils.unix_socket_supported) {
            return error.NotSupported;
        }

        if (path.len == 0) return error.InvalidPath;
        if (path.len >= 108) return error.PathTooLong;

        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer socket_mod.closeSocket(sock);

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return UnixClient{
            .socket = sock,
            .path = owned_path,
            .allocator = allocator,
            .path_owned = true,
        };
    }

    /// Connect to Unix socket server.
    pub fn connect(self: *UnixClient) !void {
        const addr = try utils.UnixAddress.fromPath(self.path);
        try posix.connect(self.socket, @ptrCast(&addr), addr.getLen());
    }

    /// Close socket and free resources.
    pub fn close(self: *UnixClient) void {
        socket_mod.closeSocket(self.socket);
        if (self.path_owned) {
            self.allocator.free(self.path);
        }
    }

    /// Set socket to non-blocking mode.
    pub fn setNonBlocking(self: *UnixClient) !void {
        try socket_mod.setNonBlocking(self.socket);
    }

    /// Get underlying socket descriptor.
    pub fn getSocket(self: *const UnixClient) socket_mod.Socket {
        return self.socket;
    }

    /// Get socket path.
    pub fn getPath(self: *const UnixClient) []const u8 {
        return self.path;
    }
};
