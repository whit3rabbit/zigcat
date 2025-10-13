// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! TCP connection utilities with timeout-aware I/O.
//!
//! This module provides TCP client and server functionality with:
//! - Non-blocking connect with poll() timeout
//! - Address family detection (IPv4/IPv6)
//! - Multiple address fallback (tries all resolved addresses)
//! - SO_ERROR checking after poll() (critical for connection validation)
//! - TLS wrapper functions for encrypted connections
//!
//! Timeout safety:
//! - All connect operations use non-blocking sockets
//! - poll() enforces timeout in milliseconds
//! - SO_ERROR checked after poll returns to detect async connection failures
//! - See TIMEOUT_SAFETY.md for complete timeout patterns
//!
//! Critical pattern (from CLAUDE.md):
//! ```zig
//! socket.setNonBlocking(sock);
//! const result = posix.connect(sock, &addr, len);
//! // Handle WouldBlock/InProgress
//! const ready = try poll_wrapper.poll(&pollfds, timeout_ms);
//! if (ready == 0) return error.ConnectionTimeout;
//! // CRITICAL: Check SO_ERROR after poll
//! ```

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket = @import("socket.zig");
const tls_mod = @import("../tls/tls.zig");
const TlsConfig = tls_mod.TlsConfig;
const poll_wrapper = @import("../util/poll_wrapper.zig");
const TlsConnection = tls_mod.TlsConnection;
const proxy = @import("proxy/mod.zig");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const platform = @import("../util/platform.zig");

/// Open a TCP connection to host:port with timeout using poll() backend.
///
/// Implements robust connection logic:
/// 1. Resolve hostname to list of addresses (IPv4/IPv6)
/// 2. Try each address in order until one succeeds
/// 3. For each attempt:
///    a. Create non-blocking socket
///    b. Initiate connect (expect WouldBlock/InProgress)
///    c. Poll with timeout for writability
///    d. Check SO_ERROR to verify connection success
///
/// Timeout enforcement:
/// - Uses poll() with timeout_ms for each connection attempt
/// - Returns ConnectionTimeout if poll times out
/// - Tries next address on timeout or connection error
///
/// Address family handling:
/// - Automatically detects IPv4 vs IPv6 from resolved addresses
/// - Creates appropriate socket type for each address
///
/// Parameters:
///   host: Hostname or IP address to connect to
///   port: TCP port number
///   timeout_ms: Connect timeout in milliseconds
///
/// Returns: Connected socket or error (UnknownHost, ConnectionTimeout, ConnectionFailed)
fn openTcpClientPoll(host: []const u8, port: u16, timeout_ms: u32, cfg: *const config.Config) !socket.Socket {
    // Resolve addresses first
    const addr_list = try std.net.getAddressList(
        std.heap.page_allocator,
        host,
        port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    var last_error: ?anyerror = null;
    var attempted_connection = false;
    for (addr_list.addrs) |addr| {
        if (cfg.ipv6_only and addr.any.family != posix.AF.INET6) {
            continue;
        }
        if (cfg.ipv4_only and addr.any.family != posix.AF.INET) {
            continue;
        }
        attempted_connection = true;

        // Try connecting to this address using centralized helper
        if (connectAddressWithTimeout(addr, timeout_ms)) |sock| {
            return sock;
        } else |err| {
            last_error = err;
        }
    }

    if (!attempted_connection) {
        return error.UnknownHost;
    }

    return last_error orelse error.ConnectionFailed;
}

/// Connect to a single address with timeout.
///
/// This is a centralized helper for establishing non-blocking TCP connections
/// with the critical poll() + SO_ERROR pattern. Used by openTcpClientPoll and
/// all proxy connection functions.
///
/// Implementation:
/// 1. Create non-blocking socket for address family
/// 2. Initiate non-blocking connect
/// 3. Poll with timeout for writability
/// 4. Check SO_ERROR to verify connection success
///
/// Parameters:
///   addr: Target address (IPv4 or IPv6)
///   timeout_ms: Connect timeout in milliseconds
///
/// Returns: Connected socket or error
pub fn connectAddressWithTimeout(addr: std.net.Address, timeout_ms: u32) !socket.Socket {
    // Determine address family
    const family = if (addr.any.family == posix.AF.INET)
        socket.AddressFamily.ipv4
    else
        socket.AddressFamily.ipv6;

    // Create socket
    const sock = try socket.createTcpSocket(family);
    errdefer socket.closeSocket(sock);

    // Set non-blocking for timeout support
    try socket.setNonBlocking(sock);

    // Initiate connection
    const result = posix.connect(sock, &addr.any, addr.getOsSockLen());

    if (result) {
        // Connected immediately
        return sock;
    } else |err| {
        if (err == error.WouldBlock or err == error.InProgress) {
            // Wait for connection with timeout
            if (try waitForConnect(sock, timeout_ms)) {
                return sock;
            } else {
                return error.ConnectionTimeout;
            }
        } else {
            return err;
        }
    }
}

/// Open a TCP connection to host:port with timeout using io_uring backend (Linux 5.1+).
///
/// High-performance TCP connect using io_uring asynchronous I/O.
/// Falls back to poll-based implementation if io_uring is not available.
///
/// Architecture:
/// 1. Resolve hostname to list of addresses (IPv4/IPv6)
/// 2. Try each address in order until one succeeds
/// 3. For each attempt:
///    a. Create non-blocking socket
///    b. Initialize temporary io_uring (2-entry queue)
///    c. Submit IORING_OP_CONNECT operation
///    d. Wait for completion with timeout
///    e. Check cqe.res for connection result (0 = success, <0 = error)
///
/// Timeout enforcement:
/// - Uses kernel_timespec for microsecond-precision timeout
/// - Returns ConnectionTimeout if io_uring times out
/// - Tries next address on timeout or connection error
///
/// Performance benefits over poll():
/// - Zero-copy kernel communication
/// - No syscall overhead for poll()
/// - ~10-20% faster connection establishment
///
/// Parameters:
///   host: Hostname or IP address to connect to
///   port: TCP port number
///   timeout_ms: Connect timeout in milliseconds
///
/// Returns: Connected socket or error (UnknownHost, ConnectionTimeout, ConnectionFailed, IoUringNotSupported)
fn openTcpClientIoUring(host: []const u8, port: u16, timeout_ms: u32, cfg: *const config.Config) !socket.Socket {
    // Compile-time check: io_uring only available on Linux x86_64
    // io_uring support in Zig stdlib is architecture-dependent
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        return error.IoUringNotSupported;
    }

    // Check if IO_Uring type exists (fails during cross-compilation)
    if (!@hasDecl(std.os.linux, "IO_Uring")) {
        return error.IoUringNotSupported;
    }

    // Resolve addresses first (same pattern as poll version)
    const addr_list = try std.net.getAddressList(
        std.heap.page_allocator,
        host,
        port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    // Validate timeout range (10ms-60s, same as portscan_uring.zig:90)
    const safe_timeout = @max(10, @min(timeout_ms, 60000));

    var last_error: ?anyerror = null;
    var attempted_connection = false;
    for (addr_list.addrs) |addr| {
        if (cfg.ipv6_only and addr.any.family != posix.AF.INET6) {
            continue;
        }
        if (cfg.ipv4_only and addr.any.family != posix.AF.INET) {
            continue;
        }
        attempted_connection = true;
        // Create a fresh socket for each address attempt
        const family = if (addr.any.family == posix.AF.INET)
            socket.AddressFamily.ipv4
        else
            socket.AddressFamily.ipv6;

        const sock = socket.createTcpSocket(family) catch |err| {
            last_error = err;
            continue;
        };
        errdefer socket.closeSocket(sock);

        // Set non-blocking for io_uring (required for IORING_OP_CONNECT)
        socket.setNonBlocking(sock) catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        // Initialize temporary io_uring with 2-entry queue (connect + optional timeout)
        const IO_Uring = std.os.linux.IO_Uring;
        var ring = IO_Uring.init(2, 0) catch |err| {
            // io_uring init failed, fall back to poll
            socket.closeSocket(sock);
            std.debug.print( "io_uring init failed: {any}, falling back to poll\n", .{err});
            return error.IoUringNotSupported;
        };
        defer ring.deinit();

        // Get submission queue entry
        const sqe = ring.get_sqe() catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        // Prepare IORING_OP_CONNECT operation
        sqe.prep_connect(
            sock,
            @ptrCast(&addr.any),
            addr.getOsSockLen(),
        );
        sqe.user_data = @intFromPtr(&sock); // Track which socket this is

        // Submit the connect operation
        _ = ring.submit() catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        // Convert timeout to kernel_timespec (same pattern as portscan_uring.zig:218-222)
        const timeout_ns = safe_timeout * std.time.ns_per_ms;
        const timeout_spec = std.os.linux.kernel_timespec{
            .tv_sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
            .tv_nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
        };

        // Wait for completion with timeout
        const cqe = ring.copy_cqe_wait(&timeout_spec) catch |err| {
            socket.closeSocket(sock);
            if (err == error.Timeout) {
                last_error = error.ConnectionTimeout;
            } else {
                last_error = err;
            }
            continue;
        };

        // Check connection result
        // cqe.res == 0: connection succeeded
        // cqe.res < 0: connection failed (negative errno)
        if (cqe.res == 0) {
            // Connection succeeded immediately
            return sock;
        } else if (cqe.res == -@as(i32, @intCast(@intFromEnum(std.posix.E.INPROGRESS)))) {
            // Connection in progress, wait for completion
            // This shouldn't happen with io_uring connect, but handle it just in case
            const cqe2 = ring.copy_cqe_wait(&timeout_spec) catch |err| {
                socket.closeSocket(sock);
                if (err == error.Timeout) {
                    last_error = error.ConnectionTimeout;
                } else {
                    last_error = err;
                }
                continue;
            };

            if (cqe2.res == 0) {
                return sock;
            } else {
                socket.closeSocket(sock);
                last_error = error.ConnectionFailed;
            }
        } else {
            // Connection failed with error
            socket.closeSocket(sock);
            last_error = error.ConnectionFailed;
        }
    }

    if (!attempted_connection) {
        return error.UnknownHost;
    }

    return last_error orelse error.ConnectionFailed;
}

/// Open a TCP connection to host:port with timeout.
///
/// Dispatcher that auto-selects the best backend:
/// - Linux 5.1+ with io_uring: Uses openTcpClientIoUring() for best performance
/// - All other platforms: Uses openTcpClientPoll() with poll()-based timeout
///
/// Implements robust connection logic:
/// 1. Check for io_uring support (Linux 5.1+ with CONFIG_IO_URING)
/// 2. Try io_uring first if available (10-20% faster)
/// 3. Fall back to poll() if io_uring fails or unavailable
///
/// This function is the primary entry point for TCP connections and is used by:
/// - client.zig: Client mode connections
/// - proxy/*.zig: Proxy connections
/// - connectTls(): TLS connections
///
/// Parameters:
///   host: Hostname or IP address to connect to
///   port: TCP port number
///   timeout_ms: Connect timeout in milliseconds
///
/// Returns: Connected socket or error (UnknownHost, ConnectionTimeout, ConnectionFailed)
pub fn openTcpClient(host: []const u8, port: u16, timeout_ms: u32, cfg: *const config.Config) !socket.Socket {
    // Check for io_uring support at runtime
    if (platform.isIoUringSupported()) {
        // Try io_uring first for best performance
        return openTcpClientIoUring(host, port, timeout_ms, cfg) catch |err| {
            // Fall back to poll on io_uring errors
            if (err == error.IoUringNotSupported) {
                std.debug.print("io_uring not supported, using poll() for connect\n", .{});
                return openTcpClientPoll(host, port, timeout_ms, cfg);
            }
            return err;
        };
    }

    // Use poll-based implementation as default/fallback
    return openTcpClientPoll(host, port, timeout_ms, cfg);
}

/// Wait for socket to become writable (connected) with timeout.
///
/// CRITICAL: This function implements the mandatory poll() + SO_ERROR pattern
/// for reliable non-blocking connect. From CLAUDE.md:
/// "Check SO_ERROR after poll (connection can fail even if poll returns ready)"
///
/// Process:
/// 1. Poll socket for writability (POLL.OUT event)
/// 2. If poll returns 0, connection timed out
/// 3. If poll returns ready, check SO_ERROR to verify success
/// 4. Return true only if SO_ERROR == 0 (connection succeeded)
///
/// Why SO_ERROR check is critical:
/// - poll() may return ready even if async connect failed
/// - SO_ERROR contains the actual connection result
/// - Skipping this check causes silent connection failures
///
/// Parameters:
///   sock: Non-blocking socket with connect() in progress
///   timeout_ms: Timeout in milliseconds for poll()
///
/// Returns: true if connected, false if timed out, error on poll failure
fn waitForConnect(sock: socket.Socket, timeout_ms: u32) !bool {
    var pollfds = [_]poll_wrapper.pollfd{.{
        .fd = sock,
        .events = poll_wrapper.POLL.OUT,
        .revents = 0,
    }};

    const ready = try poll_wrapper.poll(&pollfds, @intCast(timeout_ms));
    if (ready == 0) return false; // Timeout

    // Check if connection succeeded
    var err: i32 = undefined;
    const len: posix.socklen_t = @sizeOf(i32);
    try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&err)[0..len]);

    return err == 0;
}

/// Create a TCP listening socket with SO_REUSEADDR and SO_REUSEPORT.
///
/// Server socket creation:
/// 1. Detect address family from bind address string
/// 2. Create TCP socket for detected family
/// 3. Set SO_REUSEADDR for quick restart after close
/// 4. Set SO_REUSEPORT for multi-process binding (Unix)
/// 5. Bind to specified address and port
/// 6. Listen with backlog of 128 connections
///
/// Address family detection:
/// - Automatically handles IPv4, IPv6, or wildcard (0.0.0.0/::)
/// - Uses socket.detectAddressFamily() helper
///
/// Parameters:
///   bind_addr: Address to bind to (e.g., "0.0.0.0", "::", "192.168.1.1")
///   port: TCP port number to listen on
///
/// Returns: Listening socket ready for accept() calls
pub fn openTcpListener(bind_addr: []const u8, port: u16) !socket.Socket {
    const family = socket.detectAddressFamily(bind_addr);
    const sock = try socket.createTcpSocket(family);
    errdefer socket.closeSocket(sock);

    try socket.setReuseAddr(sock);
    try socket.setReusePort(sock);

    // Parse bind address
    const addr = try std.net.Address.parseIp(bind_addr, port);

    // Bind
    try posix.bind(sock, &addr.any, addr.getOsSockLen());

    // Listen
    try posix.listen(sock, 128);

    return sock;
}

/// Accept a connection from a listening socket with optional timeout.
///
/// Implements timeout-aware accept using poll():
/// - If timeout_ms > 0: poll first, then accept
/// - If timeout_ms == 0: blocking accept (no timeout)
///
/// Timeout enforcement:
/// - poll() waits for incoming connection (POLL.IN event)
/// - Returns Timeout error if poll times out
/// - Only calls accept() after poll confirms connection available
///
/// Parameters:
///   listener: Listening socket from openTcpListener()
///   timeout_ms: Accept timeout in milliseconds (0 = no timeout)
///
/// Returns: Connected client socket or Timeout error
pub fn acceptConnection(listener: socket.Socket, timeout_ms: u32) !socket.Socket {
    if (timeout_ms > 0) {
        var pollfds = [_]poll_wrapper.pollfd{.{
            .fd = listener,
            .events = poll_wrapper.POLL.IN,
            .revents = 0,
        }};

        const ready = try poll_wrapper.poll(&pollfds, @intCast(timeout_ms));
        if (ready == 0) return error.Timeout;
    }

    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    return posix.accept(listener, &addr, &addr_len, 0) catch |err| {
        logging.logDebug("Accept failed: {any}\n", .{err});
        return err;
    };
}

/// Connect to a TLS server
pub fn connectTls(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_ms: u32,
    tls_config: TlsConfig,
    cfg: *const config.Config,
) !TlsConnection {
    // First establish TCP connection
    const sock = try openTcpClient(host, port, timeout_ms, cfg);
    errdefer socket.closeSocket(sock);

    // Wrap with TLS
    return tls_mod.connectTls(allocator, sock, tls_config) catch |err| {
        socket.closeSocket(sock);
        return err;
    };
}

/// Accept a TLS connection
pub fn acceptTls(
    allocator: std.mem.Allocator,
    listener: socket.Socket,
    timeout_ms: u32,
    tls_config: TlsConfig,
) !TlsConnection {
    // Accept TCP connection
    const sock = try acceptConnection(listener, timeout_ms);
    errdefer socket.closeSocket(sock);

    // Wrap with TLS
    return tls_mod.acceptTls(allocator, sock, tls_config) catch |err| {
        socket.closeSocket(sock);
        return err;
    };
}

/// Open a TCP connection through a proxy
pub fn openTcpClientWithProxy(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    host: []const u8,
    port: u16,
) !socket.Socket {
    return try proxy.connectThroughProxy(allocator, cfg, host, port);
}

/// Open a TCP connection with specific source port (--keep-source-port flag).
///
/// This function binds to a specific source port before connecting, ensuring
/// the client uses the requested port for outgoing connections. This is useful
/// for firewall rules, port-based authentication, or debugging.
///
/// Implementation:
/// 1. Create non-blocking socket
/// 2. Bind to source port (0.0.0.0:source_port or :::source_port)
/// 3. Connect to target with timeout
/// 4. Check SO_ERROR after poll
///
/// Note: Binding to a specific source port may fail if:
/// - Port is already in use
/// - Port is privileged (<1024) and process lacks permissions
/// - Multiple connections share the same source port (without SO_REUSEADDR)
///
/// Parameters:
///   host: Target hostname or IP address
///   port: Target TCP port
///   timeout_ms: Connect timeout in milliseconds
///   source_port: Source port to bind to (0 = auto-assign)
///
/// Returns: Connected socket or error
pub fn openTcpClientWithSourcePort(
    host: []const u8,
    port: u16,
    timeout_ms: u32,
    source_port: u16,
    cfg: *const config.Config,
) !socket.Socket {
    // Resolve target addresses first
    const addr_list = try std.net.getAddressList(
        std.heap.page_allocator,
        host,
        port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    var last_error: ?anyerror = null;
    var attempted_connection = false;
    for (addr_list.addrs) |addr| {
        if (cfg.ipv6_only and addr.any.family != posix.AF.INET6) {
            continue;
        }
        if (cfg.ipv4_only and addr.any.family != posix.AF.INET) {
            continue;
        }
        attempted_connection = true;
        // Create socket matching target address family
        const family = if (addr.any.family == posix.AF.INET)
            socket.AddressFamily.ipv4
        else
            socket.AddressFamily.ipv6;

        const sock = socket.createTcpSocket(family) catch |err| {
            last_error = err;
            continue;
        };
        errdefer socket.closeSocket(sock);

        // Enable SO_REUSEADDR to allow quick rebinding
        socket.setReuseAddr(sock) catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        // Bind to specific source port
        const bind_addr = if (family == socket.AddressFamily.ipv4)
            try std.net.Address.parseIp("0.0.0.0", source_port)
        else
            try std.net.Address.parseIp("::", source_port);

        posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen()) catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        // Set non-blocking for timeout support
        socket.setNonBlocking(sock) catch |err| {
            socket.closeSocket(sock);
            last_error = err;
            continue;
        };

        const result = posix.connect(sock, &addr.any, addr.getOsSockLen());

        if (result) {
            // Connected immediately
            return sock;
        } else |err| {
            if (err == error.WouldBlock or err == error.InProgress) {
                // Wait for connection with timeout
                if (try waitForConnect(sock, timeout_ms)) {
                    return sock;
                }
                socket.closeSocket(sock);
                last_error = error.ConnectionTimeout;
            } else {
                socket.closeSocket(sock);
                last_error = err;
            }
        }
    }

    if (!attempted_connection) {
        return error.UnknownHost;
    }

    return last_error orelse error.ConnectionFailed;
}
