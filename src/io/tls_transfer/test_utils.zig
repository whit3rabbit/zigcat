// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Testing utilities for TLS transfer modules.

const std = @import("std");

const errors = @import("errors.zig");

pub const MockTlsConnection = struct {
    allocator: std.mem.Allocator,
    behavior: Behavior,
    read_data: std.ArrayList(u8),
    write_data: std.ArrayList(u8),
    read_position: usize,
    error_on_operation: ?ErrorTrigger,
    call_count: CallCount,
    state: ConnectionState,

    pub const Behavior = enum {
        normal,
        slow_read,
        slow_write,
        error_on_read,
        error_on_write,
        would_block_then_success,
        alert_received,
        invalid_state,
        handshake_incomplete,
        connection_closed,
    };

    pub const ErrorTrigger = struct {
        operation: enum { read, write, close, deinit },
        after_calls: u32,
        error_type: errors.TLSTransferError,
    };

    pub const CallCount = struct {
        read: u32 = 0,
        write: u32 = 0,
        close: u32 = 0,
        deinit: u32 = 0,
    };

    pub const ConnectionState = enum {
        connected,
        closed,
        error_state,
    };

    pub fn init(allocator: std.mem.Allocator, behavior: Behavior) !*MockTlsConnection {
        const mock = try allocator.create(MockTlsConnection);
        mock.* = .{
            .allocator = allocator,
            .behavior = behavior,
            .read_data = try std.ArrayList(u8).initCapacity(allocator, 0),
            .write_data = try std.ArrayList(u8).initCapacity(allocator, 0),
            .read_position = 0,
            .error_on_operation = null,
            .call_count = .{},
            .state = .connected,
        };
        return mock;
    }

    pub fn deinit(self: *MockTlsConnection) void {
        self.call_count.deinit += 1;

        if (self.error_on_operation) |trigger| {
            if (trigger.operation == .deinit and self.call_count.deinit >= trigger.after_calls) {
                self.state = .error_state;
                return;
            }
        }

        self.read_data.deinit(self.allocator);
        self.write_data.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setReadData(self: *MockTlsConnection, data: []const u8) !void {
        try self.read_data.appendSlice(self.allocator, data);
    }

    pub fn getWrittenData(self: *const MockTlsConnection) []const u8 {
        return self.write_data.items;
    }

    pub fn setErrorTrigger(self: *MockTlsConnection, trigger: ErrorTrigger) void {
        self.error_on_operation = trigger;
    }

    pub fn read(self: *MockTlsConnection, buffer: []u8) !usize {
        self.call_count.read += 1;

        if (self.error_on_operation) |trigger| {
            if (trigger.operation == .read and self.call_count.read >= trigger.after_calls) {
                self.state = .error_state;
                return mapTlsTransferErrorToTlsError(trigger.error_type);
            }
        }

        if (self.state != .connected) {
            return error.InvalidState;
        }

        return switch (self.behavior) {
            .normal => self.normalRead(buffer),
            .slow_read => blk: {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                break :blk self.normalRead(buffer);
            },
            .error_on_read => error.AlertReceived,
            .would_block_then_success => if (self.call_count.read == 1)
                error.WouldBlock
            else
                self.normalRead(buffer),
            .alert_received => error.AlertReceived,
            .invalid_state => error.InvalidState,
            .handshake_incomplete => error.HandshakeFailed,
            .connection_closed => {
                self.state = .closed;
                return 0;
            },
            .slow_write, .error_on_write => self.normalRead(buffer),
        };
    }

    fn normalRead(self: *MockTlsConnection, buffer: []u8) !usize {
        if (self.read_position >= self.read_data.items.len) {
            return 0;
        }

        const available = self.read_data.items.len - self.read_position;
        const to_read = @min(buffer.len, available);

        @memcpy(buffer[0..to_read], self.read_data.items[self.read_position .. self.read_position + to_read]);
        self.read_position += to_read;

        return to_read;
    }

    pub fn write(self: *MockTlsConnection, data: []const u8) !usize {
        self.call_count.write += 1;

        if (self.error_on_operation) |trigger| {
            if (trigger.operation == .write and self.call_count.write >= trigger.after_calls) {
                self.state = .error_state;
                return mapTlsTransferErrorToTlsError(trigger.error_type);
            }
        }

        if (self.state != .connected) {
            return error.InvalidState;
        }

        switch (self.behavior) {
            .normal => {
                try self.write_data.appendSlice(self.allocator, data);
                return data.len;
            },
            .slow_write => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                try self.write_data.appendSlice(self.allocator, data);
                return data.len;
            },
            .error_on_write => return error.AlertReceived,
            .would_block_then_success => {
                if (self.call_count.write == 1) {
                    return error.WouldBlock;
                } else {
                    try self.write_data.appendSlice(self.allocator, data);
                    return data.len;
                }
            },
            .alert_received => return error.AlertReceived,
            .invalid_state => return error.InvalidState,
            .handshake_incomplete => return error.HandshakeFailed,
            else => {
                try self.write_data.appendSlice(self.allocator, data);
                return data.len;
            },
        }
    }

    pub fn close(self: *MockTlsConnection) void {
        self.call_count.close += 1;

        if (self.error_on_operation) |trigger| {
            if (trigger.operation == .close and self.call_count.close >= trigger.after_calls) {
                self.state = .error_state;
                return;
            }
        }

        self.state = .closed;
    }

    fn mapTlsTransferErrorToTlsError(tls_err: errors.TLSTransferError) anyerror {
        return switch (tls_err) {
            errors.TLSTransferError.AlertReceived => error.AlertReceived,
            errors.TLSTransferError.InvalidState => error.InvalidState,
            errors.TLSTransferError.HandshakeFailed => error.HandshakeFailed,
            errors.TLSTransferError.CertificateVerificationFailed => error.CertificateVerificationFailed,
            errors.TLSTransferError.BufferTooSmall => error.BufferTooSmall,
            errors.TLSTransferError.TlsNotEnabled => error.TlsNotEnabled,
            errors.TLSTransferError.WouldBlock => error.WouldBlock,
            errors.TLSTransferError.ConnectionClosed => error.BrokenPipe,
            errors.TLSTransferError.ConnectionReset => error.ConnectionResetByPeer,
            errors.TLSTransferError.NetworkTimeout => error.Timeout,
            errors.TLSTransferError.OutOfMemory => error.OutOfMemory,
            else => error.SystemError,
        };
    }
};

/// Wrapper to make MockTlsConnection compatible with the TlsConnection interface.
pub const MockTlsConnectionWrapper = struct {
    mock: *MockTlsConnection,

    pub fn read(self: *MockTlsConnectionWrapper, buffer: []u8) !usize {
        return self.mock.read(buffer);
    }

    pub fn write(self: *MockTlsConnectionWrapper, data: []const u8) !usize {
        return self.mock.write(data);
    }

    pub fn close(self: *MockTlsConnectionWrapper) void {
        self.mock.close();
    }

    pub fn deinit(self: *MockTlsConnectionWrapper) void {
        self.mock.deinit();
    }
};
