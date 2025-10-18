const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol");
const telnet = protocol.telnet;
const telnet_options = protocol.telnet_options;
const telnet_environ = protocol.telnet_environ;
const tty_state = protocol.tty_state;
const posix = std.posix;

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;
const EchoHandler = telnet_options.EchoHandler;
const TerminalTypeHandler = telnet_options.TerminalTypeHandler;
const NAWSHandler = telnet_options.NAWSHandler;
const SuppressGoAheadHandler = telnet_options.SuppressGoAheadHandler;
const LinemodeHandler = telnet_options.LinemodeHandler;
const OptionHandlerRegistry = telnet_options.OptionHandlerRegistry;
const NewEnvironHandler = telnet_options.NewEnvironHandler;

test "NewEnviron buildIsResponse encodes variables" {
    var value = try testing.allocator.dupe(u8, "ansi");
    defer testing.allocator.free(value);

    var entries = [_]telnet_environ.OwnedEntry{
        .{ .name = "TERM", .value = value, .kind = .variable },
    };

    const payload = try telnet_environ.buildIsResponse(testing.allocator, &entries);
    defer testing.allocator.free(payload);

    const expected = [_]u8{
        telnet_environ.NewEnviron.IS,
        telnet_environ.NewEnviron.VAR,
        'T',
        'E',
        'R',
        'M',
        telnet_environ.NewEnviron.VALUE,
        'a',
        'n',
        's',
        'i',
    };

    try testing.expectEqualSlices(u8, &expected, payload);
}

test "EchoHandler - handle WILL echo" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try EchoHandler.handleWill(testing.allocator, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.do),
        @intFromEnum(TelnetOption.echo),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "EchoHandler - handle DO echo" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try EchoHandler.handleDo(testing.allocator, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.will),
        @intFromEnum(TelnetOption.echo),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "EchoHandler - handle WONT echo" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try try EchoHandler.handleWont(testing.allocator, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.dont),
        @intFromEnum(TelnetOption.echo),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "EchoHandler - handle DONT echo" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try try EchoHandler.handleDont(testing.allocator, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.wont),
        @intFromEnum(TelnetOption.echo),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "TerminalTypeHandler - handle SEND subnegotiation" {
    const terminal_type = "xterm-256color";
    const handler = TerminalTypeHandler.init(terminal_type);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const send_data = [_]u8{1}; // SEND command
    try handler.handleSubnegotiation(testing.allocator, &send_data, &response);

    const expected_start = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
        0, // IS command
    };

    const expected_end = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.se),
    };

    try testing.expect(response.items.len >= expected_start.len + terminal_type.len + expected_end.len);
    try testing.expectEqualSlices(u8, &expected_start, response.items[0..expected_start.len]);
    try testing.expectEqualSlices(u8, terminal_type, response.items[expected_start.len .. expected_start.len + terminal_type.len]);
    try testing.expectEqualSlices(u8, &expected_end, response.items[response.items.len - expected_end.len ..]);
}

test "TerminalTypeHandler - handle IS subnegotiation" {
    const terminal_type = "xterm";
    const handler = TerminalTypeHandler.init(terminal_type);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const is_data = [_]u8{ 0, 'v', 't', '1', '0', '0' }; // IS vt100
    try handler.handleSubnegotiation(testing.allocator, &is_data, &response);

    // Should not generate any response for IS command
    try testing.expectEqual(@as(usize, 0), response.items.len);
}

test "NAWSHandler - send window size" {
    const handler = NAWSHandler.init(80, 24);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try handler.sendWindowSize(testing.allocator, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.naws),
        0, 80, // Width: 80 (big-endian)
        0,                               24, // Height: 24 (big-endian)
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.se),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "NAWSHandler - handle DO NAWS" {
    const handler = NAWSHandler.init(132, 43);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try handler.handleDo(testing.allocator, &response);

    // Should respond with WILL and then send window size
    const expected_will = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.will),
        @intFromEnum(TelnetOption.naws),
    };

    const expected_naws = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.naws),
        0, 132, // Width: 132 (big-endian)
        0,                               43, // Height: 43 (big-endian)
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.se),
    };

    try testing.expect(response.items.len >= expected_will.len + expected_naws.len);
    try testing.expectEqualSlices(u8, &expected_will, response.items[0..expected_will.len]);
    try testing.expectEqualSlices(u8, &expected_naws, response.items[expected_will.len..]);
}

test "NAWSHandler - parse window size subnegotiation" {
    const data = [_]u8{ 0, 120, 0, 30 }; // Width: 120, Height: 30
    const result = NAWSHandler.handleSubnegotiation(&data);

    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 120), result.?.width);
    try testing.expectEqual(@as(u16, 30), result.?.height);
}

test "NAWSHandler - parse invalid window size subnegotiation" {
    const data = [_]u8{ 0, 120 }; // Too short
    const result = NAWSHandler.handleSubnegotiation(&data);

    try testing.expect(result == null);
}

test "NAWSHandler - update window size" {
    var handler = NAWSHandler.init(80, 24);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try handler.updateWindowSize(testing.allocator, 100, 50, &response);

    try testing.expectEqual(@as(u16, 100), handler.width);
    try testing.expectEqual(@as(u16, 50), handler.height);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.naws),
        0, 100, // Width: 100 (big-endian)
        0,                               50, // Height: 50 (big-endian)
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.se),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "SuppressGoAheadHandler - handle all commands" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    // Test WILL
    try try SuppressGoAheadHandler.handleWill(testing.allocator, &response);
    var expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.do),
        @intFromEnum(TelnetOption.suppress_ga),
    };
    try testing.expectEqualSlices(u8, &expected, response.items[0..3]);

    // Test DO
    response.clearRetainingCapacity();
    try try SuppressGoAheadHandler.handleDo(testing.allocator, &response);
    expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.will),
        @intFromEnum(TelnetOption.suppress_ga),
    };
    try testing.expectEqualSlices(u8, &expected, response.items);

    // Test WONT
    response.clearRetainingCapacity();
    try try SuppressGoAheadHandler.handleWont(testing.allocator, &response);
    expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.dont),
        @intFromEnum(TelnetOption.suppress_ga),
    };
    try testing.expectEqualSlices(u8, &expected, response.items);

    // Test DONT
    response.clearRetainingCapacity();
    try try SuppressGoAheadHandler.handleDont(testing.allocator, &response);
    expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.wont),
        @intFromEnum(TelnetOption.suppress_ga),
    };
    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "LinemodeHandler - handle DO linemode" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    var handler = LinemodeHandler.init(null);
    try handler.handleDo(testing.allocator, &response);

    const expected_will = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.will),
        @intFromEnum(TelnetOption.linemode),
    };

    try testing.expectEqualSlices(u8, &expected_will, response.items);
}

fn buildFakeTty() tty_state.TtyState {
    const ops = tty_state.Ops{
        .isatty = struct {
            fn f(_: posix.fd_t) bool {
                return true;
            }
        }.f,
        .tcgetattr = struct {
            fn f(_: posix.fd_t) posix.TermiosGetError!posix.termios {
                return fakeTermios;
            }
        }.f,
        .tcsetattr = struct {
            fn f(_: posix.fd_t, _: posix.TCSA, _: posix.termios) posix.TermiosSetError!void {
                return;
            }
        }.f,
    };

    return tty_state.initWithOps(0, ops);
}

var fakeTermios = std.mem.zeroInit(posix.termios, .{});

test "LinemodeHandler - send settings emits SLC table" {
    // Populate fake termios with representative control characters
    if (@hasField(posix.V, "INTR")) {
        fakeTermios.cc[@intFromEnum(@field(posix.V, "INTR"))] = 3;
    }
    if (@hasField(posix.V, "ERASE")) {
        fakeTermios.cc[@intFromEnum(@field(posix.V, "ERASE"))] = 0x7F;
    }

    var tty = buildFakeTty();
    var handler = LinemodeHandler.init(&tty);

    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try handler.sendLinemodeSettings(testing.allocator, &response);

    // The MODE subnegotiation should appear first
    try testing.expectEqual(@as(u8, @intFromEnum(TelnetCommand.iac)), response.items[0]);
    try testing.expectEqual(@as(u8, @intFromEnum(TelnetCommand.sb)), response.items[1]);
    try testing.expectEqual(@as(u8, @intFromEnum(TelnetOption.linemode)), response.items[2]);
    try testing.expectEqual(@as(u8, 1), response.items[3]);
    try testing.expectEqual(@as(u8, 0x03), response.items[4]); // MODE_EDIT | MODE_TRAPSIG
    try testing.expectEqual(@as(u8, @intFromEnum(TelnetCommand.iac)), response.items[5]);
    try testing.expectEqual(@as(u8, @intFromEnum(TelnetCommand.se)), response.items[6]);

    // Locate the SLC subnegotiation
    const slc_pattern = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.linemode),
        3,
    };
    const slc_offset = std.mem.indexOf(u8, response.items, &slc_pattern) orelse unreachable;
    const slc_slice = blk: {
        const after = response.items[slc_offset + slc_pattern.len ..];
        const iac_index = std.mem.indexOfScalar(u8, after, @intFromEnum(TelnetCommand.iac)) orelse unreachable;
        break :blk after[0..iac_index];
    };

    var found_intr = false;
    var found_erase = false;
    var i: usize = 0;
    while (i + 2 <= slc_slice.len) : (i += 3) {
        const func = slc_slice[i];
        const flags = slc_slice[i + 1];
        const value = slc_slice[i + 2];

        switch (func) {
            3 => { // SLC_IP
                found_intr = true;
                try testing.expect(flags & 0x02 != 0);
                if (@hasField(posix.V, "INTR")) {
                    try testing.expectEqual(@as(u8, 3), value);
                }
            },
            10 => { // SLC_EC
                found_erase = true;
                if (@hasField(posix.V, "ERASE")) {
                    try testing.expectEqual(@as(u8, 0x7F), value);
                }
            },
            else => {},
        }
    }

    try testing.expect(found_intr);
    try testing.expect(found_erase or !@hasField(posix.V, "ERASE"));
}

test "LinemodeHandler - handle MODE subnegotiation" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    var handler = LinemodeHandler.init(null);

    const mode_data = [_]u8{ 1, 5 }; // MODE command with EDIT and LIT_ECHO
    try handler.handleSubnegotiation(testing.allocator, &mode_data, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.linemode),
        1, // MODE command
        5 | 4, // Original mode with ACK bit set
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.se),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "LinemodeHandler - handle MODE subnegotiation with ACK" {
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const mode_data = [_]u8{ 1, 7 }; // MODE command with ACK bit already set
    try LinemodeHandler.handleSubnegotiation(testing.allocator, &mode_data, &response);

    // Should not respond to ACK
    try testing.expectEqual(@as(usize, 0), response.items.len);
}

test "OptionHandlerRegistry - initialization" {
    const registry = OptionHandlerRegistry.init("xterm", 80, 24, null);

    try testing.expectEqualStrings("xterm", registry.terminal_type_handler.terminal_type);
    try testing.expectEqual(@as(u16, 80), registry.naws_handler.width);
    try testing.expectEqual(@as(u16, 24), registry.naws_handler.height);
}

test "OptionHandlerRegistry - handle supported option negotiation" {
    var registry = OptionHandlerRegistry.init("vt100", 132, 43, null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try registry.handleNegotiation(testing.allocator, .do, .echo, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.will),
        @intFromEnum(TelnetOption.echo),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "OptionHandlerRegistry - DO linemode emits SLC" {
    // Reuse fake termios populated with representative characters
    fakeTermios = std.mem.zeroInit(posix.termios, .{});
    if (@hasField(posix.V, "INTR")) {
        fakeTermios.cc[@intFromEnum(@field(posix.V, "INTR"))] = 3;
    }

    var tty = buildFakeTty();
    var registry = OptionHandlerRegistry.init("xterm", 80, 24, &tty);

    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try registry.handleNegotiation(testing.allocator, .do, .linemode, &response);

    const pattern = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.linemode),
        3,
    };
    const offset = std.mem.indexOf(u8, response.items, &pattern) orelse unreachable;
    const triplets = blk: {
        const after = response.items[offset + pattern.len ..];
        const iac_idx = std.mem.indexOfScalar(u8, after, @intFromEnum(TelnetCommand.iac)) orelse unreachable;
        break :blk after[0..iac_idx];
    };

    try testing.expect(triplets.len >= 3);
    try testing.expect(registry.linemode_handler.slc_values[LinemodeHandler.SLC_IP] == 3 or !@hasField(posix.V, "INTR"));
}

test "LinemodeHandler parses SLC reply" {
    var handler = LinemodeHandler.init(null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const slc_payload = [_]u8{ LinemodeHandler.SLC, LinemodeHandler.SLC_IP, LinemodeHandler.SLC_VALUE, 0x05, LinemodeHandler.SLC_EC, LinemodeHandler.SLC_NOSUPPORT, 0 };
    try handler.handleSubnegotiation(testing.allocator, &slc_payload, &response);

    try testing.expectEqual(@as(u8, 0x05), handler.slc_values[LinemodeHandler.SLC_IP]);
    try testing.expectEqual(@as(u8, 0xFF), handler.slc_values[LinemodeHandler.SLC_EC]);
}

test "OptionHandlerRegistry - handle unsupported option negotiation" {
    var registry = OptionHandlerRegistry.init("xterm", 80, 24, null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try registry.handleNegotiation(testing.allocator, .will, .status, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.dont),
        @intFromEnum(TelnetOption.status),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "OptionHandlerRegistry - handle terminal type subnegotiation" {
    var registry = OptionHandlerRegistry.init("ansi", 80, 24, null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const send_data = [_]u8{1}; // SEND command
    try registry.handleSubnegotiation(testing.allocator, .terminal_type, &send_data, &response);

    const expected_start = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
        0, // IS command
    };

    const expected_end = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.se),
    };

    try testing.expect(response.items.len >= expected_start.len + 4 + expected_end.len);
    try testing.expectEqualSlices(u8, &expected_start, response.items[0..expected_start.len]);
    try testing.expectEqualSlices(u8, "ansi", response.items[expected_start.len .. expected_start.len + 4]);
    try testing.expectEqualSlices(u8, &expected_end, response.items[response.items.len - expected_end.len ..]);
}

test "OptionHandlerRegistry - handle NAWS subnegotiation" {
    var registry = OptionHandlerRegistry.init("xterm", 80, 24, null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const naws_data = [_]u8{ 0, 100, 0, 30 }; // Width: 100, Height: 30
    try registry.handleSubnegotiation(testing.allocator, .naws, &naws_data, &response);

    // NAWS subnegotiation doesn't generate a response, just processes the data
    try testing.expectEqual(@as(usize, 0), response.items.len);
}

test "OptionHandlerRegistry - update window size" {
    var registry = OptionHandlerRegistry.init("xterm", 80, 24, null);
    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    try registry.updateWindowSize(testing.allocator, 120, 40, &response);

    try testing.expectEqual(@as(u16, 120), registry.naws_handler.width);
    try testing.expectEqual(@as(u16, 40), registry.naws_handler.height);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.naws),
        0, 120, // Width: 120 (big-endian)
        0,                               40, // Height: 40 (big-endian)
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.se),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

test "OptionHandlerRegistry - respond to NEW-ENVIRON SEND" {
    var registry = OptionHandlerRegistry.init("xterm", 80, 24, null);
    registry.new_environ_handler.fetch_fn = testFetchEnv;

    var response = std.ArrayList(u8).init(testing.allocator);
    defer response.deinit();

    const request = [_]u8{telnet_environ.NewEnviron.SEND};
    try registry.handleSubnegotiation(testing.allocator, .new_environ, &request, &response);

    const expected = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.new_environ),
        telnet_environ.NewEnviron.IS,
        telnet_environ.NewEnviron.VAR,
        'T',
        'E',
        'R',
        'M',
        telnet_environ.NewEnviron.VALUE,
        'a',
        'n',
        's',
        'i',
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.se),
    };

    try testing.expectEqualSlices(u8, &expected, response.items);
}

fn testFetchEnv(
    allocator: std.mem.Allocator,
    requested: []const []const u8,
) NewEnvironHandler.FetchError!telnet_environ.Collection {
    _ = requested;

    var collection = telnet_environ.Collection.init(allocator);
    errdefer collection.deinit();

    const value = try allocator.dupe(u8, "ansi");
    errdefer allocator.free(value);
    try collection.entries.append(allocator, .{ .name = "TERM", .value = value, .kind = .variable });

    return collection;
}
