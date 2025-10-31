// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


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

/// Log warning messages (always printed)
///
/// Warnings are always printed for important non-error conditions.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
///
/// Example output: "Warning: TLS verification disabled"
pub fn logWarning(comptime fmt: []const u8, args: anytype) void {
    logInternal("WARN", fmt, args);
}

// =============================================================================
// CONFIG-BASED LOGGING FUNCTIONS
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

/// Log connection events with Address (level 1 - normal)
///
/// Logs connection accept/close events with IP address.
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - address: Client/server network address
/// - action: Event type (e.g., "ACCEPT", "CONNECT", "CLOSE")
///
/// Example output: "[ACCEPT] Connection from 127.0.0.1:54321"
pub fn logConnectionAddr(cfg: *const config.Config, address: std.net.Address, action: []const u8) void {
    if (isVerbosityEnabled(cfg, .normal)) {
        std.debug.print("[{s}] Connection from {any}\n", .{ action, address });
    }
}

/// Log connection event with host:port format (level 1 - normal)
///
/// Logs connection events with explicit host:port instead of Address.
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - host: Hostname or IP address string
/// - port: Port number
/// - action: Event type (e.g., "CONNECT", "RESOLVE")
///
/// Example output: "[CONNECT] google.com:80"
pub fn logConnectionHost(cfg: *const config.Config, host: []const u8, port: u16, action: []const u8) void {
    if (isVerbosityEnabled(cfg, .normal)) {
        logInternal(action, "{s}:{d}\n", .{ host, port });
    }
}

/// Log data transfer statistics (level 1 - normal)
///
/// Prints summary of bidirectional transfer at completion.
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - bytes_sent: Number of bytes sent to remote
/// - bytes_recv: Number of bytes received from remote
///
/// Example output:
/// ```
/// Transfer complete:
///   Sent: 1024 bytes
///   Received: 2048 bytes
/// ```
pub fn logTransferStatsCfg(cfg: *const config.Config, bytes_sent: usize, bytes_recv: usize) void {
    if (isVerbosityEnabled(cfg, .normal)) {
        std.debug.print("\nTransfer complete:\n", .{});
        std.debug.print("  Sent: {d} bytes\n", .{bytes_sent});
        std.debug.print("  Received: {d} bytes\n", .{bytes_recv});
    }
}

/// Log hex dump of data (level 2 - verbose)
///
/// Prints hexadecimal and ASCII representation of binary data.
/// Useful for debugging protocol implementations.
///
/// Format: 16 bytes per line with offset, hex bytes, and ASCII
///
/// Parameters:
/// - cfg: Configuration with verbosity level
/// - data: Binary data to display
/// - label: Description label for the dump
///
/// Example output:
/// ```
/// [TLS Handshake] Hex dump (32 bytes):
/// 0000:  16 03 01 00 1c 01 00 00 18 03 03 00 00 00 00 00  ................
/// 0010:  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
/// ```
pub fn logHexDumpCfg(cfg: *const config.Config, data: []const u8, label: []const u8) void {
    if (isVerbosityEnabled(cfg, .verbose)) {
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

fn logInternal(comptime level_str: []const u8, comptime fmt: []const u8, args: anytype) void {
    // Get current Unix timestamp (seconds since epoch)
    // In Zig 0.16+, use Instant for time queries
    const instant = std.time.Instant.now() catch {
        std.debug.print("[?] [{s}] ", .{level_str});
        std.debug.print(fmt, args);
        return;
    };
    // For logging, we just need a rough timestamp - use nanoseconds / 1e9 for seconds
    const timestamp_sec = @divFloor(instant.timestamp.sec, 1);
    std.debug.print("[{d}] [{s}] ", .{ timestamp_sec, level_str });
    std.debug.print(fmt, args);
}

// =============================================================================
// DEPRECATED LEGACY FUNCTIONS (for backward compatibility)
// =============================================================================
// These functions exist for backward compatibility with code that doesn't
// have access to Config. They always log at debug level.
// New code should use Config-based functions (logDebugCfg, logTraceCfg, etc).

/// Log message at specific level without Config (deprecated, always logs)
///
/// DEPRECATED: Use Config-based logging functions instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - level: Verbosity level (ignored, provided for API compatibility)
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn log(comptime level: u8, comptime fmt: []const u8, args: anytype) void {
    _ = level; // Ignored for backward compatibility
    logInternal("INFO", fmt, args);
}

/// Log debug messages without Config (deprecated, always logs)
///
/// DEPRECATED: Use logDebugCfg(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logDebug(comptime fmt: []const u8, args: anytype) void {
    logInternal("DEBUG", fmt, args);
}

/// Log trace messages without Config (deprecated, always logs)
///
/// DEPRECATED: Use logTraceCfg(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - fmt: Format string (comptime)
/// - args: Format arguments
pub fn logTrace(comptime fmt: []const u8, args: anytype) void {
    logInternal("TRACE", fmt, args);
}

/// Log connection events without Config (deprecated, always logs)
///
/// DEPRECATED: Use logConnectionAddr(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - address: Client/server network address
/// - action: Event type (e.g., "ACCEPT", "CONNECT", "CLOSE")
pub fn logConnection(address: std.Io.net.IpAddress, action: []const u8) void {
    std.debug.print("[{s}] Connection from {any}\n", .{ action, address });
}

/// Log connection event with host:port without Config (deprecated, always logs)
///
/// DEPRECATED: Use logConnectionHost(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - host: Hostname or IP address string
/// - port: Port number
/// - action: Event type (e.g., "CONNECT", "RESOLVE")
pub fn logConnectionString(host: []const u8, port: u16, action: []const u8) void {
    logInternal(action, "{s}:{d}\n", .{ host, port });
}

/// Log transfer statistics without Config (deprecated, always logs)
///
/// DEPRECATED: Use logTransferStatsCfg(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - bytes_sent: Number of bytes sent to remote
/// - bytes_recv: Number of bytes received from remote
pub fn logTransferStats(bytes_sent: usize, bytes_recv: usize) void {
    std.debug.print("\nTransfer complete:\n", .{});
    std.debug.print("  Sent: {d} bytes\n", .{bytes_sent});
    std.debug.print("  Received: {d} bytes\n", .{bytes_recv});
}

/// Log hex dump without Config (deprecated, always logs)
///
/// DEPRECATED: Use logHexDumpCfg(cfg, ...) instead for proper verbosity control.
/// This function always logs regardless of verbosity for backward compatibility.
///
/// Parameters:
/// - data: Binary data to display
/// - label: Description label for the dump
pub fn logHexDump(data: []const u8, label: []const u8) void {
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
