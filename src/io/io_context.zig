// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Global Io instance management for zigcat.
//!
//! The std.Io interface must be initialized once at startup and passed
//! throughout the application for network operations, timers, and async I/O.
//!
//! Usage:
//! ```zig
//! var io_ctx = try IoContext.init(allocator);
//! defer io_ctx.deinit();
//!
//! // Pass io instance to network operations
//! const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
//! var listener = try addr.listen(io_ctx.io, .{ .reuse_address = true });
//! ```

const std = @import("std");

/// Global Io context wrapper for zigcat.
///
/// Manages the std.Io.Threaded backend which provides:
/// - Thread pool for concurrent operations
/// - Platform-specific optimizations (io_uring on Linux, kqueue on macOS)
/// - Async/await primitives for non-blocking I/O
pub const IoContext = struct {
    threaded: std.Io.Threaded,
    io: std.Io,

    /// Initialize the Io context with a thread pool.
    ///
    /// The thread pool size is automatically determined based on CPU count.
    /// For single-threaded mode, compile with -fsingle-threaded.
    ///
    /// Parameters:
    ///   allocator: Memory allocator for internal structures
    ///
    /// Returns: Initialized IoContext
    pub fn init(allocator: std.mem.Allocator) IoContext {
        var threaded: std.Io.Threaded = .init(allocator);
        return .{
            .threaded = threaded,
            .io = threaded.io(),
        };
    }

    /// Clean up the Io context and thread pool.
    ///
    /// This will wait for all pending operations to complete.
    pub fn deinit(self: *IoContext) void {
        self.threaded.deinit();
    }
};
