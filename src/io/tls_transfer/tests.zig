// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Consolidated tests for TLS transfer modules.

const std = @import("std");
const testing = std.testing;

const config = @import("../../config.zig");
const tls = @import("../../tls/tls.zig");
const output = @import("../output.zig");
const hexdump = @import("../hexdump.zig");

const transfer = @import("transfer.zig");
const errors = @import("errors.zig");
const test_utils = @import("test_utils.zig");

test "TLS transfer buffer size is non-zero" {
    try testing.expect(transfer.BUFFER_SIZE > 0);
}

test "tlsBidirectionalTransfer handles disabled TLS gracefully" {
    const allocator = testing.allocator;

    var tls_conn = tls.TlsConnection{
        .allocator = allocator,
        .backend = .{ .disabled = {} },
    };

    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);

    const read_result = tls_conn.read(&[_]u8{});
    try testing.expectError(error.TlsNotEnabled, read_result);

    const write_result = tls_conn.write(&[_]u8{});
    try testing.expectError(error.TlsNotEnabled, write_result);
}

test "TLS transfer - basic mock connection functionality" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .normal);
    defer mock.deinit();

    const test_input = "Hello, TLS World!";
    try mock.setReadData(test_input);

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var read_buffer: [1024]u8 = undefined;
    const bytes_read = try wrapper.read(&read_buffer);
    try testing.expectEqual(test_input.len, bytes_read);
    try testing.expectEqualStrings(test_input, read_buffer[0..bytes_read]);

    const test_output = "Response from client";
    const bytes_written = try wrapper.write(test_output);
    try testing.expectEqual(test_output.len, bytes_written);
    try testing.expectEqualStrings(test_output, mock.getWrittenData());
}

test "TLS transfer - AlertReceived error handling" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .alert_received);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var buffer: [1024]u8 = undefined;
    const result = wrapper.read(&buffer);
    try testing.expectError(error.AlertReceived, result);

    const tls_err = errors.mapTlsError(error.AlertReceived);
    try testing.expectEqual(errors.TLSTransferError.AlertReceived, tls_err);
    try testing.expect(!errors.isTlsErrorRecoverable(tls_err));
}

test "TLS transfer - InvalidState error handling" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .invalid_state);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    const test_data = "test data";
    const result = wrapper.write(test_data);
    try testing.expectError(error.InvalidState, result);

    const tls_err = errors.mapTlsError(error.InvalidState);
    try testing.expectEqual(errors.TLSTransferError.InvalidState, tls_err);
    try testing.expect(!errors.isTlsErrorRecoverable(tls_err));
}

test "TLS transfer - WouldBlock error recovery" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .would_block_then_success);
    defer mock.deinit();

    const test_data = "Success after WouldBlock";
    try mock.setReadData(test_data);

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var buffer: [1024]u8 = undefined;
    const first_result = wrapper.read(&buffer);
    try testing.expectError(error.WouldBlock, first_result);

    const would_block_err = errors.mapTlsError(error.WouldBlock);
    try testing.expect(errors.isTlsErrorRecoverable(would_block_err));

    const second_result = try wrapper.read(&buffer);
    try testing.expectEqual(test_data.len, second_result);
    try testing.expectEqualStrings(test_data, buffer[0..second_result]);
}

test "TLS transfer - HandshakeFailed error handling" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .handshake_incomplete);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var buffer: [1024]u8 = undefined;
    const result = wrapper.read(&buffer);
    try testing.expectError(error.HandshakeFailed, result);

    const tls_err = errors.mapTlsError(error.HandshakeFailed);
    try testing.expectEqual(errors.TLSTransferError.HandshakeFailed, tls_err);
    try testing.expect(!errors.isTlsErrorRecoverable(tls_err));
}

test "TLS transfer - connection closed detection" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .connection_closed);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var buffer: [1024]u8 = undefined;
    const bytes_read = try wrapper.read(&buffer);
    try testing.expectEqual(@as(usize, 0), bytes_read);
}

test "TLS transfer - I/O control mode validation" {
    const allocator = testing.allocator;

    {
        var cfg = config.Config.init(allocator);
        defer cfg.deinit(allocator);
        cfg.send_only = true;
        cfg.recv_only = false;
        try config.validateIOControl(&cfg);
        try testing.expect(cfg.send_only);
        try testing.expect(!cfg.recv_only);
    }

    {
        var cfg = config.Config.init(allocator);
        defer cfg.deinit(allocator);
        cfg.send_only = false;
        cfg.recv_only = true;
        try config.validateIOControl(&cfg);
        try testing.expect(!cfg.send_only);
        try testing.expect(cfg.recv_only);
    }

    {
        var cfg = config.Config.init(allocator);
        defer cfg.deinit(allocator);
        cfg.send_only = true;
        cfg.recv_only = true;
        try testing.expectError(config.IOControlError.ConflictingIOModes, config.validateIOControl(&cfg));
    }
}

test "TLS transfer - timeout configuration and cleanup" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .normal);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var cfg = config.Config.init(allocator);
    defer cfg.deinit(allocator);
    cfg.idle_timeout = 5000;

    try testing.expectEqual(@as(u32, 5000), cfg.idle_timeout);

    wrapper.close();
    try testing.expectEqual(@as(u32, 1), mock.call_count.close);
    try testing.expectEqual(test_utils.MockTlsConnection.ConnectionState.closed, mock.state);
}

test "TLS transfer - comprehensive error recoverability" {
    const recoverable = [_]errors.TLSTransferError{
        errors.TLSTransferError.WouldBlock,
        errors.TLSTransferError.BufferTooSmall,
        errors.TLSTransferError.NetworkTimeout,
    };

    const fatal = [_]errors.TLSTransferError{
        errors.TLSTransferError.AlertReceived,
        errors.TLSTransferError.InvalidState,
        errors.TLSTransferError.HandshakeFailed,
        errors.TLSTransferError.CertificateVerificationFailed,
        errors.TLSTransferError.ConnectionClosed,
        errors.TLSTransferError.ConnectionReset,
        errors.TLSTransferError.TlsNotEnabled,
    };

    for (recoverable) |err| {
        try testing.expect(errors.isTlsErrorRecoverable(err));
    }

    for (fatal) |err| {
        try testing.expect(!errors.isTlsErrorRecoverable(err));
    }
}

test "TLS transfer - error message generation coverage" {
    const cases = [_]struct {
        err: errors.TLSTransferError,
        tokens: []const []const u8,
    }{
        .{ .err = errors.TLSTransferError.AlertReceived, .tokens = &[_][]const u8{ "alert", "received" } },
        .{ .err = errors.TLSTransferError.InvalidState, .tokens = &[_][]const u8{ "invalid", "state" } },
        .{ .err = errors.TLSTransferError.HandshakeFailed, .tokens = &[_][]const u8{ "handshake", "failed" } },
        .{ .err = errors.TLSTransferError.CertificateVerificationFailed, .tokens = &[_][]const u8{ "certificate", "verification" } },
        .{ .err = errors.TLSTransferError.WouldBlock, .tokens = &[_][]const u8{ "would", "block" } },
        .{ .err = errors.TLSTransferError.TlsNotEnabled, .tokens = &[_][]const u8{ "not", "enabled" } },
    };

    for (cases) |case_info| {
        const msg = errors.getTlsErrorMessage(case_info.err, "test");
        try testing.expect(msg.len > 0);

        for (case_info.tokens) |token| {
            var found = false;
            var i: usize = 0;
            while (i <= msg.len - token.len) : (i += 1) {
                if (std.ascii.eqlIgnoreCase(msg[i .. i + token.len], token)) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }
}

test "TLS transfer - large data handling simulation" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .normal);
    defer mock.deinit();

    const test_size = 1024;
    const test_data = try allocator.alloc(u8, test_size);
    defer allocator.free(test_data);

    for (test_data, 0..) |*byte, i| {
        byte.* = @truncate(i & 0xFF);
    }

    try mock.setReadData(test_data);

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    var total_read: usize = 0;
    var buffer: [256]u8 = undefined;

    while (total_read < test_size) {
        const bytes_read = try wrapper.read(&buffer);
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read], 0..) |byte, i| {
            const expected = @as(u8, @truncate((total_read + i) & 0xFF));
            try testing.expectEqual(expected, byte);
        }

        total_read += bytes_read;
    }

    try testing.expectEqual(test_size, total_read);
}

test "TLS transfer - connection state transitions" {
    const allocator = testing.allocator;

    var mock = try test_utils.MockTlsConnection.init(allocator, .normal);
    defer mock.deinit();

    var wrapper = test_utils.MockTlsConnectionWrapper{ .mock = mock };

    try testing.expectEqual(test_utils.MockTlsConnection.ConnectionState.connected, mock.state);

    const test_data = "state test";
    _ = try wrapper.write(test_data);
    try testing.expectEqual(test_utils.MockTlsConnection.ConnectionState.connected, mock.state);

    wrapper.close();
    try testing.expectEqual(test_utils.MockTlsConnection.ConnectionState.closed, mock.state);

    const result = wrapper.write("should fail");
    try testing.expectError(error.InvalidState, result);
}

test "TLS transfer - output integration with mock files" {
    const allocator = testing.allocator;

    const output_file = "test_tls_output.tmp";
    std.fs.cwd().deleteFile(output_file) catch {};
    defer std.fs.cwd().deleteFile(output_file) catch {};

    var output_logger = try output.OutputLogger.init(allocator, output_file, false);
    defer output_logger.deinit();

    const test_data = "TLS transfer test data";
    try output_logger.write(test_data);
    try output_logger.flush();

    const file = try std.fs.cwd().openFile(output_file, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);

    try testing.expectEqualStrings(test_data, contents);
}

test "TLS transfer - hex dump integration" {
    const allocator = testing.allocator;

    const hex_file = "test_tls_hexdump.tmp";
    std.fs.cwd().deleteFile(hex_file) catch {};
    defer std.fs.cwd().deleteFile(hex_file) catch {};

    var hex_dumper = try hexdump.HexDumper.initFromPath(allocator, hex_file);
    defer hex_dumper.deinit();

    const test_data = "TLS hex dump test";
    try hex_dumper.dump(test_data);
    try hex_dumper.flush();

    const file = try std.fs.cwd().openFile(hex_file, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 2048);
    defer allocator.free(contents);

    try testing.expect(contents.len > 0);
    try testing.expect(std.mem.indexOf(u8, contents, "00000000") != null);
    try testing.expect(std.mem.indexOf(u8, contents, test_data) != null);
}
