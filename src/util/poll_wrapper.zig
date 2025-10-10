//! Cross-platform `poll()` abstraction shared by all event loops.
//!
//! - On Unix-like targets we delegate straight to `posix.poll()` so descriptor
//!   limits and semantics match the native API.
//! - On Windows we emulate the interface on top of `select()`, which keeps the
//!   code path compatible with console pipes while avoiding IOCP/WSAPoll.
//!
//! Known limitations:
//! - The Windows emulation inherits `FD_SETSIZE` (typically 64) and therefore
//!   cannot watch more sockets than `select()` allows.
//! - `select()` has no `POLLPRI` equivalent; callers only receive readable,
//!   writable, or error notifications.
//! - Sockets with values greater than `FD_SETSIZE` are rejected by `select()`,
//!   so we rely on the surrounding code to keep descriptor counts low.
//!
//! Usage:
//! ```zig
//! const poll_wrapper = @import("util/poll_wrapper.zig");
//! var pollfds = [_]poll_wrapper.pollfd{
//!     .{ .fd = sock, .events = poll_wrapper.POLL.IN, .revents = 0 },
//! };
//! const ready = try poll_wrapper.poll(&pollfds, timeout_ms);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

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
        return pollWindows(fds, timeout_ms);
    } else {
        return posix.poll(fds, timeout_ms);
    }
}

// Windows-specific poll() implementation using select()
fn pollWindows(fds: []pollfd, timeout_ms: i32) !usize {
    const windows = std.os.windows;
    const ws2_32 = windows.ws2_32;

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
            FD_SET(pfd.fd, &read_fds);
        }
        if (pfd.events & POLL.OUT != 0) {
            FD_SET(pfd.fd, &write_fds);
        }
        // Always include the descriptor in the error set so `POLLERR` maps
        // to `select()`'s exceptional condition; callers must keep probing
        // `revents & POLL.ERR` just like they would on POSIX.
        FD_SET(pfd.fd, &error_fds);

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

    // Use a hash map for efficient lookup of revents
    var revents_map = std.HashMap(posix.socket_t, i16).init(std.heap.page_allocator);
    defer revents_map.deinit();

    var i: u32 = 0;
    while (i < read_fds.fd_count) : (i += 1) {
        const fd = read_fds.fd_array[i];
        const entry = try revents_map.getOrPut(fd);
        entry.value_ptr.* |= POLL.IN;
    }

    i = 0;
    while (i < write_fds.fd_count) : (i += 1) {
        const fd = write_fds.fd_array[i];
        const entry = try revents_map.getOrPut(fd);
        entry.value_ptr.* |= POLL.OUT;
    }

    i = 0;
    while (i < error_fds.fd_count) : (i += 1) {
        const fd = error_fds.fd_array[i];
        const entry = try revents_map.getOrPut(fd);
        entry.value_ptr.* |= POLL.ERR;
    }

    // Update revents for each fd
    var ready_count: usize = 0;
    for (fds) |*pfd| {
        if (revents_map.get(pfd.fd)) |revents| {
            pfd.revents = revents;
            ready_count += 1;
        }
    }

    return ready_count;
}

// Windows fd_set helper functions
fn FD_ZERO(set: *std.os.windows.ws2_32.fd_set) void {
    set.fd_count = 0;
}

fn FD_SET(fd: posix.socket_t, set: *std.os.windows.ws2_32.fd_set) void {
    const ws2_32 = std.os.windows.ws2_32;
    if (set.fd_count < ws2_32.FD_SETSIZE) {
        set.fd_array[set.fd_count] = fd;
        set.fd_count += 1;
    }
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
