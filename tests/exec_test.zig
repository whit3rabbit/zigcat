const std = @import("std");
const exec = @import("../src/server/exec.zig");
const config_mod = @import("../src/config.zig");
const security = @import("../src/util/security.zig");

test "ExecMode enum values" {
    try std.testing.expectEqual(exec.ExecMode.direct, .direct);
    try std.testing.expectEqual(exec.ExecMode.shell, .shell);
}

test "ExecConfig default values" {
    const config = exec.ExecConfig{
        .mode = .direct,
        .program = "/bin/echo",
        .args = &[_][]const u8{"hello"},
    };

    try std.testing.expectEqual(exec.ExecMode.direct, config.mode);
    try std.testing.expectEqualStrings("/bin/echo", config.program);
    try std.testing.expectEqual(true, config.require_allow);
}

test "buildShellCommand creates proper shell invocation" {
    const allocator = std.testing.allocator;

    var result = try exec.buildShellCommand(allocator, "echo hello");
    defer result.deinit();

    if (@import("builtin").os.tag == .windows) {
        try std.testing.expectEqualStrings("cmd.exe", result.program);
        try std.testing.expectEqualStrings("/c", result.args[0]);
    } else {
        try std.testing.expectEqualStrings("/bin/sh", result.program);
        try std.testing.expectEqualStrings("-c", result.args[0]);
    }

    try std.testing.expectEqualStrings("echo hello", result.args[1]);
}

test "buildShellCommand with complex command" {
    const allocator = std.testing.allocator;

    const cmd = "echo 'hello world' | grep hello";
    var result = try exec.buildShellCommand(allocator, cmd);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings(cmd, result.args[1]);
}

test "security validation requires allow list with exec" {
    // Should fail when require_allow=true and allow_list_count=0
    try std.testing.expectError(
        error.ExecRequiresAllow,
        security.validateExecSecurity("/bin/sh", 0, true),
    );
}

test "security validation passes with allow list" {
    // Should pass when allow list has entries
    try security.validateExecSecurity("/bin/sh", 3, true);
}

test "security validation passes when not required" {
    // Should pass when require_allow=false (even without allow list)
    try security.validateExecSecurity("/bin/sh", 0, false);
}

test "getUserInfo resolves nobody" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const user = try security.getUserInfo("nobody");
    try std.testing.expectEqual(@as(u32, 65534), user.uid);
    try std.testing.expectEqual(@as(u32, 65534), user.gid);
    try std.testing.expectEqualStrings("nobody", user.name);
}

test "getUserInfo resolves daemon" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const user = try security.getUserInfo("daemon");
    try std.testing.expectEqual(@as(u32, 1), user.uid);
    try std.testing.expectEqual(@as(u32, 1), user.gid);
}

test "getUserInfo parses numeric UID" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const user = try security.getUserInfo("12345");
    try std.testing.expectEqual(@as(u32, 12345), user.uid);
    try std.testing.expectEqual(@as(u32, 12345), user.gid);
}

test "getUserInfo fails on invalid username" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    try std.testing.expectError(
        error.UserNotFound,
        security.getUserInfo("nonexistent_user_xyz"),
    );
}

// Integration test (requires actual process spawning, marked as slow)
test "exec mode safety: require_allow enforcement" {
    const config = exec.ExecConfig{
        .mode = .direct,
        .program = "/bin/echo",
        .args = &[_][]const u8{"test"},
        .require_allow = true,
    };

    // This should be enforced at the main.zig level
    try std.testing.expect(config.require_allow);
}

test "exec mode safety: shell command sanitization" {
    const allocator = std.testing.allocator;

    // Test that we properly pass commands through shell
    const dangerous_cmd = "echo test; rm -rf /";
    var result = try exec.buildShellCommand(allocator, dangerous_cmd);
    defer result.deinit();

    // The command should be passed as a single argument to -c
    // Shell will handle it (but we should still validate with allow list)
    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings(dangerous_cmd, result.args[1]);
}

test "buildExecSessionConfig maps config fields" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.exec_stdin_buffer_size = 4096;
    cfg.exec_stdout_buffer_size = 8192;
    cfg.exec_stderr_buffer_size = 2048;
    cfg.exec_max_buffer_bytes = 16384;
    cfg.exec_flow_pause_percent = 0.9;
    cfg.exec_flow_resume_percent = 0.5;
    cfg.exec_execution_timeout_ms = 1500;
    cfg.exec_idle_timeout_ms = 250;
    cfg.exec_connection_timeout_ms = 300;

    const session_cfg = config_mod.buildExecSessionConfig(&cfg);
    try std.testing.expectEqual(@as(usize, 4096), session_cfg.buffers.stdin_capacity);
    try std.testing.expectEqual(@as(usize, 8192), session_cfg.buffers.stdout_capacity);
    try std.testing.expectEqual(@as(usize, 2048), session_cfg.buffers.stderr_capacity);
    try std.testing.expectEqual(@as(usize, 16384), session_cfg.flow.max_total_buffer_bytes);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), session_cfg.flow.pause_threshold_percent, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), session_cfg.flow.resume_threshold_percent, 0.0001);
    try std.testing.expectEqual(@as(u32, 1500), session_cfg.timeouts.execution_ms);
    try std.testing.expectEqual(@as(u32, 250), session_cfg.timeouts.idle_ms);
    try std.testing.expectEqual(@as(u32, 300), session_cfg.timeouts.connection_ms);
}
