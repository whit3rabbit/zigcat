// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Fixed-size buffer pool for io_uring provided buffers.
//!
//! This module implements a buffer pool manager that:
//! - Pre-allocates a contiguous block of memory for all buffers
//! - Provides buffer IDs for use with IORING_OP_PROVIDE_BUFFERS
//! - Tracks buffer availability with a free list
//! - Enables zero-copy buffer management
//!
//! ## Architecture
//!
//! ```
//! Storage (single allocation):
//! ┌────────┬────────┬────────┬────────┐
//! │ Buf 0  │ Buf 1  │ Buf 2  │ Buf 3  │ ... (16 buffers × 8KB each)
//! └────────┴────────┴────────┴────────┘
//!
//! Free List (ArrayList of buffer IDs):
//! [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
//!
//! After acquireBuffer() x3:
//! [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]  // Buffers 0,1,2 in use
//! ```
//!
//! ## Usage
//!
//! ```zig
//! var pool = try FixedBufferPool.init(allocator, 16, 8192, 0);
//! defer pool.deinit();
//!
//! // Acquire a buffer
//! const buffer_id = pool.acquireBuffer() orelse return error.PoolExhausted;
//!
//! // Use the buffer
//! const buffer_slice = pool.getBuffer(buffer_id);
//! const bytes_read = try socket.read(buffer_slice);
//!
//! // Return buffer to pool when done
//! try pool.releaseBuffer(buffer_id);
//! ```

const std = @import("std");

/// Default number of buffers in a pool (16 × 8KB = 128KB per pool)
pub const DEFAULT_BUFFER_COUNT: u16 = 16;

/// Default size of each buffer (8KB matches typical TCP receive window)
pub const DEFAULT_BUFFER_SIZE: usize = 8192;

/// Maximum number of buffer groups (stdin, stdout, stderr)
pub const MAX_BUFFER_GROUPS: u8 = 3;

/// Errors for buffer pool operations
pub const BufferPoolError = error{
    /// Attempted to release a buffer that's already free
    BufferAlreadyFree,
    /// Attempted to release an invalid buffer ID
    InvalidBufferId,
    /// All buffers are in use
    PoolExhausted,
};

/// Fixed-size buffer pool for io_uring provided buffers.
///
/// Manages a pre-allocated contiguous block of memory subdivided into
/// fixed-size buffers. Tracks buffer availability with a free list and
/// provides buffer IDs for use with io_uring's provided buffer mechanism.
///
/// ## Memory Layout
///
/// The pool allocates a single large buffer (buffer_count × buffer_size)
/// and logically divides it into fixed-size chunks. This ensures:
/// - Single allocation (efficient, reduces fragmentation)
/// - Contiguous memory (better cache locality)
/// - Easy registration with io_uring (single memory range)
///
/// ## Thread Safety
///
/// This struct is **not thread-safe**. It's designed for single-threaded
/// use within an ExecSession. Each session has its own buffer pools.
pub const FixedBufferPool = struct {
    allocator: std.mem.Allocator,
    storage: []u8, // Single large allocation
    buffer_size: usize,
    buffer_count: u16,
    bgid: u16, // Buffer Group ID for io_uring
    free_list: std.ArrayList(u16), // Available buffer IDs

    /// Initialize a buffer pool with specified parameters.
    ///
    /// Allocates a single contiguous block of memory and populates the
    /// free list with all buffer IDs (0 to buffer_count - 1).
    ///
    /// Parameters:
    ///   allocator: Memory allocator for pool storage and free list
    ///   buffer_count: Number of buffers (1-65535)
    ///   buffer_size: Size of each buffer in bytes (must be > 0)
    ///   bgid: Buffer Group ID for io_uring registration (0-65535)
    ///
    /// Returns: Initialized buffer pool or allocation error
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to allocate storage or free list
    ///
    /// Example:
    /// ```zig
    /// // Create pool for stdin: 16 buffers × 8KB, BGID 0
    /// var stdin_pool = try FixedBufferPool.init(allocator, 16, 8192, 0);
    /// defer stdin_pool.deinit();
    /// ```
    pub fn init(
        allocator: std.mem.Allocator,
        buffer_count: u16,
        buffer_size: usize,
        bgid: u16,
    ) !FixedBufferPool {
        if (buffer_count == 0) {
            return error.InvalidConfiguration;
        }
        if (buffer_size == 0) {
            return error.InvalidConfiguration;
        }

        // Allocate single large buffer
        const total_size = @as(usize, buffer_count) * buffer_size;
        const storage = try allocator.alloc(u8, total_size);
        errdefer allocator.free(storage);

        // Initialize free list with all buffer IDs
        var free_list = try std.ArrayList(u16).initCapacity(allocator, buffer_count);
        errdefer free_list.deinit(allocator);

        var i: u16 = 0;
        while (i < buffer_count) : (i += 1) {
            try free_list.append(allocator, i);
        }

        return FixedBufferPool{
            .allocator = allocator,
            .storage = storage,
            .buffer_size = buffer_size,
            .buffer_count = buffer_count,
            .bgid = bgid,
            .free_list = free_list,
        };
    }

    /// Release all resources associated with the buffer pool.
    ///
    /// Frees the storage buffer and the free list. After calling deinit(),
    /// the pool must not be used.
    pub fn deinit(self: *FixedBufferPool) void {
        self.allocator.free(self.storage);
        self.free_list.deinit(self.allocator);
        self.storage = &[_]u8{};
        self.buffer_count = 0;
    }

    /// Acquire a buffer from the pool.
    ///
    /// Removes a buffer ID from the free list and returns it. The caller
    /// is responsible for returning the buffer via releaseBuffer() when done.
    ///
    /// Returns: Buffer ID (0 to buffer_count - 1) or null if pool exhausted
    ///
    /// Example:
    /// ```zig
    /// const buffer_id = pool.acquireBuffer() orelse {
    ///     std.debug.print("Pool exhausted! All buffers in use\n", .{});
    ///     return error.PoolExhausted;
    /// };
    /// defer pool.releaseBuffer(buffer_id) catch {}; // Return on error
    /// ```
    pub fn acquireBuffer(self: *FixedBufferPool) ?u16 {
        if (self.free_list.items.len == 0) {
            return null; // Pool exhausted
        }
        return self.free_list.pop();
    }

    /// Return a buffer to the pool.
    ///
    /// Adds the buffer ID back to the free list, making it available for
    /// future acquisitions. The buffer must have been previously acquired
    /// via acquireBuffer().
    ///
    /// Parameters:
    ///   buffer_id: Buffer ID to release (must be valid and not already free)
    ///
    /// Errors:
    ///   - error.InvalidBufferId: Buffer ID is out of range
    ///   - error.BufferAlreadyFree: Buffer is already in the free list
    ///
    /// Example:
    /// ```zig
    /// const buffer_id = try pool.acquireBuffer() orelse return error.PoolExhausted;
    /// // ... use buffer ...
    /// try pool.releaseBuffer(buffer_id);
    /// ```
    pub fn releaseBuffer(self: *FixedBufferPool, buffer_id: u16) !void {
        // Validate buffer ID
        if (buffer_id >= self.buffer_count) {
            return BufferPoolError.InvalidBufferId;
        }

        // Check if buffer is already free (double-release detection)
        for (self.free_list.items) |free_id| {
            if (free_id == buffer_id) {
                return BufferPoolError.BufferAlreadyFree;
            }
        }

        // Add back to free list
        try self.free_list.append(self.allocator, buffer_id);
    }

    /// Get a mutable slice for the specified buffer.
    ///
    /// Returns a slice into the storage array corresponding to the buffer ID.
    /// The slice is valid until deinit() is called on the pool.
    ///
    /// Parameters:
    ///   buffer_id: Buffer ID (must be < buffer_count)
    ///
    /// Returns: Mutable slice of size buffer_size
    ///
    /// Panics: In debug mode, panics if buffer_id >= buffer_count
    ///
    /// Example:
    /// ```zig
    /// const buffer_id = pool.acquireBuffer() orelse return error.PoolExhausted;
    /// const buffer = pool.getBuffer(buffer_id);
    /// const bytes_read = try socket.read(buffer);
    /// ```
    pub fn getBuffer(self: *FixedBufferPool, buffer_id: u16) []u8 {
        std.debug.assert(buffer_id < self.buffer_count);
        const start = @as(usize, buffer_id) * self.buffer_size;
        const end = start + self.buffer_size;
        return self.storage[start..end];
    }

    /// Get a const slice for the specified buffer.
    ///
    /// Similar to getBuffer() but returns a const slice for read-only access.
    ///
    /// Parameters:
    ///   buffer_id: Buffer ID (must be < buffer_count)
    ///
    /// Returns: Const slice of size buffer_size
    ///
    /// Panics: In debug mode, panics if buffer_id >= buffer_count
    pub fn getConstBuffer(self: *const FixedBufferPool, buffer_id: u16) []const u8 {
        std.debug.assert(buffer_id < self.buffer_count);
        const start = @as(usize, buffer_id) * self.buffer_size;
        const end = start + self.buffer_size;
        return self.storage[start..end];
    }

    /// Get the number of buffers currently available.
    ///
    /// Returns: Count of buffers in the free list
    pub fn availableBuffers(self: *const FixedBufferPool) usize {
        return self.free_list.items.len;
    }

    /// Get the number of buffers currently in use.
    ///
    /// Returns: Count of buffers not in the free list
    pub fn buffersInUse(self: *const FixedBufferPool) usize {
        return self.buffer_count - self.free_list.items.len;
    }

    /// Check if the pool is exhausted (all buffers in use).
    ///
    /// Returns: true if no buffers are available, false otherwise
    pub fn isExhausted(self: *const FixedBufferPool) bool {
        return self.free_list.items.len == 0;
    }
};

// ========================================================================
// Tests
// ========================================================================

test "FixedBufferPool: init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 8, 4096, 0);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 8), pool.buffer_count);
    try testing.expectEqual(@as(usize, 4096), pool.buffer_size);
    try testing.expectEqual(@as(u16, 0), pool.bgid);
    try testing.expectEqual(@as(usize, 8), pool.availableBuffers());
    try testing.expectEqual(@as(usize, 0), pool.buffersInUse());
}

test "FixedBufferPool: acquire and release" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    // Acquire all buffers
    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id1 = pool.acquireBuffer() orelse return error.TestFailed;
    const id2 = pool.acquireBuffer() orelse return error.TestFailed;
    const id3 = pool.acquireBuffer() orelse return error.TestFailed;

    try testing.expectEqual(@as(usize, 0), pool.availableBuffers());
    try testing.expectEqual(@as(usize, 4), pool.buffersInUse());
    try testing.expect(pool.isExhausted());

    // Pool exhausted
    try testing.expectEqual(@as(?u16, null), pool.acquireBuffer());

    // Release one buffer
    try pool.releaseBuffer(id0);
    try testing.expectEqual(@as(usize, 1), pool.availableBuffers());

    // Can acquire again
    const id_reused = pool.acquireBuffer() orelse return error.TestFailed;
    try testing.expectEqual(id0, id_reused);

    // Release all
    try pool.releaseBuffer(id1);
    try pool.releaseBuffer(id2);
    try pool.releaseBuffer(id3);
    try testing.expectEqual(@as(usize, 3), pool.availableBuffers());
}

test "FixedBufferPool: double release detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    const id = pool.acquireBuffer() orelse return error.TestFailed;
    try pool.releaseBuffer(id);

    // Attempting to release again should error
    try testing.expectError(BufferPoolError.BufferAlreadyFree, pool.releaseBuffer(id));
}

test "FixedBufferPool: invalid buffer ID" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    // Buffer ID 4 is out of range (valid: 0-3)
    try testing.expectError(BufferPoolError.InvalidBufferId, pool.releaseBuffer(4));
    try testing.expectError(BufferPoolError.InvalidBufferId, pool.releaseBuffer(100));
}

test "FixedBufferPool: getBuffer returns correct slices" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id3 = pool.acquireBuffer() orelse return error.TestFailed;

    const buf0 = pool.getBuffer(id0);
    const buf3 = pool.getBuffer(id3);

    // Buffers should be distinct and correct size
    try testing.expectEqual(@as(usize, 1024), buf0.len);
    try testing.expectEqual(@as(usize, 1024), buf3.len);
    try testing.expect(@intFromPtr(buf0.ptr) != @intFromPtr(buf3.ptr));

    // Write to one buffer should not affect the other
    @memset(buf0, 0xAA);
    @memset(buf3, 0xBB);

    try testing.expectEqual(@as(u8, 0xAA), buf0[0]);
    try testing.expectEqual(@as(u8, 0xBB), buf3[0]);
}

test "FixedBufferPool: stress test" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 16, 4096, 0);
    defer pool.deinit();

    var acquired = std.ArrayList(u16).init(allocator);
    defer acquired.deinit(allocator);

    // Acquire all buffers
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const id = pool.acquireBuffer() orelse return error.TestFailed;
        try acquired.append(allocator, id);
    }

    try testing.expect(pool.isExhausted());

    // Release all buffers
    for (acquired.items) |id| {
        try pool.releaseBuffer(id);
    }

    try testing.expectEqual(@as(usize, 16), pool.availableBuffers());
    try testing.expectEqual(@as(usize, 0), pool.buffersInUse());
}
