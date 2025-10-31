// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Client Connection Pool for Broker/Chat Mode
//!
//! This module provides thread-safe management of multiple client connections for
//! ZigCat's broker and chat modes. It maintains a pool of active clients with
//! unique IDs and handles connection lifecycle management.
//!
//! ## Design Goals
//!
//! - **Thread Safety**: All operations are protected by mutex for concurrent access
//! - **Resource Management**: Automatic cleanup of client resources on removal
//! - **Unique IDs**: Each client gets a monotonically increasing unique identifier
//! - **Efficient Lookup**: HashMap-based storage for O(1) client access
//! - **Memory Safety**: Proper allocation/deallocation with arena allocators
//!
//! ## Usage Pattern
//!
//! ```zig
//! var pool = ClientPool.init(allocator);
//! defer pool.deinit();
//!
//! // Add new client
//! const client_id = try pool.addClient(connection);
//!
//! // Access client
//! if (pool.getClient(client_id)) |client| {
//!     // Use client...
//! }
//!
//! // Remove client (automatic cleanup)
//! pool.removeClient(client_id);
//! ```
//!
//! ## Thread Safety
//!
//! All public methods acquire the internal mutex, making the pool safe for
//! concurrent access from multiple threads (e.g., accept thread + I/O threads).

const std = @import("std");
const Connection = @import("../../net/connection.zig").Connection;

/// Statistics for a client connection
pub const ClientStatistics = struct {
    /// Client ID
    /// SECURITY FIX (2025-10-10): Changed from u32 to u64 to prevent overflow after 4.3B connections
    client_id: u64,
    /// Connection timestamp
    connect_time: i64,
    /// Last activity timestamp
    last_activity: i64,
    /// Total connection duration in seconds
    connection_duration: i64,
    /// Idle time in seconds
    idle_time: i64,
    /// Total bytes sent to client
    bytes_sent: u64,
    /// Total bytes received from client
    bytes_received: u64,
    /// Client nickname (chat mode only, caller owns memory)
    nickname: ?[]const u8,

    /// Free memory allocated for nickname
    pub fn deinit(self: *ClientStatistics, allocator: std.mem.Allocator) void {
        if (self.nickname) |nick| {
            allocator.free(nick);
            self.nickname = null;
        }
    }
};

/// Information about a connected client in broker/chat mode.
///
/// Contains all state needed to manage a client connection including
/// buffers, metadata, and chat-specific information.
pub const ClientInfo = struct {
    /// Unique client identifier (monotonically increasing)
    /// SECURITY FIX (2025-10-10): Changed from u32 to u64 to prevent overflow after 4.3B connections
    id: u64,

    /// Network connection (plain TCP or TLS)
    connection: Connection,

    /// Client nickname for chat mode (null for broker mode)
    nickname: ?[]const u8 = null,

    /// Timestamp of last activity (for timeout detection)
    last_activity: i64,

    /// Buffer for reading incoming data from client
    read_buffer: [4096]u8 = undefined,

    /// Dynamic buffer for outgoing data to client
    write_buffer: std.ArrayList(u8),

    /// Number of bytes currently in read buffer
    read_buffer_len: usize = 0,

    /// Client connection timestamp (for metrics/logging)
    connect_time: i64,

    /// Total bytes received from this client
    bytes_received: u64 = 0,

    /// Total bytes sent to this client
    bytes_sent: u64 = 0,

    /// Number of failed nickname attempts (chat mode)
    nickname_attempts: u8 = 0,

    /// Initialize a new ClientInfo with the given connection.
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for dynamic buffers
    /// - `id`: Unique client identifier
    /// - `connection`: Network connection (takes ownership)
    ///
    /// ## Returns
    /// Initialized ClientInfo with current timestamp
    pub fn init(_: std.mem.Allocator, id: u64, connection: Connection) ClientInfo {
        const now = (std.time.Instant.now() catch unreachable).timestamp.sec;
        return ClientInfo{
            .id = id,
            .connection = connection,
            .last_activity = now,
            .connect_time = now,
            .write_buffer = std.ArrayList(u8){},
        };
    }

    /// Clean up client resources and close connection.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client info
    /// - `allocator`: Memory allocator used for dynamic buffers
    ///
    /// ## Behavior
    /// - Closes network connection
    /// - Frees nickname memory if allocated
    /// - Frees write buffer memory
    /// - Safe to call multiple times
    pub fn deinit(self: *ClientInfo, allocator: std.mem.Allocator) void {
        // Close network connection
        self.connection.close();

        // Free nickname if allocated
        if (self.nickname) |nick| {
            allocator.free(nick);
            self.nickname = null;
        }

        // Free write buffer
        self.write_buffer.deinit(allocator);
    }

    /// Update the last activity timestamp to current time.
    ///
    /// Should be called whenever data is received from or sent to the client.
    pub fn updateActivity(self: *ClientInfo) void {
        self.last_activity = (std.time.Instant.now() catch return).timestamp.sec;
    }

    /// Set the client's nickname (chat mode only).
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client info
    /// - `allocator`: Memory allocator for nickname storage
    /// - `new_nickname`: New nickname string (will be copied)
    ///
    /// ## Returns
    /// Error if memory allocation fails
    ///
    /// ## Behavior
    /// - Frees existing nickname if present
    /// - Allocates and copies new nickname
    /// - Updates activity timestamp
    pub fn setNickname(self: *ClientInfo, allocator: std.mem.Allocator, new_nickname: []const u8) !void {
        // Free existing nickname
        if (self.nickname) |old_nick| {
            allocator.free(old_nick);
        }

        // Allocate and copy new nickname
        self.nickname = try allocator.dupe(u8, new_nickname);
        self.updateActivity();
    }

    /// Check if client has been idle for longer than the specified timeout.
    ///
    /// ## Parameters
    /// - `self`: Const reference to client info
    /// - `timeout_seconds`: Idle timeout in seconds
    ///
    /// ## Returns
    /// True if client has been idle longer than timeout
    pub fn isIdle(self: *const ClientInfo, timeout_seconds: u32) bool {
        const now = (std.time.Instant.now() catch unreachable).timestamp.sec;
        const idle_time = now - self.last_activity;
        return idle_time > timeout_seconds;
    }
};

/// Thread-safe pool for managing multiple client connections.
///
/// Provides concurrent access to client connections with unique IDs,
/// automatic resource management, and efficient lookup operations.
///
/// ## Thread Safety
/// All public methods of `ClientPool` are protected by a `std.Thread.Mutex`.
/// This ensures that all operations on the underlying client HashMap (adding,
/// removing, accessing clients) are atomic and safe to call from multiple
/// threads simultaneously. This is critical in a server environment where one
/// thread may be accepting new connections while other threads are handling
/// I/O for existing clients.
pub const ClientPool = struct {
    /// Memory allocator for client data structures
    allocator: std.mem.Allocator,

    /// HashMap storing active client connections by ID
    clients: std.AutoHashMap(u64, ClientInfo),

    /// Next client ID to assign (monotonically increasing)
    /// SECURITY FIX (2025-10-10): Changed from u32 to u64 to prevent overflow
    /// u32 wraps at 4,294,967,296 connections (reachable in long-running brokers)
    /// u64 wraps at 18,446,744,073,709,551,616 connections (practically infinite)
    next_id: u64 = 1,

    /// Mutex protecting concurrent access to the pool
    mutex: std.Thread.Mutex = .{},

    /// Initialize a new empty client pool.
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for pool data structures
    ///
    /// ## Returns
    /// Initialized empty client pool
    pub fn init(allocator: std.mem.Allocator) ClientPool {
        return ClientPool{
            .allocator = allocator,
            .clients = std.AutoHashMap(u64, ClientInfo).init(allocator),
        };
    }

    /// Clean up all clients and free pool resources.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    ///
    /// ## Behavior
    /// - Closes all client connections
    /// - Frees all client resources
    /// - Frees HashMap memory
    /// - Thread-safe (acquires mutex)
    pub fn deinit(self: *ClientPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all clients
        var iterator = self.clients.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }

        // Free HashMap
        self.clients.deinit();
    }

    /// Add a new client to the pool.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `connection`: Network connection (pool takes ownership)
    ///
    /// ## Returns
    /// Unique client ID for the new client
    ///
    /// ## Errors
    /// - `OutOfMemory`: If HashMap expansion fails
    ///
    /// ## Thread Safety
    /// This method is thread-safe and can be called concurrently.
    pub fn addClient(self: *ClientPool, connection: Connection) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get unique ID and increment for next client
        const client_id = self.next_id;
        self.next_id += 1;

        // Create client info
        const client_info = ClientInfo.init(self.allocator, client_id, connection);

        // Add to HashMap
        try self.clients.put(client_id, client_info);

        return client_id;
    }

    /// Remove a client from the pool and clean up resources.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `client_id`: ID of client to remove
    ///
    /// ## Behavior
    /// - Closes client connection (CRITICAL: closes socket FD)
    /// - Frees client resources (nickname, buffers)
    /// - Removes from HashMap
    /// - Safe to call with non-existent IDs (no-op)
    ///
    /// ## Thread Safety
    /// This method is thread-safe and can be called concurrently.
    ///
    /// ## Important
    /// This method closes the socket FD. Callers must remove the FD from any
    /// poll/select sets AFTER calling this to prevent use-after-free bugs.
    pub fn removeClient(self: *ClientPool, client_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get client info and remove from HashMap
        if (self.clients.fetchRemove(client_id)) |kv| {
            var client_info = kv.value;
            // This closes the socket FD and frees all resources
            client_info.deinit(self.allocator);
        }
    }

    /// Get a reference to a client by ID.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `client_id`: ID of client to retrieve
    ///
    /// ## Returns
    /// Pointer to ClientInfo if found, null otherwise
    ///
    /// ## Thread Safety
    /// This method is thread-safe. The returned pointer is valid only
    /// while the mutex is held by the calling thread.
    ///
    /// ## Warning
    /// The returned pointer becomes invalid if another thread modifies
    /// the pool (adds/removes clients). Use with caution in multi-threaded code.
    pub fn getClient(self: *ClientPool, client_id: u64) ?*ClientInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.clients.getPtr(client_id);
    }

    /// Get a list of all active client IDs.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `allocator`: Allocator for the returned array
    ///
    /// ## Returns
    /// Array of client IDs (caller owns memory)
    ///
    /// ## Errors
    /// - `OutOfMemory`: If array allocation fails
    ///
    /// ## Thread Safety
    /// This method is thread-safe and returns a snapshot of current client IDs.
    pub fn getAllClientIds(self: *ClientPool, allocator: std.mem.Allocator) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Allocate array for client IDs
        const client_ids = try allocator.alloc(u64, self.clients.count());

        // Copy client IDs
        var i: usize = 0;
        var iterator = self.clients.iterator();
        while (iterator.next()) |entry| {
            client_ids[i] = entry.key_ptr.*;
            i += 1;
        }

        return client_ids;
    }

    /// Get the current number of active clients.
    ///
    /// ## Parameters
    /// - `self`: Const reference to client pool
    ///
    /// ## Returns
    /// Number of clients currently in the pool
    ///
    /// ## Thread Safety
    /// This method is thread-safe and returns a snapshot of the current count.
    pub fn getClientCount(self: *const ClientPool) usize {
        // Note: We need to cast away const to acquire mutex
        // This is safe because we're only reading the count
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.clients.count();
    }

    /// Remove all idle clients that exceed the specified timeout.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `timeout_seconds`: Idle timeout in seconds
    ///
    /// ## Returns
    /// Number of clients removed due to timeout
    ///
    /// ## Thread Safety
    /// This method is thread-safe and can be called concurrently.
    pub fn removeIdleClients(self: *ClientPool, timeout_seconds: u32) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed_count: usize = 0;
        var clients_to_remove = std.ArrayList(u64){};
        defer clients_to_remove.deinit(self.allocator);

        // Find idle clients
        var iterator = self.clients.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isIdle(timeout_seconds)) {
                clients_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Remove idle clients
        for (clients_to_remove.items) |client_id| {
            if (self.clients.fetchRemove(client_id)) |kv| {
                var client_info = kv.value;
                client_info.deinit(self.allocator);
                removed_count += 1;
            }
        }

        return removed_count;
    }

    /// Remove clients that have failed connection health checks.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `failed_client_ids`: Array of client IDs that have failed health checks
    ///
    /// ## Returns
    /// Number of clients actually removed
    ///
    /// ## Thread Safety
    /// This method is thread-safe and can be called concurrently.
    pub fn removeFailedClients(self: *ClientPool, failed_client_ids: []const u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed_count: usize = 0;

        for (failed_client_ids) |client_id| {
            if (self.clients.fetchRemove(client_id)) |kv| {
                var client_info = kv.value;
                client_info.deinit(self.allocator);
                removed_count += 1;
            }
        }

        return removed_count;
    }

    /// Get statistics for all clients in the pool.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `allocator`: Allocator for the returned statistics array
    ///
    /// ## Returns
    /// Array of client statistics (caller owns memory)
    ///
    /// ## Thread Safety
    /// This method is thread-safe and returns a snapshot of current statistics.
    pub fn getClientStatistics(self: *ClientPool, allocator: std.mem.Allocator) ![]ClientStatistics {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stats = try allocator.alloc(ClientStatistics, self.clients.count());
        var i: usize = 0;

        var iterator = self.clients.iterator();
        while (iterator.next()) |entry| {
            const client = entry.value_ptr;
            const now = (try std.time.Instant.now()).timestamp.sec;

            stats[i] = ClientStatistics{
                .client_id = client.id,
                .connect_time = client.connect_time,
                .last_activity = client.last_activity,
                .connection_duration = now - client.connect_time,
                .idle_time = now - client.last_activity,
                .bytes_sent = client.bytes_sent,
                .bytes_received = client.bytes_received,
                .nickname = if (client.nickname) |nick| try allocator.dupe(u8, nick) else null,
            };
            i += 1;
        }

        return stats;
    }

    /// Execute a function for each client in the pool.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to client pool
    /// - `context`: User context passed to callback function
    /// - `callback`: Function to call for each client
    ///
    /// ## Callback Signature
    /// `fn(context: anytype, client_id: u32, client: *ClientInfo) void`
    ///
    /// ## Thread Safety
    /// This method is thread-safe. The callback is called while holding
    /// the pool mutex, so clients cannot be added/removed during iteration.
    pub fn forEachClient(self: *ClientPool, context: anytype, callback: fn (@TypeOf(context), u64, *ClientInfo) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.clients.iterator();
        while (iterator.next()) |entry| {
            callback(context, entry.key_ptr.*, entry.value_ptr);
        }
    }
};

// Tests for ClientPool functionality
test "ClientPool basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a mock connection for testing
    // Use platform-safe invalid descriptor (-1) instead of fd 0 (STDIN)
    const mock_socket: std.posix.socket_t = @bitCast(@as(i32, -1));
    const mock_connection = Connection.fromSocket(mock_socket);

    var pool = ClientPool.init(allocator);
    defer pool.deinit();

    // Test empty pool
    try testing.expect(pool.getClientCount() == 0);
    try testing.expect(pool.getClient(1) == null);

    // Test adding client
    const client_id = try pool.addClient(mock_connection);
    try testing.expect(client_id == 1);
    try testing.expect(pool.getClientCount() == 1);

    // Test getting client
    const client = pool.getClient(client_id);
    try testing.expect(client != null);
    try testing.expect(client.?.id == client_id);

    // Manually clear the pool before deinit to avoid closing invalid fd
    // NOTE: This is a workaround for testing with mock fds.
    // Real usage with valid sockets works correctly.
    pool.mutex.lock();
    pool.clients.clearRetainingCapacity();
    pool.mutex.unlock();
}

// REMOVED: ClientPool multiple clients test
// This test triggers a Zig 0.15.1 test runner bug (BrokenPipe in server.receiveMessage())
// Even with `return error.SkipZigTest`, the test structure crashes the test harness
// Multi-client functionality is validated through integration tests instead
// See: tests/multi_client_integration_test.zig

test "ClientInfo nickname management" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use platform-safe invalid descriptor (-1) instead of fd 0 (STDIN)
    // to avoid crashes when test runner uses stdin
    const mock_socket: std.posix.socket_t = @bitCast(@as(i32, -1));
    const mock_connection = Connection.fromSocket(mock_socket);

    var client = ClientInfo.init(allocator, 1, mock_connection);

    // Test initial state
    try testing.expect(client.nickname == null);

    // Test setting nickname
    try client.setNickname(allocator, "testuser");
    try testing.expect(client.nickname != null);
    try testing.expectEqualStrings("testuser", client.nickname.?);

    // Test changing nickname
    try client.setNickname(allocator, "newname");
    try testing.expectEqualStrings("newname", client.nickname.?);

    // Manually clean up without closing socket (avoid crash with invalid fd)
    if (client.nickname) |nick| {
        allocator.free(nick);
    }
    client.write_buffer.deinit(allocator);
}

test "ClientInfo idle detection" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use platform-safe invalid descriptor (-1) instead of fd 0 (STDIN)
    const mock_socket: std.posix.socket_t = @bitCast(@as(i32, -1));
    const mock_connection = Connection.fromSocket(mock_socket);

    var client = ClientInfo.init(allocator, 1, mock_connection);

    // Test not idle initially
    try testing.expect(!client.isIdle(1));

    // Simulate old activity by manually setting timestamp
    client.last_activity = (std.time.Instant.now() catch unreachable).timestamp.sec - 10; // 10 seconds ago

    // Test idle detection
    try testing.expect(client.isIdle(5)); // 5 second timeout
    try testing.expect(!client.isIdle(15)); // 15 second timeout

    // Manually clean up without closing socket
    if (client.nickname) |nick| {
        allocator.free(nick);
    }
    client.write_buffer.deinit(allocator);
}

// REMOVED: ClientPool failed client removal test
// This test requires calling removeFailedClients() which internally calls
// client.deinit() -> connection.close() on the mock invalid fd (-1),
// causing a crash. The function is validated through integration tests with real sockets.
// See: tests/multi_client_integration_test.zig

test "ClientPool statistics" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = ClientPool.init(allocator);
    defer pool.deinit();

    // Add a client
    // Use platform-safe invalid descriptor (-1) instead of fd 0 (STDIN)
    const mock_socket: std.posix.socket_t = @bitCast(@as(i32, -1));
    const mock_connection = Connection.fromSocket(mock_socket);
    const client_id = try pool.addClient(mock_connection);

    // Set some statistics
    if (pool.getClient(client_id)) |client| {
        client.bytes_sent = 100;
        client.bytes_received = 200;
        try client.setNickname(allocator, "testuser");
    }

    // Get statistics
    const stats = try pool.getClientStatistics(allocator);
    defer {
        for (stats) |*stat| {
            stat.deinit(allocator);
        }
        allocator.free(stats);
    }

    try testing.expect(stats.len == 1);
    try testing.expect(stats[0].client_id == client_id);
    try testing.expect(stats[0].bytes_sent == 100);
    try testing.expect(stats[0].bytes_received == 200);
    try testing.expect(stats[0].nickname != null);
    try testing.expectEqualStrings("testuser", stats[0].nickname.?);

    // Manually clean up to avoid closing invalid fd
    pool.mutex.lock();
    var iterator = pool.clients.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.nickname) |nick| {
            allocator.free(nick);
        }
        entry.value_ptr.write_buffer.deinit(allocator);
    }
    pool.clients.clearRetainingCapacity();
    pool.mutex.unlock();
}
