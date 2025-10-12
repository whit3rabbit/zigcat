//! Windows Unix Socket Backend Selection
//!
//! This module provides automatic backend selection for Unix socket support on Windows:
//! - Windows 10 RS4+ (Build 17063+): Native AF_UNIX sockets (preferred)
//! - Older Windows (7/8/10 pre-RS4): Windows Named Pipes (fallback)
//!
//! The API is transparent to callers - they use UnixServer regardless of backend.

const std = @import("std");
const builtin = @import("builtin");

// This module is Windows-only
comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_backend.zig is Windows-only. Use Unix sockets on other platforms.");
    }
}

const windows = std.os.windows;
const posix = std.posix;
const socket_mod = @import("../socket.zig");
const utils = @import("../unixsock/utils.zig");
const windows_pipe = @import("pipe.zig");
const logging = @import("../../util/logging.zig");

/// Backend type for Windows Unix socket implementation
pub const WindowsBackendType = enum {
    af_unix, // Native AF_UNIX sockets (Windows 10 RS4+)
    named_pipe, // Windows Named Pipes (fallback for older Windows)
};

/// Detect which Windows backend to use
///
/// Returns:
/// - .af_unix if Windows 10 Build 17063+ (supports AF_UNIX)
/// - .named_pipe for older Windows versions
pub fn detectBackend() WindowsBackendType {
    if (builtin.os.tag != .windows) {
        @compileError("detectBackend() is Windows-only");
    }

    // Check if Windows version supports AF_UNIX (Build 17063+ / RS4)
    const supports_af_unix = builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false;

    if (supports_af_unix) {
        logging.log(1, "Using AF_UNIX backend (Windows 10 RS4+)\n", .{});
        return .af_unix;
    } else {
        logging.log(1, "Using Named Pipes backend (Windows < 10 RS4)\n", .{});
        return .named_pipe;
    }
}

/// Windows-specific server handle (union of AF_UNIX socket or Named Pipe)
pub const WindowsServerHandle = union(WindowsBackendType) {
    af_unix: socket_mod.Socket,
    named_pipe: windows_pipe.NamedPipeServer,

    /// Initialize Windows server with automatic backend selection
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !WindowsServerHandle {
        const backend = detectBackend();

        switch (backend) {
            .af_unix => {
                // Use native AF_UNIX sockets (Windows 10 RS4+)
                const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
                errdefer socket_mod.closeSocket(sock);

                const addr = try utils.UnixAddress.fromPath(path);

                // Apply ACL permissions after bind
                try posix.bind(sock, @ptrCast(&addr), addr.getLen());
                errdefer std.fs.cwd().deleteFile(path) catch {};

                const win_security = @import("../../util/windows_security.zig");
                win_security.setSocketPermissions(path, 0o700) catch |err| {
                    logging.logWarning("Failed to set Windows socket permissions: {any}\n", .{err});
                };

                try posix.listen(sock, 128);

                return WindowsServerHandle{ .af_unix = sock };
            },
            .named_pipe => {
                // Use Named Pipes fallback (older Windows)
                const pipe_config = windows_pipe.PipeConfig{
                    .reject_remote = true,
                    .first_instance = true,
                    .use_custom_security = true,
                };

                const pipe_server = try windows_pipe.NamedPipeServer.init(
                    allocator,
                    path,
                    pipe_config,
                );

                return WindowsServerHandle{ .named_pipe = pipe_server };
            },
        }
    }

    /// Accept client connection (blocks)
    ///
    /// For AF_UNIX: Returns new socket FD
    /// For Named Pipes: Returns void (same handle reused)
    pub fn accept(self: *WindowsServerHandle) !?socket_mod.Socket {
        switch (self.*) {
            .af_unix => |sock| {
                var addr: posix.sockaddr = undefined;
                var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
                const client_sock = try posix.accept(sock, &addr, &addr_len, 0);
                return client_sock;
            },
            .named_pipe => |*pipe_server| {
                try pipe_server.accept();
                return null; // Named Pipe reuses same handle
            },
        }
    }

    /// Get handle for I/O operations
    ///
    /// For AF_UNIX: Returns server socket (use accept() return value for I/O)
    /// For Named Pipes: Returns pipe handle (use this for I/O)
    pub fn getHandle(self: *const WindowsServerHandle) socket_mod.Socket {
        switch (self.*) {
            .af_unix => |sock| return sock,
            .named_pipe => |*pipe_server| {
                // Named Pipe HANDLE needs to be cast to Socket type
                // On Windows, socket_t is usize and HANDLE is *anyopaque
                return @intFromPtr(pipe_server.getHandle());
            },
        }
    }

    /// Disconnect client (Named Pipes only)
    ///
    /// For AF_UNIX: No-op (close client socket separately)
    /// For Named Pipes: Required between clients
    pub fn disconnect(self: *WindowsServerHandle) !void {
        switch (self.*) {
            .af_unix => {
                // No-op for AF_UNIX (caller closes client socket)
            },
            .named_pipe => |*pipe_server| {
                try pipe_server.disconnect();
            },
        }
    }

    /// Check if client is connected (Named Pipes only)
    pub fn isConnected(self: *const WindowsServerHandle) bool {
        switch (self.*) {
            .af_unix => return false, // Not applicable
            .named_pipe => |*pipe_server| return pipe_server.isConnected(),
        }
    }

    /// Clean up resources
    pub fn deinit(self: *WindowsServerHandle) void {
        switch (self.*) {
            .af_unix => |sock| {
                socket_mod.closeSocket(sock);
            },
            .named_pipe => |*pipe_server| {
                pipe_server.deinit();
            },
        }
    }
};

/// Windows-specific client connection with automatic backend selection
pub fn connectWindowsClient(
    allocator: std.mem.Allocator,
    path: []const u8,
    timeout_ms: u32,
) !socket_mod.Socket {
    const backend = detectBackend();

    switch (backend) {
        .af_unix => {
            // Use native AF_UNIX socket connection
            const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            errdefer socket_mod.closeSocket(sock);

            const addr = try utils.UnixAddress.fromPath(path);

            try posix.connect(sock, @ptrCast(&addr), addr.getLen());

            return sock;
        },
        .named_pipe => {
            // Use Named Pipe connection
            const handle = try windows_pipe.connectToNamedPipe(
                allocator,
                path,
                timeout_ms,
            );

            // Cast HANDLE to Socket type
            return @intFromPtr(handle);
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "detectBackend" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const backend = detectBackend();

    // Verify backend is valid
    try std.testing.expect(backend == .af_unix or backend == .named_pipe);
}
