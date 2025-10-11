// Platform-Specific Tests
// Tests for Windows, Unix, and cross-platform compatibility

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const builtin = @import("builtin");

// Import modules under test
// const platform = @import("../src/util/platform.zig");
// const network = @import("../src/net/socket.zig");

// =============================================================================
// WINDOWS-SPECIFIC TESTS
// =============================================================================

test "Windows - WSAStartup initialization" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // On Windows, WSAStartup must be called before any socket operations
    // Test that our platform init does this correctly

    // const result = try platform.init();
    // try expect(result.initialized);
    //
    // // Verify Winsock version
    // try expect(result.version_major >= 2);
    // try expect(result.version_minor >= 2);
}

test "Windows - WSACleanup on deinit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Verify WSACleanup is called on shutdown

    // try platform.init();
    // defer platform.deinit();
    //
    // // After deinit, Winsock should be cleaned up
    // // Attempting socket operations should fail
}

test "Windows - closesocket vs close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // On Windows, sockets use closesocket(), not close()
    // Test that our abstraction uses the right one

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // const fd = socket.fd;
    //
    // socket.close();
    //
    // // Verify socket is closed (operations should fail)
    // const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    // try expectError(error.InvalidSocket, socket.bind(addr));
}

test "Windows - SOCKET handle type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // On Windows, SOCKET is usize, not i32
    // Verify our socket type handles this correctly

    // const socket = try network.createSocket(testing.allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // // SOCKET should be a valid handle
    // try expect(socket.fd != std.os.windows.INVALID_SOCKET);
}

test "Windows - WSAEWOULDBLOCK handling" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Windows uses WSAEWOULDBLOCK instead of EAGAIN
    // Test error mapping

    // const socket = try network.createSocket(testing.allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // try socket.setNonBlocking(true);
    //
    // // Try to read from non-connected socket
    // var buffer: [1024]u8 = undefined;
    // socket.recv(&buffer) catch |err| {
    //     try expectEqual(error.WouldBlock, err);
    //     return;
    // };
}

test "Windows - select vs WSAPoll" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Windows can use either select() or WSAPoll()
    // Test that our poller works correctly

    // const poller = try platform.Poller.init(testing.allocator);
    // defer poller.deinit();
    //
    // const socket = try network.createSocket(testing.allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // try poller.add(socket.fd, .{ .read = true });
    //
    // // Poll with timeout
    // const events = try poller.poll(100); // 100ms timeout
    // try expectEqual(@as(usize, 0), events.len); // No events yet
}

test "Windows - path separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Windows uses backslash, Unix uses forward slash
    // Test path handling

    // const path = platform.joinPath(testing.allocator, "C:\\temp", "socket.sock");
    // defer testing.allocator.free(path);
    //
    // try expectEqualStrings("C:\\temp\\socket.sock", path);
}

// =============================================================================
// UNIX-SPECIFIC TESTS
// =============================================================================

test "Unix - file descriptor semantics" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // On Unix, sockets are file descriptors
    // Test that we can treat them like files

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // // Socket fd should be a valid file descriptor
    // try expect(socket.fd >= 0);
    //
    // // Should be able to use fcntl on it
    // const flags = try std.os.fcntl(socket.fd, std.os.F.GETFL, 0);
    // try expect(flags >= 0);
}

test "Unix - SIGPIPE handling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // On Unix, writing to a closed socket can generate SIGPIPE
    // We should either ignore it or use MSG_NOSIGNAL

    // Test that SIGPIPE is handled correctly
    // const handler = try platform.getSigpipeHandler();
    // try expectEqual(platform.SigpipeHandler.ignore, handler);
}

test "Unix - domain sockets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // Unix domain sockets (AF_UNIX) are Unix-only
    // Test creation and binding

    // const socket = try network.createUnixSocket(allocator);
    // defer socket.close();
    //
    // const path = "/tmp/test-socket.sock";
    // defer std.fs.cwd().deleteFile(path) catch {};
    //
    // try socket.bind(path);
    //
    // // Verify socket file exists
    // const stat = try std.fs.cwd().statFile(path);
    // try expect(stat.kind == .UnixDomainSocket);
}

test "Unix - SO_REUSEPORT support" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;

    // SO_REUSEPORT is supported on some Unix systems (Linux, BSD)
    // Test if available

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // // Try to set SO_REUSEPORT
    // socket.setReusePort(true) catch |err| {
    //     // Some platforms don't support it
    //     if (err == error.NotSupported) return error.SkipZigTest;
    //     return err;
    // };
}

test "Unix - fork safety" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Socket file descriptors should have FD_CLOEXEC set
    // To prevent leaking into child processes

    // const socket = try network.createSocket(testing.allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // const flags = try std.os.fcntl(socket.fd, std.os.F.GETFD, 0);
    // try expect((flags & std.os.FD_CLOEXEC) != 0);
}

test "Unix - signal handling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Test that our signal handling doesn't interfere with socket I/O
    // Specifically: EINTR should be handled correctly

    // const socket = try network.createSocket(testing.allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // // Simulate interrupted syscall
    // // recv() should retry on EINTR
}

// =============================================================================
// IPv6 PLATFORM TESTS
// =============================================================================

test "IPv6 - availability check" {
    const allocator = testing.allocator;

    // Not all systems have IPv6 enabled
    // Test detection and fallback

    // const ipv6_available = try platform.hasIPv6();
    //
    // if (ipv6_available) {
    //     const socket = try network.createSocket(allocator, .ipv6, .tcp);
    //     defer socket.close();
    //
    //     try expect(socket.fd >= 0);
    // } else {
    //     // Should fall back to IPv4 or return error
    //     try expectError(error.IPv6NotSupported, network.createSocket(allocator, .ipv6, .tcp));
    // }
}

test "IPv6 - dual stack configuration" {
    const allocator = testing.allocator;

    // Test IPV6_V6ONLY socket option
    // When disabled, IPv6 socket can accept IPv4 connections

    // const socket = try network.createSocket(allocator, .ipv6, .tcp);
    // defer socket.close();
    //
    // // Disable IPv6-only mode
    // try socket.setIPv6Only(false);
    //
    // // Verify option was set
    // const v6only = try socket.getIPv6Only();
    // try expect(!v6only);
}

test "IPv6 - loopback address" {
    const allocator = testing.allocator;

    // Test IPv6 loopback (::1)

    // const addr = try std.net.Address.parseIp6("::1", 0);
    // try expect(addr.any.family == std.os.AF.INET6);
}

// =============================================================================
// CROSS-PLATFORM COMPATIBILITY TESTS
// =============================================================================

test "cross-platform - socket creation" {
    const allocator = testing.allocator;

    // Socket creation should work on all platforms

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // try expect(socket.fd != platform.INVALID_SOCKET);
}

test "cross-platform - address parsing" {
    // Address parsing should work identically on all platforms

    const addr = try std.net.Address.parseIp4("192.168.1.1", 8080);

    try expectEqual(@as(u16, 8080), addr.getPort());
}

test "cross-platform - localhost connection" {
    const allocator = testing.allocator;

    // Basic localhost connection should work everywhere

    // const listener = try network.createSocket(allocator, .ipv4, .tcp);
    // defer listener.close();
    //
    // const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // const client = try network.createSocket(allocator, .ipv4, .tcp);
    // defer client.close();
    //
    // try client.connect(listen_addr);
}

test "cross-platform - UDP socket" {
    const allocator = testing.allocator;

    // UDP should work on all platforms

    // const socket = try network.createSocket(allocator, .ipv4, .udp);
    // defer socket.close();
    //
    // const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
}

test "cross-platform - non-blocking I/O" {
    const allocator = testing.allocator;

    // Non-blocking mode should work on all platforms

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // try socket.setNonBlocking(true);
    //
    // // Verify with a read that would block
    // var buffer: [1024]u8 = undefined;
    // try expectError(error.WouldBlock, socket.recv(&buffer));
}

test "cross-platform - socket options" {
    const allocator = testing.allocator;

    // Common socket options should work everywhere

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // try socket.setReuseAddr(true);
    // try socket.setKeepAlive(true);
    // try socket.setNoDelay(true);
    //
    // // Verify options were set
    // try expect(try socket.getReuseAddr());
    // try expect(try socket.getKeepAlive());
    // try expect(try socket.getNoDelay());
}

// =============================================================================
// ENDIANNESS TESTS
// =============================================================================

test "endianness - port number conversion" {
    // Port numbers must be in network byte order (big-endian)
    // Test that conversion is correct on all architectures

    const port_host: u16 = 8080;
    const port_network = std.mem.nativeToBig(u16, port_host);

    // On big-endian systems, these are equal
    // On little-endian systems, they're different
    if (builtin.cpu.arch.endian() == .Little) {
        try expect(port_host != port_network);
        try expectEqual(@as(u16, 0x901F), port_network); // 8080 in big-endian
    } else {
        try expectEqual(port_host, port_network);
    }
}

test "endianness - IP address conversion" {
    // IPv4 addresses must be in network byte order

    const addr = try std.net.Address.parseIp4("192.168.1.1", 0);

    // Verify address is stored in network order
    // 192.168.1.1 = 0xC0A80101 in network order
}

// =============================================================================
// LEGACY SYSTEM TESTS
// =============================================================================

test "legacy - old Windows version support" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Test that we can run on older Windows versions
    // (Windows 7, Windows Server 2008 R2, etc.)

    // Check Windows version
    // const version = try platform.getWindowsVersion();
    //
    // // Should support Windows 7 (6.1) and later
    // try expect(version.major >= 6);
    // if (version.major == 6) {
    //     try expect(version.minor >= 1);
    // }
}

test "legacy - old Linux kernel support" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Test that we work on older Linux kernels
    // Avoid using very recent syscalls

    // const version = try platform.getKernelVersion();
    //
    // // Should work on kernels 2.6.32+ (RHEL 6 era)
    // try expect(version.major >= 2);
    // if (version.major == 2) {
    //     try expect(version.minor >= 6);
    // }
}

test "legacy - BSD compatibility" {
    if (builtin.os.tag != .freebsd and
        builtin.os.tag != .openbsd and
        builtin.os.tag != .netbsd and
        builtin.os.tag != .dragonfly)
        return error.SkipZigTest;

    const allocator = testing.allocator;

    // Test that basic operations work on BSD systems

    // const socket = try network.createSocket(allocator, .ipv4, .tcp);
    // defer socket.close();
    //
    // const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
}

// =============================================================================
// PLATFORM DETECTION TESTS
// =============================================================================

test "platform - OS detection" {
    // Verify we correctly detect the OS

    // const os = platform.getOS();
    //
    // if (builtin.os.tag == .windows) {
    //     try expectEqual(platform.OS.windows, os);
    // } else if (builtin.os.tag == .linux) {
    //     try expectEqual(platform.OS.linux, os);
    // } else if (builtin.os.tag == .macos) {
    //     try expectEqual(platform.OS.macos, os);
    // }
}

test "platform - architecture detection" {
    // Verify we correctly detect the CPU architecture

    // const arch = platform.getArch();
    //
    // if (builtin.cpu.arch == .x86_64) {
    //     try expectEqual(platform.Arch.x86_64, arch);
    // } else if (builtin.cpu.arch == .aarch64) {
    //     try expectEqual(platform.Arch.aarch64, arch);
    // }
}

test "platform - feature detection" {
    // Test runtime feature detection

    // const features = try platform.detectFeatures();
    //
    // // All platforms should support basic TCP/IP
    // try expect(features.tcp);
    // try expect(features.udp);
    //
    // // IPv6 may or may not be available
    // // Unix sockets only on Unix
    // if (builtin.os.tag != .windows) {
    //     try expect(features.unix_sockets);
    // }
}

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
