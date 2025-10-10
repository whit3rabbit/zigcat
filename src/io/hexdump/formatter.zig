//! Hex dump formatting logic
//!
//! Provides formatting functions for converting binary data into
//! traditional hexdump format with offset, hex bytes, and ASCII sidebar.

const std = @import("std");

/// Format a single line of hex dump output.
///
/// Internal function that formats up to 16 bytes of data in hex dump format:
/// - 8-digit hex offset
/// - 16 hex bytes (in two groups of 8)
/// - ASCII sidebar with printable characters
///
/// Format: "00000000  48 65 6c 6c 6f 20 57 6f  72 6c 64 21 0a 00 00 00  |Hello World!....|"
///
/// Parameters:
///   - data: Up to 16 bytes of data to format
///   - offset: Byte offset to display for this line
///   - buffer: Fixed-size buffer to write formatted line into
///
/// Returns:
///   Slice of the buffer containing the formatted line
pub fn formatHexLine(data: []const u8, offset: u64, buffer: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    // Write offset (8 hex digits)
    try writer.print("{x:0>8}  ", .{offset});

    // Write hex bytes (16 bytes max, 2 groups of 8)
    var i: usize = 0;
    while (i < 16) {
        if (i < data.len) {
            try writer.print("{x:0>2} ", .{data[i]});
        } else {
            try writer.print("   ", .{});
        }

        // Add extra space after 8th byte
        if (i == 7) {
            try writer.print(" ", .{});
        }
        i += 1;
    }

    // Write ASCII representation
    try writer.print(" |", .{});
    for (data) |byte| {
        const ascii_char = if (std.ascii.isPrint(byte)) byte else '.';
        try writer.print("{c}", .{ascii_char});
    }

    // Pad ASCII section if needed
    i = data.len;
    while (i < 16) {
        try writer.print(" ", .{});
        i += 1;
    }

    try writer.print("|\n", .{});

    return stream.getWritten();
}
