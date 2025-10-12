// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Command-line interface module for zigcat.
//!
//! This module re-exports functions from specialized CLI submodules:
//! - cli/parser.zig: Argument parsing logic
//! - cli/help.zig: Help and version display
//!
//! Maintains backward compatibility by re-exporting all public functions
//! at the top level.

const std = @import("std");
const config = @import("config.zig");

// Re-export parser functions
const parser = @import("cli/parser.zig");
pub const CliError = parser.CliError;
pub const parseArgs = parser.parseArgs;

// Re-export help functions
const help = @import("cli/help.zig");
pub const printHelp = help.printHelp;
pub const printVersion = help.printVersion;
pub const printVersionAll = help.printVersionAll;

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;

// =============================================================================
// I/O CONTROL CLI TESTS
// =============================================================================

test "CLI parser - send-only flag" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.send_only);
    try testing.expect(!cfg.recv_only);
}

test "CLI parser - recv-only flag" {
    var args = [_][:0]const u8{ "zigcat", "--recv-only", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.recv_only);
    try testing.expect(!cfg.send_only);
}

test "CLI parser - conflicting I/O flags" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "--recv-only", "example.com", "80" };

    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.ConflictingIOModes, err);
    }
}

test "CLI parser - output file short flag" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/output.log", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/output.log", cfg.output_file.?);
    try testing.expect(!cfg.append_output);
}

test "CLI parser - output file long flag" {
    var args = [_][:0]const u8{ "zigcat", "--output", "/tmp/output.log", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "CLI parser - append flag with output" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/output.log", "--append", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.append_output);
    try testing.expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "CLI parser - hex-dump flag without file" {
    var args = [_][:0]const u8{ "zigcat", "-x", "-v", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.hex_dump);
    try testing.expect(cfg.hex_dump_file == null);
}

test "CLI parser - hex-dump flag with file" {
    var args = [_][:0]const u8{ "zigcat", "-x", "/tmp/dump.hex", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.hex_dump);
    try testing.expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "CLI parser - hex-dump long flag with file" {
    var args = [_][:0]const u8{ "zigcat", "--hex-dump", "/tmp/dump.hex", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.hex_dump);
    try testing.expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "CLI parser - invalid output file paths" {
    // Empty output file path
    var args1 = [_][:0]const u8{ "zigcat", "-o", "", "example.com", "80" };
    if (parseArgs(testing.allocator, &args1)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.InvalidOutputPath, err);
    }

    // Empty hex dump file path
    var args2 = [_][:0]const u8{ "zigcat", "-x", "", "example.com", "80" };
    if (parseArgs(testing.allocator, &args2)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.InvalidOutputPath, err);
    }

    // Null bytes in output path
    var args3 = [_][:0]const u8{ "zigcat", "-o", "/tmp/out\x00put.log", "example.com", "80" };
    if (parseArgs(testing.allocator, &args3)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.InvalidOutputPath, err);
    }

    // Null bytes in hex dump path
    var args4 = [_][:0]const u8{ "zigcat", "-x", "/tmp/hex\x00dump.log", "example.com", "80" };
    if (parseArgs(testing.allocator, &args4)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.InvalidOutputPath, err);
    }
}

test "CLI parser - missing values for I/O flags" {
    // Missing output file
    var args1 = [_][:0]const u8{ "zigcat", "-o" };
    try testing.expectError(CliError.MissingValue, parseArgs(testing.allocator, &args1));

    // Missing exec command
    var args2 = [_][:0]const u8{ "zigcat", "-e" };
    try testing.expectError(CliError.MissingValue, parseArgs(testing.allocator, &args2));

    // Missing shell command
    var args3 = [_][:0]const u8{ "zigcat", "-c" };
    try testing.expectError(CliError.MissingValue, parseArgs(testing.allocator, &args3));
}

// Integration test - CLI to Config validation
test "CLI integration - conflicting flags end-to-end" {
    var args = [_][:0]const u8{ "zigcat", "--send-only", "--recv-only", "example.com", "80" };

    // Should fail at CLI parsing level
    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.ConflictingIOModes, err);
    }
}

test "CLI integration - complete I/O control parsing" {
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/test.log", "-x", "/tmp/test.hex", "--send-only", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // Verify all flags were parsed correctly
    try testing.expectEqualStrings("/tmp/test.log", cfg.output_file.?);
    try testing.expect(cfg.hex_dump);
    try testing.expectEqualStrings("/tmp/test.hex", cfg.hex_dump_file.?);
    try testing.expect(cfg.send_only);
    try testing.expect(!cfg.recv_only);

    // Validate configuration
    try config.validateIOControl(&cfg);
}

// =============================================================================
// BROKER/CHAT MODE CLI TESTS
// =============================================================================

test "CLI parser - broker mode flag" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--broker", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.broker_mode);
    try testing.expect(!cfg.chat_mode);
    try testing.expect(cfg.listen_mode);
}

test "CLI parser - chat mode flag" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--chat", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.chat_mode);
    try testing.expect(!cfg.broker_mode);
    try testing.expect(cfg.listen_mode);
}

test "CLI parser - conflicting broker and chat flags" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--broker", "--chat", "8080" };

    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here
    } else |err| {
        try testing.expectEqual(CliError.ConflictingIOModes, err);
    }
}

test "CLI parser - max-clients flag" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--broker", "--max-clients", "100", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.broker_mode);
    try testing.expectEqual(@as(u32, 100), cfg.max_clients);
}

test "CLI parser - max-clients with chat mode" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--chat", "--max-clients", "25", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.chat_mode);
    try testing.expectEqual(@as(u32, 25), cfg.max_clients);
}

test "CLI parser - missing max-clients value" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--broker", "--max-clients" };

    try testing.expectError(CliError.MissingValue, parseArgs(testing.allocator, &args));
}

test "CLI parser - broker mode default values" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--broker", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.broker_mode);
    try testing.expectEqual(@as(u32, 50), cfg.max_clients); // Default value
    try testing.expectEqual(@as(usize, 32), cfg.chat_max_nickname_len); // Default value
    try testing.expectEqual(@as(usize, 1024), cfg.chat_max_message_len); // Default value
}

test "CLI parser - chat mode default values" {
    var args = [_][:0]const u8{ "zigcat", "-l", "--chat", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.chat_mode);
    try testing.expectEqual(@as(u32, 50), cfg.max_clients); // Default value
    try testing.expectEqual(@as(usize, 32), cfg.chat_max_nickname_len); // Default value
    try testing.expectEqual(@as(usize, 1024), cfg.chat_max_message_len); // Default value
}

test "CLI integration - broker mode with other flags" {
    var args = [_][:0]const u8{ "zigcat", "-l", "-v", "--broker", "--max-clients", "75", "-k", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.listen_mode);
    try testing.expect(cfg.verbose);
    try testing.expect(cfg.broker_mode);
    try testing.expect(cfg.keep_listening);
    try testing.expectEqual(@as(u32, 75), cfg.max_clients);
}

test "CLI integration - chat mode with other flags" {
    var args = [_][:0]const u8{ "zigcat", "-l", "-v", "--chat", "--max-clients", "30", "--ssl", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.listen_mode);
    try testing.expect(cfg.verbose);
    try testing.expect(cfg.chat_mode);
    try testing.expect(cfg.ssl);
    try testing.expectEqual(@as(u32, 30), cfg.max_clients);
}

// =============================================================================
// UNIX SOCKET CLI TESTS
// =============================================================================

test "CLI parser - Unix socket short flag" {
    var args = [_][:0]const u8{ "zigcat", "-U", "/tmp/test.sock" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/test.sock", cfg.unix_socket_path.?);
}

test "CLI parser - Unix socket long flag" {
    var args = [_][:0]const u8{ "zigcat", "--unixsock", "/tmp/test.sock" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/test.sock", cfg.unix_socket_path.?);
}

test "CLI parser - Unix socket with listen mode" {
    var args = [_][:0]const u8{ "zigcat", "-l", "-U", "/tmp/server.sock" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.listen_mode);
    try testing.expectEqualStrings("/tmp/server.sock", cfg.unix_socket_path.?);
}

test "CLI parser - missing Unix socket path" {
    var args = [_][:0]const u8{ "zigcat", "-U" };

    try testing.expectError(CliError.MissingValue, parseArgs(testing.allocator, &args));
}

test "CLI parser - Unix socket conflicts with host/port" {
    var args = [_][:0]const u8{ "zigcat", "-U", "/tmp/test.sock", "example.com", "80" };

    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here on Unix platforms
    } else |err| {
        // On Unix platforms, this should fail with conflicting modes
        // On non-Unix platforms, it should fail with unsupported feature
        try testing.expect(err == CliError.ConflictingIOModes or err == CliError.UnknownOption);
    }
}

test "CLI parser - Unix socket conflicts with UDP" {
    var args = [_][:0]const u8{ "zigcat", "-U", "/tmp/test.sock", "-u" };

    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here on Unix platforms
    } else |err| {
        // On Unix platforms, this should fail with conflicting modes
        // On non-Unix platforms, it should fail with unsupported feature
        try testing.expect(err == CliError.ConflictingIOModes or err == CliError.UnknownOption);
    }
}

test "CLI parser - Unix socket conflicts with TLS" {
    var args = [_][:0]const u8{ "zigcat", "-U", "/tmp/test.sock", "--ssl" };

    if (parseArgs(testing.allocator, &args)) |_| {
        try testing.expect(false); // Should not reach here on Unix platforms
    } else |err| {
        // On Unix platforms, this should fail with conflicting modes
        // On non-Unix platforms, it should fail with unsupported feature
        try testing.expect(err == CliError.ConflictingIOModes or err == CliError.UnknownOption);
    }
}

// =============================================================================
// MULTI-LEVEL VERBOSITY CLI TESTS
// =============================================================================

test "CLI parser - single -v flag (verbose level)" {
    var args = [_][:0]const u8{ "zigcat", "-v", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.verbose, cfg.verbosity);
    try testing.expect(cfg.verbose); // Backward compatibility
}

test "CLI parser - double -v flag (debug level)" {
    var args = [_][:0]const u8{ "zigcat", "-v", "-v", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.debug, cfg.verbosity);
}

test "CLI parser - triple -v flag (trace level)" {
    var args = [_][:0]const u8{ "zigcat", "-v", "-v", "-v", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.trace, cfg.verbosity);
}

test "CLI parser - four -v flags (still trace level)" {
    var args = [_][:0]const u8{ "zigcat", "-v", "-v", "-v", "-v", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // Should cap at trace level
    try testing.expectEqual(config.VerbosityLevel.trace, cfg.verbosity);
}

test "CLI parser - quiet flag short form" {
    var args = [_][:0]const u8{ "zigcat", "-q", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.quiet, cfg.verbosity);
}

test "CLI parser - quiet flag long form" {
    var args = [_][:0]const u8{ "zigcat", "--quiet", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.quiet, cfg.verbosity);
}

test "CLI parser - default verbosity level" {
    var args = [_][:0]const u8{ "zigcat", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.normal, cfg.verbosity);
    try testing.expect(!cfg.verbose); // Backward compatibility
}

test "CLI parser - quiet overrides verbose flags" {
    // -q should override any -v flags
    var args = [_][:0]const u8{ "zigcat", "-v", "-v", "-q", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    // -q is processed after -v flags, so it stays quiet
    try testing.expectEqual(config.VerbosityLevel.quiet, cfg.verbosity);
}

test "CLI parser - verbose with long flag" {
    var args = [_][:0]const u8{ "zigcat", "--verbose", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.verbose, cfg.verbosity);
}

test "CLI parser - mixed short and long verbose flags" {
    var args = [_][:0]const u8{ "zigcat", "-v", "--verbose", "example.com", "80" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(config.VerbosityLevel.debug, cfg.verbosity);
}

test "CLI parser - verbosity with other flags" {
    var args = [_][:0]const u8{ "zigcat", "-l", "-v", "-v", "-k", "8080" };

    var cfg = try parseArgs(testing.allocator, &args);
    defer cfg.deinit(testing.allocator);

    try testing.expect(cfg.listen_mode);
    try testing.expect(cfg.keep_listening);
    try testing.expectEqual(config.VerbosityLevel.debug, cfg.verbosity);
}
