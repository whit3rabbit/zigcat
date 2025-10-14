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

pub fn init(fd: posix.fd_t) TtyState {
    return initWithOps(fd, default_ops);
}

pub fn initWithOps(fd: posix.fd_t, ops: Ops) TtyState {
    return TtyState{
        .fd = fd,
        .ops = ops,
    };
}

pub fn isatty(fd: posix.fd_t) bool {
    return posix.isatty(fd);
}

pub fn isTerminal(state: *const TtyState) bool {
    return state.ops.isatty(state.fd);
}

pub fn supportsRawMode() bool {
    return has_termios;
}
