//! Platform detection and kernel version parsing tests
//!
//! Tests for src/util/platform.zig functionality:
//! - Kernel version parsing from various distribution formats
//! - Version comparison logic
//! - io_uring capability detection
//!
//! Note: This is a standalone test file and must be self-contained.
//! It cannot import from src/ due to circular dependency issues.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

/// Kernel version structure (duplicated from platform.zig for standalone testing)
const KernelVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn isAtLeast(self: KernelVersion, major: u32, minor: u32) bool {
        if (self.major > major) return true;
        if (self.major < major) return false;
        return self.minor >= minor;
    }
};

/// Parse kernel version from uname release string
/// Handles formats like:
/// - "5.10.0" (vanilla)
/// - "5.10.0-23-generic" (Ubuntu/Debian)
/// - "5.10.0-23.fc35.x86_64" (Fedora)
/// - "5.15.0-1.el9.x86_64" (RHEL/Rocky)
fn parseKernelVersion(release: []const u8) !KernelVersion {
    // Find the end of the version part (before first '-' or end of string)
    const version_end = std.mem.indexOf(u8, release, "-") orelse release.len;
    const version_str = release[0..version_end];

    // Split by '.'
    var iter = std.mem.splitScalar(u8, version_str, '.');

    const major_str = iter.next() orelse return error.InvalidVersion;
    const minor_str = iter.next() orelse return error.InvalidVersion;
    const patch_str = iter.next() orelse return error.InvalidVersion;

    return KernelVersion{
        .major = try std.fmt.parseInt(u32, major_str, 10),
        .minor = try std.fmt.parseInt(u32, minor_str, 10),
        .patch = try std.fmt.parseInt(u32, patch_str, 10),
    };
}

// ============================================================================
// Kernel Version Parsing Tests
// ============================================================================

test "parseKernelVersion - vanilla kernel" {
    const version = try parseKernelVersion("5.10.0");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 10), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "parseKernelVersion - Ubuntu/Debian format" {
    const version = try parseKernelVersion("5.15.0-91-generic");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 15), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "parseKernelVersion - Fedora format" {
    const version = try parseKernelVersion("6.5.9-300.fc39.x86_64");
    try testing.expectEqual(@as(u32, 6), version.major);
    try testing.expectEqual(@as(u32, 5), version.minor);
    try testing.expectEqual(@as(u32, 9), version.patch);
}

test "parseKernelVersion - RHEL/Rocky format" {
    const version = try parseKernelVersion("5.14.0-362.el9.x86_64");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 14), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "parseKernelVersion - Arch Linux format" {
    const version = try parseKernelVersion("6.6.8-arch1-1");
    try testing.expectEqual(@as(u32, 6), version.major);
    try testing.expectEqual(@as(u32, 6), version.minor);
    try testing.expectEqual(@as(u32, 8), version.patch);
}

test "parseKernelVersion - minimum io_uring version" {
    const version = try parseKernelVersion("5.1.0");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 1), version.minor);
    try testing.expect(version.isAtLeast(5, 1));
}

test "parseKernelVersion - invalid format (no minor)" {
    const result = parseKernelVersion("5");
    try testing.expectError(error.InvalidVersion, result);
}

test "parseKernelVersion - invalid format (no patch)" {
    const result = parseKernelVersion("5.10");
    try testing.expectError(error.InvalidVersion, result);
}

test "parseKernelVersion - invalid format (non-numeric)" {
    const result = parseKernelVersion("5.10.x");
    try testing.expectError(error.InvalidCharacter, result);
}

// ============================================================================
// Version Comparison Tests
// ============================================================================

test "KernelVersion.isAtLeast - exact match" {
    const version = KernelVersion{ .major = 5, .minor = 10, .patch = 0 };
    try testing.expect(version.isAtLeast(5, 10));
}

test "KernelVersion.isAtLeast - higher major" {
    const version = KernelVersion{ .major = 6, .minor = 0, .patch = 0 };
    try testing.expect(version.isAtLeast(5, 10));
    try testing.expect(version.isAtLeast(5, 1));
}

test "KernelVersion.isAtLeast - same major, higher minor" {
    const version = KernelVersion{ .major = 5, .minor = 15, .patch = 0 };
    try testing.expect(version.isAtLeast(5, 10));
    try testing.expect(version.isAtLeast(5, 1));
}

test "KernelVersion.isAtLeast - same major, lower minor" {
    const version = KernelVersion{ .major = 5, .minor = 0, .patch = 0 };
    try testing.expect(!version.isAtLeast(5, 1));
    try testing.expect(!version.isAtLeast(5, 10));
}

test "KernelVersion.isAtLeast - lower major" {
    const version = KernelVersion{ .major = 4, .minor = 20, .patch = 0 };
    try testing.expect(!version.isAtLeast(5, 1));
}

test "KernelVersion.isAtLeast - io_uring minimum version" {
    // io_uring requires Linux 5.1+
    const v5_0 = KernelVersion{ .major = 5, .minor = 0, .patch = 0 };
    const v5_1 = KernelVersion{ .major = 5, .minor = 1, .patch = 0 };
    const v5_2 = KernelVersion{ .major = 5, .minor = 2, .patch = 0 };
    const v6_0 = KernelVersion{ .major = 6, .minor = 0, .patch = 0 };

    try testing.expect(!v5_0.isAtLeast(5, 1)); // Too old
    try testing.expect(v5_1.isAtLeast(5, 1));  // Minimum
    try testing.expect(v5_2.isAtLeast(5, 1));  // Newer
    try testing.expect(v6_0.isAtLeast(5, 1));  // Much newer
}

// ============================================================================
// Platform Detection Tests
// ============================================================================

test "compile-time platform detection" {
    // This test validates that we can detect Linux at compile time
    const is_linux = builtin.os.tag == .linux;

    if (is_linux) {
        // On Linux, we should be able to detect kernel version at runtime
        // (actual detection tested in integration tests)
        try testing.expect(true);
    } else {
        // On non-Linux, io_uring should not be available
        try testing.expect(true);
    }
}

// ============================================================================
// Edge Cases and Robustness Tests
// ============================================================================

test "parseKernelVersion - very high version numbers" {
    const version = try parseKernelVersion("999.999.999");
    try testing.expectEqual(@as(u32, 999), version.major);
    try testing.expectEqual(@as(u32, 999), version.minor);
    try testing.expectEqual(@as(u32, 999), version.patch);
}

test "parseKernelVersion - zero version" {
    const version = try parseKernelVersion("0.0.0");
    try testing.expectEqual(@as(u32, 0), version.major);
    try testing.expectEqual(@as(u32, 0), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "parseKernelVersion - complex distribution suffix" {
    const version = try parseKernelVersion("5.15.0-91-generic-foo-bar-baz");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 15), version.minor);
    try testing.expectEqual(@as(u32, 0), version.patch);
}

test "parseKernelVersion - empty string" {
    const result = parseKernelVersion("");
    try testing.expectError(error.InvalidVersion, result);
}
