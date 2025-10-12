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
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    // Offset column (8 hex digits)
    try writer.print("{x:0>8}  ", .{offset});

    // Hex byte columns with an extra space between the two groups of eight.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (i < data.len) {
            try writer.print("{x:0>2} ", .{data[i]});
        } else {
            try writer.writeAll("   ");
        }

        if (i == 7) {
            try writer.writeByte(' ');
        }
    }

    try ascii.renderSidebar(data, writer);
    try writer.writeByte('\n');

    return stream.getWritten();
}

test "formatLine produces expected prefix and ASCII sidebar" {
    var buffer: [80]u8 = undefined;
    const line = try formatLine("Hi", 0x10, &buffer);

    try std.testing.expect(std.mem.startsWith(u8, line, "00000010  48 69"));
    try std.testing.expect(std.mem.endsWith(u8, line, "|Hi              |\n"));
}
