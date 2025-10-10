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
//! - Multiple ports: scanPorts()
//! - Port range: scanPortRange()
//!
//! Usage:
//! ```zig
//! const is_open = try scanPort(allocator, "192.168.1.1", 80, 5000);
//! try scanPortRange(allocator, "localhost", 8000, 8100, 1000);
//! ```
//!
//! Performance:
//! - No data transfer (zero-I/O mode)
//! - Immediate socket close after connection
//! - Timeout-based parallel scanning possible

const std = @import("std");
const tcp = @import("../net/tcp.zig");
const socket_mod = @import("../net/socket.zig");
const logging = @import("logging.zig");

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
