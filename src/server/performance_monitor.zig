// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Performance Monitor for Resource Tracking and Optimization
//!
//! This module provides comprehensive performance monitoring and resource tracking
//! for broker/chat mode operations. It monitors system resources, tracks performance
//! metrics, and provides insights for optimization and troubleshooting.
//!
//! ## Design Goals
//!
//! - **Real-time Monitoring**: Track performance metrics in real-time
//! - **Resource Tracking**: Monitor memory, CPU, and network usage
//! - **Performance Analysis**: Provide detailed performance insights
//! - **Alerting**: Detect performance issues and resource constraints
//! - **Historical Data**: Maintain performance history for analysis
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   System        │    │   Performance    │    │   Metrics       │
//! │   Monitor       │───▶│   Monitor        │◀───│   Collector     │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//!          │                       │                       │
//!          ▼                       ▼                       ▼
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │   Resource      │    │   Alert          │    │   Historical    │
//! │   Tracking      │    │   Manager        │    │   Data          │
//! │                 │    │                  │    │                 │
//! └─────────────────┘    └──────────────────┘    └─────────────────┘
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Performance monitoring configuration
pub const PerformanceConfig = struct {
    /// Monitoring interval in milliseconds
    monitoring_interval_ms: u64 = 1000, // 1 second
    /// Number of historical samples to keep
    history_size: usize = 300, // 5 minutes at 1s intervals
    /// Enable detailed CPU monitoring
    enable_cpu_monitoring: bool = true,
    /// Enable detailed memory monitoring
    enable_memory_monitoring: bool = true,
    /// Enable network I/O monitoring
    enable_network_monitoring: bool = true,
    /// Memory usage alert threshold (percentage)
    memory_alert_threshold: f32 = 85.0,
    /// CPU usage alert threshold (percentage)
    cpu_alert_threshold: f32 = 90.0,
    /// Network throughput alert threshold (bytes/sec)
    network_alert_threshold: u64 = 100 * 1024 * 1024, // 100MB/s
};

/// System resource snapshot
pub const ResourceSnapshot = struct {
    /// Timestamp of snapshot
    timestamp: i64,
    /// Memory usage in bytes
    memory_usage: u64 = 0,
    /// Memory usage percentage
    memory_percent: f32 = 0.0,
    /// Available memory in bytes
    available_memory: u64 = 0,
    /// CPU usage percentage (0.0-100.0)
    cpu_percent: f32 = 0.0,
    /// Network bytes received per second
    network_rx_bytes_per_sec: u64 = 0,
    /// Network bytes transmitted per second
    network_tx_bytes_per_sec: u64 = 0,
    /// Number of active connections
    active_connections: u32 = 0,
    /// Number of file descriptors in use
    file_descriptors: u32 = 0,
    /// System load average (1 minute)
    load_average: f32 = 0.0,

    /// Initialize snapshot with current timestamp
    pub fn init() ResourceSnapshot {
        return ResourceSnapshot{
            .timestamp = std.time.timestamp(),
        };
    }

    /// Calculate memory usage percentage
    pub fn calculateMemoryPercent(self: *ResourceSnapshot, total_memory: u64) void {
        if (total_memory > 0) {
            self.memory_percent = @as(f32, @floatFromInt(self.memory_usage)) / @as(f32, @floatFromInt(total_memory)) * 100.0;
        }
    }
};

/// Performance metrics for broker/chat operations
pub const BrokerMetrics = struct {
    /// Total messages relayed
    messages_relayed: u64 = 0,
    /// Total bytes relayed
    bytes_relayed: u64 = 0,
    /// Messages per second (current)
    messages_per_second: f32 = 0.0,
    /// Bytes per second (current)
    bytes_per_second: f32 = 0.0,
    /// Average message size
    avg_message_size: f32 = 0.0,
    /// Peak messages per second
    peak_messages_per_second: f32 = 0.0,
    /// Peak bytes per second
    peak_bytes_per_second: f32 = 0.0,
    /// Number of relay errors
    relay_errors: u64 = 0,
    /// Number of client disconnections
    client_disconnections: u64 = 0,
    /// Average relay latency (microseconds)
    avg_relay_latency_us: u64 = 0,
    /// Peak relay latency (microseconds)
    peak_relay_latency_us: u64 = 0,

    /// Update metrics with new relay operation
    pub fn updateRelay(self: *BrokerMetrics, bytes: u64, latency_us: u64) void {
        self.messages_relayed += 1;
        self.bytes_relayed += bytes;

        // Update average message size
        self.avg_message_size = @as(f32, @floatFromInt(self.bytes_relayed)) / @as(f32, @floatFromInt(self.messages_relayed));

        // Update latency metrics
        if (latency_us > self.peak_relay_latency_us) {
            self.peak_relay_latency_us = latency_us;
        }

        // Simple moving average for latency (could be improved with proper windowing)
        self.avg_relay_latency_us = (self.avg_relay_latency_us + latency_us) / 2;
    }

    /// Update throughput metrics
    pub fn updateThroughput(self: *BrokerMetrics, messages_per_sec: f32, bytes_per_sec: f32) void {
        self.messages_per_second = messages_per_sec;
        self.bytes_per_second = bytes_per_sec;

        if (messages_per_sec > self.peak_messages_per_second) {
            self.peak_messages_per_second = messages_per_sec;
        }

        if (bytes_per_sec > self.peak_bytes_per_second) {
            self.peak_bytes_per_second = bytes_per_sec;
        }
    }

    /// Record relay error
    pub fn recordError(self: *BrokerMetrics) void {
        self.relay_errors += 1;
    }

    /// Record client disconnection
    pub fn recordDisconnection(self: *BrokerMetrics) void {
        self.client_disconnections += 1;
    }
};

/// Performance alert types
pub const AlertType = enum {
    memory_high,
    cpu_high,
    network_high,
    relay_errors,
    client_disconnections,
    latency_high,

    /// Get human-readable description
    pub fn description(self: AlertType) []const u8 {
        return switch (self) {
            .memory_high => "High Memory Usage",
            .cpu_high => "High CPU Usage",
            .network_high => "High Network Usage",
            .relay_errors => "High Relay Error Rate",
            .client_disconnections => "High Client Disconnection Rate",
            .latency_high => "High Relay Latency",
        };
    }
};

/// Performance alert
pub const PerformanceAlert = struct {
    /// Alert type
    alert_type: AlertType,
    /// Alert message
    message: []const u8,
    /// Alert severity (1-5, 5 being critical)
    severity: u8,
    /// Timestamp when alert was triggered
    timestamp: i64,
    /// Current value that triggered the alert
    current_value: f64,
    /// Threshold that was exceeded
    threshold: f64,

    /// Initialize alert
    pub fn init(alert_type: AlertType, message: []const u8, severity: u8, current_value: f64, threshold: f64) PerformanceAlert {
        return PerformanceAlert{
            .alert_type = alert_type,
            .message = message,
            .severity = severity,
            .timestamp = std.time.timestamp(),
            .current_value = current_value,
            .threshold = threshold,
        };
    }
};

/// Historical data ring buffer
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        head: usize = 0,
        count: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, buffer_capacity: usize) !Self {
            const data = try allocator.alloc(T, buffer_capacity);
            return Self{
                .data = data,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn push(self: *Self, item: T) void {
            self.data[self.head] = item;
            self.head = (self.head + 1) % self.data.len;
            if (self.count < self.data.len) {
                self.count += 1;
            }
        }

        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.count) return null;
            const actual_index = if (self.count < self.data.len)
                index
            else
                (self.head + index) % self.data.len;
            return self.data[actual_index];
        }

        pub fn latest(self: *const Self) ?T {
            if (self.count == 0) return null;
            const latest_index = if (self.head == 0) self.data.len - 1 else self.head - 1;
            return self.data[latest_index];
        }

        pub fn size(self: *const Self) usize {
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            return self.data.len;
        }
    };
}

/// Provides real-time and historical performance monitoring for the server.
///
/// This struct is responsible for collecting, storing, and analyzing performance
/// metrics related to resource usage (CPU, memory) and application-level
/// operations (message relay, latency). It is designed to be updated periodically
/// from a main server loop.
///
/// ## Key Components
///
/// - **Resource History**: A `RingBuffer` stores recent `ResourceSnapshot`s,
///   providing a time-series view of system-level metrics like CPU and memory usage.
/// - **Broker Metrics**: Aggregates application-specific counters for operations
///   like the number of messages relayed, total bytes transferred, and error counts.
/// - **Alerting**: The `checkAlerts` method evaluates the latest resource snapshot
///   against configured thresholds and generates `PerformanceAlert`s if limits
///   are exceeded.
///
/// ## Usage
///
/// 1.  Initialize a `PerformanceMonitor` once when the server starts.
/// 2.  In the main event loop, call `update()` periodically (e.g., once per second).
/// 3.  Call specific recording methods like `recordRelay()` or `recordError()` from
///     the relevant parts of the application logic as events occur.
/// 4.  The server can then expose the collected data via a telemetry endpoint by
///     calling `getPerformanceSummary()` or `getActiveAlerts()`.
pub const PerformanceMonitor = struct {
    /// The allocator used for internal data structures.
    allocator: std.mem.Allocator,
    /// Configuration
    config: PerformanceConfig,
    /// Historical resource snapshots
    resource_history: RingBuffer(ResourceSnapshot),
    /// Current broker metrics
    broker_metrics: BrokerMetrics = BrokerMetrics{},
    /// Active alerts
    active_alerts: std.ArrayList(PerformanceAlert),
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    /// Last monitoring timestamp
    last_monitor_time: i64,
    /// Monitoring enabled flag
    monitoring_enabled: bool = true,
    /// Previous network stats for rate calculation
    prev_network_rx: u64 = 0,
    prev_network_tx: u64 = 0,
    prev_network_time: i64 = 0,

    /// Initialize performance monitor
    pub fn init(allocator: std.mem.Allocator, config: PerformanceConfig) !PerformanceMonitor {
        return PerformanceMonitor{
            .allocator = allocator,
            .config = config,
            .resource_history = try RingBuffer(ResourceSnapshot).init(allocator, config.history_size),
            .active_alerts = std.ArrayList(PerformanceAlert){},
            .last_monitor_time = std.time.timestamp(),
        };
    }

    /// Clean up performance monitor
    pub fn deinit(self: *PerformanceMonitor) void {
        self.resource_history.deinit();

        // Free alert messages
        for (self.active_alerts.items) |alert| {
            self.allocator.free(alert.message);
        }
        self.active_alerts.deinit(self.allocator);
    }

    /// Update monitoring data
    pub fn update(self: *PerformanceMonitor) void {
        if (!self.monitoring_enabled) return;

        const now = std.time.timestamp();
        const interval_ms = self.config.monitoring_interval_ms;

        if (@as(u64, @intCast(now - self.last_monitor_time)) * 1000 < interval_ms) {
            return; // Not time for update yet
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Collect resource snapshot
        var snapshot = self.collectResourceSnapshot();

        // Calculate throughput metrics
        self.calculateThroughputMetrics(&snapshot);

        // Store snapshot in history
        self.resource_history.push(snapshot);

        // Check for alerts
        self.checkAlerts(&snapshot);

        self.last_monitor_time = now;
    }

    /// Collect current resource snapshot
    fn collectResourceSnapshot(self: *PerformanceMonitor) ResourceSnapshot {
        var snapshot = ResourceSnapshot.init();

        // Get memory information
        if (self.config.enable_memory_monitoring) {
            self.collectMemoryInfo(&snapshot);
        }

        // Get CPU information
        if (self.config.enable_cpu_monitoring) {
            self.collectCpuInfo(&snapshot);
        }

        // Get network information
        if (self.config.enable_network_monitoring) {
            self.collectNetworkInfo(&snapshot);
        }

        return snapshot;
    }

    /// Collect memory information
    fn collectMemoryInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        // Platform-specific memory collection
        if (builtin.os.tag == .linux) {
            self.collectLinuxMemoryInfo(snapshot);
        } else if (builtin.os.tag == .windows) {
            self.collectWindowsMemoryInfo(snapshot);
        } else if (builtin.os.tag == .macos) {
            self.collectMacOSMemoryInfo(snapshot);
        } else {
            // Fallback: use basic process memory info
            self.collectBasicMemoryInfo(snapshot);
        }
    }

    /// Collect Linux memory information
    fn collectLinuxMemoryInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {

        // Read /proc/meminfo
        const meminfo_file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return;
        defer meminfo_file.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = meminfo_file.readAll(&buffer) catch return;
        const content = buffer[0..bytes_read];

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                if (self.parseMemoryValue(line)) |total| {
                    snapshot.available_memory = total * 1024; // Convert KB to bytes
                }
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                if (self.parseMemoryValue(line)) |available| {
                    const total = snapshot.available_memory / 1024; // Convert back to KB
                    snapshot.memory_usage = (total - available) * 1024; // Convert to bytes
                    snapshot.calculateMemoryPercent(snapshot.available_memory);
                }
            }
        }
    }

    /// Parse memory value from /proc/meminfo line
    fn parseMemoryValue(self: *PerformanceMonitor, line: []const u8) ?u64 {
        _ = self; // Suppress unused parameter warning

        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // Skip label

        while (parts.next()) |part| {
            if (part.len > 0 and std.ascii.isDigit(part[0])) {
                return std.fmt.parseInt(u64, part, 10) catch null;
            }
        }
        return null;
    }

    /// Collect Windows memory information
    fn collectWindowsMemoryInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        _ = self;

        // Use Windows API GlobalMemoryStatusEx to get real memory information
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const DWORDLONG = windows.DWORDLONG;

            // MEMORYSTATUSEX structure
            const MEMORYSTATUSEX = extern struct {
                dwLength: windows.DWORD,
                dwMemoryLoad: windows.DWORD,
                ullTotalPhys: DWORDLONG,
                ullAvailPhys: DWORDLONG,
                ullTotalPageFile: DWORDLONG,
                ullAvailPageFile: DWORDLONG,
                ullTotalVirtual: DWORDLONG,
                ullAvailVirtual: DWORDLONG,
                ullAvailExtendedVirtual: DWORDLONG,
            };

            var mem_status: MEMORYSTATUSEX = undefined;
            mem_status.dwLength = @sizeOf(MEMORYSTATUSEX);

            // GlobalMemoryStatusEx function (from kernel32.dll)
            const kernel32 = windows.kernel32;
            const GlobalMemoryStatusEx = kernel32.GlobalMemoryStatusEx;

            if (GlobalMemoryStatusEx(&mem_status) != 0) {
                snapshot.available_memory = mem_status.ullTotalPhys;
                snapshot.memory_usage = mem_status.ullTotalPhys - mem_status.ullAvailPhys;
                snapshot.calculateMemoryPercent(snapshot.available_memory);
                return;
            }
        }

        // Fallback if Windows API fails or not on Windows
        snapshot.available_memory = 8 * 1024 * 1024 * 1024; // Assume 8GB
        snapshot.memory_usage = 2 * 1024 * 1024 * 1024; // Assume 2GB used
        snapshot.calculateMemoryPercent(snapshot.available_memory);
    }

    /// Collect macOS memory information
    fn collectMacOSMemoryInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        _ = self;

        // Use sysctl to get real memory information on macOS
        // hw.memsize gives total physical memory
        var total_mem: u64 = 0;
        var len: usize = @sizeOf(u64);
        const hw_memsize = [_]c_int{ 6, 24 }; // CTL_HW, HW_MEMSIZE

        if (std.posix.sysctl(&hw_memsize, &total_mem, &len, null, 0)) {
            snapshot.available_memory = total_mem;
        } else |_| {
            // Fallback if sysctl fails
            snapshot.available_memory = 8 * 1024 * 1024 * 1024; // Assume 8GB
        }

        // Get VM statistics for memory usage
        // On macOS, we approximate usage from vm.swapusage or use basic heuristic
        // vm.swapusage is more complex (requires parsing), so we'll use host_statistics
        // For simplicity, estimate memory usage as 25% of total (typical for idle system)
        snapshot.memory_usage = snapshot.available_memory / 4;
        snapshot.calculateMemoryPercent(snapshot.available_memory);
    }

    /// Collect basic memory information (fallback)
    fn collectBasicMemoryInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        _ = self;

        // Use a simple heuristic based on typical system memory
        // This is a fallback and not accurate
        snapshot.available_memory = 8 * 1024 * 1024 * 1024; // Assume 8GB
        snapshot.memory_usage = 2 * 1024 * 1024 * 1024; // Assume 2GB used
        snapshot.calculateMemoryPercent(snapshot.available_memory);
    }

    /// Collect CPU information
    fn collectCpuInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {

        // Platform-specific CPU collection
        if (builtin.os.tag == .linux) {
            self.collectLinuxCpuInfo(snapshot);
        } else {
            // Fallback: use a simple estimate
            snapshot.cpu_percent = 10.0; // Placeholder
        }
    }

    /// Collect Linux CPU information
    fn collectLinuxCpuInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        _ = self; // Suppress unused parameter warning

        // Read /proc/loadavg for load average
        const loadavg_file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch return;
        defer loadavg_file.close();

        var buffer: [256]u8 = undefined;
        const bytes_read = loadavg_file.readAll(&buffer) catch return;
        const content = buffer[0..bytes_read];

        var parts = std.mem.splitScalar(u8, content, ' ');
        if (parts.next()) |load_str| {
            snapshot.load_average = std.fmt.parseFloat(f32, load_str) catch 0.0;
            // Convert load average to approximate CPU percentage
            snapshot.cpu_percent = @min(snapshot.load_average * 100.0, 100.0);
        }
    }

    /// Collect network information
    fn collectNetworkInfo(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        // This is a simplified implementation
        // In a real implementation, you would read network interface statistics

        const now = std.time.timestamp();
        if (self.prev_network_time > 0) {
            const time_diff = @as(f64, @floatFromInt(now - self.prev_network_time));
            if (time_diff > 0) {
                // Calculate rates (these would be real values in a full implementation)
                snapshot.network_rx_bytes_per_sec = @intFromFloat(@as(f64, @floatFromInt(self.prev_network_rx)) / time_diff);
                snapshot.network_tx_bytes_per_sec = @intFromFloat(@as(f64, @floatFromInt(self.prev_network_tx)) / time_diff);
            }
        }

        // Update previous values (placeholder values)
        self.prev_network_rx = snapshot.network_rx_bytes_per_sec;
        self.prev_network_tx = snapshot.network_tx_bytes_per_sec;
        self.prev_network_time = now;
    }

    /// Calculate throughput metrics
    fn calculateThroughputMetrics(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        _ = snapshot; // Suppress unused parameter warning

        // Calculate messages and bytes per second based on recent history
        if (self.resource_history.size() >= 2) {
            if (self.resource_history.latest()) |current| {
                if (self.resource_history.get(self.resource_history.size() - 2)) |previous| {
                    const time_diff = @as(f32, @floatFromInt(current.timestamp - previous.timestamp));
                    if (time_diff > 0) {
                        const messages_diff = @as(f32, @floatFromInt(self.broker_metrics.messages_relayed));
                        const bytes_diff = @as(f32, @floatFromInt(self.broker_metrics.bytes_relayed));

                        self.broker_metrics.updateThroughput(messages_diff / time_diff, bytes_diff / time_diff);
                    }
                }
            }
        }
    }

    /// Check for performance alerts
    fn checkAlerts(self: *PerformanceMonitor, snapshot: *ResourceSnapshot) void {
        // Clear old alerts (keep only recent ones)
        self.clearOldAlerts();

        // Check memory usage
        if (snapshot.memory_percent > self.config.memory_alert_threshold) {
            const message = std.fmt.allocPrint(self.allocator, "Memory usage is {d:.1}% (threshold: {d:.1}%)", .{ snapshot.memory_percent, self.config.memory_alert_threshold }) catch return;

            const alert = PerformanceAlert.init(.memory_high, message, if (snapshot.memory_percent > 95.0) 5 else 3, snapshot.memory_percent, self.config.memory_alert_threshold);

            self.active_alerts.append(self.allocator, alert) catch {};
        }

        // Check CPU usage
        if (snapshot.cpu_percent > self.config.cpu_alert_threshold) {
            const message = std.fmt.allocPrint(self.allocator, "CPU usage is {d:.1}% (threshold: {d:.1}%)", .{ snapshot.cpu_percent, self.config.cpu_alert_threshold }) catch return;

            const alert = PerformanceAlert.init(.cpu_high, message, if (snapshot.cpu_percent > 98.0) 5 else 3, snapshot.cpu_percent, self.config.cpu_alert_threshold);

            self.active_alerts.append(self.allocator, alert) catch {};
        }

        // Check network usage
        const total_network = snapshot.network_rx_bytes_per_sec + snapshot.network_tx_bytes_per_sec;
        if (total_network > self.config.network_alert_threshold) {
            const message = std.fmt.allocPrint(self.allocator, "Network usage is {} bytes/sec (threshold: {} bytes/sec)", .{ total_network, self.config.network_alert_threshold }) catch return;

            const alert = PerformanceAlert.init(.network_high, message, 3, @floatFromInt(total_network), @floatFromInt(self.config.network_alert_threshold));

            self.active_alerts.append(self.allocator, alert) catch {};
        }
    }

    /// Clear old alerts (older than 5 minutes)
    fn clearOldAlerts(self: *PerformanceMonitor) void {
        const now = std.time.timestamp();
        const alert_timeout = 300; // 5 minutes

        var i: usize = 0;
        while (i < self.active_alerts.items.len) {
            const alert = &self.active_alerts.items[i];
            if (now - alert.timestamp > alert_timeout) {
                self.allocator.free(alert.message);
                _ = self.active_alerts.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Record broker relay operation
    pub fn recordRelay(self: *PerformanceMonitor, bytes: u64, latency_us: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.broker_metrics.updateRelay(bytes, latency_us);
    }

    /// Record broker error
    pub fn recordError(self: *PerformanceMonitor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.broker_metrics.recordError();
    }

    /// Record client disconnection
    pub fn recordDisconnection(self: *PerformanceMonitor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.broker_metrics.recordDisconnection();
    }

    /// Get current broker metrics
    pub fn getBrokerMetrics(self: *const PerformanceMonitor) BrokerMetrics {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.broker_metrics;
    }

    /// Get latest resource snapshot
    pub fn getLatestSnapshot(self: *const PerformanceMonitor) ?ResourceSnapshot {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        return self_mut.resource_history.latest();
    }

    /// Get active alerts
    pub fn getActiveAlerts(self: *const PerformanceMonitor, allocator: std.mem.Allocator) ![]PerformanceAlert {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        const alerts = try allocator.alloc(PerformanceAlert, self_mut.active_alerts.items.len);
        for (self_mut.active_alerts.items, 0..) |alert, i| {
            alerts[i] = alert;
            // Note: We're sharing the message pointer, caller should not free it
        }

        return alerts;
    }

    /// Enable/disable monitoring
    pub fn setMonitoringEnabled(self: *PerformanceMonitor, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.monitoring_enabled = enabled;
    }

    /// Get performance summary
    pub fn getPerformanceSummary(self: *const PerformanceMonitor) struct {
        memory_usage_percent: f32,
        cpu_usage_percent: f32,
        messages_per_second: f32,
        bytes_per_second: f32,
        active_alerts: usize,
        relay_errors: u64,
        avg_latency_us: u64,
    } {
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();

        const latest_snapshot = self_mut.resource_history.latest();

        return .{
            .memory_usage_percent = if (latest_snapshot) |snapshot| snapshot.memory_percent else 0.0,
            .cpu_usage_percent = if (latest_snapshot) |snapshot| snapshot.cpu_percent else 0.0,
            .messages_per_second = self_mut.broker_metrics.messages_per_second,
            .bytes_per_second = self_mut.broker_metrics.bytes_per_second,
            .active_alerts = self_mut.active_alerts.items.len,
            .relay_errors = self_mut.broker_metrics.relay_errors,
            .avg_latency_us = self_mut.broker_metrics.avg_relay_latency_us,
        };
    }
};

// Tests
test "PerformanceMonitor basic operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = PerformanceConfig{
        .monitoring_interval_ms = 100, // Fast for testing
        .history_size = 10,
    };

    var monitor = try PerformanceMonitor.init(allocator, config);
    defer monitor.deinit();

    // Test recording operations
    monitor.recordRelay(1024, 500);
    monitor.recordError();
    monitor.recordDisconnection();

    const metrics = monitor.getBrokerMetrics();
    try testing.expect(metrics.messages_relayed == 1);
    try testing.expect(metrics.bytes_relayed == 1024);
    try testing.expect(metrics.relay_errors == 1);
    try testing.expect(metrics.client_disconnections == 1);
}

test "RingBuffer operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = try RingBuffer(u32).init(allocator, 3);
    defer buffer.deinit();

    // Test empty buffer
    try testing.expect(buffer.size() == 0);
    try testing.expect(buffer.latest() == null);

    // Test adding items
    buffer.push(1);
    buffer.push(2);
    buffer.push(3);

    try testing.expect(buffer.size() == 3);
    try testing.expect(buffer.latest().? == 3);
    try testing.expect(buffer.get(0).? == 1);
    try testing.expect(buffer.get(2).? == 3);

    // Test overflow
    buffer.push(4);
    try testing.expect(buffer.size() == 3);
    try testing.expect(buffer.latest().? == 4);
    try testing.expect(buffer.get(0).? == 2); // First item was overwritten
}

test "ResourceSnapshot operations" {
    const testing = std.testing;

    var snapshot = ResourceSnapshot.init();
    snapshot.memory_usage = 1024 * 1024 * 1024; // 1GB
    snapshot.calculateMemoryPercent(4 * 1024 * 1024 * 1024); // 4GB total

    try testing.expect(snapshot.memory_percent == 25.0);
    try testing.expect(snapshot.timestamp > 0);
}

test "BrokerMetrics operations" {
    const testing = std.testing;

    var metrics = BrokerMetrics{};

    // Test relay updates
    metrics.updateRelay(1024, 500);
    metrics.updateRelay(2048, 750);

    try testing.expect(metrics.messages_relayed == 2);
    try testing.expect(metrics.bytes_relayed == 3072);
    try testing.expect(metrics.avg_message_size == 1536.0);
    try testing.expect(metrics.peak_relay_latency_us == 750);

    // Test error recording
    metrics.recordError();
    metrics.recordDisconnection();

    try testing.expect(metrics.relay_errors == 1);
    try testing.expect(metrics.client_disconnections == 1);
}
