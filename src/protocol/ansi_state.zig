// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! ANSI terminal state management for active rendering mode.
//!
//! This module tracks the current state of the terminal screen including:
//! - Cursor position
//! - Current SGR attributes (colors, bold, italic, etc.)
//! - Screen dimensions
//!
//! Used in active rendering mode to maintain accurate terminal state.

const std = @import("std");
const ansi_commands = @import("ansi_commands.zig");

/// Terminal screen state
pub const TerminalState = struct {
    /// Current cursor position (1-based, like VT100)
    cursor_line: u16 = 1,
    cursor_column: u16 = 1,

    /// Saved cursor position (for save/restore commands)
    saved_cursor_line: u16 = 1,
    saved_cursor_column: u16 = 1,

    /// Screen dimensions (from NAWS or defaults)
    screen_width: u16 = 80,
    screen_height: u16 = 24,

    /// Current SGR attributes
    current_attributes: Attributes = .{},

    /// Initialize with specific screen dimensions
    pub fn init(width: u16, height: u16) TerminalState {
        return .{
            .screen_width = width,
            .screen_height = height,
        };
    }

    /// Apply cursor movement command
    pub fn applyCursorMove(self: *TerminalState, move: ansi_commands.CursorMove) void {
        switch (move) {
            .up => |n| {
                // Move up N lines, stop at top
                if (self.cursor_line > n) {
                    self.cursor_line -= n;
                } else {
                    self.cursor_line = 1;
                }
            },
            .down => |n| {
                // Move down N lines, stop at bottom
                if (self.cursor_line + n <= self.screen_height) {
                    self.cursor_line += n;
                } else {
                    self.cursor_line = self.screen_height;
                }
            },
            .forward => |n| {
                // Move forward N columns, stop at right margin
                if (self.cursor_column + n <= self.screen_width) {
                    self.cursor_column += n;
                } else {
                    self.cursor_column = self.screen_width;
                }
            },
            .backward => |n| {
                // Move backward N columns, stop at left margin
                if (self.cursor_column > n) {
                    self.cursor_column -= n;
                } else {
                    self.cursor_column = 1;
                }
            },
            .position => |pos| {
                // Move to absolute position, clamp to screen bounds
                self.cursor_line = @min(pos.line, self.screen_height);
                self.cursor_column = @min(pos.column, self.screen_width);

                // VT100 uses 1-based indexing, ensure at least 1
                if (self.cursor_line == 0) self.cursor_line = 1;
                if (self.cursor_column == 0) self.cursor_column = 1;
            },
            .save => {
                // Save current cursor position
                self.saved_cursor_line = self.cursor_line;
                self.saved_cursor_column = self.cursor_column;
            },
            .restore => {
                // Restore saved cursor position
                self.cursor_line = self.saved_cursor_line;
                self.cursor_column = self.saved_cursor_column;
            },
        }
    }

    /// Apply SGR attribute
    pub fn applySgrAttribute(self: *TerminalState, attr: ansi_commands.SgrAttribute) void {
        switch (attr) {
            .reset => self.current_attributes = .{},
            .bold => self.current_attributes.bold = true,
            .faint => self.current_attributes.faint = true,
            .italic => self.current_attributes.italic = true,
            .underline => self.current_attributes.underline = true,
            .slow_blink => self.current_attributes.blink = true,
            .rapid_blink => self.current_attributes.blink = true,
            .reverse => self.current_attributes.reverse = true,
            .conceal => self.current_attributes.conceal = true,
            .crossed_out => self.current_attributes.crossed_out = true,
            .normal_intensity => {
                self.current_attributes.bold = false;
                self.current_attributes.faint = false;
            },
            .not_italic => self.current_attributes.italic = false,
            .not_underlined => self.current_attributes.underline = false,
            .not_blinking => self.current_attributes.blink = false,
            .not_reversed => self.current_attributes.reverse = false,
            .not_concealed => self.current_attributes.conceal = false,
            .not_crossed_out => self.current_attributes.crossed_out = false,
            .foreground_color => |color| self.current_attributes.foreground = color,
            .background_color => |color| self.current_attributes.background = color,
            .default_foreground => self.current_attributes.foreground = null,
            .default_background => self.current_attributes.background = null,
        }
    }

    /// Update screen dimensions (e.g., from NAWS)
    pub fn updateDimensions(self: *TerminalState, width: u16, height: u16) void {
        self.screen_width = width;
        self.screen_height = height;

        // Clamp cursor to new bounds
        if (self.cursor_line > height) self.cursor_line = height;
        if (self.cursor_column > width) self.cursor_column = width;
    }

    /// Get current cursor position (0-based for compatibility with line editor)
    pub fn getCursorPosition0Based(self: *const TerminalState) struct { line: u16, column: u16 } {
        return .{
            .line = if (self.cursor_line > 0) self.cursor_line - 1 else 0,
            .column = if (self.cursor_column > 0) self.cursor_column - 1 else 0,
        };
    }
};

/// SGR text attributes
pub const Attributes = struct {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    conceal: bool = false,
    crossed_out: bool = false,
    foreground: ?ansi_commands.Color = null,
    background: ?ansi_commands.Color = null,

    /// Check if any attributes are active (non-default)
    pub fn hasAny(self: *const Attributes) bool {
        return self.bold or self.faint or self.italic or self.underline or
            self.blink or self.reverse or self.conceal or self.crossed_out or
            self.foreground != null or self.background != null;
    }

    /// Generate SGR reset sequence (ESC[0m)
    pub fn generateResetSequence(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "\x1B[0m");
    }

    /// Generate SGR sequence to set these attributes
    pub fn generateSgrSequence(self: *const Attributes, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("\x1B[");

        var first = true;

        if (self.bold) {
            if (!first) try buf.append(';');
            try buf.appendSlice("1");
            first = false;
        }
        if (self.faint) {
            if (!first) try buf.append(';');
            try buf.appendSlice("2");
            first = false;
        }
        if (self.italic) {
            if (!first) try buf.append(';');
            try buf.appendSlice("3");
            first = false;
        }
        if (self.underline) {
            if (!first) try buf.append(';');
            try buf.appendSlice("4");
            first = false;
        }
        if (self.blink) {
            if (!first) try buf.append(';');
            try buf.appendSlice("5");
            first = false;
        }
        if (self.reverse) {
            if (!first) try buf.append(';');
            try buf.appendSlice("7");
            first = false;
        }
        if (self.conceal) {
            if (!first) try buf.append(';');
            try buf.appendSlice("8");
            first = false;
        }
        if (self.crossed_out) {
            if (!first) try buf.append(';');
            try buf.appendSlice("9");
            first = false;
        }

        // Foreground color
        if (self.foreground) |fg| {
            if (!first) try buf.append(';');
            try appendColorCode(&buf, fg, true);
            first = false;
        }

        // Background color
        if (self.background) |bg| {
            if (!first) try buf.append(';');
            try appendColorCode(&buf, bg, false);
            first = false;
        }

        try buf.append('m');

        return try buf.toOwnedSlice();
    }

    fn appendColorCode(buf: *std.ArrayList(u8), color: ansi_commands.Color, foreground: bool) !void {
        const base = if (foreground) @as(u8, 30) else @as(u8, 40);
        const bright_base = if (foreground) @as(u8, 90) else @as(u8, 100);

        switch (color) {
            .ansi => |idx| {
                try std.fmt.format(buf.writer(), "{d}", .{base + idx});
            },
            .ansi_bright => |idx| {
                try std.fmt.format(buf.writer(), "{d}", .{bright_base + idx});
            },
            .palette => |idx| {
                const code = if (foreground) @as(u8, 38) else @as(u8, 48);
                try std.fmt.format(buf.writer(), "{d};5;{d}", .{ code, idx });
            },
            .rgb => |rgb| {
                const code = if (foreground) @as(u8, 38) else @as(u8, 48);
                try std.fmt.format(buf.writer(), "{d};2;{d};{d};{d}", .{ code, rgb.r, rgb.g, rgb.b });
            },
        }
    }
};
