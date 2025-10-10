//! Flow Control Manager for Resource Management
//!
//! This module implements flow control mechanisms to prevent memory exhaustion
//! and manage resource usage in broker/chat mode. It provides backpressure
//! mechanisms, resource monitoring, and graceful degradation under load.
//!
//! ## Design Goals
//!
//! - **Backpressure Management**: Prevent memory exhaustion with flow control
//! - **Resource Monitoring**: Track system resource usage in real-time
//! - **Graceful Degradation**: Handle resource pressure without crashing
//! - **Client Prioritization**: Manage resources fairly across clients
//! - **Performance Metrics**: Provide detailed performance monitoring
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Resource      │    │   Flow Control   │    │   Backpressure  │
//! │   Monitor       │───▶│   Manager        │◀───│   Controller    │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//!          │                       │                       │
//!          ▼                       ▼                       ▼
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Memory        │    │   Client         │    │   Rate          │
//! │   Tracking      │    │   Throttling     │    │   Limiting      │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//! ```

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../util/logging.zig");

/// Flow control configuration
pub const FlowControlConfig = struct {
    /// Maximum memory usage before triggering flow control (bytes)
    max_memory_usage: usize = 32 * 1024 * 1024, // 32MB default
    /// Memory usage threshold to start flow control (0.0-1.0)
    flow_control_threshold: f32 = 0.75, // 75%
    /// Memory usage threshold for aggressive throttling (0.0-1.0)
    throttle_threshold: f32 = 0.85, // 85%
    /// Memory usage threshold for emergency mode (0.0-1.0)
    emergency_threshold: f32 = 0.95, // 95%
    /// Maximum bytes per second per client (0 = unlimited)
    max_bytes_per_second_per_client: usize = 1024 * 1024, // 1MB/s
    /// Maximum pending bytes per client before dropping
    max_pending_bytes_per_client: usize = 64 * 1024, // 64KB
    /// Time window for rate limiting (milliseconds)
    rate_limit_window_ms: u64 = 1000, // 1 second
    /// Cleanup interval for resource monitoring (milliseconds)
    cleanup_interval_ms: u64 = 5000, // 5 seconds
    /// Enable adaptive flow control based on system load
    adaptive_flow_control: bool = true,
};

/// Flow control state levels
pub const FlowControlLevel = enum {
    /// Normal operation, no restrictions
    normal,
    /// Light flow control, minor restrictions
    light,
    /// Moderate flow control, significant restrictions
    moderate,
    /// Heavy flow control, severe restrictions
    heavy,
    /// Emergency mode, drop connections if necessary
    emergency,

    /// Get human-readable description
    pub fn description(self: FlowControlLevel) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .light => "Light Flow Control",
            .moderate => "Moderate Flow Control",
            .heavy => "Heavy Flow Control",
            .emergency => "Emergency Mode",
        };
    }
};

/// Client flow control state
pub const ClientFlowState = struct {
    /// Client ID
    client_id: u32,
    /// Bytes sent in current time window
    bytes_sent_window: u64 = 0,
    /// Bytes pending to be sent
    bytes_pending: u64 = 0,
    /// Timestamp of current rate limit window start
    window_start: i64,
    /// Number of times client was throttled
    throttle_count: u64 = 0,
    /// Last time client was throttled
    last_throttle_time: i64 = 0,
    /// Client priority (higher = more important)
    priority: u8 = 128, // Default medium priority

    /// Initialize client flow state
    pub fn init(client_id: u32) ClientFlowState {
        return ClientFlowState{
            .client_id = client_id,
            .window_start = std.time.timestamp(),
        };
    }

    /// Check if client should be rate limited
    pub fn shouldRateLimit(self: *const ClientFlowState, config: *const FlowControlConfig) bool {
        const now = std.time.timestamp();
        const window_duration_ms = @as(u64, @intCast(now - self.window_start)) * 1000;

        // Reset window if expired
        if (window_duration_ms >= config.rate_limit_window_ms) {
            return false; // New window, allow traffic
        }

        // Check if client exceeded rate limit
        const rate_limit = config.max_bytes_per_second_per_client;
        if (rate_limit > 0) {
            const elapsed_fraction = @as(f64, @floatFromInt(window_duration_ms)) / @as(f64, @floatFromInt(config.rate_limit_window_ms));
            const allowed_bytes = @as(u64, @intFromFloat(@as(f64, @floatFromInt(rate_limit)) * elapsed_fraction));
            return self.bytes_sent_window > allowed_bytes;
        }

        return false;
    }

    /// Check if client has too much pending data
    pub fn hasTooMuchPending(self: *const ClientFlowState, config: *const FlowControlConfig) bool {
        return self.bytes_pending > config.max_pending_bytes_per_client;
    }

    /// Reset rate limiting window
    pub fn resetWindow(self: *ClientFlowState) void {
        self.window_start = std.time.timestamp();
        self.bytes_sent_window = 0;
    }

    /// Record bytes sent
    pub fn recordBytesSent(self: *ClientFlowState, bytes: u64) void {
        self.bytes_sent_window += bytes;
        if (self.bytes_pending >= bytes) {
            self.bytes_pending -= bytes;
        } else {
            self.bytes_pending = 0;
        }
    }

    /// Record bytes pending
    pub fn recordBytesPending(self: *ClientFlowState, bytes: u64) void {
        self.bytes_pending += bytes;
    }

    /// Record throttling event
    pub fn recordThrottle(self: *ClientFlowState) void {
        self.throttle_count += 1;
        self.last_throttle_time = std.time.timestamp();
    }
};

/// System resource information
pub const ResourceInfo = struct {
    /// Current memory usage (bytes)
    memory_usage: u64 = 0,
    /// Maximum memory limit (bytes)
    memory_limit: u64 = 0,
    /// Memory usage percentage (0.0-1.0)
    memory_usage_percent: f32 = 0.0,
    /// Number of active clients
    active_clients: u32 = 0,
    /// Total bytes per second across all clients
    total_bytes_per_second: u64 = 0,
    /// System load average (if available)
    load_average: f32 = 0.0,
    /// Available system memory (bytes, if available)
    available_system_memory: u64 = 0,

    /// Update memory usage information
    pub fn updateMemoryUsage(self: *ResourceInfo, current: u64, limit: u64) void {
        self.memory_usage = current;
        self.memory_limit = limit;
        self.memory_usage_percent = if (limit > 0)
            @as(f32, @floatFromInt(current)) / @as(f32, @floatFromInt(limit))
        else
            0.0;
    }
};

/// Flow control statistics
pub const FlowControlStats = struct {
    /// Current flow control level
    current_level: FlowControlLevel = .normal,
    /// Number of times flow control was activated
    flow_control_activations: u64 = 0,
    /// Number of clients currently throttled
    clients_throttled: u32 = 0,
    /// Total bytes dropped due to flow control
    bytes_dropped: u64 = 0,
    /// Total connections dropped due to resource pressure
    connections_dropped: u32 = 0,
    /// Average response time (microseconds)
    avg_response_time_us: u64 = 0,
    /// Peak memory usage recorded
    peak_memory_usage: u64 = 0,
    /// Time spent in each flow control level (seconds)
    time_in_level: [5]u64 = [_]u64{0} ** 5, // normal, light, moderate, heavy, emergency

    /// Reset statistics
    pub fn reset(self: *FlowControlStats) void {
        self.* = FlowControlStats{};
    }
};

/// Flow control manager
pub const FlowControlManager = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Configuration
    config: FlowControlConfig,
    /// Client flow states
    client_states: std.AutoHashMap(u32, ClientFlowState),
    /// Current resource information
    resource_info: ResourceInfo = ResourceInfo{},
    /// Flow control statistics
    stats: FlowControlStats = FlowControlStats{},
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    /// Last cleanup time
    last_cleanup: i64,
    /// Current flow control level
    current_level: FlowControlLevel = .normal,
    /// Level change timestamp
    level_change_time: i64,

    /// Initialize flow control manager
    pub fn init(allocator: std.mem.Allocator, config: FlowControlConfig) FlowControlManager {
        const now = std.time.timestamp();
        return FlowControlManager{
            .allocator = allocator,
            .config = config,
            .client_states = std.AutoHashMap(u32, ClientFlowState).init(allocator),
            .last_cleanup = now,
            .level_change_time = now,
        };
    }

    /// Clean up flow control manager
    pub fn deinit(self: *FlowControlManager) void {
        self.client_states.deinit();
    }

    /// Add a client to flow control tracking
    pub fn addClient(self: *FlowControlManager, client_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const client_state = ClientFlowState.init(client_id);
        try self.client_states.put(client_id, client_state);
        self.resource_info.active_clients += 1;
    }

    /// Remove a client from flow control tracking
    pub fn removeClient(self: *FlowControlManager, client_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client_states.remove(client_id)) {
            if (self.resource_info.active_clients > 0) {
                self.resource_info.active_clients -= 1;
            }
        }
    }

    /// Check if data should be sent to a client
    pub fn shouldSendData(self: *FlowControlManager, client_id: u32, data_size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get client state
        var client_state = self.client_states.getPtr(client_id) orelse return false;

        // Check rate limiting
        if (client_state.shouldRateLimit(&self.config)) {
            client_state.recordThrottle();
            return false;
        }

        // Check pending data limit
        if (client_state.hasTooMuchPending(&self.config)) {
            return false;
        }

        // Check global flow control level
        switch (self.current_level) {
            .normal => return true,
            .light => {
                // Allow high priority clients
                return client_state.priority > 150;
            },
            .moderate => {
                // Allow only high priority clients, reduce data size
                return client_state.priority > 180 and data_size <= 1024;
            },
            .heavy => {
                // Allow only very high priority clients, small data only
                return client_state.priority > 200 and data_size <= 512;
            },
            .emergency => {
                // Only critical clients
                return client_state.priority > 240 and data_size <= 256;
            },
        }
    }

    /// Record data sent to a client
    pub fn recordDataSent(self: *FlowControlManager, client_id: u32, bytes_sent: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client_states.getPtr(client_id)) |client_state| {
            client_state.recordBytesSent(bytes_sent);

            // Reset window if needed
            const now = std.time.timestamp();
            const window_duration_ms = @as(u64, @intCast(now - client_state.window_start)) * 1000;
            if (window_duration_ms >= self.config.rate_limit_window_ms) {
                client_state.resetWindow();
            }
        }
    }

    /// Record data pending for a client
    pub fn recordDataPending(self: *FlowControlManager, client_id: u32, bytes_pending: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client_states.getPtr(client_id)) |client_state| {
            client_state.recordBytesPending(bytes_pending);
        }
    }

    /// Update resource information
    pub fn updateResourceInfo(self: *FlowControlManager, memory_usage: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.resource_info.updateMemoryUsage(memory_usage, self.config.max_memory_usage);

        // Update peak memory usage
        if (memory_usage > self.stats.peak_memory_usage) {
            self.stats.peak_memory_usage = memory_usage;
        }

        // Update flow control level based on memory usage
        self.updateFlowControlLevel();

        // Perform periodic cleanup
        self.performPeriodicCleanup();
    }

    /// Update flow control level based on current conditions
    fn updateFlowControlLevel(self: *FlowControlManager) void {
        const old_level = self.current_level;
        const memory_percent = self.resource_info.memory_usage_percent;

        const new_level = if (memory_percent >= self.config.emergency_threshold)
            FlowControlLevel.emergency
        else if (memory_percent >= self.config.throttle_threshold)
            FlowControlLevel.heavy
        else if (memory_percent >= self.config.flow_control_threshold)
            FlowControlLevel.moderate
        else if (memory_percent >= self.config.flow_control_threshold * 0.8)
            FlowControlLevel.light
        else
            FlowControlLevel.normal;

        if (new_level != old_level) {
            // Update time spent in old level
            const now = std.time.timestamp();
            const time_in_old_level = @as(u64, @intCast(now - self.level_change_time));
            self.stats.time_in_level[@intFromEnum(old_level)] += time_in_old_level;

            // Switch to new level
            self.current_level = new_level;
            self.level_change_time = now;

            if (new_level != .normal) {
                self.stats.flow_control_activations += 1;
            }

            logging.logDebug("Flow control level changed: {any} -> {any}\n", .{ old_level, new_level });
        }
    }

    /// Perform periodic cleanup and maintenance
    fn performPeriodicCleanup(self: *FlowControlManager) void {
        const now = std.time.timestamp();
        const cleanup_interval_s = self.config.cleanup_interval_ms / 1000;

        if (now - self.last_cleanup < cleanup_interval_s) {
            return;
        }

        self.last_cleanup = now;

        // Reset client windows that have expired
        var iterator = self.client_states.iterator();
        while (iterator.next()) |entry| {
            const client_state = entry.value_ptr;
            const window_duration_ms = @as(u64, @intCast(now - client_state.window_start)) * 1000;
            if (window_duration_ms >= self.config.rate_limit_window_ms) {
                client_state.resetWindow();
            }
        }

        // Update throttled client count
        self.updateThrottledClientCount();
    }

    /// Update count of currently throttled clients
    fn updateThrottledClientCount(self: *FlowControlManager) void {
        var throttled_count: u32 = 0;
        var iterator = self.client_states.iterator();
        while (iterator.next()) |entry| {
            const client_state = entry.value_ptr;
            if (client_state.shouldRateLimit(&self.config)) {
                throttled_count += 1;
            }
        }
        self.stats.clients_throttled = throttled_count;
    }

    /// Get current flow control level
    pub fn getCurrentLevel(self: *const FlowControlManager) FlowControlLevel {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.current_level;
    }

    /// Get current statistics
    pub fn getStats(self: *const FlowControlManager) FlowControlStats {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        var stats = self_mut.stats;
        stats.current_level = self_mut.current_level;
        return stats;
    }

    /// Get resource information
    pub fn getResourceInfo(self: *const FlowControlManager) ResourceInfo {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.resource_info;
    }

    /// Set client priority
    pub fn setClientPriority(self: *FlowControlManager, client_id: u32, priority: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client_states.getPtr(client_id)) |client_state| {
            client_state.priority = priority;
        }
    }

    /// Force emergency mode (for testing or critical situations)
    pub fn forceEmergencyMode(self: *FlowControlManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_level = self.current_level;
        self.current_level = .emergency;

        if (old_level != .emergency) {
            const now = std.time.timestamp();
            const time_in_old_level = @as(u64, @intCast(now - self.level_change_time));
            self.stats.time_in_level[@intFromEnum(old_level)] += time_in_old_level;
            self.level_change_time = now;
            self.stats.flow_control_activations += 1;
        }
    }

    /// Reset to normal mode
    pub fn resetToNormal(self: *FlowControlManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_level = self.current_level;
        self.current_level = .normal;

        if (old_level != .normal) {
            const now = std.time.timestamp();
            const time_in_old_level = @as(u64, @intCast(now - self.level_change_time));
            self.stats.time_in_level[@intFromEnum(old_level)] += time_in_old_level;
            self.level_change_time = now;
        }
    }
};

// Tests
test "FlowControlManager basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = FlowControlConfig{
        .max_memory_usage = 1024 * 1024, // 1MB
        .flow_control_threshold = 0.5, // 50%
        .max_bytes_per_second_per_client = 1024,
    };

    var manager = FlowControlManager.init(allocator, config);
    defer manager.deinit();

    // Test adding clients
    try manager.addClient(1);
    try manager.addClient(2);

    const resource_info = manager.getResourceInfo();
    try testing.expect(resource_info.active_clients == 2);

    // Test normal operation
    try testing.expect(manager.shouldSendData(1, 100));
    try testing.expect(manager.getCurrentLevel() == .normal);

    // Test data recording
    manager.recordDataSent(1, 100);
    manager.recordDataPending(1, 50);

    // Test removing clients
    manager.removeClient(1);
    const resource_info_after = manager.getResourceInfo();
    try testing.expect(resource_info_after.active_clients == 1);
}

test "FlowControlManager flow control levels" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = FlowControlConfig{
        .max_memory_usage = 1000, // Small limit for testing
        .flow_control_threshold = 0.5, // 50%
        .throttle_threshold = 0.8, // 80%
        .emergency_threshold = 0.9, // 90%
    };

    var manager = FlowControlManager.init(allocator, config);
    defer manager.deinit();

    try manager.addClient(1);

    // Test normal level (below 40%)
    manager.updateResourceInfo(300); // 30% usage
    try testing.expect(manager.getCurrentLevel() == .normal);

    // Test light level (40%+, which is 0.8 * flow_control_threshold)
    manager.updateResourceInfo(400); // 40% usage
    try testing.expect(manager.getCurrentLevel() == .light);

    // Test moderate level (50%+, which is flow_control_threshold)
    manager.updateResourceInfo(600); // 60% usage
    try testing.expect(manager.getCurrentLevel() == .moderate);

    // Test heavy level
    manager.updateResourceInfo(850); // 85% usage
    try testing.expect(manager.getCurrentLevel() == .heavy);

    // Test emergency level
    manager.updateResourceInfo(950); // 95% usage
    try testing.expect(manager.getCurrentLevel() == .emergency);
}

test "ClientFlowState rate limiting" {
    const testing = std.testing;

    const config = FlowControlConfig{
        .max_bytes_per_second_per_client = 1000,
        .rate_limit_window_ms = 1000,
    };

    var client_state = ClientFlowState.init(1);

    // Should not be rate limited initially
    try testing.expect(!client_state.shouldRateLimit(&config));

    // Record bytes sent
    client_state.recordBytesSent(1500);

    // Should be rate limited now
    try testing.expect(client_state.shouldRateLimit(&config));

    // Reset window
    client_state.resetWindow();

    // Should not be rate limited after reset
    try testing.expect(!client_state.shouldRateLimit(&config));
}

test "FlowControlManager client priority" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = FlowControlConfig{};

    var manager = FlowControlManager.init(allocator, config);
    defer manager.deinit();

    try manager.addClient(1);
    try manager.addClient(2);

    // Set different priorities
    manager.setClientPriority(1, 200); // High priority
    manager.setClientPriority(2, 100); // Low priority

    // Force moderate flow control
    manager.updateResourceInfo(config.max_memory_usage * 3 / 4); // 75% usage

    // High priority client should be allowed
    try testing.expect(manager.shouldSendData(1, 100));

    // Low priority client should be blocked in moderate flow control
    try testing.expect(!manager.shouldSendData(2, 100));
}
