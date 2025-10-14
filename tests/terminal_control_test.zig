const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const terminal = @import("terminal");
const tty_state = terminal.tty_state;
const tty_control = terminal.tty_control;

const raw_supported = tty_state.supportsRawMode();

const TestHooks = struct {
    pub var next_get: posix.termios = std.mem.zeroes(posix.termios);
    pub var last_set: ?posix.termios = null;
    pub var prev_set: ?posix.termios = null;
    pub var set_calls: usize = 0;
    pub var is_tty: bool = true;

    pub fn reset(termios_value: posix.termios) void {
        next_get = termios_value;
        last_set = null;
        prev_set = null;
        set_calls = 0;
        is_tty = true;
    }

    pub fn setIsTty(value: bool) void {
        is_tty = value;
    }

    fn isatty(_: posix.fd_t) bool {
        return is_tty;
    }

    fn tcgetattr(_: posix.fd_t) posix.TermiosGetError!posix.termios {
        return next_get;
    }

    fn tcsetattr(_: posix.fd_t, _: posix.TCSA, termios_value: posix.termios) posix.TermiosSetError!void {
        prev_set = last_set;
        last_set = termios_value;
        set_calls += 1;
    }
};

fn makeOps() tty_state.Ops {
    return tty_state.Ops{
        .isatty = TestHooks.isatty,
        .tcgetattr = TestHooks.tcgetattr,
        .tcsetattr = TestHooks.tcsetattr,
    };
}

fn makeSampleTermios() posix.termios {
    var term = std.mem.zeroes(posix.termios);
    inline for (.{ "BRKINT", "ICRNL", "INPCK", "ISTRIP", "IXON" }) |flag| {
        setBoolFlag(&term.iflag, flag, true);
    }
    setBoolFlag(&term.oflag, "OPOST", true);
    if (@hasField(@TypeOf(term.cflag), "CSIZE")) {
        const FieldType = @TypeOf(@field(term.cflag, "CSIZE"));
        if (@hasField(FieldType, "CS7")) {
            @field(term.cflag, "CSIZE") = FieldType.CS7;
        }
    }
    inline for (.{ "ECHO", "ICANON", "IEXTEN", "ISIG" }) |flag| {
        setBoolFlag(&term.lflag, flag, true);
    }
    term.cc[@intFromEnum(posix.V.MIN)] = 0;
    term.cc[@intFromEnum(posix.V.TIME)] = 5;
    return term;
}

test "enableRawMode clears cooked flags and sets byte timing" {
    if (!raw_supported) return error.SkipZigTest;

    const original = makeSampleTermios();
    TestHooks.reset(original);

    var state = tty_state.initWithOps(0, makeOps());

    try tty_control.saveOriginalTermios(&state);
    try tty_control.enableRawMode(&state);

    try testing.expect(state.is_raw);
    try testing.expectEqual(@as(usize, 1), TestHooks.set_calls);

    const raw_termios = TestHooks.last_set orelse unreachable;
    inline for (.{ "BRKINT", "ICRNL", "INPCK", "ISTRIP", "IXON" }) |flag| {
        try testing.expect(!getBoolFlag(raw_termios.iflag, flag));
    }
    try testing.expect(!getBoolFlag(raw_termios.oflag, "OPOST"));

    inline for (.{ "ECHO", "ICANON", "IEXTEN", "ISIG" }) |flag| {
        try testing.expect(!getBoolFlag(raw_termios.lflag, flag));
    }
    if (@hasField(@TypeOf(raw_termios.cflag), "CSIZE")) {
        const FieldType = @TypeOf(@field(raw_termios.cflag, "CSIZE"));
        if (@hasField(FieldType, "CS8")) {
            try testing.expect(@field(raw_termios.cflag, "CSIZE") == FieldType.CS8);
        }
    }
    try testing.expectEqual(@as(u8, 1), raw_termios.cc[@intFromEnum(posix.V.MIN)]);
    try testing.expectEqual(@as(u8, 0), raw_termios.cc[@intFromEnum(posix.V.TIME)]);
}

test "restoreOriginalTermios reapplies saved configuration" {
    if (!raw_supported) return error.SkipZigTest;

    const original = makeSampleTermios();
    TestHooks.reset(original);

    var state = tty_state.initWithOps(0, makeOps());

    try tty_control.saveOriginalTermios(&state);
    try tty_control.enableRawMode(&state);
    try tty_control.restoreOriginalTermios(&state);

    try testing.expect(!state.is_raw);
    try testing.expectEqual(@as(usize, 2), TestHooks.set_calls);

    const restored = TestHooks.last_set orelse unreachable;
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&restored), std.mem.asBytes(&original)));
}

test "saveOriginalTermios returns NotATerminal when not a tty" {
    if (!raw_supported) return error.SkipZigTest;

    const original = makeSampleTermios();
    TestHooks.reset(original);
    TestHooks.setIsTty(false);

    var state = tty_state.initWithOps(0, makeOps());

    try testing.expectError(error.NotATerminal, tty_control.saveOriginalTermios(&state));
    try testing.expectEqual(@as(usize, 0), TestHooks.set_calls);
}

test "repeated enable and disable cycles preserve state" {
    if (!raw_supported) return error.SkipZigTest;

    const original = makeSampleTermios();
    TestHooks.reset(original);

    var state = tty_state.initWithOps(0, makeOps());

    try tty_control.saveOriginalTermios(&state);
    try tty_control.enableRawMode(&state);
    try testing.expect(state.is_raw);

    try tty_control.disableRawMode(&state);
    try testing.expect(!state.is_raw);
    try testing.expectEqual(@as(usize, 2), TestHooks.set_calls);

    try tty_control.disableRawMode(&state);
    try testing.expectEqual(@as(usize, 2), TestHooks.set_calls);

    try tty_control.enableRawMode(&state);
    try tty_control.restoreOriginalTermios(&state);
    try testing.expect(!state.is_raw);
    try testing.expectEqual(@as(usize, 4), TestHooks.set_calls);
}

fn setBoolFlag(ptr: anytype, comptime name: []const u8, value: bool) void {
    if (@hasField(@TypeOf(ptr.*), name)) {
        @field(ptr.*, name) = value;
    }
}

fn getBoolFlag(value: anytype, comptime name: []const u8) bool {
    if (@hasField(@TypeOf(value), name)) {
        return @field(value, name);
    }
    return false;
}
