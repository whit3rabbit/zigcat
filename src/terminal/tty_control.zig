const std = @import("std");
const posix = std.posix;

const tty_state = @import("tty_state.zig");

const has_termios = @hasDecl(posix, "tcgetattr");

pub const TtyError = if (has_termios)
    posix.TermiosGetError || posix.TermiosSetError || error{TermiosNotSaved}
else
    error{UnsupportedPlatform};

pub fn saveOriginalTermios(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.ops.isatty(state.fd)) {
        return error.NotATerminal;
    }

    const original = try state.ops.tcgetattr(state.fd);
    state.original_termios = original;
    state.is_raw = false;
}

pub fn enableRawMode(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (state.is_raw) return;

    const original = state.original_termios orelse return error.TermiosNotSaved;

    var raw = original;
    inline for (.{ "BRKINT", "ICRNL", "INPCK", "ISTRIP", "IXON" }) |flag| {
        setBoolFlag(&raw.iflag, flag, false);
    }

    setBoolFlag(&raw.oflag, "OPOST", false);

    if (@hasField(@TypeOf(raw.cflag), "CSIZE")) {
        const FieldType = @TypeOf(@field(raw.cflag, "CSIZE"));
        if (@hasField(FieldType, "CS8")) {
            @field(raw.cflag, "CSIZE") = FieldType.CS8;
        }
    }

    inline for (.{ "ECHO", "ICANON", "IEXTEN", "ISIG" }) |flag| {
        setBoolFlag(&raw.lflag, flag, false);
    }
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try state.ops.tcsetattr(state.fd, .FLUSH, raw);
    state.is_raw = true;
}

pub fn disableRawMode(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.is_raw) return;
    try restoreOriginalTermios(state);
}

pub fn restoreOriginalTermios(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.is_raw) return;

    const original = state.original_termios orelse return error.TermiosNotSaved;
    try state.ops.tcsetattr(state.fd, .FLUSH, original);
    state.is_raw = false;
}

pub fn setLocalEcho(state: *tty_state.TtyState, enable: bool) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    _ = state.original_termios orelse return error.TermiosNotSaved;

    var term = try state.ops.tcgetattr(state.fd);

    setBoolFlag(&term.lflag, "ECHO", enable);

    try state.ops.tcsetattr(state.fd, .NOW, term);
}

fn setBoolFlag(ptr: anytype, comptime name: []const u8, value: bool) void {
    if (@hasField(@TypeOf(ptr.*), name)) {
        @field(ptr.*, name) = value;
    }
}
