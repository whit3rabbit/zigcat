//! This module defines the state management for terminal (TTY) operations.
//! Its primary purpose is to hold the original terminal settings (`termios`) so
//! they can be restored when the application exits, ensuring the terminal is
...
//! (`tcgetattr`, `tcsetattr`, etc.) can be mocked for testing purposes.

const std = @import("std");
const posix = std.posix;

const has_termios = @hasDecl(posix, "tcgetattr");

pub const Ops = if (has_termios)
    struct {
        isatty: *const fn (posix.fd_t) bool,
        tcgetattr: *const fn (posix.fd_t) posix.TermiosGetError!posix.termios,
        tcsetattr: *const fn (posix.fd_t, posix.TCSA, posix.termios) posix.TermiosSetError!void,
    }
else
    struct {
        isatty: *const fn (posix.fd_t) bool,
    };

pub const default_ops = if (has_termios)
    Ops{
        .isatty = posix.isatty,
        .tcgetattr = posix.tcgetattr,
        .tcsetattr = posix.tcsetattr,
    }
else
    Ops{
        .isatty = posix.isatty,
    };

pub const TtyState = if (has_termios)
    struct {
        fd: posix.fd_t,
        original_termios: ?posix.termios = null,
        is_raw: bool = false,
        ops: Ops = default_ops,
    }
else
    struct {
        fd: posix.fd_t,
        is_raw: bool = false,
        ops: Ops = default_ops,
    };

/// Initializes a new `TtyState` with the default system operations.
///
/// - `fd`: The file descriptor for the terminal (e.g., `std.io.getStdIn().handle`).
///
/// Returns a `TtyState` instance ready to be used with `tty_control` functions.
pub fn init(fd: posix.fd_t) TtyState {
    return initWithOps(fd, default_ops);
}

/// Initializes a new `TtyState` with custom operations.
///
/// This function is primarily used for testing, allowing the injection of mock
/// functions for `isatty`, `tcgetattr`, and `tcsetattr`.
///
/// - `fd`: The file descriptor for the terminal.
/// - `ops`: A struct containing function pointers for terminal operations.
///
/// Returns a `TtyState` instance configured with the provided operations.
pub fn initWithOps(fd: posix.fd_t, ops: Ops) TtyState {
    return TtyState{
        .fd = fd,
        .ops = ops,
    };
}

/// Checks if a file descriptor refers to a terminal.
///
/// This is a direct wrapper around the underlying `posix.isatty` function.
///
/// - `fd`: The file descriptor to check.
///
/// Returns `true` if the descriptor is a TTY, `false` otherwise.
pub fn isatty(fd: posix.fd_t) bool {
    return posix.isatty(fd);
}

/// Checks if the file descriptor within a `TtyState` refers to a terminal.
///
/// This uses the `isatty` function pointer from the `ops` field, allowing it
/// to be mocked for testing.
///
/// - `state`: A pointer to the `TtyState` to check.
///
/// Returns `true` if the descriptor is a TTY, `false` otherwise.
pub fn isTerminal(state: *const TtyState) bool {
    return state.ops.isatty(state.fd);
}

/// Reports whether the current platform supports terminal raw mode.
///
/// Support is determined at compile time by checking for the presence of
/// `posix.tcgetattr`.
///
/// Returns `true` if raw mode is supported, `false` otherwise.
pub fn supportsRawMode() bool {
    return has_termios;
}
