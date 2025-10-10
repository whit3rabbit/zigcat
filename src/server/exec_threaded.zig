//! Thread-based execution logic for Windows and Telnet.
const std = @import("std");
const logging = @import("../util/logging.zig");

const ExecConfig = @import("./exec_types.zig").ExecConfig;
const ExecError = @import("./exec_types.zig").ExecError;

/// Fallback threaded execution path (primarily for Windows).
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

/// Pipe data from socket to child stdin
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

/// Pipe data from child stdout/stderr to socket
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
) !void {
    // SECURITY WARNING: Log this dangerous operation
    logging.logNormal("╔══════════════════════════════════════════╗\n", .{});
    logging.logNormal("║ SECURITY: Executing command (Telnet)    ║\n", .{});
    logging.logNormal("║ Program: {s:<31}║\n", .{exec_config.program});
    logging.logNormal("║ Client:  {any:<31}║\n", .{client_addr});
    logging.logNormal("║ Mode:    {s:<31}║\n", .{@tagName(exec_config.mode)});
    logging.logNormal("╚══════════════════════════════════════════╝\n", .{});

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

/// Pipe data from Telnet connection to child stdin (with IAC filtering).
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

/// Pipe data from child stdout/stderr to Telnet connection (with IAC escaping).
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
