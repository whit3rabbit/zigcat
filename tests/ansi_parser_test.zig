// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const ansi_parser = @import("protocol").ansi_parser;
const ansi_commands = @import("protocol").ansi_commands;
const ansi_state = @import("protocol").ansi_state;

const Parser = ansi_parser.Parser;
const Handler = ansi_parser.Handler;

// Test context for collecting parser events
const TestContext = struct {
    printed: std.ArrayList(u8),
    executed: std.ArrayList(u8),
    csi_sequences: std.ArrayList(CsiSeq),
    esc_sequences: std.ArrayList(EscSeq),
    osc_strings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const CsiSeq = struct {
        params: []u16,
        intermediates: []u8,
        private_marker: u8,
        final: u8,
    };

    const EscSeq = struct {
        intermediates: []u8,
        final: u8,
    };

    fn init(allocator: std.mem.Allocator) TestContext {
        return .{
            .printed = std.ArrayList(u8).init(allocator),
            .executed = std.ArrayList(u8).init(allocator),
            .csi_sequences = std.ArrayList(CsiSeq).init(allocator),
            .esc_sequences = std.ArrayList(EscSeq).init(allocator),
            .osc_strings = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestContext) void {
        self.printed.deinit();
        self.executed.deinit();

        for (self.csi_sequences.items) |seq| {
            self.allocator.free(seq.params);
            self.allocator.free(seq.intermediates);
        }
        self.csi_sequences.deinit();

        for (self.esc_sequences.items) |seq| {
            self.allocator.free(seq.intermediates);
        }
        self.esc_sequences.deinit();

        for (self.osc_strings.items) |str| {
            self.allocator.free(str);
        }
        self.osc_strings.deinit();
    }

    fn printFn(ctx: *anyopaque, ch: u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));
        self.printed.append(ch) catch unreachable;
    }

    fn executeFn(ctx: *anyopaque, ch: u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));
        self.executed.append(ch) catch unreachable;
    }

    fn csiDispatchFn(
        ctx: *anyopaque,
        params: []const u16,
        intermediates: []const u8,
        private_marker: u8,
        final: u8,
    ) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));

        const params_copy = self.allocator.dupe(u16, params) catch unreachable;
        const inter_copy = self.allocator.dupe(u8, intermediates) catch unreachable;

        self.csi_sequences.append(.{
            .params = params_copy,
            .intermediates = inter_copy,
            .private_marker = private_marker,
            .final = final,
        }) catch unreachable;
    }

    fn escDispatchFn(ctx: *anyopaque, intermediates: []const u8, final: u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));

        const inter_copy = self.allocator.dupe(u8, intermediates) catch unreachable;

        self.esc_sequences.append(.{
            .intermediates = inter_copy,
            .final = final,
        }) catch unreachable;
    }

    fn oscDispatchFn(ctx: *anyopaque, data: []const u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));
        const data_copy = self.allocator.dupe(u8, data) catch unreachable;
        self.osc_strings.append(data_copy) catch unreachable;
    }

    fn getHandler(self: *TestContext) Handler {
        return .{
            .print_fn = printFn,
            .execute_fn = executeFn,
            .csi_dispatch_fn = csiDispatchFn,
            .esc_dispatch_fn = escDispatchFn,
            .osc_dispatch_fn = oscDispatchFn,
            .context = self,
        };
    }
};

// Tests

test "parser init and deinit" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try testing.expectEqual(ansi_parser.State.ground, parser.getState());
}

test "parse printable characters" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("Hello, World!");

    try testing.expectEqualStrings("Hello, World!", ctx.printed.items);
    try testing.expectEqual(@as(usize, 0), ctx.executed.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.csi_sequences.items.len);
}

test "parse C0 controls" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    // Tab, newline, carriage return
    try parser.parse("\t\n\r");

    try testing.expectEqual(@as(usize, 3), ctx.executed.items.len);
    try testing.expectEqual(@as(u8, '\t'), ctx.executed.items[0]);
    try testing.expectEqual(@as(u8, '\n'), ctx.executed.items[1]);
    try testing.expectEqual(@as(u8, '\r'), ctx.executed.items[2]);
}

test "parse simple CSI sequence - cursor up" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[5A"); // Cursor up 5 lines

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(usize, 1), seq.params.len);
    try testing.expectEqual(@as(u16, 5), seq.params[0]);
    try testing.expectEqual(@as(u8, 'A'), seq.final);
}

test "parse CSI sequence with multiple parameters" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[10;20H"); // Cursor position line 10, column 20

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(usize, 2), seq.params.len);
    try testing.expectEqual(@as(u16, 10), seq.params[0]);
    try testing.expectEqual(@as(u16, 20), seq.params[1]);
    try testing.expectEqual(@as(u8, 'H'), seq.final);
}

test "parse SGR sequence - bold red" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[1;31m"); // Bold + red foreground

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(usize, 2), seq.params.len);
    try testing.expectEqual(@as(u16, 1), seq.params[0]);
    try testing.expectEqual(@as(u16, 31), seq.params[1]);
    try testing.expectEqual(@as(u8, 'm'), seq.final);
}

test "parse 256-color SGR sequence" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[38;5;208m"); // 256-color orange foreground

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(usize, 3), seq.params.len);
    try testing.expectEqual(@as(u16, 38), seq.params[0]);
    try testing.expectEqual(@as(u16, 5), seq.params[1]);
    try testing.expectEqual(@as(u16, 208), seq.params[2]);
}

test "parse true-color SGR sequence" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[38;2;255;100;0m"); // RGB orange foreground

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(usize, 5), seq.params.len);
    try testing.expectEqual(@as(u16, 38), seq.params[0]);
    try testing.expectEqual(@as(u16, 2), seq.params[1]);
    try testing.expectEqual(@as(u16, 255), seq.params[2]);
    try testing.expectEqual(@as(u16, 100), seq.params[3]);
    try testing.expectEqual(@as(u16, 0), seq.params[4]);
}

test "parse OSC sequence - set title" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B]2;My Window Title\x07"); // Set title, BEL terminator

    try testing.expectEqual(@as(usize, 1), ctx.osc_strings.items.len);
    try testing.expectEqualStrings("2;My Window Title", ctx.osc_strings.items[0]);
}

test "parse OSC sequence - ST terminator" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B]0;Title\x1B\\"); // Set title with ST terminator (ESC \)

    try testing.expectEqual(@as(usize, 1), ctx.osc_strings.items.len);
    try testing.expectEqualStrings("0;Title", ctx.osc_strings.items[0]);
}

test "CAN cancels sequence" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[31\x18m"); // Start SGR, CAN cancels, then 'm'

    // CAN should cancel the sequence and return to ground
    // The 'm' after CAN is just a printable character
    try testing.expectEqual(@as(usize, 0), ctx.csi_sequences.items.len);
    try testing.expectEqual(@as(usize, 1), ctx.executed.items.len);
    try testing.expectEqual(@as(u8, 0x18), ctx.executed.items[0]);
    try testing.expectEqual(@as(usize, 1), ctx.printed.items.len);
    try testing.expectEqual(@as(u8, 'm'), ctx.printed.items[0]);
}

test "ESC cancels previous sequence" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("\x1B[31\x1B[32m"); // Start red, ESC cancels, start green

    // Should only see the green foreground sequence
    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    const seq = ctx.csi_sequences.items[0];
    try testing.expectEqual(@as(u16, 32), seq.params[0]);
}

test "incomplete sequence across buffer boundaries" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    // Split CSI sequence across two parse calls
    try parser.parse("\x1B[3"); // Partial
    try parser.parse("1m"); // Complete

    try testing.expectEqual(@as(usize, 1), ctx.csi_sequences.items.len);
    try testing.expectEqual(@as(u16, 31), ctx.csi_sequences.items[0].params[0]);
}

test "mixed data and escape sequences" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();

    var parser = Parser.init(testing.allocator, ctx.getHandler());
    defer parser.deinit();

    try parser.parse("Hello \x1B[1mbold\x1B[0m world");

    try testing.expectEqualStrings("Hello bold world", ctx.printed.items);
    try testing.expectEqual(@as(usize, 2), ctx.csi_sequences.items.len);
}

// Command parsing tests

test "parseSgr - reset" {
    const attrs = try ansi_commands.parseSgr(testing.allocator, &[_]u16{0});
    defer testing.allocator.free(attrs);

    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expectEqual(ansi_commands.SgrAttribute.reset, attrs[0]);
}

test "parseSgr - 8-color foreground" {
    const attrs = try ansi_commands.parseSgr(testing.allocator, &[_]u16{31});
    defer testing.allocator.free(attrs);

    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0] == .foreground_color);
    try testing.expectEqual(ansi_commands.Color{ .ansi = 1 }, attrs[0].foreground_color);
}

test "parseSgr - 256-color" {
    const attrs = try ansi_commands.parseSgr(testing.allocator, &[_]u16{ 38, 5, 208 });
    defer testing.allocator.free(attrs);

    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0] == .foreground_color);
    try testing.expectEqual(ansi_commands.Color{ .palette = 208 }, attrs[0].foreground_color);
}

test "parseSgr - true-color" {
    const attrs = try ansi_commands.parseSgr(testing.allocator, &[_]u16{ 38, 2, 255, 100, 0 });
    defer testing.allocator.free(attrs);

    try testing.expectEqual(@as(usize, 1), attrs.len);
    try testing.expect(attrs[0] == .foreground_color);
    const rgb = attrs[0].foreground_color.rgb;
    try testing.expectEqual(@as(u8, 255), rgb.r);
    try testing.expectEqual(@as(u8, 100), rgb.g);
    try testing.expectEqual(@as(u8, 0), rgb.b);
}

test "parseCursorMove - up" {
    const move = ansi_commands.parseCursorMove(&[_]u16{5}, 'A');
    try testing.expect(move != null);
    try testing.expectEqual(ansi_commands.CursorMove{ .up = 5 }, move.?);
}

test "parseCursorMove - position" {
    const move = ansi_commands.parseCursorMove(&[_]u16{ 10, 20 }, 'H');
    try testing.expect(move != null);
    try testing.expectEqual(@as(u16, 10), move.?.position.line);
    try testing.expectEqual(@as(u16, 20), move.?.position.column);
}

test "parseErase - display from cursor to end" {
    const erase = ansi_commands.parseErase(&[_]u16{0}, 'J');
    try testing.expect(erase != null);
    try testing.expectEqual(ansi_commands.EraseCommand{ .display = .cursor_to_end }, erase.?);
}

test "parseErase - entire line" {
    const erase = ansi_commands.parseErase(&[_]u16{2}, 'K');
    try testing.expect(erase != null);
    try testing.expectEqual(ansi_commands.EraseCommand{ .line = .entire }, erase.?);
}

test "parseMouseSgr - button press" {
    const mouse = ansi_commands.parseMouseSgr(&[_]u16{ 0, 10, 20 }, '<', 'M');
    try testing.expect(mouse != null);
    try testing.expectEqual(@as(u8, 0), mouse.?.button);
    try testing.expectEqual(@as(u16, 10), mouse.?.x);
    try testing.expectEqual(@as(u16, 20), mouse.?.y);
    try testing.expectEqual(true, mouse.?.press);
}

test "parseMouseSgr - button release" {
    const mouse = ansi_commands.parseMouseSgr(&[_]u16{ 0, 10, 20 }, '<', 'm');
    try testing.expect(mouse != null);
    try testing.expectEqual(false, mouse.?.press);
}

test "parseOsc - set title" {
    const osc = try ansi_commands.parseOsc(testing.allocator, "2;My Title");
    defer ansi_commands.freeOscCommand(testing.allocator, osc);

    try testing.expect(osc == .set_title);
    try testing.expectEqualStrings("My Title", osc.set_title);
}

test "parseOsc - query foreground color" {
    const osc = try ansi_commands.parseOsc(testing.allocator, "10;?");
    defer ansi_commands.freeOscCommand(testing.allocator, osc);

    try testing.expectEqual(ansi_commands.OscCommand.query_foreground_color, osc);
}

// Terminal state tests

test "TerminalState - cursor movement" {
    var state = ansi_state.TerminalState.init(80, 24);

    // Move down 5 lines
    state.applyCursorMove(.{ .down = 5 });
    try testing.expectEqual(@as(u16, 6), state.cursor_line);

    // Move right 10 columns
    state.applyCursorMove(.{ .forward = 10 });
    try testing.expectEqual(@as(u16, 11), state.cursor_column);

    // Move to absolute position
    state.applyCursorMove(.{ .position = .{ .line = 10, .column = 20 } });
    try testing.expectEqual(@as(u16, 10), state.cursor_line);
    try testing.expectEqual(@as(u16, 20), state.cursor_column);
}

test "TerminalState - cursor bounds checking" {
    var state = ansi_state.TerminalState.init(80, 24);

    // Try to move beyond bottom
    state.applyCursorMove(.{ .down = 100 });
    try testing.expectEqual(@as(u16, 24), state.cursor_line); // Clamped to bottom

    // Try to move beyond right
    state.applyCursorMove(.{ .forward = 200 });
    try testing.expectEqual(@as(u16, 80), state.cursor_column); // Clamped to right
}

test "TerminalState - save and restore cursor" {
    var state = ansi_state.TerminalState.init(80, 24);

    // Move and save
    state.applyCursorMove(.{ .position = .{ .line = 10, .column = 20 } });
    state.applyCursorMove(.save);

    // Move elsewhere
    state.applyCursorMove(.{ .position = .{ .line = 5, .column = 5 } });
    try testing.expectEqual(@as(u16, 5), state.cursor_line);

    // Restore
    state.applyCursorMove(.restore);
    try testing.expectEqual(@as(u16, 10), state.cursor_line);
    try testing.expectEqual(@as(u16, 20), state.cursor_column);
}

test "TerminalState - SGR attributes" {
    var state = ansi_state.TerminalState.init(80, 24);

    // Apply bold
    state.applySgrAttribute(.bold);
    try testing.expectEqual(true, state.current_attributes.bold);

    // Apply red foreground
    state.applySgrAttribute(.{ .foreground_color = .{ .ansi = 1 } });
    try testing.expect(state.current_attributes.foreground != null);

    // Reset
    state.applySgrAttribute(.reset);
    try testing.expectEqual(false, state.current_attributes.bold);
    try testing.expectEqual(@as(?ansi_commands.Color, null), state.current_attributes.foreground);
}
