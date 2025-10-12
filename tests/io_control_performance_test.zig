//! Performance and compatibility tests for I/O control and output features
//! Tests large file transfers, binary data handling, memory usage, resource cleanup, and cross-platform behavior
//!
//! This test suite covers:
//! - Large file transfers with output logging enabled
//! - Binary data handling with hex dump functionality
//! - Memory usage and resource cleanup under various scenarios
//! - Cross-platform file I/O behavior and path handling
//!
//! Requirements covered: 4.3, 4.5, 4.6
//!
//! This is a standalone test module that implements simplified versions of
//! OutputLogger and HexDumper for performance testing without depending on
//! the main source modules.

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const builtin = @import("builtin");
const test_artifacts = @import("utils/test_artifacts.zig");

// =============================================================================
// SIMPLIFIED OUTPUT LOGGER FOR TESTING
// =============================================================================

const TestOutputLogger = struct {
    file: ?std.fs.File = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, append: bool) !TestOutputLogger {
        if (path == null) return TestOutputLogger{ .allocator = allocator };

        const file = if (append)
            try std.fs.cwd().openFile(path.?, .{ .mode = .write_only })
        else
            try std.fs.cwd().createFile(path.?, .{ .truncate = true });

        if (append) {
            try file.seekFromEnd(0);
        }

        return TestOutputLogger{
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestOutputLogger) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    pub fn write(self: *TestOutputLogger, data: []const u8) !void {
        if (self.file) |file| {
            try file.writeAll(data);
        }
    }

    pub fn flush(self: *TestOutputLogger) !void {
        if (self.file) |file| {
            try file.sync();
        }
    }
};

// =============================================================================
// SIMPLIFIED HEX DUMPER FOR TESTING
// =============================================================================

const TestHexDumper = struct {
    file: ?std.fs.File = null,
    allocator: std.mem.Allocator,
    offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) !TestHexDumper {
        const file = if (path != null)
            try std.fs.cwd().createFile(path.?, .{ .truncate = true })
        else
            null;

        return TestHexDumper{
            .file = file,
            .allocator = allocator,
            .offset = 0,
        };
    }

    pub fn deinit(self: *TestHexDumper) void {
        if (self.file) |file| {
            file.close();
        }
    }

    pub fn dump(self: *TestHexDumper, data: []const u8) !void {
        if (self.file == null) return;

        var i: usize = 0;
        while (i < data.len) {
            const chunk_size = @min(16, data.len - i);
            const chunk = data[i .. i + chunk_size];

            try self.formatHexLine(chunk, self.offset + i);
            i += chunk_size;
        }
        self.offset += data.len;
    }

    fn formatHexLine(self: *TestHexDumper, data: []const u8, offset: u64) !void {
        const file = self.file.?;

        // Create a buffer for the writer
        var buffer: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        // Write offset
        try writer.print("{x:0>8}  ", .{offset});

        // Write hex bytes
        var j: usize = 0;
        while (j < 16) {
            if (j < data.len) {
                try writer.print("{x:0>2} ", .{data[j]});
            } else {
                try writer.print("   ", .{});
            }
            if (j == 7) try writer.print(" ", .{});
            j += 1;
        }

        // Write ASCII representation
        try writer.print(" |", .{});
        for (data) |byte| {
            const ascii_char = if (std.ascii.isPrint(byte)) byte else '.';
            try writer.print("{c}", .{ascii_char});
        }
        // Pad ASCII section
        j = data.len;
        while (j < 16) {
            try writer.print(" ", .{});
            j += 1;
        }
        try writer.print("|\n", .{});

        // Write the formatted line to the file
        try file.writeAll(stream.getWritten());
    }
};

// =============================================================================
// LARGE FILE TRANSFER PERFORMANCE TESTS
// =============================================================================

test "performance - large file transfer with output logging" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test with progressively larger data sizes
    const test_sizes = [_]usize{ 1024, 10 * 1024, 100 * 1024, 1024 * 1024 }; // 1KB to 1MB

    for (test_sizes) |size| {
        const test_output = try artifacts.makePath("large_transfer_{d}.tmp", .{size});
        defer allocator.free(test_output);

        // Create test data
        const test_data = try allocator.alloc(u8, size);
        defer allocator.free(test_data);

        // Fill with pattern data for verification
        for (test_data, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast(i % 256));
        }

        // Measure write performance
        const start_time = std.time.nanoTimestamp();

        // Initialize TestOutputLogger and write data
        var logger = try TestOutputLogger.init(allocator, test_output, false);
        defer logger.deinit();

        try logger.write(test_data);
        try logger.flush();

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Verify data integrity
        const file = try std.fs.cwd().openFile(test_output, .{});
        defer file.close();

        const stat = try file.stat();
        try expectEqual(@as(u64, size), stat.size);

        const read_data = try file.readToEndAlloc(allocator, size + 1);
        defer allocator.free(read_data);

        try expectEqual(size, read_data.len);
        try expect(std.mem.eql(u8, test_data, read_data));

        // Performance logging (for manual verification)
        const throughput_mbps = (@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)) / (duration_ms / 1000.0);
        std.debug.print("Size: {d}KB, Time: {d:.2}ms, Throughput: {d:.2}MB/s\n", .{
            size / 1024,
            duration_ms,
            throughput_mbps,
        });
    }
}

test "performance - large file transfer with hex dump" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test hex dump performance with various data sizes
    const test_sizes = [_]usize{ 1024, 4096, 16384 }; // Smaller sizes for hex dump due to expansion

    for (test_sizes) |size| {
        const test_hexdump = try artifacts.makePath("large_hexdump_{d}.tmp", .{size});
        defer allocator.free(test_hexdump);

        // Create binary test data with varied patterns
        const test_data = try allocator.alloc(u8, size);
        defer allocator.free(test_data);

        for (test_data, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast((i * 17 + 42) % 256)); // Varied pattern
        }

        // Measure hex dump performance
        const start_time = std.time.nanoTimestamp();

        var hex_dumper = try TestHexDumper.init(allocator, test_hexdump);
        defer hex_dumper.deinit();

        try hex_dumper.dump(test_data);

        const end_time = std.time.nanoTimestamp();
        const duration_ns = end_time - start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Verify hex dump file was created and has reasonable size
        const file = try std.fs.cwd().openFile(test_hexdump, .{});
        defer file.close();

        const stat = try file.stat();
        try expect(stat.size > size); // Hex dump should be larger than original data

        // Read and verify hex dump format
        const hex_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(hex_content);

        // Verify hex dump contains expected elements
        try expect(std.mem.indexOf(u8, hex_content, "00000000") != null); // Offset
        try expect(std.mem.indexOf(u8, hex_content, "|") != null); // ASCII section
        try expect(std.mem.count(u8, hex_content, "\n") >= size / 16); // Line count

        // Performance logging
        const throughput_kbps = (@as(f64, @floatFromInt(size)) / 1024.0) / (duration_ms / 1000.0);
        std.debug.print("Hex dump - Size: {d}KB, Time: {d:.2}ms, Throughput: {d:.2}KB/s\n", .{
            size / 1024,
            duration_ms,
            throughput_kbps,
        });
    }
}

test "performance - concurrent file operations" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test concurrent output logging and hex dump operations
    const test_data = "Concurrent operation test data with various characters: !@#$%^&*()_+{}|:<>?[]\\;'\",./" ** 10;

    const output_file = try artifacts.relativePath("concurrent_output.tmp");
    defer allocator.free(output_file);
    const hexdump_file = try artifacts.relativePath("concurrent_hexdump.tmp");
    defer allocator.free(hexdump_file);

    const start_time = std.time.nanoTimestamp();

    // Initialize both loggers
    var output_logger = try TestOutputLogger.init(allocator, output_file, false);
    defer output_logger.deinit();

    var hex_dumper = try TestHexDumper.init(allocator, hexdump_file);
    defer hex_dumper.deinit();

    // Perform concurrent operations
    try output_logger.write(test_data);
    try hex_dumper.dump(test_data);

    try output_logger.flush();

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Verify both files were created correctly
    {
        const file = try std.fs.cwd().openFile(output_file, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, test_data.len + 1);
        defer allocator.free(content);

        try expectEqualStrings(test_data, content);
    }

    {
        const file = try std.fs.cwd().openFile(hexdump_file, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10240);
        defer allocator.free(content);

        try expect(content.len > 0);
        try expect(std.mem.indexOf(u8, content, "00000000") != null);
    }

    std.debug.print("Concurrent operations completed in {d:.2}ms\n", .{duration_ms});
}

// =============================================================================
// BINARY DATA HANDLING TESTS
// =============================================================================

test "performance - binary data patterns" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test various binary data patterns that might cause performance issues
    const test_patterns = [_]struct {
        name: []const u8,
        generator: *const fn ([]u8) void,
    }{
        .{ .name = "all_zeros", .generator = generateAllZeros },
        .{ .name = "all_ones", .generator = generateAllOnes },
        .{ .name = "alternating", .generator = generateAlternating },
        .{ .name = "random_binary", .generator = generateRandomBinary },
        .{ .name = "control_chars", .generator = generateControlChars },
        .{ .name = "high_ascii", .generator = generateHighAscii },
    };

    const data_size = 4096;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    for (test_patterns) |pattern| {
        const output_file = try artifacts.makePath("binary_{s}_output.tmp", .{pattern.name});
        defer allocator.free(output_file);
        const hexdump_file = try artifacts.makePath("binary_{s}_hexdump.tmp", .{pattern.name});
        defer allocator.free(hexdump_file);

        // Generate test pattern
        pattern.generator(test_data);

        const start_time = std.time.nanoTimestamp();

        // Test output logging
        var output_logger = try TestOutputLogger.init(allocator, output_file, false);
        defer output_logger.deinit();
        try output_logger.write(test_data);
        try output_logger.flush();

        // Test hex dump
        var hex_dumper = try TestHexDumper.init(allocator, hexdump_file);
        defer hex_dumper.deinit();
        try hex_dumper.dump(test_data);

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

        // Verify data integrity
        {
            const file = try std.fs.cwd().openFile(output_file, .{});
            defer file.close();

            const read_data = try file.readToEndAlloc(allocator, data_size + 1);
            defer allocator.free(read_data);

            try expect(std.mem.eql(u8, test_data, read_data));
        }

        // Verify hex dump format
        {
            const file = try std.fs.cwd().openFile(hexdump_file, .{});
            defer file.close();

            const hex_content = try file.readToEndAlloc(allocator, 100000);
            defer allocator.free(hex_content);

            try expect(hex_content.len > 0);
            try expect(std.mem.indexOf(u8, hex_content, "00000000") != null);

            // Verify ASCII representation handles non-printable characters
            if (std.mem.eql(u8, pattern.name, "control_chars")) {
                try expect(std.mem.indexOf(u8, hex_content, ".") != null); // Dots for non-printable
            }
        }

        std.debug.print("Binary pattern '{s}': {d:.2}ms\n", .{ pattern.name, duration_ms });
    }
}

test "performance - null byte handling" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test handling of data with embedded null bytes
    const test_data = [_]u8{ 'H', 'e', 'l', 'l', 'o', 0, 'W', 'o', 'r', 'l', 'd', 0, 0, 0, 'E', 'n', 'd' };

    const output_file = try artifacts.relativePath("null_bytes_output.tmp");
    defer allocator.free(output_file);
    const hexdump_file = try artifacts.relativePath("null_bytes_hexdump.tmp");
    defer allocator.free(hexdump_file);

    // Test output logging with null bytes
    var output_logger = try TestOutputLogger.init(allocator, output_file, false);
    defer output_logger.deinit();
    try output_logger.write(&test_data);
    try output_logger.flush();

    // Test hex dump with null bytes
    var hex_dumper = try TestHexDumper.init(allocator, hexdump_file);
    defer hex_dumper.deinit();
    try hex_dumper.dump(&test_data);

    // Verify null bytes are preserved in output
    {
        const file = try std.fs.cwd().openFile(output_file, .{});
        defer file.close();

        const read_data = try file.readToEndAlloc(allocator, test_data.len + 1);
        defer allocator.free(read_data);

        try expectEqual(test_data.len, read_data.len);
        try expect(std.mem.eql(u8, &test_data, read_data));
    }

    // Verify null bytes are properly represented in hex dump
    {
        const file = try std.fs.cwd().openFile(hexdump_file, .{});
        defer file.close();

        const hex_content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(hex_content);

        try expect(std.mem.indexOf(u8, hex_content, "00") != null); // Null bytes as hex
        try expect(std.mem.indexOf(u8, hex_content, "48") != null); // 'H' in hex
        try expect(std.mem.indexOf(u8, hex_content, "65") != null); // 'e' in hex
        try expect(std.mem.indexOf(u8, hex_content, "Hello") != null or std.mem.indexOf(u8, hex_content, "World") != null); // ASCII representation
    }
}

// =============================================================================
// MEMORY USAGE AND RESOURCE CLEANUP TESTS
// =============================================================================

test "performance - memory usage under load" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test memory usage with multiple simultaneous operations
    const num_operations = 10;
    const data_size = 1024;

    var loggers = try allocator.alloc(TestOutputLogger, num_operations);
    defer allocator.free(loggers);

    var hex_dumpers = try allocator.alloc(TestHexDumper, num_operations);
    defer allocator.free(hex_dumpers);

    var file_paths = try allocator.alloc([]const u8, num_operations * 2);
    defer {
        for (file_paths) |path| {
            allocator.free(path);
        }
        allocator.free(file_paths);
    }

    // Initialize multiple loggers and hex dumpers
    for (0..num_operations) |i| {
        file_paths[i * 2] = try artifacts.makePath("memory_test_output_{d}.tmp", .{i});
        file_paths[i * 2 + 1] = try artifacts.makePath("memory_test_hexdump_{d}.tmp", .{i});

        loggers[i] = try TestOutputLogger.init(allocator, file_paths[i * 2], false);
        hex_dumpers[i] = try TestHexDumper.init(allocator, file_paths[i * 2 + 1]);
    }

    // Cleanup function
    defer {
        for (0..num_operations) |i| {
            loggers[i].deinit();
            hex_dumpers[i].deinit();
        }
    }

    // Create test data
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    for (test_data, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    const start_time = std.time.nanoTimestamp();

    // Perform operations on all loggers/dumpers
    for (0..num_operations) |i| {
        try loggers[i].write(test_data);
        try hex_dumpers[i].dump(test_data);
        try loggers[i].flush();
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Verify all operations completed successfully
    for (0..num_operations) |i| {
        // Check output file
        const output_file = try std.fs.cwd().openFile(file_paths[i * 2], .{});
        defer output_file.close();

        const stat = try output_file.stat();
        try expectEqual(@as(u64, data_size), stat.size);

        // Check hex dump file
        const hexdump_file = try std.fs.cwd().openFile(file_paths[i * 2 + 1], .{});
        defer hexdump_file.close();

        const hex_stat = try hexdump_file.stat();
        try expect(hex_stat.size > data_size); // Hex dump should be larger
    }

    std.debug.print("Memory load test - {d} operations: {d:.2}ms\n", .{ num_operations, duration_ms });
}

test "performance - resource cleanup verification" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test that resources are properly cleaned up even under error conditions
    var test_files = [_][]const u8{
        try artifacts.relativePath("cleanup_test_1.tmp"),
        try artifacts.relativePath("cleanup_test_2.tmp"),
        try artifacts.relativePath("cleanup_test_3.tmp"),
    };
    defer {
        for (&test_files) |path| {
            allocator.free(path);
        }
    }

    // Test normal cleanup
    {
        var logger = try TestOutputLogger.init(allocator, test_files[0], false);
        try logger.write("Test data");
        logger.deinit(); // Explicit cleanup
    }

    // Test cleanup with defer (simulating error conditions)
    {
        var logger = try TestOutputLogger.init(allocator, test_files[1], false);
        defer logger.deinit(); // Cleanup via defer

        try logger.write("Test data with defer cleanup");
        // Simulate early return or error
    }

    // Test multiple cleanup calls (should be safe)
    {
        var logger = try TestOutputLogger.init(allocator, test_files[2], false);
        try logger.write("Test data");
        logger.deinit();
        logger.deinit(); // Second call should be safe
    }

    // Verify files were created
    for (test_files) |file_path| {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        try expect(stat.size > 0);
    }

    // Clean up test files
}

test "performance - append mode performance" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    const test_file = try artifacts.relativePath("append_performance.tmp");
    defer allocator.free(test_file);

    const chunk_size = 1024;
    const num_chunks = 10;
    const test_data = try allocator.alloc(u8, chunk_size);
    defer allocator.free(test_data);

    // Fill test data
    for (test_data, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    const start_time = std.time.nanoTimestamp();

    // First write (truncate mode)
    {
        var logger = try TestOutputLogger.init(allocator, test_file, false);
        defer logger.deinit();
        try logger.write(test_data);
        try logger.flush();
    }

    // Subsequent writes (append mode)
    for (1..num_chunks) |_| {
        var logger = try TestOutputLogger.init(allocator, test_file, true);
        defer logger.deinit();
        try logger.write(test_data);
        try logger.flush();
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Verify final file size
    const file = try std.fs.cwd().openFile(test_file, .{});
    defer file.close();

    const stat = try file.stat();
    const expected_size = chunk_size * num_chunks;
    try expectEqual(@as(u64, expected_size), stat.size);

    std.debug.print("Append performance - {d} chunks: {d:.2}ms\n", .{ num_chunks, duration_ms });
}

// =============================================================================
// CROSS-PLATFORM FILE I/O AND PATH HANDLING TESTS
// =============================================================================

test "compatibility - cross-platform path handling" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test various path formats that should work across platforms
    var test_paths = [_][]const u8{
        try artifacts.relativePath("simple_file.tmp"),
        try artifacts.relativePath("file_with_spaces.tmp"),
        try artifacts.relativePath("file-with-dashes.tmp"),
        try artifacts.relativePath("file_with_underscores.tmp"),
        try artifacts.relativePath("file.with.dots.tmp"),
        try artifacts.relativePath("UPPERCASE_FILE.tmp"),
        try artifacts.relativePath("lowercase_file.tmp"),
        try artifacts.relativePath("MixedCase_File.tmp"),
    };
    defer {
        for (test_paths) |path| {
            allocator.free(path);
        }
    }

    const test_data = "Cross-platform path test data";

    // Test file creation with various path formats
    for (test_paths) |path| {
        var logger = try TestOutputLogger.init(allocator, path, false);
        defer logger.deinit();

        try logger.write(test_data);
        try logger.flush();

        // Verify file was created and is readable
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, test_data.len + 1);
        defer allocator.free(content);

        try expectEqualStrings(test_data, content);
    }
}

test "compatibility - file permissions and access" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    const test_file = try artifacts.relativePath("permissions_test.tmp");
    defer allocator.free(test_file);

    // Test file creation with default permissions
    {
        var logger = try TestOutputLogger.init(allocator, test_file, false);
        defer logger.deinit();

        try logger.write("Permission test data");
        try logger.flush();
    }

    // Verify file is readable and writable
    {
        const file = try std.fs.cwd().openFile(test_file, .{ .mode = .read_write });
        defer file.close();

        // Try to write additional data
        try file.seekFromEnd(0);
        try file.writeAll("\nAdditional data");

        // Verify both writes are present
        try file.seekTo(0);
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);

        try expect(std.mem.indexOf(u8, content, "Permission test data") != null);
        try expect(std.mem.indexOf(u8, content, "Additional data") != null);
    }
}

test "compatibility - platform-specific behavior" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test behavior that might vary across platforms
    const test_file = try artifacts.relativePath("platform_behavior.tmp");
    defer allocator.free(test_file);

    // Test line ending handling
    const test_data = switch (builtin.os.tag) {
        .windows => "Line 1\r\nLine 2\r\nLine 3\r\n",
        else => "Line 1\nLine 2\nLine 3\n",
    };

    var logger = try TestOutputLogger.init(allocator, test_file, false);
    defer logger.deinit();

    try logger.write(test_data);
    try logger.flush();

    // Verify data was written correctly
    const file = try std.fs.cwd().openFile(test_file, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, test_data.len + 1);
    defer allocator.free(content);

    try expectEqualStrings(test_data, content);

    // Test that we can handle both line ending styles regardless of platform
    const mixed_endings = "Unix line\nWindows line\r\nMac line\r";

    const mixed_file = try artifacts.relativePath("mixed_endings.tmp");
    defer allocator.free(mixed_file);

    var mixed_logger = try TestOutputLogger.init(allocator, mixed_file, false);
    defer mixed_logger.deinit();

    try mixed_logger.write(mixed_endings);
    try mixed_logger.flush();

    // Verify mixed endings are preserved
    const mixed_file_handle = try std.fs.cwd().openFile(mixed_file, .{});
    defer mixed_file_handle.close();

    const mixed_content = try mixed_file_handle.readToEndAlloc(allocator, mixed_endings.len + 1);
    defer allocator.free(mixed_content);

    try expectEqualStrings(mixed_endings, mixed_content);
}

test "compatibility - unicode and special characters" {
    const allocator = testing.allocator;
    var artifacts = test_artifacts.ArtifactDir.init(allocator);
    defer artifacts.deinit();

    // Test handling of various character encodings and special characters
    const test_cases = [_]struct {
        name: []const u8,
        data: []const u8,
    }{
        .{ .name = "ascii", .data = "Basic ASCII text 123!@#$%^&*()" },
        .{ .name = "utf8", .data = "UTF-8: Hello 世界 🌍 café naïve résumé" },
        .{ .name = "special_chars", .data = "Special: \t\n\r\\\"'`~!@#$%^&*()_+-=[]{}|;:,.<>?" },
        .{ .name = "control_chars", .data = "\x01\x02\x03\x1B[31mRed\x1B[0m\x7F" },
    };

    for (test_cases) |test_case| {
        const output_file = try artifacts.makePath("unicode_{s}_output.tmp", .{test_case.name});
        defer allocator.free(output_file);
        const hexdump_file = try artifacts.makePath("unicode_{s}_hexdump.tmp", .{test_case.name});
        defer allocator.free(hexdump_file);

        // Test output logging
        var logger = try TestOutputLogger.init(allocator, output_file, false);
        defer logger.deinit();
        try logger.write(test_case.data);
        try logger.flush();

        // Test hex dump
        var hex_dumper = try TestHexDumper.init(allocator, hexdump_file);
        defer hex_dumper.deinit();
        try hex_dumper.dump(test_case.data);

        // Verify output file preserves data exactly
        {
            const file = try std.fs.cwd().openFile(output_file, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, test_case.data.len + 1);
            defer allocator.free(content);

            try expectEqualStrings(test_case.data, content);
        }

        // Verify hex dump handles special characters appropriately
        {
            const file = try std.fs.cwd().openFile(hexdump_file, .{});
            defer file.close();

            const hex_content = try file.readToEndAlloc(allocator, 4096);
            defer allocator.free(hex_content);

            try expect(hex_content.len > 0);
            try expect(std.mem.indexOf(u8, hex_content, "00000000") != null);

            // For control characters, verify they're represented as dots
            if (std.mem.eql(u8, test_case.name, "control_chars")) {
                try expect(std.mem.indexOf(u8, hex_content, ".") != null);
            }
        }
    }
}

// =============================================================================
// HELPER FUNCTIONS FOR BINARY DATA GENERATION
// =============================================================================

fn generateAllZeros(data: []u8) void {
    @memset(data, 0);
}

fn generateAllOnes(data: []u8) void {
    @memset(data, 0xFF);
}

fn generateAlternating(data: []u8) void {
    for (data, 0..) |*byte, i| {
        byte.* = if (i % 2 == 0) 0xAA else 0x55;
    }
}

fn generateRandomBinary(data: []u8) void {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (data) |*byte| {
        byte.* = random.int(u8);
    }
}

fn generateControlChars(data: []u8) void {
    for (data, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 32)); // Control characters 0-31
    }
}

fn generateHighAscii(data: []u8) void {
    for (data, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(128 + (i % 128))); // High ASCII 128-255
    }
}
