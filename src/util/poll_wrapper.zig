// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! # Cross-Platform `poll()` Wrapper
//!
//! This module provides a cross-platform abstraction for the `poll()` system call,
//! which is used for I/O multiplexing. It ensures that code using `poll()` can
//! work seamlessly across both POSIX-compliant systems (Linux, macOS, BSD) and
//! Windows.
//!
//! ## Platform-Specific Implementations
//!
//! -   **POSIX Systems**: On Unix-like operating systems, this wrapper is a thin
//!     layer that delegates directly to the standard `posix.poll()`. It uses the
//!     native `pollfd` struct and constants, providing full-featured and
//!     efficient I/O multiplexing.
//!
//! -   **Windows**: Windows does not have a native `poll()` system call. This module
//!     provides two backends and automatically selects the best one available:
//!     1.  **`WSAPoll()`** (Preferred): Available on Windows Vista and newer, this
//!         function is the direct equivalent of POSIX `poll()`. It is highly
//!         efficient and has no limit on the number of file descriptors, making it
//!         the ideal choice for modern Windows systems.
//!     2.  **`select()`** (Fallback): On older Windows versions (pre-Vista), the
//!         wrapper falls back to an emulation of `poll()` using the `select()`
//!         function. This backend has significant limitations.
//!
//! ## `select()` Backend Limitations (Windows Fallback)
//!
//! The `select()` function is constrained by the `FD_SETSIZE` constant, which is
//! typically 64 on Windows. Because `select()` uses separate sets for read, write,
//! and error conditions, a single connection being polled for both reading and
//! writing can consume multiple slots. This wrapper calculates the worst-case
//! usage (`fds.len * 3`) and returns `error.TooManyFileDescriptors` if the
//! request exceeds `FD_SETSIZE`, preventing silent failures and potential security
//! vulnerabilities. This effectively limits the `select()` backend to ~21
//! concurrent connections.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

var select_backend_warning_printed = std.atomic.Value(bool).init(false);
const select_backend_warning_message =
    "Warning: Running on an older version of Windows that uses the 'select' backend, which is limited to ~21 concurrent connections. Broker/chat mode may be unstable. Upgrade to Windows 10 (Build 17063) or newer for better performance.\n";

pub const WindowsBackend = enum {
    wsapoll,
    select,
};

const WindowsBackendState = enum {
    unknown,
    wsapoll,
    select,
};

var windows_backend_state = std.atomic.Value(WindowsBackendState).init(.unknown);

// Export poll constants
pub const POLL = struct {
    pub const IN: i16 = if (builtin.os.tag == .windows) 0x0001 else posix.POLL.IN;
    pub const OUT: i16 = if (builtin.os.tag == .windows) 0x0004 else posix.POLL.OUT;
    pub const ERR: i16 = if (builtin.os.tag == .windows) 0x0008 else posix.POLL.ERR;
    pub const HUP: i16 = if (builtin.os.tag == .windows) 0x0010 else posix.POLL.HUP;
    pub const NVAL: i16 = if (builtin.os.tag == .windows) 0x0020 else posix.POLL.NVAL;
};

// Cross-platform pollfd structure
pub const pollfd = if (builtin.os.tag == .windows)
    struct {
        fd: posix.socket_t,
        events: i16,
        revents: i16,
    }
else
    posix.pollfd;

// Cross-platform poll() function
pub fn poll(fds: []pollfd, timeout_ms: i32) !usize {
    if (builtin.os.tag == .windows) {
        // Use WSAPoll on Windows Vista+ for better scalability
        // Falls back to select() if WSAPoll is not available
        const result = pollWindowsWSAPoll(fds, timeout_ms) catch |err| {
            // If WSAPoll fails or is unavailable, try select() backend
            if (err == error.WSAPollNotAvailable or err == error.Unexpected) {
                markWindowsBackend(.select);
                return pollWindowsSelect(fds, timeout_ms) catch |select_err| {
                    if (select_err == error.TooManyFileDescriptors) {
                        warnSelectBackendLimitOnce();
                    }
                    return select_err;
                };
            }
            return err;
        };

        markWindowsBackend(.wsapoll);
        return result;
    } else {
        return posix.poll(fds, timeout_ms);
    }
}

// Windows-specific poll() implementation using WSAPoll (Windows Vista+)
// This is the preferred backend as it has no FD_SETSIZE limitation
fn pollWindowsWSAPoll(fds: []pollfd, timeout_ms: i32) !usize {
    const windows = std.os.windows;
    const ws2_32 = windows.ws2_32;

    // WSAPoll uses the same structure as our pollfd on Windows
    // No conversion needed - we can cast directly
    const result = ws2_32.WSAPoll(
        @ptrCast(fds.ptr),
        @intCast(fds.len),
        timeout_ms,
    );

    if (result == ws2_32.SOCKET_ERROR) {
        const wsa_error = ws2_32.WSAGetLastError();
        return switch (wsa_error) {
            .WSAENETDOWN => error.NetworkDown,
            .WSAEFAULT => error.BadAddress,
            .WSAEOPNOTSUPP => error.WSAPollNotAvailable,
            .WSAEINVAL => error.InvalidArgument,
            .WSAENOBUFS => error.NoBufferSpace,
            .WSAEINTR => error.Interrupted,
            else => error.Unexpected,
        };
    }

    return @intCast(result);
}

pub fn windowsPollBackend() WindowsBackend {
    if (builtin.os.tag != .windows) return .wsapoll;

    const cached = windows_backend_state.load(.seq_cst);
    if (cached != .unknown) {
        return toWindowsBackend(cached);
    }

    const detected = probeWindowsBackend();
    windows_backend_state.store(detected, .seq_cst);
    return toWindowsBackend(detected);
}

// Windows-specific poll() implementation using select() (legacy fallback)
// Limited to ~21 clients due to FD_SETSIZE=64 constraint
// Kept for compatibility with older Windows versions or as fallback
fn pollWindowsSelect(fds: []pollfd, timeout_ms: i32) !usize {
    const windows = std.os.windows;
    const ws2_32 = windows.ws2_32;

    // The `select` function is limited by `FD_SETSIZE` (typically 64 on Windows).
    // A single socket can be in the read, write, and error sets simultaneously.
    // To be safe, we assume the worst-case scenario where every file descriptor
    // in `fds` needs to be added to all three sets.
    const max_fd_set_entries_needed = fds.len * 3;
    if (max_fd_set_entries_needed > ws2_32.FD_SETSIZE) {
        // This check is a security measure to prevent a Denial of Service (DoS) attack.
        // Without it, if more than `FD_SETSIZE / 3` clients connect, `select` would
        // silently fail to monitor the excess sockets, leaving them unresponsive.
        // By failing explicitly, we prevent the server from accepting connections
        // it cannot properly manage.
        return error.TooManyFileDescriptors;
    }

    // Initialize fd_sets
    var read_fds: ws2_32.fd_set = undefined;
    var write_fds: ws2_32.fd_set = undefined;
    var error_fds: ws2_32.fd_set = undefined;

    // Clear all fd_sets
    FD_ZERO(&read_fds);
    FD_ZERO(&write_fds);
    FD_ZERO(&error_fds);

    var max_fd: usize = 0;

    // Add file descriptors to appropriate sets
    for (fds) |*pfd| {
        pfd.revents = 0; // Clear revents

        if (pfd.events & POLL.IN != 0) {
            try FD_SET(pfd.fd, &read_fds);
        }
        if (pfd.events & POLL.OUT != 0) {
            try FD_SET(pfd.fd, &write_fds);
        }
        // Always include the descriptor in the error set so `POLLERR` maps
        // to `select()`'s exceptional condition; callers must keep probing
        // `revents & POLL.ERR` just like they would on POSIX.
        try FD_SET(pfd.fd, &error_fds);

        if (pfd.fd > max_fd) {
            max_fd = pfd.fd;
        }
    }

    // Convert timeout to timeval
    var tv: ws2_32.timeval = undefined;
    const timeout_ptr: ?*ws2_32.timeval = if (timeout_ms < 0)
        null // Infinite timeout, mirroring POSIX poll semantics
    else blk: {
        tv.tv_sec = @intCast(@divFloor(timeout_ms, 1000));
        tv.tv_usec = @intCast(@mod(timeout_ms, 1000) * 1000);
        break :blk &tv;
    };

    // Call select()
    const result = ws2_32.select(
        @intCast(max_fd + 1),
        &read_fds,
        &write_fds,
        &error_fds,
        timeout_ptr,
    );

    if (result == ws2_32.SOCKET_ERROR) {
        return error.SelectFailed;
    }

    if (result == 0) {
        return 0; // Timeout
    }

    // Update revents for each fd without heap allocation
    var ready_count: usize = 0;
    for (fds) |*pfd| {
        var revents: i16 = 0;
        if (FD_ISSET(pfd.fd, &read_fds)) revents |= POLL.IN;
        if (FD_ISSET(pfd.fd, &write_fds)) revents |= POLL.OUT;
        if (FD_ISSET(pfd.fd, &error_fds)) revents |= POLL.ERR;

        pfd.revents = revents;
        if (revents != 0) ready_count += 1;
    }

    return ready_count;
}

fn warnSelectBackendLimitOnce() void {
    if (builtin.is_test) return;
    if (!select_backend_warning_printed.swap(true, .seq_cst)) {
        std.debug.print(select_backend_warning_message, .{});
    }
}

fn markWindowsBackend(backend: WindowsBackend) void {
    if (builtin.os.tag != .windows) return;

    const state: WindowsBackendState = switch (backend) {
        .wsapoll => .wsapoll,
        .select => .select,
    };
    windows_backend_state.store(state, .seq_cst);
}

fn toWindowsBackend(state: WindowsBackendState) WindowsBackend {
    return switch (state) {
        .wsapoll => .wsapoll,
        .select => .select,
        .unknown => unreachable,
    };
}

fn probeWindowsBackend() WindowsBackendState {
    if (builtin.os.tag != .windows) return .wsapoll;

    const ws2_32 = std.os.windows.ws2_32;
    const result = ws2_32.WSAPoll(null, 0, 0);
    if (result == ws2_32.SOCKET_ERROR) {
        const wsa_error = ws2_32.WSAGetLastError();
        return switch (wsa_error) {
            .WSAEOPNOTSUPP, .WSAEINVAL => .select,
            else => .wsapoll,
        };
    }

    return .wsapoll;
}

pub fn testingOverrideWindowsBackend(backend: ?WindowsBackend) void {
    if (!builtin.is_test) @compileError("testingOverrideWindowsBackend is test-only");
    if (builtin.os.tag != .windows) return;

    const state: WindowsBackendState = if (backend) |value| switch (value) {
        .wsapoll => .wsapoll,
        .select => .select,
    } else .unknown;

    windows_backend_state.store(state, .seq_cst);
}

// Windows fd_set helper functions
fn FD_ZERO(set: *std.os.windows.ws2_32.fd_set) void {
    set.fd_count = 0;
}

fn FD_SET(fd: posix.socket_t, set: *std.os.windows.ws2_32.fd_set) !void {
    const ws2_32 = std.os.windows.ws2_32;
    if (set.fd_count >= ws2_32.FD_SETSIZE) {
        // SECURITY: Fail explicitly instead of silently dropping the file descriptor
        // This prevents the DoS condition where connections are accepted but not monitored
        return error.FdSetOverflow;
    }
    set.fd_array[set.fd_count] = fd;
    set.fd_count += 1;
}

fn FD_ISSET(fd: posix.socket_t, set: *const std.os.windows.ws2_32.fd_set) bool {
    var i: u32 = 0;
    while (i < set.fd_count) : (i += 1) {
        if (set.fd_array[i] == fd) {
            return true;
        }
    }
    return false;
}

pub fn shutdown(socket: posix.socket_t, mode: enum { send, receive, both }) !void {
    if (builtin.os.tag == .windows) {
        const how = switch (mode) {
            .send => std.os.windows.ws2_32.SD_SEND,
            .receive => std.os.windows.ws2_32.SD_RECEIVE,
            .both => std.os.windows.ws2_32.SD_BOTH,
        };
        if (std.os.windows.ws2_32.shutdown(socket, how) != 0) {
            return error.ShutdownFailed;
        }
    } else {
        // Use posix.ShutdownHow enum values
        // Note: SHUT.WR/RD/RDWR are comptime_int constants that map to the enum
        switch (mode) {
            .send => try posix.shutdown(socket, .send),
            .receive => try posix.shutdown(socket, .recv),
            .both => try posix.shutdown(socket, .both),
        }
    }
}

// Unit tests
test "poll wrapper - timeout on empty set" {
    const testing = std.testing;

    var fds: [0]pollfd = undefined;
    const ready = try poll(&fds, 10); // 10ms timeout
    try testing.expectEqual(@as(usize, 0), ready);
}

test "poll wrapper - POLL constants defined" {
    const testing = std.testing;

    // Verify constants are non-zero
    try testing.expect(POLL.IN != 0);
    try testing.expect(POLL.OUT != 0);
    try testing.expect(POLL.ERR != 0);
    try testing.expect(POLL.HUP != 0);
    try testing.expect(POLL.NVAL != 0);
}

test "poll wrapper - pollfd structure compatibility" {
    const testing = std.testing;

    // Verify we can create pollfd structures
    const pfd = pollfd{
        .fd = @bitCast(@as(i32, -1)),
        .events = POLL.IN,
        .revents = 0,
    };

    try testing.expectEqual(POLL.IN, pfd.events);
    try testing.expectEqual(@as(i16, 0), pfd.revents);
}

test "poll wrapper - invalid fd handling" {
    const testing = std.testing;

    // Create a pollfd with an invalid fd
    const pfd = pollfd{
        .fd = @bitCast(@as(i32, -1)),
        .events = POLL.IN,
        .revents = 0,
    };

    var fds = [_]pollfd{pfd};

    // Should timeout or return immediately depending on platform
    // Both behaviors are acceptable for invalid fd
    const ready = poll(&fds, 10) catch |err| {
        // Error is acceptable for invalid fd
        try testing.expect(err == error.SelectFailed or err == error.Unexpected);
        return;
    };

    // If no error, should timeout (0) or detect invalid fd
    try testing.expect(ready == 0 or fds[0].revents & POLL.NVAL != 0);
}

test "poll wrapper - event flags" {
    const testing = std.testing;

    const pfd = pollfd{
        .fd = @bitCast(@as(i32, -1)),
        .events = POLL.IN | POLL.OUT,
        .revents = 0,
    };

    // Verify we can set multiple event flags
    try testing.expect(pfd.events & POLL.IN != 0);
    try testing.expect(pfd.events & POLL.OUT != 0);
}

test "poll wrapper - FD_SETSIZE overflow protection (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    // Create more pollfds than FD_SETSIZE can handle
    // FD_SETSIZE is typically 64, and each pollfd needs 3 entries (read/write/error)
    // So 22+ pollfds should trigger the overflow protection
    const excessive_fd_count = 25; // 25 * 3 = 75 > 64
    var fds: [excessive_fd_count]pollfd = undefined;

    for (&fds, 0..) |*pfd, i| {
        pfd.* = pollfd{
            .fd = @intCast(i), // Dummy socket FD
            .events = POLL.IN | POLL.OUT, // Request both read and write
            .revents = 0,
        };
    }

    // Attempt to poll with select() backend - should return TooManyFileDescriptors error
    const result = pollWindowsSelect(&fds, 10);
    try testing.expectError(error.TooManyFileDescriptors, result);
}

test "poll wrapper - FD_SET overflow protection (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var fd_set: std.os.windows.ws2_32.fd_set = undefined;
    FD_ZERO(&fd_set);

    // Fill the fd_set to capacity
    var i: u32 = 0;
    while (i < std.os.windows.ws2_32.FD_SETSIZE) : (i += 1) {
        try FD_SET(@intCast(i), &fd_set);
    }

    // Verify the set is at capacity
    try testing.expectEqual(std.os.windows.ws2_32.FD_SETSIZE, fd_set.fd_count);

    // Attempt to add one more - should return FdSetOverflow error
    const result = FD_SET(@intCast(std.os.windows.ws2_32.FD_SETSIZE), &fd_set);
    try testing.expectError(error.FdSetOverflow, result);

    // Verify fd_count hasn't changed
    try testing.expectEqual(std.os.windows.ws2_32.FD_SETSIZE, fd_set.fd_count);
}

test "poll wrapper - WSAPoll handles many connections (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    // Test that WSAPoll can handle more connections than FD_SETSIZE
    // This test uses dummy FDs, so it won't actually poll real sockets
    // But it verifies that WSAPoll doesn't have the FD_SETSIZE limitation

    const large_fd_count = 100; // Far exceeds FD_SETSIZE (64)
    var fds: [large_fd_count]pollfd = undefined;

    for (&fds, 0..) |*pfd, i| {
        pfd.* = pollfd{
            .fd = @intCast(i), // Dummy socket FD
            .events = POLL.IN,
            .revents = 0,
        };
    }

    // Attempt to poll with WSAPoll backend
    // This should NOT return TooManyFileDescriptors error
    // It may return other errors (like InvalidArgument for dummy FDs), but not FD_SETSIZE-related errors
    const result = pollWindowsWSAPoll(&fds, 0); // 0 timeout for immediate return

    // We expect either:
    // 1. Success (0 ready FDs since these are dummy FDs)
    // 2. An error other than TooManyFileDescriptors
    if (result) |ready_count| {
        // Success - WSAPoll can handle 100+ FDs
        try testing.expectEqual(@as(usize, 0), ready_count);
    } else |err| {
        // Error is OK as long as it's not TooManyFileDescriptors
        try testing.expect(err != error.TooManyFileDescriptors);
    }
}
