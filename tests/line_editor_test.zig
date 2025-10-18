const std = @import("std");
const testing = std.testing;
const line_editor = @import("../src/io/line_editor.zig");
const stream_mod = @import("../src/io/stream.zig");

const TestContext = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .allocator = allocator, .writes = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *TestContext) void {
        self.writes.deinit();
    }
};

fn streamRead(_: *anyopaque, _: []u8) anyerror!usize {
    return 0;
}

fn streamWrite(context: *anyopaque, data: []const u8) anyerror!usize {
    const ctx: *TestContext = @ptrCast(context);
    try ctx.writes.appendSlice(ctx.allocator, data);
    return data.len;
}

fn streamClose(_: *anyopaque) void {}

fn streamHandle(_: *anyopaque) std.posix.socket_t {
    return 0;
}

fn makeStream(ctx: *TestContext) stream_mod.Stream {
    return .{
        .context = ctx,
        .readFn = streamRead,
        .writeFn = streamWrite,
        .closeFn = streamClose,
        .handleFn = streamHandle,
    };
}

fn makePipe() !struct { reader: std.fs.File, writer: std.fs.File } {
    var fds = try std.posix.pipe();
    return .{
        .reader = std.fs.File{ .handle = fds[0] },
        .writer = std.fs.File{ .handle = fds[1] },
    };
}

fn readPipe(reader: std.fs.File) ![]u8 {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    errdefer buffer.deinit();

    var temp: [128]u8 = undefined;
    while (true) {
        const n = reader.read(&temp) catch break;
        if (n == 0) break;
        try buffer.appendSlice(testing.allocator, temp[0..n]);
        if (n < temp.len) break;
    }
    return buffer.toOwnedSlice();
}

fn sendEscSequence(editor: *line_editor.LineEditor, stream: stream_mod.Stream, seq: []const u8) !void {
    var buf: [3]u8 = .{ 0x1b, '[', 0 }; // allocate small temp
    if (seq.len == 1) {
        buf[2] = seq[0];
        _ = try editor.processInput(stream, buf[0..3]);
    } else {
        var temp = std.ArrayList(u8).init(testing.allocator);
        defer temp.deinit();
        try temp.appendSlice(testing.allocator, &[_]u8{ 0x1b, '[' });
        try temp.appendSlice(testing.allocator, seq);
        _ = try editor.processInput(stream, temp.items);
    }
}

fn processBytes(editor: *line_editor.LineEditor, stream: stream_mod.Stream, bytes: []const u8) !void {
    _ = try editor.processInput(stream, bytes);
}

fn expectWrites(ctx: *TestContext, expected: []const u8) !void {
    try testing.expectEqualSlices(u8, expected, ctx.writes.items);
}

fn expectPipeContains(reader: std.fs.File, expected_substring: []const u8) !void {
    const data = try readPipe(reader);
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, expected_substring) != null);
}

fn resetContext(ctx: *TestContext) void {
    ctx.writes.clearRetainingCapacity();
}

test "line editor inserts and commits" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();
    var stream = makeStream(&ctx);

    const pipe_pair = try makePipe();
    defer pipe_pair.reader.close();
    defer pipe_pair.writer.close();

    var editor = try line_editor.LineEditor.init(testing.allocator, pipe_pair.writer, false);
    defer editor.deinit();

    try processBytes(&editor, stream, "abc");
    try sendEscSequence(&editor, stream, "D"); // left arrow
    try processBytes(&editor, stream, "X");
    const sent = try editor.processInput(stream, "\r");
    try testing.expect(sent);

    try expectWrites(&ctx, "abXc\n");
    resetContext(&ctx);
}

test "line editor delete and navigation" {
    var ctx = TestContext.init(testing.allocator);
    defer ctx.deinit();
    var stream = makeStream(&ctx);

    const pipe_pair = try makePipe();
    defer pipe_pair.reader.close();
    defer pipe_pair.writer.close();

    var editor = try line_editor.LineEditor.init(testing.allocator, pipe_pair.writer, false);
    defer editor.deinit();

    try processBytes(&editor, stream, "hello");
    try sendEscSequence(&editor, stream, "D");
    try sendEscSequence(&editor, stream, "D");
    try sendEscSequence(&editor, stream, "3~"); // delete key
    try processBytes(&editor, stream, "!");
    _ = try editor.processInput(stream, "\r");

    try expectWrites(&ctx, "hel!\n");
}
