//! Hexadecimal dump formatting with ASCII sidebar and optional file output.
//!
//! This module provides the `HexDumper` type for formatting binary data in
//! traditional hexdump format with hexadecimal bytes on the left, ASCII
//! representation on the right, and byte offsets for each line.
//!
//! # Features
//!
//! - **Standard hex dump format**: 16 bytes per line with offset, hex, and ASCII
//! - **Dual output**: Display to stdout and optionally save to file
//! - **Offset tracking**: Maintains running offset across multiple dump operations
//! - **Non-printable handling**: Displays '.' for non-ASCII bytes in sidebar
//!
//! # Output Format
//!
//! ```
//! 00000000  48 65 6c 6c 6f 2c 20 57  6f 72 6c 64 21 0a 00 00  |Hello, World!...|
//! 00000010  54 65 73 74 20 64 61 74  61 20 68 65 72 65 2e 00  |Test data here..|
//! ```
//!
//! Format breakdown:
//! - Offset (8 hex digits): Byte position in stream
//! - Hex bytes (2 groups of 8): Hexadecimal representation
//! - ASCII sidebar (16 chars): Printable ASCII or '.' for non-printable
//!
//! # Usage Example
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Create hex dumper with file output
//! var dumper = try HexDumper.init(allocator, "dump.txt");
//! defer dumper.deinit();
//!
//! // Dump binary data
//! const data = [_]u8{0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21};
//! try dumper.dump(&data);
//! try dumper.flush();
//!
//! // Dump more data (offset continues from previous)
//! try dumper.dump("More data");
//! // Output: 00000006  4d 6f 72 65 20 64 61 74  61 ...
//!
//! // Reset offset for new connection
//! dumper.resetOffset();
//! ```
//!
//! # Use Cases
//!
//! - **Network protocol debugging**: Inspect binary network traffic
//! - **Data validation**: Verify binary data transmission
//! - **Reverse engineering**: Analyze binary file formats
//! - **Security analysis**: Examine suspicious binary data
//!
//! # Performance Characteristics
//!
//! - O(n) time complexity for dumping n bytes
//! - Fixed 80-byte stack buffer per line (no heap allocation for formatting)
//! - File I/O overhead if file output enabled
//!
//! # Platform Compatibility
//!
//! Works on all platforms supported by Zig's standard library with cross-platform
//! file operations and output handling.

const std = @import("std");
const config = @import("../config.zig");

// Import submodules
const formatter = @import("hexdump/formatter.zig");
const output = @import("hexdump/output.zig");

// Re-export functions
pub const mapHexDumpFileError = output.mapHexDumpFileError;
pub const formatHexLine = formatter.formatHexLine;

/// HexDumper handles formatting binary data in hexadecimal format with ASCII sidebar
/// and optional file output support.
///
/// This type manages hex dump formatting for Zigcat, displaying binary data in the
/// traditional format with offsets, hex bytes, and an ASCII sidebar. Output is sent
/// to both stdout and optionally to a file for persistent logging.
///
/// The dumper maintains a running offset across multiple dump operations, which is
/// useful for streaming data where you want continuous offset tracking. The offset
/// can be reset for new connections or data streams.
pub const HexDumper = struct {
    file: ?std.fs.File = null,
    allocator: std.mem.Allocator,
    path: ?[]const u8 = null,
    offset: u64 = 0,

    /// Initialize HexDumper with optional file path for output.
    ///
    /// Creates a new HexDumper instance. If a file path is provided, the file
    /// will be created (truncated if it exists) for hex dump output. The offset
    /// is initialized to zero.
    ///
    /// Parameters:
    ///   - allocator: Memory allocator (stored for future use)
    ///   - path: Optional file path for saving hex dump (null for stdout-only)
    ///
    /// Returns:
    ///   Initialized HexDumper instance with offset at 0
    ///
    /// Errors:
    ///   - InvalidOutputPath: Empty path string
    ///   - Various IOControlErrors from mapHexDumpFileError()
    ///
    /// Example:
    /// ```zig
    /// var dumper = try HexDumper.init(allocator, "network.hex");
    /// defer dumper.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) !HexDumper {
        var dumper = HexDumper{
            .allocator = allocator,
            .path = path,
            .offset = 0,
        };

        if (path) |file_path| {
            dumper.file = try output.openHexDumpFile(file_path);
        }

        return dumper;
    }

    /// Clean up resources and close file if open.
    ///
    /// Closes the hex dump file (if one was opened) and releases resources.
    /// Safe to call multiple times. This method must be called to ensure
    /// the file is properly closed and buffers are flushed.
    ///
    /// Example:
    /// ```zig
    /// var dumper = try HexDumper.init(allocator, "data.hex");
    /// defer dumper.deinit(); // Ensures cleanup even on error
    /// ```
    pub fn deinit(self: *HexDumper) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    /// Dump data in hexadecimal format with ASCII sidebar.
    ///
    /// Formats the provided data in traditional hex dump format (16 bytes per line)
    /// and outputs to both stdout and the file (if configured). The offset is
    /// automatically incremented by the data length after dumping.
    ///
    /// If data is empty, this is a no-op that returns immediately.
    ///
    /// Parameters:
    ///   - data: Binary data to format and display
    ///
    /// Errors:
    ///   - Various IOControlErrors if file write fails
    ///
    /// Example:
    /// ```zig
    /// const packet = [_]u8{0x48, 0x65, 0x6c, 0x6c, 0x6f};
    /// try dumper.dump(&packet);
    /// // Output: 00000000  48 65 6c 6c 6f                                    |Hello|
    /// ```
    pub fn dump(self: *HexDumper, data: []const u8) !void {
        if (data.len == 0) return;

        var i: usize = 0;
        while (i < data.len) {
            const chunk_size = @min(16, data.len - i);
            const chunk = data[i .. i + chunk_size];

            try self.formatAndWriteLine(chunk, self.offset + i);
            i += chunk_size;
        }

        self.offset += data.len;
    }

    /// Format and write a single line of hex dump output.
    ///
    /// Internal function that formats up to 16 bytes of data and writes it
    /// to stdout and file (if configured).
    ///
    /// Parameters:
    ///   - data: Up to 16 bytes of data to format
    ///   - offset: Byte offset to display for this line
    ///
    /// Errors:
    ///   - Various IOControlErrors if file write fails
    fn formatAndWriteLine(self: *HexDumper, data: []const u8, offset: u64) !void {
        // Use a fixed-size buffer for the formatted line
        var line_buffer: [80]u8 = undefined;
        const formatted_line = try formatter.formatHexLine(data, offset, &line_buffer);

        // Write to stdout and file
        try output.writeHexLine(formatted_line, self.file, self.path);
    }

    /// Flush any buffered data to disk with error recovery.
    ///
    /// Forces all buffered hex dump data to be written to disk using `file.sync()`.
    /// If no file is configured, this is a no-op that returns immediately.
    ///
    /// Errors:
    ///   - Various IOControlErrors from mapHexDumpFileError() if sync fails
    ///
    /// Example:
    /// ```zig
    /// try dumper.dump(packet_data);
    /// try dumper.flush(); // Ensure hex dump is on disk
    /// ```
    pub fn flush(self: *HexDumper) !void {
        if (self.file) |file| {
            if (self.path) |path| {
                try output.flushHexDumpFile(file, path);
            }
        }
    }

    /// Check if dumper is configured to write to a file.
    ///
    /// Returns: true if a file was opened during init, false for stdout-only mode
    pub fn isFileEnabled(self: *const HexDumper) bool {
        return self.file != null;
    }

    /// Get the configured file path (may be null).
    ///
    /// Returns: File path string if configured, null for stdout-only mode
    pub fn getPath(self: *const HexDumper) ?[]const u8 {
        return self.path;
    }

    /// Get current offset for next dump operation.
    ///
    /// Returns: Current byte offset (incremented after each dump() call)
    pub fn getOffset(self: *const HexDumper) u64 {
        return self.offset;
    }

    /// Reset offset to zero (useful for new connections).
    ///
    /// Resets the running offset back to 0. This is useful when starting a new
    /// connection or data stream where you want offsets to restart from zero.
    ///
    /// Example:
    /// ```zig
    /// try dumper.dump(connection1_data);
    /// dumper.resetOffset(); // Start fresh for new connection
    /// try dumper.dump(connection2_data);
    /// // Output: 00000000  ... (offset restarted)
    /// ```
    pub fn resetOffset(self: *HexDumper) void {
        self.offset = 0;
    }
};

// Tests
test "HexDumper - init with no path" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    try testing.expect(!dumper.isFileEnabled());
    try testing.expect(dumper.getPath() == null);
    try testing.expect(dumper.getOffset() == 0);
}

test "HexDumper - init with empty path" {
    const testing = std.testing;

    try testing.expectError(config.IOControlError.InvalidOutputPath, HexDumper.init(testing.allocator, ""));
}

test "HexDumper - offset tracking" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    try testing.expect(dumper.getOffset() == 0);

    // Simulate dumping some data (we can't easily test the actual output)
    dumper.offset += 16;
    try testing.expect(dumper.getOffset() == 16);

    dumper.resetOffset();
    try testing.expect(dumper.getOffset() == 0);
}

test "HexDumper - flush with no file" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Should not error when no file is configured
    try dumper.flush();
}

test "HexDumper - create and write to file" {
    const testing = std.testing;

    const test_file = "test_hexdump.tmp";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        try testing.expect(dumper.isFileEnabled());
        try testing.expectEqualStrings(test_file, dumper.getPath().?);

        // Test with some sample data
        const test_data = "Hello, World!";
        try dumper.dump(test_data);
        try dumper.flush();
    }

    // Verify file was created and has content
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should contain hex dump format
        try testing.expect(contents.len > 0);
        try testing.expect(std.mem.indexOf(u8, contents, "00000000") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "Hello, World!") != null);
    }
}

test "HexDumper - empty data handling" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Should handle empty data gracefully
    try dumper.dump("");
    try testing.expect(dumper.getOffset() == 0);
}

test "HexDumper - large data handling" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Test with data larger than 16 bytes (multiple lines)
    const test_data = "This is a test string that is longer than 16 bytes to test multi-line hex dump formatting.";
    try dumper.dump(test_data);

    try testing.expect(dumper.getOffset() == test_data.len);
}

test "HexDumper - binary data with non-printable characters" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Test with binary data including null bytes and control characters
    const test_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x48, 0x65, 0x6C, 0x6C, 0x6F };
    try dumper.dump(&test_data);

    try testing.expect(dumper.getOffset() == test_data.len);
}

test "HexDumper - error recovery and graceful handling" {
    const testing = std.testing;

    // Test initialization with invalid directory
    const invalid_path = "/nonexistent/directory/hexdump.txt";
    try testing.expectError(config.IOControlError.DirectoryNotFound, HexDumper.init(testing.allocator, invalid_path));
}

test "mapHexDumpFileError - comprehensive error mapping" {
    const testing = std.testing;

    // Test various error mappings
    const test_path = "test_hexdump.txt";

    // Test access denied mapping
    const access_err = mapHexDumpFileError(error.AccessDenied, test_path, "test");
    try testing.expectEqual(config.IOControlError.InsufficientPermissions, access_err);

    // Test file not found mapping
    const notfound_err = mapHexDumpFileError(error.FileNotFound, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notfound_err);

    // Test is directory mapping
    const isdir_err = mapHexDumpFileError(error.IsDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.IsDirectory, isdir_err);

    // Test no space left mapping
    const nospace_err = mapHexDumpFileError(error.NoSpaceLeft, test_path, "test");
    try testing.expectEqual(config.IOControlError.DiskFull, nospace_err);

    // Test file busy mapping
    const busy_err = mapHexDumpFileError(error.FileBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, busy_err);

    // Test name too long mapping
    const toolong_err = mapHexDumpFileError(error.NameTooLong, test_path, "test");
    try testing.expectEqual(config.IOControlError.PathTooLong, toolong_err);

    // Test unknown error mapping
    const unknown_err = mapHexDumpFileError(error.Unexpected, test_path, "test");
    try testing.expectEqual(config.IOControlError.HexDumpFileCreateFailed, unknown_err);
}
// =============================================================================
// COMPREHENSIVE HEX DUMPER TESTS
// =============================================================================

test "HexDumper - comprehensive initialization and properties" {
    const testing = std.testing;

    // Test with no file path
    var dumper1 = try HexDumper.init(testing.allocator, null);
    defer dumper1.deinit();

    try testing.expect(!dumper1.isFileEnabled());
    try testing.expect(dumper1.getPath() == null);
    try testing.expectEqual(@as(u64, 0), dumper1.getOffset());

    // Test with file path
    const test_file = "test_hexdumper_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var dumper2 = try HexDumper.init(testing.allocator, test_file);
    defer dumper2.deinit();

    try testing.expect(dumper2.isFileEnabled());
    try testing.expectEqualStrings(test_file, dumper2.getPath().?);
    try testing.expectEqual(@as(u64, 0), dumper2.getOffset());
}

test "HexDumper - comprehensive empty path validation" {
    const testing = std.testing;

    try testing.expectError(config.IOControlError.InvalidOutputPath, HexDumper.init(testing.allocator, ""));
}

test "HexDumper - comprehensive offset tracking" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    try testing.expectEqual(@as(u64, 0), dumper.getOffset());

    // Simulate dumping various sizes of data
    const test_data1 = "Hello";
    try dumper.dump(test_data1);
    try testing.expectEqual(@as(u64, test_data1.len), dumper.getOffset());

    const test_data2 = ", World!";
    try dumper.dump(test_data2);
    try testing.expectEqual(@as(u64, test_data1.len + test_data2.len), dumper.getOffset());

    const test_data3 = " This is a longer string for testing.";
    try dumper.dump(test_data3);
    try testing.expectEqual(@as(u64, test_data1.len + test_data2.len + test_data3.len), dumper.getOffset());

    // Reset offset
    dumper.resetOffset();
    try testing.expectEqual(@as(u64, 0), dumper.getOffset());
}

test "HexDumper - comprehensive empty data handling" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Should handle empty data gracefully
    try dumper.dump("");
    try testing.expectEqual(@as(u64, 0), dumper.getOffset());

    // Multiple empty dumps
    try dumper.dump("");
    try dumper.dump("");
    try dumper.dump("");
    try testing.expectEqual(@as(u64, 0), dumper.getOffset());
}

test "HexDumper - comprehensive file output functionality" {
    const testing = std.testing;

    const test_file = "test_hexdump_output_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        const test_data = "Hello, World!";
        try dumper.dump(test_data);
        try dumper.flush();
    }

    // Verify file was created and has hex dump content
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should contain hex dump format
        try testing.expect(contents.len > 0);
        try testing.expect(std.mem.indexOf(u8, contents, "00000000") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "Hello, World!") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "|") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "48 65 6c 6c 6f") != null); // "Hello" in hex
    }
}

test "HexDumper - comprehensive formatting accuracy for various data sizes" {
    const testing = std.testing;

    const test_file = "test_hexdump_formatting.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        // Test with exactly 16 bytes
        const test_data_16 = "0123456789ABCDEF";
        try dumper.dump(test_data_16);

        // Test with less than 16 bytes
        dumper.resetOffset();
        const test_data_short = "Short";
        try dumper.dump(test_data_short);

        // Test with more than 16 bytes
        dumper.resetOffset();
        const test_data_long = "This is a test string that is definitely longer than 16 bytes for testing multi-line hex dump.";
        try dumper.dump(test_data_long);

        try dumper.flush();
    }

    // Verify hex dump format
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 4096);
        defer testing.allocator.free(contents);

        // Should have proper hex formatting for 16-byte line
        try testing.expect(std.mem.indexOf(u8, contents, "30 31 32 33 34 35 36 37") != null); // "01234567" in hex
        try testing.expect(std.mem.indexOf(u8, contents, "38 39 41 42 43 44 45 46") != null); // "89ABCDEF" in hex
        try testing.expect(std.mem.indexOf(u8, contents, "|0123456789ABCDEF|") != null);

        // Should have proper formatting for short data
        try testing.expect(std.mem.indexOf(u8, contents, "|Short           |") != null);

        // Should have multiple offset lines for long data
        try testing.expect(std.mem.indexOf(u8, contents, "00000000") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "00000010") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "00000020") != null);
    }
}

test "HexDumper - comprehensive binary data with non-printable characters" {
    const testing = std.testing;

    const test_file = "test_hexdump_binary_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        // Test with all possible byte values
        var all_bytes: [256]u8 = undefined;
        for (all_bytes, 0..) |_, i| {
            all_bytes[i] = @intCast(i);
        }
        try dumper.dump(&all_bytes);

        // Test with specific binary patterns
        dumper.resetOffset();
        const binary_pattern = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
        try dumper.dump(&binary_pattern);

        try dumper.flush();
    }

    // Verify binary hex dump format
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 8192);
        defer testing.allocator.free(contents);

        // Should have proper hex representation
        try testing.expect(std.mem.indexOf(u8, contents, "00 01 02 03 04 05 06 07") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "08 09 0a 0b 0c 0d 0e 0f") != null);

        // Non-printable characters should be replaced with dots
        try testing.expect(std.mem.indexOf(u8, contents, "|................|") != null);

        // Should handle all byte values
        try testing.expect(std.mem.indexOf(u8, contents, "ff") != null); // 255 in hex
    }
}

test "HexDumper - comprehensive mixed printable and non-printable data" {
    const testing = std.testing;

    const test_file = "test_hexdump_mixed_comprehensive.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        // Mix of printable and non-printable characters
        const test_data1 = [_]u8{ 'H', 'e', 'l', 'l', 'o', 0x00, 0x01, 0x02, 'W', 'o', 'r', 'l', 'd', 0xFF, 0xFE, '!' };
        try dumper.dump(&test_data1);

        // Another mixed pattern
        const test_data2 = [_]u8{ 0x7F, 'A', 'B', 'C', 0x80, 0x90, 'X', 'Y', 'Z', 0x00, 0x0A, 0x0D, '1', '2', '3', 0xFF };
        try dumper.dump(&test_data2);

        try dumper.flush();
    }

    // Verify mixed data formatting
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 2048);
        defer testing.allocator.free(contents);

        // Should show printable characters as-is and non-printable as dots
        try testing.expect(std.mem.indexOf(u8, contents, "|Hello...World..!|") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "48 65 6c 6c 6f 00 01 02") != null); // "Hello" + null bytes

        // Should handle the second pattern
        try testing.expect(std.mem.indexOf(u8, contents, "|.ABC..XYZ...123.|") != null);
    }
}

test "HexDumper - comprehensive flush operations" {
    const testing = std.testing;

    // Test flush without file
    var dumper1 = try HexDumper.init(testing.allocator, null);
    defer dumper1.deinit();

    try dumper1.flush(); // Should not error

    // Test flush with file
    const test_file = "test_hexdump_flush.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var dumper2 = try HexDumper.init(testing.allocator, test_file);
    defer dumper2.deinit();

    try dumper2.dump("Test data");
    try dumper2.flush();
    try dumper2.dump("More data");
    try dumper2.flush();
}

test "HexDumper - comprehensive multiple dump operations with offset tracking" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Multiple dumps with different sizes
    try dumper.dump("A");
    try testing.expectEqual(@as(u64, 1), dumper.getOffset());

    try dumper.dump("BC");
    try testing.expectEqual(@as(u64, 3), dumper.getOffset());

    try dumper.dump("DEFG");
    try testing.expectEqual(@as(u64, 7), dumper.getOffset());

    try dumper.dump("HIJKLMNOP");
    try testing.expectEqual(@as(u64, 16), dumper.getOffset());

    try dumper.dump("QRSTUVWXYZ");
    try testing.expectEqual(@as(u64, 26), dumper.getOffset());

    // Reset and verify
    dumper.resetOffset();
    try testing.expectEqual(@as(u64, 0), dumper.getOffset());

    // Continue dumping after reset
    try dumper.dump("New data after reset");
    try testing.expectEqual(@as(u64, 20), dumper.getOffset());
}

test "HexDumper - comprehensive error recovery scenarios" {
    const testing = std.testing;

    // Test initialization with invalid directory
    const invalid_path = "/nonexistent/directory/hexdump.txt";
    try testing.expectError(config.IOControlError.DirectoryNotFound, HexDumper.init(testing.allocator, invalid_path));
}

test "mapHexDumpFileError - comprehensive error mapping coverage" {
    const testing = std.testing;

    const test_path = "test_hexdump.txt";

    // Test all error mappings
    const access_err = mapHexDumpFileError(error.AccessDenied, test_path, "test");
    try testing.expectEqual(config.IOControlError.InsufficientPermissions, access_err);

    const notfound_err = mapHexDumpFileError(error.FileNotFound, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notfound_err);

    const isdir_err = mapHexDumpFileError(error.IsDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.IsDirectory, isdir_err);

    const nospace_err = mapHexDumpFileError(error.NoSpaceLeft, test_path, "test");
    try testing.expectEqual(config.IOControlError.DiskFull, nospace_err);

    const busy_err = mapHexDumpFileError(error.FileBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, busy_err);

    const resource_busy_err = mapHexDumpFileError(error.ResourceBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileLocked, resource_busy_err);

    const toolong_err = mapHexDumpFileError(error.NameTooLong, test_path, "test");
    try testing.expectEqual(config.IOControlError.PathTooLong, toolong_err);

    const utf8_err = mapHexDumpFileError(error.InvalidUtf8, test_path, "test");
    try testing.expectEqual(config.IOControlError.InvalidPathCharacters, utf8_err);

    const badpath_err = mapHexDumpFileError(error.BadPathName, test_path, "test");
    try testing.expectEqual(config.IOControlError.InvalidPathCharacters, badpath_err);

    const notdir_err = mapHexDumpFileError(error.NotDir, test_path, "test");
    try testing.expectEqual(config.IOControlError.DirectoryNotFound, notdir_err);

    const device_busy_err = mapHexDumpFileError(error.DeviceBusy, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileSystemError, device_busy_err);

    const system_resources_err = mapHexDumpFileError(error.SystemResources, test_path, "test");
    try testing.expectEqual(config.IOControlError.FileSystemError, system_resources_err);

    const unknown_err = mapHexDumpFileError(error.Unexpected, test_path, "test");
    try testing.expectEqual(config.IOControlError.HexDumpFileCreateFailed, unknown_err);
}

test "HexDumper - comprehensive edge cases and boundary conditions" {
    const testing = std.testing;

    var dumper = try HexDumper.init(testing.allocator, null);
    defer dumper.deinit();

    // Test with exactly 15 bytes (one less than full line)
    const data_15 = "123456789012345";
    try dumper.dump(data_15);
    try testing.expectEqual(@as(u64, 15), dumper.getOffset());

    // Reset and test with exactly 17 bytes (one more than full line)
    dumper.resetOffset();
    const data_17 = "12345678901234567";
    try dumper.dump(data_17);
    try testing.expectEqual(@as(u64, 17), dumper.getOffset());

    // Reset and test with exactly 32 bytes (two full lines)
    dumper.resetOffset();
    const data_32 = "12345678901234567890123456789012";
    try dumper.dump(data_32);
    try testing.expectEqual(@as(u64, 32), dumper.getOffset());

    // Test with single byte
    dumper.resetOffset();
    try dumper.dump("X");
    try testing.expectEqual(@as(u64, 1), dumper.getOffset());
}

test "HexDumper - comprehensive file truncation behavior" {
    const testing = std.testing;

    const test_file = "test_hexdump_truncation.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write
    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        try dumper.dump("Original content");
        try dumper.flush();
    }

    // Second write (should truncate)
    {
        var dumper = try HexDumper.init(testing.allocator, test_file);
        defer dumper.deinit();

        try dumper.dump("New content");
        try dumper.flush();
    }

    // Verify only new content is present
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should only contain the new content, not the original
        try testing.expect(std.mem.indexOf(u8, contents, "New content") != null);
        try testing.expect(std.mem.indexOf(u8, contents, "Original content") == null);
    }
}
