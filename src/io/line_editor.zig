// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Local line editor for Telnet client mode.
//!
//! Provides client-side line editing with support for:
//! - Basic editing: backspace, delete, kill line, erase word
//! - Cursor movement: arrow keys, Home/End, Ctrl+A/E, Ctrl+B/F
//! - Word-wise navigation: Ctrl+Left/Right (via CSI modifiers)
//! - Visual feedback: local echo, cursor positioning
//! - CRLF/LF handling based on server requirements
//!
//! The editor handles basic ANSI escape sequences for cursor movement
//! and can coordinate with the full ANSI parser (ansi_parser.zig) when
//! enabled via --telnet-ansi-mode.
//!
//! ## Integration with ANSI Parser
//!
//! When ANSI parsing is enabled, the line editor coordinates cursor
//! position with the parser's terminal state. This ensures that ANSI
//! cursor movement commands (CUU, CUD, CUF, CUB, CUP) update the editor's
//! cursor correctly during local editing mode.
//!
//! ## Usage
//!
//! ```zig
//! var editor = try LineEditor.init(allocator, stdout, true); // CRLF mode
//! defer editor.deinit();
//!
//! // Process user input
//! const sent = try editor.processInput(stream, user_input);
//! if (sent) {
//!     // Data was transmitted to server
//! }
//! ```

const std = @import("std");

const Stream = @import("stream.zig").Stream;

/// Local line editor for Telnet client mode
pub const LineEditor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    stdout: std.fs.File,
    crlf: bool,
    cursor: usize = 0,
    last_rendered_len: usize = 0,
    escape_state: EscapeState = .none,
    csi_buf: [12]u8 = undefined,
    csi_len: usize = 0,

    const EscapeState = enum {
        none,
        esc,
        csi,
    };

    pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File, crlf: bool) !LineEditor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8){},
            .stdout = stdout,
            .crlf = crlf,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buffer.deinit(self.allocator);
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
            .esc => return self.handleEscSequence(stream, byte),
            .csi => {
                if ((byte >= '0' and byte <= '9') or byte == ';') {
                    if (self.csi_len < self.csi_buf.len) {
                        self.csi_buf[self.csi_len] = byte;
                        self.csi_len += 1;
                    }
                    return false;
                }

                self.escape_state = .none;
                switch (byte) {
                    'D' => {
                        if (self.csiHasWordModifier()) {
                            try self.moveCursorWordLeft();
                        } else if (self.cursor > 0) {
                            self.cursor -= 1;
                            try self.redrawLine();
                        }
                    },
                    'C' => {
                        if (self.csiHasWordModifier()) {
                            try self.moveCursorWordRight();
                        } else if (self.cursor < self.buffer.items.len) {
                            self.cursor += 1;
                            try self.redrawLine();
                        }
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

    fn handleEscSequence(self: *LineEditor, stream: Stream, byte: u8) !bool {
        switch (byte) {
            '[' => {
                self.escape_state = .csi;
                self.csi_len = 0;
                return false;
            },
            'b', 'B' => {
                self.escape_state = .none;
                try self.moveCursorWordLeft();
                return false;
            },
            'f', 'F' => {
                self.escape_state = .none;
                try self.moveCursorWordRight();
                return false;
            },
            'd', 'D' => {
                self.escape_state = .none;
                try self.eraseWordRight();
                return false;
            },
            0x7F, 0x08 => {
                self.escape_state = .none;
                try self.eraseWord();
                return false;
            },
            else => {
                self.escape_state = .none;
                return try self.handleRegularByte(stream, byte);
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
                if (self.cursor == self.buffer.items.len) {
                    // Treat Ctrl+D at end-of-line as EOF (flush pending data).
                    return try self.flushPending(stream);
                }

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
                _ = try stream.write(&[_]u8{byte});
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

        const target = self.scanWordLeft(self.cursor);
        if (target == self.cursor) return;

        const removed = self.cursor - target;
        try self.buffer.replaceRange(self.allocator, target, removed, &[_]u8{});
        self.cursor = target;
        try self.redrawLine();
    }

    fn eraseWordRight(self: *LineEditor) !void {
        if (self.cursor >= self.buffer.items.len) return;

        const target = self.scanWordRight(self.cursor);
        if (target == self.cursor) return;

        const removed = target - self.cursor;
        try self.buffer.replaceRange(self.allocator, self.cursor, removed, &[_]u8{});
        try self.redrawLine();
    }

    fn commitLine(self: *LineEditor, stream: Stream) !bool {
        self.escape_state = .none;

        if (self.buffer.items.len > 0) {
            _ = try stream.write(self.buffer.items);
        }

        if (self.crlf) {
            _ = try stream.write(&[_]u8{ '\r', '\n' });
            try self.stdout.writeAll("\r\n");
        } else {
            _ = try stream.write(&[_]u8{'\n'});
            try self.stdout.writeAll("\n");
        }

        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.last_rendered_len = 0;
        return true;
    }

    pub fn flushPending(self: *LineEditor, stream: Stream) !bool {
        if (self.buffer.items.len == 0) return false;
        return try self.commitLine(stream);
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
        const params = self.csiParseParams();
        const first = params.first orelse return;

        switch (first) {
            3 => {
                if (self.csiHasWordModifier()) {
                    try self.eraseWordRight();
                } else {
                    try self.deleteChar();
                }
            },
            1, 7 => {
                self.cursor = 0;
                try self.redrawLine();
            },
            4, 8 => {
                self.cursor = self.buffer.items.len;
                try self.redrawLine();
            },
            else => {},
        }
    }

    fn moveCursorWordLeft(self: *LineEditor) !void {
        if (self.cursor == 0) return;
        self.cursor = self.scanWordLeft(self.cursor);
        try self.redrawLine();
    }

    fn moveCursorWordRight(self: *LineEditor) !void {
        if (self.cursor >= self.buffer.items.len) {
            self.cursor = self.buffer.items.len;
            return;
        }
        self.cursor = self.scanWordRight(self.cursor);
        try self.redrawLine();
    }

    fn scanWordLeft(self: *const LineEditor, start: usize) usize {
        var index = start;
        while (index > 0 and std.ascii.isWhitespace(self.buffer.items[index - 1])) {
            index -= 1;
        }
        while (index > 0 and !std.ascii.isWhitespace(self.buffer.items[index - 1])) {
            index -= 1;
        }
        return index;
    }

    fn scanWordRight(self: *const LineEditor, start: usize) usize {
        var index = start;
        while (index < self.buffer.items.len and std.ascii.isWhitespace(self.buffer.items[index])) {
            index += 1;
        }
        while (index < self.buffer.items.len and !std.ascii.isWhitespace(self.buffer.items[index])) {
            index += 1;
        }
        return index;
    }

    fn csiParseParams(self: *const LineEditor) struct { first: ?u8, last: ?u8 } {
        const seq = self.csi_buf[0..self.csi_len];
        var it = std.mem.splitScalar(u8, seq, ';');
        var first_value: ?u8 = null;
        var last_value: ?u8 = null;

        while (it.next()) |token| {
            if (token.len == 0) continue;
            const value = std.fmt.parseUnsigned(u8, token, 10) catch continue;
            if (first_value == null) first_value = value;
            last_value = value;
        }

        return .{ .first = first_value, .last = last_value };
    }

    fn csiHasWordModifier(self: *const LineEditor) bool {
        const params = self.csiParseParams();
        const last = params.last orelse return false;

        return switch (last) {
            3, 4, 5, 6, 7, 8 => true,
            else => false,
        };
    }
};
