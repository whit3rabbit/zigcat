// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! # Chat Protocol Handler
//!
//! This module implements the application-level logic for ZigCat's `--chat` mode.
//! It builds on top of the `BrokerServer` to provide a line-oriented, multi-user
//! chat service with features like nicknames, join/leave notifications, and
//! formatted messages.
//!
//! ## Key Responsibilities
//!
//! - **Nickname Management**: Handles the initial prompt for a nickname, validates
//!   the user's choice (for length, characters, and uniqueness), and stores it.
//! - **Line-Oriented Processing**: Buffers incoming TCP stream data and processes it
//!   one line at a time, correctly handling `\n` and `\r\n` line endings.
//! - **Message Formatting**: Prepends chat messages with the sender's nickname, e.g.,
//!   `[alice] Hello, world!`.
//! - **System Notifications**: Generates and broadcasts system-level messages for
//!   events like a user joining (`*** bob joined the chat`), leaving, or changing
//!   their nickname.
//!
//! ## Protocol Flow
//!
//! 1.  **Connection**: A new client connects. The `BrokerServer` accepts it.
//! 2.  **Welcome**: The `ChatHandler` sends a welcome message and prompts for a nickname.
//!     The client is in the `awaiting_nickname` state.
//! 3.  **Nickname Input**: The client sends their desired nickname.
//! 4.  **Validation**: The handler validates the nickname. If it's valid and not
//!     taken, the client's state is set to `active`, and a "join" notification
//!     is broadcast to all other clients. If not, an error is sent, and the
//!     client remains in the `awaiting_nickname` state.
//! 5.  **Chatting**: Once active, any line sent by the client is treated as a chat
//!     message. The handler formats it and relays it to all other clients.
//! 6.  **Disconnection**: When a client disconnects, the handler broadcasts a "leave"
//!     notification to the remaining clients.
//!
//! This module is tightly coupled with the `BrokerServer`, which handles the
//! underlying I/O and client management. The `ChatHandler` effectively acts as
//! a state machine and formatter for the chat application logic.

const std = @import("std");
const RelayEngine = @import("relay.zig").RelayEngine;
const ClientPool = @import("client_pool.zig").ClientPool;
const ClientInfo = @import("client_pool.zig").ClientInfo;
const logging = @import("../util/logging.zig");

/// Chat protocol handler errors
pub const ChatError = error{
    /// Client not found in pool
    ClientNotFound,
    /// Invalid nickname provided
    InvalidNickname,
    /// Nickname already in use
    NicknameTaken,
    /// Message too long for processing
    MessageTooLong,
    /// Failed to send message to client
    SendFailed,
    /// Memory allocation failed
    OutOfMemory,
    /// Invalid message format
    InvalidMessageFormat,
    /// Client not in correct state for operation
    InvalidClientState,
};

/// Chat client states for protocol flow management
pub const ChatClientState = enum {
    /// Client just connected, needs nickname
    awaiting_nickname,
    /// Client has nickname and is active in chat
    active,
    /// Client is disconnecting
    disconnecting,
};

/// Chat protocol handler for line-oriented messaging
pub const ChatHandler = struct {
    /// Memory allocator for message formatting
    allocator: std.mem.Allocator,
    /// Reference to relay engine for message distribution
    relay_engine: *RelayEngine,
    /// Maximum nickname length allowed
    max_nickname_len: usize = 32,
    /// Maximum message length allowed
    max_message_len: usize = 1024,
    /// Welcome message sent to new clients
    welcome_message: []const u8 = "Welcome to ZigCat chat! Please enter your nickname: ",
    /// Nickname prompt for invalid attempts
    nickname_prompt: []const u8 = "Please enter a valid nickname: ",

    /// Initialize chat protocol handler
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for message formatting
    /// - `relay_engine`: Reference to relay engine for message distribution
    ///
    /// ## Returns
    /// Initialized chat handler ready for use
    pub fn init(allocator: std.mem.Allocator, relay_engine: *RelayEngine) ChatHandler {
        return ChatHandler{
            .allocator = allocator,
            .relay_engine = relay_engine,
        };
    }

    /// Clean up chat handler resources
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    pub fn deinit(self: *ChatHandler) void {
        _ = self;
    }

    /// Handle a new client joining the chat
    ///
    /// Sends welcome message and prompts for nickname. This is called
    /// when a client first connects to the chat server.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of the newly connected client
    ///
    /// ## Returns
    /// Error if welcome message cannot be sent
    ///
    /// ## Behavior
    /// - Sends welcome message to client
    /// - Prompts for nickname
    /// - Sets client state to awaiting_nickname
    pub fn handleClientJoin(self: *ChatHandler, client_id: u32) !void {
        // Get client from pool
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        // Send welcome message and nickname prompt
        const bytes_sent = client.connection.write(self.welcome_message) catch {
            return ChatError.SendFailed;
        };

        // Update client statistics
        client.bytes_sent += bytes_sent;
        client.updateActivity();

        logging.logDebug("Sent welcome message to client {any} ({any} bytes)\n", .{ client_id, bytes_sent });
    }

    /// Handle a client leaving the chat
    ///
    /// Announces the client's departure to all remaining clients if the
    /// client had a nickname set.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of the departing client
    /// - `nickname`: Optional nickname of the departing client
    ///
    /// ## Returns
    /// Error if leave announcement cannot be sent
    ///
    /// ## Behavior
    /// - Creates leave announcement message
    /// - Broadcasts to all remaining clients
    /// - Logs the departure
    pub fn handleClientLeave(self: *ChatHandler, client_id: u32, nickname: ?[]const u8) !void {
        // Only announce if client had a nickname
        if (nickname) |nick| {
            self.unregisterNickname(nick);

            // Create leave announcement
            const leave_msg = try std.fmt.allocPrint(
                self.allocator,
                "*** {s} left the chat\n",
                .{nick},
            );
            defer self.allocator.free(leave_msg);

            // Broadcast to all clients (no sender exclusion for system messages)
            try self.relay_engine.broadcastNotification(leave_msg);

            logging.logDebug("Client {any} ({s}) left the chat\n", .{ client_id, nick });
        } else {
            logging.logDebug("Client {any} left without setting nickname\n", .{client_id});
        }
    }

    /// Process incoming message data from a client
    ///
    /// Handles both nickname setting (for new clients) and regular chat
    /// messages. Processes line-oriented data with proper CRLF handling.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client sending the message
    /// - `raw_data`: Raw data received from client
    ///
    /// ## Returns
    /// Error if message processing fails
    ///
    /// ## Behavior
    /// - Processes complete lines from raw data
    /// - Handles nickname setting for new clients
    /// - Formats and relays chat messages
    /// - Maintains client read buffer state
    pub fn processMessage(self: *ChatHandler, client_id: u32, raw_data: []const u8) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        // Add new data to client's read buffer
        if (client.read_buffer_len + raw_data.len > client.read_buffer.len) {
            // Buffer would overflow - reset and send error
            client.read_buffer_len = 0;
            const error_msg = "*** Message too long, please try again\n";
            _ = client.connection.write(error_msg) catch {};
            return ChatError.MessageTooLong;
        }

        // Copy new data to read buffer
        @memcpy(client.read_buffer[client.read_buffer_len .. client.read_buffer_len + raw_data.len], raw_data);
        client.read_buffer_len += raw_data.len;

        // Process complete lines
        try self.processCompleteLines(client_id);
    }

    /// Process complete lines from client's read buffer
    ///
    /// Extracts complete lines (ending with \n) from the client's read buffer
    /// and processes each line according to the client's current state.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client whose buffer to process
    ///
    /// ## Returns
    /// Error if line processing fails
    fn processCompleteLines(self: *ChatHandler, client_id: u32) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        var start: usize = 0;
        while (start < client.read_buffer_len) {
            // Find line ending
            const line_end = std.mem.indexOfScalarPos(u8, client.read_buffer[0..client.read_buffer_len], start, '\n');
            if (line_end == null) {
                // No complete line yet
                break;
            }

            const end = line_end.?;
            var line = client.read_buffer[start..end];

            // Remove trailing \r if present (handle CRLF)
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            // Process the line based on client state
            try self.processLine(client_id, line);

            start = end + 1; // Move past the \n
        }

        // Move remaining data to beginning of buffer
        if (start > 0) {
            const remaining = client.read_buffer_len - start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, client.read_buffer[0..remaining], client.read_buffer[start..client.read_buffer_len]);
            }
            client.read_buffer_len = remaining;
        }
    }

    /// Process a single complete line from a client
    ///
    /// Handles the line based on whether the client has set a nickname or not.
    /// New clients are prompted for nicknames, while active clients have their
    /// messages formatted and relayed.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client sending the line
    /// - `line`: Complete line of text (without line endings)
    ///
    /// ## Returns
    /// Error if line processing fails
    fn processLine(self: *ChatHandler, client_id: u32, line: []const u8) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        if (client.nickname == null) {
            // Client hasn't set nickname yet - process as nickname
            try self.handleNicknameInput(client_id, line);
        } else {
            // Client has nickname - process as chat message
            try self.handleChatMessage(client_id, line);
        }
    }

    /// Handle nickname input from a new client
    ///
    /// Validates the proposed nickname, checks for conflicts, and either
    /// sets the nickname (with join announcement) or prompts again.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client setting nickname
    /// - `nickname_input`: Raw nickname input from client
    ///
    /// ## Returns
    /// Error if nickname processing fails
    fn handleNicknameInput(self: *ChatHandler, client_id: u32, nickname_input: []const u8) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        // Trim whitespace from nickname
        const trimmed_nick = std.mem.trim(u8, nickname_input, " \t\r\n");

        // Validate nickname
        if (!self.validateNickname(trimmed_nick)) {
            // Send error message and prompt again
            const error_msg = "*** Invalid nickname. Please use 1-32 characters, no special characters.\n";
            _ = client.connection.write(error_msg) catch {};
            _ = client.connection.write(self.nickname_prompt) catch {};
            return;
        }

        // Check if nickname is already taken
        if (self.isNicknameTaken(trimmed_nick, client_id)) {
            // Send error message and prompt again
            const error_msg = "*** Nickname already taken. Please choose another.\n";
            _ = client.connection.write(error_msg) catch {};
            _ = client.connection.write(self.nickname_prompt) catch {};
            return;
        }

        self.registerNickname(trimmed_nick, client_id) catch |err| {
            const error_msg = "*** Failed to set nickname. Please try again.\n";
            _ = client.connection.write(error_msg) catch {};
            _ = client.connection.write(self.nickname_prompt) catch {};
            logging.logError(err, "register nickname");
            return;
        };

        // Set nickname
        client.setNickname(self.allocator, trimmed_nick) catch |err| {
            self.unregisterNickname(trimmed_nick);
            const error_msg = "*** Failed to set nickname. Please try again.\n";
            _ = client.connection.write(error_msg) catch {};
            _ = client.connection.write(self.nickname_prompt) catch {};
            logging.logError(err, "set nickname");
            return;
        };

        // Send confirmation to client
        const confirm_msg = try std.fmt.allocPrint(
            self.allocator,
            "*** You are now known as {s}\n",
            .{trimmed_nick},
        );
        defer self.allocator.free(confirm_msg);

        _ = client.connection.write(confirm_msg) catch {};

        // Announce join to other clients
        const join_msg = try std.fmt.allocPrint(
            self.allocator,
            "*** {s} joined the chat\n",
            .{trimmed_nick},
        );
        defer self.allocator.free(join_msg);

        // Relay join message to all other clients (exclude this client)
        try self.relay_engine.relayData(join_msg, client_id);

        logging.logDebug("Client {any} set nickname: {s}\n", .{ client_id, trimmed_nick });
    }

    /// Handle a chat message from an active client
    ///
    /// Formats the message with the client's nickname and relays it to
    /// all other connected clients.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client sending the message
    /// - `message`: Message content (without nickname prefix)
    ///
    /// ## Returns
    /// Error if message handling fails
    fn handleChatMessage(self: *ChatHandler, client_id: u32, message: []const u8) !void {
        // Ignore empty messages
        if (message.len == 0) return;

        // Validate message length
        if (message.len > self.max_message_len) {
            const client_pool = self.relay_engine.client_pool;
            if (client_pool.getClient(client_id)) |client| {
                const error_msg = "*** Message too long, please try again\n";
                _ = client.connection.write(error_msg) catch {};
            }
            return ChatError.MessageTooLong;
        }

        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        // Get client nickname (should exist for active clients)
        const nickname = client.nickname orelse return ChatError.InvalidClientState;

        // Format message with nickname prefix
        const formatted_msg = try std.fmt.allocPrint(
            self.allocator,
            "[{s}] {s}\n",
            .{ nickname, message },
        );
        defer self.allocator.free(formatted_msg);

        // Relay formatted message to all other clients
        try self.relay_engine.relayData(formatted_msg, client_id);

        logging.logDebug("Chat message from {s}: {s}\n", .{ nickname, message });
    }

    /// Handle nickname change request from a client
    ///
    /// Validates the new nickname, checks for conflicts, updates the client's
    /// nickname, and announces the change to all clients.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `client_id`: ID of client changing nickname
    /// - `new_nickname`: New nickname to set
    ///
    /// ## Returns
    /// Error if nickname change fails
    ///
    /// ## Behavior
    /// - Validates new nickname
    /// - Checks for conflicts with existing nicknames
    /// - Updates client nickname
    /// - Broadcasts nickname change notification
    pub fn handleNicknameChange(self: *ChatHandler, client_id: u32, new_nickname: []const u8) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        // Validate new nickname
        if (!self.validateNickname(new_nickname)) {
            const error_msg = "*** Invalid nickname. Please use 1-32 characters, no special characters.\n";
            _ = client.connection.write(error_msg) catch {};
            return ChatError.InvalidNickname;
        }

        // Check for nickname conflicts
        if (self.isNicknameTaken(new_nickname, client_id)) {
            const error_msg = "*** Nickname already taken. Please choose another.\n";
            _ = client.connection.write(error_msg) catch {};
            return ChatError.NicknameTaken;
        }

        // Get old nickname for announcement
        const old_nickname = if (client.nickname) |nick|
            try self.allocator.dupe(u8, nick)
        else
            try self.allocator.dupe(u8, "Unknown");
        defer self.allocator.free(old_nickname);

        const previous_nick = client.nickname;
        if (previous_nick) |old| {
            self.unregisterNickname(old);
        }

        self.registerNickname(new_nickname, client_id) catch |err| {
            if (previous_nick) |old| {
                self.registerNickname(old, client_id) catch |restore_err| {
                    logging.logError(restore_err, "restore nickname after register failure");
                };
            }

            const error_msg = "*** Failed to set nickname. Please try again.\n";
            _ = client.connection.write(error_msg) catch {};
            return err;
        };

        // Update client nickname
        client.setNickname(self.allocator, new_nickname) catch |err| {
            self.unregisterNickname(new_nickname);
            if (previous_nick) |old| {
                self.registerNickname(old, client_id) catch |restore_err| {
                    logging.logError(restore_err, "restore nickname after set failure");
                };
            }
            return err;
        };

        // Broadcast nickname change notification
        const change_msg = try std.fmt.allocPrint(
            self.allocator,
            "*** {s} is now known as {s}\n",
            .{ old_nickname, new_nickname },
        );
        defer self.allocator.free(change_msg);

        try self.relay_engine.broadcastNotification(change_msg);

        logging.logDebug("Client {any} changed nickname from {s} to {s}\n", .{ client_id, old_nickname, new_nickname });
    }

    /// Send welcome message to a client
    ///
    /// Sends the standard welcome message and nickname prompt to a newly
    /// connected client.
    ///
    /// ## Parameters
    /// - `self`: Const reference to chat handler
    /// - `client_id`: ID of client to send welcome message to
    ///
    /// ## Returns
    /// Error if welcome message cannot be sent
    fn sendWelcomeMessage(self: *const ChatHandler, client_id: u32) !void {
        const client_pool = self.relay_engine.client_pool;
        const client = client_pool.getClient(client_id) orelse return ChatError.ClientNotFound;

        const bytes_sent = client.connection.write(self.welcome_message) catch {
            return ChatError.SendFailed;
        };

        client.bytes_sent += bytes_sent;
        client.updateActivity();
    }

    /// Validate a nickname for chat mode
    ///
    /// Checks nickname against validation rules including length limits,
    /// character restrictions, and formatting requirements.
    ///
    /// ## Parameters
    /// - `self`: Const reference to chat handler
    /// - `nickname`: Nickname to validate
    ///
    /// ## Returns
    /// True if nickname is valid, false otherwise
    ///
    /// ## Validation Rules
    /// - Length between 1 and max_nickname_len
    /// - No whitespace at start/end
    /// - No control characters
    /// - No special characters that could break formatting
    /// - No reserved words or patterns
    fn validateNickname(self: *const ChatHandler, nickname: []const u8) bool {
        // Check length
        if (nickname.len == 0 or nickname.len > self.max_nickname_len) {
            return false;
        }

        // Check for whitespace at start/end
        const trimmed = std.mem.trim(u8, nickname, " \t\r\n");
        if (trimmed.len != nickname.len) {
            return false;
        }

        // Check for invalid characters
        for (nickname) |char| {
            // Disallow control characters
            if (char < 32 or char == 127) {
                return false;
            }
            // Disallow characters that could break message formatting
            if (char == '[' or char == ']' or char == '\n' or char == '\r') {
                return false;
            }
            // Disallow other problematic characters
            if (char == '*' or char == '/' or char == '\\') {
                return false;
            }
        }

        // Check for reserved patterns
        if (std.mem.startsWith(u8, nickname, "***")) {
            return false; // Reserved for system messages
        }

        return true;
    }

    /// Check if a nickname is already taken by another client
    ///
    /// Uses a hash map of active nicknames for O(1) lookups.
    ///
    /// ## Parameters
    /// - `self`: Const reference to chat handler
    /// - `nickname`: Nickname to check for conflicts
    /// - `exclude_client_id`: Client ID to exclude from check (for nickname changes)
    ///
    /// ## Returns
    /// True if nickname is taken by another client, false otherwise
    fn isNicknameTaken(self: *const ChatHandler, nickname: []const u8, exclude_client_id: u32) bool {
        return self.relay_engine.isNicknameTaken(nickname, exclude_client_id);
    }

    fn registerNickname(self: *ChatHandler, nickname: []const u8, client_id: u32) !void {
        try self.relay_engine.registerNickname(nickname, client_id);
    }

    fn unregisterNickname(self: *ChatHandler, nickname: []const u8) void {
        self.relay_engine.unregisterNickname(nickname);
    }

    /// Parse a nickname command from client input
    ///
    /// Extracts nickname from various command formats that clients might use.
    /// Supports both direct nickname input and command-style input.
    ///
    /// ## Parameters
    /// - `self`: Const reference to chat handler
    /// - `data`: Raw input data from client
    ///
    /// ## Returns
    /// Extracted nickname if found, null otherwise
    ///
    /// ## Supported Formats
    /// - Direct: `nickname`
    /// - Command: `/nick nickname`
    /// - Command: `/name nickname`
    fn parseNicknameCommand(self: *const ChatHandler, data: []const u8) ?[]const u8 {
        _ = self; // Suppress unused parameter warning

        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Check for /nick command
        if (std.mem.startsWith(u8, trimmed, "/nick ")) {
            const nick_start = 6; // Length of "/nick "
            if (trimmed.len > nick_start) {
                return std.mem.trim(u8, trimmed[nick_start..], " \t");
            }
            return null;
        }

        // Check for /name command
        if (std.mem.startsWith(u8, trimmed, "/name ")) {
            const name_start = 6; // Length of "/name "
            if (trimmed.len > name_start) {
                return std.mem.trim(u8, trimmed[name_start..], " \t");
            }
            return null;
        }

        // Treat as direct nickname input
        return trimmed;
    }

    /// Set maximum nickname length
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `max_len`: Maximum nickname length in bytes
    pub fn setMaxNicknameLength(self: *ChatHandler, max_len: usize) void {
        self.max_nickname_len = max_len;
    }

    /// Set maximum message length
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to chat handler
    /// - `max_len`: Maximum message length in bytes
    pub fn setMaxMessageLength(self: *ChatHandler, max_len: usize) void {
        self.max_message_len = max_len;
    }

    /// Get current configuration
    ///
    /// ## Parameters
    /// - `self`: Const reference to chat handler
    ///
    /// ## Returns
    /// Tuple of (max_nickname_len, max_message_len)
    pub fn getConfig(self: *const ChatHandler) struct { max_nickname_len: usize, max_message_len: usize } {
        return .{
            .max_nickname_len = self.max_nickname_len,
            .max_message_len = self.max_message_len,
        };
    }
};

// Tests for ChatHandler functionality
test "ChatHandler initialization" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = @import("client_pool.zig").ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = @import("relay.zig").RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    var chat_handler = ChatHandler.init(allocator, &relay_engine);
    defer chat_handler.deinit();

    try testing.expect(chat_handler.max_nickname_len == 32);
    try testing.expect(chat_handler.max_message_len == 1024);
}

test "ChatHandler nickname validation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = @import("client_pool.zig").ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = @import("relay.zig").RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    const chat_handler = ChatHandler.init(allocator, &relay_engine);

    // Valid nicknames
    try testing.expect(chat_handler.validateNickname("alice"));
    try testing.expect(chat_handler.validateNickname("user123"));
    try testing.expect(chat_handler.validateNickname("test_user"));
    try testing.expect(chat_handler.validateNickname("Bob"));

    // Invalid nicknames
    try testing.expect(!chat_handler.validateNickname("")); // Empty
    try testing.expect(!chat_handler.validateNickname(" alice")); // Leading space
    try testing.expect(!chat_handler.validateNickname("alice ")); // Trailing space
    try testing.expect(!chat_handler.validateNickname("alice\n")); // Control character
    try testing.expect(!chat_handler.validateNickname("alice[bob]")); // Brackets
    try testing.expect(!chat_handler.validateNickname("***system")); // Reserved pattern
    try testing.expect(!chat_handler.validateNickname("alice*bob")); // Asterisk
    try testing.expect(!chat_handler.validateNickname("a" ** 50)); // Too long
}

test "ChatHandler nickname command parsing" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = @import("client_pool.zig").ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = @import("relay.zig").RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    const chat_handler = ChatHandler.init(allocator, &relay_engine);

    // Test direct nickname
    if (chat_handler.parseNicknameCommand("alice")) |nick| {
        try testing.expectEqualStrings("alice", nick);
    } else {
        try testing.expect(false);
    }

    // Test /nick command
    if (chat_handler.parseNicknameCommand("/nick bob")) |nick| {
        try testing.expectEqualStrings("bob", nick);
    } else {
        try testing.expect(false);
    }

    // Test /name command
    if (chat_handler.parseNicknameCommand("/name charlie")) |nick| {
        try testing.expectEqualStrings("charlie", nick);
    } else {
        try testing.expect(false);
    }

    // Test empty input
    try testing.expect(chat_handler.parseNicknameCommand("") == null);
    try testing.expect(chat_handler.parseNicknameCommand("   ") == null);

    // Test incomplete commands
    try testing.expect(chat_handler.parseNicknameCommand("/nick") == null);
    try testing.expect(chat_handler.parseNicknameCommand("/name") == null);
}

test "ChatHandler configuration" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = @import("client_pool.zig").ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = @import("relay.zig").RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    var chat_handler = ChatHandler.init(allocator, &relay_engine);

    // Test setting configuration
    chat_handler.setMaxNicknameLength(64);
    chat_handler.setMaxMessageLength(2048);

    const config = chat_handler.getConfig();
    try testing.expect(config.max_nickname_len == 64);
    try testing.expect(config.max_message_len == 2048);
}
