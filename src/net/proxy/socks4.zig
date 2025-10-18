// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! SOCKS4 proxy protocol implementation.
//!
//! **⚠️ LEGACY PROTOCOL - IPv4 ONLY ⚠️**
//!
//! SOCKS4 is an older proxy protocol with significant limitations:
//! - **IPv4 only**: Cannot connect to IPv6 targets
//! - **No authentication**: Only optional user-id field
//! - **No DNS resolution**: Target must be resolved to IPv4 before request
//!
//! **Protocol Format:**
//! ```
//! Request:
//! +-----+-----+----------+----------+----------+-------+
//! | VER | CMD | DST.PORT | DST.ADDR | USER-ID  | NULL  |
//! +-----+-----+----------+----------+----------+-------+
//! |  1  |  1  |    2     |    4     | variable |   1   |
//! +-----+-----+----------+----------+----------+-------+
//!
//! Response:
//! +-----+-----+----------+----------+
//! | VER | REP | BND.PORT | BND.ADDR |
//! +-----+-----+----------+----------+
//! |  1  |  1  |    2     |    4     |
//! +-----+-----+----------+----------+
//! ```
//!
//! **Commands:**
//! - CMD_CONNECT (0x01): Establish TCP connection
//! - CMD_BIND (0x02): Bind port for incoming connection
//!
//! **Reply Codes:**
//! - 90: Request granted
//! - 91: Request rejected or failed
//! - 92: Identd connection failed
//! - 93: Identd user-id mismatch
//!
//! **Use Cases:**
//! - Legacy proxy systems that don't support SOCKS5
//! - Simplified proxy scenarios where IPv4 is sufficient
//!
//! **Recommendation:**
//! Use SOCKS5 for new deployments (supports IPv6, auth, DNS resolution).

const std = @import("std");
const posix = std.posix;
const socket = @import("../socket.zig");
const tcp = @import("../tcp.zig");
const poll_wrapper = @import("../../util/poll_wrapper.zig");
const logging = @import("../../util/logging.zig");
const config = @import("../../config.zig");

// SOCKS4 protocol constants
const SOCKS4_VERSION: u8 = 0x04;
const CMD_CONNECT: u8 = 0x01;
const CMD_BIND: u8 = 0x02;

// Reply codes
const REP_GRANTED: u8 = 90;
const REP_REJECTED: u8 = 91;
const REP_IDENT_FAILED: u8 = 92;
const REP_IDENT_MISMATCH: u8 = 93;

/// Connect to target through SOCKS4 proxy.
///
/// **⚠️ IPv4 LIMITATION:**
/// SOCKS4 only supports IPv4. Hostnames are resolved to IPv4 before
/// sending request. If target has only IPv6 address, connection fails.
///
/// **Parameters:**
/// - `allocator`: Memory allocator for hostname resolution
/// - `proxy_host`: SOCKS4 proxy hostname or IP
/// - `proxy_port`: SOCKS4 proxy port (typically 1080)
/// - `target_host`: Destination hostname or IPv4 address
/// - `target_port`: Destination port
/// - `user_id`: Optional user identifier (empty string if none)
/// - `timeout_ms`: Connection timeout in milliseconds
///
/// **Returns:**
/// Socket connected to target through SOCKS4 proxy.
///
/// **Errors:**
/// - `error.NoIpv4Address`: Target has no IPv4 address
/// - `error.Socks4ConnectionFailed`: Proxy rejected request
/// - `error.ConnectionTimeout`: Proxy connect timeout
/// - `error.InvalidProxyResponse`: Malformed response
///
/// **Protocol Flow:**
/// 1. Resolve target to IPv4 address
/// 2. Connect to SOCKS4 proxy
/// 3. Send CONNECT request (version, cmd, port, IP, user-id)
/// 4. Receive response (8 bytes: null, reply, port, IP)
/// 5. Check reply code (90 = success)
///
/// **Example:**
/// ```zig
/// const sock = try connect(
///     allocator,
///     "socks4.example.com",
///     1080,
///     "target.com",  // Will be resolved to IPv4
///     80,
///     "",  // No user-id
///     30000
/// );
/// ```
pub fn connect(
    allocator: std.mem.Allocator,
    proxy_host: []const u8,
    proxy_port: u16,
    target_host: []const u8,
    target_port: u16,
    user_id: []const u8,
    cfg: *const config.Config,
) !socket.Socket {
    // Step 1: Connect to SOCKS4 proxy
    const sock = try connectToProxy(proxy_host, proxy_port, cfg);
    errdefer socket.closeSocket(sock);

    // Step 2: Resolve target to IPv4 (SOCKS4 requires IPv4)
    const target_addr = try resolveToIpv4(allocator, target_host);

    // Step 3: Send CONNECT request
    try sendConnectRequest(sock, target_addr, target_port, user_id);

    // Step 4: Read response
    try readConnectResponse(sock);

    // Step 5: Connection established
    return sock;
}

fn connectToProxy(host: []const u8, port: u16, cfg: *const config.Config) !socket.Socket {
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

        // Use centralized connection helper from tcp.zig
        if (tcp.connectAddressWithTimeout(addr, cfg.connect_timeout)) |sock| {
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

    /// Resolves a hostname to its first available IPv4 address.
    ///
    /// SOCKS4 requires the client to provide a destination IPv4 address. This
    /// function first attempts to parse the host as a literal IPv4 address. If
    /// that fails, it performs a DNS lookup and returns the first IPv4 address
    /// found in the results.
    ///
    /// Returns `error.NoIpv4Address` if the host has no A records.
    fn resolveToIpv4(allocator: std.mem.Allocator, host: []const u8) ![4]u8 {
    // Try parsing as IPv4 first
    if (std.net.Address.parseIp4(host, 0)) |addr| {
        return @as(*const [4]u8, @ptrCast(&addr.in.sa.addr)).*;
    } else |_| {
        // Not a direct IPv4, need to resolve
        const addr_list = try std.net.getAddressList(allocator, host, 0);
        defer addr_list.deinit();

        // Find first IPv4 address
        for (addr_list.addrs) |addr| {
            if (addr.any.family == posix.AF.INET) {
                return @as(*const [4]u8, @ptrCast(&addr.in.sa.addr)).*;
            }
        }

        return error.NoIpv4Address;
    }
}

    /// Constructs and sends the SOCKS4 `CONNECT` request packet.
    ///
    /// This function assembles the SOCKS4 request packet, which includes the
    /// protocol version, command code, destination port and address, and a
    /// null-terminated user ID. It then sends the packet to the proxy server.
    fn sendConnectRequest(
    sock: socket.Socket,
    target_addr: [4]u8,
    target_port: u16,
    user_id: []const u8,
) !void {
    var request: [512]u8 = undefined;
    var idx: usize = 0;

    // Version
    request[idx] = SOCKS4_VERSION;
    idx += 1;

    // Command (CONNECT)
    request[idx] = CMD_CONNECT;
    idx += 1;

    // Port (big-endian)
    request[idx] = @intCast((target_port >> 8) & 0xFF);
    idx += 1;
    request[idx] = @intCast(target_port & 0xFF);
    idx += 1;

    // IPv4 address
    @memcpy(request[idx..][0..4], &target_addr);
    idx += 4;

    // User ID (null-terminated)
    if (user_id.len > 0) {
        @memcpy(request[idx..][0..user_id.len], user_id);
        idx += user_id.len;
    }
    request[idx] = 0;
    idx += 1;

    // Send request
    _ = try posix.send(sock, request[0..idx], 0);
}

    /// Reads and validates the 8-byte response from the SOCKS4 server.
    ///
    /// This function waits for the response using `poll` with a timeout, reads
    /// the fixed-size response packet, and checks the reply code. A reply code
    /// of `90` indicates success; any other code results in an error.
    fn readConnectResponse(sock: socket.Socket) !void {
    var response: [8]u8 = undefined;

    var pollfds = [_]poll_wrapper.pollfd{.{
        .fd = sock,
        .events = poll_wrapper.POLL.IN,
        .revents = 0,
    }};

    const ready = try poll_wrapper.poll(&pollfds, 30000);
    if (ready == 0) return error.ProxyTimeout;

    const n = try posix.recv(sock, &response, 0);
    if (n != 8) return error.InvalidProxyResponse;

    // Response format:
    // Byte 0: null byte (should be 0)
    // Byte 1: reply code
    // Bytes 2-3: destination port (ignored)
    // Bytes 4-7: destination IP (ignored)

    const reply = response[1];

    if (reply != REP_GRANTED) {
        const err_msg = switch (reply) {
            REP_REJECTED => "Request rejected or failed",
            REP_IDENT_FAILED => "Request rejected because SOCKS server cannot connect to identd",
            REP_IDENT_MISMATCH => "Request rejected because identd reported different user-id",
            else => "Unknown error",
        };
        std.debug.print( "SOCKS4 error: {s}\n", .{err_msg});
        return error.Socks4ConnectionFailed;
    }
}
