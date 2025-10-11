//! Buffer Pool Manager for Efficient Memory Management
//!
//! This module provides memory pooling for client I/O operations in broker/chat mode.
//! It implements efficient buffer allocation, reuse, and flow control to prevent
//! memory exhaustion under high data rates.
//!
//! ## Design Goals
//!
//! - **Memory Pooling**: Reuse buffers to reduce allocation overhead
//! - **Flow Control**: Prevent memory exhaustion with backpressure mechanisms
//! - **Resource Monitoring**: Track memory usage and implement limits
//! - **Graceful Degradation**: Handle memory pressure without crashing
//! - **Thread Safety**: Support concurrent access from multiple threads
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Buffer        │    │   Buffer         │    │   Flow          │
//! │   Pool          │───▶│   Manager        │◀───│   Control       │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//!          │                       │                       │
//!          ▼                       ▼                       ▼
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Memory        │    │   Resource       │    │   Backpressure  │
//! │   Allocation    │    │   Monitoring     │    │   Management    │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Buffer pool configuration
pub const BufferPoolConfig = struct {
    /// Size of each buffer in bytes
    buffer_size: usize = 4096,
    /// Initial number of buffers to pre-allocate
    initial_pool_size: usize = 32,
    /// Maximum number of buffers in the pool
    max_pool_size: usize = 256,
    /// Maximum total memory usage in bytes (0 = unlimited)
    max_memory_usage: usize = 16 * 1024 * 1024, // 16MB default
    /// Enable flow control when memory usage exceeds this threshold
    flow_control_threshold: f32 = 0.8, // 80% of max memory
    /// Enable aggressive cleanup when memory usage exceeds this threshold
    cleanup_threshold: f32 = 0.9, // 90% of max memory
};

/// Buffer pool statistics
pub const BufferPoolStats = struct {
    /// Total buffers allocated
    total_allocated: u64 = 0,
    /// Buffers currently in use
    buffers_in_use: u64 = 0,
    /// Buffers available in pool
    buffers_available: u64 = 0,
    /// Total memory usage in bytes
    memory_usage: u64 = 0,
    /// Number of allocation requests
    allocation_requests: u64 = 0,
    /// Number of successful allocations from pool
    pool_hits: u64 = 0,
    /// Number of allocations that required new memory
    pool_misses: u64 = 0,
    /// Number of times flow control was triggered
    flow_control_triggers: u64 = 0,
    /// Number of buffers reclaimed during cleanup
    buffers_reclaimed: u64 = 0,

    /// Calculate pool hit rate as percentage
    pub fn hitRate(self: *const BufferPoolStats) f32 {
        if (self.allocation_requests == 0) return 0.0;
        return @as(f32, @floatFromInt(self.pool_hits)) / @as(f32, @floatFromInt(self.allocation_requests)) * 100.0;
    }

    /// Calculate memory usage as percentage of maximum
    pub fn memoryUsagePercent(self: *const BufferPoolStats, max_memory: usize) f32 {
        if (max_memory == 0) return 0.0;
        return @as(f32, @floatFromInt(self.memory_usage)) / @as(f32, @floatFromInt(max_memory)) * 100.0;
    }
};

/// A single, reference-counted buffer managed by the `BufferPool`.
///
/// This struct wraps a raw byte slice (`data`) with metadata to track its
/// state, including its current length, capacity, and usage timestamps. It is
/// designed to be acquired from and returned to a `BufferPool`.
pub const ManagedBuffer = struct {
    /// The raw memory slice where data is stored.
    data: []u8,
    /// The total capacity of the `data` slice in bytes.
    capacity: usize,
    /// The number of bytes currently written to the buffer.
    len: usize = 0,
    /// A reference count for shared usage scenarios (currently unused, for future use).
    ref_count: u32 = 1,
    /// The timestamp (in seconds) when the buffer was first allocated.
    allocated_at: i64,
    /// The timestamp (in seconds) of the last read or write access.
    last_accessed: i64,

    /// Initializes a new `ManagedBuffer` from a raw data slice.
    /// @param data The allocated byte slice for the buffer.
    /// @return An initialized `ManagedBuffer`.
    pub fn init(data: []u8) ManagedBuffer {
        const now = std.time.timestamp();
        return ManagedBuffer{
            .data = data,
            .capacity = data.len,
            .allocated_at = now,
            .last_accessed = now,
        };
    }

    /// Update last accessed timestamp
    pub fn touch(self: *ManagedBuffer) void {
        self.last_accessed = std.time.timestamp();
    }

    /// Get writable slice of buffer
    pub fn getWritable(self: *ManagedBuffer) []u8 {
        self.touch();
        return self.data[self.len..];
    }

    /// Get readable slice of buffer
    pub fn getReadable(self: *const ManagedBuffer) []const u8 {
        return self.data[0..self.len];
    }

    /// Advance the buffer length after writing data
    pub fn advance(self: *ManagedBuffer, bytes: usize) void {
        self.len = @min(self.len + bytes, self.capacity);
        self.touch();
    }

    /// Reset buffer for reuse
    pub fn reset(self: *ManagedBuffer) void {
        self.len = 0;
        self.ref_count = 1;
        self.touch();
    }

    /// Check if buffer is idle (not accessed recently)
    pub fn isIdle(self: *const ManagedBuffer, idle_threshold_seconds: i64) bool {
        const now = std.time.timestamp();
        return (now - self.last_accessed) > idle_threshold_seconds;
    }
};

/// A thread-safe pool for managing and reusing a collection of `ManagedBuffer`s.
///
/// The `BufferPool` is designed to reduce the overhead of frequent memory
/// allocation and deallocation in high-throughput scenarios, such as a busy chat
/// or broker server. It maintains a list of available buffers that can be
/// acquired and released.
///
/// ## Key Features
/// - **Pooling**: Instead of freeing a buffer after use, it's returned to the pool
///   to be reused by the next request, avoiding expensive system calls.
/// - **Thread Safety**: All public methods (`acquire`, `release`, etc.) are protected
///   by a mutex, allowing the pool to be safely shared across multiple threads.
/// - **Resource Limiting**: The pool is configured with a maximum size and total
///   memory usage limit to prevent unbounded resource consumption.
/// - **Flow Control**: If the pool's memory usage exceeds a configured threshold,
///   it enters a "flow control" state, causing new `acquire` requests to fail
///   until memory is freed. This acts as a backpressure mechanism.
pub const BufferPool = struct {
    /// The allocator used to create and destroy buffers.
    allocator: std.mem.Allocator,
    /// Pool configuration
    config: BufferPoolConfig,
    /// Available buffers
    available_buffers: std.ArrayList(*ManagedBuffer),
    /// All allocated buffers (for tracking)
    all_buffers: std.ArrayList(*ManagedBuffer),
    /// Pool statistics
    stats: BufferPoolStats = BufferPoolStats{},
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    /// Flow control enabled flag
    flow_control_active: bool = false,

    /// Initialize buffer pool
    pub fn init(allocator: std.mem.Allocator, config: BufferPoolConfig) !BufferPool {
        var pool = BufferPool{
            .allocator = allocator,
            .config = config,
            .available_buffers = std.ArrayList(*ManagedBuffer){},
            .all_buffers = std.ArrayList(*ManagedBuffer){},
        };

        // Pre-allocate initial buffers
        try pool.preallocateBuffers();

        return pool;
    }

    /// Clean up buffer pool
    pub fn deinit(self: *BufferPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all buffers
        for (self.all_buffers.items) |buffer| {
            self.allocator.free(buffer.data);
            self.allocator.destroy(buffer);
        }

        self.available_buffers.deinit(self.allocator);
        self.all_buffers.deinit(self.allocator);
    }

    /// Pre-allocate initial buffers
    fn preallocateBuffers(self: *BufferPool) !void {
        for (0..self.config.initial_pool_size) |_| {
            const buffer = try self.createBuffer();
            try self.available_buffers.append(self.allocator, buffer);
            try self.all_buffers.append(self.allocator, buffer);
            self.stats.buffers_available += 1;
            self.stats.total_allocated += 1;
            self.stats.memory_usage += self.config.buffer_size + @sizeOf(ManagedBuffer);
        }
    }

    /// Create a new buffer
    fn createBuffer(self: *BufferPool) !*ManagedBuffer {
        const data = try self.allocator.alloc(u8, self.config.buffer_size);
        const buffer = try self.allocator.create(ManagedBuffer);
        buffer.* = ManagedBuffer.init(data);
        return buffer;
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *BufferPool) !*ManagedBuffer {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.stats.allocation_requests += 1;

        // Check flow control
        if (self.shouldTriggerFlowControl()) {
            self.flow_control_active = true;
            self.stats.flow_control_triggers += 1;
            return error.FlowControlActive;
        }

        // Try to get buffer from pool
        if (self.available_buffers.items.len > 0) {
            const buffer = self.available_buffers.pop() orelse unreachable; // Safe: checked len > 0
            buffer.reset();
            self.stats.buffers_available -= 1;
            self.stats.buffers_in_use += 1;
            self.stats.pool_hits += 1;
            return buffer;
        }

        // Pool is empty, check if we can allocate new buffer
        if (self.canAllocateNewBuffer()) {
            const buffer = try self.createBuffer();
            try self.all_buffers.append(self.allocator, buffer);
            self.stats.total_allocated += 1;
            self.stats.buffers_in_use += 1;
            self.stats.memory_usage += self.config.buffer_size + @sizeOf(ManagedBuffer);
            self.stats.pool_misses += 1;
            return buffer;
        }

        // Cannot allocate, trigger cleanup and try again
        const reclaimed = self.performCleanup();
        self.stats.buffers_reclaimed += reclaimed;

        if (self.available_buffers.items.len > 0) {
            const buffer = self.available_buffers.pop() orelse unreachable; // Safe: checked len > 0
            buffer.reset();
            self.stats.buffers_available -= 1;
            self.stats.buffers_in_use += 1;
            self.stats.pool_hits += 1;
            return buffer;
        }

        return error.OutOfMemory;
    }

    /// Release a buffer back to the pool
    pub fn release(self: *BufferPool, buffer: *ManagedBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Decrement reference count
        if (buffer.ref_count > 1) {
            buffer.ref_count -= 1;
            return;
        }

        // Reset buffer and return to pool
        buffer.reset();
        self.available_buffers.append(self.allocator, buffer) catch {
            // If we can't add to pool, just leave it allocated
            return;
        };

        self.stats.buffers_in_use -= 1;
        self.stats.buffers_available += 1;

        // Check if we can disable flow control
        if (self.flow_control_active and !self.shouldTriggerFlowControl()) {
            self.flow_control_active = false;
        }
    }

    /// Check if flow control should be triggered
    fn shouldTriggerFlowControl(self: *const BufferPool) bool {
        if (self.config.max_memory_usage == 0) return false;

        const usage_ratio = @as(f32, @floatFromInt(self.stats.memory_usage)) / @as(f32, @floatFromInt(self.config.max_memory_usage));
        return usage_ratio >= self.config.flow_control_threshold;
    }

    /// Check if we can allocate a new buffer
    fn canAllocateNewBuffer(self: *const BufferPool) bool {
        // Check pool size limit
        if (self.all_buffers.items.len >= self.config.max_pool_size) {
            return false;
        }

        // Check memory limit
        if (self.config.max_memory_usage > 0) {
            const new_usage = self.stats.memory_usage + self.config.buffer_size + @sizeOf(ManagedBuffer);
            if (new_usage > self.config.max_memory_usage) {
                return false;
            }
        }

        return true;
    }

    /// Perform cleanup to reclaim idle buffers
    fn performCleanup(self: *BufferPool) u64 {
        const idle_threshold: i64 = 300; // 5 minutes
        var reclaimed: u64 = 0;

        // Find idle buffers in available pool
        var i: usize = 0;
        while (i < self.available_buffers.items.len) {
            const buffer = self.available_buffers.items[i];
            if (buffer.isIdle(idle_threshold)) {
                // Remove from available pool
                _ = self.available_buffers.swapRemove(i);

                // Remove from all buffers and free
                for (self.all_buffers.items, 0..) |all_buffer, j| {
                    if (all_buffer == buffer) {
                        _ = self.all_buffers.swapRemove(j);
                        break;
                    }
                }

                self.allocator.free(buffer.data);
                self.allocator.destroy(buffer);

                self.stats.buffers_available -= 1;
                self.stats.total_allocated -= 1;
                self.stats.memory_usage -= self.config.buffer_size + @sizeOf(ManagedBuffer);
                reclaimed += 1;
            } else {
                i += 1;
            }
        }

        return reclaimed;
    }

    /// Get current statistics
    pub fn getStats(self: *const BufferPool) BufferPoolStats {
        // Note: We need to cast away const to acquire mutex
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.stats;
    }

    /// Check if flow control is active
    pub fn isFlowControlActive(self: *const BufferPool) bool {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.flow_control_active;
    }

    /// Force cleanup of idle buffers
    pub fn forceCleanup(self: *BufferPool) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const reclaimed = self.performCleanup();
        self.stats.buffers_reclaimed += reclaimed;
        return reclaimed;
    }

    /// Get memory usage information
    pub fn getMemoryInfo(self: *const BufferPool) struct {
        current_usage: usize,
        max_usage: usize,
        usage_percent: f32,
        flow_control_active: bool,
    } {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return .{
            .current_usage = @intCast(self_mut.stats.memory_usage),
            .max_usage = self_mut.config.max_memory_usage,
            .usage_percent = if (self_mut.config.max_memory_usage > 0)
                @as(f32, @floatFromInt(self_mut.stats.memory_usage)) / @as(f32, @floatFromInt(self_mut.config.max_memory_usage)) * 100.0
            else
                0.0,
            .flow_control_active = self_mut.flow_control_active,
        };
    }
};

// Tests
test "BufferPool basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BufferPoolConfig{
        .buffer_size = 1024,
        .initial_pool_size = 4,
        .max_pool_size = 8,
        .max_memory_usage = 16384,
    };

    var pool = try BufferPool.init(allocator, config);
    defer pool.deinit();

    // Test initial state
    const initial_stats = pool.getStats();
    try testing.expect(initial_stats.total_allocated == 4);
    try testing.expect(initial_stats.buffers_available == 4);
    try testing.expect(initial_stats.buffers_in_use == 0);

    // Test buffer acquisition
    const buffer1 = try pool.acquire();
    try testing.expect(buffer1.capacity == 1024);
    try testing.expect(buffer1.len == 0);

    const stats_after_acquire = pool.getStats();
    try testing.expect(stats_after_acquire.buffers_in_use == 1);
    try testing.expect(stats_after_acquire.buffers_available == 3);

    // Test buffer release
    pool.release(buffer1);
    const stats_after_release = pool.getStats();
    try testing.expect(stats_after_release.buffers_in_use == 0);
    try testing.expect(stats_after_release.buffers_available == 4);
}

test "BufferPool flow control" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BufferPoolConfig{
        .buffer_size = 1024,
        .initial_pool_size = 2,
        .max_pool_size = 10, // Increased to allow enough allocations for flow control
        .max_memory_usage = 5120, // Adjusted so 80% threshold allows 3+ buffers before flow control (each buffer ~= 1080 bytes)
        .flow_control_threshold = 0.75, // Lower threshold to trigger before hard limit (75% = 3840 bytes, ~3.5 buffers)
    };

    var pool = try BufferPool.init(allocator, config);
    defer pool.deinit();

    // Acquire buffers until flow control triggers
    var buffers = std.ArrayList(*ManagedBuffer){};
    defer buffers.deinit(allocator);

    // Should be able to acquire some buffers
    try buffers.append(allocator, try pool.acquire());
    try buffers.append(allocator, try pool.acquire());

    // Eventually should trigger flow control
    var flow_control_triggered = false;
    for (0..10) |_| {
        if (pool.acquire()) |buffer| {
            try buffers.append(allocator, buffer);
        } else |err| {
            if (err == error.FlowControlActive) {
                flow_control_triggered = true;
                break;
            }
        }
    }

    try testing.expect(flow_control_triggered);
    try testing.expect(pool.isFlowControlActive());

    // Release buffers
    for (buffers.items) |buffer| {
        pool.release(buffer);
    }
}

test "ManagedBuffer operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    var buffer = ManagedBuffer.init(data);

    // Test initial state
    try testing.expect(buffer.capacity == 1024);
    try testing.expect(buffer.len == 0);
    try testing.expect(buffer.ref_count == 1);

    // Test writing data
    const writable = buffer.getWritable();
    try testing.expect(writable.len == 1024);

    // Simulate writing some data
    @memcpy(writable[0..5], "hello");
    buffer.advance(5);

    try testing.expect(buffer.len == 5);

    const readable = buffer.getReadable();
    try testing.expectEqualStrings("hello", readable);

    // Test reset
    buffer.reset();
    try testing.expect(buffer.len == 0);
    try testing.expect(buffer.ref_count == 1);
}

test "BufferPool cleanup" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = BufferPoolConfig{
        .buffer_size = 1024,
        .initial_pool_size = 4,
        .max_pool_size = 8,
        .max_memory_usage = 16384,
    };

    var pool = try BufferPool.init(allocator, config);
    defer pool.deinit();

    // Force cleanup (should not reclaim anything since buffers are new)
    const reclaimed = pool.forceCleanup();
    try testing.expect(reclaimed == 0);

    // Get memory info
    const memory_info = pool.getMemoryInfo();
    try testing.expect(memory_info.current_usage > 0);
    try testing.expect(memory_info.max_usage == 16384);
    try testing.expect(!memory_info.flow_control_active);
}
