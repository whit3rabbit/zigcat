// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Provided buffer stream abstraction with IoRingBuffer-compatible interface.
//!
//! This module bridges the gap between BufferChain (which manages discrete
//! provided buffers) and the existing I/O code that expects an IoRingBuffer-like
//! interface.
//!
//! ## The Challenge
//!
//! Existing code uses IoRingBuffer:
//! ```zig
//! const writable = buffer.writableSlice();  // Get space to write into
//! const n = try socket.read(writable);
//! buffer.commitWrite(n);                     // Mark bytes as valid
//!
//! const readable = buffer.readableSlice();   // Get data to read
//! const sent = try socket.write(readable);
//! buffer.consume(sent);                      // Mark bytes as consumed
//! ```
//!
//! With provided buffers, the kernel provides the buffer:
//! ```zig
//! // io_uring completion: buffer_id=5, bytes_read=4096
//! // We don't "write into" a buffer - the kernel already filled it!
//! ```
//!
//! ## The Solution: ProvidedStream
//!
//! ProvidedStream wraps BufferChain and provides a read-oriented interface:
//!
//! ```zig
//! // On io_uring read completion:
//! try stream.commitProvidedBuffer(buffer_id, bytes_read);
//!
//! // Existing code can still use familiar interface:
//! const readable = stream.readableSlice();   // Works as expected
//! const sent = try socket.write(readable);
//! try stream.consume(sent);                  // Returns buffers to pool
//! ```
//!
//! ## Key Differences from IoRingBuffer
//!
//! | IoRingBuffer | ProvidedStream |
//! |--------------|----------------|
//! | Pre-allocated single buffer | Dynamic chain of pool buffers |
//! | writableSlice() for recv | commitProvidedBuffer() after recv |
//! | Contiguous memory | Potentially fragmented |
//! | Fixed capacity | Limited by pool size (16 buffers) |
//!
//! ## Usage
//!
//! ```zig
//! var stream = try ProvidedStream.init(allocator, pool);
//! defer stream.deinit();
//!
//! // Data arrives via io_uring (buffer already filled by kernel)
//! try stream.commitProvidedBuffer(buffer_id, bytes_read);
//!
//! // Write to socket (may require multiple calls if fragmented)
//! while (stream.availableRead() > 0) {
//!     const slice = stream.readableSlice();
//!     const written = try socket.write(slice);
//!     try stream.consume(written);
//! }
//! ```

const std = @import("std");
const BufferChain = @import("./buffer_chain.zig").BufferChain;
const FixedBufferPool = @import("./buffer_pool.zig").FixedBufferPool;

/// Provided buffer stream with IoRingBuffer-compatible interface.
///
/// This struct wraps a BufferChain to provide a familiar stream interface
/// for code that previously used IoRingBuffer. The key difference is that
/// data arrives pre-filled from io_uring, rather than being written into
/// a pre-allocated buffer.
///
/// ## Memory Management
///
/// - The stream owns the BufferChain
/// - Buffers are referenced from the FixedBufferPool (not owned)
/// - Buffers are automatically returned to the pool when consumed
///
/// ## Thread Safety
///
/// This struct is **not thread-safe**. It's designed for single-threaded
/// use within an ExecSession.
pub const ProvidedStream = struct {
    chain: BufferChain,
    pool: *FixedBufferPool, // Reference to the buffer pool

    /// Initialize a provided stream.
    ///
    /// Parameters:
    ///   allocator: Memory allocator for the BufferChain
    ///   pool: Buffer pool that owns the buffers (must outlive stream)
    ///
    /// Returns: Initialized stream
    pub fn init(allocator: std.mem.Allocator, pool: *FixedBufferPool) !ProvidedStream {
        return ProvidedStream{
            .chain = try BufferChain.init(allocator),
            .pool = pool,
        };
    }

    /// Release all resources.
    ///
    /// **CRITICAL**: This does NOT return buffers to the pool. The caller
    /// must ensure all buffers are consumed before calling deinit().
    pub fn deinit(self: *ProvidedStream) void {
        self.chain.deinit();
    }

    /// Add a buffer that was provided by io_uring.
    ///
    /// This is the "write" equivalent for provided buffers - it marks
    /// a buffer as containing valid data. The buffer was already filled
    /// by the kernel during an io_uring read operation.
    ///
    /// Parameters:
    ///   buffer_id: Buffer ID from CQE flags
    ///   len: Number of valid bytes (from CQE res field)
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to add segment to chain
    ///
    /// Example:
    /// ```zig
    /// // io_uring completion handler:
    /// const buffer_id: u16 = @intCast((cqe.flags >> 16) & 0xFFFF);
    /// const bytes_read = @as(usize, @intCast(cqe.res));
    /// try stream.commitProvidedBuffer(buffer_id, bytes_read);
    /// ```
    pub fn commitProvidedBuffer(self: *ProvidedStream, buffer_id: u16, len: usize) !void {
        try self.chain.append(buffer_id, len);
    }

    /// Consume bytes from the stream.
    ///
    /// Removes `amount` bytes from the front of the stream, returning
    /// fully-consumed buffers to the pool.
    ///
    /// Parameters:
    ///   amount: Number of bytes to consume
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to return buffer to pool (rare)
    ///
    /// Example:
    /// ```zig
    /// const slice = stream.readableSlice();
    /// const written = try socket.write(slice);
    /// try stream.consume(written);
    /// ```
    pub fn consume(self: *ProvidedStream, amount: usize) !void {
        try self.chain.consume(amount, self.pool);
    }

    /// Consume all bytes in the stream.
    ///
    /// Returns all buffers to the pool and empties the stream.
    ///
    /// Errors:
    ///   - error.OutOfMemory: Failed to return buffer to pool
    pub fn consumeAll(self: *ProvidedStream) !void {
        try self.chain.consumeAll(self.pool);
    }

    /// Get the first readable slice.
    ///
    /// Returns a const slice pointing to the first contiguous chunk of
    /// available data. Due to buffer boundaries, this may be less than
    /// availableRead().
    ///
    /// Returns: Slice of available data, or empty slice if stream is empty
    ///
    /// Example:
    /// ```zig
    /// const slice = stream.readableSlice();
    /// if (slice.len > 0) {
    ///     const written = try socket.write(slice);
    ///     try stream.consume(written);
    /// }
    /// ```
    pub fn readableSlice(self: *const ProvidedStream) []const u8 {
        return self.chain.firstReadableSlice(self.pool);
    }

    /// Get the first writable slice (for rare in-place modifications).
    ///
    /// Most code should not need this - provided buffers arrive pre-filled.
    /// This is only useful for operations that modify data in-place before
    /// transmission (e.g., CRLF conversion).
    ///
    /// Returns: Mutable slice or empty slice if stream is empty
    pub fn writableSlice(self: *const ProvidedStream) []u8 {
        return self.chain.firstWritableSlice(self.pool);
    }

    /// Get the total number of bytes available for reading.
    ///
    /// Returns: Sum of all buffer segment lengths
    pub fn availableRead(self: *const ProvidedStream) usize {
        return self.chain.totalAvailable();
    }

    /// Check if the stream is empty.
    ///
    /// Returns: true if no data available, false otherwise
    pub fn isEmpty(self: *const ProvidedStream) bool {
        return self.chain.isEmpty();
    }

    /// Get the number of buffer segments in the stream.
    ///
    /// Useful for monitoring fragmentation. Higher values indicate
    /// more fragmentation, which may impact performance.
    ///
    /// Returns: Number of discrete buffer segments
    pub fn segmentCount(self: *const ProvidedStream) usize {
        return self.chain.segmentCount();
    }

    /// Get fragmentation ratio (segments per MB of data).
    ///
    /// Useful for monitoring stream efficiency. Lower is better.
    ///
    /// Returns: Segments per MB (0 if empty)
    pub fn fragmentationRatio(self: *const ProvidedStream) f64 {
        const bytes = self.availableRead();
        if (bytes == 0) return 0.0;

        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        const segments = @as(f64, @floatFromInt(self.segmentCount()));
        return segments / mb;
    }
};

// ========================================================================
// Tests
// ========================================================================

test "ProvidedStream: init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    try testing.expectEqual(@as(usize, 0), stream.availableRead());
    try testing.expect(stream.isEmpty());
}

test "ProvidedStream: commitProvidedBuffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    try stream.commitProvidedBuffer(id0, 512);

    try testing.expectEqual(@as(usize, 512), stream.availableRead());
    try testing.expectEqual(@as(usize, 1), stream.segmentCount());
}

test "ProvidedStream: readableSlice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const buffer = pool.getBuffer(id0);
    @memset(buffer, 0xBB);

    try stream.commitProvidedBuffer(id0, 1024);

    const slice = stream.readableSlice();
    try testing.expectEqual(@as(usize, 1024), slice.len);
    try testing.expectEqual(@as(u8, 0xBB), slice[0]);
    try testing.expectEqual(@as(u8, 0xBB), slice[1023]);
}

test "ProvidedStream: consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    try stream.commitProvidedBuffer(id0, 1024);

    // Consume partial
    try stream.consume(500);
    try testing.expectEqual(@as(usize, 524), stream.availableRead());

    // Buffer still in use
    try testing.expectEqual(@as(usize, 0), pool.availableBuffers());

    // Consume rest
    try stream.consume(524);
    try testing.expect(stream.isEmpty());

    // Buffer returned to pool
    try testing.expectEqual(@as(usize, 1), pool.availableBuffers());
}

test "ProvidedStream: consumeAll" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id1 = pool.acquireBuffer() orelse return error.TestFailed;

    try stream.commitProvidedBuffer(id0, 1024);
    try stream.commitProvidedBuffer(id1, 512);

    try stream.consumeAll();

    try testing.expect(stream.isEmpty());
    try testing.expectEqual(@as(usize, 2), pool.availableBuffers());
}

test "ProvidedStream: fragmentation ratio" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 16, 8192, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    // Add 16 buffers (16 * 8KB = 128KB = 0.125MB)
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const id = pool.acquireBuffer() orelse return error.TestFailed;
        try stream.commitProvidedBuffer(id, 8192);
    }

    const ratio = stream.fragmentationRatio();
    // 16 segments / 0.125MB = 128 segments/MB
    try testing.expect(ratio > 127.0 and ratio < 129.0);
}

test "ProvidedStream: multiple buffers with consume" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try FixedBufferPool.init(allocator, 4, 1024, 0);
    defer pool.deinit();

    var stream = try ProvidedStream.init(allocator, &pool);
    defer stream.deinit();

    const id0 = pool.acquireBuffer() orelse return error.TestFailed;
    const id1 = pool.acquireBuffer() orelse return error.TestFailed;
    const id2 = pool.acquireBuffer() orelse return error.TestFailed;

    try stream.commitProvidedBuffer(id0, 1024);
    try stream.commitProvidedBuffer(id1, 1024);
    try stream.commitProvidedBuffer(id2, 512);

    try testing.expectEqual(@as(usize, 2560), stream.availableRead());

    // Consume across boundaries
    try stream.consume(1500); // Consumes id0 + partial id1

    try testing.expectEqual(@as(usize, 1060), stream.availableRead());
    try testing.expectEqual(@as(usize, 2), stream.segmentCount());

    // One buffer returned
    try testing.expectEqual(@as(usize, 1), pool.availableBuffers());
}
