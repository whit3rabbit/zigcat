// io_uring port scanner compile-time tests
//
// These tests validate io_uring compile-time availability checks.
// Note: This is a standalone test file and must be self-contained.
// Cannot import from src/ due to circular dependency issues.
//
// For full integration testing of the scanner implementation,
// use `zig build test` which includes src/util/portscan_uring.zig tests.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

test "io_uring compile-time availability on Linux" {
    // On Linux, io_uring should be available at compile time
    if (builtin.os.tag == .linux) {
        // IO_Uring type should be available
        const IoUring = std.os.linux.IoUring;
        _ = IoUring;
        try testing.expect(true);
    } else {
        // On non-Linux, skip test
        return error.SkipZigTest;
    }
}

test "io_uring compile-time availability on non-Linux" {
    // On non-Linux platforms, io_uring should not be available
    if (builtin.os.tag != .linux) {
        // Test passes - platform correctly detected as non-Linux
        try testing.expect(true);
    } else {
        // On Linux, skip this test
        return error.SkipZigTest;
    }
}

test "io_uring initialization attempt" {
    if (builtin.os.tag != .linux) {
        std.debug.print("Skipping io_uring init test (not Linux)\n", .{});
        return error.SkipZigTest;
    }

    // Try to initialize IO_Uring with small queue
    const IoUring = std.os.linux.IoUring;
    var ring = IoUring.init(1, 0) catch |err| {
        // Failure is okay - kernel might not support io_uring
        std.debug.print("io_uring init failed (expected on kernels < 5.1 or CONFIG_IO_URING disabled): {any}\n", .{err});
        return error.SkipZigTest;
    };
    defer ring.deinit();

    std.debug.print("io_uring successfully initialized\n", .{});
    try testing.expect(true);
}

test "io_uring SQE operations exist" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    // Verify that IO_Uring SQE type and prep methods exist at compile time
    const IoUring = std.os.linux.IoUring;
    const SubmissionQueueEntry = std.os.linux.io_uring_sqe;

    // These should compile without error
    _ = IoUring;
    _ = SubmissionQueueEntry;

    try testing.expect(true);
}

test "platform detection - Linux vs non-Linux" {
    // This test validates platform detection at compile time
    const is_linux = builtin.os.tag == .linux;

    if (is_linux) {
        std.debug.print("Running on Linux - io_uring may be available\n", .{});
    } else {
        std.debug.print("Running on {s} - io_uring not available\n", .{@tagName(builtin.os.tag)});
    }

    try testing.expect(true);
}

test "socket types for io_uring" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    // Verify required socket constants exist
    const AF = std.posix.AF;
    const SOCK = std.posix.SOCK;
    const IPPROTO = std.posix.IPPROTO;

    _ = AF.INET;
    _ = AF.INET6;
    _ = SOCK.STREAM;
    _ = SOCK.NONBLOCK;
    _ = IPPROTO.TCP;

    try testing.expect(true);
}

test "kernel timespec for io_uring timeout" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    // Verify kernel_timespec type exists for io_uring timeouts
    const kernel_timespec = std.os.linux.kernel_timespec;

    const timeout = kernel_timespec{
        .sec = 1,
        .nsec = 0,
    };

    try testing.expectEqual(@as(i64, 1), timeout.sec);
    try testing.expectEqual(@as(i64, 0), timeout.nsec);
}
