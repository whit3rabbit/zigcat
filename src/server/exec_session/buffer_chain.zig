// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Buffer chain abstraction for managing discrete buffers as a logical stream.
//!
//! This module solves the core challenge of io_uring provided buffers: data
//! arrives in discrete fixed-size chunks (e.g., 8KB buffers), but applications
//! expect a continuous stream interface.
//!
//! ## The Problem
//!
//! ```
//! Traditional Stream (IoRingBuffer):
//! ┌────────────────────────────────────┐
//! │ █████████████████████████████      │  ← Continuous, single buffer
//! └────────────────────────────────────┘
//!
//! Provided Buffers:
//! ┌────────┐  ┌────────┐  ┌────────┐
//! │ Buffer │  │ Buffer │  │ Buffer │  ← Discrete, multiple buffers
//! │   #3   │  │   #7   │  │   #12  │
//! └────────┘  └────────┘  └────────┘
//! ```
//!
//! ## The Solution: BufferChain
//!
//! BufferChain links discrete buffer segments into a logical stream:
//!
//! ```
//! Segments: [
//!   { buffer_id: 3, offset: 0, len: 8192 },   ← 8KB full
//!   { buffer_id: 7, offset: 0, len: 4096 },   ← 4KB used
//!   { buffer_id: 12, offset: 0, len: 8192 },  ← 8KB full
//! ]
//! Total bytes available: 20480 (20KB)
//!
//! After consume(10000):
//! Segments: [
//!   { buffer_id: 7, offset: 1808, len: 2288 },  ← Partial segment
//!   { buffer_id: 12, offset: 0, len: 8192 },
//! ]
//! Total bytes available: 10480
//! (Buffers 3 and part of 7 returned to pool)
//! ```
//!
//! ## Usage
//!
//! ```zig
//! var chain = try BufferChain.init(allocator);
//! defer chain.deinit();
//!
//! // Data arrives from io_uring with buffer ID
//! try chain.append(buffer_id, bytes_received);
//!
//! // Get first readable chunk (for writing to socket)
//! while (chain.totalAvailable() > 0) {
//!     const slice = try chain.firstReadableSlice(pool);
//!     const written = try socket.write(slice);
//!     try chain.consume(written, pool);  // Returns buffers when fully consumed
//! }
//! ```

const std = @import("std");
const FixedBufferPool = @import("./buffer_pool.zig").FixedBufferPool;

/// A single segment in the buffer chain.
///
/// Represents a buffer (by ID) with an offset and length, allowing
/// partial consumption of buffers.
pub const Segment = struct {
    buffer_id: u16, // ID in the buffer pool
    offset: usize, // Start offset within the buffer
    len: usize, // Valid bytes from offset

    /// Check if this segment is fully consumed.
    pub fn isEmpty(self: Segment) bool {
        return self.len == 0;
    }
};

/// Buffer chain for managing discrete buffers as a logical stream.
///
/// This struct maintains an ordered list of buffer segments, tracking
/// the offset and length within each buffer. As data is consumed from
/// the front, buffers are automatically returned to the pool.
///
/// ## Memory Management
///
/// - The chain owns the list of segments but not the buffers themselves
/// - Buffers are owned by the FixedBufferPool
/// - When a segment is fully consumed, its buffer is returned to the pool
/// - The caller must ensure buffers are returned even on error paths
///
/// ## Thread Safety
///
/// This struct is **not thread-safe**. It's designed for single-threaded
/// use within an ExecSession.
pub const BufferChain = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment),
    total_bytes: usize, // Cache of total available bytes

    /// Initialize an empty buffer chain.
    ///
    /// Parameters:
    ///   allocator: Memory allocator for the segment list
    ///
    /// Returns: Initialized empty chain
    pub fn init(allocator: std.mem.Allocator) !BufferChain {
        return BufferChain{
            .allocator = allocator,
            .segments = std.ArrayList(Segment){},
            .total_bytes = 0,
        };
    }

    /// Release all resources.
    ///
    /// **CRITICAL**: This does NOT return buffers to the pool. The caller
    /// must ensure all buffers are consumed or explicitly returned before
    /// calling deinit().
    pub fn deinit(self: *BufferChain) void {
        self.segments.deinit(self.allocator);
        self.total_bytes = 0;
    }

    /// Append a new buffer segment to the end of the chain.
    ///
    /// The buffer is added with offset=0, meaning the entire buffer
    /// from [0..len) contains valid data.
    ///
    /// Parameters:
    ///   buffer_id: Buffer ID from the pool
    ///   len: Number of valid bytes in the buffer (1 to buffer_size)
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to allocate space for the segment
    ///
    /// Example:
    /// ```zig
    /// // io_uring completion: buffer_id=5, bytes_read=4096
    /// try chain.append(5, 4096);
    /// ```
    pub fn append(self: *BufferChain, buffer_id: u16, len: usize) !void {
        if (len == 0) return; // Ignore empty buffers

        try self.segments.append(self.allocator, Segment{
            .buffer_id = buffer_id,
            .offset = 0,
            .len = len,
        });
        self.total_bytes += len;
    }

    /// Consume bytes from the front of the chain.
    ///
    /// Removes `amount` bytes from the chain, updating segment offsets
    /// and returning fully-consumed buffers to the pool.
    ///
    /// Behavior:
    /// - If amount < first segment length: Update offset/len
    /// - If amount >= first segment length: Remove segment, return buffer
    /// - If amount spans multiple segments: Remove/update multiple segments
    ///
    /// Parameters:
    ///   amount: Number of bytes to consume
    ///   pool: Buffer pool to return consumed buffers to
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to return buffer to pool (rare)
    ///
    /// Example:
    /// ```zig
    /// const slice = try chain.firstReadableSlice(pool);
    /// const written = try socket.write(slice);
    /// try chain.consume(written, pool);  // May return 0-N buffers
    /// ```
    pub fn consume(self: *BufferChain, amount: usize, pool: *FixedBufferPool) !void {
        if (amount == 0) return;
        if (amount > self.total_bytes) {
            // Consume all available bytes
            return self.consumeAll(pool);
        }

        var remaining = amount;

        while (remaining > 0 and self.segments.items.len > 0) {
            var segment = &self.segments.items[0];

            if (remaining < segment.len) {
                // Partial consumption: Update segment offset/len
                segment.offset += remaining;
                segment.len -= remaining;
                self.total_bytes -= remaining;
                return;
            }

            // Full segment consumption: Remove and return buffer
            const consumed = segment.len;
            const buffer_id = segment.buffer_id;

            _ = self.segments.orderedRemove(0);
            self.total_bytes -= consumed;
            remaining -= consumed;

            // Return buffer to pool
            try pool.releaseBuffer(buffer_id);
        }
    }

    /// Consume all bytes in the chain, returning all buffers to the pool.
    ///
    /// After this call, the chain will be empty (totalAvailable() == 0).
    ///
    /// Parameters:
    ///   pool: Buffer pool to return buffers to
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to return buffer to pool
    pub fn consumeAll(self: *BufferChain, pool: *FixedBufferPool) !void {
        for (self.segments.items) |segment| {
            try pool.releaseBuffer(segment.buffer_id);
        }
        self.segments.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    /// Get the first readable slice from the chain.
    ///
    /// Returns a const slice pointing to the first contiguous chunk of
    /// data. Due to buffer boundaries, this may be less than totalAvailable().
    ///
    /// Parameters:
    ///   pool: Buffer pool to look up buffer data
    ///
    /// Returns: Slice of available data, or empty slice if chain is empty
    ///
    /// Example:
    /// ```zig
    /// // Chain has 3 segments: 8KB + 4KB + 8KB = 20KB total
    /// const slice = try chain.firstReadableSlice(pool);
    /// // slice.len == 8KB (only first segment)
    ///
    /// // Must call consume() to advance to next segment:
    /// try chain.consume(slice.len, pool);
    /// const next_slice = try chain.firstReadableSlice(pool);
    /// // next_slice.len == 4KB (second segment)
    /// ```
    pub fn firstReadableSlice(self: *const BufferChain, pool: *const FixedBufferPool) []const u8 {
        if (self.segments.items.len == 0) {
            return &[_]u8{}; // Empty chain
        }

        const segment = self.segments.items[0];
        const buffer = pool.getConstBuffer(segment.buffer_id);
        return buffer[segment.offset .. segment.offset + segment.len];
    }

    /// Get a mutable slice for the first segment (used for in-place modification).
    ///
    /// This is rarely needed but useful for operations like CRLF conversion
    /// that modify data in-place before transmission.
    ///
    /// Parameters:
    ///   pool: Buffer pool to look up buffer data
    ///
    /// Returns: Mutable slice or empty slice if chain is empty
    pub fn firstWritableSlice(self: *const BufferChain, pool: *FixedBufferPool) []u8 {
        if (self.segments.items.len == 0) {
            return &[_]u8{};
        }

        const segment = self.segments.items[0];
        const buffer = pool.getBuffer(segment.buffer_id);
        return buffer[segment.offset .. segment.offset + segment.len];
    }

    /// Get total bytes available across all segments.
    ///
    /// Returns: Sum of all segment lengths
    pub fn totalAvailable(self: *const BufferChain) usize {
        return self.total_bytes;
    }

    /// Check if the chain is empty.
    ///
    /// Returns: true if no data available, false otherwise
    pub fn isEmpty(self: *const BufferChain) bool {
        return self.total_bytes == 0;
    }

    /// Get the number of segments in the chain.
    ///
    /// Useful for debugging and monitoring fragmentation.
    ///
    /// Returns: Number of buffer segments
    pub fn segmentCount(self: *const BufferChain) usize {
        return self.segments.items.len;
    }
};

// ========================================================================
// Tests
// ========================================================================

test "BufferChain: init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    try testing.expectEqual(@as(usize, 0), chain.totalAvailable());
    try testing.expect(chain.isEmpty());
    try testing.expectEqual(@as(usize, 0), chain.segmentCount());
}

test "BufferChain: append single segment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    try chain.append(0, 1024);

    try testing.expectEqual(@as(usize, 1024), chain.totalAvailable());
    try testing.expectEqual(@as(usize, 1), chain.segmentCount());
}

test "BufferChain: append multiple segments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    try chain.append(0, 8192);
    try chain.append(1, 4096);
    try chain.append(2, 8192);

    try testing.expectEqual(@as(usize, 20480), chain.totalAvailable());
    try testing.expectEqual(@as(usize, 3), chain.segmentCount());
}

test "BufferChain: partial consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    try chain.append(id0, 1024);

    // Consume 500 bytes (partial)
    try chain.consume(500, &pool);

    try testing.expectEqual(@as(usize, 524), chain.totalAvailable());
    try testing.expectEqual(@as(usize, 1), chain.segmentCount());

    // Segment should have offset=500, len=524
    const segment = chain.segments.items[0];
    try testing.expectEqual(@as(usize, 500), segment.offset);
    try testing.expectEqual(@as(usize, 524), segment.len);

    // Buffer should still be in use
    try testing.expectEqual(@as(usize, 0), pool.availableBuffers());
}

test "BufferChain: full segment consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    try chain.append(id0, 1024);

    // Consume entire segment
    try chain.consume(1024, &pool);

    try testing.expectEqual(@as(usize, 0), chain.totalAvailable());
    try testing.expectEqual(@as(usize, 0), chain.segmentCount());
    try testing.expect(chain.isEmpty());

    // Buffer should be returned to pool
    try testing.expectEqual(@as(usize, 1), pool.availableBuffers());
}

test "BufferChain: multi-segment consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id1 = pool.acquireBuffer() orelse return error.TestFailed;
    const id2 = pool.acquireBuffer() orelse return error.TestFailed;

    try chain.append(id0, 1024);
    try chain.append(id1, 1024);
    try chain.append(id2, 1024);

    // Consume 2500 bytes (spans 3 segments: 1024 + 1024 + 452)
    try chain.consume(2500, &pool);

    try testing.expectEqual(@as(usize, 572), chain.totalAvailable());
    try testing.expectEqual(@as(usize, 1), chain.segmentCount());

    // Third segment should remain with offset=452, len=572
    const segment = chain.segments.items[0];
    try testing.expectEqual(id2, segment.buffer_id);
    try testing.expectEqual(@as(usize, 452), segment.offset);
    try testing.expectEqual(@as(usize, 572), segment.len);

    // First two buffers returned, third still in use
    try testing.expectEqual(@as(usize, 2), pool.availableBuffers());
}

test "BufferChain: consumeAll" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id1 = pool.acquireBuffer() orelse return error.TestFailed;

    try chain.append(id0, 1024);
    try chain.append(id1, 512);

    try chain.consumeAll(&pool);

    try testing.expect(chain.isEmpty());
    try testing.expectEqual(@as(usize, 2), pool.availableBuffers());
}

test "BufferChain: firstReadableSlice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const buffer0 = pool.getBuffer(id0);
    @memset(buffer0, 0xAA);

    try chain.append(id0, 1024);

    const slice = chain.firstReadableSlice(&pool);
    try testing.expectEqual(@as(usize, 1024), slice.len);
    try testing.expectEqual(@as(u8, 0xAA), slice[0]);
    try testing.expectEqual(@as(u8, 0xAA), slice[1023]);
}

test "BufferChain: consume past total available" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var chain = try BufferChain.init(allocator);
    defer chain.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    try chain.append(id0, 1024);

    // Try to consume more than available (should consume all)
    try chain.consume(5000, &pool);

    try testing.expect(chain.isEmpty());
    try testing.expectEqual(@as(usize, 1), pool.availableBuffers());
}
