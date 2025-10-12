// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Poll-based backend for exec session.
//!
//! This module provides a traditional poll(2)-based event loop for managing
//! bidirectional I/O between a network socket and a child process. It works on
//! all Unix-like systems and serves as the fallback when io_uring is not available.
//!
//! ## Key Features
//! - Traditional poll(2) event multiplexing
//! - Non-blocking I/O with proper error handling
//! - Flow control integration
//! - Timeout management
//! - Works on all Unix-like platforms (Linux, macOS, BSD)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const math = std.math;

const IoRingBuffer = @import("../../util/io_ring_buffer.zig").IoRingBuffer;
const TimeoutTracker = @import("../../util/timeout_tracker.zig").TimeoutTracker;
const ExecSessionConfig = @import("../exec_types.zig").ExecSessionConfig;
const ExecError = @import("../exec_types.zig").ExecError;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;
const FlowState = @import("./flow_control.zig").FlowState;
const computeThresholdBytes = @import("./flow_control.zig").computeThresholdBytes;

const socket_io = @import("./socket_io.zig");
const child_io = @import("./child_io.zig");

/// Poll-based exec session implementation.
pub const PollSession = struct {
    const socket_index: usize = 0;
    const child_stdin_index: usize = 1;
    const child_stdout_index: usize = 2;
    const child_stderr_index: usize = 3;

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

    pub fn init(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !PollSession {
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

        var session = PollSession{
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

    pub fn deinit(self: *PollSession) void {
        self.stdin_buffer.deinit();
        self.stdout_buffer.deinit();
        self.stderr_buffer.deinit();
    }

    pub fn run(self: *PollSession) !void {
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
        self.handleSocketWritable() catch {};
        self.maybeShutdownSocketWrite();
    }

    fn totalBuffered(self: *const PollSession) usize {
        return self.stdin_buffer.availableRead() +
            self.stdout_buffer.availableRead() +
            self.stderr_buffer.availableRead();
    }

    fn updateFlow(self: *PollSession) !void {
        const total = self.totalBuffered();
        if (self.flow_enabled and total > self.max_total_buffer_bytes) {
            return ExecError.FlowControlTriggered;
        }

        if (self.flow_enabled) {
            self.flow_state.update(total);
        }
    }

    fn updatePollInterests(self: *PollSession) void {
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

    fn computePollTimeout(self: *PollSession) i32 {
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

    fn checkTimeouts(self: *PollSession) !void {
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

    fn shouldContinue(self: *const PollSession) bool {
        // Same logic as original ExecSession.shouldContinue()
        if (!self.socket_write_closed and (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0)) return true;
        if (!self.child_stdout_closed or !self.child_stderr_closed) return true;
        if (!self.child_stdin_closed and self.stdin_buffer.availableRead() > 0) return true;
        if (!self.socket_read_closed and !self.child_stdin_closed) return true;
        return false;
    }

    fn handleSocketReadable(self: *PollSession) !void {
        var ctx = socket_io.SocketReadContext{
            .telnet_conn = self.telnet_conn,
            .stdin_buffer = &self.stdin_buffer,
            .tracker = &self.tracker,
            .flow_state = &self.flow_state,
            .flow_enabled = self.flow_enabled,
            .socket_read_closed = &self.socket_read_closed,
            .child_stdin_closed = self.child_stdin_closed,
        };

        _ = try socket_io.readSocketToBuffer(&ctx);
        try self.updateFlow();
        try self.handleChildStdinWritable();
    }

    fn handleSocketWritable(self: *PollSession) !void {
        if (self.socket_write_closed) return;

        var ctx = socket_io.SocketWriteContext{
            .telnet_conn = self.telnet_conn,
            .tracker = &self.tracker,
            .socket_write_closed = &self.socket_write_closed,
        };

        try socket_io.flushBufferToSocket(&self.stdout_buffer, &ctx);
        try self.updateFlow();
        try socket_io.flushBufferToSocket(&self.stderr_buffer, &ctx);
        try self.updateFlow();
        self.maybeShutdownSocketWrite();
    }

    fn handleChildStdoutReadable(self: *PollSession) !void {
        var ctx = child_io.ChildReadContext{
            .fd = self.stdout_fd,
            .buffer = &self.stdout_buffer,
            .tracker = &self.tracker,
            .flow_state = &self.flow_state,
            .flow_enabled = self.flow_enabled,
            .stream_closed = &self.child_stdout_closed,
        };

        _ = try child_io.readChildStreamToBuffer(&ctx);
        try self.updateFlow();
        try self.handleSocketWritable();
    }

    fn handleChildStderrReadable(self: *PollSession) !void {
        var ctx = child_io.ChildReadContext{
            .fd = self.stderr_fd,
            .buffer = &self.stderr_buffer,
            .tracker = &self.tracker,
            .flow_state = &self.flow_state,
            .flow_enabled = self.flow_enabled,
            .stream_closed = &self.child_stderr_closed,
        };

        _ = try child_io.readChildStreamToBuffer(&ctx);
        try self.updateFlow();
        try self.handleSocketWritable();
    }

    fn handleChildStdinWritable(self: *PollSession) !void {
        var ctx = child_io.ChildWriteContext{
            .fd = self.stdin_fd,
            .buffer = &self.stdin_buffer,
            .tracker = &self.tracker,
            .stdin_closed = &self.child_stdin_closed,
            .socket_read_closed = self.socket_read_closed,
        };

        _ = try child_io.writeBufferToChildStdin(&ctx);
        try self.updateFlow();
    }

    fn maybeShutdownSocketWrite(self: *PollSession) void {
        if (self.socket_write_closed) return;
        if (self.stdout_buffer.availableRead() > 0 or self.stderr_buffer.availableRead() > 0) return;
        if (!self.child_stdout_closed or !self.child_stderr_closed) return;

        if (builtin.os.tag != .windows) {
            _ = posix.shutdown(self.socket_fd, .send) catch {};
        }
        self.socket_write_closed = true;
    }

    // ========================================================================
    // Poll-based event dispatchers
    // ========================================================================

    fn dispatchSocketEvents(self: *PollSession, revents: i16) !void {
        if (revents == 0) return;
        if ((revents & posix.POLL.NVAL) != 0) {
            self.socket_read_closed = true;
            self.socket_write_closed = true;
            if (self.stdin_buffer.availableRead() == 0) {
                child_io.closeChildStream(&self.child.stdin, &self.child_stdin_closed);
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
                child_io.closeChildStream(&self.child.stdin, &self.child_stdin_closed);
            }
        }
        if ((revents & posix.POLL.ERR) != 0) {
            self.socket_read_closed = true;
            self.socket_write_closed = true;
            if (self.stdin_buffer.availableRead() == 0) {
                child_io.closeChildStream(&self.child.stdin, &self.child_stdin_closed);
            }
        }
    }

    fn dispatchChildStdinEvents(self: *PollSession, revents: i16) !void {
        if (revents == 0 or self.child_stdin_closed) return;
        if ((revents & posix.POLL.OUT) != 0) {
            try self.handleChildStdinWritable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            child_io.closeChildStream(&self.child.stdin, &self.child_stdin_closed);
        }
    }

    fn dispatchChildStdoutEvents(self: *PollSession, revents: i16) !void {
        if (revents == 0 or self.child_stdout_closed) return;
        if ((revents & posix.POLL.IN) != 0) {
            try self.handleChildStdoutReadable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            child_io.closeChildStream(&self.child.stdout, &self.child_stdout_closed);
        }
    }

    fn dispatchChildStderrEvents(self: *PollSession, revents: i16) !void {
        if (revents == 0 or self.child_stderr_closed) return;
        if ((revents & posix.POLL.IN) != 0) {
            try self.handleChildStderrReadable();
        }
        if ((revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            child_io.closeChildStream(&self.child.stderr, &self.child_stderr_closed);
        }
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
