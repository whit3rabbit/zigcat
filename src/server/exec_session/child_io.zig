// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Child process I/O handlers for exec session.
//!
//! This module provides helper functions for managing I/O between an exec session
//! and a child process's stdin/stdout/stderr streams. All functions handle non-blocking
//! I/O with proper error handling for broken pipes and process termination.
//!
//! ## Key Features
//! - Non-blocking reads from child stdout/stderr with flow control
//! - Non-blocking writes to child stdin with buffering
//! - Graceful pipe closure detection
//! - Activity tracking for idle timeout management

const std = @import("std");
const posix = std.posix;
const IoRingBuffer = @import("../../util/io_ring_buffer.zig").IoRingBuffer;
const TimeoutTracker = @import("../../util/timeout_tracker.zig").TimeoutTracker;
const FlowState = @import("./flow_control.zig").FlowState;

/// Context for child stdout/stderr read operations.
pub const ChildReadContext = struct {
    fd: posix.fd_t,
    buffer: *IoRingBuffer,
    tracker: *TimeoutTracker,
    flow_state: *const FlowState,
    flow_enabled: bool,
    stream_closed: *bool,
};

/// Context for child stdin write operations.
pub const ChildWriteContext = struct {
    fd: posix.fd_t,
    buffer: *IoRingBuffer,
    tracker: *TimeoutTracker,
    stdin_closed: *bool,
    socket_read_closed: bool,
};

/// Read from child output stream (stdout or stderr) into buffer.
///
/// Reads data from a child process's stdout or stderr into the provided buffer,
/// respecting flow control pauses. Returns the number of bytes read, or sets
/// stream_closed on EOF/error.
///
/// ## Error Handling
/// - WouldBlock: Returns immediately (no error)
/// - BrokenPipe: Sets stream_closed, returns immediately
/// - Other errors: Sets stream_closed (child may have exited), returns immediately
pub fn readChildStreamToBuffer(ctx: *ChildReadContext) !usize {
    var total_read: usize = 0;

    while (!ctx.stream_closed.*) {
        // Check flow control - pause if thresholds exceeded
        if (ctx.flow_enabled and ctx.flow_state.shouldPause()) break;

        const writable = ctx.buffer.writableSlice();
        if (writable.len == 0) break;

        const read_bytes = posix.read(ctx.fd, writable) catch |err| {
            switch (err) {
                error.WouldBlock => return total_read,
                error.BrokenPipe => {
                    ctx.stream_closed.* = true;
                    return total_read;
                },
                else => {
                    // Child may have exited - close stream and continue
                    ctx.stream_closed.* = true;
                    return total_read;
                },
            }
        };

        // EOF - child closed this output stream
        if (read_bytes == 0) {
            ctx.stream_closed.* = true;
            break;
        }

        ctx.buffer.commitWrite(read_bytes);
        ctx.tracker.markActivity();
        total_read += read_bytes;

        // Partial read - would block on next read
        if (read_bytes < writable.len) break;
    }

    return total_read;
}

/// Write from buffer to child stdin with non-blocking I/O.
///
/// Writes as much data as possible from the buffer to the child's stdin without blocking.
/// Handles partial writes by consuming only the successfully written bytes. Automatically
/// closes stdin when socket is closed and buffer is empty.
///
/// ## Error Handling
/// - WouldBlock: Returns immediately after consuming written bytes
/// - BrokenPipe: Sets stdin_closed, returns immediately
/// - Other errors: Sets stdin_closed (child may have exited), returns immediately
pub fn writeBufferToChildStdin(ctx: *ChildWriteContext) !usize {
    var total_written: usize = 0;

    while (!ctx.stdin_closed.* and ctx.buffer.availableRead() > 0) {
        const chunk = ctx.buffer.readableSlice();
        if (chunk.len == 0) break;

        const written = posix.write(ctx.fd, chunk) catch |err| {
            switch (err) {
                error.WouldBlock => return total_written,
                error.BrokenPipe => {
                    ctx.stdin_closed.* = true;
                    return total_written;
                },
                else => {
                    // Child may have exited - close stdin and continue
                    ctx.stdin_closed.* = true;
                    return total_written;
                },
            }
        };

        if (written == 0) break;

        ctx.buffer.consume(written);
        ctx.tracker.markActivity();
        total_written += written;

        // Partial write - would block on next write
        if (written < chunk.len) break;
    }

    // Auto-close stdin when socket is closed and buffer is drained
    if (ctx.socket_read_closed and ctx.buffer.availableRead() == 0 and !ctx.stdin_closed.*) {
        ctx.stdin_closed.* = true;
    }

    return total_written;
}

/// Close a child process's file descriptor and mark stream as closed.
///
/// Safely closes a child process's stdin, stdout, or stderr file handle. Updates the
/// provided stream_closed flag and nullifies the file handle in the child process struct.
///
/// ## Parameters
/// - `child`: Pointer to the child process struct
/// - `file_field`: Pointer to the optional file field (stdin/stdout/stderr)
/// - `stream_closed`: Pointer to boolean tracking closed state
pub fn closeChildStream(
    file_field: *?std.fs.File,
    stream_closed: *bool,
) void {
    if (stream_closed.*) return;

    if (file_field.*) |file| {
        file.close();
        file_field.* = null;
    }
    stream_closed.* = true;
}

// ========================================================================
// Tests
// ========================================================================

test "ChildReadContext has required fields" {
    // Compile-time test to ensure context struct matches expectations
    const testing = std.testing;
    const T = ChildReadContext;

    // Verify field types exist
    const has_fd = @hasField(T, "fd");
    const has_buffer = @hasField(T, "buffer");
    const has_tracker = @hasField(T, "tracker");
    const has_flow_state = @hasField(T, "flow_state");
    const has_stream_closed = @hasField(T, "stream_closed");

    try testing.expect(has_fd);
    try testing.expect(has_buffer);
    try testing.expect(has_tracker);
    try testing.expect(has_flow_state);
    try testing.expect(has_stream_closed);
}

test "ChildWriteContext has required fields" {
    // Compile-time test to ensure context struct matches expectations
    const testing = std.testing;
    const T = ChildWriteContext;

    // Verify field types exist
    const has_fd = @hasField(T, "fd");
    const has_buffer = @hasField(T, "buffer");
    const has_tracker = @hasField(T, "tracker");
    const has_stdin_closed = @hasField(T, "stdin_closed");
    const has_socket_read_closed = @hasField(T, "socket_read_closed");

    try testing.expect(has_fd);
    try testing.expect(has_buffer);
    try testing.expect(has_tracker);
    try testing.expect(has_stdin_closed);
    try testing.expect(has_socket_read_closed);
}

test "closeChildStream idempotent" {
    // Test that closing a stream multiple times is safe
    const testing = std.testing;

    var file_opt: ?std.fs.File = null;
    var stream_closed: bool = false;

    // First close
    closeChildStream(&file_opt, &stream_closed);
    try testing.expect(stream_closed);
    try testing.expect(file_opt == null);

    // Second close (should be no-op)
    closeChildStream(&file_opt, &stream_closed);
    try testing.expect(stream_closed);
    try testing.expect(file_opt == null);
}
