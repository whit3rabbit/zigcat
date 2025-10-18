// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! ANSI command dispatchers for CSI and escape sequences.
//!
//! This module provides handlers for:
//! - SGR (Select Graphic Rendition) - colors and text attributes
//! - Cursor movement commands (CUU, CUD, CUF, CUB, CUP)
//! - Erase functions (ED, EL)
//! - Mouse tracking sequences (SGR 1006 mode)
//! - OSC (Operating System Command) sequences
//!
//! Each handler receives parsed parameters and performs the appropriate action.

const std = @import("std");

/// SGR (Select Graphic Rendition) attributes
pub const SgrAttribute = union(enum) {
    reset,
    bold,
    faint,
    italic,
    underline,
    slow_blink,
    rapid_blink,
    reverse,
    conceal,
    crossed_out,
    normal_intensity,
    not_italic,
    not_underlined,
    not_blinking,
    not_reversed,
    not_concealed,
    not_crossed_out,
    foreground_color: Color,
    background_color: Color,
    default_foreground,
    default_background,
};

/// Color representation supporting 8-color, 256-color, and true-color
pub const Color = union(enum) {
    /// Standard 8 colors (0-7: black, red, green, yellow, blue, magenta, cyan, white)
    ansi: u8,
    /// Bright/high-intensity colors (0-7 corresponding to 90-97, 100-107)
    ansi_bright: u8,
    /// 256-color palette (0-255)
    palette: u8,
    /// True-color RGB (24-bit)
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Parse SGR (Select Graphic Rendition) parameters
///
/// Returns a list of attributes parsed from the parameter array.
/// Each semicolon-separated value is a distinct SGR code.
///
/// Examples:
/// - `ESC[0m` → reset
/// - `ESC[31m` → red foreground
/// - `ESC[1;32m` → bold + green foreground
/// - `ESC[38;5;208m` → 256-color orange foreground
/// - `ESC[38;2;255;100;0m` → true-color orange foreground
pub fn parseSgr(allocator: std.mem.Allocator, params: []const u16) ![]SgrAttribute {
    var attrs = std.ArrayList(SgrAttribute).init(allocator);
    defer attrs.deinit();

    // If no parameters, default to reset
    if (params.len == 0) {
        try attrs.append(.reset);
        return try attrs.toOwnedSlice();
    }

    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const code = params[i];

        switch (code) {
            0 => try attrs.append(.reset),
            1 => try attrs.append(.bold),
            2 => try attrs.append(.faint),
            3 => try attrs.append(.italic),
            4 => try attrs.append(.underline),
            5 => try attrs.append(.slow_blink),
            6 => try attrs.append(.rapid_blink),
            7 => try attrs.append(.reverse),
            8 => try attrs.append(.conceal),
            9 => try attrs.append(.crossed_out),
            22 => try attrs.append(.normal_intensity),
            23 => try attrs.append(.not_italic),
            24 => try attrs.append(.not_underlined),
            25 => try attrs.append(.not_blinking),
            27 => try attrs.append(.not_reversed),
            28 => try attrs.append(.not_concealed),
            29 => try attrs.append(.not_crossed_out),

            // Standard foreground colors (30-37)
            30 => try attrs.append(.{ .foreground_color = .{ .ansi = 0 } }), // Black
            31 => try attrs.append(.{ .foreground_color = .{ .ansi = 1 } }), // Red
            32 => try attrs.append(.{ .foreground_color = .{ .ansi = 2 } }), // Green
            33 => try attrs.append(.{ .foreground_color = .{ .ansi = 3 } }), // Yellow
            34 => try attrs.append(.{ .foreground_color = .{ .ansi = 4 } }), // Blue
            35 => try attrs.append(.{ .foreground_color = .{ .ansi = 5 } }), // Magenta
            36 => try attrs.append(.{ .foreground_color = .{ .ansi = 6 } }), // Cyan
            37 => try attrs.append(.{ .foreground_color = .{ .ansi = 7 } }), // White

            // 256-color or true-color foreground (38)
            38 => {
                if (i + 1 < params.len) {
                    const subcode = params[i + 1];
                    if (subcode == 5 and i + 2 < params.len) {
                        // 256-color: ESC[38;5;<n>m
                        const color_idx = params[i + 2];
                        try attrs.append(.{ .foreground_color = .{ .palette = @intCast(color_idx) } });
                        i += 2;
                    } else if (subcode == 2 and i + 4 < params.len) {
                        // True-color: ESC[38;2;<r>;<g>;<b>m
                        const r = params[i + 2];
                        const g = params[i + 3];
                        const b = params[i + 4];
                        try attrs.append(.{ .foreground_color = .{ .rgb = .{
                            .r = @intCast(@min(r, 255)),
                            .g = @intCast(@min(g, 255)),
                            .b = @intCast(@min(b, 255)),
                        } } });
                        i += 4;
                    }
                }
            },

            39 => try attrs.append(.default_foreground),

            // Standard background colors (40-47)
            40 => try attrs.append(.{ .background_color = .{ .ansi = 0 } }), // Black
            41 => try attrs.append(.{ .background_color = .{ .ansi = 1 } }), // Red
            42 => try attrs.append(.{ .background_color = .{ .ansi = 2 } }), // Green
            43 => try attrs.append(.{ .background_color = .{ .ansi = 3 } }), // Yellow
            44 => try attrs.append(.{ .background_color = .{ .ansi = 4 } }), // Blue
            45 => try attrs.append(.{ .background_color = .{ .ansi = 5 } }), // Magenta
            46 => try attrs.append(.{ .background_color = .{ .ansi = 6 } }), // Cyan
            47 => try attrs.append(.{ .background_color = .{ .ansi = 7 } }), // White

            // 256-color or true-color background (48)
            48 => {
                if (i + 1 < params.len) {
                    const subcode = params[i + 1];
                    if (subcode == 5 and i + 2 < params.len) {
                        // 256-color: ESC[48;5;<n>m
                        const color_idx = params[i + 2];
                        try attrs.append(.{ .background_color = .{ .palette = @intCast(color_idx) } });
                        i += 2;
                    } else if (subcode == 2 and i + 4 < params.len) {
                        // True-color: ESC[48;2;<r>;<g>;<b>m
                        const r = params[i + 2];
                        const g = params[i + 3];
                        const b = params[i + 4];
                        try attrs.append(.{ .background_color = .{ .rgb = .{
                            .r = @intCast(@min(r, 255)),
                            .g = @intCast(@min(g, 255)),
                            .b = @intCast(@min(b, 255)),
                        } } });
                        i += 4;
                    }
                }
            },

            49 => try attrs.append(.default_background),

            // Bright foreground colors (90-97)
            90 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 0 } }),
            91 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 1 } }),
            92 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 2 } }),
            93 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 3 } }),
            94 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 4 } }),
            95 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 5 } }),
            96 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 6 } }),
            97 => try attrs.append(.{ .foreground_color = .{ .ansi_bright = 7 } }),

            // Bright background colors (100-107)
            100 => try attrs.append(.{ .background_color = .{ .ansi_bright = 0 } }),
            101 => try attrs.append(.{ .background_color = .{ .ansi_bright = 1 } }),
            102 => try attrs.append(.{ .background_color = .{ .ansi_bright = 2 } }),
            103 => try attrs.append(.{ .background_color = .{ .ansi_bright = 3 } }),
            104 => try attrs.append(.{ .background_color = .{ .ansi_bright = 4 } }),
            105 => try attrs.append(.{ .background_color = .{ .ansi_bright = 5 } }),
            106 => try attrs.append(.{ .background_color = .{ .ansi_bright = 6 } }),
            107 => try attrs.append(.{ .background_color = .{ .ansi_bright = 7 } }),

            else => {
                // Unknown SGR code - ignore
            },
        }
    }

    return try attrs.toOwnedSlice();
}

/// Cursor movement command
pub const CursorMove = union(enum) {
    /// Move cursor up N lines (CUU - ESC[<n>A)
    up: u16,
    /// Move cursor down N lines (CUD - ESC[<n>B)
    down: u16,
    /// Move cursor forward (right) N columns (CUF - ESC[<n>C)
    forward: u16,
    /// Move cursor backward (left) N columns (CUB - ESC[<n>D)
    backward: u16,
    /// Move cursor to line N, column M (CUP - ESC[<line>;<col>H or f)
    position: struct { line: u16, column: u16 },
    /// Save cursor position (DECSC - ESC[s or ESC 7)
    save,
    /// Restore cursor position (DECRC - ESC[u or ESC 8)
    restore,
};

/// Parse cursor movement command from CSI sequence
pub fn parseCursorMove(params: []const u16, final: u8) ?CursorMove {
    // Get first parameter (default to 1 if not specified or 0)
    const param1 = if (params.len > 0 and params[0] > 0) params[0] else 1;

    return switch (final) {
        'A' => .{ .up = param1 },
        'B' => .{ .down = param1 },
        'C' => .{ .forward = param1 },
        'D' => .{ .backward = param1 },
        'H', 'f' => { // CUP or HVP
            const line = if (params.len > 0 and params[0] > 0) params[0] else 1;
            const column = if (params.len > 1 and params[1] > 0) params[1] else 1;
            return .{ .position = .{ .line = line, .column = column } };
        },
        's' => .save,
        'u' => .restore,
        else => null,
    };
}

/// Erase command
pub const EraseCommand = union(enum) {
    /// Erase in display (ED - ESC[<n>J)
    display: EraseMode,
    /// Erase in line (EL - ESC[<n>K)
    line: EraseMode,
};

/// Erase mode for ED/EL commands
pub const EraseMode = enum {
    /// From cursor to end (0 or omitted)
    cursor_to_end,
    /// From beginning to cursor (1)
    beginning_to_cursor,
    /// Entire display/line (2)
    entire,
    /// Entire display including scrollback (3, ED only)
    entire_with_scrollback,
};

/// Parse erase command from CSI sequence
pub fn parseErase(params: []const u16, final: u8) ?EraseCommand {
    // Get first parameter (default to 0 if not specified)
    const param = if (params.len > 0) params[0] else 0;

    const mode: EraseMode = switch (param) {
        0 => .cursor_to_end,
        1 => .beginning_to_cursor,
        2 => .entire,
        3 => if (final == 'J') .entire_with_scrollback else .entire,
        else => return null,
    };

    return switch (final) {
        'J' => .{ .display = mode },
        'K' => .{ .line = mode },
        else => null,
    };
}

/// Mouse event from SGR 1006 encoding
pub const MouseEvent = struct {
    /// Button code (Cb parameter)
    button: u8,
    /// X coordinate (Cx parameter, 1-based)
    x: u16,
    /// Y coordinate (Cy parameter, 1-based)
    y: u16,
    /// Button press (true) or release (false)
    press: bool,
};

/// Parse SGR 1006 mouse tracking sequence
///
/// Format: ESC[<Cb;Cx;CyM (press) or ESC[<Cb;Cx;Cym (release)
/// Private marker: '<' (0x3C)
pub fn parseMouseSgr(params: []const u16, private_marker: u8, final: u8) ?MouseEvent {
    // Must have '<' private marker and M or m final
    if (private_marker != '<' or (final != 'M' and final != 'm')) {
        return null;
    }

    // Need at least 3 parameters: button, x, y
    if (params.len < 3) {
        return null;
    }

    return MouseEvent{
        .button = @intCast(@min(params[0], 255)),
        .x = params[1],
        .y = params[2],
        .press = final == 'M',
    };
}

/// OSC (Operating System Command) command
pub const OscCommand = union(enum) {
    /// Set window title and icon name (OSC 0)
    set_title_and_icon: []const u8,
    /// Set icon name only (OSC 1)
    set_icon_name: []const u8,
    /// Set window title only (OSC 2)
    set_title: []const u8,
    /// Change color palette entry (OSC 4)
    set_palette_color: struct {
        index: u8,
        spec: []const u8,
    },
    /// Query color palette entry (OSC 4 with ?)
    query_palette_color: u8,
    /// Change foreground color (OSC 10)
    set_foreground_color: []const u8,
    /// Query foreground color (OSC 10 with ?)
    query_foreground_color,
    /// Change background color (OSC 11)
    set_background_color: []const u8,
    /// Query background color (OSC 11 with ?)
    query_background_color,
    /// Unknown/unsupported OSC command
    unknown: []const u8,
};

/// Parse OSC (Operating System Command) string
///
/// Format: ESC]<Ps>;<Pt>BEL or ESC]<Ps>;<Pt>ST
/// The data contains everything after ESC] and before terminator
pub fn parseOsc(allocator: std.mem.Allocator, data: []const u8) !OscCommand {
    // Find the semicolon separator
    const semicolon_pos = std.mem.indexOfScalar(u8, data, ';') orelse {
        // No semicolon - treat as unknown
        const owned = try allocator.dupe(u8, data);
        return .{ .unknown = owned };
    };

    // Parse Ps (command number)
    const ps_str = data[0..semicolon_pos];
    const ps = std.fmt.parseInt(u8, ps_str, 10) catch {
        const owned = try allocator.dupe(u8, data);
        return .{ .unknown = owned };
    };

    // Pt is everything after the semicolon
    const pt = data[semicolon_pos + 1 ..];

    switch (ps) {
        0 => {
            const owned = try allocator.dupe(u8, pt);
            return .{ .set_title_and_icon = owned };
        },
        1 => {
            const owned = try allocator.dupe(u8, pt);
            return .{ .set_icon_name = owned };
        },
        2 => {
            const owned = try allocator.dupe(u8, pt);
            return .{ .set_title = owned };
        },
        4 => {
            // OSC 4 can have multiple formats:
            // - OSC 4;<index>;?BEL (query)
            // - OSC 4;<index>;<color_spec>BEL (set)
            const second_semi = std.mem.indexOfScalar(u8, pt, ';');
            if (second_semi) |pos| {
                const index_str = pt[0..pos];
                const index = std.fmt.parseInt(u8, index_str, 10) catch {
                    const owned = try allocator.dupe(u8, data);
                    return .{ .unknown = owned };
                };

                const spec_or_query = pt[pos + 1 ..];
                if (std.mem.eql(u8, spec_or_query, "?")) {
                    return .{ .query_palette_color = index };
                } else {
                    const owned = try allocator.dupe(u8, spec_or_query);
                    return .{ .set_palette_color = .{ .index = index, .spec = owned } };
                }
            } else {
                const owned = try allocator.dupe(u8, data);
                return .{ .unknown = owned };
            }
        },
        10 => {
            if (std.mem.eql(u8, pt, "?")) {
                return .query_foreground_color;
            } else {
                const owned = try allocator.dupe(u8, pt);
                return .{ .set_foreground_color = owned };
            }
        },
        11 => {
            if (std.mem.eql(u8, pt, "?")) {
                return .query_background_color;
            } else {
                const owned = try allocator.dupe(u8, pt);
                return .{ .set_background_color = owned };
            }
        },
        else => {
            const owned = try allocator.dupe(u8, data);
            return .{ .unknown = owned };
        },
    }
}

/// Free memory allocated by parseOsc
pub fn freeOscCommand(allocator: std.mem.Allocator, cmd: OscCommand) void {
    switch (cmd) {
        .set_title_and_icon,
        .set_icon_name,
        .set_title,
        .set_foreground_color,
        .set_background_color,
        .unknown,
        => |str| allocator.free(str),
        .set_palette_color => |pc| allocator.free(pc.spec),
        .query_palette_color,
        .query_foreground_color,
        .query_background_color,
        => {},
    }
}
