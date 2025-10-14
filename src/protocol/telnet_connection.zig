// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! This file implements the `TelnetConnection` struct, which acts as a high-level
//! wrapper around a raw network connection (`Connection`). Its primary role is to
//! provide a standard `read()` and `write()` interface that transparently handles
// a Telnet session. It uses `TelnetProcessor` to handle the underlying state
//! machine, but this struct manages the I/O buffers and orchestrates the
//! interaction between application data and Telnet commands.

const std = @import("std");
const Connection = @import("../net/connection.zig").Connection;
const TelnetProcessor = @import("telnet_processor.zig").TelnetProcessor;
const telnet = @import("telnet.zig");
const tty_state = @import("terminal").tty_state;

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;
const TelnetError = telnet.TelnetError;

/// Wraps an existing Connection with Telnet protocol processing.
pub const TelnetConnection = struct {
    inner: Connection,
    processor: TelnetProcessor,
    read_buffer: std.ArrayList(u8),
    write_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pending_data: std.ArrayList(u8),
    pending_response: std.ArrayList(u8),

    const BUFFER_SIZE = 4096;

    /// Initialize TelnetConnection from an existing Connection.
    /// Takes ownership of the connection.
    pub fn init(
        connection: Connection,
        allocator: std.mem.Allocator,
        terminal_type: ?[]const u8,
        window_width: ?u16,
        window_height: ?u16,
        local_tty: ?*tty_state.TtyState,
    ) !TelnetConnection {
        const term_type = terminal_type orelse "UNKNOWN";
        const width = window_width orelse 80;
        const height = window_height orelse 24;

        return TelnetConnection{
            .inner = connection,
            .processor = TelnetProcessor.init(allocator, term_type, width, height, local_tty),
            .read_buffer = try std.ArrayList(u8).initCapacity(allocator, BUFFER_SIZE),
            .write_buffer = try std.ArrayList(u8).initCapacity(allocator, BUFFER_SIZE),
            .allocator = allocator,
            .pending_data = try std.ArrayList(u8).initCapacity(allocator, BUFFER_SIZE),
            .pending_response = try std.ArrayList(u8).initCapacity(allocator, BUFFER_SIZE),
        };
    }

    /// Clean up resources and close the underlying connection.
    pub fn deinit(self: *TelnetConnection) void {
        self.processor.deinit();
        self.read_buffer.deinit(self.allocator);
        self.write_buffer.deinit(self.allocator);
        self.pending_data.deinit(self.allocator);
        self.pending_response.deinit(self.allocator);
        self.inner.close();
    }

    /// Read application data, filtering out Telnet protocol sequences.
    /// Returns number of bytes read (0 indicates EOF).
    pub fn read(self: *TelnetConnection, buffer: []u8) !usize {
        // Return pending application data first
        if (self.pending_data.items.len > 0) {
            const bytes_to_copy = @min(buffer.len, self.pending_data.items.len);
            @memcpy(buffer[0..bytes_to_copy], self.pending_data.items[0..bytes_to_copy]);

            const remaining = self.pending_data.items[bytes_to_copy..];
            std.mem.copyForwards(u8, self.pending_data.items, remaining);
            self.pending_data.shrinkRetainingCapacity(remaining.len);

            return bytes_to_copy;
        }

        try self.flushPendingResponses();

        self.read_buffer.clearRetainingCapacity();
        try self.read_buffer.resize(self.allocator, BUFFER_SIZE);

        const bytes_read = try self.inner.read(self.read_buffer.items);
        if (bytes_read == 0) {
            return 0;
        }

        self.read_buffer.shrinkRetainingCapacity(bytes_read);

        const result = try self.processor.processInput(self.read_buffer.items);
        defer {
            self.allocator.free(result.data);
            self.allocator.free(result.response);
        }

        if (result.response.len > 0) {
            try self.pending_response.appendSlice(self.allocator, result.response);
        }

        if (result.data.len == 0) {
            // No application data - recursively read more
            return self.read(buffer);
        }
        const bytes_to_return = @min(buffer.len, result.data.len);
        @memcpy(buffer[0..bytes_to_return], result.data[0..bytes_to_return]);

        if (result.data.len > bytes_to_return) {
            try self.pending_data.appendSlice(self.allocator, result.data[bytes_to_return..]);
        }

        return bytes_to_return;
    }

    /// Write application data, escaping IAC bytes as needed.
    /// Returns number of application bytes written.
    pub fn write(self: *TelnetConnection, data: []const u8) !usize {
        try self.flushPendingResponses();

        const processed_data = try self.processor.processOutput(data, null);
        defer self.allocator.free(processed_data);

        const bytes_written = try self.inner.write(processed_data);

        // Calculate application bytes written (approximate due to IAC escaping)
        if (processed_data.len == 0) {
            return 0;
        }

        const app_bytes_written = (data.len * bytes_written) / processed_data.len;
        return @min(app_bytes_written, data.len);
    }

    /// Close the connection and release resources.
    pub fn close(self: *TelnetConnection) void {
        self.flushPendingResponses() catch {};
        self.inner.close();
    }

    /// Get underlying socket descriptor for poll() or setsockopt().
    /// WARNING: Do not read/write directly - use TelnetConnection methods.
    pub fn getSocket(self: *TelnetConnection) @import("../net/socket.zig").Socket {
        return self.inner.getSocket();
    }

    /// Returns true if connection uses TLS encryption.
    pub fn isTls(self: *const TelnetConnection) bool {
        return self.inner.isTls();
    }

    /// Returns true if connection uses Unix domain sockets.
    pub fn isUnixSocket(self: *const TelnetConnection) bool {
        return self.inner.isUnixSocket();
    }

    /// Send a Telnet command to the remote peer.
    /// For negotiation commands (WILL/WONT/DO/DONT), option parameter is required.
    pub fn sendCommand(self: *TelnetConnection, command: TelnetCommand, option: ?TelnetOption) !void {
        const cmd_data = try self.processor.createCommand(command, option);
        defer self.allocator.free(cmd_data);

        _ = try self.inner.write(cmd_data);
    }

    /// Initiate option negotiation with the remote peer.
    pub fn negotiateOption(self: *TelnetConnection, option: TelnetOption, enable: bool) !void {
        const command: TelnetCommand = if (enable) .will else .wont;
        try self.sendCommand(command, option);
    }

    /// Get current negotiation state of a Telnet option.
    pub fn getOptionState(self: *const TelnetConnection, option: TelnetOption) @import("telnet_processor.zig").OptionState {
        return self.processor.getOptionState(option);
    }

    /// Update terminal window size and send NAWS negotiation if enabled.
    pub fn updateWindowSize(self: *TelnetConnection, width: u16, height: u16) !bool {
        const response_data = try self.processor.updateWindowSize(width, height);
        defer self.allocator.free(response_data);

        if (response_data.len > 0) {
            _ = try self.inner.write(response_data);
            return true;
        }

        return false;
    }

    /// Perform initial Telnet negotiation for client mode.
    /// Client requests server capabilities and offers its own.
    /// Typically called after connection establishment in client mode.
    pub fn performInitialNegotiation(self: *TelnetConnection) !void {
        try self.sendCommand(.do, .suppress_ga); // Request server suppress go-ahead
        try self.sendCommand(.will, .terminal_type); // Offer to provide terminal type
        try self.sendCommand(.will, .naws); // Offer to provide window size
    }

    /// Perform initial Telnet negotiation for server mode.
    /// Server offers capabilities and requests client information.
    /// Typically called after accepting connection in server mode.
    ///
    /// Server-side negotiation differs from client:
    /// - Server announces WILL ECHO (server will echo client input)
    /// - Server announces WILL SUPPRESS_GA (server suppresses go-ahead)
    /// - Server requests DO TERMINAL_TYPE (asks client for terminal type)
    /// - Server requests DO NAWS (asks client for window size)
    pub fn performServerNegotiation(self: *TelnetConnection) !void {
        try self.sendCommand(.will, .echo); // Announce server will echo
        try self.sendCommand(.will, .suppress_ga); // Announce server suppresses go-ahead
        try self.sendCommand(.do, .terminal_type); // Request client terminal type
        try self.sendCommand(.do, .naws); // Request client window size
    }

    /// Reset Telnet negotiation state to initial conditions.
    pub fn resetNegotiation(self: *TelnetConnection) void {
        self.processor.resetNegotiation();
        self.pending_data.clearRetainingCapacity();
        self.pending_response.clearRetainingCapacity();
    }

    /// Flush pending Telnet responses to the remote peer.
    fn flushPendingResponses(self: *TelnetConnection) !void {
        if (self.pending_response.items.len > 0) {
            _ = try self.inner.write(self.pending_response.items);
            self.pending_response.clearRetainingCapacity();
        }
    }
};

/// Create TelnetConnection with default settings.
pub fn fromConnection(connection: Connection, allocator: std.mem.Allocator) !TelnetConnection {
    return TelnetConnection.init(connection, allocator, null, null, null, null);
}

/// Create TelnetConnection with custom terminal configuration.
pub fn fromConnectionWithConfig(
    connection: Connection,
    allocator: std.mem.Allocator,
    terminal_type: []const u8,
    window_width: u16,
    window_height: u16,
) !TelnetConnection {
    return TelnetConnection.init(connection, allocator, terminal_type, window_width, window_height, null);
}
