// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Ring buffer for non-blocking I/O operations.
//!
//! Provides contiguous slices for reading/writing without additional copying.
//! Designed for use by the exec session poll loop to stage socket and child
//! process data while respecting memory limits.
const std = @import("std");

/// Errors for buffer management
pub const BufferError = error{
    /// Operation exceeded configured capacity
    Overflow,
    /// Buffer capacity must be greater than zero
    InvalidCapacity,
};

/// Ring buffer for non-blocking I/O operations.
///
/// Provides contiguous slices for reading/writing without additional copying.
/// Designed for use by the exec session poll loop to stage socket and child
/// process data while respecting memory limits.
pub const IoRingBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    read_index: usize = 0,
    write_index: usize = 0,
    len: usize = 0,
    high_water_mark: usize = 0,
    overflowed: bool = false,

    /// Initialize a ring buffer with specified capacity.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !IoRingBuffer {
        if (capacity == 0) {
            return BufferError.InvalidCapacity;
        }

        const storage = try allocator.alloc(u8, capacity);
        return .{
            .allocator = allocator,
            .storage = storage,
            .capacity = capacity,
        };
    }

    /// Free storage associated with the ring buffer.
    pub fn deinit(self: *IoRingBuffer) void {
        if (self.storage.len != 0) {
            self.allocator.free(self.storage);
        }
        self.storage = &[_]u8{};
        self.capacity = 0;
        self.read_index = 0;
        self.write_index = 0;
        self.len = 0;
        self.high_water_mark = 0;
        self.overflowed = false;
    }

    /// Number of bytes currently buffered.
    pub fn availableRead(self: *const IoRingBuffer) usize {
        return self.len;
    }

    /// Remaining capacity available for writes.
    pub fn availableWrite(self: *const IoRingBuffer) usize {
        return self.capacity - self.len;
    }

    /// Whether the buffer has recorded an overflow.
    pub fn hasOverflowed(self: *const IoRingBuffer) bool {
        return self.overflowed;
    }

    /// Reset overflow tracking.
    pub fn clearOverflow(self: *IoRingBuffer) void {
        self.overflowed = false;
    }

    /// Obtain first contiguous writable slice.
    pub fn writableSlice(self: *IoRingBuffer) []u8 {
        if (self.len == self.capacity) {
            return self.storage[0..0];
        }

        if (self.write_index >= self.read_index) {
            const tail_space = self.capacity - self.write_index;
            if (tail_space == 0) {
                const max_len = self.read_index;
                return self.storage[0..max_len];
            }
            const max_len = @min(tail_space, self.capacity - self.len);
            return self.storage[self.write_index .. self.write_index + max_len];
        }

        const max_len = self.read_index - self.write_index;
        return self.storage[self.write_index .. self.write_index + max_len];
    }

    /// Commit bytes written into previously obtained writable slice.
    ///
    /// SECURITY: Performs index math in widened (u128) space to avoid overflow.
    /// Guarantees `(write_index + amount) % capacity` semantics even when
    /// capacity exceeds half of the native usize range on 32-bit targets.
    pub fn commitWrite(self: *IoRingBuffer, amount: usize) void {
        if (amount == 0) return;

        if (amount > self.availableWrite()) {
            self.overflowed = true;
            return;
        }

        // SECURITY: Advance index using widened arithmetic to avoid overflow on 32-bit
        self.write_index = advanceIndex(self.write_index, amount, self.capacity);
        self.len += amount;
        if (self.len > self.high_water_mark) {
            self.high_water_mark = self.len;
        }
    }

    /// Obtain first contiguous readable slice.
    pub fn readableSlice(self: *const IoRingBuffer) []const u8 {
        if (self.len == 0) {
            return self.storage[0..0];
        }

        if (self.read_index < self.write_index) {
            return self.storage[self.read_index .. self.read_index + self.len];
        }

        const chunk_len = @min(self.len, self.capacity - self.read_index);
        return self.storage[self.read_index .. self.read_index + chunk_len];
    }

    /// Consume bytes from the buffer after reading.
    ///
    /// SECURITY: Performs index math in widened (u128) space to avoid overflow,
    /// preserving `(read_index + amount) % capacity` semantics on 32-bit targets.
    pub fn consume(self: *IoRingBuffer, amount: usize) void {
        if (amount == 0) return;

        if (amount > self.len) {
            self.len = 0;
            self.read_index = self.write_index;
            return;
        }

        // SECURITY: Advance index using widened arithmetic to avoid overflow on 32-bit
        self.read_index = advanceIndex(self.read_index, amount, self.capacity);
        self.len -= amount;
    }

    /// Copy data into the buffer, returning error if it does not fit.
    pub fn writeAll(self: *IoRingBuffer, data: []const u8) !void {
        if (data.len > self.availableWrite()) {
            self.overflowed = true;
            return BufferError.Overflow;
        }

        var remaining = data;
        while (remaining.len > 0) {
            const span = self.writableSlice();
            const to_copy = @min(span.len, remaining.len);
            std.mem.copyForwards(u8, span[0..to_copy], remaining[0..to_copy]);
            self.commitWrite(to_copy);
            remaining = remaining[to_copy..];
        }
    }

    /// Copy data out of the buffer into destination slice.
    pub fn readInto(self: *IoRingBuffer, dest: []u8) usize {
        var copied: usize = 0;
        var remaining = dest;

        while (remaining.len > 0 and self.len > 0) {
            const span = self.readableSlice();
            if (span.len == 0) break;
            const to_copy = @min(span.len, remaining.len);
            std.mem.copyForwards(u8, remaining[0..to_copy], span[0..to_copy]);
            self.consume(to_copy);
            copied += to_copy;
            remaining = remaining[to_copy..];
        }

        return copied;
    }

    /// Reset buffer contents while retaining allocated storage.
    pub fn reset(self: *IoRingBuffer) void {
        self.read_index = 0;
        self.write_index = 0;
        self.len = 0;
        self.high_water_mark = 0;
        self.overflowed = false;
    }
};

/// Advance an index by `amount` modulo `capacity` without intermediate overflow.
fn advanceIndex(index: usize, amount: usize, capacity: usize) usize {
    std.debug.assert(capacity != 0);
    const widened = @as(u128, index) + @as(u128, amount);
    const wrapped = widened % @as(u128, capacity);
    return @intCast(wrapped);
}

test "IoRingBuffer basic read/write" {
    const allocator = std.testing.allocator;
    var buffer = try IoRingBuffer.init(allocator, 8);
    defer buffer.deinit();

    try buffer.writeAll("abcd");
    try std.testing.expectEqual(@as(usize, 4), buffer.availableRead());
    try std.testing.expectEqualStrings("abcd", buffer.readableSlice());

    var tmp: [2]u8 = undefined;
    const copied = buffer.readInto(&tmp);
    try std.testing.expectEqual(@as(usize, 2), copied);
    try std.testing.expectEqualStrings("ab", tmp[0..2]);

    try buffer.writeAll("efgh");
    try std.testing.expectEqual(@as(usize, 6), buffer.availableRead());

    var out: [6]u8 = undefined;
    const copied2 = buffer.readInto(&out);
    try std.testing.expectEqual(@as(usize, 6), copied2);
    try std.testing.expectEqualStrings("cdefgh", out[0..6]);
    try std.testing.expectEqual(@as(usize, 0), buffer.availableRead());
}

test "IoRingBuffer overflow detection" {
    const allocator = std.testing.allocator;
    var buffer = try IoRingBuffer.init(allocator, 4);
    defer buffer.deinit();

    try buffer.writeAll("abcd");
    try std.testing.expectEqual(@as(usize, 4), buffer.availableRead());

    const result = buffer.writeAll("x");
    try std.testing.expectError(BufferError.Overflow, result);
    try std.testing.expect(buffer.hasOverflowed());
}

test "IoRingBuffer integer overflow protection - commitWrite" {
    const allocator = std.testing.allocator;
    var buffer = try IoRingBuffer.init(allocator, 16);
    defer buffer.deinit();

    // Simulate near-overflow scenario by manually setting write_index
    // to a value close to usize max
    buffer.write_index = std.math.maxInt(usize) - 5;

    // Attempt to commit a write that would overflow with standard addition
    // With +% wrapping addition, this should work correctly
    const slice = buffer.writableSlice();
    if (slice.len > 0) {
        // Write some data
        const to_write = @min(slice.len, 8);
        @memset(slice[0..to_write], 'X');
        buffer.commitWrite(to_write);

        // Buffer should still be in valid state
        // write_index should have wrapped correctly via modulo
        try std.testing.expect(buffer.write_index < buffer.capacity);
        try std.testing.expectEqual(@as(usize, to_write), buffer.availableRead());
    }
}

test "IoRingBuffer integer overflow protection - consume" {
    const allocator = std.testing.allocator;
    var buffer = try IoRingBuffer.init(allocator, 16);
    defer buffer.deinit();

    // Write some data first
    try buffer.writeAll("test data");

    // Simulate near-overflow scenario for read_index
    buffer.read_index = std.math.maxInt(usize) - 5;
    // Adjust write_index to maintain valid buffer state
    buffer.write_index = (buffer.read_index +% buffer.len) % buffer.capacity;

    // Consume bytes - should handle wrapping correctly
    const to_consume = @min(buffer.availableRead(), 4);
    buffer.consume(to_consume);

    // Buffer should still be in valid state
    try std.testing.expect(buffer.read_index < buffer.capacity);
    try std.testing.expectEqual(@as(usize, 9 - to_consume), buffer.availableRead());
}

test "IoRingBuffer wrapping behavior across capacity boundary" {
    const allocator = std.testing.allocator;
    var buffer = try IoRingBuffer.init(allocator, 8);
    defer buffer.deinit();

    // Fill buffer
    try buffer.writeAll("12345678");
    try std.testing.expectEqual(@as(usize, 8), buffer.availableRead());

    // Consume some data to advance read_index
    buffer.consume(5);
    try std.testing.expectEqual(@as(usize, 3), buffer.availableRead());
    try std.testing.expectEqual(@as(usize, 5), buffer.read_index);
    try std.testing.expectEqual(@as(usize, 0), buffer.write_index); // Wrapped to 0

    // Write more data - should wrap write_index correctly
    try buffer.writeAll("ABCDE");
    try std.testing.expectEqual(@as(usize, 8), buffer.availableRead());

    // Verify write_index wrapped correctly
    // With wrapping arithmetic: (0 +% 5) % 8 = 5
    try std.testing.expectEqual(@as(usize, 5), buffer.write_index);

    // Read all data to verify correctness
    var out: [8]u8 = undefined;
    const copied = buffer.readInto(&out);
    try std.testing.expectEqual(@as(usize, 8), copied);
    try std.testing.expectEqualStrings("678ABCDE", out[0..8]);
}
