// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Thread-based execution logic for Windows and Telnet.
const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");

const ExecConfig = @import("./exec_types.zig").ExecConfig;
const ExecError = @import("./exec_types.zig").ExecError;

/// Manages a command execution session using a separate thread for each I/O stream.
///
/// This function serves as a fallback I/O mechanism when more advanced,
/// single-threaded event loops (like `io_uring` or `iocp`) are not available.
/// It spawns up to three threads:
/// 1. A thread to pipe data from the network stream to the child's stdin.
/// 2. A thread to pipe data from the child's stdout to the network stream.
/// 3. A thread to pipe data from the child's stderr to the network stream.
///
/// The function waits for all spawned threads to complete before returning.
pub fn runThreadedExec(stream: std.net.Stream, child: *std.process.Child) !void {
    var stdin_thread: ?std.Thread = null;
    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;

    if (child.stdin) |stdin_file| {
        stdin_thread = std.Thread.spawn(.{}, pipeToChild, .{
            stream,
            stdin_file,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stdin thread");
            return ExecError.ThreadSpawnFailed;
        };
        child.stdin = null;
    }

    if (child.stdout) |stdout_file| {
        stdout_thread = std.Thread.spawn(.{}, pipeFromChild, .{
            stdout_file,
            stream,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stdout thread");
            if (stdin_thread) |t| t.detach();
            return ExecError.ThreadSpawnFailed;
        };
        child.stdout = null;
    }

    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, pipeFromChild, .{
            stderr_file,
            stream,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stderr thread");
            if (stdin_thread) |t| t.detach();
            if (stdout_thread) |t| t.detach();
            return ExecError.ThreadSpawnFailed;
        };
        child.stderr = null;
    }

    if (stdin_thread) |t| t.join();
    if (stdout_thread) |t| t.join();
    if (stderr_thread) |t| t.join();
}

    /// The entry point for a thread that pipes data from a network stream (source)
    /// to a child process's standard input (destination).
    ///
    /// It continuously reads from the stream and writes to the file until either
    /// an EOF is received or a write error occurs.
    fn pipeToChild(src: std.net.Stream, dst: std.fs.File) void {
    defer dst.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch |err| {
            if (err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
                logging.logDebug("Socket read error: {any}\n", .{err});
            }
            break;
        };
        if (n == 0) break;

        _ = dst.write(buf[0..n]) catch |err| {
            if (err != error.BrokenPipe) {
                logging.logDebug("Child stdin write error: {any}\n", .{err});
            }
            break;
        };
    }
}

    /// The entry point for a thread that pipes data from a child process's
    /// output (stdout or stderr) to a network stream.
    ///
    /// It continuously reads from the file and writes to the stream until an
    /// EOF is received or a write error occurs.
    fn pipeFromChild(src: std.fs.File, dst: std.net.Stream) void {
    defer src.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch |err| {
            if (err != error.BrokenPipe) {
                logging.logDebug("Child output read error: {any}\n", .{err});
            }
            break;
        };
        if (n == 0) break;

        _ = dst.write(buf[0..n]) catch |err| {
            if (err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
                logging.logDebug("Socket write error: {any}\n", .{err});
            }
            break;
        };
    }
}

/// Execute command with Telnet protocol processing enabled.
pub fn executeWithTelnetConnectionThreaded(
    allocator: std.mem.Allocator,
    telnet_conn: anytype, // *TelnetConnection
    exec_config: ExecConfig,
    client_addr: std.net.Address,
    cfg: *const config.Config,
) !void {
    // SECURITY WARNING: Log this dangerous operation
    logging.logNormal(cfg, "╔══════════════════════════════════════════╗\n", .{});
    logging.logNormal(cfg, "║ SECURITY: Executing command (Telnet)    ║\n", .{});
    logging.logNormal(cfg, "║ Program: {s:<31}║\n", .{exec_config.program});
    logging.logNormal(cfg, "║ Client:  {any:<31}║\n", .{client_addr});
    logging.logNormal(cfg, "║ Mode:    {s:<31}║\n", .{@tagName(exec_config.mode)});
    logging.logNormal(cfg, "╚══════════════════════════════════════════╝\n", .{});

    // Build command with args
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exec_config.program);
    for (exec_config.args) |arg| {
        try argv.append(allocator, arg);
    }

    // Create child process with pipes
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

    // Spawn child process
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    // Extract pipes (spawn() creates them, we take ownership)
    var stdin_thread: ?std.Thread = null;
    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;

    if (child.stdin) |stdin_file| {
        stdin_thread = std.Thread.spawn(.{}, pipeToChildTelnet, .{
            telnet_conn,
            stdin_file,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stdin thread");
            return ExecError.ThreadSpawnFailed;
        };
        child.stdin = null;
    }

    if (child.stdout) |stdout_file| {
        stdout_thread = std.Thread.spawn(.{}, pipeFromChildTelnet, .{
            stdout_file,
            telnet_conn,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stdout thread");
            if (stdin_thread) |t| t.detach();
            return ExecError.ThreadSpawnFailed;
        };
        child.stdout = null;
    }

    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, pipeFromChildTelnet, .{
            stderr_file,
            telnet_conn,
        }) catch |err| {
            logging.logError(err, "Failed to spawn stderr thread");
            if (stdin_thread) |t| t.detach();
            if (stdout_thread) |t| t.detach();
            return ExecError.ThreadSpawnFailed;
        };
        child.stderr = null;
    }

    if (stdin_thread) |t| t.join();
    if (stdout_thread) |t| t.join();
    if (stderr_thread) |t| t.join();
}

    /// The entry point for a thread that pipes data from a `TelnetConnection` to
    /// a child's stdin.
    ///
    /// This function is similar to `pipeToChild`, but it reads from a
    /// `TelnetConnection` instance, which automatically filters out Telnet
    /// command sequences (IAC commands) before passing the application data along.
    fn pipeToChildTelnet(telnet_conn: anytype, dst: std.fs.File) void {
    defer dst.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        // TelnetConnection.read() filters IAC sequences automatically
        const n = telnet_conn.read(&buf) catch |err| {
            if (err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
                logging.logDebug("Telnet read error: {any}\n", .{err});
            }
            break;
        };
        if (n == 0) break; // EOF

        // Write application data to child stdin
        dst.writeAll(buf[0..n]) catch |err| {
            if (err != error.BrokenPipe) {
                logging.logDebug("Child stdin write error: {any}\n", .{err});
            }
            break;
        };
    }
}

    /// The entry point for a thread that pipes data from a child's output to a
    /// `TelnetConnection`.
    ///
    /// This function is similar to `pipeFromChild`, but it writes to a
    /// `TelnetConnection` instance, which automatically escapes any Telnet
    /// command bytes (e.g., `0xFF`) in the application data before sending it.
    fn pipeFromChildTelnet(src: std.fs.File, telnet_conn: anytype) void {
    defer src.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch |err| {
            if (err != error.BrokenPipe) {
                logging.logDebug("Child output read error: {any}\n", .{err});
            }
            break;
        };
        if (n == 0) break; // EOF

        // TelnetConnection.write() escapes IAC bytes automatically
        _ = telnet_conn.write(buf[0..n]) catch |err| {
            if (err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
                logging.logDebug("Telnet write error: {any}\n", .{err});
            }
            break;
        };
    }
}
