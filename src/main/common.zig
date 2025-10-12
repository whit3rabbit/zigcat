// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Shared runtime utilities for `main`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const config = @import("../config.zig");
const logging = @import("../util/logging.zig");

/// Global shutdown flag (atomic for thread safety).
pub var shutdown_requested = std.atomic.Value(bool).init(false);

/// Signal handler for graceful shutdown (SIGINT, SIGTERM).
pub fn handleShutdownSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Register signal handlers when running in listen/server mode.
pub fn registerSignalHandlers(cfg: *const config.Config) void {
    // Windows uses SetConsoleCtrlHandler instead of POSIX signals
    if (builtin.os.tag == .windows) {
        logging.logVerbose(cfg, "Signal handlers not supported on Windows (use Ctrl+C)\n", .{});
        return;
    }

    // Initialize empty mask (Zig 0.15.x returns by value).
    const empty_mask = posix.sigemptyset();

    const sigaction = posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = empty_mask,
        .flags = 0,
    };

    _ = posix.sigaction(posix.SIG.INT, &sigaction, null);
    _ = posix.sigaction(posix.SIG.TERM, &sigaction, null);

    logging.logVerbose(cfg, "Signal handlers registered (SIGINT, SIGTERM)\n", .{});
}

/// Display user-friendly error messages for I/O control initialization failures.
pub fn handleIOInitError(cfg: *const config.Config, err: anyerror, component: []const u8) void {
    _ = cfg;
    switch (err) {
        config.IOControlError.ConflictingIOModes => {
            logging.logError(err, "Cannot use both --send-only and --recv-only flags simultaneously");
            logging.logWarning("  Choose either --send-only OR --recv-only, not both\n", .{});
        },
        config.IOControlError.InvalidOutputPath => {
            logging.logError(err, "Invalid file path specified");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Path cannot be empty or contain invalid characters\n", .{});
        },
        config.IOControlError.InvalidPathCharacters => {
            logging.logError(err, "file path contains invalid characters");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Avoid control characters, null bytes, and platform-specific reserved names\n", .{});
        },
        config.IOControlError.PathTraversalDetected => {
            logging.logError(err, "file path contains forbidden directory traversal sequences");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Remove any '../' or '..\\' segments and target a safe directory\n", .{});
        },
        config.IOControlError.PathTooLong => {
            logging.logError(err, "file path is too long");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Try using a shorter path or relative path\n", .{});
        },
        config.IOControlError.DirectoryNotFound => {
            logging.logError(err, "Parent directory does not exist");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Create the directory first or choose an existing location\n", .{});
        },
        config.IOControlError.InsufficientPermissions => {
            logging.logError(err, "Insufficient permissions for file operations");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check file/directory permissions or run with appropriate privileges\n", .{});
        },
        config.IOControlError.DiskFull => {
            logging.logError(err, "No space left on device");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Free up disk space or choose a different location\n", .{});
        },
        config.IOControlError.FileLocked => {
            logging.logError(err, "file is locked by another process");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Close other applications using this file\n", .{});
        },
        config.IOControlError.IsDirectory => {
            logging.logError(err, "path points to a directory, not a file");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Specify a file path, not a directory\n", .{});
        },
        config.IOControlError.FileSystemError => {
            logging.logError(err, "File system error during initialization");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check system resources and try again\n", .{});
        },
        config.IOControlError.OutputFileCreateFailed => {
            logging.logError(err, "Failed to create or open file");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check path, permissions, and available disk space\n", .{});
        },
        config.IOControlError.HexDumpFileCreateFailed => {
            logging.logError(err, "Failed to create file");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check path, permissions, and available disk space\n", .{});
        },
        config.IOControlError.OutputFileWriteFailed => {
            logging.logError(err, "Failed to write to file");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check disk space, permissions, and file system health\n", .{});
        },
        config.IOControlError.HexDumpFileWriteFailed => {
            logging.logError(err, "Failed to write to file");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  Check disk space, permissions, and file system health\n", .{});
        },
        else => {
            logging.logError(err, "Failed to initialize component");
            logging.logWarning("  Component: {s}\n", .{component});
            logging.logWarning("  This may be a system-specific issue - check logs for details\n", .{});
        },
    }
}
