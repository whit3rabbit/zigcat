// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Cross-platform socket abstraction layer for Zigcat.
//!
//! This module provides a unified interface for socket operations across Windows and Unix platforms,
//! handling critical platform differences:
//!
//! ## Platform Differences
//!
//! ### Socket Types
//! - **Windows**: Socket is `std.os.windows.ws2_32.SOCKET` (usize)
//! - **Unix/POSIX**: Socket is `posix.socket_t` (i32)
//!
//! ### Initialization
//! - **Windows**: Requires `WSAStartup()` before any socket operations, cleanup with `WSACleanup()`
//! - **Unix/POSIX**: No initialization required, sockets available immediately
//!
//! ### Non-blocking Mode
//! - **Windows**: Uses `ioctlsocket()` with `FIONBIO` flag
//! - **Unix/POSIX**: Uses `fcntl()` with `O_NONBLOCK` flag
//!
//! ### Socket Closure
//! - **Windows**: Uses `closesocket()` from WinSock API
//! - **Unix/POSIX**: Uses standard `close()` POSIX call
//!
//! ## Usage Pattern
//!
//! ```zig
//! // Initialize platform networking (Windows only, no-op on Unix)
//! try socket.initPlatform();
//! defer socket.deinitPlatform();
//!
//! // Create and configure socket
//! const sock = try socket.createTcpSocket(.ipv4);
//! defer socket.closeSocket(sock);
//!
//! try socket.setReuseAddr(sock);
//! try socket.setNonBlocking(sock);
//! ```
//!
//! ## Memory Safety
//! All socket operations use `errdefer` cleanup patterns. Callers must ensure sockets are closed
//! either explicitly via `closeSocket()` or through `defer` statements.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const logging = @import("../util/logging.zig");

/// Platform-specific socket type.
/// Windows uses SOCKET (usize), Unix uses socket_t (i32).
pub const Socket = if (builtin.os.tag == .windows) std.os.windows.ws2_32.SOCKET else posix.socket_t;

/// Check if a socket descriptor is valid.
///
/// Platform-agnostic validation for socket descriptors.
///
/// ## Parameters
/// - `sock`: Socket descriptor to validate
///
/// ## Returns
/// - `true` if socket is valid
/// - `false` if socket is invalid
///
/// ## Platform Implementation
/// - **Windows**: Checks `sock != INVALID_SOCKET`
/// - **Unix/POSIX**: Checks `sock >= 0`
///
/// ## Example
/// ```zig
/// const sock = try createTcpSocket(.ipv4);
/// if (isValidSocket(sock)) {
///     // Use socket
/// }
/// ```
pub fn isValidSocket(sock: Socket) bool {
    if (builtin.os.tag == .windows) {
        return sock != std.os.windows.ws2_32.INVALID_SOCKET;
    } else {
        return sock >= 0;
    }
}

/// Initialize platform-specific networking subsystem.
///
/// **Windows**: Calls `WSAStartup()` to initialize WinSock 2.2 library.
/// **Unix/POSIX**: No-op, returns immediately without error.
///
/// ## Requirements
/// - Must be called before any socket operations on Windows
/// - Must be paired with `deinitPlatform()` cleanup
/// - Safe to call multiple times (WSAStartup is reference-counted on Windows)
///
/// ## Errors
/// - `error.WSAStartupFailed`: Windows failed to initialize WinSock library
///
/// ## Example
/// ```zig
/// try socket.initPlatform();
/// defer socket.deinitPlatform();
/// ```
pub fn initPlatform() !void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var wsa_data: windows.ws2_32.WSADATA = undefined;
        const result = windows.ws2_32.WSAStartup(0x0202, &wsa_data);
        if (result != 0) {
            return error.WSAStartupFailed;
        }
    }
}

/// Cleanup platform-specific networking subsystem.
///
/// **Windows**: Calls `WSACleanup()` to decrement WinSock reference count.
/// **Unix/POSIX**: No-op, returns immediately.
///
/// ## Requirements
/// - Should be called after all sockets are closed
/// - Must be paired with `initPlatform()` initialization
/// - Safe to call even if init failed (no-op on Unix, decrements on Windows)
///
/// ## Platform Notes
/// On Windows, WSACleanup is reference-counted, so each WSAStartup must have
/// a matching WSACleanup call.
pub fn deinitPlatform() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.WSACleanup();
    }
}

/// Create a TCP socket with specified address family.
///
/// ## Parameters
/// - `family`: Address family (.ipv4 or .ipv6)
///
/// ## Returns
/// Platform-specific socket descriptor (usize on Windows, i32 on Unix)
///
/// ## Errors
/// - `error.AddressFamilyNotSupported`: System doesn't support the requested address family
/// - `error.ProtocolFamilyNotAvailable`: TCP protocol not available
/// - `error.SystemResources`: Out of file descriptors or memory
/// - Other POSIX socket creation errors
///
/// ## Memory Safety
/// Caller must ensure socket is closed via `closeSocket()` or use `defer`/`errdefer`.
///
/// ## Example
/// ```zig
/// const sock = try createTcpSocket(.ipv4);
/// errdefer closeSocket(sock);
/// ```
pub fn createTcpSocket(family: AddressFamily) !Socket {
    const af: u32 = switch (family) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };

    return posix.socket(
        af,
        posix.SOCK.STREAM,
        posix.IPPROTO.TCP,
    ) catch |err| {
        logging.logDebug("Failed to create TCP socket: {any}\n", .{err});
        return err;
    };
}

/// Create a UDP socket with specified address family.
///
/// ## Parameters
/// - `family`: Address family (.ipv4 or .ipv6)
///
/// ## Returns
/// Platform-specific socket descriptor (usize on Windows, i32 on Unix)
///
/// ## Errors
/// - `error.AddressFamilyNotSupported`: System doesn't support the requested address family
/// - `error.ProtocolFamilyNotAvailable`: UDP protocol not available
/// - `error.SystemResources`: Out of file descriptors or memory
/// - Other POSIX socket creation errors
///
/// ## Memory Safety
/// Caller must ensure socket is closed via `closeSocket()` or use `defer`/`errdefer`.
///
/// ## Example
/// ```zig
/// const sock = try createUdpSocket(.ipv4);
/// errdefer closeSocket(sock);
/// ```
pub fn createUdpSocket(family: AddressFamily) !Socket {
    const af: u32 = switch (family) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };

    return posix.socket(
        af,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    ) catch |err| {
        logging.logDebug("Failed to create UDP socket: {any}\n", .{err});
        return err;
    };
}

/// Create an SCTP socket with specified address family.
///
/// ## Parameters
/// - `family`: Address family (.ipv4 or .ipv6)
///
/// ## Returns
/// Platform-specific socket descriptor (usize on Windows, i32 on Unix)
///
/// ## Errors
/// - `error.SctpNotSupported`: SCTP is not supported on this platform
/// - `error.AddressFamilyNotSupported`: System doesn't support the requested address family
/// - `error.ProtocolFamilyNotAvailable`: SCTP protocol not available
/// - `error.SystemResources`: Out of file descriptors or memory
/// - Other POSIX socket creation errors
///
/// ## Platform Support
/// - **Linux**: Supported
/// - **FreeBSD**: Supported
/// - **macOS**: Deprecated, may not be available
/// - **Windows**: Not supported
pub fn createSctpSocket(family: AddressFamily) !Socket {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd and builtin.os.tag != .macos) {
        return error.SctpNotSupported;
    }

    const af: u32 = switch (family) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };

    const IPPROTO_SCTP = 132;

    return posix.socket(
        af,
        posix.SOCK.SEQPACKET,
        IPPROTO_SCTP,
    ) catch |err| {
        logging.logDebug("Failed to create SCTP socket: {any}\n", .{err});
        if (err == error.ProtocolNotSupported) {
            return error.SctpNotSupported;
        }
        return err;
    };
}

/// Enable SO_REUSEADDR socket option.
///
/// Allows binding to an address that is in TIME_WAIT state, useful for server restart scenarios.
///
/// ## Parameters
/// - `sock`: Socket descriptor to configure
///
/// ## Errors
/// - `error.PermissionDenied`: Insufficient privileges to set option
/// - `error.InvalidArgument`: Invalid socket or option value
/// - Other POSIX setsockopt errors
///
/// ## Platform Behavior
/// - **Unix**: Allows immediate rebind of address in TIME_WAIT
/// - **Windows**: Similar behavior, allows address reuse
///
/// ## Example
/// ```zig
/// const sock = try createTcpSocket(.ipv4);
/// try setReuseAddr(sock);  // Allow quick server restart
/// ```
pub fn setReuseAddr(sock: Socket) !void {
    const enable: c_int = 1;
    try posix.setsockopt(
        sock,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        std.mem.asBytes(&enable),
    );
}

/// Enable SO_REUSEPORT socket option (platform-specific, optional).
///
/// Allows multiple sockets to bind to the same port for load balancing.
/// This is an OPTIONAL operation that fails gracefully on unsupported platforms.
///
/// ## Parameters
/// - `sock`: Socket descriptor to configure
///
/// ## Platform Support
/// - **Linux**: Supported (SO_REUSEPORT = 15), enables kernel load balancing
/// - **macOS**: Supported (SO_REUSEPORT = 0x0200)
/// - **Windows**: Not supported, function returns without error
/// - **Other Unix**: May not be available, logs warning and continues
///
/// ## Errors
/// This function does NOT propagate errors. If SO_REUSEPORT is unavailable,
/// a warning is printed to stderr and execution continues.
///
/// ## Use Case
/// Primarily for server applications that want to run multiple instances
/// on the same port with kernel-level load balancing.
pub fn setReusePort(sock: Socket) !void {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const enable: c_int = 1;
        const SO_REUSEPORT = if (builtin.os.tag == .linux) 15 else 0x0200;
        posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            @intCast(SO_REUSEPORT),
            std.mem.asBytes(&enable),
        ) catch |err| {
            // SO_REUSEPORT is optional, don't fail if not available
            logging.logDebug("Warning: SO_REUSEPORT not available: {any}\n", .{err});
        };
    }
}

/// Set socket to non-blocking mode.
///
/// CRITICAL for timeout-aware I/O operations. Non-blocking sockets return immediately
/// from read/write operations instead of blocking indefinitely.
///
/// ## Parameters
/// - `sock`: Socket descriptor to configure
///
/// ## Errors
/// - **Windows**: `error.IoctlFailed` if `ioctlsocket()` fails
/// - **Unix**: POSIX fcntl errors (PermissionDenied, InvalidArgument, etc.)
///
/// ## Platform Implementation
/// - **Windows**: Uses `ioctlsocket()` with `FIONBIO` flag
/// - **Unix**: Uses `fcntl(F_GETFL)` to read flags, then `fcntl(F_SETFL)` with `O_NONBLOCK (0x0004)`
///
/// ## Usage Pattern
/// Non-blocking mode is MANDATORY for all timeout-aware operations. After setting,
/// operations must use `std.posix.poll()` to wait for readiness with timeout.
///
/// ## Example
/// ```zig
/// const sock = try createTcpSocket(.ipv4);
/// try setNonBlocking(sock);  // Required for timeout enforcement
///
/// // Now use with poll() for timeout control
/// var pollfds = [_]posix.pollfd{.{ .fd = sock, .events = POLL.OUT, .revents = 0 }};
/// const ready = try posix.poll(&pollfds, timeout_ms);
/// ```
///
/// See `/docs/TIMEOUT_SAFETY.md` for complete timeout patterns.
pub fn setNonBlocking(sock: Socket) !void {
    if (builtin.os.tag == .windows) {
        var mode: c_ulong = 1;
        const result = std.os.windows.ws2_32.ioctlsocket(sock, std.os.windows.ws2_32.FIONBIO, &mode);
        if (result != 0) return error.IoctlFailed;
    } else {
        const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
        const NONBLOCK: u32 = 0x0004; // O_NONBLOCK on most Unix systems
        _ = try posix.fcntl(sock, posix.F.SETFL, flags | NONBLOCK);
    }
}

/// Close a socket and release system resources.
///
/// This function handles platform-specific socket cleanup. Always use this instead
/// of direct `close()` calls for cross-platform compatibility.
///
/// ## Parameters
/// - `sock`: Socket descriptor to close
///
/// ## Platform Implementation
/// - **Windows**: Uses `closesocket()` from WinSock API
/// - **Unix/POSIX**: Uses standard `close()` system call
///
/// ## Memory Safety
/// - Safe to call multiple times on the same socket (close is idempotent on most platforms)
/// - Does NOT return errors (failures are silently ignored)
/// - Should be called in `defer` or `errdefer` blocks for automatic cleanup
///
/// ## Example
/// ```zig
/// const sock = try createTcpSocket(.ipv4);
/// defer closeSocket(sock);  // Automatic cleanup
/// ```
pub fn closeSocket(sock: Socket) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(sock);
    } else {
        posix.close(sock);
    }
}

/// Address family enumeration for socket creation.
pub const AddressFamily = enum {
    /// IPv4 address family (AF_INET)
    ipv4,
    /// IPv6 address family (AF_INET6)
    ipv6,
};

/// Detect address family from hostname or IP address string.
///
/// Uses simple heuristic: presence of ':' indicates IPv6, otherwise IPv4.
///
/// ## Parameters
/// - `host`: Hostname or IP address string
///
/// ## Returns
/// - `.ipv6` if string contains ':' (e.g., "::1", "2001:db8::1")
/// - `.ipv4` otherwise (e.g., "127.0.0.1", "example.com")
///
/// ## Limitations
/// This is a HEURISTIC, not a validator. It does not:
/// - Validate IP address format
/// - Resolve hostnames
/// - Handle IPv6 addresses with port notation (e.g., "[::1]:8080")
///
/// ## Example
/// ```zig
/// const family = detectAddressFamily("192.168.1.1");  // .ipv4
/// const family6 = detectAddressFamily("::1");         // .ipv6
/// ```
pub fn detectAddressFamily(host: []const u8) AddressFamily {
    // Simple heuristic: if it contains ':', assume IPv6
    if (std.mem.indexOf(u8, host, ":")) |_| {
        return .ipv6;
    }
    return .ipv4;
}
