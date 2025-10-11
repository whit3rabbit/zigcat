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
const builtin = @import("builtin");
const tcp = @import("../net/tcp.zig");
const socket_mod = @import("../net/socket.zig");
const logging = @import("logging.zig");
const platform = @import("platform.zig");
const portscan_uring = @import("portscan_uring.zig");

/// Scan result for parallel scanning
const ScanResult = struct {
    port: u16,
    is_open: bool,
};

/// Randomize port scanning order (stealth mode).
///
/// Uses Fisher-Yates shuffle algorithm to randomize the order of ports.
/// This helps evade IDS/IPS systems that detect sequential port scans.
///
/// Security Note:
/// - Port randomization reduces detection by signature-based IDS
/// - Does NOT provide complete anonymity or undetectability
/// - Use only for authorized security testing
///
/// Parameters:
///   ports: Array of port numbers to shuffle in-place
///
/// Example:
/// ```zig
/// var ports = [_]u16{ 80, 443, 8080, 3000 };
/// randomizePortOrder(&ports);
/// // ports is now in random order, e.g., [3000, 80, 8080, 443]
/// ```
pub fn randomizePortOrder(ports: []u16) void {
    if (ports.len <= 1) return; // Nothing to shuffle

    // Seed PRNG with current timestamp for randomness
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const random = prng.random();

    // Fisher-Yates shuffle algorithm
    random.shuffle(u16, ports);
}

/// Automatically select the best port scanning backend.
///
/// Selection priority:
/// 1. io_uring (Linux 5.1+): Fastest, 500-1000 concurrent ops
/// 2. Thread pool (all platforms): Fast, 10-100 concurrent ops
/// 3. Sequential (fallback): Slowest, 1 operation at a time
///
/// Platform-specific behavior:
/// - Linux 5.1+: Tries io_uring, falls back to thread pool
/// - macOS/Windows/BSD: Uses thread pool if parallel enabled
/// - All platforms: Falls back to sequential if parallel disabled
///
/// Parameters:
///   allocator: Memory allocator for results
///   host: Target hostname or IP address
///   ports: Array of port numbers to scan
///   timeout_ms: Connection timeout per port in milliseconds
///   parallel: Enable parallel scanning (thread pool or io_uring)
///   workers: Number of worker threads (ignored for io_uring)
///   randomize: Randomize port order before scanning
///   delay_ms: Delay between scans in milliseconds
///
/// Returns: ArrayList of ScanResult sorted by port number
///
/// Example:
/// ```zig
/// var results = try scanPortsAuto(allocator, "example.com", ports, 1000, true, 10, true, 0);
/// defer results.deinit(allocator);
/// ```
pub fn scanPortsAuto(
    allocator: std.mem.Allocator,
    host: []const u8,
    ports: []u16,
    timeout_ms: u32,
    parallel: bool,
    workers: usize,
    randomize: bool,
    delay_ms: u32,
) !std.ArrayList(ScanResult) {
    // Apply randomization if requested (do this once before backend selection)
    if (randomize) {
        randomizePortOrder(ports);
    }

    // Try io_uring on Linux (if available and parallel mode enabled)
    if (parallel and builtin.os.tag == .linux) {
        if (platform.isIoUringSupported()) {
            std.debug.print( "Using io_uring scanner ({d} ports, kernel 5.1+)\n", .{ports.len});

            // Try io_uring, fall back to thread pool if it fails
            if (portscan_uring.scanPortsIoUring(allocator, host, ports, timeout_ms, false, delay_ms)) |results| {
                return results;
            } else |err| {
                std.debug.print( "io_uring failed ({}), falling back to thread pool\n", .{err});
            }
        }
    }

    // Use thread pool if parallel mode enabled
    if (parallel) {
        std.debug.print( "Using thread pool scanner ({d} workers, {d} ports)\n", .{ workers, ports.len });
        return try scanPortsParallel(allocator, host, ports, timeout_ms, workers, delay_ms);
    }

    // Fall back to sequential scanning
    std.debug.print( "Using sequential scanner ({d} ports)\n", .{ports.len});

    var results: std.ArrayList(ScanResult) = .{};
    errdefer results.deinit(allocator);

    for (ports) |port| {
        const is_open = try scanPort(allocator, host, port, timeout_ms);
        try results.append(allocator, .{ .port = port, .is_open = is_open });

        // Apply delay if configured
        if (delay_ms > 0) {
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }

    return results;
}

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

/// Workload description for scanning workers.
const Workload = union(enum) {
    /// Iterate over an explicit slice of ports.
    ports_slice: struct {
        ports: []const u16,
        index: *std.atomic.Value(usize),
    },
    /// Iterate over an inclusive port range via atomic counter.
    port_range: struct {
        next_port: *std.atomic.Value(u32),
        end_port: u16,
    },
};

/// Worker context for parallel scanning
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    results: *std.ArrayList(ScanResult),
    mutex: *std.Thread.Mutex,
    timeout_ms: u32,
    delay_ms: u32, // Inter-scan delay in milliseconds (stealth mode)
    host: []const u8,
    workload: Workload,
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
        std.debug.print( "Port {any} closed (connection refused or timeout)\n", .{port});
        return false; // Connection refused or timeout = port closed/unreachable
    };
    defer socket_mod.closeSocket(sock);

    // Port is open if we got here
    std.debug.print( "Port {any} open\n", .{port});
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
        std.debug.print( "{s}:{any} - {s}\n", .{
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
            std.debug.print( "{s}:{any} - open\n", .{ host, port });
        }
    }
}

// ============================================================================
// PARALLEL SCANNING IMPLEMENTATION
// ============================================================================

/// Worker thread function for parallel port scanning
///
/// Workers ask the workload for the next port to scan via atomic fetch.
/// Results are appended under a mutex (to keep the array consistent) and open
/// ports are logged immediately before releasing the lock. Optional delay is
/// applied after each scan.
fn scanWorker(ctx: WorkerContext) void {
    while (true) {
        const maybe_port = switch (ctx.workload) {
            .ports_slice => |slice_work| blk: {
                const task_idx = slice_work.index.fetchAdd(1, .monotonic);
                if (task_idx >= slice_work.ports.len) break :blk null;
                break :blk slice_work.ports[task_idx];
            },
            .port_range => |range_work| blk: {
                const port_value = range_work.next_port.fetchAdd(1, .monotonic);
                if (port_value > range_work.end_port) break :blk null;
                break :blk @as(u16, @intCast(port_value));
            },
        };

        const port = maybe_port orelse break;

        // Perform scan (uses existing scanPort function)
        const is_open = scanPort(ctx.allocator, ctx.host, port, ctx.timeout_ms) catch false;

        // Store result and print immediately (thread-safe)
        ctx.mutex.lock();
        const append_result = ctx.results.append(ctx.allocator, .{
            .port = port,
            .is_open = is_open,
        });
        if (is_open) {
            std.debug.print( "{s}:{d} - open\n", .{ ctx.host, port });
        }
        ctx.mutex.unlock();

        append_result catch {
            // Silently ignore append errors (results may be incomplete)
            // Better than crashing the worker thread
        };

        // Apply inter-scan delay if configured (stealth mode)
        if (ctx.delay_ms > 0) {
            std.Thread.sleep(ctx.delay_ms * std.time.ns_per_ms);
        }
    }
}

/// Scan multiple ports in parallel using a thread pool
///
/// Uses a pool of worker threads to scan ports concurrently.
/// Significantly faster than sequential scanning for large port lists.
///
/// Architecture:
/// 1. Spawn worker threads (default: 10)
/// 2. Workers atomically fetch next port index from shared slice
/// 3. Record results under mutex
/// 4. Sort results by port number before returning
///
/// Thread Safety:
/// - Atomic index ensures lock-free task distribution
/// - Mutex guards result collection
/// - All threads joined before returning
///
/// Parameters:
/// - allocator: Memory allocator for result storage and thread bookkeeping
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
    delay_ms: u32,
) !std.ArrayList(ScanResult) {
    // Validate worker count (min 1, max 100)
    const workers = @max(1, @min(num_workers, 100));

    // Initialize result collection
    var results: std.ArrayList(ScanResult) = .{};
    errdefer results.deinit(allocator);

    // Initialize synchronization primitives
    var mutex = std.Thread.Mutex{};
    var task_index = std.atomic.Value(usize).init(0);

    // Create worker context
    const ctx = WorkerContext{
        .allocator = allocator,
        .results = &results,
        .mutex = &mutex,
        .timeout_ms = timeout_ms,
        .delay_ms = delay_ms,
        .host = host,
        .workload = .{
            .ports_slice = .{
                .ports = ports,
                .index = &task_index,
            },
        },
    };

    // Spawn worker threads
    var threads: std.ArrayList(std.Thread) = .{};
    defer threads.deinit(allocator);

    var i: usize = 0;
    while (i < workers) : (i += 1) {
        const thread = try std.Thread.spawn(.{}, scanWorker, .{ctx});
        try threads.append(allocator, thread);
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
/// - Randomized scans build and shuffle a temporary port slice
/// - Default scans use an atomic next-port counter (no preallocation)
/// - Open ports print as soon as workers finish scanning
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
    randomize: bool,
    delay_ms: u32,
) !void {
    if (start_port > end_port) {
        return error.InvalidPortRange;
    }

    const workers = @max(1, @min(num_workers, 100));

    var results: std.ArrayList(ScanResult) = undefined;
    defer results.deinit(allocator);

    if (randomize) {
        // Fallback to slice-based scanning to support shuffle behaviour.
        const port_count = @as(usize, @intCast(end_port - start_port + 1));
        const ports = try allocator.alloc(u16, port_count);
        defer allocator.free(ports);

        var port = start_port;
        var idx: usize = 0;
        while (port <= end_port) : (port += 1) {
            ports[idx] = port;
            idx += 1;
        }

        randomizePortOrder(ports);

        results = try scanPortsParallel(allocator, host, ports, timeout_ms, workers, delay_ms);
    } else {
        results = .{};

        var mutex = std.Thread.Mutex{};
        var next_port = std.atomic.Value(u32).init(@as(u32, start_port));

        const ctx = WorkerContext{
            .allocator = allocator,
            .results = &results,
            .mutex = &mutex,
            .timeout_ms = timeout_ms,
            .delay_ms = delay_ms,
            .host = host,
            .workload = .{
                .port_range = .{
                    .next_port = &next_port,
                    .end_port = end_port,
                },
            },
        };

        var threads: std.ArrayList(std.Thread) = .{};
        defer threads.deinit(allocator);

        var i: usize = 0;
        while (i < workers) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, scanWorker, .{ctx});
            try threads.append(allocator, thread);
        }

        for (threads.items) |thread| {
            thread.join();
        }
    }

    // Results are retained to keep API parity with non-range parallel scanning,
    // but open ports were already logged from worker threads for immediacy.
}
