// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! io_uring-based backend for exec session (Linux 5.1+ only).
//!
//! This module provides a high-performance io_uring event loop for managing
//! bidirectional I/O between a network socket and a child process. It offers
//! 5-10x lower CPU usage compared to poll-based I/O through kernel-managed
//! asynchronous operations.
//!
//! ## Key Features
//! - True asynchronous I/O via io_uring (Linux 5.1+)
//! - Zero syscall overhead for I/O operations
//! - Batched operation submission
//! - Flow control integration
//! - Timeout management
//! - Automatic fallback to poll on errors

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const math = std.math;

const IoRingBuffer = @import("../../util/io_ring_buffer.zig").IoRingBuffer;
const TimeoutTracker = @import("../../util/timeout_tracker.zig").TimeoutTracker;
const ExecSessionConfig = @import("../exec_types.zig").ExecSessionConfig;
const ExecError = @import("../exec_types.zig").ExecError;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;
const io_uring_wrapper = @import("../../util/io_uring_wrapper.zig");
const UringEventLoop = io_uring_wrapper.UringEventLoop;
const CompletionResult = io_uring_wrapper.CompletionResult;
const FlowState = @import("./flow_control.zig").FlowState;
const computeThresholdBytes = @import("./flow_control.zig").computeThresholdBytes;

/// Implements the exec session I/O loop using Linux's `io_uring` interface.
///
/// This struct provides a high-performance, fully asynchronous I/O backend for
/// managing the data flow between a network socket and a child process's standard
/// I/O. It is the preferred backend on modern Linux systems (kernel 5.1+).
///
/// The session leverages a `UringEventLoop` to submit and complete I/O requests
/// (reads and writes) with minimal syscall overhead. It also integrates flow
/// control and timeout management, similar to the other backends.
pub const UringSession = struct {
    // User data constants for io_uring operation tracking
    const USER_DATA_SOCKET_READ: u64 = 1;
    const USER_DATA_SOCKET_WRITE: u64 = 2;
    const USER_DATA_STDIN_WRITE: u64 = 3;
    const USER_DATA_STDOUT_READ: u64 = 4;
    const USER_DATA_STDERR_READ: u64 = 5;

    allocator: std.mem.Allocator,
    telnet_conn: *TelnetConnection,
    socket_fd: posix.fd_t,
    child: *std.process.Child,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    stderr_fd: posix.fd_t,
    stdin_buffer: IoRingBuffer,
    stdout_buffer: IoRingBuffer,
    stderr_buffer: IoRingBuffer,
    flow_state: FlowState,
    max_total_buffer_bytes: usize,
    tracker: TimeoutTracker,
    config: ExecSessionConfig,
    socket_read_closed: bool = false,
    socket_write_closed: bool = false,
    child_stdin_closed: bool = false,
    child_stdout_closed: bool = false,
    child_stderr_closed: bool = false,
    flow_enabled: bool = true,
    ring: UringEventLoop,
    // Pending async operations tracking
    socket_read_pending: bool = false,
    socket_write_pending: bool = false,
    stdin_write_pending: bool = false,
    stdout_read_pending: bool = false,
    stderr_read_pending: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !UringSession {
        // Only available on Linux
        if (builtin.os.tag != .linux) {
            return error.IoUringNotSupported;
        }

        if (builtin.os.tag == .windows) {
            return error.Unsupported;
        }

        const stdin_fd = if (child.stdin) |f| f.handle else -1;
        const stdout_fd = if (child.stdout) |f| f.handle else -1;
        const stderr_fd = if (child.stderr) |f| f.handle else -1;
        const socket_fd: posix.fd_t = telnet_conn.getSocket();

        try setFdNonBlocking(socket_fd);
        if (stdin_fd != -1) try setFdNonBlocking(stdin_fd);
        if (stdout_fd != -1) try setFdNonBlocking(stdout_fd);
        if (stderr_fd != -1) try setFdNonBlocking(stderr_fd);

        var stdin_buffer = try IoRingBuffer.init(allocator, cfg.buffers.stdin_capacity);
        errdefer stdin_buffer.deinit();

        var stdout_buffer = try IoRingBuffer.init(allocator, cfg.buffers.stdout_capacity);
        errdefer stdout_buffer.deinit();

        var stderr_buffer = try IoRingBuffer.init(allocator, cfg.buffers.stderr_capacity);
        errdefer stderr_buffer.deinit();

        const total_capacity = cfg.buffers.stdin_capacity + cfg.buffers.stdout_capacity + cfg.buffers.stderr_capacity;
        var max_total = cfg.flow.max_total_buffer_bytes;
        if (max_total == 0) {
            max_total = total_capacity;
        }
        if (max_total < total_capacity) {
            return ExecError.InvalidConfiguration;
        }

        var pause_bytes = computeThresholdBytes(max_total, cfg.flow.pause_threshold_percent);
        var resume_bytes = computeThresholdBytes(max_total, cfg.flow.resume_threshold_percent);
        var flow_enabled = true;

        if (pause_bytes == 0) {
            flow_enabled = false;
            pause_bytes = max_total;
            resume_bytes = max_total;
        }

        if (resume_bytes >= pause_bytes and pause_bytes > 0) {
            const adjust = @max(@as(usize, 1), pause_bytes / 4);
            if (adjust >= pause_bytes) {
                resume_bytes = pause_bytes - 1;
            } else {
                resume_bytes = pause_bytes - adjust;
            }
        }

        // Initialize io_uring with 64-entry queue (enough for exec session)
        var ring = try UringEventLoop.init(allocator, 64);
        errdefer ring.deinit();

        var session = UringSession{
            .allocator = allocator,
            .telnet_conn = telnet_conn,
            .socket_fd = socket_fd,
            .child = child,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .stderr_fd = stderr_fd,
            .stdin_buffer = stdin_buffer,
            .stdout_buffer = stdout_buffer,
            .stderr_buffer = stderr_buffer,
            .flow_state = FlowState{
                .pause_threshold_bytes = pause_bytes,
                .resume_threshold_bytes = resume_bytes,
            },
            .max_total_buffer_bytes = max_total,
            .tracker = TimeoutTracker.init(cfg.timeouts),
            .config = cfg,
            .socket_read_closed = false,
            .socket_write_closed = false,
            .child_stdin_closed = (stdin_fd == -1),
            .child_stdout_closed = (stdout_fd == -1),
            .child_stderr_closed = (stderr_fd == -1),
            .flow_enabled = flow_enabled,
            .ring = ring,
        };

        try session.updateFlow();

        return session;
    }

    pub fn deinit(self: *UringSession) void {
        self.ring.deinit();
        self.stdin_buffer.deinit();
        self.stdout_buffer.deinit();
        self.stderr_buffer.deinit();
    }

    pub fn run(self: *UringSession) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        // Submit initial read operations for all open FDs
        try self.submitUringReads();

        while (self.shouldContinue()) {
            defer _ = arena_state.reset(.retain_capacity);

            try self.checkTimeouts();

            // Compute timeout for io_uring wait
            const timeout_ms = self.computeUringTimeout();

            // Wait for completion with timeout
            const cqe_result = if (timeout_ms >= 0) blk: {
                const timeout_ns = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
                const timeout_spec = std.os.linux.kernel_timespec{
                    .sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
                };
                break :blk self.ring.waitForCompletion(&timeout_spec);
            } else self.ring.waitForCompletion(null);

            const cqe = cqe_result catch |err| {
                if (err == error.Timeout) {
                    try self.checkTimeouts();
                    continue;
                }
                return ExecError.PollFailed;
            };

            // Process completion
            try self.handleUringCompletion(cqe);

            try self.checkTimeouts();
        }

        // Final flush
        self.flushUringBuffers() catch {};
        self.maybeShutdownSocketWrite();
    }

    /// Calculates the total number of bytes currently held in all I/O buffers.
    fn totalBuffered(self: *const UringSession) usize {
        return self.stdin_buffer.availableRead() +
            self.stdout_buffer.availableRead() +
            self.stderr_buffer.availableRead();
    }

    /// Updates the flow control state based on the current buffer usage.
    ///
    /// This function checks the total buffered bytes against the configured
    /// thresholds and updates the `flow_state` to either pause or resume reads.
    fn updateFlow(self: *UringSession) !void {
        const total = self.totalBuffered();
        if (self.flow_enabled and total > self.max_total_buffer_bytes) {
            return ExecError.FlowControlTriggered;
        }

        if (self.flow_enabled) {
            self.flow_state.update(total);
        }
    }

    /// Calculates the appropriate timeout for the `io_uring_enter` call.
    ///
    /// The timeout is determined by the `TimeoutTracker`, which considers the
    /// execution, idle, and connection timeouts. This ensures the event loop
    /// wakes up in time to enforce timeouts. Returns -1 for an infinite timeout.
    fn computeUringTimeout(self: *UringSession) i32 {
        const next = self.tracker.nextPollTimeout(null);
        if (next) |ms| {
            if (ms == 0) return 0;
            if (ms > @as(u64, math.maxInt(i32))) {
                return math.maxInt(i32);
            }
            return @intCast(ms);
        }
        return -1;
    }

    /// Checks for and handles any expired timers.
    ///
    /// If a timeout (execution, idle, or connection) has occurred, this function
    /// kills the child process and returns the corresponding timeout error.
    fn checkTimeouts(self: *UringSession) !void {
        switch (self.tracker.check()) {
            .none => {},
            .execution => {
                _ = self.child.kill() catch {};
                return ExecError.TimeoutExecution;
            },
            .idle => {
                _ = self.child.kill() catch {};
                return ExecError.TimeoutIdle;
            },
            .connection => {
                _ = self.child.kill() catch {};
                return ExecError.TimeoutConnection;
            },
        }
    }

    /// Determines whether the main I/O event loop should continue running.
    ///
    /// The loop continues as long as there is potential work to be done.
    fn shouldContinue(self: *const UringSession) bool {
        // Same logic as poll backend
        if (!self.socket_write_closed and (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0)) return true;
        if (!self.child_stdout_closed or !self.child_stderr_closed) return true;
        if (!self.child_stdin_closed and self.stdin_buffer.availableRead() > 0) return true;
        if (!self.socket_read_closed and !self.child_stdin_closed) return true;
        return false;
    }

    /// Submits asynchronous read operations to the `io_uring` for all active sources.
    ///
    /// This function checks the state of the socket, child stdout, and child stderr.
    /// If a source is open, not currently under a pending read operation, has
    /// available buffer space, and is not paused by flow control, it submits a
    /// new read request to the kernel.
    fn submitUringReads(self: *UringSession) !void {
        const pause_reads = self.flow_enabled and self.flow_state.shouldPause();

        // Submit socket read if needed
        if (!self.socket_read_closed and !pause_reads and !self.child_stdin_closed and
            self.stdin_buffer.availableWrite() > 0 and !self.socket_read_pending)
        {
            const writable = self.stdin_buffer.writableSlice();
            if (writable.len > 0) {
                try self.ring.submitRead(self.socket_fd, writable, USER_DATA_SOCKET_READ);
                self.socket_read_pending = true;
            }
        }

        // Submit child stdout read if needed
        if (!self.child_stdout_closed and !pause_reads and
            self.stdout_buffer.availableWrite() > 0 and !self.stdout_read_pending)
        {
            const writable = self.stdout_buffer.writableSlice();
            if (writable.len > 0) {
                try self.ring.submitRead(self.stdout_fd, writable, USER_DATA_STDOUT_READ);
                self.stdout_read_pending = true;
            }
        }

        // Submit child stderr read if needed
        if (!self.child_stderr_closed and !pause_reads and
            self.stderr_buffer.availableWrite() > 0 and !self.stderr_read_pending)
        {
            const writable = self.stderr_buffer.writableSlice();
            if (writable.len > 0) {
                try self.ring.submitRead(self.stderr_fd, writable, USER_DATA_STDERR_READ);
                self.stderr_read_pending = true;
            }
        }

        // Submit writes if there's data buffered
        try self.submitUringWrites();
    }

    /// Submits asynchronous write operations to the `io_uring` for all active destinations.
    ///
    /// This function checks for buffered data destined for the socket (from stdout/stderr)
    /// or for the child's stdin (from the socket). If there is data to write and no
    /// write operation is currently pending for that destination, it submits a new
    /// write request to the kernel.
    fn submitUringWrites(self: *UringSession) !void {
        // Submit socket write if we have stdout/stderr data
        if (!self.socket_write_closed and !self.socket_write_pending) {
            // Prioritize stdout over stderr
            if (self.stdout_buffer.availableRead() > 0) {
                const chunk = self.stdout_buffer.readableSlice();
                if (chunk.len > 0) {
                    try self.ring.submitWrite(self.socket_fd, chunk, USER_DATA_SOCKET_WRITE);
                    self.socket_write_pending = true;
                }
            } else if (self.stderr_buffer.availableRead() > 0) {
                const chunk = self.stderr_buffer.readableSlice();
                if (chunk.len > 0) {
                    try self.ring.submitWrite(self.socket_fd, chunk, USER_DATA_SOCKET_WRITE);
                    self.socket_write_pending = true;
                }
            }
        }

        // Submit child stdin write if we have socket data buffered
        if (!self.child_stdin_closed and !self.stdin_write_pending and
            self.stdin_buffer.availableRead() > 0)
        {
            const chunk = self.stdin_buffer.readableSlice();
            if (chunk.len > 0) {
                try self.ring.submitWrite(self.stdin_fd, chunk, USER_DATA_STDIN_WRITE);
                self.stdin_write_pending = true;
            }
        }
    }

    /// Dispatches a completed `io_uring` operation to its specific handler.
    ///
    /// This function acts as a router. It examines the `user_data` field of the
    /// completion queue entry (CQE) to identify the operation that has finished
    /// and calls the corresponding `handle...` function.
    fn handleUringCompletion(self: *UringSession, cqe: CompletionResult) !void {
        switch (cqe.user_data) {
            USER_DATA_SOCKET_READ => {
                self.socket_read_pending = false;
                try self.handleUringSocketRead(cqe.res);
            },
            USER_DATA_SOCKET_WRITE => {
                self.socket_write_pending = false;
                try self.handleUringSocketWrite(cqe.res);
            },
            USER_DATA_STDIN_WRITE => {
                self.stdin_write_pending = false;
                try self.handleUringStdinWrite(cqe.res);
            },
            USER_DATA_STDOUT_READ => {
                self.stdout_read_pending = false;
                try self.handleUringStdoutRead(cqe.res);
            },
            USER_DATA_STDERR_READ => {
                self.stderr_read_pending = false;
                try self.handleUringStderrRead(cqe.res);
            },
            else => {},
        }
    }

    /// Handles the completion of a socket read operation from the `io_uring`.
    ///
    /// If the read was successful, it commits the received data to the stdin
    /// buffer, updates flow control, and resubmits new I/O operations. If an
    /// error or EOF occurred, it closes the socket's read side.
    fn handleUringSocketRead(self: *UringSession, res: i32) !void {
        if (res < 0) {
            // Error occurred (negative errno)
            self.socket_read_closed = true;
            return;
        }

        if (res == 0) {
            // EOF - socket closed by peer
            self.socket_read_closed = true;
            return;
        }

        const bytes_read = @as(usize, @intCast(res));
        self.stdin_buffer.commitWrite(bytes_read);
        self.tracker.markActivity();
        try self.updateFlow();

        // Resubmit socket read if still open
        try self.submitUringReads();
    }

    /// Handles the completion of a socket write operation from the `io_uring`.
    ///
    /// If the write was successful, it consumes the written data from the
    /// appropriate buffer (stdout or stderr), updates flow control, and
    /// resubmits new write operations if more data is pending. If an error
    /// occurred, it closes the socket's write side.
    fn handleUringSocketWrite(self: *UringSession, res: i32) !void {
        if (res < 0) {
            // Error occurred
            self.socket_write_closed = true;
            return;
        }

        const bytes_written = @as(usize, @intCast(res));

        // Consume from whichever buffer we were writing from
        if (self.stdout_buffer.availableRead() > 0) {
            const chunk = self.stdout_buffer.readableSlice();
            const consumed = @min(bytes_written, chunk.len);
            self.stdout_buffer.consume(consumed);
        } else if (self.stderr_buffer.availableRead() > 0) {
            const chunk = self.stderr_buffer.readableSlice();
            const consumed = @min(bytes_written, chunk.len);
            self.stderr_buffer.consume(consumed);
        }

        self.tracker.markActivity();
        try self.updateFlow();

        // Resubmit writes if more data available
        try self.submitUringWrites();
    }

    /// Handles the completion of a write operation to the child's stdin.
    ///
    /// If the write was successful, it consumes the written data from the stdin
    /// buffer and resubmits new writes if more data is available. If the socket
    /// has been closed and the buffer is now empty, it closes the child's stdin.
    /// If an error occurred, it closes the child's stdin immediately.
    fn handleUringStdinWrite(self: *UringSession, res: i32) !void {
        if (res < 0) {
            // Error occurred - child stdin closed
            self.closeChildStdin();
            return;
        }

        const bytes_written = @as(usize, @intCast(res));
        self.stdin_buffer.consume(bytes_written);
        self.tracker.markActivity();
        try self.updateFlow();

        // Close stdin if socket read closed and buffer empty
        if (self.socket_read_closed and self.stdin_buffer.availableRead() == 0) {
            self.closeChildStdin();
        }

        // Resubmit writes if more data available
        try self.submitUringWrites();
    }

    /// Handles the completion of a read operation from the child's stdout.
    ///
    /// If the read was successful, it commits the data to the stdout buffer and
    /// triggers new I/O submissions to forward the data to the socket. If an
    /// error or EOF occurred, it closes the child's stdout pipe.
    fn handleUringStdoutRead(self: *UringSession, res: i32) !void {
        if (res < 0) {
            // Error occurred
            self.closeChildStdout();
            return;
        }

        if (res == 0) {
            // EOF - child stdout closed
            self.closeChildStdout();
            return;
        }

        const bytes_read = @as(usize, @intCast(res));
        self.stdout_buffer.commitWrite(bytes_read);
        self.tracker.markActivity();
        try self.updateFlow();

        // Resubmit reads and trigger writes
        try self.submitUringReads();
        try self.submitUringWrites();
    }

    /// Handles the completion of a read operation from the child's stderr.
    ///
    /// If the read was successful, it commits the data to the stderr buffer and
    /// triggers new I/O submissions to forward the data to the socket. If an
    /// error or EOF occurred, it closes the child's stderr pipe.
    fn handleUringStderrRead(self: *UringSession, res: i32) !void {
        if (res < 0) {
            // Error occurred
            self.closeChildStderr();
            return;
        }

        if (res == 0) {
            // EOF - child stderr closed
            self.closeChildStderr();
            return;
        }

        const bytes_read = @as(usize, @intCast(res));
        self.stderr_buffer.commitWrite(bytes_read);
        self.tracker.markActivity();
        try self.updateFlow();

        // Resubmit reads and trigger writes
        try self.submitUringReads();
        try self.submitUringWrites();
    }

    /// Attempts to flush any remaining data in the stdout/stderr buffers to the socket.
    ///
    /// This function is called at the end of the `run` loop to ensure that any
    /// data received from the child process just before it exited is sent to the
    /// client. It performs a short, blocking-like loop to write data and wait for
    /// completions.
    fn flushUringBuffers(self: *UringSession) !void {
        // Attempt to flush any remaining buffered data
        while (!self.socket_write_closed and
            (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0))
        {
            if (!self.socket_write_pending) {
                try self.submitUringWrites();
            }

            // Wait for write completion with short timeout
            const timeout_spec = std.os.linux.kernel_timespec{
                .sec = 0,
                .nsec = 100 * std.time.ns_per_ms, // 100ms timeout
            };

            const cqe = self.ring.waitForCompletion(&timeout_spec) catch break;
            try self.handleUringCompletion(cqe);

            // Prevent infinite loop
            if (cqe.user_data != USER_DATA_SOCKET_WRITE) break;
        }
    }

    /// Closes the child process's stdout pipe and marks it as closed.
    fn closeChildStdout(self: *UringSession) void {
        if (self.child_stdout_closed) return;
        if (self.child.stdout) |file| {
            file.close();
            self.child.stdout = null;
        }
        self.child_stdout_closed = true;
    }

    /// Closes the child process's stderr pipe and marks it as closed.
    fn closeChildStderr(self: *UringSession) void {
        if (self.child_stderr_closed) return;
        if (self.child.stderr) |file| {
            file.close();
            self.child.stderr = null;
        }
        self.child_stderr_closed = true;
    }

    /// Closes the child process's stdin pipe and marks it as closed.
    fn closeChildStdin(self: *UringSession) void {
        if (self.child_stdin_closed) return;
        if (self.child.stdin) |file| {
            file.close();
            self.child.stdin = null;
        }
        self.child_stdin_closed = true;
    }

    /// Checks if the socket's write side can be shut down and does so if appropriate.
    ///
    /// The socket write side is shut down when both of the child's output pipes
    /// (stdout and stderr) are closed and there is no more data in their
    /// respective buffers left to write.
    fn maybeShutdownSocketWrite(self: *UringSession) void {
        if (self.socket_write_closed) return;
        if (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0) return;
        if (!self.child_stdout_closed or !self.child_stderr_closed) return;

        if (builtin.os.tag != .windows) {
            _ = posix.shutdown(self.socket_fd, .send) catch {};
        }
        self.socket_write_closed = true;
    }
};

/// Set a POSIX file descriptor to non-blocking mode.
fn setFdNonBlocking(fd: posix.fd_t) !void {
    if (builtin.os.tag == .windows) {
        return error.Unsupported;
    }

    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const o_nonblock: u32 = switch (builtin.os.tag) {
        .linux => 0x0800, // O_NONBLOCK on Linux
        else => 0x0004, // BSD/macOS default
    };
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | o_nonblock);
}
