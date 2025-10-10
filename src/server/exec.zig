//! Execute command on connection (-e/-c flags)
//!
//! SECURITY CRITICAL: This module handles remote command execution,
//! which is inherently dangerous. All operations log security events
//! and require explicit access control via --allow flag.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");

const session = @import("./exec_session.zig");
const threaded = @import("./exec_threaded.zig");
const types = @import("./exec_types.zig");

pub const ExecMode = types.ExecMode;
pub const ExecBufferConfig = types.ExecBufferConfig;
pub const ExecFlowConfig = types.ExecFlowConfig;
pub const ExecSessionConfig = types.ExecSessionConfig;
pub const ExecConfig = types.ExecConfig;
pub const ExecError = types.ExecError;

pub const ExecSession = session.ExecSession;
const executeWithTelnetConnectionThreaded = threaded.executeWithTelnetConnectionThreaded;

/// Execute a program with the socket as stdin/stdout/stderr
///
/// SECURITY WARNING: This function executes arbitrary programs with network I/O,
/// allowing remote clients to run commands on the server. Use with extreme caution.
///
/// Architecture:
/// 1. Spawns a child process using the provided program and arguments.
/// 2. On Unix-like systems, it uses a poll-driven session (`ExecSession`) to manage
///    I/O between the socket and the child process pipes in a single thread.
/// 3. On Windows, it falls back to a thread-per-pipe implementation (`runThreadedExec`).
/// 4. Waits for the child process to terminate and logs the result.
///
/// Memory Management:
/// - Uses ArrayList.deinit(allocator) for Zig 0.15.1 compatibility
/// - Socket and pipes closed via defer/errdefer on error paths
///
/// Parameters:
/// - allocator: Memory allocator for ArrayList operations
/// - socket: Connected client socket (already established connection)
/// - exec_config: Command configuration (program, args, mode)
/// - client_addr: Client IP address for security logging
///
/// Returns:
/// - error.ThreadSpawnFailed if I/O thread creation fails (on Windows)
/// - error.ChildWaitFailed if process termination wait fails
/// - std.process.Child.SpawnError on process spawn failure
///
/// Security:
/// - Logs SECURITY WARNING with program name and client address
/// - Displays boxed warning to stderr for operator visibility
/// - Should only be called after validateExecSecurity() check
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
        var exec_session = try session.ExecSession.init(allocator, socket, &child, exec_config.session_config);
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

    switch (term) {
        .Exited => |code| logging.log(1, "Child process exited with code: {any}\n", .{code}),
        .Signal => |sig| logging.log(1, "Child process terminated by signal: {any}\n", .{sig}),
        .Stopped => |sig| logging.log(1, "Child process stopped by signal: {any}\n", .{sig}),
        .Unknown => |code| logging.log(1, "Child process exited with unknown status: {any}\n", .{code}),
    }
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
    _: *const config.Config,
) !void {
    if (builtin.os.tag == .windows) {
        return executeWithTelnetConnectionThreaded(allocator, telnet_conn, exec_config, client_addr);
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
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

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

    switch (term) {
        .Exited => |code| logging.log(1, "Child process exited with code: {any}\n", .{code}),
        .Signal => |sig| logging.log(1, "Child process terminated by signal: {any}\n", .{sig}),
        .Stopped => |sig| logging.log(1, "Child process stopped by signal: {any}\n", .{sig}),
        .Unknown => |code| logging.log(1, "Child process exited with unknown status: {any}\n", .{code}),
    }
}
