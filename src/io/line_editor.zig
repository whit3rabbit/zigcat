const std = @import("std");

const Stream = @import("stream.zig").Stream;

pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    stdout: std.fs.File,
    crlf: bool,
    cursor: usize = 0,
    last_rendered_len: usize = 0,
    escape_state: EscapeState = .none,
    csi_buf: [4]u8 = undefined,
    csi_len: usize = 0,

    const EscapeState = enum {
        none,
        esc,
        csi,
    };

    pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File, crlf: bool) !LineEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .stdout = stdout,
            .crlf = crlf,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit();
    }

    /// Process incoming terminal bytes. Returns true when data was forwarded to the network.
    pub fn processInput(self: *LineEditor, stream: Stream, data: []const u8) !bool {
        var sent = false;
        for (data) |byte| {
            sent = (try self.handleByte(stream, byte)) or sent;
        }
        return sent;
    }

    fn handleByte(self: *LineEditor, stream: Stream, byte: u8) !bool {
        switch (self.escape_state) {
            .none => return self.handleRegularByte(stream, byte),
            .esc => {
                if (byte == '[') {
                    self.escape_state = .csi;
                    self.csi_len = 0;
                } else {
                    self.escape_state = .none;
                    try self.handleRegularByte(stream, byte);
                }
                return false;
            },
            .csi => {
                if (byte >= '0' and byte <= '9') {
                    if (self.csi_len < self.csi_buf.len) {
                        self.csi_buf[self.csi_len] = byte;
                        self.csi_len += 1;
                    }
                    return false;
                }

                self.escape_state = .none;
                switch (byte) {
                    'D' => {
                        if (self.cursor > 0) self.cursor -= 1;
                        try self.redrawLine();
                    },
                    'C' => {
                        if (self.cursor < self.buffer.items.len) self.cursor += 1;
                        try self.redrawLine();
                    },
                    'H' => {
                        self.cursor = 0;
                        try self.redrawLine();
                    },
                    'F' => {
                        self.cursor = self.buffer.items.len;
                        try self.redrawLine();
                    },
                    '~' => try self.handleCsiTilde(),
                    else => {},
                }
                return false;
            },
        }
    }

    fn handleRegularByte(self: *LineEditor, stream: Stream, byte: u8) !bool {
        switch (byte) {
            '\r', '\n' => return try self.commitLine(stream),
            0x08, 0x7F => {
                try self.backspace();
                return false;
            },
            0x15 => {
                try self.killLine();
                return false;
            },
            0x17 => {
                try self.eraseWord();
                return false;
            },
            0x04 => {
                try self.deleteChar();
                return false;
            },
            0x02 => { // Ctrl-B
                if (self.cursor > 0) self.cursor -= 1;
                try self.redrawLine();
                return false;
            },
            0x06 => { // Ctrl-F
                if (self.cursor < self.buffer.items.len) self.cursor += 1;
                try self.redrawLine();
                return false;
            },
            0x01 => { // Ctrl-A
                self.cursor = 0;
                try self.redrawLine();
                return false;
            },
            0x05 => { // Ctrl-E
                self.cursor = self.buffer.items.len;
                try self.redrawLine();
                return false;
            },
            0x1b => {
                self.escape_state = .esc;
                return false;
            },
            else => {
                if (byte >= 0x20 or byte == 0x09) {
                    try self.insertByte(byte);
                    return false;
                }

                if (self.buffer.items.len > 0) {
                    _ = try self.commitLine(stream);
                }
                try stream.write(&[_]u8{byte});
                return true;
            },
        }
    }

    fn insertByte(self: *LineEditor, byte: u8) !void {
        try self.buffer.insertSlice(self.allocator, self.cursor, &[_]u8{byte});
        self.cursor += 1;
        try self.redrawLine();
    }

    fn deleteChar(self: *LineEditor) !void {
        if (self.cursor >= self.buffer.items.len) return;
        _ = self.buffer.orderedRemove(self.cursor);
        try self.redrawLine();
    }

    fn backspace(self: *LineEditor) !void {
        if (self.cursor == 0) return;
        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
        try self.redrawLine();
    }

    fn killLine(self: *LineEditor) !void {
        if (self.cursor == 0) return;
        try self.buffer.replaceRange(self.allocator, 0, self.cursor, &[_]u8{});
        self.cursor = 0;
        try self.redrawLine();
    }

    fn eraseWord(self: *LineEditor) !void {
        if (self.cursor == 0) return;

        var index = self.cursor;
        while (index > 0 and self.buffer.items[index - 1] == ' ') index -= 1;
        while (index > 0 and self.buffer.items[index - 1] != ' ') index -= 1;

        const removed = self.cursor - index;
        try self.buffer.replaceRange(self.allocator, index, removed, &[_]u8{});
        self.cursor = index;
        try self.redrawLine();
    }

    fn commitLine(self: *LineEditor, stream: Stream) !bool {
        if (self.buffer.items.len > 0) {
            try stream.write(self.buffer.items);
        }

        if (self.crlf) {
            try stream.write(&[_]u8{ '\r', '\n' });
            try self.stdout.writeAll("\r\n");
        } else {
            try stream.write(&[_]u8{'\n'});
            try self.stdout.writeAll("\n");
        }

        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.last_rendered_len = 0;
        return true;
    }

    fn redrawLine(self: *LineEditor) !void {
        try self.stdout.writeAll("\r");
        try self.stdout.writeAll(self.buffer.items);

        if (self.last_rendered_len > self.buffer.items.len) {
            var diff = self.last_rendered_len - self.buffer.items.len;
            var spaces: [64]u8 = undefined;
            @memset(spaces[0..], ' ');
            while (diff > 0) {
                const chunk = @min(diff, spaces.len);
                try self.stdout.writeAll(spaces[0..chunk]);
                diff -= chunk;
            }
        }

        self.last_rendered_len = self.buffer.items.len;

        try self.stdout.writeAll("\r");
        if (self.cursor > 0) {
            try self.stdout.writeAll(self.buffer.items[0..self.cursor]);
        }
    }

    fn handleCsiTilde(self: *LineEditor) !void {
        const seq = self.csi_buf[0..self.csi_len];
        if (std.mem.eql(u8, seq, "3")) {
            try self.deleteChar();
        } else if (std.mem.eql(u8, seq, "1") or std.mem.eql(u8, seq, "7")) {
            self.cursor = 0;
            try self.redrawLine();
        } else if (std.mem.eql(u8, seq, "4") or std.mem.eql(u8, seq, "8")) {
            self.cursor = self.buffer.items.len;
            try self.redrawLine();
        }
    }
};
