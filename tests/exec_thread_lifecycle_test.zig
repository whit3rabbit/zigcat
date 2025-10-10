//! Exec Mode Thread Lifecycle Tests
//!
//! Tests thread management and cleanup in exec mode to isolate and validate
//! fix for panic when joining threads after child.wait()
//!
//! Test Categories:
//! - T1: Minimal panic reproduction
//! - T2: Thread lifecycle validation
//! - T3: Process cleanup sequence
//! - T4: Edge cases
//! - T5: Thread detachment scenarios

const std = @import("std");
const testing = std.testing;
const exec = @import("zigcat").exec;
const posix = std.posix;
const net = std.net;
const atomic = std.atomic;

pub const std_options = struct {
    pub const log_level = .err;
};

fn findProgram(candidates: []const []const u8) []const u8 {
    for (candidates) |candidate| {
        if (std.fs.accessAbsolute(candidate, .{})) |_| {
            return candidate;
        } else |err| switch (err) {
            error.AccessDenied, error.FileNotFound => continue,
            else => continue,
        }
    }
    std.debug.panic("Unable to locate program from candidates", .{});
}

fn trueProgram() []const u8 {
    return findProgram(&.{ "/bin/true", "/usr/bin/true" });
}

fn echoProgram() []const u8 {
    return findProgram(&.{ "/bin/echo", "/usr/bin/echo" });
}

fn catProgram() []const u8 {
    return findProgram(&.{ "/bin/cat", "/usr/bin/cat" });
}

fn sleepProgram() []const u8 {
    return findProgram(&.{ "/bin/sleep", "/usr/bin/sleep" });
}

/// Helper: Create a socket pair for testing
fn createMockSocketPair() ![2]posix.socket_t {
    var sv: [2]posix.socket_t = undefined;

    const domain = @as(c_uint, @intCast(posix.AF.UNIX));
    const sock_type = @as(c_uint, @intCast(posix.SOCK.STREAM));
    const rc = std.c.socketpair(domain, sock_type, 0, &sv);

    return switch (posix.errno(rc)) {
        .SUCCESS => sv,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// Helper: Execute with timeout protection
fn executeWithTimeout(
    allocator: std.mem.Allocator,
    socket: net.Stream,
    config: exec.ExecConfig,
    client_addr: net.Address,
    timeout_ms: u32,
) !void {
    var completed = atomic.Value(bool).init(false);

    const timeout_thread = try std.Thread.spawn(.{}, struct {
        fn timeoutFunc(done: *atomic.Value(bool), ms: u32) void {
            var timer = std.time.Timer.start() catch unreachable;
            const timeout_ns = @as(u64, ms) * std.time.ns_per_ms;
            while (true) {
                if (done.load(.acquire)) return;
                const elapsed = timer.read();
                if (elapsed >= timeout_ns) break;
                const remaining = timeout_ns - elapsed;
                const sleep_ns = if (remaining < std.time.ns_per_ms) remaining else std.time.ns_per_ms;
                std.Thread.sleep(sleep_ns);
            }
            if (!done.load(.acquire)) {
                std.debug.panic("executeWithTimeout exceeded {d}ms", .{ms});
            }
        }
    }.timeoutFunc, .{ &completed, timeout_ms });
    defer timeout_thread.join();

    // Execute in separate thread to enable timeout
    const exec_thread = try std.Thread.spawn(.{}, struct {
        fn execFunc(
            alloc: std.mem.Allocator,
            sock: net.Stream,
            cfg: exec.ExecConfig,
            addr: net.Address,
        ) void {
            exec.executeWithConnection(alloc, sock, cfg, addr) catch {};
        }
    }.execFunc, .{ allocator, socket, config, client_addr });

    exec_thread.join();
    completed.store(true, .release);
}

// ============================================================================
// T1: Minimal Panic Reproduction Tests
// ============================================================================

test "T1.1: exec panic - immediate exit command (/bin/true)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create socket pair
    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = trueProgram(),
        .args = &[_][]const u8{},
        .require_allow = false,
    };

    // This test EXPECTS to panic (before fix) or succeed (after fix)
    // Use timeout to prevent infinite hang
    try executeWithTimeout(allocator, socket, config, client_addr, 5000);

    // After fix: should succeed
    // Before fix: may panic (test framework should catch it)
}

test "T1.2: exec panic - echo command with immediate input" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Create socket pair
    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    var write_closed = false;
    defer if (!write_closed) posix.close(sv[1]);

    // Write test data to socket (simulate client input)
    const test_data = "test\n";
    const write_result = try posix.write(sv[1], test_data);
    try testing.expect(write_result == test_data.len);
    posix.close(sv[1]); // Close write end to signal EOF
    write_closed = true;
    write_closed = true;

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = echoProgram(),
        .args = &[_][]const u8{"hello"},
        .require_allow = false,
    };

    // Execute with timeout
    try executeWithTimeout(allocator, socket, config, client_addr, 5000);
}

// ============================================================================
// T2: Thread Lifecycle Validation Tests
// ============================================================================

test "T2.1: thread lifecycle - verify clean exit on short command" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = echoProgram(),
        .args = &[_][]const u8{"test"},
        .require_allow = false,
    };

    // This should complete without panic
    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

test "T2.2: thread lifecycle - pipe closure detection" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    var write_closed = false;
    defer if (!write_closed) posix.close(sv[1]);

    // Close write end immediately to test pipe closure handling
    posix.close(sv[1]);
    write_closed = true;

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = echoProgram(),
        .args = &[_][]const u8{"test"},
        .require_allow = false,
    };

    // Should handle closed pipe gracefully
    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

// ============================================================================
// T3: Process Cleanup Sequence Tests
// ============================================================================

test "T3.1: cleanup sequence - verify no resource leaks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Run multiple iterations to detect leaks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const sv = try createMockSocketPair();
        defer posix.close(sv[0]);
        defer posix.close(sv[1]);

        const socket = net.Stream{ .handle = sv[0] };
        const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

        const config = exec.ExecConfig{
            .mode = .direct,
            .program = trueProgram(),
            .args = &[_][]const u8{},
            .require_allow = false,
        };

        try exec.executeWithConnection(allocator, socket, config, client_addr);
    }

    // If we get here without panic or leak, test passes
}

// ============================================================================
// T4: Edge Case Tests
// ============================================================================

test "T4.1: edge case - command that never reads stdin" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    // Write data that will never be read
    const test_data = "this should be ignored\n";
    _ = try posix.write(sv[1], test_data);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = trueProgram(), // Exits immediately without reading stdin
        .args = &[_][]const u8{},
        .require_allow = false,
    };

    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

test "T4.2: edge case - silent command (no output)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = trueProgram(), // No output
        .args = &[_][]const u8{},
        .require_allow = false,
    };

    try exec.executeWithConnection(allocator, socket, config, client_addr);

    // Verify socket still readable (even with no data)
    var buf: [1]u8 = undefined;
    const n = try posix.read(sv[1], &buf);
    try testing.expectEqual(@as(usize, 0), n); // EOF expected
}

test "T4.3: edge case - shell command with pipe" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    // Build shell command
    const result = try exec.buildShellCommand(allocator, "echo hello | grep hello");
    defer allocator.free(result.args);

    const config = exec.ExecConfig{
        .mode = .shell,
        .program = result.program,
        .args = result.args,
        .require_allow = false,
    };

    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

// ============================================================================
// T5: Thread Detachment Scenarios
// ============================================================================

test "T5.1: detachment - verify error handling on invalid program" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = "/nonexistent/program",
        .args = &[_][]const u8{},
        .require_allow = false,
    };

    // Should return error, not panic
    const result = exec.executeWithConnection(allocator, socket, config, client_addr);
    try testing.expectError(error.FileNotFound, result);
}

// ============================================================================
// Validation Tests (Post-Fix)
// ============================================================================

test "V1: validate fix - /bin/true completes without panic" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = trueProgram(),
        .args = &[_][]const u8{},
        .require_allow = false,
    };

    // CRITICAL: This must NOT panic
    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

test "V2: validate fix - /bin/echo with input completes without panic" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    var write_closed = false;
    defer if (!write_closed) posix.close(sv[1]);

    // Write test input
    const test_data = "test\n";
    _ = try posix.write(sv[1], test_data);
    posix.close(sv[1]); // Signal EOF
    write_closed = true;

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = echoProgram(),
        .args = &[_][]const u8{"hello"},
        .require_allow = false,
    };

    // CRITICAL: This must NOT panic (exact reproduction of manual test)
    try exec.executeWithConnection(allocator, socket, config, client_addr);
}

test "V3: validate fix - no performance regression" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const start_time = std.time.milliTimestamp();

    // Run 50 iterations (reduced from 100 for test speed)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const sv = try createMockSocketPair();
        defer posix.close(sv[0]);
        defer posix.close(sv[1]);

        const socket = net.Stream{ .handle = sv[0] };
        const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

        const config = exec.ExecConfig{
            .mode = .direct,
            .program = echoProgram(),
            .args = &[_][]const u8{"test"},
            .require_allow = false,
        };

        try exec.executeWithConnection(allocator, socket, config, client_addr);
    }

    const elapsed_ms = std.time.milliTimestamp() - start_time;

    // Should complete 50 iterations in < 10 seconds
    try testing.expect(elapsed_ms < 10000);

    std.debug.print("\nPerformance: 50 iterations in {d}ms ({d}ms avg)\n", .{
        elapsed_ms,
        @divTrunc(elapsed_ms, 50),
    });
}

test "V4: validate fix - error paths still work correctly" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    // Test 1: Invalid program
    {
        const config = exec.ExecConfig{
            .mode = .direct,
            .program = "/nonexistent",
            .args = &[_][]const u8{},
            .require_allow = false,
        };

        const result = exec.executeWithConnection(allocator, socket, config, client_addr);
        try testing.expectError(error.FileNotFound, result);
    }

    // Test 2: Valid program still works
    {
        const config = exec.ExecConfig{
            .mode = .direct,
            .program = trueProgram(),
            .args = &[_][]const u8{},
            .require_allow = false,
        };

        try exec.executeWithConnection(allocator, socket, config, client_addr);
    }
}

// ============================================================================
// T6: Timeout and Flow Control Tests
// ============================================================================

test "T6.1: exec idle timeout triggers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = catProgram(),
        .args = &[_][]const u8{},
        .require_allow = false,
        .session_config = .{
            .timeouts = .{
                .idle_ms = 100,
            },
        },
    };

    try testing.expectError(
        exec.ExecError.TimeoutIdle,
        exec.executeWithConnection(allocator, socket, config, client_addr),
    );
}

test "T6.2: exec execution timeout terminates long-running command" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = sleepProgram(),
        .args = &[_][]const u8{"5"},
        .require_allow = false,
        .session_config = .{
            .timeouts = .{
                .execution_ms = 200,
            },
        },
    };

    try testing.expectError(
        exec.ExecError.TimeoutExecution,
        exec.executeWithConnection(allocator, socket, config, client_addr),
    );
}

test "T6.3: exec connection timeout triggers before activity" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = catProgram(),
        .args = &[_][]const u8{},
        .require_allow = false,
        .session_config = .{
            .timeouts = .{
                .connection_ms = 100,
            },
        },
    };

    try testing.expectError(
        exec.ExecError.TimeoutConnection,
        exec.executeWithConnection(allocator, socket, config, client_addr),
    );
}

test "T6.4: exec session rejects invalid flow control configuration" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    const sv = try createMockSocketPair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const socket = net.Stream{ .handle = sv[0] };
    const client_addr = try net.Address.parseIp4("127.0.0.1", 0);

    const config = exec.ExecConfig{
        .mode = .direct,
        .program = catProgram(),
        .args = &[_][]const u8{},
        .require_allow = false,
        .session_config = .{
            .buffers = .{
                .stdin_capacity = 4096,
                .stdout_capacity = 4096,
                .stderr_capacity = 4096,
            },
            .flow = .{
                .max_total_buffer_bytes = 1024,
            },
        },
    };

    try testing.expectError(
        exec.ExecError.InvalidConfiguration,
        exec.executeWithConnection(allocator, socket, config, client_addr),
    );
}
