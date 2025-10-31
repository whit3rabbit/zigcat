// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Hex dump line formatting helpers.
//!
//! Responsible for assembling the offset column, grouped hexadecimal byte
//! output, and delegating ASCII sidebar rendering to `ascii.zig`.

const std = @import("std");
const ascii = @import("ascii.zig");

/// Format a single hexdump line into the provided scratch buffer.
///
/// The resulting slice contains the fully formatted line including trailing
/// newline. Callers are expected to allocate at least 80 bytes, matching the
/// legacy implementation's stack buffer size.
pub fn formatLine(data: []const u8, offset: u64, buffer: []u8) ![]const u8 {
    var pos: usize = 0;

    // Offset column (8 hex digits)
    const offset_str = try std.fmt.bufPrint(buffer[pos..], "{x:0>8}  ", .{offset});
    pos += offset_str.len;

    // Hex byte columns with an extra space between the two groups of eight.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (i < data.len) {
            const byte_str = try std.fmt.bufPrint(buffer[pos..], "{x:0>2} ", .{data[i]});
            pos += byte_str.len;
        } else {
            @memcpy(buffer[pos..][0..3], "   ");
            pos += 3;
        }

        if (i == 7) {
            buffer[pos] = ' ';
            pos += 1;
        }
    }

    // Render ASCII sidebar inline
    buffer[pos] = ' ';
    pos += 1;
    buffer[pos] = '|';
    pos += 1;

    for (data) |byte| {
        buffer[pos] = ascii.sanitizeByte(byte);
        pos += 1;
    }

    var j: usize = data.len;
    while (j < 16) : (j += 1) {
        buffer[pos] = ' ';
        pos += 1;
    }

    buffer[pos] = '|';
    pos += 1;
    buffer[pos] = '\n';
    pos += 1;

    return buffer[0..pos];
}

test "formatLine produces expected prefix and ASCII sidebar" {
    var buffer: [80]u8 = undefined;
    const line = try formatLine("Hi", 0x10, &buffer);

    try std.testing.expect(std.mem.startsWith(u8, line, "00000010  48 69"));
    try std.testing.expect(std.mem.endsWith(u8, line, "|Hi              |\n"));
}
