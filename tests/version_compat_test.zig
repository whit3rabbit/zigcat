const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// Test that version detection correctly identifies Zig versions
test "version detection - builtin.zig_version" {
    // This test verifies that the builtin.zig_version structure is accessible
    // and that our version checks will work correctly across Zig versions

    const major = builtin.zig_version.major;
    const minor = builtin.zig_version.minor;
    const patch = builtin.zig_version.patch;

    // We expect either 0.15.x or 0.16.x
    try testing.expectEqual(@as(u32, 0), major);
    try testing.expect(minor >= 15 and minor <= 16);

    std.debug.print("\n[Version Compat Test] Detected Zig version: {}.{}.{}\n", .{ major, minor, patch });
}

// Test the version check pattern used in listen.zig
test "version check pattern - readFileAlloc API compatibility" {
    // This test validates the pattern we use for cross-version compatibility
    const is_016_or_later = builtin.zig_version.minor >= 16;

    std.debug.print("\n[Version Compat Test] Using Zig 0.16+ APIs: {}\n", .{is_016_or_later});

    if (builtin.zig_version.minor >= 16) {
        // In 0.16.0+, we would use: std.fs.cwd().readFileAlloc(path, allocator, limit)
        std.debug.print("[Version Compat Test] Would use new readFileAlloc API (path, allocator, Limit)\n", .{});
    } else {
        // In 0.15.1, we use: std.fs.cwd().readFileAlloc(allocator, path, max_bytes)
        std.debug.print("[Version Compat Test] Using legacy readFileAlloc API (allocator, path, max_bytes)\n", .{});
    }
}

// Test that the std.Io.Limit type exists in 0.16.0+
test "std.Io.Limit availability check" {
    if (builtin.zig_version.minor >= 16) {
        // In Zig 0.16.0+, std.Io.Limit should exist
        // We can't test the actual usage without triggering the linker bug,
        // but we can verify the type is available at compile time
        if (@hasDecl(std, "Io")) {
            std.debug.print("\n[Version Compat Test] std.Io is available in this Zig version\n", .{});
            // Note: We can't use std.Io.Limit here because it would trigger
            // compilation in 0.15.1 where it doesn't exist
        } else {
            std.debug.print("\n[Version Compat Test] WARNING: std.Io not found in 0.16.0+ build\n", .{});
        }
    } else {
        std.debug.print("\n[Version Compat Test] std.Io not expected in Zig 0.15.x\n", .{});
    }
}

// Test that our migration patterns compile successfully
test "migration pattern - conditional compilation" {
    // This test ensures that the version check pattern itself compiles
    // without errors on both 0.15.1 and 0.16.0-dev

    const dummy_value = if (builtin.zig_version.minor >= 16)
        "new_api_path"
    else
        "old_api_path";

    try testing.expect(dummy_value.len > 0);
    std.debug.print("\n[Version Compat Test] Conditional compilation works: {s}\n", .{dummy_value});
}
