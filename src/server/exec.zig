// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Execute command on connection (-e/-c flags)
//!
//! SECURITY CRITICAL: This module handles remote command execution,
//! which is inherently dangerous. All operations log security events
//! and require explicit access control via --allow flag.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");

const session = @import("./exec_session/mod.zig");
const threaded = @import("./exec_threaded.zig");
const types = @import("./exec_types.zig");
const platform = @import("../util/platform.zig");

pub const ExecMode = types.ExecMode;
pub const ExecBufferConfig = types.ExecBufferConfig;
pub const ExecFlowConfig = types.ExecFlowConfig;
pub const ExecSessionConfig = types.ExecSessionConfig;
pub const ExecConfig = types.ExecConfig;
pub const ExecError = types.ExecError;

pub const ExecSession = session.ExecSession;
const executeWithTelnetConnectionThreaded = threaded.executeWithTelnetConnectionThreaded;

/// Executes a command, binding its standard I/O streams to a network connection.
///
/// This is a security-critical function that allows a remote client to execute
/// arbitrary commands on the server. It should only be called after thorough
/// security validation, such as checks performed by `config.security.validateExecSecurity`.
///
/// ## Security
/// - **Remote Code Execution**: This function's primary purpose is to enable RCE.
///   It is imperative that its usage is restricted to trusted clients and environments.
/// - **Logging**: A prominent security warning is always logged to stderr and the
///   application log, detailing the command being executed and the client's address.
///
/// ## Platform Support
/// The I/O handling between the socket and the child process is platform-dependent:
/// - **Linux (Kernel 5.1+)**: Uses `io_uring` for high-performance, single-threaded,
///   asynchronous I/O multiplexing.
/// - **Other Unix-like Systems (e.g., macOS, BSD)**: Falls back to a `poll(2)`-based
///   event loop, managing I/O in a single thread.
/// - **Windows**: Uses a multi-threaded approach (`exec_threaded.zig`), where each
///   I/O stream (stdin, stdout, stderr) is managed by a dedicated thread.
///
/// ## Resource Management
/// - **Socket Ownership**: This function takes ownership of the `socket`. The socket is
///   wrapped in `net.Connection` and `protocol.TelnetConnection` types, and its
///   file descriptor is closed automatically when those wrappers are deinited at the
///   end of the function's scope.
/// - **Child Process**: The child process is spawned and its pipes are created.
///   `defer` and `errdefer` statements ensure that pipes are closed, the process is
///   killed on error, and `wait()` is called to reap the process, preventing zombies.
///
/// ## Error Conditions
/// This function can return a variety of errors, including but not limited to:
/// - `std.process.Child.SpawnError`: If the command cannot be spawned (e.g., not found).
/// - `error.ThreadSpawnFailed`: On Windows, if I/O threads cannot be created.
/// - `error.IoUringNotSupported`: If `io_uring` initialization fails (will fallback to poll).
/// - `error.OutOfMemory`: If memory allocation for arguments or buffers fails.
/// - Any I/O error from the underlying session (`ExecSession`) during the data relay.
///
/// @param allocator The memory allocator.
/// @param socket The connected client socket. The function takes ownership of this socket.
/// @param exec_config The configuration for the command to execute, including program,
///        arguments, and I/O redirection settings.
/// @param client_addr The address of the connected client, used for logging.
pub fn executeWithConnection(
    allocator: std.mem.Allocator,
    socket: std.net.Stream,
    exec_config: ExecConfig,
    client_addr: std.net.Address,
    _: *const config.Config,
) !void {
    // SECURITY WARNING: Log this dangerous operation (always printed)
    logging.logWarning("╔══════════════════════════════════════════╗\n", .{});
    logging.logWarning("║ SECURITY: Executing command              ║\n", .{});
    logging.logWarning("║ Program: {s:<31}║\n", .{exec_config.program});
    logging.logWarning("║ Client:  {any:<31}║\n", .{client_addr});
    logging.logWarning("║ Mode:    {s:<31}║\n", .{@tagName(exec_config.mode)});
    logging.logWarning("╚══════════════════════════════════════════╝\n", .{});

    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exec_config.program);
    for (exec_config.args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    if (exec_config.redirect_stdin) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Inherit;
    }
    if (exec_config.redirect_stdout) {
        child.stdout_behavior = .Pipe;
    } else {
        child.stdout_behavior = .Inherit;
    }
    if (exec_config.redirect_stderr) {
        child.stderr_behavior = .Pipe;
    } else {
        child.stderr_behavior = .Inherit;
    }

    try child.spawn();
    errdefer {
        closeChildPipes(&child);
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    if (builtin.os.tag == .windows) {
        threaded.runThreadedExec(socket, &child) catch |err| {
            closeChildPipes(&child);
            _ = child.kill() catch {};
            return err;
        };
    } else {
        // Wrap socket in Connection and TelnetConnection for protocol handling
        const connection = @import("../net/connection.zig").Connection.fromSocket(socket.handle);
        var telnet_conn = try @import("../protocol/telnet_connection.zig").fromConnection(connection, allocator);
        defer telnet_conn.deinit();

        // ExecSession.init() automatically selects best backend (io_uring or poll)
        var exec_session = try session.ExecSession.init(allocator, &telnet_conn, &child, exec_config.session_config);
        defer exec_session.deinit();

        exec_session.run() catch |err| {
            closeChildPipes(&child);
            _ = child.kill() catch {};
            return err;
        };
    }

    closeChildPipes(&child);

    const term = child.wait() catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => logging.logError(err, "Failed to wait for child"),
        }
        return err;
    };

    logChildTermination(term);
}

/// Ensure child process pipes are closed and optionals cleared.
pub fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |file| {
        file.close();
        child.stdin = null;
    }
    if (child.stdout) |file| {
        file.close();
        child.stdout = null;
    }
    if (child.stderr) |file| {
        file.close();
        child.stderr = null;
    }
}

/// Log child process termination status
fn logChildTermination(term: std.process.Child.Term) void {
    switch (term) {
        .Exited => |code| logging.log(1, "Child process exited with code: {any}\n", .{code}),
        .Signal => |sig| logging.log(1, "Child process terminated by signal: {any}\n", .{sig}),
        .Stopped => |sig| logging.log(1, "Child process stopped by signal: {any}\n", .{sig}),
        .Unknown => |code| logging.log(1, "Child process exited with unknown status: {any}\n", .{code}),
    }
}

/// Build shell command for -c mode
pub fn buildShellCommand(
    allocator: std.mem.Allocator,
    command_string: []const u8,
) !struct { program: []const u8, args: []const []const u8 } {
    const shell_path = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
    const shell_arg = if (builtin.os.tag == .windows) "/c" else "-c";

    const args_arr = try allocator.alloc([]const u8, 2);
    args_arr[0] = shell_arg;
    args_arr[1] = command_string;

    return .{
        .program = shell_path,
        .args = args_arr,
    };
}

test "buildShellCommand Unix" {
    const allocator = std.testing.allocator;

    const result = try buildShellCommand(allocator, "echo hello");
    defer allocator.free(result.args);

    if (builtin.os.tag != .windows) {
        try std.testing.expectEqualStrings("/bin/sh", result.program);
        try std.testing.expectEqual(@as(usize, 2), result.args.len);
        try std.testing.expectEqualStrings("-c", result.args[0]);
    }
}

pub fn executeWithTelnetConnection(
    allocator: std.mem.Allocator,
    telnet_conn: anytype,
    exec_config: ExecConfig,
    client_addr: std.net.Address,
    cfg: *const config.Config,
) !void {
    if (builtin.os.tag == .windows) {
        return executeWithTelnetConnectionThreaded(allocator, telnet_conn, exec_config, client_addr, cfg);
    }

    // POSIX implementation using ExecSession
    logging.log(1, "Executing command with Telnet...\n", .{});

    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exec_config.program);
    for (exec_config.args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    if (exec_config.redirect_stdin) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Inherit;
    }
    if (exec_config.redirect_stdout) {
        child.stdout_behavior = .Pipe;
    } else {
        child.stdout_behavior = .Inherit;
    }
    if (exec_config.redirect_stderr) {
        child.stderr_behavior = .Pipe;
    } else {
        child.stderr_behavior = .Inherit;
    }

    try child.spawn();
    errdefer {
        closeChildPipes(&child);
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // ExecSession.init() automatically selects best backend (io_uring or poll)
    var exec_session = try session.ExecSession.init(allocator, telnet_conn, &child, exec_config.session_config);
    defer exec_session.deinit();

    exec_session.run() catch |err| {
        closeChildPipes(&child);
        _ = child.kill() catch {};
        return err;
    };

    closeChildPipes(&child);

    const term = child.wait() catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => logging.logError(err, "Failed to wait for child"),
        }
        return err;
    };

    logChildTermination(term);
}
