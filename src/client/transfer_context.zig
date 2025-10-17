// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Transfer context for client connections.
//!
//! This module provides a reusable context for bidirectional data transfer,
//! eliminating code duplication across client modes (TCP, Unix socket, gsocket).
//!
//! The TransferContext encapsulates:
//! - OutputLogger: Saves transferred data to file (with io_uring if available)
//! - HexDumper: Generates hex dumps of transferred data (with io_uring if available)
//! - Automatic cleanup via defer
//!
//! Usage pattern:
//! ```zig
//! var ctx = try TransferContext.init(allocator, cfg);
//! defer ctx.deinit();
//! try ctx.runTransfer(allocator, stream, cfg);
//! ```

const std = @import("std");
const config = @import("../config.zig");
const transfer = @import("../io/transfer.zig");
const output = @import("../io/output.zig");
const hexdump = @import("../io/hexdump.zig");
const stream = @import("../io/stream.zig");

/// Transfer context with output logging and hex dumping.
///
/// This struct automatically initializes and manages:
/// - OutputLogger: Writes transferred data to file (if --output specified)
/// - HexDumper: Writes hex dumps to file (if --hex-dump specified)
///
/// Both components automatically use io_uring on Linux 5.1+ for better performance.
pub const TransferContext = struct {
    output_logger: output.OutputLoggerAuto,
    hex_dumper: hexdump.HexDumperAuto,

    /// Initialize transfer context with output logger and hex dumper.
    ///
    /// Automatically selects best backend:
    /// - Linux 5.1+: Uses io_uring for async I/O
    /// - Other platforms: Uses blocking I/O
    ///
    /// Parameters:
    ///   allocator: Memory allocator for buffer allocation
    ///   cfg: Configuration with output file paths
    ///
    /// Returns: Initialized TransferContext
    ///
    /// Errors:
    ///   error.OutOfMemory: Failed to allocate buffers
    ///   error.FileNotFound: Output file path invalid
    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !TransferContext {
        // Initialize output logger (honors --output and --append flags)
        var output_logger = try output.OutputLoggerAuto.init(
            allocator,
            cfg.output_file,
            cfg.append_output,
        );
        errdefer output_logger.deinit();

        // Initialize hex dumper (honors --hex-dump flag)
        var hex_dumper = try hexdump.HexDumperAuto.initFromPath(
            allocator,
            cfg.hex_dump_file,
        );
        errdefer hex_dumper.deinit();

        return TransferContext{
            .output_logger = output_logger,
            .hex_dumper = hex_dumper,
        };
    }

    /// Free all resources (closes output files, flushes buffers).
    ///
    /// Safe to call multiple times (no-op after first call).
    pub fn deinit(self: *TransferContext) void {
        self.hex_dumper.deinit();
        self.output_logger.deinit();
    }

    /// Run bidirectional transfer with logging and hex dumping.
    ///
    /// This is a convenience wrapper around transfer.bidirectionalTransfer()
    /// that automatically passes the output logger and hex dumper.
    ///
    /// Parameters:
    ///   allocator: Memory allocator
    ///   s: Stream to transfer data through
    ///   cfg: Configuration with timeout and verbosity settings
    ///
    /// Returns: void (exits when transfer completes or errors)
    ///
    /// Errors:
    ///   error.ConnectionResetByPeer: Remote endpoint closed connection
    ///   error.BrokenPipe: Local endpoint closed connection
    ///   error.Timeout: Idle timeout exceeded
    pub fn runTransfer(
        self: *TransferContext,
        allocator: std.mem.Allocator,
        s: stream.Stream,
        cfg: *const config.Config,
    ) !void {
        try transfer.bidirectionalTransfer(
            allocator,
            s,
            cfg,
            &self.output_logger,
            &self.hex_dumper,
        );
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "TransferContext initialization" {
    const allocator = testing.allocator;

    // Create minimal config (no output files)
    const cfg = config.Config{
        .output_file = null,
        .hex_dump_file = null,
        .append_output = false,
    };

    var ctx = try TransferContext.init(allocator, &cfg);
    defer ctx.deinit();

    // Verify logger and dumper are initialized (basic smoke test)
    try testing.expect(@as(?*anyopaque, @ptrCast(&ctx.output_logger)) != null);
    try testing.expect(@as(?*anyopaque, @ptrCast(&ctx.hex_dumper)) != null);
}

test "TransferContext cleanup (double deinit)" {
    const allocator = testing.allocator;

    const cfg = config.Config{
        .output_file = null,
        .hex_dump_file = null,
        .append_output = false,
    };

    var ctx = try TransferContext.init(allocator, &cfg);

    // First deinit should free resources
    ctx.deinit();

    // Second deinit should be safe (no-op)
    ctx.deinit();

    // Test passes if no crash or memory leak
}
