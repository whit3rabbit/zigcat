//! Configuration-based logging system for zigcat.
//!
//! All logging functions now require a Config reference to determine verbosity.
//! This eliminates global state and improves testability.
//!
//! Verbosity Levels:
//! - quiet (0): Silent (errors only)
//! - normal (1): Default (connections, warnings)
//! - verbose (2): Connection details (via -v)
//! - debug (3): Protocol details (via -vv)
//! - trace (4): All internal state (via -vvv)
//!
//! Usage:
//! ```zig
//! const cfg = Config{ .verbosity = .verbose };
//! logging.logVerbose(&cfg, "Connected to {s}\n", .{host});  // Level 2
//! logging.logDebugCfg(&cfg, "Data: {x}\n", .{data});  // Level 3
//! logging.logTraceCfg(&cfg, "Protocol state: {}\n", .{state});  // Level 4
//! ```

const std = @import("std");
const config = @import("../config.zig");

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
