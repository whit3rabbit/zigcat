// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! CLI-related configuration validation.
//!
//! This module handles validation of options that are primarily
//! controlled via command-line flags, such as output redirection
//! and I/O mode toggles.

const std = @import("std");
const builtin = @import("builtin");
const path_safety = @import("../util/path_safety.zig");

const config_struct = @import("config_struct.zig");
const Config = config_struct.Config;

/// Errors related to I/O control configuration validation.
pub const IOControlError = error{
    /// Both --send-only and --recv-only flags specified
    ConflictingIOModes,
    /// Failed to create output file for logging
    OutputFileCreateFailed,
    /// Failed to write to output file
    OutputFileWriteFailed,
    /// Failed to create hex dump file
    HexDumpFileCreateFailed,
    /// Failed to write to hex dump file
    HexDumpFileWriteFailed,
    /// Output file path is invalid (empty or malformed)
    InvalidOutputPath,
    /// File path contains invalid characters or sequences
    InvalidPathCharacters,
    /// File path is too long for the filesystem
    PathTooLong,
    /// Insufficient permissions to create or write to file
    InsufficientPermissions,
    /// Directory in file path does not exist
    DirectoryNotFound,
    /// Disk full or insufficient space for file operations
    DiskFull,
    /// File is locked by another process
    FileLocked,
    /// File path points to a directory instead of a file
    IsDirectory,
    /// File system error during operation
    FileSystemError,
    /// File path contains parent directory traversal (e.g. ../)
    PathTraversalDetected,
};

/// Validate I/O control configuration for conflicts and path issues.
/// Checks mutually exclusive I/O modes and validates file paths.
pub fn validateIOControl(cfg: *const Config) IOControlError!void {
    // Check for conflicting I/O modes
    if (cfg.send_only and cfg.recv_only) {
        return IOControlError.ConflictingIOModes;
    }

    // Validate output file path if specified
    if (cfg.output_file) |path| {
        try validateFilePath(path, "output file");
    }

    // Validate hex dump file path if specified
    if (cfg.hex_dump_file) |path| {
        try validateFilePath(path, "hex dump file");
    }
}

/// Validate a file path for common issues and accessibility.
fn validateFilePath(path: []const u8, context: []const u8) IOControlError!void {
    _ = context;
    if (path.len == 0) {
        return IOControlError.InvalidOutputPath;
    }

    const MAX_PATH_LENGTH = 4096;
    if (path.len > MAX_PATH_LENGTH) {
        return IOControlError.PathTooLong;
    }

    for (path) |byte| {
        if (byte == 0) {
            return IOControlError.InvalidPathCharacters;
        }
        if (byte < 32 and byte != '\t') {
            return IOControlError.InvalidPathCharacters;
        }
    }

    if (builtin.os.tag == .windows) {
        try validateWindowsPath(path);
    } else {
        try validateUnixPath(path);
    }

    if (!path_safety.isSafePath(path)) {
        return IOControlError.PathTraversalDetected;
    }

    if (std.fs.path.dirname(path)) |parent_dir| {
        std.fs.cwd().access(parent_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => return IOControlError.DirectoryNotFound,
            error.AccessDenied => return IOControlError.InsufficientPermissions,
            else => {},
        };
    }
}

/// Validate Windows-specific path requirements.
fn validateWindowsPath(path: []const u8) IOControlError!void {
    const reserved_names = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",
        "COM1", "COM2", "COM3", "COM4",
        "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3",
        "LPT4", "LPT5", "LPT6", "LPT7",
        "LPT8", "LPT9",
    };

    const filename = std.fs.path.basename(path);
    const name_without_ext = if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index|
        filename[0..dot_index]
    else
        filename;

    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name_without_ext, reserved)) {
            return IOControlError.InvalidPathCharacters;
        }
    }

    // Check for invalid Windows characters
    // Note: ':' is allowed only for drive letters (e.g., C:\)
    const invalid_chars = [_]u8{ '<', '>', ':', '"', '/', '\\', '|', '?', '*' };
    for (invalid_chars) |ch| {
        if (std.mem.indexOfScalar(u8, path, ch) != null) {
            return IOControlError.InvalidPathCharacters;
        }
    }

    // Check for trailing spaces or dots
    if (path.len > 0) {
        const last_char = path[path.len - 1];
        if (last_char == ' ' or last_char == '.') {
            return IOControlError.InvalidPathCharacters;
        }
    }

    // Check for trailing spaces/dots in components
    var it = std.mem.splitScalar(u8, path, '\\');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        const last_char = component[component.len - 1];
        if (last_char == ' ' or last_char == '.') {
            return IOControlError.InvalidPathCharacters;
        }
    }
}

/// Validate Unix-specific path requirements.
fn validateUnixPath(path: []const u8) IOControlError!void {
    // Check for extremely long path components
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len > 255) {
            return IOControlError.PathTooLong;
        }
    }
}

test "validateIOControl catches conflicting I/O modes" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.send_only = true;
    cfg.recv_only = true;

    try testing.expectError(IOControlError.ConflictingIOModes, validateIOControl(&cfg));
}

test "validateIOControl accepts compatible modes and paths" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.send_only = true;
    try validateIOControl(&cfg);

    cfg.send_only = false;
    cfg.recv_only = true;
    try validateIOControl(&cfg);

    cfg.recv_only = false;
    cfg.output_file = "/tmp/output.txt";
    cfg.hex_dump_file = "/tmp/hexdump.txt";
    try validateIOControl(&cfg);
}

test "validateFilePath rejects malformed paths" {
    const testing = std.testing;

    try testing.expectError(IOControlError.InvalidOutputPath, validateFilePath("", "test"));

    const long_path = "a" ** 5000;
    try testing.expectError(IOControlError.PathTooLong, validateFilePath(long_path, "test"));

    try testing.expectError(IOControlError.InvalidPathCharacters, validateFilePath("bad\x00path", "test"));
    try testing.expectError(IOControlError.InvalidPathCharacters, validateFilePath("bad\x01path", "test"));

    try testing.expectError(IOControlError.PathTraversalDetected, validateFilePath("../etc/passwd", "test"));
    try testing.expectError(IOControlError.PathTraversalDetected, validateFilePath("..\\windows\\system.ini", "test"));
}
