// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! ASCII translation helpers for hexdump output.
//!
//! Provides reusable utilities for converting raw bytes into their printable
//! ASCII representation and rendering the sidebar column used by the hex
//! dumper output format.

const std = @import("std");

/// Translate a byte into a printable ASCII glyph used in the hexdump sidebar.
///
/// Printable bytes are forwarded unchanged. Control characters and other
/// non-printable values are replaced with '.'. This keeps the sidebar readable
/// while still hinting at the byte count.
pub fn sanitizeByte(byte: u8) u8 {
    return if (std.ascii.isPrint(byte)) byte else '.';
}

/// Render the ASCII sidebar for up to 16 bytes into the provided writer.
///
/// The sidebar is rendered in the familiar `|....|` style and padded with
/// spaces when fewer than 16 bytes are present.
pub fn renderSidebar(data: []const u8, writer: anytype) !void {
    try writer.writeByte(' ');
    try writer.writeByte('|');

    for (data) |byte| {
        try writer.writeByte(sanitizeByte(byte));
    }

    var i: usize = data.len;
    while (i < 16) : (i += 1) {
        try writer.writeByte(' ');
    }

    try writer.writeByte('|');
}

test "sanitizeByte replaces non-printable characters" {
    try std.testing.expectEqual(@as(u8, 'A'), sanitizeByte('A'));
    try std.testing.expectEqual(@as(u8, '.'), sanitizeByte(0x03));
}

test "renderSidebar pads to 16 columns" {
    var buffer: [20]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try renderSidebar("Hi", stream.writer());
    const written = stream.getWritten();
    try std.testing.expectEqualStrings(" |Hi              |", written);
}
