// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Poll-driven and io_uring exec session that manages child I/O with flow control.
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const posix = std.posix;

const IoRingBuffer = @import("../util/io_ring_buffer.zig").IoRingBuffer;
const TimeoutTracker = @import("../util/timeout_tracker.zig").TimeoutTracker;
const ExecSessionConfig = @import("./exec_types.zig").ExecSessionConfig;
const ExecError = @import("./exec_types.zig").ExecError;
const TelnetConnection = @import("../protocol/telnet_connection.zig").TelnetConnection;
const UringEventLoop = @import("../util/io_uring_wrapper.zig").UringEventLoop;

/// Set a POSIX file descriptor to non-blocking mode.
fn setFdNonBlocking(fd: posix.fd_t) !void {
    if (builtin.os.tag == .windows) {
        // Child process pipes on Windows require overlapped I/O; fallback path handles this.
        return error.Unsupported;
    }

    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const o_nonblock: u32 = switch (builtin.os.tag) {
        .linux => 0x0800, // O_NONBLOCK on Linux
        else => 0x0004, // BSD/macOS default
    };
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | o_nonblock);
}

/// Flow control state machine for exec session buffers.
const FlowState = struct {
    pause_threshold_bytes: usize,
    resume_threshold_bytes: usize,
    paused: bool = false,

    /// Update state based on current buffered byte count.
    pub fn update(self: *FlowState, buffered_bytes: usize) void {
        if (!self.paused and buffered_bytes >= self.pause_threshold_bytes) {
            self.paused = true;
        } else if (self.paused and buffered_bytes <= self.resume_threshold_bytes) {
            self.paused = false;
        }
    }

    /// Whether flow control currently pauses new reads.
    pub fn shouldPause(self: *const FlowState) bool {
        return self.paused;
    }
};

/// Compute flow control threshold in bytes from percentage.
fn computeThresholdBytes(max_total: usize, percent: f32) usize {
    if (max_total == 0) return 0;
    var clamped = percent;
    if (clamped < 0.0) clamped = 0.0;
    if (clamped > 1.0) clamped = 1.0;

    const total_f64 = @as(f64, @floatFromInt(max_total));
    const raw = total_f64 * @as(f64, clamped);
    var threshold: usize = @intFromFloat(raw);
    if (threshold == 0 and clamped > 0.0) threshold = 1;
    if (threshold > max_total) threshold = max_total;
    return threshold;
}

/// Manages the I/O loop for a command execution session, relaying data between
/// a network connection and the standard I/O streams of a child process.
///
/// ## I/O Multiplexing
/// `ExecSession` supports two event loop backends on Unix-like systems:
/// 1.  **`io_uring`**: On modern Linux systems, it uses the high-performance `io_uring`
///     interface for fully asynchronous I/O. This is the preferred backend.
/// 2.  **`poll`**: On other Unix-like systems (or older Linux kernels), it falls back
///     to a traditional `poll(2)`-based event loop.
///
/// This struct is not used on Windows, which employs a threaded model instead.
///
/// ## State Management
/// The session's lifecycle is managed through a set of boolean flags that track the
/// state of each I/O stream:
/// - `socket_read_closed`: True if the network socket is no longer readable (e.g., closed by peer).
/// - `socket_write_closed`: True if the network socket is no longer writable.
/// - `child_stdin_closed`: True if the child process's stdin pipe is closed.
/// - `child_stdout_closed`: True if the child process's stdout pipe is closed.
/// - `child_stderr_closed`: True if the child process's stderr pipe is closed.
/// The main event loop (`run` or `runIoUring`) continues as long as there is any
/// potential for data to be moved, as determined by the `shouldContinue` method.
///
/// ## I/O Buffering
/// The session uses three instances of `IoRingBuffer` to buffer data in-memory:
/// - `stdin_buffer`: Holds data read from the socket, waiting to be written to the child's stdin.
/// - `stdout_buffer`: Holds data read from the child's stdout, waiting to be written to the socket.
/// - `stderr_buffer`: Holds data read from the child's stderr, waiting to be written to the socket.
///
/// ## Flow Control
/// To prevent uncontrolled memory growth when one side of the connection produces
/// data faster than the other can consume it, `ExecSession` implements a flow control
/// mechanism.
/// - When the total number of bytes across all three buffers exceeds `pause_threshold_bytes`,
///   the session stops reading new data from both the socket and the child process.
/// - Reading resumes only after the total buffered bytes drops below `resume_threshold_bytes`.
/// This prevents the buffers from overflowing while allowing writes to drain the pending data.
/// The flow control can be configured via `ExecSessionConfig`.
pub const ExecSession = struct {
    const socket_index: usize = 0;
    const child_stdin_index: usize = 1;
    const child_stdout_index: usize = 2;
    const child_stderr_index: usize = 3;

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
    poll_fds: [4]posix.pollfd,
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
    ring: ?UringEventLoop = null,
    use_uring: bool = false,
    // Pending async operations tracking for io_uring
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
    ) !ExecSession {
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

        var session = ExecSession{
            .allocator = allocator,
            .telnet_conn = telnet_conn,
            .socket_fd = socket_fd,
            .child = child,
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .stderr_fd = stderr_fd,
            .poll_fds = .{
                .{ .fd = socket_fd, .events = 0, .revents = 0 },
                .{ .fd = stdin_fd, .events = 0, .revents = 0 },
                .{ .fd = stdout_fd, .events = 0, .revents = 0 },
                .{ .fd = stderr_fd, .events = 0, .revents = 0 },
            },
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
        };

        try session.updateFlow();
        session.updatePollInterests();

        return session;
    }

    pub fn initIoUring(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !ExecSession {
        // Initialize with poll-based setup first
        var session = try init(allocator, telnet_conn, child, cfg);
        errdefer session.deinit();

        // Only attempt io_uring on Linux
        if (builtin.os.tag != .linux) {
            return error.IoUringNotSupported;
        }

        // Initialize io_uring with 64-entry queue (enough for exec session)
        session.ring = try UringEventLoop.init(allocator, 64);
        session.use_uring = true;

        return session;
    }

    pub fn deinit(self: *ExecSession) void {
        if (self.ring) |*r| {
            r.deinit();
        }
        self.stdin_buffer.deinit();
        self.stdout_buffer.deinit();
        self.stderr_buffer.deinit();
    }

    pub fn run(self: *ExecSession) !void {
        while (self.shouldContinue()) {
            try self.checkTimeouts();
            self.updatePollInterests();

            const timeout_ms = self.computePollTimeout();
            const ready = posix.poll(self.poll_fds[0..], timeout_ms) catch |err| switch (err) {
                error.NetworkSubsystemFailed, error.SystemResources, error.Unexpected => return ExecError.PollFailed,
            };

            if (ready == 0) {
                try self.checkTimeouts();
                continue;
            }

            if (self.poll_fds[socket_index].fd != -1) {
                try self.dispatchSocketEvents(self.poll_fds[socket_index].revents);
                self.poll_fds[socket_index].revents = 0;
            }
            if (self.poll_fds[child_stdin_index].fd != -1) {
                try self.dispatchChildStdinEvents(self.poll_fds[child_stdin_index].revents);
                self.poll_fds[child_stdin_index].revents = 0;
            }
            if (self.poll_fds[child_stdout_index].fd != -1) {
                try self.dispatchChildStdoutEvents(self.poll_fds[child_stdout_index].revents);
                self.poll_fds[child_stdout_index].revents = 0;
            }
            if (self.poll_fds[child_stderr_index].fd != -1) {
                try self.dispatchChildStderrEvents(self.poll_fds[child_stderr_index].revents);
                self.poll_fds[child_stderr_index].revents = 0;
            }

            try self.checkTimeouts();
        }

        // Final flush to ensure pending buffers are delivered.
        self.handleSocketWritable() catch {
            // Socket may already be closed, that's OK
        };
        self.maybeShutdownSocketWrite();
    }

    pub fn runIoUring(self: *ExecSession) !void {
        if (builtin.os.tag != .linux) {
            return error.IoUringNotSupported;
        }

        var ring = self.ring orelse return error.IoUringNotSupported;

        // Submit initial read operations for all open FDs
        try self.submitUringReads(&ring);

        while (self.shouldContinue()) {
            try self.checkTimeouts();

            // Compute timeout for io_uring wait
            const timeout_ms = self.computeUringTimeout();
            const timeout_spec = if (timeout_ms >= 0) blk: {
                const timeout_ns = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
                break :blk std.os.linux.kernel_timespec{
                    .tv_sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
                    .tv_nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
                };
            } else null;

            // Wait for completion
            const cqe = ring.waitForCompletion(if (timeout_ms >= 0) &timeout_spec else null) catch |err| {
                if (err == error.Timeout) {
                    try self.checkTimeouts();
                    continue;
                }
                return ExecError.PollFailed;
            };

            // Process completion
            try self.handleUringCompletion(&ring, cqe);

            try self.checkTimeouts();
        }

        // Final flush
        self.flushUringBuffers(&ring) catch {};
        self.maybeShutdownSocketWrite();
    }

    fn totalBuffered(self: *const ExecSession) usize {
        return self.stdin_buffer.availableRead() +
            self.stdout_buffer.availableRead() +
            self.stderr_buffer.availableRead();
    }

    fn updateFlow(self: *ExecSession) !void {
        const total = self.totalBuffered();
        if (self.flow_enabled and total > self.max_total_buffer_bytes) {
            return ExecError.FlowControlTriggered;
        }

        if (self.flow_enabled) {
            self.flow_state.update(total);
        }
    }

    fn updatePollInterests(self: *ExecSession) void {
        const pause_reads = self.flow_enabled and self.flow_state.shouldPause();

        // Socket poll events
        if (self.socket_read_closed and self.socket_write_closed) {
            self.poll_fds[socket_index].fd = -1;
            self.poll_fds[socket_index].events = 0;
        } else {
            self.poll_fds[socket_index].fd = self.socket_fd;
            var events: i16 = posix.POLL.ERR | posix.POLL.HUP;
            if (!self.socket_read_closed and !pause_reads and !self.child_stdin_closed and self.stdin_buffer.availableWrite() > 0) {
                events |= posix.POLL.IN;
            }
            if (!self.socket_write_closed and (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0)) {
                events |= posix.POLL.OUT;
            }
            self.poll_fds[socket_index].events = events;
        }

        // Child stdin events (writing data to child)
        if (self.child_stdin_closed) {
            self.poll_fds[child_stdin_index].fd = -1;
            self.poll_fds[child_stdin_index].events = 0;
        } else {
            self.poll_fds[child_stdin_index].fd = self.stdin_fd;
            var events: i16 = posix.POLL.ERR | posix.POLL.HUP;
            if (self.stdin_buffer.availableRead() > 0) {
                events |= posix.POLL.OUT;
            }
            self.poll_fds[child_stdin_index].events = events;
        }

        // Child stdout events (reading data from child)
        if (self.child_stdout_closed) {
            self.poll_fds[child_stdout_index].fd = -1;
            self.poll_fds[child_stdout_index].events = 0;
        } else {
            self.poll_fds[child_stdout_index].fd = self.stdout_fd;
            var events: i16 = posix.POLL.ERR | posix.POLL.HUP;
            if (!pause_reads and self.stdout_buffer.availableWrite() > 0) {
                events |= posix.POLL.IN;
            }
            self.poll_fds[child_stdout_index].events = events;
        }

        // Child stderr events (reading data from child)
        if (self.child_stderr_closed) {
            self.poll_fds[child_stderr_index].fd = -1;
            self.poll_fds[child_stderr_index].events = 0;
        } else {
            self.poll_fds[child_stderr_index].fd = self.stderr_fd;
            var events: i16 = posix.POLL.ERR | posix.POLL.HUP;
            if (!pause_reads and self.stderr_buffer.availableWrite() > 0) {
                events |= posix.POLL.IN;
            }
            self.poll_fds[child_stderr_index].events = events;
        }
    }

    fn computePollTimeout(self: *ExecSession) i32 {
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

    fn checkTimeouts(self: *ExecSession) !void {
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

    fn shouldContinue(self: *const ExecSession) bool {
        // Condition 1: There is data from the child process (stdout/stderr) that
        // still needs to be written to the socket. We must continue to ensure this
        // data is delivered.
        if (!self.socket_write_closed and (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0)) return true;

        // Condition 2: The child process's output streams (stdout/stderr) are still
        // open. We must continue because the child could produce more output at any time.
        if (!self.child_stdout_closed or !self.child_stderr_closed) return true;

        // Condition 3: There is data from the socket in our stdin_buffer waiting to be
        // written to the child's stdin, and the child's stdin is still open.
        // We must continue to deliver this input to the child.
        if (!self.child_stdin_closed and self.stdin_buffer.availableRead() > 0) return true;

        // Condition 4: The socket is still open for reading and the child's stdin is
        // still open to receive data. We must continue to be able to read new data
        // from the socket and pass it to the child.
        if (!self.socket_read_closed and !self.child_stdin_closed) return true;

        // If none of the above conditions are met, it means all I/O paths are closed
        // and all buffers are empty. The session is complete.
        return false;
    }

    fn handleSocketReadable(self: *ExecSession) !void {
        while (!self.socket_read_closed and !self.child_stdin_closed) {
            if (self.flow_enabled and self.flow_state.shouldPause()) break;
            const writable = self.stdin_buffer.writableSlice();
            if (writable.len == 0) break;

            const read_bytes = self.telnet_conn.read(writable) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.ConnectionResetByPeer, error.BrokenPipe => {
                        self.socket_read_closed = true;
                        return;
                    },
                    else => {
                        // Log but don't fail - socket may already be closed
                        self.socket_read_closed = true;
                        return;
                    },
                }
            };

            if (read_bytes == 0) {
                self.socket_read_closed = true;
                break;
            }

            self.stdin_buffer.commitWrite(read_bytes);
            self.tracker.markActivity();
            try self.updateFlow();

            if (read_bytes < writable.len) break;
        }

        try self.handleChildStdinWritable();
    }

    fn handleSocketWritable(self: *ExecSession) !void {
        if (self.socket_write_closed) return;

        try self.flushBufferToSocket(&self.stdout_buffer);
        try self.flushBufferToSocket(&self.stderr_buffer);
        self.maybeShutdownSocketWrite();
    }

    fn flushBufferToSocket(self: *ExecSession, buffer: *IoRingBuffer) !void {
        while (!self.socket_write_closed and buffer.availableRead() > 0) {
            const chunk = buffer.readableSlice();
            if (chunk.len == 0) break;

            const written = self.telnet_conn.write(chunk) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.ConnectionResetByPeer, error.BrokenPipe => {
                        self.socket_write_closed = true;
                        return;
                    },
                    else => {
                        // Log but don't fail - socket may already be closed
                        self.socket_write_closed = true;
                        return;
                    },
                }
            };

            if (written == 0) break;

            buffer.consume(written);
            self.tracker.markActivity();
            try self.updateFlow();

            if (written < chunk.len) break;
        }
    }

    fn handleChildStdoutReadable(self: *ExecSession) !void {
        while (!self.child_stdout_closed) {
            if (self.flow_enabled and self.flow_state.shouldPause()) break;
            const writable = self.stdout_buffer.writableSlice();
            if (writable.len == 0) break;

            const read_bytes = posix.read(self.stdout_fd, writable) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.BrokenPipe => {
                        self.closeChildStdout();
                        return;
                    },
                    else => {
                        // Child may have exited - close stdout and continue
                        self.closeChildStdout();
                        return;
                    },
                }
            };

            if (read_bytes == 0) {
                self.closeChildStdout();
                break;
            }

            self.stdout_buffer.commitWrite(read_bytes);
            self.tracker.markActivity();
            try self.updateFlow();

            if (read_bytes < writable.len) break;
        }

        try self.handleSocketWritable();
    }

    fn handleChildStderrReadable(self: *ExecSession) !void {
        while (!self.child_stderr_closed) {
            if (self.flow_enabled and self.flow_state.shouldPause()) break;
            const writable = self.stderr_buffer.writableSlice();
            if (writable.len == 0) break;

            const read_bytes = posix.read(self.stderr_fd, writable) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.BrokenPipe => {
                        self.closeChildStderr();
                        return;
                    },
                    else => {
                        // Child may have exited - close stderr and continue
                        self.closeChildStderr();
                        return;
                    },
                }
            };

            if (read_bytes == 0) {
                self.closeChildStderr();
                break;
            }

            self.stderr_buffer.commitWrite(read_bytes);
            self.tracker.markActivity();
            try self.updateFlow();

            if (read_bytes < writable.len) break;
        }

        try self.handleSocketWritable();
    }

    fn handleChildStdinWritable(self: *ExecSession) !void {
        while (!self.child_stdin_closed and self.stdin_buffer.availableRead() > 0) {
            const chunk = self.stdin_buffer.readableSlice();
            if (chunk.len == 0) break;

            const written = posix.write(self.stdin_fd, chunk) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    error.BrokenPipe => {
                        self.closeChildStdin();
                        return;
                    },
                    else => {
                        // Child may have exited - close stdin and continue
                        self.closeChildStdin();
                        return;
                    },
                }
            };

            if (written == 0) break;

            self.stdin_buffer.consume(written);
            self.tracker.markActivity();
            try self.updateFlow();

            if (written < chunk.len) break;
        }

        if (self.socket_read_closed and self.stdin_buffer.availableRead() == 0) {
            self.closeChildStdin();
        }
    }

    fn closeChildStdout(self: *ExecSession) void {
        if (self.child_stdout_closed) return;
        if (self.child.stdout) |file| {
            file.close();
            self.child.stdout = null;
        }
        self.child_stdout_closed = true;
        self.poll_fds[child_stdout_index].fd = -1;
    }

    fn closeChildStderr(self: *ExecSession) void {
        if (self.child_stderr_closed) return;
        if (self.child.stderr) |file| {
            file.close();
            self.child.stderr = null;
        }
        self.child_stderr_closed = true;
        self.poll_fds[child_stderr_index].fd = -1;
    }

    fn closeChildStdin(self: *ExecSession) void {
        if (self.child_stdin_closed) return;
        if (self.child.stdin) |file| {
            file.close();
            self.child.stdin = null;
        }
        self.child_stdin_closed = true;
        self.poll_fds[child_stdin_index].fd = -1;
    }

    fn maybeShutdownSocketWrite(self: *ExecSession) void {
        if (self.socket_write_closed) return;
        if (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0) return;
        if (!self.child_stdout_closed or !self.child_stderr_closed) return;

        if (builtin.os.tag != .windows) {
            _ = posix.shutdown(self.socket_fd, .send) catch {};
        }
        self.socket_write_closed = true;
    }

    // ========================================================================
    // io_uring-specific methods
    // ========================================================================

    fn computeUringTimeout(self: *ExecSession) i32 {
        return self.computePollTimeout();
    }

    fn submitUringReads(self: *ExecSession, ring: *UringEventLoop) !void {
        const pause_reads = self.flow_enabled and self.flow_state.shouldPause();

        // Submit socket read if needed
        if (!self.socket_read_closed and !pause_reads and !self.child_stdin_closed and
            self.stdin_buffer.availableWrite() > 0 and !self.socket_read_pending)
        {
            const writable = self.stdin_buffer.writableSlice();
            if (writable.len > 0) {
                try ring.submitRead(self.socket_fd, writable, USER_DATA_SOCKET_READ);
                self.socket_read_pending = true;
            }
        }

        // Submit child stdout read if needed
        if (!self.child_stdout_closed and !pause_reads and
            self.stdout_buffer.availableWrite() > 0 and !self.stdout_read_pending)
        {
            const writable = self.stdout_buffer.writableSlice();
            if (writable.len > 0) {
                try ring.submitRead(self.stdout_fd, writable, USER_DATA_STDOUT_READ);
                self.stdout_read_pending = true;
            }
        }

        // Submit child stderr read if needed
        if (!self.child_stderr_closed and !pause_reads and
            self.stderr_buffer.availableWrite() > 0 and !self.stderr_read_pending)
        {
            const writable = self.stderr_buffer.writableSlice();
            if (writable.len > 0) {
                try ring.submitRead(self.stderr_fd, writable, USER_DATA_STDERR_READ);
                self.stderr_read_pending = true;
            }
        }

        // Submit writes if there's data buffered
        try self.submitUringWrites(ring);
    }

    fn submitUringWrites(self: *ExecSession, ring: *UringEventLoop) !void {
        // Submit socket write if we have stdout/stderr data
        if (!self.socket_write_closed and !self.socket_write_pending) {
            // Prioritize stdout over stderr
            if (self.stdout_buffer.availableRead() > 0) {
                const chunk = self.stdout_buffer.readableSlice();
                if (chunk.len > 0) {
                    try ring.submitWrite(self.socket_fd, chunk, USER_DATA_SOCKET_WRITE);
                    self.socket_write_pending = true;
                }
            } else if (self.stderr_buffer.availableRead() > 0) {
                const chunk = self.stderr_buffer.readableSlice();
                if (chunk.len > 0) {
                    try ring.submitWrite(self.socket_fd, chunk, USER_DATA_SOCKET_WRITE);
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
                try ring.submitWrite(self.stdin_fd, chunk, USER_DATA_STDIN_WRITE);
                self.stdin_write_pending = true;
            }
        }
    }

    fn handleUringCompletion(self: *ExecSession, ring: *UringEventLoop, cqe: UringEventLoop.CompletionResult) !void {
        switch (cqe.user_data) {
            USER_DATA_SOCKET_READ => {
                self.socket_read_pending = false;
                try self.handleUringSocketRead(ring, cqe.res);
            },
            USER_DATA_SOCKET_WRITE => {
                self.socket_write_pending = false;
                try self.handleUringSocketWrite(ring, cqe.res);
            },
            USER_DATA_STDIN_WRITE => {
                self.stdin_write_pending = false;
                try self.handleUringStdinWrite(ring, cqe.res);
            },
            USER_DATA_STDOUT_READ => {
                self.stdout_read_pending = false;
                try self.handleUringStdoutRead(ring, cqe.res);
            },
            USER_DATA_STDERR_READ => {
                self.stderr_read_pending = false;
                try self.handleUringStderrRead(ring, cqe.res);
            },
            else => {},
        }
    }

    fn handleUringSocketRead(self: *ExecSession, ring: *UringEventLoop, res: i32) !void {
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
        try self.submitUringReads(ring);
    }

    fn handleUringSocketWrite(self: *ExecSession, ring: *UringEventLoop, res: i32) !void {
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
        try self.submitUringWrites(ring);
    }

    fn handleUringStdinWrite(self: *ExecSession, ring: *UringEventLoop, res: i32) !void {
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
        try self.submitUringWrites(ring);
    }

    fn handleUringStdoutRead(self: *ExecSession, ring: *UringEventLoop, res: i32) !void {
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
        try self.submitUringReads(ring);
        try self.submitUringWrites(ring);
    }

    fn handleUringStderrRead(self: *ExecSession, ring: *UringEventLoop, res: i32) !void {
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
        try self.submitUringReads(ring);
        try self.submitUringWrites(ring);
    }

    fn flushUringBuffers(self: *ExecSession, ring: *UringEventLoop) !void {
        // Attempt to flush any remaining buffered data
        while (!self.socket_write_closed and
            (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0))
        {
            if (!self.socket_write_pending) {
                try self.submitUringWrites(ring);
            }

            // Wait for write completion with short timeout
            const timeout_spec = std.os.linux.kernel_timespec{
                .tv_sec = 0,
                .tv_nsec = 100 * std.time.ns_per_ms, // 100ms timeout
            };

            const cqe = ring.waitForCompletion(&timeout_spec) catch break;
            try self.handleUringCompletion(ring, cqe);

            // Prevent infinite loop
            if (cqe.user_data != USER_DATA_SOCKET_WRITE) break;
        }
    }

    // ========================================================================
    // Poll-based event dispatchers
    // ========================================================================

    fn dispatchSocketEvents(self: *ExecSession, revents: i16) !void {
        if (revents == 0) return;
        if ((revents & posix.POLL.NVAL) != 0) {
            // Invalid FD - socket was closed, mark as disconnected
            self.socket_read_closed = true;
            self.socket_write_closed = true;
            if (self.stdin_buffer.availableRead() == 0) {
                self.closeChildStdin();
            }
            return;
        }
        if ((revents & posix.POLL.IN) != 0) {
            try self.handleSocketReadable();
        }
        if ((revents & posix.POLL.OUT) != 0) {
            try self.handleSocketWritable();
        }
        if ((revents & posix.POLL.HUP) != 0) {
            self.socket_read_closed = true;
            if (self.stdin_buffer.availableRead() == 0) {
                self.closeChildStdin();
            }
        }
        if ((revents & posix.POLL.ERR) != 0) {
            // Socket error - could be normal disconnection
            // Mark socket as closed but don't fail immediately
            self.socket_read_closed = true;
            self.socket_write_closed = true;
            if (self.stdin_buffer.availableRead() == 0) {
                self.closeChildStdin();
            }
        }
    }

    fn dispatchChildStdinEvents(self: *ExecSession, revents: i16) !void {
        if (revents == 0 or self.child_stdin_closed) return;
        if ((revents & posix.POLL.OUT) != 0) {
            try self.handleChildStdinWritable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            self.closeChildStdin();
        }
    }

    fn dispatchChildStdoutEvents(self: *ExecSession, revents: i16) !void {
        if (revents == 0 or self.child_stdout_closed) return;
        if ((revents & posix.POLL.IN) != 0) {
            try self.handleChildStdoutReadable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            self.closeChildStdout();
        }
    }

    fn dispatchChildStderrEvents(self: *ExecSession, revents: i16) !void {
        if (revents == 0 or self.child_stderr_closed) return;
        if ((revents & posix.POLL.IN) != 0) {
            try self.handleChildStderrReadable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            self.closeChildStderr();
        }
    }
};
