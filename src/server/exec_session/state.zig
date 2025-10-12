// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Session state tracking and lifecycle management for exec sessions.
//!
//! Tracks which file descriptors are closed and provides queries for determining
//! whether the session should continue running.
const std = @import("std");
const IoRingBuffer = @import("../../util/io_ring_buffer.zig").IoRingBuffer;

// Use generic type parameter for buffer interface
// This allows both production code and tests to inject their buffer types
pub fn SessionStateFor(comptime BufferType: type) type {
    return struct {
        const Self = @This();

        socket_read_closed: bool = false,
        socket_write_closed: bool = false,
        child_stdin_closed: bool = false,
        child_stdout_closed: bool = false,
        child_stderr_closed: bool = false,

        pub fn shouldContinue(
            self: *const Self,
            stdin_buffer: *const BufferType,
            stdout_buffer: *const BufferType,
            stderr_buffer: *const BufferType,
        ) bool {
            // Condition 1: Pending output to socket
            if (!self.socket_write_closed and (stdout_buffer.availableRead() > 0 or stderr_buffer.availableRead() > 0)) {
                return true;
            }

            // Condition 2: Child may produce more output
            if (!self.child_stdout_closed or !self.child_stderr_closed) {
                return true;
            }

            // Condition 3: Pending input to child
            if (!self.child_stdin_closed and stdin_buffer.availableRead() > 0) {
                return true;
            }

            // Condition 4: Active relay path (socket → child)
            if (!self.socket_read_closed and !self.child_stdin_closed) {
                return true;
            }

            // All I/O paths closed and buffers empty
            return false;
        }

        pub fn canReadFromSocket(self: *const Self) bool {
            return !self.socket_read_closed and !self.child_stdin_closed;
        }

        pub fn canWriteToSocket(self: *const Self) bool {
            return !self.socket_write_closed;
        }

        pub fn canWriteToChildStdin(self: *const Self) bool {
            return !self.child_stdin_closed;
        }

        pub fn canReadFromChildStdout(self: *const Self) bool {
            return !self.child_stdout_closed;
        }

        pub fn canReadFromChildStderr(self: *const Self) bool {
            return !self.child_stderr_closed;
        }

        pub fn shouldShutdownSocketWrite(
            self: *const Self,
            stdout_buffer: *const BufferType,
            stderr_buffer: *const BufferType,
        ) bool {
            if (self.socket_write_closed) return false;
            if (stdout_buffer.availableRead() > 0 or stderr_buffer.availableRead() > 0) return false;
            if (!self.child_stdout_closed or !self.child_stderr_closed) return false;
            return true;
        }

        pub fn shouldCloseChildStdin(
            self: *const Self,
            stdin_buffer: *const BufferType,
        ) bool {
            if (self.child_stdin_closed) return false;
            return self.socket_read_closed and stdin_buffer.availableRead() == 0;
        }
    };
}

/// Session state tracking for socket and child process I/O streams.
///
/// Instantiation of SessionStateFor with IoRingBuffer as the buffer type.
/// This is the concrete type used in production exec sessions.
///
/// Each boolean field represents whether a particular I/O stream is closed:
/// - `socket_*_closed`: Network socket read/write directions
/// - `child_*_closed`: Child process stdin/stdout/stderr pipes
pub const SessionState = SessionStateFor(IoRingBuffer);

// ========================================================================
// Tests
// ========================================================================

test "SessionState shouldContinue with pending output" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stdin_buf = try IoRingBuffer.init(allocator, 16);
    defer stdin_buf.deinit();
    var stdout_buf = try IoRingBuffer.init(allocator, 16);
    defer stdout_buf.deinit();
    var stderr_buf = try IoRingBuffer.init(allocator, 16);
    defer stderr_buf.deinit();

    var state = SessionState{};

    // Write some data to stdout buffer
    try stdout_buf.writeAll("test");

    // Should continue because there's buffered output
    try testing.expect(state.shouldContinue(&stdin_buf, &stdout_buf, &stderr_buf));
}

test "SessionState shouldContinue with open child streams" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stdin_buf = try IoRingBuffer.init(allocator, 16);
    defer stdin_buf.deinit();
    var stdout_buf = try IoRingBuffer.init(allocator, 16);
    defer stdout_buf.deinit();
    var stderr_buf = try IoRingBuffer.init(allocator, 16);
    defer stderr_buf.deinit();

    var state = SessionState{};

    // Child stdout still open (even with no buffered data)
    try testing.expect(state.shouldContinue(&stdin_buf, &stdout_buf, &stderr_buf));

    // Close stdout, but stderr still open
    state.child_stdout_closed = true;
    try testing.expect(state.shouldContinue(&stdin_buf, &stdout_buf, &stderr_buf));
}

test "SessionState shouldContinue terminates when all closed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stdin_buf = try IoRingBuffer.init(allocator, 16);
    defer stdin_buf.deinit();
    var stdout_buf = try IoRingBuffer.init(allocator, 16);
    defer stdout_buf.deinit();
    var stderr_buf = try IoRingBuffer.init(allocator, 16);
    defer stderr_buf.deinit();

    var state = SessionState{
        .socket_read_closed = true,
        .socket_write_closed = true,
        .child_stdin_closed = true,
        .child_stdout_closed = true,
        .child_stderr_closed = true,
    };

    // All closed, no buffered data - should terminate
    try testing.expect(!state.shouldContinue(&stdin_buf, &stdout_buf, &stderr_buf));
}

test "SessionState shouldShutdownSocketWrite" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stdout_buf = try IoRingBuffer.init(allocator, 16);
    defer stdout_buf.deinit();
    var stderr_buf = try IoRingBuffer.init(allocator, 16);
    defer stderr_buf.deinit();

    var state = SessionState{};

    // Child streams open - don't shutdown
    try testing.expect(!state.shouldShutdownSocketWrite(&stdout_buf, &stderr_buf));

    // Close child streams
    state.child_stdout_closed = true;
    state.child_stderr_closed = true;

    // Should shutdown now (both child streams closed, no buffered data)
    try testing.expect(state.shouldShutdownSocketWrite(&stdout_buf, &stderr_buf));

    // Add buffered data - should NOT shutdown
    try stdout_buf.writeAll("data");
    try testing.expect(!state.shouldShutdownSocketWrite(&stdout_buf, &stderr_buf));
}

test "SessionState shouldCloseChildStdin" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stdin_buf = try IoRingBuffer.init(allocator, 16);
    defer stdin_buf.deinit();

    var state = SessionState{};

    // Socket still open - don't close stdin
    try testing.expect(!state.shouldCloseChildStdin(&stdin_buf));

    // Close socket read
    state.socket_read_closed = true;

    // Should close stdin now (socket closed, no buffered data)
    try testing.expect(state.shouldCloseChildStdin(&stdin_buf));

    // Add buffered data - should NOT close
    try stdin_buf.writeAll("data");
    try testing.expect(!state.shouldCloseChildStdin(&stdin_buf));
}
