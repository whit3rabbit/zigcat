//! Line ending codec for converting between LF and CRLF formats.
//!
//! This module provides utilities for converting line endings between Unix-style
//! LF (Line Feed, '\n') and Windows-style CRLF (Carriage Return + Line Feed, '\r\n').
//! These conversions are commonly needed when transferring text data between
//! systems with different line ending conventions.
//!
//! # Functions
//!
//! - `convertLfToCrlf()`: Convert LF to CRLF (allocates new buffer if conversion needed)
//! - `convertCrlfToLf()`: Convert CRLF to LF (in-place modification)
//!
//! # Usage Example
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//! const unix_data = "Hello\nWorld\n";
//!
//! // Convert to Windows format (requires allocation)
//! const windows_data = try convertLfToCrlf(allocator, unix_data);
//! defer if (windows_data.ptr != unix_data.ptr) allocator.free(windows_data);
//! // Result: "Hello\r\nWorld\r\n"
//!
//! // Convert back to Unix format (in-place)
//! var buffer = try allocator.dupe(u8, windows_data);
//! defer allocator.free(buffer);
//! const unix_result = convertCrlfToLf(buffer);
//! // Result: "Hello\nWorld\n"
//! ```
//!
//! # Performance Characteristics
//!
//! - `convertLfToCrlf()`: O(n) time, may allocate new buffer if LF characters present
//! - `convertCrlfToLf()`: O(n) time, modifies buffer in-place (no allocation)
//!
//! # Memory Management
//!
//! `convertLfToCrlf()` returns the original slice if no conversion is needed,
//! otherwise allocates a new buffer. Callers must check if the returned pointer
//! differs from the input pointer before freeing.

const std = @import("std");

/// Convert LF to CRLF in data (allocates new buffer if conversion needed).
///
/// Scans the input data for LF ('\n') characters and converts them to CRLF ('\r\n').
/// If no LF characters are found, returns the original data slice without allocation.
/// Otherwise, allocates a new buffer with the converted data.
///
/// Parameters:
///   - allocator: Memory allocator for the converted buffer
///   - data: Input data to convert
///
/// Returns:
///   - Original data slice if no conversion needed
///   - New allocated buffer with CRLF line endings if conversion performed
///
/// Errors:
///   - OutOfMemory: Failed to allocate buffer for converted data
///
/// Example:
/// ```zig
/// const result = try convertLfToCrlf(allocator, "Hello\n");
/// defer if (result.ptr != data.ptr) allocator.free(result);
/// // result is "Hello\r\n"
/// ```
pub fn convertLfToCrlf(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    // Count LF characters
    var lf_count: usize = 0;
    for (data) |byte| {
        if (byte == '\n') lf_count += 1;
    }

    if (lf_count == 0) {
        // No conversion needed, return original data
        return data;
    }

    // Allocate buffer for converted data
    const new_len = data.len + lf_count;
    const result = try allocator.alloc(u8, new_len);

    var i: usize = 0;
    var j: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            // Insert CR before LF
            result[j] = '\r';
            j += 1;
            result[j] = '\n';
            j += 1;
        } else {
            result[j] = data[i];
            j += 1;
        }
    }

    return result;
}

/// Convert CRLF to LF in data (modifies in place, returns slice).
///
/// Scans the input buffer for CRLF sequences ('\r\n') and converts them to LF ('\n').
/// The conversion is performed in-place without allocation, and returns a slice
/// of the modified buffer with the new length (always <= original length).
///
/// This function is safe to use with mutable slices and does not require deallocation
/// since it operates on the caller's buffer.
///
/// Parameters:
///   - data: Mutable buffer to convert (modified in-place)
///
/// Returns:
///   - Slice of the input buffer with converted data (length may be shorter)
///
/// Example:
/// ```zig
/// var buffer = [_]u8{'H', 'i', '\r', '\n', 'B', 'y', 'e', '\r', '\n'};
/// const result = convertCrlfToLf(&buffer);
/// // result is "Hi\nBye\n" (length 7, original length 9)
/// ```
pub fn convertCrlfToLf(data: []u8) []u8 {
    var i: usize = 0;
    var j: usize = 0;

    while (i < data.len) {
        if (i + 1 < data.len and data[i] == '\r' and data[i + 1] == '\n') {
            // Skip CR, keep only LF
            data[j] = '\n';
            i += 2;
            j += 1;
        } else {
            data[j] = data[i];
            i += 1;
            j += 1;
        }
    }

    return data[0..j];
}

test "convertLfToCrlf no conversion" {
    const allocator = std.testing.allocator;
    const input = "hello world";
    const result = try convertLfToCrlf(allocator, input);
    defer if (result.ptr != input.ptr) allocator.free(result);

    try std.testing.expectEqualStrings(input, result);
}

test "convertLfToCrlf with newlines" {
    const allocator = std.testing.allocator;
    const input = "hello\nworld\n";
    const result = try convertLfToCrlf(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello\r\nworld\r\n", result);
}

test "convertCrlfToLf" {
    var input = [_]u8{ 'h', 'e', 'l', 'l', 'o', '\r', '\n', 'w', 'o', 'r', 'l', 'd', '\r', '\n' };
    const result = convertCrlfToLf(&input);

    try std.testing.expectEqualStrings("hello\nworld\n", result);
}
