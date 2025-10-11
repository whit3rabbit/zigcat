//! Connection abstraction layer providing unified interface for TCP, TLS, and Unix domain sockets.
//!
//! Uses tagged union to enable polymorphic operations across connection types while maintaining
//! type safety and zero-cost abstractions.

const std = @import("std");
const builtin = @import("builtin");
const tls = @import("../tls/tls.zig");
const socket_mod = @import("socket.zig");
const logging = @import("../util/logging.zig");

/// Connection type enumeration for different socket types.
pub const ConnectionType = enum {
    tcp_plain,
    tcp_tls,
    udp,
    unix_socket,
};

/// Unix domain socket platform support detection.
pub const UnixSocketSupport = struct {
    pub const available = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };

    pub fn checkSupport() !void {
        if (!available) {
            return error.UnixSocketsNotSupported;
        }
    }
};

/// Unified connection interface supporting TCP, TLS, and Unix domain sockets.
pub const Connection = union(enum) {
    plain: socket_mod.Socket,
    tls: tls.TlsConnection,
    unix_socket: struct {
        socket: socket_mod.Socket,
        path: ?[]const u8, // For cleanup tracking
    },

    /// Read data from the connection.
    /// Returns number of bytes read (0 indicates EOF).
    /// TLS connections may require multiple socket reads for one application read.
    pub fn read(self: *Connection, buffer: []u8) !usize {
        return switch (self.*) {
            .plain => |sock| {
                const result = std.posix.recv(sock, buffer, 0) catch |err| {
                    return err;
                };
                return result;
            },
            .tls => |*conn| conn.read(buffer),
            .unix_socket => |unix_conn| {
                const result = std.posix.recv(unix_conn.socket, buffer, 0) catch |err| {
                    return err;
                };
                return result;
            },
        };
    }

    /// Write data to the connection.
    /// Returns number of bytes written (may be less than data.len).
    /// TLS connections may require multiple socket writes for one application write.
    pub fn write(self: *Connection, data: []const u8) !usize {
        return switch (self.*) {
            .plain => |sock| {
                const result = std.posix.send(sock, data, 0) catch |err| {
                    return err;
                };
                return result;
            },
            .tls => |*conn| conn.write(data),
            .unix_socket => |unix_conn| {
                const result = std.posix.send(unix_conn.socket, data, 0) catch |err| {
                    return err;
                };
                return result;
            },
        };
    }

    /// Close the connection and release resources.
    /// TLS connections perform close_notify alert before closing.
    /// For Unix sockets needing file cleanup, use closeWithCleanup() instead.
    pub fn close(self: *Connection) void {
        switch (self.*) {
            .plain => |sock| socket_mod.closeSocket(sock),
            .tls => |*conn| conn.close(),
            .unix_socket => |unix_conn| socket_mod.closeSocket(unix_conn.socket),
        }
    }

    /// Close connection and remove Unix socket files if path is tracked.
    /// File removal errors are logged but don't prevent socket closure.
    pub fn closeWithCleanup(self: *Connection) void {
        switch (self.*) {
            .plain => |sock| socket_mod.closeSocket(sock),
            .tls => |*conn| conn.close(),
            .unix_socket => |unix_conn| {
                // Close the socket first
                socket_mod.closeSocket(unix_conn.socket);

                // Clean up socket file if path is tracked
                if (unix_conn.path) |path| {
                    std.fs.cwd().deleteFile(path) catch |err| {
                        logging.logDebug("Failed to remove Unix socket file '{s}': {any}\n", .{ path, err });
                    };
                }
            },
        }
    }

    /// Get underlying socket descriptor for operations like poll() or setsockopt().
    /// WARNING: Do not read/write directly on TLS connection sockets.
    pub fn getSocket(self: *Connection) socket_mod.Socket {
        return switch (self.*) {
            .plain => |sock| sock,
            .tls => |*conn| conn.getSocket(),
            .unix_socket => |unix_conn| unix_conn.socket,
        };
    }

    /// Create plain TCP connection from existing socket.
    /// Connection takes ownership of socket.
    pub fn fromSocket(sock: socket_mod.Socket) Connection {
        return .{ .plain = sock };
    }

    /// Create TLS connection from established handshake.
    /// Connection takes ownership of TLS connection and underlying socket.
    pub fn fromTls(conn: tls.TlsConnection) Connection {
        return .{ .tls = conn };
    }

    /// Create Unix domain socket connection from existing socket.
    /// Path parameter enables file cleanup via closeWithCleanup().
    pub fn fromUnixSocket(sock: socket_mod.Socket, path: ?[]const u8) Connection {
        return .{ .unix_socket = .{ .socket = sock, .path = path } };
    }

    /// Returns true if connection uses TLS encryption.
    pub fn isTls(self: *const Connection) bool {
        return switch (self.*) {
            .plain => false,
            .tls => true,
            .unix_socket => false,
        };
    }

    /// Returns true if connection uses Unix domain sockets.
    pub fn isUnixSocket(self: *const Connection) bool {
        return switch (self.*) {
            .plain => false,
            .tls => false,
            .unix_socket => true,
        };
    }

    /// Returns the connection type enum value.
    pub fn getType(self: *const Connection) ConnectionType {
        return switch (self.*) {
            .plain => .tcp_plain,
            .tls => .tcp_tls,
            .unix_socket => .unix_socket,
        };
    }
};
