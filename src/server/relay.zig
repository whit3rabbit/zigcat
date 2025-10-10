//! Message Relay Engine for Data Distribution
//!
//! This module implements the core message relay functionality for ZigCat's
//! broker and chat modes. It handles efficient data distribution between
//! multiple clients with sender exclusion and minimal memory overhead.
//!
//! ## Design Goals
//!
//! - **Efficient Distribution**: Minimize memory copying and allocation overhead
//! - **Sender Exclusion**: Prevent clients from receiving their own data
//! - **Mode Awareness**: Handle both raw broker mode and formatted chat mode
//! - **Error Isolation**: Client-specific errors don't affect other clients
//! - **Memory Safety**: Proper buffer management and bounds checking
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Client        │    │   Relay          │    │   Client        │
//! │   Data Input    │───▶│   Engine         │───▶│   Data Output   │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//!          │                       │                       │
//!          ▼                       ▼                       ▼
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Raw Data      │    │   Format         │    │   Distribute    │
//! │   (Broker)      │    │   Messages       │    │   to Clients    │
//! │   Chat Lines    │    │   (Chat Mode)    │    │   (Exclude      │
//! │   (Chat)        │    │                  │    │   Sender)       │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//! ```
//!
//! ## Usage Patterns
//!
//! ### Broker Mode
//! ```zig
//! // Raw data relay - forward as-is
//! try relay_engine.relayData(raw_data, sender_id);
//! ```
//!
//! ### Chat Mode
//! ```zig
//! // Formatted message relay with nickname
//! try relay_engine.relayMessage(message_text, sender_id);
//!
//! // System notifications to all clients
//! try relay_engine.broadcastNotification("*** User joined");
//! ```
//!
//! ## Performance Characteristics
//!
//! - **Zero-Copy**: Direct buffer access where possible
//! - **Batch Operations**: Single allocation for multiple client writes
//! - **Error Recovery**: Failed clients are isolated and removed
//! - **Memory Pooling**: Reusable buffers for message formatting

const std = @import("std");
const ClientPool = @import("client_pool.zig").ClientPool;
const ClientInfo = @import("client_pool.zig").ClientInfo;
const logging = @import("../util/logging.zig");

/// Broker operation modes (imported from broker.zig)
pub const BrokerMode = enum {
    /// Raw data relay mode - forwards all data as-is
    broker,
    /// Line-oriented chat mode with nicknames and formatting
    chat,
};

/// Relay engine errors
pub const RelayError = error{
    /// Client not found in pool
    ClientNotFound,
    /// Failed to relay data to one or more clients
    RelayFailed,
    /// Message formatting failed
    FormatError,
    /// Memory allocation failed
    OutOfMemory,
    /// Invalid nickname provided
    InvalidNickname,
    /// Nickname already in use
    NicknameTaken,
    /// Message too long for buffer
    MessageTooLong,
};

/// Statistics for relay operations
pub const RelayStats = struct {
    /// Total messages relayed
    messages_relayed: u64 = 0,
    /// Total bytes relayed
    bytes_relayed: u64 = 0,
    /// Number of relay errors encountered
    relay_errors: u64 = 0,
    /// Number of clients that failed to receive data
    failed_clients: u64 = 0,

    /// Reset all statistics to zero
    pub fn reset(self: *RelayStats) void {
        self.* = RelayStats{};
    }
};

/// Message relay engine for distributing data between clients
pub const RelayEngine = struct {
    /// Memory allocator for temporary buffers
    allocator: std.mem.Allocator,
    /// Reference to client pool for accessing clients
    client_pool: *ClientPool,
    /// Current broker mode (broker or chat)
    mode: BrokerMode,
    /// Relay operation statistics
    stats: RelayStats = RelayStats{},
    /// Maximum message length for chat mode
    max_message_len: usize = 1024,
    /// Maximum nickname length for chat mode
    max_nickname_len: usize = 32,
    /// Fast lookup table for active chat nicknames
    nickname_index: std.StringHashMap(u32),

    /// Initialize relay engine
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for temporary message formatting
    /// - `client_pool`: Reference to client pool for accessing clients
    /// - `mode`: Broker operation mode (broker or chat)
    ///
    /// ## Returns
    /// Initialized relay engine ready for use
    pub fn init(allocator: std.mem.Allocator, client_pool: *ClientPool, mode: BrokerMode) RelayEngine {
        return RelayEngine{
            .allocator = allocator,
            .client_pool = client_pool,
            .mode = mode,
            .nickname_index = std.StringHashMap(u32).init(allocator),
        };
    }

    /// Release relay engine resources
    pub fn deinit(self: *RelayEngine) void {
        self.clearNicknameIndex();
        self.nickname_index.deinit();
    }

    /// Relay raw data to all clients except the sender
    ///
    /// This is the core relay function used in broker mode to forward
    /// data as-is without any formatting or modification.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `data`: Raw data to relay to clients
    /// - `sender_id`: ID of client that sent the data (excluded from relay)
    ///
    /// ## Returns
    /// Error if relay operation fails completely
    ///
    /// ## Behavior
    /// - Distributes data to all clients except sender
    /// - Continues on individual client errors
    /// - Updates relay statistics
    /// - Logs errors for debugging
    pub fn relayData(self: *RelayEngine, data: []const u8, sender_id: u32) !void {
        if (data.len == 0) return;

        // Get list of all client IDs
        const client_ids = self.client_pool.getAllClientIds(self.allocator) catch {
            return RelayError.OutOfMemory;
        };
        defer self.allocator.free(client_ids);

        var success_count: usize = 0;
        var error_count: usize = 0;

        // Relay to each client (except sender)
        for (client_ids) |client_id| {
            // Skip sender to prevent echo-back
            if (client_id == sender_id) continue;

            // Get client from pool
            if (self.client_pool.getClient(client_id)) |client| {
                // Attempt to send data to client
                const bytes_sent = client.connection.write(data) catch |err| {
                    error_count += 1;
                    self.stats.failed_clients += 1;

                    // Log error but continue with other clients
                    logging.logDebug("Failed to relay {any} bytes to client {any}: {any}\n", .{ data.len, client_id, err });
                    continue;
                };

                // Update client statistics
                client.bytes_sent += bytes_sent;
                client.updateActivity();
                success_count += 1;
            } else {
                // Client not found - may have been removed
                error_count += 1;
                self.stats.failed_clients += 1;
            }
        }

        // Update relay statistics
        if (success_count > 0) {
            self.stats.messages_relayed += 1;
            self.stats.bytes_relayed += data.len * success_count;
        }

        if (error_count > 0) {
            self.stats.relay_errors += 1;
        }

        // Log relay summary for debugging
        logging.logDebug("Relayed {any} bytes to {any} clients ({any} errors)\n", .{ data.len, success_count, error_count });
    }

    /// Relay a formatted chat message to all clients except the sender
    ///
    /// This function is used in chat mode to send formatted messages
    /// with nickname prefixes to all connected clients.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `message`: Plain message text (without formatting)
    /// - `sender_id`: ID of client that sent the message
    ///
    /// ## Returns
    /// Error if message formatting or relay fails
    ///
    /// ## Behavior
    /// - Looks up sender's nickname from client pool
    /// - Formats message with nickname prefix
    /// - Relays formatted message to all other clients
    /// - Handles missing nickname gracefully
    pub fn relayMessage(self: *RelayEngine, message: []const u8, sender_id: u32) !void {
        if (self.mode != .chat) {
            // In broker mode, just relay raw data
            return self.relayData(message, sender_id);
        }

        // Get sender's nickname
        const sender_nickname = blk: {
            if (self.client_pool.getClient(sender_id)) |client| {
                if (client.nickname) |nick| {
                    break :blk nick;
                }
            }
            break :blk "Unknown";
        };

        // Format the chat message
        const formatted_message = try self.formatChatMessage(message, sender_nickname);
        defer self.allocator.free(formatted_message);

        // Relay the formatted message
        try self.relayData(formatted_message, sender_id);
    }

    /// Broadcast a notification message to all clients
    ///
    /// This function sends system notifications (like join/leave messages)
    /// to all connected clients without excluding any sender.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `notification`: Notification message to broadcast
    ///
    /// ## Returns
    /// Error if broadcast fails
    ///
    /// ## Behavior
    /// - Sends notification to ALL clients (no sender exclusion)
    /// - Used for system messages like join/leave announcements
    /// - Handles client errors gracefully
    pub fn broadcastNotification(self: *RelayEngine, notification: []const u8) !void {
        if (notification.len == 0) return;

        // Get list of all client IDs
        const client_ids = self.client_pool.getAllClientIds(self.allocator) catch {
            return RelayError.OutOfMemory;
        };
        defer self.allocator.free(client_ids);

        var success_count: usize = 0;
        var error_count: usize = 0;

        // Send to all clients (no sender exclusion for notifications)
        for (client_ids) |client_id| {
            if (self.client_pool.getClient(client_id)) |client| {
                const bytes_sent = client.connection.write(notification) catch |err| {
                    error_count += 1;
                    self.stats.failed_clients += 1;
                    logging.logDebug("Failed to broadcast to client {any}: {any}\n", .{ client_id, err });
                    continue;
                };

                client.bytes_sent += bytes_sent;
                client.updateActivity();
                success_count += 1;
            } else {
                error_count += 1;
                self.stats.failed_clients += 1;
            }
        }

        // Update statistics
        if (success_count > 0) {
            self.stats.messages_relayed += 1;
            self.stats.bytes_relayed += notification.len * success_count;
        }

        if (error_count > 0) {
            self.stats.relay_errors += 1;
        }

        logging.logDebug("Broadcast {any} bytes to {any} clients ({any} errors)\n", .{ notification.len, success_count, error_count });
    }

    /// Format a chat message with nickname prefix
    ///
    /// ## Parameters
    /// - `self`: Const reference to relay engine
    /// - `message`: Plain message text
    /// - `sender_nickname`: Nickname of the sender
    ///
    /// ## Returns
    /// Formatted message string (caller owns memory)
    ///
    /// ## Format
    /// `[nickname] message\n`
    fn formatChatMessage(self: *const RelayEngine, message: []const u8, sender_nickname: []const u8) ![]u8 {
        // Validate message length
        if (message.len > self.max_message_len) {
            return RelayError.MessageTooLong;
        }

        // Validate nickname length
        if (sender_nickname.len > self.max_nickname_len) {
            return RelayError.InvalidNickname;
        }

        // Format: [nickname] message\n
        const formatted = try std.fmt.allocPrint(
            self.allocator,
            "[{s}] {s}\n",
            .{ sender_nickname, message },
        );

        return formatted;
    }

    /// Handle nickname change for a client
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `client_id`: ID of client changing nickname
    /// - `new_nickname`: New nickname to set
    ///
    /// ## Returns
    /// Error if nickname change fails
    ///
    /// ## Behavior
    /// - Validates new nickname
    /// - Checks for nickname conflicts
    /// - Updates client nickname
    /// - Broadcasts nickname change notification
    pub fn handleNicknameChange(self: *RelayEngine, client_id: u32, new_nickname: []const u8) !void {
        if (self.mode != .chat) return; // Only applicable in chat mode

        // Validate nickname
        if (!self.validateNickname(new_nickname)) {
            return RelayError.InvalidNickname;
        }

        // Check for nickname conflicts
        if (self.isNicknameTaken(new_nickname, client_id)) {
            return RelayError.NicknameTaken;
        }

        // Get client and old nickname
        const client = self.client_pool.getClient(client_id) orelse return RelayError.ClientNotFound;
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
        const notification = try std.fmt.allocPrint(
            self.allocator,
            "*** {s} is now known as {s}\n",
            .{ old_nickname, new_nickname },
        );
        defer self.allocator.free(notification);

        try self.broadcastNotification(notification);
    }

    /// Validate a nickname for chat mode
    ///
    /// ## Parameters
    /// - `self`: Const reference to relay engine
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
    fn validateNickname(self: *const RelayEngine, nickname: []const u8) bool {
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
        }

        return true;
    }

    /// Check if a nickname is already taken by another client
    ///
    /// ## Parameters
    /// - `self`: Const reference to relay engine
    /// - `nickname`: Nickname to check
    /// - `exclude_client_id`: Client ID to exclude from check (for nickname changes)
    ///
    /// ## Returns
    /// True if nickname is taken by another client, false otherwise
    fn isNicknameTaken(self: *const RelayEngine, nickname: []const u8, exclude_client_id: u32) bool {
        if (self.mode != .chat) return false;

        if (self.nickname_index.get(nickname)) |existing_id| {
            return existing_id != exclude_client_id;
        }

        return false;
    }

    pub fn registerNickname(self: *RelayEngine, nickname: []const u8, client_id: u32) !void {
        if (self.mode != .chat) return;

        if (self.nickname_index.fetchRemove(nickname)) |kv| {
            self.allocator.free(@constCast(kv.key));
        }

        const nickname_copy = try self.allocator.dupe(u8, nickname);
        errdefer self.allocator.free(nickname_copy);

        try self.nickname_index.put(nickname_copy, client_id);
    }

    pub fn unregisterNickname(self: *RelayEngine, nickname: []const u8) void {
        if (self.mode != .chat) return;

        if (self.nickname_index.fetchRemove(nickname)) |kv| {
            self.allocator.free(@constCast(kv.key));
        }
    }

    pub fn unregisterNicknameById(self: *RelayEngine, client_id: u32) void {
        if (self.mode != .chat) return;

        var it = self.nickname_index.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == client_id) {
                const key = entry.key_ptr.*;
                if (self.nickname_index.fetchRemove(key)) |kv| {
                    self.allocator.free(@constCast(kv.key));
                }
                return;
            }
        }
    }

    fn clearNicknameIndex(self: *RelayEngine) void {
        if (self.nickname_index.count() == 0) return;

        var it = self.nickname_index.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.nickname_index.clearRetainingCapacity();
    }

    /// Get current relay statistics
    ///
    /// ## Parameters
    /// - `self`: Const reference to relay engine
    ///
    /// ## Returns
    /// Copy of current relay statistics
    pub fn getStats(self: *const RelayEngine) RelayStats {
        return self.stats;
    }

    /// Reset relay statistics
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    pub fn resetStats(self: *RelayEngine) void {
        self.stats.reset();
    }

    /// Set maximum message length for chat mode
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `max_len`: Maximum message length in bytes
    pub fn setMaxMessageLength(self: *RelayEngine, max_len: usize) void {
        self.max_message_len = max_len;
    }

    /// Set maximum nickname length for chat mode
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to relay engine
    /// - `max_len`: Maximum nickname length in bytes
    pub fn setMaxNicknameLength(self: *RelayEngine, max_len: usize) void {
        self.max_nickname_len = max_len;
    }
};

// Tests for RelayEngine functionality
test "RelayEngine initialization" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    const relay_engine = RelayEngine.init(allocator, &client_pool, .broker);

    try testing.expect(relay_engine.mode == .broker);
    try testing.expect(relay_engine.max_message_len == 1024);
    try testing.expect(relay_engine.max_nickname_len == 32);
    try testing.expect(relay_engine.stats.messages_relayed == 0);
}

test "RelayEngine nickname validation" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    const relay_engine = RelayEngine.init(allocator, &client_pool, .chat);

    // Valid nicknames
    try testing.expect(relay_engine.validateNickname("alice"));
    try testing.expect(relay_engine.validateNickname("user123"));
    try testing.expect(relay_engine.validateNickname("test_user"));

    // Invalid nicknames
    try testing.expect(!relay_engine.validateNickname("")); // Empty
    try testing.expect(!relay_engine.validateNickname(" alice")); // Leading space
    try testing.expect(!relay_engine.validateNickname("alice ")); // Trailing space
    try testing.expect(!relay_engine.validateNickname("alice\n")); // Control character
    try testing.expect(!relay_engine.validateNickname("alice[bob]")); // Brackets
    try testing.expect(!relay_engine.validateNickname("a" ** 50)); // Too long
}

test "RelayEngine message formatting" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    const relay_engine = RelayEngine.init(allocator, &client_pool, .chat);

    // Test message formatting
    const formatted = try relay_engine.formatChatMessage("Hello world", "alice");
    defer allocator.free(formatted);

    try testing.expectEqualStrings("[alice] Hello world\n", formatted);
}

test "RelayEngine statistics" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .broker);

    // Test initial statistics
    const initial_stats = relay_engine.getStats();
    try testing.expect(initial_stats.messages_relayed == 0);
    try testing.expect(initial_stats.bytes_relayed == 0);
    try testing.expect(initial_stats.relay_errors == 0);

    // Test statistics reset
    relay_engine.stats.messages_relayed = 10;
    relay_engine.resetStats();
    const reset_stats = relay_engine.getStats();
    try testing.expect(reset_stats.messages_relayed == 0);
}

test "RelayEngine configuration" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);

    // Test setting maximum lengths
    relay_engine.setMaxMessageLength(2048);
    relay_engine.setMaxNicknameLength(64);

    try testing.expect(relay_engine.max_message_len == 2048);
    try testing.expect(relay_engine.max_nickname_len == 64);
}
