const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const protocol = @import("protocol");
const telnet = protocol.telnet;
const telnet_options = protocol.telnet_options;
const tty_state = protocol.tty_state;
const tty_control = protocol.tty_control;

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;

const raw_supported = tty_state.supportsRawMode();

const TestHooks = struct {
    pub var current: posix.termios = std.mem.zeroes(posix.termios);
    pub var set_calls: usize = 0;
    pub var is_tty: bool = true;

    pub fn reset(termios_value: posix.termios) void {
        current = termios_value;
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
        return current;
    }

    fn tcsetattr(_: posix.fd_t, _: posix.TCSA, termios_value: posix.termios) posix.TermiosSetError!void {
        current = termios_value;
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

fn makeTermios(echo_enabled: bool) posix.termios {
    var term = std.mem.zeroes(posix.termios);
    setBoolFlag(&term.lflag, "ECHO", echo_enabled);
    return term;
}

test "echo handler disables local echo on WILL" {
    if (!raw_supported) return error.SkipZigTest;

    var state = tty_state.initWithOps(0, makeOps());
    TestHooks.reset(makeTermios(true));
    try tty_control.saveOriginalTermios(&state);

    var handler = telnet_options.EchoHandler.init(&state);
    var response = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer response.deinit(testing.allocator);

    try handler.handleWill(testing.allocator, &response);

    try testing.expect(TestHooks.set_calls > 0);
    try testing.expect(!getBoolFlag(TestHooks.current.lflag, "ECHO"));
    try testing.expectEqualSlices(u8, &[_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.do),
        @intFromEnum(TelnetOption.echo),
    }, response.items);
}

test "echo handler enables local echo on WONT" {
    if (!raw_supported) return error.SkipZigTest;

    var state = tty_state.initWithOps(0, makeOps());
    TestHooks.reset(makeTermios(false));
    try tty_control.saveOriginalTermios(&state);

    var handler = telnet_options.EchoHandler.init(&state);
    var response = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer response.deinit(testing.allocator);

    try handler.handleWont(testing.allocator, &response);

    try testing.expect(TestHooks.set_calls > 0);
    try testing.expect(getBoolFlag(TestHooks.current.lflag, "ECHO"));
    try testing.expectEqualSlices(u8, &[_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.dont),
        @intFromEnum(TelnetOption.echo),
    }, response.items);
}

test "option registry toggles local echo across negotiations" {
    if (!raw_supported) return error.SkipZigTest;

    var state = tty_state.initWithOps(0, makeOps());
    TestHooks.reset(makeTermios(true));
    try tty_control.saveOriginalTermios(&state);

    var registry = telnet_options.OptionHandlerRegistry.init("xterm", 80, 24, &state);

    var response = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer response.deinit(testing.allocator);

    try registry.handleNegotiation(testing.allocator, TelnetCommand.will, TelnetOption.echo, &response);
    try testing.expect(!getBoolFlag(TestHooks.current.lflag, "ECHO"));

    response.clearRetainingCapacity();
    try registry.handleNegotiation(testing.allocator, TelnetCommand.wont, TelnetOption.echo, &response);
    try testing.expect(getBoolFlag(TestHooks.current.lflag, "ECHO"));
}

test "echo handler ignores missing tty state" {
    if (!raw_supported) return error.SkipZigTest;

    var handler = telnet_options.EchoHandler.init(null);
    var response = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer response.deinit(testing.allocator);

    try handler.handleDo(testing.allocator, &response);
    try testing.expectEqual(@as(usize, 3), response.items.len);
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
