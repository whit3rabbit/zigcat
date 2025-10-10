//! Output file logging with support for truncate and append modes.
//!
//! This module provides the `OutputLogger` type for writing data to output files
//! with comprehensive error handling and user-friendly error messages. It supports
//! both truncate mode (overwrite existing file) and append mode (add to existing file).
//!
//! # Features
//!
//! - **Truncate/Append Modes**: Control whether to overwrite or append to existing files
//! - **Comprehensive Error Handling**: Detailed error messages with recovery suggestions
//! - **Optional File Output**: Can operate without a file (no-op mode)
//! - **Flush Support**: Explicit sync-to-disk for critical data
//!
//! # Usage Example
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Create logger in truncate mode (default)
//! var logger = try OutputLogger.init(allocator, "output.log", false);
//! defer logger.deinit();
//!
//! try logger.write("First line\n");
//! try logger.write("Second line\n");
//! try logger.flush();
//!
//! // Create logger in append mode
//! var append_logger = try OutputLogger.init(allocator, "output.log", true);
//! defer append_logger.deinit();
//! try append_logger.write("Appended line\n");
//! ```
//!
//! # Error Handling
//!
//! The module provides detailed error classification through `mapFileError()`,
//! which converts filesystem errors to `IOControlError` types with helpful
//! suggestions for resolution:
//!
//! - `InsufficientPermissions`: Permission denied (suggests chmod)
//! - `DirectoryNotFound`: Parent directory doesn't exist (suggests mkdir)
//! - `IsDirectory`: Path is a directory, not a file
//! - `DiskFull`: No space left on device
//! - `FileLocked`: File locked by another process
//! - `PathTooLong`: Path exceeds system limits
//! - `InvalidPathCharacters`: Path contains invalid characters
//!
//! # Platform Compatibility
//!
//! Works on all platforms supported by Zig's standard library (Unix, Windows, etc.)
//! with cross-platform file operations.

const std = @import("std");
const config = @import("../config.zig");

/// Map filesystem errors to specific IOControlError types with user-friendly messages.
///
/// This function provides detailed error classification and logging for file operations,
/// helping users understand what went wrong and how to fix it.
///
/// Parameters:
///   err: The original filesystem error
///   path: File path that caused the error (for logging)
///   operation: Description of the operation that failed
///
/// Returns: Appropriate IOControlError based on the original error
fn mapFileError(err: anyerror, path: []const u8, operation: []const u8) config.IOControlError {
    // Suppress debug output during tests to avoid contaminating test output
    const is_test = @import("builtin").is_test;

    switch (err) {
        error.AccessDenied => {
            if (!is_test) {
                std.debug.print("Error: Permission denied to {s} output file '{s}'\n", .{ operation, path });
                std.debug.print("  Try: chmod +w '{s}' or run with appropriate permissions\n", .{path});
            }
            return config.IOControlError.InsufficientPermissions;
        },
        error.FileNotFound => {
            if (!is_test) {
                std.debug.print("Error: Directory not found for output file '{s}'\n", .{path});
                std.debug.print("  Try: mkdir -p '{s}'\n", .{std.fs.path.dirname(path) orelse "."});
            }
            return config.IOControlError.DirectoryNotFound;
        },
        error.IsDir => {
            if (!is_test) {
                std.debug.print("Error: Output path '{s}' is a directory, not a file\n", .{path});
            }
            return config.IOControlError.IsDirectory;
        },
        error.NoSpaceLeft => {
            if (!is_test) {
                std.debug.print("Error: No space left on device for output file '{s}'\n", .{path});
                std.debug.print("  Try: Free up disk space or choose a different location\n", .{});
            }
            return config.IOControlError.DiskFull;
        },
        error.FileBusy, error.ResourceBusy => {
            if (!is_test) {
                std.debug.print("Error: Output file '{s}' is locked by another process\n", .{path});
                std.debug.print("  Try: Close other applications using this file\n", .{});
            }
            return config.IOControlError.FileLocked;
        },
        error.NameTooLong => {
            if (!is_test) {
                std.debug.print("Error: Output file path '{s}' is too long\n", .{path});
            }
            return config.IOControlError.PathTooLong;
        },
        error.InvalidUtf8, error.BadPathName => {
            if (!is_test) {
                std.debug.print("Error: Output file path '{s}' contains invalid characters\n", .{path});
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
                std.debug.print("Error: System resources unavailable for output file '{s}'\n", .{path});
            }
            return config.IOControlError.FileSystemError;
        },
        else => {
            if (!is_test) {
                std.debug.print("Error: Failed to {s} output file '{s}': {any}\n", .{ operation, path, err });
            }
            return config.IOControlError.OutputFileCreateFailed;
        },
    }
}

/// OutputLogger handles writing data to output files with support for
/// truncate/append modes and proper resource management.
///
/// This type manages file output for Zigcat, supporting both truncate mode
/// (overwrite existing file) and append mode (add to existing file). It can
/// also operate without a file for scenarios where file output is optional.
///
/// The logger ensures proper cleanup via the `deinit()` method and provides
/// graceful error recovery with detailed error messages.
pub const OutputLogger = struct {
    file: ?std.fs.File = null,
    allocator: std.mem.Allocator,
    path: ?[]const u8 = null,
    append_mode: bool = false,

    /// Initialize OutputLogger with optional file path and append mode.
    ///
    /// Creates a new OutputLogger instance. If a file path is provided, the file
    /// will be opened (created if necessary). In truncate mode (append=false), any
    /// existing file will be overwritten. In append mode (append=true), data will
    /// be written to the end of existing files.
    ///
    /// Parameters:
    ///   - allocator: Memory allocator (stored for future use)
    ///   - path: Optional file path (null for no-file mode)
    ///   - append: If true, append to existing file; if false, truncate
    ///
    /// Returns:
    ///   Initialized OutputLogger instance
    ///
    /// Errors:
    ///   - InvalidOutputPath: Empty path string
    ///   - Various IOControlErrors from mapFileError() (permission, disk full, etc.)
    ///
    /// Example:
    /// ```zig
    /// var logger = try OutputLogger.init(allocator, "data.log", false);
    /// defer logger.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, append: bool) !OutputLogger {
        var logger = OutputLogger{
            .allocator = allocator,
            .path = path,
            .append_mode = append,
        };

        if (path) |file_path| {
            // Validate path is not empty
            if (file_path.len == 0) {
                return config.IOControlError.InvalidOutputPath;
            }

            // Create or open the file based on append mode
            const file = if (append) blk: {
                // Try to open existing file for appending, create if doesn't exist
                break :blk std.fs.cwd().createFile(file_path, .{
                    .read = false,
                    .truncate = false,
                    .exclusive = false,
                }) catch |err| switch (err) {
                    error.PathAlreadyExists => std.fs.cwd().openFile(file_path, .{
                        .mode = .write_only,
                    }) catch |open_err| {
                        return mapFileError(open_err, file_path, "open for appending");
                    },
                    else => {
                        return mapFileError(err, file_path, "create for appending");
                    },
                };
            } else blk: {
                // Create new file, truncating if it exists
                break :blk std.fs.cwd().createFile(file_path, .{
                    .read = false,
                    .truncate = true,
                    .exclusive = false,
                }) catch |err| {
                    return mapFileError(err, file_path, "create");
                };
            };

            // If in append mode, seek to end of file
            if (append) {
                file.seekFromEnd(0) catch |err| {
                    file.close();
                    return mapFileError(err, file_path, "seek to end");
                };
            }

            logger.file = file;
        }

        return logger;
    }

    /// Clean up resources and close file if open.
    ///
    /// Closes the output file (if one was opened) and releases resources.
    /// Safe to call multiple times. This method must be called to ensure
    /// the file is properly closed and buffers are flushed.
    ///
    /// Example:
    /// ```zig
    /// var logger = try OutputLogger.init(allocator, "output.log", false);
    /// defer logger.deinit(); // Ensures cleanup even on error
    /// ```
    pub fn deinit(self: *OutputLogger) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    /// Write data to the output file with graceful error recovery.
    ///
    /// Writes the provided data to the output file. If no file is configured
    /// (path was null during init), this is a no-op that returns immediately.
    ///
    /// Parameters:
    ///   - data: Byte slice to write to file
    ///
    /// Errors:
    ///   - Various IOControlErrors from mapFileError() if write fails
    ///
    /// Example:
    /// ```zig
    /// try logger.write("Hello, World!\n");
    /// try logger.write(binary_data);
    /// ```
    pub fn write(self: *OutputLogger, data: []const u8) !void {
        if (self.file) |file| {
            file.writeAll(data) catch |err| {
                // Attempt graceful error recovery for transient issues
                if (self.path) |path| {
                    return mapFileError(err, path, "write");
                } else {
                    return config.IOControlError.OutputFileWriteFailed;
                }
            };
        }
    }

    /// Flush any buffered data to disk with error recovery.
    ///
    /// Forces all buffered data to be written to disk using `file.sync()`.
    /// If no file is configured, this is a no-op that returns immediately.
    ///
    /// This should be called when data integrity is critical (e.g., after
    /// writing important records or before disconnecting).
    ///
    /// Errors:
    ///   - Various IOControlErrors from mapFileError() if sync fails
    ///
    /// Example:
    /// ```zig
    /// try logger.write("Critical data\n");
    /// try logger.flush(); // Ensure it's on disk
    /// ```
    pub fn flush(self: *OutputLogger) !void {
        if (self.file) |file| {
            file.sync() catch |err| {
                if (self.path) |path| {
                    return mapFileError(err, path, "flush");
                } else {
                    return config.IOControlError.OutputFileWriteFailed;
                }
            };
        }
    }

    /// Check if logger is configured to write to a file.
    ///
    /// Returns: true if a file was opened during init, false otherwise
    pub fn isEnabled(self: *const OutputLogger) bool {
        return self.file != null;
    }

    /// Get the configured file path (may be null).
    ///
    /// Returns: File path string if configured, null otherwise
    pub fn getPath(self: *const OutputLogger) ?[]const u8 {
        return self.path;
    }

    /// Check if logger is in append mode.
    ///
    /// Returns: true if logger was initialized with append=true, false for truncate mode
    pub fn isAppendMode(self: *const OutputLogger) bool {
        return self.append_mode;
    }
};

// Tests
test "OutputLogger - init with no path" {
    const testing = std.testing;

    var logger = try OutputLogger.init(testing.allocator, null, false);
    defer logger.deinit();

    try testing.expect(!logger.isEnabled());
    try testing.expect(logger.getPath() == null);
    try testing.expect(!logger.isAppendMode());
}

test "OutputLogger - init with empty path" {
    const testing = std.testing;

    try testing.expectError(config.IOControlError.InvalidOutputPath, OutputLogger.init(testing.allocator, "", false));
}

test "OutputLogger - write and flush with no file" {
    const testing = std.testing;

    var logger = try OutputLogger.init(testing.allocator, null, false);
    defer logger.deinit();

    // Should not error when no file is configured
    try logger.write("test data");
    try logger.flush();
}

test "OutputLogger - create and write to file" {
    const testing = std.testing;

    // Create a temporary file path
    const test_file = "test_output.tmp";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Test truncate mode (default)
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try testing.expect(logger.isEnabled());
        try testing.expect(!logger.isAppendMode());
        try testing.expectEqualStrings(test_file, logger.getPath().?);

        try logger.write("Hello, ");
        try logger.write("World!");
        try logger.flush();
    }

    // Verify file contents
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("Hello, World!", contents);
    }
}

test "OutputLogger - append mode" {
    const testing = std.testing;

    const test_file = "test_append.tmp";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write in truncate mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("First line\n");
        try logger.flush();
    }

    // Second write in append mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, true);
        defer logger.deinit();

        try testing.expect(logger.isAppendMode());

        try logger.write("Second line\n");
        try logger.flush();
    }

    // Verify both lines are present
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("First line\nSecond line\n", contents);
    }
}

test "OutputLogger - truncate mode overwrites existing file" {
    const testing = std.testing;

    const test_file = "test_truncate.tmp";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("Original content");
        try logger.flush();
    }

    // Second write in truncate mode (default)
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("New content");
        try logger.flush();
    }

    // Verify only new content is present
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("New content", contents);
    }
}

test "OutputLogger - error recovery and graceful handling" {
    const testing = std.testing;

    // Test initialization with invalid directory
    const invalid_path = "/nonexistent/directory/file.txt";
    try testing.expectError(config.IOControlError.DirectoryNotFound, OutputLogger.init(testing.allocator, invalid_path, false));

    // Test with read-only directory (if we can create one)
    // This test is platform-dependent and may not work in all environments
    const readonly_test = false; // Disable for now due to platform differences
    if (readonly_test) {
        const readonly_dir = "readonly_test_dir";
        _ = "readonly_test_dir/file.txt"; // Suppress unused warning

        // Create directory and make it read-only
        std.fs.cwd().makeDir(readonly_dir) catch {};
        defer std.fs.cwd().deleteTree(readonly_dir) catch {};

        // This test would need platform-specific permission setting
        // For now, we'll skip it to maintain cross-platform compatibility
    }
}

test "mapFileError - comprehensive error mapping" {
    const testing = std.testing;

    // Test various error mappings
    const test_path = "test_file.txt";

    // Test access denied mapping
    const access_err = mapFileError(error.AccessDenied, test_path, "test");
    try testing.expectEqual(config.IOControlError.InsufficientPermissions, access_err);

    // Test file not found mapping
    const notfound_err = mapFileError(error.FileNotFound, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notfound_err);

    // Test is directory mapping
    const isdir_err = mapFileError(error.IsDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.IsDirectory, isdir_err);

    // Test no space left mapping
    const nospace_err = mapFileError(error.NoSpaceLeft, test_path, "test");
    try testing.expectEqual(config.IOControlError.DiskFull, nospace_err);

    // Test file busy mapping
    const busy_err = mapFileError(error.FileBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, busy_err);

    // Test name too long mapping
    const toolong_err = mapFileError(error.NameTooLong, test_path, "test");
    try testing.expectEqual(config.IOControlError.PathTooLong, toolong_err);

    // Test unknown error mapping
    const unknown_err = mapFileError(error.Unexpected, test_path, "test");
    try testing.expectEqual(config.IOControlError.OutputFileCreateFailed, unknown_err);
}
// =============================================================================
// COMPREHENSIVE OUTPUT LOGGER TESTS
// =============================================================================

test "OutputLogger - comprehensive initialization and properties" {
    const testing = std.testing;

    // Test with no file path
    var logger1 = try OutputLogger.init(testing.allocator, null, false);
    defer logger1.deinit();

    try testing.expect(!logger1.isEnabled());
    try testing.expect(logger1.getPath() == null);
    try testing.expect(!logger1.isAppendMode());

    // Test with file path in truncate mode
    const test_file = "test_output_logger.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var logger2 = try OutputLogger.init(testing.allocator, test_file, false);
    defer logger2.deinit();

    try testing.expect(logger2.isEnabled());
    try testing.expectEqualStrings(test_file, logger2.getPath().?);
    try testing.expect(!logger2.isAppendMode());

    // Test with file path in append mode
    var logger3 = try OutputLogger.init(testing.allocator, test_file, true);
    defer logger3.deinit();

    try testing.expect(logger3.isEnabled());
    try testing.expectEqualStrings(test_file, logger3.getPath().?);
    try testing.expect(logger3.isAppendMode());
}

test "OutputLogger - comprehensive empty path validation" {
    const testing = std.testing;

    try testing.expectError(config.IOControlError.InvalidOutputPath, OutputLogger.init(testing.allocator, "", false));
    try testing.expectError(config.IOControlError.InvalidOutputPath, OutputLogger.init(testing.allocator, "", true));
}

test "OutputLogger - comprehensive write operations without file" {
    const testing = std.testing;

    var logger = try OutputLogger.init(testing.allocator, null, false);
    defer logger.deinit();

    // Should not error when no file is configured
    try logger.write("test data");
    try logger.write("");
    try logger.write("more data");
    try logger.flush();
}

test "OutputLogger - comprehensive file creation and writing" {
    const testing = std.testing;

    const test_file = "test_output_write_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Test truncate mode with multiple writes
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("Hello, ");
        try logger.write("World!");
        try logger.write("\nSecond line");
        try logger.flush();
    }

    // Verify file contents
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("Hello, World!\nSecond line", contents);
    }
}

test "OutputLogger - comprehensive append mode functionality" {
    const testing = std.testing;

    const test_file = "test_output_append_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write in truncate mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("First line\n");
        try logger.flush();
    }

    // Second write in append mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, true);
        defer logger.deinit();

        try logger.write("Second line\n");
        try logger.flush();
    }

    // Third write in append mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, true);
        defer logger.deinit();

        try logger.write("Third line\n");
        try logger.flush();
    }

    // Verify all lines are present
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("First line\nSecond line\nThird line\n", contents);
    }
}

test "OutputLogger - comprehensive large data handling" {
    const testing = std.testing;

    const test_file = "test_output_large_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        // Write large amount of data in chunks
        const chunk_size = 1000;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const large_chunk = "A" ** chunk_size;
            try logger.write(large_chunk);
        }
        try logger.flush();
    }

    // Verify file size
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const stat = try file.stat();
        try testing.expectEqual(@as(u64, 10000), stat.size);
    }
}

test "OutputLogger - comprehensive binary data handling" {
    const testing = std.testing;

    const test_file = "test_output_binary_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
    const more_binary = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 };

    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write(&binary_data);
        try logger.write(&more_binary);
        try logger.flush();
    }

    // Verify binary data integrity
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        var read_buffer: [16]u8 = undefined;
        const bytes_read = try file.readAll(&read_buffer);

        try testing.expectEqual(@as(usize, 16), bytes_read);

        // Check first chunk
        for (binary_data, 0..) |expected, i| {
            try testing.expectEqual(expected, read_buffer[i]);
        }

        // Check second chunk
        for (more_binary, 0..) |expected, i| {
            try testing.expectEqual(expected, read_buffer[8 + i]);
        }
    }
}

test "OutputLogger - comprehensive error recovery scenarios" {
    const testing = std.testing;

    // Test initialization with invalid directory
    const invalid_path = "/nonexistent/directory/file.txt";
    try testing.expectError(config.IOControlError.DirectoryNotFound, OutputLogger.init(testing.allocator, invalid_path, false));
    try testing.expectError(config.IOControlError.DirectoryNotFound, OutputLogger.init(testing.allocator, invalid_path, true));
}

test "mapFileError - comprehensive error mapping coverage" {
    const testing = std.testing;

    const test_path = "test_file.txt";

    // Test all error mappings
    const access_err = mapFileError(error.AccessDenied, test_path, "test");
    try testing.expectEqual(config.IOControlError.InsufficientPermissions, access_err);

    const notfound_err = mapFileError(error.FileNotFound, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notfound_err);

    const isdir_err = mapFileError(error.IsDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.IsDirectory, isdir_err);

    const nospace_err = mapFileError(error.NoSpaceLeft, test_path, "test");
    try testing.expectEqual(config.IOControlError.DiskFull, nospace_err);

    const busy_err = mapFileError(error.FileBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, busy_err);

    const resource_busy_err = mapFileError(error.ResourceBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, resource_busy_err);

    const toolong_err = mapFileError(error.NameTooLong, test_path, "test");
    try testing.expectEqual(config.IOControlError.PathTooLong, toolong_err);

    const utf8_err = mapFileError(error.InvalidUtf8, test_path, "test");
    try testing.expectEqual(config.IOControlError.InvalidPathCharacters, utf8_err);

    const badpath_err = mapFileError(error.BadPathName, test_path, "test");
    try testing.expectEqual(config.IOControlError.InvalidPathCharacters, badpath_err);

    const notdir_err = mapFileError(error.NotDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notdir_err);

    const device_busy_err = mapFileError(error.DeviceBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileSystemError, device_busy_err);

    const system_resources_err = mapFileError(error.SystemResources, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileSystemError, system_resources_err);

    const unknown_err = mapFileError(error.Unexpected, test_path, "test");
    try testing.expectEqual(config.IOControlError.OutputFileCreateFailed, unknown_err);
}

test "OutputLogger - multiple flush operations" {
    const testing = std.testing;

    const test_file = "test_output_flush.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("Data 1");
        try logger.flush();

        try logger.write("Data 2");
        try logger.flush();

        try logger.write("Data 3");
        try logger.flush();
    }

    // Verify all data was written
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try testing.expectEqualStrings("Data 1Data 2Data 3", contents);
    }
}
