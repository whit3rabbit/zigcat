// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Socket I/O handlers for exec session.
//!
//! This module provides helper functions for reading from and writing to network sockets
//! in the context of an exec session. All functions handle non-blocking I/O with proper
//! error handling for connection resets, broken pipes, and WouldBlock conditions.
//!
//! ## Key Features
//! - Non-blocking socket reads with flow control awareness
//! - Buffered socket writes with partial write handling
//! - Graceful error handling (connection resets, broken pipes)
//! - Activity tracking for idle timeout management

const std = @import("std");
const posix = std.posix;
const IoRingBuffer = @import("../../util/io_ring_buffer.zig").IoRingBuffer;
const TimeoutTracker = @import("../../util/timeout_tracker.zig").TimeoutTracker;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;
const FlowState = @import("./flow_control.zig").FlowState;

/// Context for socket read operations.
pub const SocketReadContext = struct {
    telnet_conn: *TelnetConnection,
    stdin_buffer: *IoRingBuffer,
    tracker: *TimeoutTracker,
    flow_state: *const FlowState,
    flow_enabled: bool,
    socket_read_closed: *bool,
    child_stdin_closed: bool,
};

/// Context for socket write operations.
pub const SocketWriteContext = struct {
    telnet_conn: *TelnetConnection,
    tracker: *TimeoutTracker,
    socket_write_closed: *bool,
};

/// Read from socket into stdin buffer with flow control.
///
/// Reads data from the telnet connection into the stdin buffer, respecting flow control
/// pauses and handling non-blocking I/O errors. Returns the number of bytes read, or
/// sets socket_read_closed on EOF/error.
///
/// ## Error Handling
/// - WouldBlock: Returns immediately (no error)
/// - ConnectionResetByPeer/BrokenPipe: Sets socket_read_closed, returns immediately
/// - Other errors: Sets socket_read_closed, returns immediately (logs but doesn't fail)
pub fn readSocketToBuffer(ctx: *SocketReadContext) !usize {
    var total_read: usize = 0;

    while (!ctx.socket_read_closed.* and !ctx.child_stdin_closed) {
        // Check flow control - pause if thresholds exceeded
        if (ctx.flow_enabled and ctx.flow_state.shouldPause()) break;

        const writable = ctx.stdin_buffer.writableSlice();
        if (writable.len == 0) break;

        const read_bytes = ctx.telnet_conn.read(writable) catch |err| {
            switch (err) {
                error.WouldBlock => return total_read,
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    ctx.socket_read_closed.* = true;
                    return total_read;
                },
                else => {
                    // Log but don't fail - socket may already be closed
                    ctx.socket_read_closed.* = true;
                    return total_read;
                },
            }
        };

        // EOF - socket closed by peer
        if (read_bytes == 0) {
            ctx.socket_read_closed.* = true;
            break;
        }

        ctx.stdin_buffer.commitWrite(read_bytes);
        ctx.tracker.markActivity();
        total_read += read_bytes;

        // Partial read - socket would block on next read
        if (read_bytes < writable.len) break;
    }

    return total_read;
}

/// Write from buffer to socket with non-blocking I/O.
///
/// Writes as much data as possible from the buffer to the socket without blocking.
/// Handles partial writes by consuming only the successfully written bytes and
/// returns the total number of bytes flushed.
///
/// ## Error Handling
/// - WouldBlock: Returns immediately after consuming written bytes
/// - ConnectionResetByPeer/BrokenPipe: Sets socket_write_closed, returns immediately
/// - Other errors: Sets socket_write_closed, returns immediately (logs but doesn't fail)
pub fn flushBufferToSocket(
    buffer: *IoRingBuffer,
    ctx: *SocketWriteContext,
) !usize {
    var total_written: usize = 0;

    while (!ctx.socket_write_closed.* and buffer.availableRead() > 0) {
        const chunk = buffer.readableSlice();
        if (chunk.len == 0) break;

        const written = ctx.telnet_conn.write(chunk) catch |err| {
            switch (err) {
                error.WouldBlock => return total_written,
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    ctx.socket_write_closed.* = true;
                    return total_written;
                },
                else => {
                    // Log but don't fail - socket may already be closed
                    ctx.socket_write_closed.* = true;
                    return total_written;
                },
            }
        };

        if (written == 0) break;

        buffer.consume(written);
        ctx.tracker.markActivity();
        total_written += written;

        // Partial write - socket would block on next write
        if (written < chunk.len) break;
    }

    return total_written;
}

/// Flush a set of buffers to the socket in order.
///
/// Attempts to write each buffer in `buffers` to the socket using the provided
/// context. Stops early if the socket becomes closed. Returns the total number
/// of bytes written across all buffers.
pub fn pipeBuffersToSocket(
    buffers: []const *IoRingBuffer,
    ctx: *SocketWriteContext,
) !usize {
    var total_written: usize = 0;

    for (buffers) |buffer| {
        total_written += try flushBufferToSocket(buffer, ctx);
        if (ctx.socket_write_closed.*) break;
    }

    return total_written;
}

// ========================================================================
// Tests
// ========================================================================

test "SocketReadContext has required fields" {
    // Compile-time test to ensure context struct matches expectations
    const testing = std.testing;
    const T = SocketReadContext;

    // Verify field types exist
    const has_telnet_conn = @hasField(T, "telnet_conn");
    const has_stdin_buffer = @hasField(T, "stdin_buffer");
    const has_tracker = @hasField(T, "tracker");
    const has_flow_state = @hasField(T, "flow_state");

    try testing.expect(has_telnet_conn);
    try testing.expect(has_stdin_buffer);
    try testing.expect(has_tracker);
    try testing.expect(has_flow_state);
}

test "SocketWriteContext has required fields" {
    // Compile-time test to ensure context struct matches expectations
    const testing = std.testing;
    const T = SocketWriteContext;

    // Verify field types exist
    const has_telnet_conn = @hasField(T, "telnet_conn");
    const has_tracker = @hasField(T, "tracker");
    const has_socket_write_closed = @hasField(T, "socket_write_closed");

    try testing.expect(has_telnet_conn);
    try testing.expect(has_tracker);
    try testing.expect(has_socket_write_closed);
}
