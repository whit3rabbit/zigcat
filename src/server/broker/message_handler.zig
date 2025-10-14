// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


const std = @import("std");
const broker = @import("../broker.zig");
const ClientPool = @import("client_manager.zig").ClientPool;
const logging = @import("../../util/logging.zig");

/// Sanitizes a byte slice, replacing invalid UTF-8 sequences with the
/// Unicode replacement character (U+FFFD). If the input is already valid UTF-8,
/// it returns a copy. Otherwise, it iterates through the input and reconstructs
/// a valid UTF-8 string.
///
/// Parameters:
///   - allocator: The memory allocator to use for the sanitized string.
///   - input: The byte slice to sanitize.
///
/// Returns:
///   A new, allocated byte slice containing the sanitized, valid UTF-8 string.
///   Returns an error if memory allocation fails.
fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(input)) {
        return allocator.dupe(u8, input); // It's valid, just copy it
    }

    var sanitized_list = std.ArrayList(u8).init(allocator);
    errdefer sanitized_list.deinit();

    var it = std.unicode.Utf8Iterator.init(input);
    while (it.next()) |codepoint| {
        try sanitized_list.writer().writeCodepoint(codepoint);
    }

    return sanitized_list.toOwnedSlice();
}

/// Handle incoming data from a client connection
/// SECURITY FIX (2025-10-10): Changed client_id from u32 to u64 to match ClientPool
pub fn handleClientData(
    self: *broker.BrokerServer,
    client_id: u64,
    scratch: std.mem.Allocator,
) !void {
    const client = self.clients.getClient(client_id) orelse return broker.BrokerError.ClientNotFound;

    if (client.read_buffer_len >= client.read_buffer.len) {
        const error_msg = "ERROR: Line too long (max 4096 bytes)\r\n";
        _ = client.connection.write(error_msg) catch {};
        logging.logWarning("Client {}: Message exceeds buffer size, closing connection\n", .{client_id});
        return error.MessageTooLong;
    }

    if (self.config.idle_timeout > 0) {
        const idle_seconds = self.config.idle_timeout / 1000;
        if (client.isIdle(@intCast(idle_seconds))) {
            logging.logDebug("Client {} idle timeout ({}s), disconnecting\n", .{ client_id, idle_seconds });
            return broker.BrokerError.ClientSocketError;
        }
    }

    const bytes_read = client.connection.read(client.read_buffer[client.read_buffer_len..]) catch |err| {
        logging.logDebug("Client {} read error: {}\n", .{ client_id, err });
        switch (err) {
            error.WouldBlock => {
                logging.logTrace("Client {} read would block (non-blocking I/O)\n", .{client_id});
                return;
            },
            error.ConnectionResetByPeer => {
                logging.logDebug("Client {} connection reset by peer\n", .{client_id});
            },
            else => {
                logging.logError(err, "client read");
            },
        }
        return broker.BrokerError.ClientSocketError;
    };

    if (bytes_read == 0) {
        logging.logDebug("Client {} sent EOF (graceful disconnect)\n", .{client_id});
        return broker.BrokerError.ClientSocketError;
    }

    client.updateActivity();
    client.bytes_received += bytes_read;
    client.read_buffer_len += bytes_read;

    logging.logDebug("Client {} sent {} bytes (total received: {}\n", .{ client_id, bytes_read, client.bytes_received });

    if (logging.isVerbosityEnabled(self.config, .debug)) {
        const received_data = client.read_buffer[client.read_buffer_len - bytes_read .. client.read_buffer_len];
        logging.logHexDump(received_data, "Client Data");
    }

    switch (self.mode) {
        .broker => {
            const data = client.read_buffer[0..client.read_buffer_len];
            logging.logTrace("Broker mode: relaying {} bytes from client {}\n", .{ data.len, client_id });
            try self.relayToClients(data, client_id);
            client.read_buffer_len = 0;
        },
        .chat => {
            logging.logTrace("Chat mode: processing {} bytes from client {}\n", .{ bytes_read, client_id });
            try processChatData(self, client_id, scratch);
        },
    }
}

/// Process chat mode data buffered for a client
/// SECURITY FIX (2025-10-10): Changed client_id from u32 to u64 to match ClientPool
pub fn processChatData(
    self: *broker.BrokerServer,
    client_id: u64,
    scratch: std.mem.Allocator,
) !void {
    const client = self.clients.getClient(client_id) orelse return broker.BrokerError.ClientNotFound;

    var start: usize = 0;
    var lines_processed: usize = 0;

    while (start < client.read_buffer_len) {
        if (lines_processed >= broker.MAX_LINES_PER_TICK) {
            if (self.config.verbose) {
                logging.logDebug("Client {} hit line limit ({} lines), deferring remaining work to next tick\n", .{ client_id, broker.MAX_LINES_PER_TICK });
            }
            break;
        }

        const line_end = std.mem.indexOfScalarPos(u8, client.read_buffer[0..client.read_buffer_len], start, '\n');
        if (line_end == null) {
            break;
        }

        const end = line_end.?;
        var line = client.read_buffer[start..end];

        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        try processChatLine(self, client_id, line, scratch);

        start = end + 1;

        lines_processed += 1;
    }

    if (start > 0) {
        const remaining = client.read_buffer_len - start;
        if (remaining > 0) {
            std.mem.copyForwards(u8, client.read_buffer[0..remaining], client.read_buffer[start..client.read_buffer_len]);
        }
        client.read_buffer_len = remaining;
    }

    if (client.read_buffer_len >= client.read_buffer.len) {
        const error_msg = "ERROR: Line too long (max 4096 bytes)\r\n";
        _ = client.connection.write(error_msg) catch {};
        logging.logWarning("Client {}: Chat message exceeds buffer size, closing connection\n", .{client_id});
        return error.MessageTooLong;
    }
}

/// Process a single chat line from a client
/// SECURITY FIX (2025-10-10): Changed client_id from u32 to u64 to match ClientPool
pub fn processChatLine(
    self: *broker.BrokerServer,
    client_id: u64,
    line: []const u8,
    scratch: std.mem.Allocator,
) !void {
    const client = self.clients.getClient(client_id) orelse return broker.BrokerError.ClientNotFound;

    if (client.nickname == null) {
        const trimmed_nick = std.mem.trim(u8, line, " \t");

        logging.logTrace("Client {} attempting to set nickname: '{s}'\n", .{ client_id, trimmed_nick });

        if (!std.unicode.utf8ValidateSlice(trimmed_nick)) {
            client.nickname_attempts += 1;
            if (client.nickname_attempts > 5) {
                const error_msg = "*** Too many failed nickname attempts. Disconnecting.\r\n";
                _ = client.connection.write(error_msg) catch {};
                logging.logWarning("Client {}: Disconnected after too many failed nickname attempts (invalid UTF-8 nickname)\n", .{client_id});
                return broker.BrokerError.TooManyFailedAttempts;
            }
            const error_msg = "*** Nickname contains invalid UTF-8 characters. Please try again.\r\n";
            _ = client.connection.write(error_msg) catch {};
            return;
        }

        if (trimmed_nick.len == 0) {
            client.nickname_attempts += 1;
            if (client.nickname_attempts > 5) {
                const error_msg = "*** Too many failed nickname attempts. Disconnecting.\r\n";
                _ = client.connection.write(error_msg) catch {};
                logging.logWarning("Client {}: Disconnected after too many failed nickname attempts (empty nickname)\n", .{client_id});
                return broker.BrokerError.TooManyFailedAttempts;
            }

            const prompt = "Please enter a valid nickname: ";
            const bytes_sent = client.connection.write(prompt) catch |err| {
                logging.logError(err, "nickname prompt");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logTrace("Sent nickname prompt to client {} ({} bytes)\n", .{ client_id, bytes_sent });
            return;
        }

        if (trimmed_nick.len > self.config.chat_max_nickname_len) {
            client.nickname_attempts += 1;
            if (client.nickname_attempts > 5) {
                const error_msg = "*** Too many failed nickname attempts. Disconnecting.\r\n";
                _ = client.connection.write(error_msg) catch {};
                logging.logWarning("Client {}: Disconnected after too many failed nickname attempts (nickname too long)\n", .{client_id});
                return broker.BrokerError.TooManyFailedAttempts;
            }

            const error_msg = try std.fmt.allocPrint(scratch, "*** Nickname too long (max {} characters), please try again\n", .{self.config.chat_max_nickname_len});

            const bytes_sent = client.connection.write(error_msg) catch |err| {
                logging.logError(err, "nickname length error");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logDebug("Client {} nickname too long: {} chars\n", .{ client_id, trimmed_nick.len });
            return;
        }

        if (self.isChatNicknameTaken(trimmed_nick, client_id)) {
            client.nickname_attempts += 1;
            if (client.nickname_attempts > 5) {
                const error_msg = "*** Too many failed nickname attempts. Disconnecting.\r\n";
                _ = client.connection.write(error_msg) catch {};
                logging.logWarning("Client {}: Disconnected after too many failed nickname attempts (nickname taken)\n", .{client_id});
                return broker.BrokerError.TooManyFailedAttempts;
            }

            const error_msg = "*** Nickname already taken, please choose another\n";
            const bytes_sent = client.connection.write(error_msg) catch |err| {
                logging.logError(err, "nickname taken message");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logDebug("Client {} attempted duplicate nickname '{s}'\n", .{ client_id, trimmed_nick });
            return;
        }

        self.registerChatNickname(trimmed_nick, client_id) catch |err| {
            const error_msg = "*** Failed to set nickname, please try again\n";
            const bytes_sent = client.connection.write(error_msg) catch |write_err| {
                logging.logError(write_err, "nickname registry error message");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logError(err, "register nickname");
            return;
        };

        client.setNickname(self.allocator, trimmed_nick) catch |err| {
            self.unregisterChatNickname(trimmed_nick);
            const error_msg = "*** Failed to set nickname, please try again\n";
            const bytes_sent = client.connection.write(error_msg) catch |write_err| {
                logging.logError(write_err, "nickname error message");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logError(err, "set nickname");
            return;
        };

        // Reset nickname attempt counter on success
        client.nickname_attempts = 0;

        const confirm_msg = try std.fmt.allocPrint(scratch, "*** You are now known as {s}\n", .{trimmed_nick});

        const bytes_sent = client.connection.write(confirm_msg) catch |err| {
            logging.logError(err, "nickname confirmation");
            return;
        };
        client.bytes_sent += bytes_sent;

        const join_msg = try std.fmt.allocPrint(scratch, "*** {s} joined the chat\n", .{trimmed_nick});

        try self.relayToClients(join_msg, client_id);

        logging.log(1, "Client {} set nickname: {s}\n", .{ client_id, trimmed_nick });
        logging.logTrace("Nickname confirmation sent to client {} ({} bytes)\n", .{ client_id, bytes_sent });
        logging.logDebug("Relayed join announcement for {s} to other clients\n", .{trimmed_nick});
    } else {
        if (line.len == 0) {
            logging.logTrace("Client {} sent empty message, ignoring\n", .{client_id});
            return;
        }

        if (line.len > self.config.chat_max_message_len) {
            const error_msg = try std.fmt.allocPrint(scratch, "*** Message too long (max {} characters)\n", .{self.config.chat_max_message_len});

            const bytes_sent = client.connection.write(error_msg) catch |err| {
                logging.logError(err, "message length error");
                return;
            };
            client.bytes_sent += bytes_sent;
            logging.logDebug("Client {} message too long: {} chars\n", .{ client_id, line.len });
            return;
        }

        const formatted_msg = try std.fmt.allocPrint(
            scratch,
            "[{s}] {s}\n",
            .{ client.nickname.?, line },
        );

        try self.relayToClients(formatted_msg, client_id);

        logging.logDebug("Chat message from {s}: {s}\n", .{ client.nickname.?, line });
        logging.logTrace("Relayed {}-byte message from client {}\n", .{ formatted_msg.len, client_id });
    }
}
