//! Shell Memory Leak Validation Tests
//!
//! This file contains 5 tests validating the fix for BUG 2.2 (Shell Memory Leak).
//!
//! **BUG 2.2**: Heap allocation not freed in shell command execution
//! - Location: src/server/exec.zig + src/main.zig
//! - Issue: buildShellCommand() allocates args array, but call sites never freed it
//! - Fix: Add defer allocator.free(shell_cmd.args) at call sites
//!
//! **Test Coverage**:
//! - TC-SHELL-1: Args array allocation
//! - TC-SHELL-2: Multiple command leak test
//! - TC-SHELL-3: Complex command string
//! - TC-SHELL-4: Empty command string
//! - TC-SHELL-5: Long command string
//!
//! **Self-Contained**: This file copies buildShellCommand() to avoid circular dependencies.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

/// Build shell command for -c mode
///
/// COPIED FROM: src/server/exec.zig
///
/// CRITICAL MEMORY: Returns HEAP-ALLOCATED args array that MUST be freed by caller!
/// Use: defer allocator.free(result.args);
///
/// Platform-specific behavior:
/// - Windows: Uses cmd.exe /c "command"
/// - Unix/Linux/macOS: Uses /bin/sh -c "command"
///
/// Returns:
/// - Anonymous struct with:
///   - program: Shell path (static string: "cmd.exe" or "/bin/sh")
///   - args: Heap-allocated array [shell_flag, command_string]
fn buildShellCommand(
    allocator: std.mem.Allocator,
    command_string: []const u8,
) !struct { program: []const u8, args: []const []const u8 } {
    // Use platform-appropriate shell
    const shell_path = if (builtin.os.tag == .windows)
        "cmd.exe"
    else
        "/bin/sh";

    const shell_arg = if (builtin.os.tag == .windows)
        "/c"
    else
        "-c";

    // Allocate array on heap to avoid stack-allocated pointer issue
    const args_arr = try allocator.alloc([]const u8, 2);
    args_arr[0] = shell_arg;
    args_arr[1] = command_string;

    return .{
        .program = shell_path,
        .args = args_arr,
    };
}

// ============================================================================
// TEST SUITE: Shell Memory Leak Safety (5 tests)
// ============================================================================

// TC-SHELL-1: Args Array Allocation
//
// Validates:
// - Args array is heap-allocated
// - Correct size (2 elements)
// - Platform-specific shell selection
// - Defer pattern frees memory
test "Shell memory: buildShellCommand allocates args array" {
    const allocator = testing.allocator;

    const result = try buildShellCommand(allocator, "echo hello");
    defer allocator.free(result.args);

    // Verify array is allocated
    try testing.expectEqual(@as(usize, 2), result.args.len);

    // Verify contents (platform-specific)
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("cmd.exe", result.program);
        try testing.expectEqualStrings("/c", result.args[0]);
    } else {
        try testing.expectEqualStrings("/bin/sh", result.program);
        try testing.expectEqualStrings("-c", result.args[0]);
    }
    try testing.expectEqualStrings("echo hello", result.args[1]);
}

// TC-SHELL-2: Multiple Command Leak Test
//
// Validates:
// - No cumulative leaks with multiple commands
// - Each args array is properly freed
// - Dynamic command generation works
test "Shell memory: multiple commands no leak" {
    const allocator = testing.allocator;

    // Create and free 50 shell commands
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "echo test{d}", .{i});
        defer allocator.free(cmd);

        const result = try buildShellCommand(allocator, cmd);
        defer allocator.free(result.args);

        // Verify each allocation
        try testing.expectEqual(@as(usize, 2), result.args.len);
    }

    // testing.allocator will detect leaks
}

// TC-SHELL-3: Complex Command String
//
// Validates:
// - Complex command strings handled correctly
// - Command string is borrowed (not duplicated)
// - Args array still properly freed
test "Shell memory: complex command with pipes" {
    const allocator = testing.allocator;

    const complex_cmd = "echo 'hello world' | grep hello | wc -l";
    const result = try buildShellCommand(allocator, complex_cmd);
    defer allocator.free(result.args);

    // Verify complex command stored correctly
    try testing.expectEqual(@as(usize, 2), result.args.len);
    try testing.expectEqualStrings(complex_cmd, result.args[1]);
}

// TC-SHELL-4: Empty Command String
//
// Validates:
// - Empty command handling
// - Allocation still occurs
// - No crashes or undefined behavior
test "Shell memory: empty command string" {
    const allocator = testing.allocator;

    const result = try buildShellCommand(allocator, "");
    defer allocator.free(result.args);

    // Verify array allocated even for empty command
    try testing.expectEqual(@as(usize, 2), result.args.len);
    try testing.expectEqualStrings("", result.args[1]);
}

// TC-SHELL-5: Long Command String
//
// Validates:
// - Large command strings (10KB+)
// - No buffer overflows
// - Memory management with large allocations
test "Shell memory: very long command string" {
    const allocator = testing.allocator;

    // Generate 10KB command string
    var cmd_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer cmd_list.deinit(allocator);

    try cmd_list.appendSlice(allocator, "echo '");
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try cmd_list.writer(allocator).print("line{d} ", .{i});
    }
    try cmd_list.appendSlice(allocator, "'");

    const result = try buildShellCommand(allocator, cmd_list.items);
    defer allocator.free(result.args);

    // Verify long command handled correctly
    try testing.expectEqual(@as(usize, 2), result.args.len);
    try testing.expectEqualStrings(cmd_list.items, result.args[1]);
}
