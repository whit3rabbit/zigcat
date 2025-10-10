//! Hex dump output operations
//!
//! Handles writing formatted hex dump data to stdout and files,
//! including error handling and file management.

const std = @import("std");
const config = @import("../../config.zig");

/// Map filesystem errors to specific IOControlError types for hex dump operations.
///
/// This function provides detailed error classification and logging for hex dump file operations,
/// helping users understand what went wrong and how to fix it.
///
/// Parameters:
///   err: The original filesystem error
///   path: File path that caused the error (for logging)
///   operation: Description of the operation that failed
///
/// Returns: Appropriate IOControlError based on the original error
pub fn mapHexDumpFileError(err: anyerror, path: []const u8, operation: []const u8) config.IOControlError {
    // Suppress debug output during tests to avoid contaminating test output
    const is_test = @import("builtin").is_test;

    switch (err) {
        error.AccessDenied => {
            if (!is_test) {
                std.debug.print("Error: Permission denied to {s} hex dump file '{s}'\n", .{ operation, path });
                std.debug.print("  Try: chmod +w '{s}' or run with appropriate permissions\n", .{path});
            }
            return config.IOControlError.InsufficientPermissions;
        },
        error.FileNotFound => {
            if (!is_test) {
                std.debug.print("Error: Directory not found for hex dump file '{s}'\n", .{path});
                std.debug.print("  Try: mkdir -p '{s}'\n", .{std.fs.path.dirname(path) orelse "."});
            }
            return config.IOControlError.DirectoryNotFound;
        },
        error.IsDir => {
            if (!is_test) {
                std.debug.print("Error: Hex dump path '{s}' is a directory, not a file\n", .{path});
            }
            return config.IOControlError.IsDirectory;
        },
        error.NoSpaceLeft => {
            if (!is_test) {
                std.debug.print("Error: No space left on device for hex dump file '{s}'\n", .{path});
                std.debug.print("  Try: Free up disk space or choose a different location\n", .{});
            }
            return config.IOControlError.DiskFull;
        },
        error.FileBusy, error.ResourceBusy => {
            if (!is_test) {
                std.debug.print("Error: Hex dump file '{s}' is locked by another process\n", .{path});
                std.debug.print("  Try: Close other applications using this file\n", .{});
            }
            return config.IOControlError.FileLocked;
        },
        error.NameTooLong => {
            if (!is_test) {
                std.debug.print("Error: Hex dump file path '{s}' is too long\n", .{path});
            }
            return config.IOControlError.PathTooLong;
        },
        error.InvalidUtf8, error.BadPathName => {
            if (!is_test) {
                std.debug.print("Error: Hex dump file path '{s}' contains invalid characters\n", .{path});
            }
            return config.IOControlError.InvalidPathCharacters;
        },
        error.NotDir => {
            if (!is_test) {
                std.debug.print("Error: Parent directory in path '{s}' is not a directory\n", .{path});
            }
            return config.IOControlError.DirectoryNotFound;
        },
        error.DeviceBusy, error.SystemResources => {
            if (!is_test) {
                std.debug.print("Error: System resources unavailable for hex dump file '{s}'\n", .{path});
            }
            return config.IOControlError.FileSystemError;
        },
        else => {
            if (!is_test) {
                std.debug.print("Error: Failed to {s} hex dump file '{s}': {any}\n", .{ operation, path, err });
            }
            return config.IOControlError.HexDumpFileCreateFailed;
        },
    }
}

/// Write formatted hex dump line to stdout and optional file.
///
/// Outputs a formatted hex dump line to both stdout (unless testing)
/// and to a file if one is provided.
///
/// Parameters:
///   - formatted_line: Formatted hex dump line to output
///   - file: Optional file to write to
///   - path: Optional file path (for error reporting)
///
/// Errors:
///   - Various IOControlErrors if file write fails
pub fn writeHexLine(formatted_line: []const u8, file: ?std.fs.File, path: ?[]const u8) !void {
    // Suppress stdout during tests to avoid contaminating test output
    const is_test = @import("builtin").is_test;
    if (!is_test) {
        // Write to stdout
        std.debug.print("{s}", .{formatted_line});
    }

    // Write to file if configured
    if (file) |f| {
        f.writeAll(formatted_line) catch |err| {
            if (path) |p| {
                return mapHexDumpFileError(err, p, "write");
            } else {
                return config.IOControlError.HexDumpFileWriteFailed;
            }
        };
    }
}

/// Open a file for hex dump output.
///
/// Creates a new file (truncating if it exists) for hex dump output.
///
/// Parameters:
///   - path: File path to create
///
/// Returns:
///   Opened file handle
///
/// Errors:
///   - InvalidOutputPath: Empty path string
///   - Various IOControlErrors from mapHexDumpFileError()
pub fn openHexDumpFile(path: []const u8) !std.fs.File {
    // Validate path is not empty
    if (path.len == 0) {
        return config.IOControlError.InvalidOutputPath;
    }

    // Create the hex dump file, truncating if it exists
    const file = std.fs.cwd().createFile(path, .{
        .read = false,
        .truncate = true,
        .exclusive = false,
    }) catch |err| {
        return mapHexDumpFileError(err, path, "create");
    };

    return file;
}

/// Flush file buffers to disk.
///
/// Forces all buffered hex dump data to be written to disk using `file.sync()`.
///
/// Parameters:
///   - file: File to flush
///   - path: File path (for error reporting)
///
/// Errors:
///   - Various IOControlErrors from mapHexDumpFileError() if sync fails
pub fn flushHexDumpFile(file: std.fs.File, path: []const u8) !void {
    file.sync() catch |err| {
        return mapHexDumpFileError(err, path, "flush");
    };
}
