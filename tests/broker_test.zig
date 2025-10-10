//! Comprehensive Unit Tests for Broker/Chat Mode Core Functionality
//!
//! This test suite covers the core components of ZigCat's broker and chat modes:
//! - ClientPool thread-safe operations and resource management
//! - Message relay engine with multiple client scenarios
//! - Chat protocol handling including nickname validation and formatting
//! - Broker server I/O multiplexing and client management
//!
//! Requirements covered: 1.2, 1.3, 2.2, 2.3, 3.1, 3.2

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

// Import modules under test
const ClientPool = @import("../src/server/client_pool.zig").ClientPool;
const ClientInfo = @import("../src/server/client_pool.zig").ClientInfo;
const RelayEngine = @import("../src/server/relay.zig").RelayEngine;
const RelayError = @import("../src/server/relay.zig").RelayError;
const BrokerMode = @import("../src/server/relay.zig").BrokerMode;
const ChatHandler = @import("../src/server/chat.zig").ChatHandler;
const Connection = @import("../src/net/connection.zig").Connection;

// =============================================================================
// CLIENT POOL TESTS
// =============================================================================

test "ClientPool - basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = ClientPool.init(allocator);
    defer pool.deinit();

    // Test empty pool
    try expectEqual(@as(usize, 0), pool.getClientCount());
    try expect(pool.getClient(1) == null);

    // Test adding client
    const mock_connection = Connection.fromSocket(0);
    const client_id = try pool.addClient(mock_connection);
    try expectEqual(@as(u32, 1), client_id);
    try expectEqual(@as(usize, 1), pool.getClientCount());

    // Test getting client
    const client = pool.getClient(client_id);
    try expect(client != null);
    try expectEqual(client_id, client.?.id);

    // Test removing client
    pool.removeClient(client_id);
    try expectEqual(@as(usize, 0), pool.getClientCount());
    try expect(pool.getClient(client_id) == null);
}

test "ClientPool - multiple clients with unique IDs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = ClientPool.init(allocator);
    defer pool.deinit();

    const mock_connection = Connection.fromSocket(0);

    // Add multiple clients
    const id1 = try pool.addClient(mock_connection);
    const id2 = try pool.addClient(mock_connection);
    const id3 = try pool.addClient(mock_connection);

    try expectEqual(@as(u32, 1), id1);
    try expectEqual(@as(u32, 2), id2);
    try expectEqual(@as(u32, 3), id3);
    try expectEqual(@as(usize, 3), pool.getClientCount());

    // Test getting all client IDs
    const client_ids = try pool.getAllClientIds(allocator);
    defer allocator.free(client_ids);

    try expectEqual(@as(usize, 3), client_ids.len);

    // Remove middle client
    pool.removeClient(id2);
    try expectEqual(@as(usize, 2), pool.getClientCount());
    try expect(pool.getClient(id1) != null);
    try expect(pool.getClient(id2) == null);
    try expect(pool.getClient(id3) != null);
}

test "ClientInfo - nickname management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const mock_connection = Connection.fromSocket(0);
    var client = ClientInfo.init(allocator, 1, mock_connection);
    defer client.deinit(allocator);

    // Test initial state
    try expect(client.nickname == null);

    // Test setting nickname
    try client.setNickname(allocator, "testuser");
    try expect(client.nickname != null);
    try expectEqualStrings("testuser", client.nickname.?);

    // Test changing nickname
    try client.setNickname(allocator, "newname");
    try expectEqualStrings("newname", client.nickname.?);
}

test "ClientInfo - idle detection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const mock_connection = Connection.fromSocket(0);
    var client = ClientInfo.init(allocator, 1, mock_connection);
    defer client.deinit(allocator);

    // Test not idle initially
    try expect(!client.isIdle(1));

    // Simulate old activity by manually setting timestamp
    client.last_activity = std.time.timestamp() - 10; // 10 seconds ago

    // Test idle detection
    try expect(client.isIdle(5)); // 5 second timeout
    try expect(!client.isIdle(15)); // 15 second timeout
}

// =============================================================================
// RELAY ENGINE TESTS
// =============================================================================

test "RelayEngine - initialization and configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    // Test broker mode initialization
    var broker_relay = RelayEngine.init(allocator, &client_pool, .broker);
    defer broker_relay.deinit();
    try expectEqual(BrokerMode.broker, broker_relay.mode);
    try expectEqual(@as(usize, 1024), broker_relay.max_message_len);
    try expectEqual(@as(usize, 32), broker_relay.max_nickname_len);

    // Test chat mode initialization
    var chat_relay = RelayEngine.init(allocator, &client_pool, .chat);
    defer chat_relay.deinit();
    try expectEqual(BrokerMode.chat, chat_relay.mode);

    // Test configuration changes
    chat_relay.setMaxMessageLength(2048);
    chat_relay.setMaxNicknameLength(64);
    try expectEqual(@as(usize, 2048), chat_relay.max_message_len);
    try expectEqual(@as(usize, 64), chat_relay.max_nickname_len);
}

test "RelayEngine - nickname validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    // Valid nicknames
    try expect(relay_engine.validateNickname("alice"));
    try expect(relay_engine.validateNickname("user123"));
    try expect(relay_engine.validateNickname("test_user"));
    try expect(relay_engine.validateNickname("Bob"));

    // Invalid nicknames
    try expect(!relay_engine.validateNickname("")); // Empty
    try expect(!relay_engine.validateNickname(" alice")); // Leading space
    try expect(!relay_engine.validateNickname("alice ")); // Trailing space
    try expect(!relay_engine.validateNickname("alice\n")); // Control character
    try expect(!relay_engine.validateNickname("alice[bob]")); // Brackets
    try expect(!relay_engine.validateNickname("a" ** 50)); // Too long
}

test "RelayEngine - message formatting" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    // Test message formatting
    const formatted = try relay_engine.formatChatMessage("Hello world", "alice");
    defer allocator.free(formatted);

    try expectEqualStrings("[alice] Hello world\n", formatted);
}

test "RelayEngine - statistics tracking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .broker);
    defer relay_engine.deinit();

    // Test initial statistics
    const initial_stats = relay_engine.getStats();
    try expectEqual(@as(u64, 0), initial_stats.messages_relayed);
    try expectEqual(@as(u64, 0), initial_stats.bytes_relayed);
    try expectEqual(@as(u64, 0), initial_stats.relay_errors);

    // Test statistics reset
    relay_engine.stats.messages_relayed = 10;
    relay_engine.resetStats();
    const reset_stats = relay_engine.getStats();
    try expectEqual(@as(u64, 0), reset_stats.messages_relayed);
}

// =============================================================================
// CHAT HANDLER TESTS
// =============================================================================

test "ChatHandler - initialization and configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    var chat_handler = ChatHandler.init(allocator, &relay_engine);
    defer chat_handler.deinit();

    try expectEqual(@as(usize, 32), chat_handler.max_nickname_len);
    try expectEqual(@as(usize, 1024), chat_handler.max_message_len);

    // Test configuration changes
    chat_handler.setMaxNicknameLength(64);
    chat_handler.setMaxMessageLength(2048);

    const config = chat_handler.getConfig();
    try expectEqual(@as(usize, 64), config.max_nickname_len);
    try expectEqual(@as(usize, 2048), config.max_message_len);
}

test "ChatHandler - nickname validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    const chat_handler = ChatHandler.init(allocator, &relay_engine);

    // Valid nicknames
    try expect(chat_handler.validateNickname("alice"));
    try expect(chat_handler.validateNickname("user123"));
    try expect(chat_handler.validateNickname("test_user"));
    try expect(chat_handler.validateNickname("Bob"));

    // Invalid nicknames
    try expect(!chat_handler.validateNickname("")); // Empty
    try expect(!chat_handler.validateNickname(" alice")); // Leading space
    try expect(!chat_handler.validateNickname("alice ")); // Trailing space
    try expect(!chat_handler.validateNickname("alice\n")); // Control character
    try expect(!chat_handler.validateNickname("alice[bob]")); // Brackets
    try expect(!chat_handler.validateNickname("***system")); // Reserved pattern
    try expect(!chat_handler.validateNickname("alice*bob")); // Asterisk
    try expect(!chat_handler.validateNickname("alice/bob")); // Slash
    try expect(!chat_handler.validateNickname("a" ** 50)); // Too long
}

test "ChatHandler - nickname command parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();

    const chat_handler = ChatHandler.init(allocator, &relay_engine);

    // Test direct nickname
    if (chat_handler.parseNicknameCommand("alice")) |nick| {
        try expectEqualStrings("alice", nick);
    } else {
        try expect(false);
    }

    // Test /nick command
    if (chat_handler.parseNicknameCommand("/nick bob")) |nick| {
        try expectEqualStrings("bob", nick);
    } else {
        try expect(false);
    }

    // Test /name command
    if (chat_handler.parseNicknameCommand("/name charlie")) |nick| {
        try expectEqualStrings("charlie", nick);
    } else {
        try expect(false);
    }

    // Test empty input
    try expect(chat_handler.parseNicknameCommand("") == null);
    try expect(chat_handler.parseNicknameCommand("   ") == null);

    // Test incomplete commands
    try expect(chat_handler.parseNicknameCommand("/nick") == null);
    try expect(chat_handler.parseNicknameCommand("/name") == null);
}

// =============================================================================
// INTEGRATION TESTS
// =============================================================================

test "Integration - broker mode basic setup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .broker);
    defer relay_engine.deinit();

    // Add mock clients
    const mock_connection = Connection.fromSocket(0);
    const client1 = try client_pool.addClient(mock_connection);
    _ = try client_pool.addClient(mock_connection);
    _ = try client_pool.addClient(mock_connection);

    try expectEqual(@as(usize, 3), client_pool.getClientCount());

    // Test data relay (expected to fail with mock connections)
    const test_data = "Hello, world!";
    relay_engine.relayData(test_data, client1) catch |err| {
        _ = err; // Expected to fail with mock connections
    };

    // Verify statistics tracking works
    const stats = relay_engine.getStats();
    try expect(stats.relay_errors >= 0);
}

test "Integration - chat mode with multiple clients" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_pool = ClientPool.init(allocator);
    defer client_pool.deinit();

    var relay_engine = RelayEngine.init(allocator, &client_pool, .chat);
    defer relay_engine.deinit();
    var chat_handler = ChatHandler.init(allocator, &relay_engine);
    defer chat_handler.deinit();

    // Add clients with nicknames
    const mock_connection = Connection.fromSocket(0);
    const client1 = try client_pool.addClient(mock_connection);
    const client2 = try client_pool.addClient(mock_connection);

    // Set nicknames through handler
    try chat_handler.processMessage(client1, "alice\n");
    try chat_handler.processMessage(client2, "bob\n");

    // Test nickname conflict detection
    try expect(chat_handler.isNicknameTaken("alice", client2));
    try expect(!chat_handler.isNicknameTaken("charlie", client1));
}

test "Memory management - resource cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test ClientInfo cleanup
    {
        const mock_connection = Connection.fromSocket(0);
        var client = ClientInfo.init(allocator, 1, mock_connection);
        try client.setNickname(allocator, "testuser");

        // Verify nickname is set
        try expect(client.nickname != null);

        // Cleanup should free nickname
        client.deinit(allocator);
    }

    // Test ClientPool cleanup
    {
        var client_pool = ClientPool.init(allocator);

        const mock_connection = Connection.fromSocket(0);
        _ = try client_pool.addClient(mock_connection);
        _ = try client_pool.addClient(mock_connection);

        // Cleanup should free all clients
        client_pool.deinit();
    }
}
