// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Client-side command execution (exec mode).
//!
//! This module implements the -e/-c flags for CLIENT mode, where a local
//! command is executed and its stdin/stdout are connected to the remote
//! socket. This is less dangerous than server-side exec since you're only
//! executing commands on your own machine.
//!
//! Workflow:
//! 1. Spawn child process with stdin/stdout redirected to pipes
//! 2. Use bidirectional I/O to relay data between socket and child
//! 3. Handle child termination and cleanup
//!
//! Security notes:
//! - Client-side exec is less dangerous than server-side (local command execution)
//! - Still requires proper command validation (avoid shell injection)
//! - Environment variables should be sanitized
//! - Uses the same ExecSession backend as server mode (poll/io_uring)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");

// Import server-side exec infrastructure (reusable for client mode)
const exec_types = @import("../server/exec_types.zig");
const exec_session = @import("../server/exec_session/mod.zig");
const exec = @import("../server/exec.zig");

pub const ExecConfig = exec_types.ExecConfig;
pub const ExecMode = exec_types.ExecMode;

/// Execute command with socket connected to stdin/stdout.
///
/// This function spawns a child process and connects its stdin/stdout to
/// the provided socket, enabling bidirectional communication between the
/// local command and remote endpoint.
///
/// Platform support:
/// - **Linux 5.1+**: Uses io_uring for high-performance async I/O
/// - **macOS/BSD**: Uses poll(2)-based event loop
/// - **Windows**: Uses multi-threaded I/O (exec_threaded.zig)
///
/// Parameters:
///   allocator: For command parsing and buffer allocation
///   socket: Connected socket to use for child I/O (takes ownership)
///   cmd: Command string to execute (shell mode) or program path (direct mode)
///   cfg: Configuration for verbose logging and options
///
/// Returns: error if spawn fails, I/O error, or child exits with error
pub fn executeCommand(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    cmd: []const u8,
    cfg: *const config.Config,
) !void {
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Client-side exec mode: executing command locally\n", .{});
        logging.logVerbose(cfg, "  Command: {s}\n", .{cmd});
    }

    // Determine exec mode based on command format
    // If cmd contains spaces or shell metacharacters, use shell mode
    // Otherwise use direct execution
    const exec_mode = determineExecMode(cmd);

    // Build command configuration
    const exec_config = try buildExecConfig(allocator, cmd, exec_mode, cfg);
    defer {
        // Free args array if it was heap-allocated
        if (exec_config.args.len > 0) {
            allocator.free(exec_config.args);
        }
    }

    // Log security warning for client-side exec
    logExecSecurity(exec_config.program, exec_config.args);

    // Create argv for Child.init
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, exec_config.program);
    for (exec_config.args) |arg| {
        try argv.append(allocator, arg);
    }

    // Spawn child process with pipes
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = if (exec_config.redirect_stdin) .Pipe else .Inherit;
    child.stdout_behavior = if (exec_config.redirect_stdout) .Pipe else .Inherit;
    child.stderr_behavior = if (exec_config.redirect_stderr) .Pipe else .Inherit;

    try child.spawn();

    // Ensure cleanup on error
    errdefer {
        exec.closeChildPipes(&child);
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // Execute bidirectional I/O using ExecSession
    // This automatically selects the best backend (io_uring, poll, or threads)
    try runExecSession(allocator, socket, &child, exec_config, cfg);

    // Close pipes before waiting for child
    exec.closeChildPipes(&child);

    // Wait for child to exit
    const term = try child.wait();
    logChildTermination(term, cfg);
}

/// Run the exec session with automatic backend selection.
fn runExecSession(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    child: *std.process.Child,
    exec_config: ExecConfig,
    cfg: *const config.Config,
) !void {
    if (builtin.os.tag == .windows) {
        // Windows uses multi-threaded approach
        const net_stream = std.net.Stream{ .handle = socket };
        return @import("../server/exec_threaded.zig").runThreadedExec(net_stream, child);
    } else {
        // Unix uses ExecSession (io_uring or poll)
        // Wrap socket in Connection and TelnetConnection for protocol handling
        const Connection = @import("../net/connection.zig").Connection;
        const TelnetConnection = @import("../protocol/telnet_connection.zig").TelnetConnection;

        const connection = Connection.fromSocket(socket);
        var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null, null, false);
        defer telnet_conn.deinit();

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Starting bidirectional I/O between socket and child process...\n", .{});
        }

        // ExecSession.init() automatically selects best backend (io_uring or poll)
        var session = try exec_session.ExecSession.init(
            allocator,
            &telnet_conn,
            child,
            exec_config.session_config,
        );
        defer session.deinit();

        try session.run();
    }
}

/// Determine execution mode based on command string.
///
/// Simple heuristic:
/// - If command contains spaces → shell mode (needs parsing)
/// - Otherwise → direct mode (single program)
fn determineExecMode(cmd: []const u8) ExecMode {
    // Check if command contains spaces or shell metacharacters
    for (cmd) |c| {
        if (c == ' ' or c == '|' or c == '>' or c == '<' or c == '&' or c == ';') {
            return .shell;
        }
    }
    return .direct;
}

/// Build ExecConfig from command string and mode.
fn buildExecConfig(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    mode: ExecMode,
    cfg: *const config.Config,
) !ExecConfig {
    switch (mode) {
        .shell => {
            // Shell mode: Use /bin/sh -c "command" or cmd.exe /c "command"
            const shell_cmd = try exec.buildShellCommand(allocator, cmd);
            return ExecConfig{
                .mode = .shell,
                .program = shell_cmd.program,
                .args = shell_cmd.args,
                .require_allow = false, // Client-side, no access control needed
                .session_config = buildSessionConfig(cfg),
                .redirect_stdin = true,
                .redirect_stdout = true,
                .redirect_stderr = true,
            };
        },
        .direct => {
            // Direct mode: Execute program directly (no args for now)
            // TODO: Parse arguments from cmd if needed in future
            return ExecConfig{
                .mode = .direct,
                .program = cmd,
                .args = &.{}, // No arguments
                .require_allow = false, // Client-side, no access control needed
                .session_config = buildSessionConfig(cfg),
                .redirect_stdin = true,
                .redirect_stdout = true,
                .redirect_stderr = true,
            };
        },
    }
}

/// Build ExecSessionConfig from user configuration.
fn buildSessionConfig(cfg: *const config.Config) exec_types.ExecSessionConfig {
    var session_config = exec_types.ExecSessionConfig{};

    // Apply timeout configuration if set
    if (cfg.idle_timeout > 0) {
        session_config.timeouts.idle_ms = cfg.idle_timeout;
    }
    if (cfg.connect_timeout > 0) {
        session_config.timeouts.connection_ms = cfg.connect_timeout;
    }

    return session_config;
}

/// Log security warning for command execution.
fn logExecSecurity(program: []const u8, args: []const []const u8) void {
    logging.logWarning("╔══════════════════════════════════════════╗\n", .{});
    logging.logWarning("║ CLIENT-SIDE EXEC: Executing locally      ║\n", .{});
    logging.logWarning("║ Program: {s:<31}║\n", .{program});
    if (args.len > 0) {
        logging.logWarning("║ Args:    {s:<31}║\n", .{args[0]});
        if (args.len > 1) {
            logging.logWarning("║          {s:<31}║\n", .{args[1]});
        }
    }
    logging.logWarning("╚══════════════════════════════════════════╝\n", .{});
}

/// Log child process termination status.
fn logChildTermination(term: std.process.Child.Term, cfg: *const config.Config) void {
    if (cfg.verbose) {
        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    logging.logVerbose(cfg, "Child process exited successfully\n", .{});
                } else {
                    logging.logVerbose(cfg, "Child process exited with code: {d}\n", .{code});
                }
            },
            .Signal => |sig| logging.logVerbose(cfg, "Child process terminated by signal: {d}\n", .{sig}),
            .Stopped => |sig| logging.logVerbose(cfg, "Child process stopped by signal: {d}\n", .{sig}),
            .Unknown => |code| logging.logVerbose(cfg, "Child process exited with unknown status: {d}\n", .{code}),
        }
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "determineExecMode - direct" {
    try testing.expectEqual(ExecMode.direct, determineExecMode("ls"));
    try testing.expectEqual(ExecMode.direct, determineExecMode("/bin/date"));
    try testing.expectEqual(ExecMode.direct, determineExecMode("whoami"));
}

test "determineExecMode - shell" {
    try testing.expectEqual(ExecMode.shell, determineExecMode("ls -la"));
    try testing.expectEqual(ExecMode.shell, determineExecMode("echo hello | grep llo"));
    try testing.expectEqual(ExecMode.shell, determineExecMode("date > file.txt"));
    try testing.expectEqual(ExecMode.shell, determineExecMode("sleep 1 && echo done"));
}

test "buildExecConfig - shell mode" {
    const allocator = testing.allocator;
    const cmd = "echo test";

    var cfg = config.Config{};
    const exec_config = try buildExecConfig(allocator, cmd, .shell, &cfg);
    defer allocator.free(exec_config.args);

    try testing.expectEqual(ExecMode.shell, exec_config.mode);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("cmd.exe", exec_config.program);
        try testing.expectEqual(@as(usize, 2), exec_config.args.len);
        try testing.expectEqualStrings("/c", exec_config.args[0]);
    } else {
        try testing.expectEqualStrings("/bin/sh", exec_config.program);
        try testing.expectEqual(@as(usize, 2), exec_config.args.len);
        try testing.expectEqualStrings("-c", exec_config.args[0]);
        try testing.expectEqualStrings("echo test", exec_config.args[1]);
    }
}

test "buildExecConfig - direct mode" {
    const allocator = testing.allocator;
    const cmd = "/bin/date";

    var cfg = config.Config{};
    const exec_config = try buildExecConfig(allocator, cmd, .direct, &cfg);

    try testing.expectEqual(ExecMode.direct, exec_config.mode);
    try testing.expectEqualStrings("/bin/date", exec_config.program);
    try testing.expectEqual(@as(usize, 0), exec_config.args.len);
    try testing.expect(exec_config.redirect_stdin);
    try testing.expect(exec_config.redirect_stdout);
    try testing.expect(exec_config.redirect_stderr);
}
