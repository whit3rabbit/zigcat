//! Zero-I/O port scanning (-z flag)
//!
//! Implements fast port scanning by connecting and immediately closing.
//! Does NOT perform any data transfer - success means port is listening.
//!
//! TIMEOUT SAFETY:
//! - All scans use validated timeout (min 10ms, max 60s)
//! - Uses tcp.openTcpClient with explicit timeout_ms parameter
//! - Timeout enforced via poll() in tcp module to prevent hangs
//!
//! Features:
//! - Single port scan: scanPort()
//! - Multiple ports: scanPorts() - sequential
//! - Port range: scanPortRange() - sequential
//! - Parallel port scan: scanPortsParallel() - concurrent
//! - Parallel port range: scanPortRangeParallel() - concurrent
//!
//! Usage:
//! ```zig
//! const is_open = try scanPort(allocator, "192.168.1.1", 80, 5000);
//! try scanPortRange(allocator, "localhost", 8000, 8100, 1000);
//! try scanPortRangeParallel(allocator, "localhost", 1, 1024, 1000, 10); // 10 threads
//! ```
//!
//! Performance:
//! - No data transfer (zero-I/O mode)
//! - Immediate socket close after connection
//! - Parallel scanning with configurable worker threads
//! - 10-100x faster for large port ranges (with parallel mode)

const std = @import("std");
const tcp = @import("../net/tcp.zig");
const socket_mod = @import("../net/socket.zig");
const logging = @import("logging.zig");

/// Scan result for parallel scanning
const ScanResult = struct {
    port: u16,
    is_open: bool,
};

/// Port range specification (e.g., "80", "1-1024")
pub const PortRange = struct {
    start: u16,
    end: u16,

    /// Parse port specification from string
    ///
    /// Supported formats:
    /// - Single port: "80" → (80, 80)
    /// - Port range: "1-1024" → (1, 1024)
    /// - Inclusive range: "8000-9000" → (8000, 9000)
    ///
    /// Parameters:
    ///   spec: Port specification string
    ///
    /// Returns: PortRange or error.InvalidPortRange
    ///
    /// Example:
    /// ```zig
    /// const range1 = try PortRange.parse("80"); // Single port
    /// const range2 = try PortRange.parse("1-1024"); // Range
    /// ```
    pub fn parse(spec: []const u8) !PortRange {
        // Check for range separator
        if (std.mem.indexOf(u8, spec, "-")) |dash_pos| {
            const start_str = spec[0..dash_pos];
            const end_str = spec[dash_pos + 1 ..];

            const start = try std.fmt.parseInt(u16, start_str, 10);
            const end = try std.fmt.parseInt(u16, end_str, 10);

            if (start > end) {
                return error.InvalidPortRange;
            }

            return PortRange{ .start = start, .end = end };
        } else {
            // Single port
            const port = try std.fmt.parseInt(u16, spec, 10);
            return PortRange{ .start = port, .end = port };
        }
    }

    /// Check if this is a single port (not a range)
    pub fn isSinglePort(self: PortRange) bool {
        return self.start == self.end;
    }

    /// Get the number of ports in this range
    pub fn count(self: PortRange) usize {
        return @as(usize, self.end - self.start + 1);
    }
};

/// Work queue for parallel scanning
const ScanTask = struct {
    host: []const u8,
    port: u16,
    timeout_ms: u32,
};

/// Worker context for parallel scanning
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(ScanTask),
    results: *std.ArrayList(ScanResult),
    task_index: *std.atomic.Value(usize),
    mutex: *std.Thread.Mutex,
};

/// Zero-I/O mode: connect to port and immediately close
///
/// TIMEOUT SAFETY: Uses validated timeout range (10ms-60s) to prevent hangs.
///
/// Architecture:
/// 1. Validates timeout to safe range (min 10ms, max 60s)
/// 2. Attempts TCP connection via tcp.openTcpClient
/// 3. Immediately closes socket (zero data transfer)
/// 4. Returns true if connection succeeded, false if refused/timeout
///
/// Parameters:
/// - allocator: Memory allocator (unused, kept for API consistency)
/// - host: Target hostname or IP address
/// - port: Target port number
/// - timeout_ms: Connection timeout in milliseconds (validated to 10-60000ms)
///
/// Returns:
/// - true if port is open (connection succeeded)
/// - false if port is closed/filtered (connection refused or timeout)
///
/// Errors:
/// - No errors returned (connection failure = port closed)
///
/// Timeout Validation:
/// - Input timeout clamped to [10ms, 60000ms] range
/// - Prevents instant failures (< 10ms) and indefinite hangs (> 60s)
///
/// Example:
/// ```zig
/// const is_open = try scanPort(allocator, "google.com", 443, 5000);
/// if (is_open) {
///     std.debug.print("Port 443 is open\n", .{});
/// }
/// ```
pub fn scanPort(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_ms: u32,
) !bool {
    _ = allocator;

    // CRITICAL: Ensure timeout is reasonable (min 10ms, max 60s)
    const safe_timeout = @max(10, @min(timeout_ms, 60000));

    const sock = tcp.openTcpClient(host, port, safe_timeout) catch {
        logging.logVerbose(null, "Port {any} closed (connection refused or timeout)\n", .{port});
        return false; // Connection refused or timeout = port closed/unreachable
    };
    defer socket_mod.closeSocket(sock);

    // Port is open if we got here
    logging.logVerbose(null, "Port {any} open\n", .{port});
    return true;
}

/// Scan multiple ports from explicit list
///
/// Scans each port in the provided array sequentially.
/// Prints results to stdout for each port.
///
/// Parameters:
/// - allocator: Memory allocator
/// - host: Target hostname or IP address
/// - ports: Array of port numbers to scan
/// - timeout_ms: Connection timeout per port in milliseconds
///
/// Output format (per port):
/// ```
/// example.com:80 - open
/// example.com:443 - open
/// example.com:8080 - closed
/// ```
///
/// Example:
/// ```zig
/// const ports = [_]u16{ 80, 443, 8080, 3000 };
/// try scanPorts(allocator, "localhost", &ports, 2000);
/// ```
pub fn scanPorts(
    allocator: std.mem.Allocator,
    host: []const u8,
    ports: []const u16,
    timeout_ms: u32,
) !void {
    for (ports) |port| {
        const is_open = try scanPort(allocator, host, port, timeout_ms);
        logging.logVerbose(null, "{s}:{any} - {s}\n", .{
            host,
            port,
            if (is_open) "open" else "closed",
        });
    }
}

/// Scan a range of ports (inclusive)
///
/// Scans all ports from start_port to end_port (inclusive).
/// Only prints results for OPEN ports to reduce output volume.
///
/// Parameters:
/// - allocator: Memory allocator
/// - host: Target hostname or IP address
/// - start_port: First port to scan (inclusive)
/// - end_port: Last port to scan (inclusive)
/// - timeout_ms: Connection timeout per port in milliseconds
///
/// Returns:
/// - error.InvalidPortRange if start_port > end_port
///
/// Output format (open ports only):
/// ```
/// 192.168.1.1:22 - open
/// 192.168.1.1:80 - open
/// 192.168.1.1:443 - open
/// ```
///
/// Performance Note:
/// - Sequential scanning (not parallel)
/// - Large ranges may take significant time
/// - Consider using smaller timeout for faster scans
///
/// Example:
/// ```zig
/// // Scan common web ports
/// try scanPortRange(allocator, "example.com", 80, 8080, 1000);
///
/// // Scan all ports (slow!)
/// try scanPortRange(allocator, "localhost", 1, 65535, 100);
/// ```
pub fn scanPortRange(
    allocator: std.mem.Allocator,
    host: []const u8,
    start_port: u16,
    end_port: u16,
    timeout_ms: u32,
) !void {
    if (start_port > end_port) {
        return error.InvalidPortRange;
    }

    var port = start_port;
    while (port <= end_port) : (port += 1) {
        const is_open = try scanPort(allocator, host, port, timeout_ms);
        if (is_open) {
            logging.logVerbose(null, "{s}:{any} - open\n", .{ host, port });
        }
    }
}

// ============================================================================
// PARALLEL SCANNING IMPLEMENTATION
// ============================================================================

/// Worker thread function for parallel port scanning
///
/// Architecture:
/// 1. Atomically fetch next task index from shared counter
/// 2. Scan port using existing scanPort() function
/// 3. Store result in thread-safe results array
/// 4. Repeat until all tasks completed
///
/// Thread Safety:
/// - Task assignment via atomic counter (lock-free)
/// - Result storage protected by mutex
/// - No shared mutable state between workers
///
/// Parameters:
/// - ctx: Worker context containing tasks, results, and synchronization primitives
fn scanWorker(ctx: WorkerContext) void {
    while (true) {
        // Atomically get next task index
        const task_idx = ctx.task_index.fetchAdd(1, .monotonic);
        if (task_idx >= ctx.tasks.items.len) {
            break; // No more tasks
        }

        const task = ctx.tasks.items[task_idx];

        // Perform scan (uses existing scanPort function)
        const is_open = scanPort(ctx.allocator, task.host, task.port, task.timeout_ms) catch false;

        // Store result (thread-safe)
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.results.append(.{
            .port = task.port,
            .is_open = is_open,
        }) catch {
            // Silently ignore append errors (results may be incomplete)
            // Better than crashing the worker thread
        };
    }
}

/// Scan multiple ports in parallel using a thread pool
///
/// Uses a pool of worker threads to scan ports concurrently.
/// Significantly faster than sequential scanning for large port lists.
///
/// Architecture:
/// 1. Create work queue with all ports to scan
/// 2. Spawn worker threads (default: 10)
/// 3. Workers atomically fetch tasks from queue
/// 4. Collect results in thread-safe array
/// 5. Sort results by port number before returning
///
/// Thread Safety:
/// - Lock-free task distribution via atomic counter
/// - Mutex-protected result collection
/// - All threads joined before returning
///
/// Parameters:
/// - allocator: Memory allocator for tasks/results/threads
/// - host: Target hostname or IP address
/// - ports: Array of port numbers to scan
/// - timeout_ms: Connection timeout per port in milliseconds
/// - num_workers: Number of concurrent worker threads (default: 10)
///
/// Returns:
/// - ArrayList of ScanResult sorted by port number
/// - Caller must call deinit() on returned list
///
/// Performance:
/// - ~10x faster than sequential for 100+ ports
/// - Scales well up to ~50 workers (diminishing returns after)
/// - Limited by network bandwidth and target rate limiting
///
/// Example:
/// ```zig
/// const ports = [_]u16{ 80, 443, 8080, 3000, 5432, 6379 };
/// var results = try scanPortsParallel(allocator, "localhost", &ports, 2000, 10);
/// defer results.deinit(allocator);
///
/// for (results.items) |result| {
///     if (result.is_open) {
///         std.debug.print("Port {d} is open\n", .{result.port});
///     }
/// }
/// ```
pub fn scanPortsParallel(
    allocator: std.mem.Allocator,
    host: []const u8,
    ports: []const u16,
    timeout_ms: u32,
    num_workers: usize,
) !std.ArrayList(ScanResult) {
    // Validate worker count (min 1, max 100)
    const workers = @max(1, @min(num_workers, 100));

    // Build task list
    var tasks = std.ArrayList(ScanTask).init(allocator);
    defer tasks.deinit(allocator);

    for (ports) |port| {
        try tasks.append(.{
            .host = host,
            .port = port,
            .timeout_ms = timeout_ms,
        });
    }

    // Initialize result collection
    var results = std.ArrayList(ScanResult).init(allocator);
    errdefer results.deinit(allocator);

    // Initialize synchronization primitives
    var task_index = std.atomic.Value(usize).init(0);
    var mutex = std.Thread.Mutex{};

    // Create worker context
    const ctx = WorkerContext{
        .allocator = allocator,
        .tasks = &tasks,
        .results = &results,
        .task_index = &task_index,
        .mutex = &mutex,
    };

    // Spawn worker threads
    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < workers) : (i += 1) {
        const thread = try std.Thread.spawn(.{}, scanWorker, .{ctx});
        try threads.append(thread);
    }

    // Wait for all workers to complete
    for (threads.items) |thread| {
        thread.join();
    }

    // Sort results by port number for consistent output
    std.mem.sort(ScanResult, results.items, {}, struct {
        fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
            return a.port < b.port;
        }
    }.lessThan);

    return results;
}

/// Scan a range of ports in parallel using a thread pool
///
/// High-performance parallel port range scanning.
/// Uses thread pool to scan multiple ports concurrently.
///
/// Architecture:
/// 1. Builds array of ports in range
/// 2. Delegates to scanPortsParallel()
/// 3. Filters and prints only open ports
///
/// Parameters:
/// - allocator: Memory allocator
/// - host: Target hostname or IP address
/// - start_port: First port to scan (inclusive)
/// - end_port: Last port to scan (inclusive)
/// - timeout_ms: Connection timeout per port in milliseconds
/// - num_workers: Number of concurrent worker threads (default: 10)
///
/// Returns:
/// - error.InvalidPortRange if start_port > end_port
///
/// Output format (open ports only):
/// ```
/// 192.168.1.1:22 - open
/// 192.168.1.1:80 - open
/// 192.168.1.1:443 - open
/// ```
///
/// Performance Comparison (1000 port scan):
/// - Sequential: ~30-60 seconds (depending on timeout)
/// - Parallel (10 workers): ~3-6 seconds
/// - Parallel (50 workers): ~1-2 seconds
///
/// Example:
/// ```zig
/// // Scan common ports with 20 workers (fast!)
/// try scanPortRangeParallel(allocator, "example.com", 1, 1024, 500, 20);
///
/// // Scan all ports with 50 workers (very fast, but aggressive)
/// try scanPortRangeParallel(allocator, "localhost", 1, 65535, 100, 50);
/// ```
pub fn scanPortRangeParallel(
    allocator: std.mem.Allocator,
    host: []const u8,
    start_port: u16,
    end_port: u16,
    timeout_ms: u32,
    num_workers: usize,
) !void {
    if (start_port > end_port) {
        return error.InvalidPortRange;
    }

    // Build port array
    const port_count = @as(usize, @intCast(end_port - start_port + 1));
    const ports = try allocator.alloc(u16, port_count);
    defer allocator.free(ports);

    var port = start_port;
    var idx: usize = 0;
    while (port <= end_port) : (port += 1) {
        ports[idx] = port;
        idx += 1;
    }

    // Scan in parallel
    var results = try scanPortsParallel(allocator, host, ports, timeout_ms, num_workers);
    defer results.deinit(allocator);

    // Print open ports only
    for (results.items) |result| {
        if (result.is_open) {
            logging.logVerbose(null, "{s}:{d} - open\n", .{ host, result.port });
        }
    }
}
