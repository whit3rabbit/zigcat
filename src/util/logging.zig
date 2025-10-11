//! Verbose output logging system
//!
//! Provides leveled logging for zigcat with runtime verbosity control.
//! Used via -v flag (can be specified multiple times for higher verbosity).
//!
//! Verbosity Levels:
//! - quiet (0): Silent (errors only)
//! - normal (1): Default (connections, warnings)
//! - verbose (2): Connection details (via -v)
//! - debug (3): Protocol details (via -vv)
//! - trace (4): All internal state (via -vvv)
//!
//! Architecture:
//! - Global verbose_level variable controls output filtering
//! - All log functions check level before printing
//! - Errors always print regardless of verbosity
//! - Uses std.debug.print for immediate stderr output
//!
//! Usage:
//! ```zig
//! const cfg = Config{ .verbosity = .verbose };
//! logging.logVerbose(&cfg, "Connected to {s}\n", .{host});  // Level 2
//! logging.logDebug(&cfg, "Data: {x}\n", .{data});  // Level 3
//! logging.logTrace(&cfg, "Protocol state: {}\n", .{state});  // Level 4
//! ```

const std = @import("std");
const config = @import("../config.zig");

/// Global verbosity level (0-4)
/// Modified via setVerbosity(), checked by all log functions
/// Deprecated: Use Config.verbosity instead
var verbose_level: u8 = 0;

/// Set the verbosity level (deprecated)
///
/// Deprecated: Use Config.verbosity instead for type safety
///
/// Controls which log messages are printed to stderr.
///
/// Levels:
/// - 0: Quiet (errors only via logError)
/// - 1: Normal (connections, warnings, transfer stats)
/// - 2: Verbose (connection details)
/// - 3: Debug (protocol details)
/// - 4: Trace (all internal state)
///
/// Parameters:
/// - level: New verbosity level (0-4)
pub fn setVerbosity(level: u8) void {
    verbose_level = level;
}

/// Get current verbosity level (deprecated)
///
/// Deprecated: Use Config.verbosity instead
///
/// Returns: Current global verbosity level
pub fn getVerbosity() u8 {
    return verbose_level;
}

/// Log message at a specific verbosity level
///
/// Generic logging function that checks level before printing.
///
/// Parameters:
/// - level: Required verbosity level for this message (comptime)
/// - fmt: Format string (comptime)
/// - args: Format arguments (tuple of values)
///
/// Note: Only prints if current verbose_level >= level
pub fn log(comptime level: u8, comptime fmt: []const u8, args: anytype) void {
    if (level <= verbose_level) {
        logInternal("INFO", fmt, args);
    }
}

/// Log connection events (level 1)
///
/// Logs connection accept/close events with IP address.
///
/// Parameters:
/// - address: Client/server network address
/// - action: Event type (e.g., "ACCEPT", "CONNECT", "CLOSE")
///
/// Example output: "[ACCEPT] Connection from 127.0.0.1:54321"
pub fn logConnection(address: std.net.Address, action: []const u8) void {
    if (verbose_level > 0) {
        std.debug.print("[{s}] Connection from {any}\n", .{action, address});
    }
}

/// Log connection event with custom format (level 1)
///
/// Logs connection events with explicit host:port instead of Address.
///
/// Parameters:
/// - host: Hostname or IP address string
/// - port: Port number
/// - action: Event type (e.g., "CONNECT", "RESOLVE")
///
/// Example output: "[CONNECT] google.com:80"
pub fn logConnectionString(host: []const u8, port: u16, action: []const u8) void {
    if (verbose_level > 0) {
        logInternal(action, "{s}:{d}\n", .{ host, port });
    }
}

/// Log errors (always printed regardless of verbosity)
///
/// Error logging bypasses verbosity check for critical failures.
///
/// Parameters:
/// - err: Error value to display
/// - context: Operation context (e.g., "connect", "bind", "read")
///
/// Example output: "Error in connect: ConnectionRefused"
pub fn logError(err: anyerror, context: []const u8) void {
    logInternal("ERROR", "in {s}: {}\n", .{ context, err });
}

/// Log warning messages (level 0)
///
/// Warnings are always printed (level 0) for important non-error conditions.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
///
/// Example output: "Warning: TLS verification disabled"
pub fn logWarning(comptime fmt: []const u8, args: anytype) void {
    logInternal("WARN", fmt, args);
}

/// Log debug messages (level 2+)
///
/// Debug logging for development and troubleshooting.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
///
/// Example output: "[DEBUG] Socket buffer size: 8192"
pub fn logDebug(comptime fmt: []const u8, args: anytype) void {
    if (verbose_level >= 2) {
        logInternal("DEBUG", fmt, args);
    }
}

/// Log trace messages (level 3+)
///
/// Detailed tracing for protocol debugging.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
///
/// Example output: "[TRACE] TLS handshake: ClientHello sent"
pub fn logTrace(comptime fmt: []const u8, args: anytype) void {
    if (verbose_level >= 3) {
        logInternal("TRACE", fmt, args);
    }
}

/// Log data transfer statistics (level 1)
///
/// Prints summary of bidirectional transfer at completion.
///
/// Parameters:
/// - bytes_sent: Number of bytes sent to remote
/// - bytes_recv: Number of bytes received from remote
///
/// Example output:
/// ```
/// Transfer complete:
///   Sent: 1024 bytes
///   Received: 2048 bytes
/// ```
pub fn logTransferStats(bytes_sent: usize, bytes_recv: usize) void {
    if (verbose_level > 0) {
        std.debug.print("\nTransfer complete:\n", .{});
        std.debug.print("  Sent: {d} bytes\n", .{bytes_sent});
        std.debug.print("  Received: {d} bytes\n", .{bytes_recv});
    }
}

/// Log hex dump of data (level 2+)
///
/// Prints hexadecimal and ASCII representation of binary data.
/// Useful for debugging protocol implementations.
///
/// Format: 16 bytes per line with offset, hex bytes, and ASCII
///
/// Parameters:
/// - data: Binary data to display
/// - label: Description label for the dump
///
/// Example output:
/// ```
/// [TLS Handshake] Hex dump (32 bytes):
/// 0000:  16 03 01 00 1c 01 00 00 18 03 03 00 00 00 00 00  ................
/// 0010:  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
/// ```
pub fn logHexDump(data: []const u8, label: []const u8) void {
    if (verbose_level >= 2) {
        std.debug.print("[{s}] Hex dump ({d} bytes):\n", .{ label, data.len });

        var i: usize = 0;
        while (i < data.len) {
            std.debug.print("{x:0>4}:  ", .{i});

            // Print hex bytes
            var j: usize = 0;
            while (j < 16 and i + j < data.len) : (j += 1) {
                std.debug.print("{x:0>2} ", .{data[i + j]});
            }

            // Padding if last line is incomplete
            while (j < 16) : (j += 1) {
                std.debug.print("   ", .{});
            }

            std.debug.print(" ", .{});

            // Print ASCII representation
            j = 0;
            while (j < 16 and i + j < data.len) : (j += 1) {
                const byte = data[i + j];
                const char = if (byte >= 32 and byte < 127) byte else '.';
                std.debug.print("{c}", .{char});
            }

            std.debug.print("\n", .{});
            i += 16;
        }
    }
}

// =============================================================================
// NEW CONFIG-BASED LOGGING FUNCTIONS (Multi-Level Verbosity)
// =============================================================================

/// Check if a verbosity level is enabled in the configuration
///
/// Helper function for readable verbosity checks.
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - level: Minimum level required (comptime constant)
///
/// Returns: true if cfg.verbosity >= level
pub fn isVerbosityEnabled(cfg: *const config.Config, comptime level: config.VerbosityLevel) bool {
    return @intFromEnum(cfg.verbosity) >= @intFromEnum(level);
}

/// Log normal message (level 1 - normal)
///
/// Logs basic connection events, important messages.
/// Prints only if verbosity >= normal (not quiet)
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logNormal(cfg: *const config.Config, comptime fmt: []const u8, args: anytype) void {
    if (isVerbosityEnabled(cfg, .normal)) {
        logInternal("INFO", fmt, args);
    }
}

/// Log verbose message (level 2 - verbose)
///
/// Logs connection details, transfer stats, etc.
/// Prints only if verbosity >= verbose (enabled with -v)
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logVerbose(cfg: *const config.Config, comptime fmt: []const u8, args: anytype) void {
    if (isVerbosityEnabled(cfg, .verbose)) {
        logInternal("VERBOSE", fmt, args);
    }
}

fn logInternal(comptime level_str: []const u8, comptime fmt: []const u8, args: anytype) void {
    const timestamp = std.time.timestamp();
    std.debug.print("[{d}] [{s}] ", .{ timestamp, level_str });
    std.debug.print(fmt, args);
}

/// Log debug message (level 3 - debug)
///
/// Logs protocol details, hex dumps, etc.
/// Prints only if verbosity >= debug (enabled with -vv)
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logDebugCfg(cfg: *const config.Config, comptime fmt: []const u8, args: anytype) void {
    if (isVerbosityEnabled(cfg, .debug)) {
        logInternal("DEBUG", fmt, args);
    }
}

/// Log trace message (level 4 - trace)
///
/// Logs all internal state, detailed tracing.
/// Prints only if verbosity >= trace (enabled with -vvv)
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logTraceCfg(cfg: *const config.Config, comptime fmt: []const u8, args: anytype) void {
    if (isVerbosityEnabled(cfg, .trace)) {
        logInternal("TRACE", fmt, args);
    }
}
