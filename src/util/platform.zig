// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Platform detection and capability checking for zigcat.
//!
//! This module provides runtime detection of platform features including:
//! - Linux kernel version parsing
//! - io_uring support detection
//! - Platform-specific capability checks
//!
//! Used to enable/disable features based on platform capabilities.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Linux kernel version structure
pub const KernelVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// Check if this version is >= the specified version
    pub fn isAtLeast(self: KernelVersion, major: u32, minor: u32) bool {
        if (self.major > major) return true;
        if (self.major < major) return false;
        return self.minor >= minor;
    }

    /// Format kernel version as string (e.g., "5.10.0")
    pub fn format(
        self: KernelVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// Parse Linux kernel version from uname release string.
///
/// Handles various distribution formats:
/// - "5.10.0" (vanilla kernel)
/// - "5.10.0-23-generic" (Ubuntu/Debian)
/// - "5.10.0-23.fc35.x86_64" (Fedora)
/// - "5.10.0-arch1-1" (Arch Linux)
///
/// Parameters:
///   release: Release string from uname (e.g., "5.10.0-23-generic")
///
/// Returns: Parsed kernel version or error.InvalidKernelVersion
///
/// Example:
/// ```zig
/// const version = try parseKernelVersion("5.10.0-23-generic");
/// std.debug.print("Kernel: {}\n", .{version}); // "Kernel: 5.10.0"
/// ```
pub fn parseKernelVersion(release: []const u8) !KernelVersion {
    // Find the first dash or end of string to isolate version part
    const version_end = std.mem.indexOf(u8, release, "-") orelse release.len;
    const version_str = release[0..version_end];

    // Split by dots to get major.minor.patch
    var it = std.mem.splitScalar(u8, version_str, '.');

    const major_str = it.next() orelse return error.InvalidKernelVersion;
    const minor_str = it.next() orelse return error.InvalidKernelVersion;
    const patch_str = it.next() orelse "0";

    const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidKernelVersion;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidKernelVersion;
    const patch = std.fmt.parseInt(u32, patch_str, 10) catch 0; // Patch is optional

    return KernelVersion{
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

/// Get current Linux kernel version at runtime.
///
/// Uses std.posix.uname() to query the kernel and parses the release string.
/// Only works on Linux - returns error on other platforms.
///
/// Returns: Current kernel version or error
///
/// Errors:
/// - error.UnsupportedPlatform: Not running on Linux
/// - error.InvalidKernelVersion: Failed to parse version string
///
/// Example:
/// ```zig
/// if (getLinuxKernelVersion()) |version| {
///     std.debug.print("Running kernel {}\n", .{version});
/// } else |err| {
///     std.debug.print("Not on Linux: {}\n", .{err});
/// }
/// ```
pub fn getLinuxKernelVersion() !KernelVersion {
    if (builtin.os.tag != .linux) {
        return error.UnsupportedPlatform;
    }

    var uts: posix.utsname = undefined;
    const result = posix.system.uname(&uts);
    if (result != 0) {
        return error.UnameCallFailed;
    }

    // Extract release string (null-terminated C string)
    const release_len = std.mem.indexOfScalar(u8, &uts.release, 0) orelse uts.release.len;
    const release = uts.release[0..release_len];

    return parseKernelVersion(release);
}

/// Check if io_uring is supported on the current system.
///
/// Requirements for io_uring support:
/// 1. Linux platform (compile-time check)
/// 2. Kernel version >= 5.1 (runtime check)
/// 3. CONFIG_IO_URING enabled in kernel (syscall probe)
///
/// This function performs a lightweight check by attempting to create
/// an io_uring instance. If it succeeds, io_uring is available.
///
/// Returns: true if io_uring is fully supported, false otherwise
///
/// Performance Note:
/// - First call performs syscall probe (~1-2ms overhead)
/// - Result should be cached if called frequently
///
/// Example:
/// ```zig
/// if (isIoUringSupported()) {
///     std.debug.print("io_uring available, using high-performance scanner\n", .{});
/// } else {
///     std.debug.print("io_uring not available, using thread pool\n", .{});
/// }
/// ```
pub fn isIoUringSupported() bool {
    // Compile-time check: Only available on Linux x86_64
    // io_uring support in Zig stdlib is architecture-dependent
    if (builtin.os.tag != .linux) {
        return false;
    }
    if (builtin.cpu.arch != .x86_64) {
        return false;
    }

    // Runtime check: Kernel version >= 5.1
    const version = getLinuxKernelVersion() catch return false;
    if (!version.isAtLeast(5, 1)) {
        return false;
    }

    // Syscall probe: Try to create an io_uring instance
    // If the syscall succeeds, CONFIG_IO_URING is enabled
    //
    // CRITICAL: std.os.linux.IO_Uring only exists when compiling FOR Linux x86_64.
    // During cross-compilation (macOS → Linux), the type doesn't exist in stdlib.
    // We must use @hasDecl to check if the type exists before referencing it.
    if (!@hasDecl(std.os.linux, "IO_Uring")) {
        return false;
    }

    const IO_Uring = std.os.linux.IO_Uring;

    // Try to initialize with minimal 1-entry ring
    var ring = IO_Uring.init(1, 0) catch {
        // io_uring syscall failed (CONFIG_IO_URING=n or permission denied)
        return false;
    };
    defer ring.deinit();

    // Successfully created io_uring instance
    return true;
}

/// Check if io_uring provided buffers are supported on the current system.
///
/// Provided buffers (IORING_OP_PROVIDE_BUFFERS) allow the kernel to automatically
/// select buffers from a pre-registered pool, improving performance by eliminating
/// per-operation buffer mapping overhead.
///
/// Requirements for provided buffer support:
/// 1. Linux platform (compile-time check)
/// 2. x86_64 architecture (compile-time check)
/// 3. Kernel version >= 5.7 (runtime check)
/// 4. Basic io_uring support (5.1+)
///
/// This function builds on isIoUringSupported() by adding the 5.7+ version check.
/// No additional syscall probe is needed - if io_uring works on 5.7+, provided
/// buffers will work.
///
/// Returns: true if provided buffers are supported, false otherwise
///
/// Performance Note:
/// - Uses cached kernel version from getLinuxKernelVersion()
/// - No syscall overhead beyond basic io_uring probe
///
/// Example:
/// ```zig
/// if (isIoUringProvidedBuffersSupported()) {
///     std.debug.print("Using io_uring with provided buffers (kernel 5.7+)\n", .{});
/// } else if (isIoUringSupported()) {
///     std.debug.print("Using io_uring with standard buffers (kernel 5.1+)\n", .{});
/// } else {
///     std.debug.print("Using poll-based I/O\n", .{});
/// }
/// ```
pub fn isIoUringProvidedBuffersSupported() bool {
    // Compile-time check: Only available on Linux x86_64
    if (builtin.os.tag != .linux) {
        return false;
    }
    if (builtin.cpu.arch != .x86_64) {
        return false;
    }

    // Runtime check: Kernel version >= 5.7
    const version = getLinuxKernelVersion() catch return false;
    if (!version.isAtLeast(5, 7)) {
        return false;
    }

    // Verify basic io_uring support is available
    // (Provided buffers require io_uring, so check both)
    if (!@hasDecl(std.os.linux, "IO_Uring")) {
        return false;
    }

    const IO_Uring = std.os.linux.IO_Uring;

    // Try to initialize with minimal 1-entry ring
    // If this succeeds on 5.7+, provided buffers will work
    var ring = IO_Uring.init(1, 0) catch {
        return false;
    };
    defer ring.deinit();

    return true;
}

/// Get a human-readable platform description.
///
/// Returns a string describing the current platform, kernel version,
/// and available features. Useful for verbose logging and debugging.
///
/// Parameters:
///   allocator: Memory allocator for building the string
///
/// Returns: Formatted platform description (caller must free)
///
/// Example output:
/// - "Linux 5.10.0 (io_uring: supported)"
/// - "Linux 4.19.0 (io_uring: not supported - kernel too old)"
/// - "macOS (io_uring: not supported - platform)"
pub fn getPlatformDescription(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .linux) {
        const version = getLinuxKernelVersion() catch {
            return try std.fmt.allocPrint(allocator, "Linux (version unknown)", .{});
        };

        const uring_status = if (isIoUringSupported())
            "supported"
        else if (version.isAtLeast(5, 1))
            "not supported - CONFIG_IO_URING disabled"
        else
            "not supported - kernel too old (need 5.1+)";

        return try std.fmt.allocPrint(
            allocator,
            "Linux {} (io_uring: {s})",
            .{ version, uring_status },
        );
    } else {
        return try std.fmt.allocPrint(
            allocator,
            "{s} (io_uring: not supported - Linux-only)",
            .{@tagName(builtin.os.tag)},
        );
    }
}
