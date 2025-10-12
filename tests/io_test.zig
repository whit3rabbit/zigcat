//! Comprehensive unit tests for I/O control functionality
//! Tests Config validation, OutputLogger, HexDumper, and CLI parsing for I/O flags
//!
//! This test suite covers:
//! - Config validation including conflicting flags detection
//! - OutputLogger file operations and error handling
//! - HexDumper formatting accuracy and file output
//! - CLI parser handling of new I/O control flags

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

const config = @import("../src/config.zig");
const cli = @import("../src/cli.zig");

// Import I/O modules
const OutputLogger = @import("../src/io/output.zig").OutputLogger;
const HexDumper = @import("../src/io/hexdump.zig").HexDumper;

// =============================================================================
// CONFIG VALIDATION TESTS
// =============================================================================

test "Config validation - conflicting I/O modes" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test send_only and recv_only conflict
    cfg.send_only = true;
    cfg.recv_only = true;

    try expectError(config.IOControlError.ConflictingIOModes, config.validateIOControl(&cfg));
}

test "Config validation - valid I/O modes" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test send_only alone
    cfg.send_only = true;
    cfg.recv_only = false;
    try config.validateIOControl(&cfg);

    // Test recv_only alone
    cfg.send_only = false;
    cfg.recv_only = true;
    try config.validateIOControl(&cfg);

    // Test neither flag set
    cfg.send_only = false;
    cfg.recv_only = false;
    try config.validateIOControl(&cfg);
}

test "Config validation - empty file paths" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test empty output file path
    cfg.output_file = "";
    try expectError(config.IOControlError.InvalidOutputPath, config.validateIOControl(&cfg));

    // Test empty hex dump file path
    cfg.output_file = null;
    cfg.hex_dump_file = "";
    try expectError(config.IOControlError.InvalidOutputPath, config.validateIOControl(&cfg));

    // Test null byte in output path
    cfg.output_file = "test\x00file.txt";
    cfg.hex_dump_file = null;
    try expectError(config.IOControlError.InvalidPathCharacters, config.validateIOControl(&cfg));

    // Test null byte in hex dump path
    cfg.output_file = null;
    cfg.hex_dump_file = "hex\x00dump.txt";
    try expectError(config.IOControlError.InvalidPathCharacters, config.validateIOControl(&cfg));

    // Directory traversal attempts
    cfg.output_file = "../etc/passwd";
    cfg.hex_dump_file = null;
    try expectError(config.IOControlError.PathTraversalDetected, config.validateIOControl(&cfg));

    cfg.output_file = null;
    cfg.hex_dump_file = "..\\windows\\system.ini";
    try expectError(config.IOControlError.PathTraversalDetected, config.validateIOControl(&cfg));
}

test "Config validation - valid file paths" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test valid output file path
    cfg.output_file = "/tmp/output.log";
    cfg.hex_dump_file = null;
    try config.validateIOControl(&cfg);

    // Test valid hex dump file path
    cfg.output_file = null;
    cfg.hex_dump_file = "/tmp/hexdump.log";
    try config.validateIOControl(&cfg);

    // Test both valid paths
    cfg.output_file = "/tmp/output.log";
    cfg.hex_dump_file = "/tmp/hexdump.log";
    try config.validateIOControl(&cfg);
}

test "Config validation - path length limits" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test extremely long path
    const long_path = "a" ** 5000;
    cfg.output_file = long_path;
    try expectError(config.IOControlError.PathTooLong, config.validateIOControl(&cfg));
}

test "Config validation - control characters in paths" {
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Test various control characters
    const control_chars = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0B, 0x0C, 0x0E, 0x0F };

    for (control_chars) |ctrl| {
        const bad_path = std.fmt.allocPrint(testing.allocator, "test{c}file.txt", .{ctrl}) catch continue;
        defer testing.allocator.free(bad_path);

        cfg.output_file = bad_path;
        try expectError(config.IOControlError.InvalidPathCharacters, config.validateIOControl(&cfg));
    }

    // Tab character should be allowed
    cfg.output_file = "test\tfile.txt";
    try config.validateIOControl(&cfg);
}

// =============================================================================
// CLI PARSER TESTS FOR I/O FLAGS
// =============================================================================

test "CLI parser - send-only flag" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.send_only);
    try expect(!cfg.recv_only);
}

test "CLI parser - recv-only flag" {
    var args = [_][:0]const u8{ "zigcat", "--recv-only", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.recv_only);
    try expect(!cfg.send_only);
}

test "CLI parser - conflicting I/O flags" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "--recv-only", "example.com", "80" };

    try expectError(cli.CliError.ConflictingIOModes, cli.parseArgs(testing.allocator, &args));
}

test "CLI parser - output file short flag" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/output.log", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
    try expect(!cfg.append_output);
}

test "CLI parser - output file long flag" {
    var args = [_][:0]const u8{ "zigcat", "--output", "/tmp/output.log", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "CLI parser - append flag with output" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/output.log", "--append", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.append_output);
    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "CLI parser - hex-dump flag without file" {
    var args = [_][:0]const u8{ "zigcat", "-x", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.hex_dump);
    try expect(cfg.hex_dump_file == null);
}

test "CLI parser - hex-dump flag with file" {
    var args = [_][:0]const u8{ "zigcat", "-x", "/tmp/dump.hex", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.hex_dump);
    try expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "CLI parser - hex-dump long flag with file" {
    var args = [_][:0]const u8{ "zigcat", "--hex-dump", "/tmp/dump.hex", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try expect(cfg.hex_dump);
    try expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "CLI parser - invalid output file paths" {
    // Empty output file path
    var args1 = [_][:0]const u8{ "zigcat", "-o", "", "example.com", "80" };
    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(testing.allocator, &args1));

    // Empty hex dump file path
    var args2 = [_][:0]const u8{ "zigcat", "-x", "", "example.com", "80" };
    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(testing.allocator, &args2));

    // Null bytes in output path
    var args3 = [_][:0]const u8{ "zigcat", "-o", "/tmp/out\x00put.log", "example.com", "80" };
    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(testing.allocator, &args3));

    // Null bytes in hex dump path
    var args4 = [_][:0]const u8{ "zigcat", "-x", "/tmp/hex\x00dump.log", "example.com", "80" };
    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(testing.allocator, &args4));

    // Directory traversal attempt
    var args5 = [_][:0]const u8{ "zigcat", "-o", "../etc/passwd", "example.com", "80" };
    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(testing.allocator, &args5));
}

test "CLI parser - missing values for I/O flags" {
    // Missing output file
    var args1 = [_][:0]const u8{ "zigcat", "-o" };
    try expectError(cli.CliError.MissingValue, cli.parseArgs(testing.allocator, &args1));

    // Missing exec command
    var args2 = [_][:0]const u8{ "zigcat", "-e" };
    try expectError(cli.CliError.MissingValue, cli.parseArgs(testing.allocator, &args2));

    // Missing shell command
    var args3 = [_][:0]const u8{ "zigcat", "-c" };
    try expectError(cli.CliError.MissingValue, cli.parseArgs(testing.allocator, &args3));
}

// =============================================================================
// OUTPUT LOGGER TESTS
// =============================================================================

test "OutputLogger - initialization and basic properties" {
    // Test with no file path
    var logger1 = try OutputLogger.init(testing.allocator, null, false);
    defer logger1.deinit();

    try expect(!logger1.isEnabled());
    try expect(logger1.getPath() == null);
    try expect(!logger1.isAppendMode());

    // Test with file path
    const test_file = "test_output_logger.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var logger2 = try OutputLogger.init(testing.allocator, test_file, true);
    defer logger2.deinit();

    try expect(logger2.isEnabled());
    try expectEqualStrings(test_file, logger2.getPath().?);
    try expect(logger2.isAppendMode());
}

test "OutputLogger - empty path validation" {
    try expectError(config.IOControlError.InvalidOutputPath, OutputLogger.init(testing.allocator, "", false));
}

test "OutputLogger - write operations without file" {
    var logger = try OutputLogger.init(testing.allocator, null, false);
    defer logger.deinit();

    // Should not error when no file is configured
    try logger.write("test data");
    try logger.flush();
}

test "OutputLogger - file creation and writing" {
    const test_file = "test_output_write.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Test truncate mode
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

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

        try expectEqualStrings("Hello, World!", contents);
    }
}

test "OutputLogger - append mode functionality" {
    const test_file = "test_output_append.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write
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

    // Verify both lines are present
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        try expectEqualStrings("First line\nSecond line\n", contents);
    }
}

test "OutputLogger - truncate mode overwrites existing file" {
    const test_file = "test_output_truncate.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // First write
    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        try logger.write("Original content");
        try logger.flush();
    }

    // Second write in truncate mode
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

        try expectEqualStrings("New content", contents);
    }
}

test "OutputLogger - large data handling" {
    const test_file = "test_output_large.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        // Write large amount of data
        const large_data = "A" ** 10000;
        try logger.write(large_data);
        try logger.flush();
    }

    // Verify large data was written correctly
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 20000);
        defer testing.allocator.free(contents);

        try expectEqual(@as(usize, 10000), contents.len);
        try expect(std.mem.eql(u8, contents, "A" ** 10000));
    }
}

test "OutputLogger - binary data handling" {
    const test_file = "test_output_binary.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var logger = try OutputLogger.init(testing.allocator, test_file, false);
        defer logger.deinit();

        // Write binary data including null bytes
        const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
        try logger.write(&binary_data);
        try logger.flush();
    }

    // Verify binary data integrity
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        var buffer: [8]u8 = undefined;
        const bytes_read = try file.readAll(&buffer);

        try expectEqual(@as(usize, 8), bytes_read);
        try expect(std.mem.eql(u8, &buffer, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC }));
    }
}

// =============================================================================
// HEX DUMPER TESTS
// =============================================================================

test "HexDumper - initialization and basic properties" {
    // Test with no file path
    var dumper1 = try HexDumper.initFromPath(testing.allocator, null);
    defer dumper1.deinit();

    try expect(!dumper1.isFileEnabled());
    try expect(dumper1.getPath() == null);
    try expectEqual(@as(u64, 0), dumper1.getOffset());

    // Test with file path
    const test_file = "test_hexdumper.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var dumper2 = try HexDumper.initFromPath(testing.allocator, test_file);
    defer dumper2.deinit();

    try expect(dumper2.isFileEnabled());
    try expectEqualStrings(test_file, dumper2.getPath().?);
}

test "HexDumper - empty path validation" {
    try expectError(config.IOControlError.InvalidOutputPath, HexDumper.initFromPath(testing.allocator, ""));
}

test "HexDumper - offset tracking without file" {
    var dumper = try HexDumper.initFromPath(testing.allocator, null);
    defer dumper.deinit();

    try expectEqual(@as(u64, 0), dumper.getOffset());

    // Simulate dumping data
    const test_data = "Hello, World!";
    try dumper.dump(test_data);
    try expectEqual(@as(u64, test_data.len), dumper.getOffset());

    // Reset offset
    dumper.resetOffset();
    try expectEqual(@as(u64, 0), dumper.getOffset());
}

test "HexDumper - dump without file" {
    var dumper = try HexDumper.initFromPath(testing.allocator, null);
    defer dumper.deinit();

    // Should not error when no file is configured
    try dumper.dump("test data");
    try expectEqual(@as(u64, 0), dumper.getOffset());
}

test "HexDumper - file output functionality" {
    const test_file = "test_hexdump_output.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
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

        try expect(contents.len > 0);
        try expect(std.mem.indexOf(u8, contents, "00000000") != null);
        try expect(std.mem.indexOf(u8, contents, "Hello, World!") != null);
        try expect(std.mem.indexOf(u8, contents, "|") != null);
    }
}

test "HexDumper - formatting accuracy for short data" {
    const test_file = "test_hexdump_short.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
        defer dumper.deinit();

        // Test with exactly 16 bytes
        const test_data = "0123456789ABCDEF";
        try dumper.dump(test_data);
        try dumper.flush();
    }

    // Verify hex dump format
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should have proper hex formatting
        try expect(std.mem.indexOf(u8, contents, "30 31 32 33 34 35 36 37") != null); // "01234567" in hex
        try expect(std.mem.indexOf(u8, contents, "38 39 41 42 43 44 45 46") != null); // "89ABCDEF" in hex
        try expect(std.mem.indexOf(u8, contents, "|0123456789ABCDEF|") != null);
    }
}

test "HexDumper - formatting accuracy for long data" {
    const test_file = "test_hexdump_long.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
        defer dumper.deinit();

        // Test with more than 16 bytes (should create multiple lines)
        const test_data = "This is a test string that is longer than 16 bytes.";
        try dumper.dump(test_data);
        try dumper.flush();
    }

    // Verify multiple lines in hex dump
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 2048);
        defer testing.allocator.free(contents);

        // Should have multiple offset lines
        try expect(std.mem.indexOf(u8, contents, "00000000") != null);
        try expect(std.mem.indexOf(u8, contents, "00000010") != null);
        try expect(std.mem.indexOf(u8, contents, "00000020") != null);

        // Should contain parts of the original string
        try expect(std.mem.indexOf(u8, contents, "This is a test s") != null);
        try expect(std.mem.indexOf(u8, contents, "tring that is lo") != null);
    }
}

test "HexDumper - binary data with non-printable characters" {
    const test_file = "test_hexdump_binary.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
        defer dumper.deinit();

        // Test with binary data (all bytes 0x00-0x0F)
        const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
        try dumper.dump(&binary_data);
        try dumper.flush();
    }

    // Verify binary data hex dump format
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should have proper hex representation
        try expect(std.mem.indexOf(u8, contents, "00 01 02 03 04 05 06 07") != null);
        try expect(std.mem.indexOf(u8, contents, "08 09 0a 0b 0c 0d 0e 0f") != null);

        // Non-printable characters should be replaced with dots
        try expect(std.mem.indexOf(u8, contents, "|................|") != null);
    }
}

test "HexDumper - mixed printable and non-printable data" {
    const test_file = "test_hexdump_mixed.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    {
        var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
        defer dumper.deinit();

        // Mix of printable and non-printable characters
        const test_data = [_]u8{ 'H', 'e', 'l', 'l', 'o', 0x00, 0x01, 0x02, 'W', 'o', 'r', 'l', 'd', 0xFF, 0xFE, '!' };
        try dumper.dump(&test_data);
        try dumper.flush();
    }

    // Verify mixed data formatting
    {
        const file = try std.fs.cwd().openFile(test_file, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(contents);

        // Should show printable characters as-is and non-printable as dots
        try expect(std.mem.indexOf(u8, contents, "|Hello...World..!|") != null);
        try expect(std.mem.indexOf(u8, contents, "48 65 6c 6c 6f 00 01 02") != null); // "Hello" + null bytes
    }
}

test "HexDumper - flush operations without file" {
    var dumper = try HexDumper.initFromPath(testing.allocator, null);
    defer dumper.deinit();

    // Should not error when no file is configured
    try dumper.flush();
}

test "HexDumper - multiple dump operations with offset tracking" {
    var dumper = try HexDumper.initFromPath(testing.allocator, null);
    defer dumper.deinit();

    // First dump
    try dumper.dump("Hello");
    try expectEqual(@as(u64, 5), dumper.getOffset());

    // Second dump
    try dumper.dump(", World!");
    try expectEqual(@as(u64, 13), dumper.getOffset());

    // Third dump
    try dumper.dump(" Test");
    try expectEqual(@as(u64, 18), dumper.getOffset());

    // Reset and verify
    dumper.resetOffset();
    try expectEqual(@as(u64, 0), dumper.getOffset());
}

// =============================================================================
// INTEGRATION TESTS
// =============================================================================

test "Integration - CLI to Config to OutputLogger" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/integration_test.log", "--append", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // Verify CLI parsing
    try expectEqualStrings("/tmp/integration_test.log", cfg.output_file.?);
    try expect(cfg.append_output);

    // Test config validation
    try config.validateIOControl(&cfg);

    // Test OutputLogger initialization with parsed config
    const test_file = "integration_output.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var logger = try OutputLogger.init(testing.allocator, test_file, cfg.append_output);
    defer logger.deinit();

    try expect(logger.isAppendMode());
    try logger.write("Integration test data");
    try logger.flush();
}

test "Integration - CLI to Config to HexDumper" {
    var args = [_][:0]const u8{ "zigcat", "-x", "/tmp/integration_hex.dump", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // Verify CLI parsing
    try expect(cfg.hex_dump);
    try expectEqualStrings("/tmp/integration_hex.dump", cfg.hex_dump_file.?);

    // Test config validation
    try config.validateIOControl(&cfg);

    // Test HexDumper initialization with parsed config
    const test_file = "integration_hexdump.tmp";
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var dumper = try HexDumper.initFromPath(testing.allocator, test_file);
    defer dumper.deinit();

    try dumper.dump("Integration hex test");
    try dumper.flush();
}

test "Integration - conflicting flags end-to-end" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "--recv-only", "example.com", "80" };

    // Should fail at CLI parsing level
    try expectError(cli.CliError.ConflictingIOModes, cli.parseArgs(testing.allocator, &args));
}

test "Integration - complete I/O control workflow" {
    const test_output = "workflow_output.tmp";
    const test_hexdump = "workflow_hexdump.tmp";

    std.fs.cwd().deleteFile(test_output) catch {};
    std.fs.cwd().deleteFile(test_hexdump) catch {};
    defer std.fs.cwd().deleteFile(test_output) catch {};
    defer std.fs.cwd().deleteFile(test_hexdump) catch {};

    // Simulate complete workflow: CLI -> Config -> I/O operations
    var args = [_][:0]const u8{ "zigcat", "-o", test_output, "-x", test_hexdump, "--send-only", "example.com", "80" };

    const cfg = try cli.parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // Validate configuration
    try config.validateIOControl(&cfg);

    // Initialize I/O components
    var logger = try OutputLogger.init(testing.allocator, cfg.output_file, cfg.append_output);
    defer logger.deinit();

    var dumper = try HexDumper.initFromPath(testing.allocator, cfg.hex_dump_file);
    defer dumper.deinit();

    // Simulate data processing
    const test_data = "Test data for complete workflow";
    try logger.write(test_data);
    try dumper.dump(test_data);

    try logger.flush();
    try dumper.flush();

    // Verify both files were created and contain expected data
    {
        const output_file = try std.fs.cwd().openFile(test_output, .{});
        defer output_file.close();

        const output_contents = try output_file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(output_contents);

        try expectEqualStrings(test_data, output_contents);
    }

    {
        const hex_file = try std.fs.cwd().openFile(test_hexdump, .{});
        defer hex_file.close();

        const hex_contents = try hex_file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(hex_contents);

        try expect(hex_contents.len > 0);
        try expect(std.mem.indexOf(u8, hex_contents, "00000000") != null);
        try expect(std.mem.indexOf(u8, hex_contents, test_data) != null);
    }
}
