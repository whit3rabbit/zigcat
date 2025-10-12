// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Unified exec session interface with backend selection.
//!
//! This module provides a single ExecSession type that automatically selects
//! the best available I/O backend:
//! - IOCP: Windows (preferred, 10-20% CPU usage)
//! - io_uring: Linux 5.1+ (preferred, 5-10% CPU usage)
//! - poll: All Unix-like systems (fallback, 30-50% CPU usage)
//!
//! ## Usage
//! ```zig
//! // Automatic backend selection
//! var session = try ExecSession.init(allocator, telnet_conn, child, config);
//! defer session.deinit();
//! try session.run();
//!
//! // Force io_uring (returns error on unsupported systems)
//! var session = try ExecSession.initIoUring(allocator, telnet_conn, child, config);
//! defer session.deinit();
//! try session.run();
//! ```

const std = @import("std");
const builtin = @import("builtin");

const ExecSessionConfig = @import("../exec_types.zig").ExecSessionConfig;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;
const platform = @import("../../util/platform.zig");

const PollSession = @import("./poll_backend.zig").PollSession;
const UringSession = @import("./uring_backend.zig").UringSession;
const IocpSession = @import("./iocp_backend.zig").IocpSession;

/// Unified exec session with automatic backend selection.
///
/// This is a tagged union that dispatches to PollSession, UringSession, or IocpSession
/// based on platform capabilities and initialization method.
///
/// Backend selection priority:
/// 1. Windows: IOCP (10-20% CPU usage)
/// 2. Linux 5.1+: io_uring (5-10% CPU usage)
/// 3. Other Unix: poll (30-50% CPU usage)
pub const ExecSession = union(enum) {
    poll: PollSession,
    uring: UringSession,
    iocp: IocpSession,

    /// Initialize exec session with automatic backend selection.
    ///
    /// Platform-specific backend selection:
    /// - Windows: IOCP (high performance, 10-20% CPU usage)
    /// - Linux 5.1+: io_uring (highest performance, 5-10% CPU usage)
    /// - Other Unix: poll (fallback, 30-50% CPU usage)
    pub fn init(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !ExecSession {
        // Windows: Try IOCP first (preferred on Windows)
        if (builtin.os.tag == .windows) {
            if (IocpSession.init(allocator, telnet_conn, child, cfg)) |iocp_session| {
                return ExecSession{ .iocp = iocp_session };
            } else |_| {
                // Fall through to poll on error (unlikely on Windows 10+)
            }
        }

        // Linux: Try io_uring on 5.1+ first
        if (builtin.os.tag == .linux and platform.isIoUringSupported()) {
            if (UringSession.init(allocator, telnet_conn, child, cfg)) |uring_session| {
                return ExecSession{ .uring = uring_session };
            } else |_| {
                // Fall through to poll on error
            }
        }

        // Fallback to poll-based session (all platforms)
        const poll_session = try PollSession.init(allocator, telnet_conn, child, cfg);
        return ExecSession{ .poll = poll_session };
    }

    /// Initialize exec session with io_uring backend (Linux 5.1+ only).
    ///
    /// Returns error.IoUringNotSupported on non-Linux or older kernels.
    /// Use this when you specifically need io_uring's performance characteristics.
    pub fn initIoUring(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !ExecSession {
        const uring_session = try UringSession.init(allocator, telnet_conn, child, cfg);
        return ExecSession{ .uring = uring_session };
    }

    /// Clean up resources used by the exec session.
    pub fn deinit(self: *ExecSession) void {
        switch (self.*) {
            .poll => |*poll_session| poll_session.deinit(),
            .uring => |*uring_session| uring_session.deinit(),
            .iocp => |*iocp_session| iocp_session.deinit(),
        }
    }

    /// Run the I/O event loop until completion.
    ///
    /// This method blocks until all I/O is complete or an error occurs.
    /// The session will automatically handle:
    /// - Bidirectional data transfer (socket ↔ child stdin/stdout/stderr)
    /// - Flow control (pause/resume based on buffer thresholds)
    /// - Timeout management (execution, idle, connection timeouts)
    /// - Graceful shutdown when all streams are closed
    pub fn run(self: *ExecSession) !void {
        switch (self.*) {
            .poll => |*poll_session| try poll_session.run(),
            .uring => |*uring_session| try uring_session.run(),
            .iocp => |*iocp_session| try iocp_session.run(),
        }
    }
};

// Re-export public types from submodules for convenience
pub const FlowState = @import("./flow_control.zig").FlowState;
pub const computeThresholdBytes = @import("./flow_control.zig").computeThresholdBytes;
pub const SessionState = @import("./state.zig").SessionState;
pub const SocketReadContext = @import("./socket_io.zig").SocketReadContext;
pub const SocketWriteContext = @import("./socket_io.zig").SocketWriteContext;
pub const ChildReadContext = @import("./child_io.zig").ChildReadContext;
pub const ChildWriteContext = @import("./child_io.zig").ChildWriteContext;

// ========================================================================
// Tests
// ========================================================================

test "ExecSession enum size" {
    const testing = std.testing;

    // Verify tagged union has reasonable size (should be close to largest variant)
    const size = @sizeOf(ExecSession);

    // Sanity check: Should be at least as large as PollSession
    const poll_size = @sizeOf(PollSession);
    try testing.expect(size >= poll_size);
}

test "ExecSession backends available" {
    const testing = std.testing;

    // Verify all backend types are available in the union
    const T = ExecSession;
    try testing.expect(@hasField(T, "poll"));
    try testing.expect(@hasField(T, "uring"));
    try testing.expect(@hasField(T, "iocp"));
}
