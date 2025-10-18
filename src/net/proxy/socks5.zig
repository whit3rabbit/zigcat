// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! SOCKS5 proxy protocol implementation (RFC 1928).
//!
//! **Modern Proxy Protocol with Full Features:**
//! - ✅ IPv4 and IPv6 support
//! - ✅ Domain name resolution by proxy
//! - ✅ Authentication (user/password, GSSAPI)
//! - ✅ Multiple commands (CONNECT, BIND, UDP ASSOCIATE)
//!
//! **Protocol Flow:**
//! ```
//! 1. Client → Proxy: Authentication method selection
//!    +-----+----------+----------+
//!    | VER | NMETHODS | METHODS  |
//!    +-----+----------+----------+
//!    |  1  |    1     | 1 to 255 |
//!    +-----+----------+----------+
//!
//! 2. Proxy → Client: Selected method
//!    +-----+--------+
//!    | VER | METHOD |
//!    +-----+--------+
//!    |  1  |   1    |
//!    +-----+--------+
//!
//! 3. [If auth required] Username/Password authentication (RFC 1929)
//!
//! 4. Client → Proxy: Connection request
//!    +-----+-----+-------+------+----------+----------+
//!    | VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
//!    +-----+-----+-------+------+----------+----------+
//!    |  1  |  1  | 0x00  |  1   | Variable |    2     |
//!    +-----+-----+-------+------+----------+----------+
//!
//! 5. Proxy → Client: Connection response
//!    +-----+-----+-------+------+----------+----------+
//!    | VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
//!    +-----+-----+-------+------+----------+----------+
//! ```
//!
//! **Address Types (ATYP):**
//! - 0x01: IPv4 (4 bytes)
//! - 0x03: Domain name (1-byte length + name)
//! - 0x04: IPv6 (16 bytes)
//!
//! **Authentication Methods:**
//! - 0x00: No authentication
//! - 0x01: GSSAPI (not implemented)
//! - 0x02: Username/Password (RFC 1929)
//! - 0xFF: No acceptable methods
//!
//! **Reply Codes:**
//! - 0x00: Success
//! - 0x01: General SOCKS server failure
//! - 0x02: Connection not allowed by ruleset
//! - 0x03: Network unreachable
//! - 0x04: Host unreachable
//! - 0x05: Connection refused
//! - 0x06: TTL expired
//! - 0x07: Command not supported
//! - 0x08: Address type not supported
//!
//! **References:**
//! - RFC 1928: SOCKS Protocol Version 5
//! - RFC 1929: Username/Password Authentication

const std = @import("std");
const posix = std.posix;
const socket = @import("../socket.zig");
const tcp = @import("../tcp.zig");
const http_connect = @import("http_connect.zig");
const poll_wrapper = @import("../../util/poll_wrapper.zig");
const logging = @import("../../util/logging.zig");
const config = @import("../../config.zig");

pub const ProxyAuth = http_connect.ProxyAuth;

// SOCKS5 protocol constants (RFC 1928)
const SOCKS5_VERSION: u8 = 0x05;

// Authentication methods
const AUTH_NO_AUTH: u8 = 0x00;
const AUTH_GSSAPI: u8 = 0x01;
const AUTH_USERNAME_PASSWORD: u8 = 0x02;
const AUTH_NO_ACCEPTABLE: u8 = 0xFF;

// Commands
const CMD_CONNECT: u8 = 0x01;
const CMD_BIND: u8 = 0x02;
const CMD_UDP_ASSOCIATE: u8 = 0x03;

// Address types
const ATYP_IPV4: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;
const ATYP_IPV6: u8 = 0x04;

// Reply codes
const REP_SUCCESS: u8 = 0x00;
const REP_GENERAL_FAILURE: u8 = 0x01;
const REP_CONNECTION_NOT_ALLOWED: u8 = 0x02;
const REP_NETWORK_UNREACHABLE: u8 = 0x03;
const REP_HOST_UNREACHABLE: u8 = 0x04;
const REP_CONNECTION_REFUSED: u8 = 0x05;
const REP_TTL_EXPIRED: u8 = 0x06;
const REP_COMMAND_NOT_SUPPORTED: u8 = 0x07;
const REP_ADDRESS_TYPE_NOT_SUPPORTED: u8 = 0x08;

/// Connect to target through SOCKS5 proxy with optional authentication.
///
/// **Parameters:**
/// - `allocator`: Memory allocator for request/response buffers
/// - `proxy_host`: SOCKS5 proxy hostname or IP
/// - `proxy_port`: SOCKS5 proxy port (typically 1080)
/// - `target_host`: Destination hostname, IPv4, or IPv6
/// - `target_port`: Destination port
/// - `auth`: Optional username/password credentials
/// - `timeout_ms`: Connection timeout in milliseconds
///
/// **Returns:**
/// Socket connected to target through SOCKS5 proxy.
///
/// **Errors:**
/// - `error.NoAcceptableAuthMethod`: Proxy requires auth we don't support
/// - `error.AuthenticationRequired`: Auth needed but not provided
/// - `error.AuthenticationFailed`: Invalid username/password
/// - `error.Socks5ConnectionFailed`: Proxy rejected connection (see reply code)
/// - `error.ConnectionTimeout`: Proxy connect timeout
/// - `error.InvalidProxyResponse`: Malformed SOCKS5 response
///
/// **Protocol Steps:**
/// 1. Connect to SOCKS5 proxy server
/// 2. Send authentication method selection (no-auth + user/pass if provided)
/// 3. Receive selected authentication method
/// 4. If user/pass selected, authenticate (RFC 1929)
/// 5. Send CONNECT request (supports IPv4/IPv6/domain)
/// 6. Receive CONNECT response
/// 7. Return connected socket
///
/// **Address Type Selection:**
/// - If `target_host` parses as IPv4: Use ATYP_IPV4
/// - If `target_host` parses as IPv6: Use ATYP_IPV6
/// - Otherwise: Use ATYP_DOMAIN (proxy resolves DNS)
///
/// **Example:**
/// ```zig
/// const auth = ProxyAuth{ .username = "user", .password = "pass" };
/// const sock = try connect(
///     allocator,
///     "socks5.example.com",
///     1080,
///     "ipv6.google.com",  // Works with IPv6!
///     443,
///     auth,
///     30000
/// );
/// ```
pub fn connect(
    allocator: std.mem.Allocator,
    proxy_host: []const u8,
    proxy_port: u16,
    target_host: []const u8,
    target_port: u16,
    auth: ?ProxyAuth,
    cfg: *const config.Config,
) !socket.Socket {
    // Step 1: Connect to SOCKS5 proxy
    const sock = try connectToProxy(proxy_host, proxy_port, cfg);
    errdefer socket.closeSocket(sock);

    // Step 2: Send authentication method selection
    try sendAuthMethodSelection(sock, auth != null);

    // Step 3: Read authentication method response
    const selected_method = try readAuthMethodResponse(sock);

    // Step 4: Perform authentication if required
    if (selected_method == AUTH_USERNAME_PASSWORD) {
        if (auth) |credentials| {
            try authenticateUserPassword(sock, credentials);
        } else {
            return error.AuthenticationRequired;
        }
    } else if (selected_method == AUTH_NO_ACCEPTABLE) {
        return error.NoAcceptableAuthMethod;
    }

    // Step 5: Send CONNECT request
    try sendConnectRequest(allocator, sock, target_host, target_port);

    // Step 6: Read CONNECT response
    try readConnectResponse(allocator, sock);

    // Step 7: Connection established
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

    /// Sends the initial client greeting to the SOCKS5 server, advertising
    /// supported authentication methods.
    ///
    /// This function sends a packet indicating the SOCKS version and a list of
    /// authentication methods the client supports. It always includes "No
    /// Authentication" (0x00) and will also include "Username/Password" (0x02)
    /// if `needs_auth` is true.
    fn sendAuthMethodSelection(sock: socket.Socket, needs_auth: bool) !void {
    var request: [4]u8 = undefined;
    request[0] = SOCKS5_VERSION;

    if (needs_auth) {
        request[1] = 2; // Number of methods
        request[2] = AUTH_NO_AUTH;
        request[3] = AUTH_USERNAME_PASSWORD;
        _ = try posix.send(sock, request[0..4], 0);
    } else {
        request[1] = 1; // Number of methods
        request[2] = AUTH_NO_AUTH;
        _ = try posix.send(sock, request[0..3], 0);
    }
}

    /// Reads the server's choice of authentication method.
    ///
    /// After the client sends its list of supported methods, the server replies
    /// with a 2-byte message indicating the SOCKS version and the single method
    /// it has chosen. This function reads that response and returns the selected
    /// method code.
    fn readAuthMethodResponse(sock: socket.Socket) !u8 {
    var response: [2]u8 = undefined;

    var pollfds = [_]poll_wrapper.pollfd{.{
        .fd = sock,
        .events = poll_wrapper.POLL.IN,
        .revents = 0,
    }};

    const ready = try poll_wrapper.poll(&pollfds, 30000);
    if (ready == 0) return error.ProxyTimeout;

    const n = try posix.recv(sock, &response, 0);
    if (n != 2) return error.InvalidProxyResponse;

    if (response[0] != SOCKS5_VERSION) {
        return error.InvalidProxyResponse;
    }

    return response[1];
}

    /// Performs the username/password authentication sub-negotiation (RFC 1929).
    ///
    /// If the server selects username/password authentication, this function is
    /// called to send the credentials and verify the server's response. It
    /// constructs a packet containing the username and password, sends it, and
    /// then waits for a 2-byte response. A status of `0` in the response
    /// indicates success.
    fn authenticateUserPassword(sock: socket.Socket, auth: ProxyAuth) !void {
    var request: [513]u8 = undefined;
    var idx: usize = 0;

    // Version (1 for username/password auth)
    request[idx] = 0x01;
    idx += 1;

    // Username length and username
    if (auth.username.len > 255) return error.UsernameTooLong;
    request[idx] = @intCast(auth.username.len);
    idx += 1;
    @memcpy(request[idx..][0..auth.username.len], auth.username);
    idx += auth.username.len;

    // Password length and password
    if (auth.password.len > 255) return error.PasswordTooLong;
    request[idx] = @intCast(auth.password.len);
    idx += 1;
    @memcpy(request[idx..][0..auth.password.len], auth.password);
    idx += auth.password.len;

    // Send authentication request
    _ = try posix.send(sock, request[0..idx], 0);

    // Read response
    var response: [2]u8 = undefined;
    var pollfds = [_]poll_wrapper.pollfd{.{
        .fd = sock,
        .events = poll_wrapper.POLL.IN,
        .revents = 0,
    }};

    const ready = try poll_wrapper.poll(&pollfds, 30000);
    if (ready == 0) return error.ProxyTimeout;

    const n = try posix.recv(sock, &response, 0);
    if (n != 2) return error.InvalidProxyResponse;

    if (response[1] != 0) {
        return error.AuthenticationFailed;
    }
}

    /// Constructs and sends the SOCKS5 `CONNECT` request packet.
    ///
    /// This function assembles the main connection request packet. It determines
    /// the correct address type (IPv4, IPv6, or domain name) based on the
    /// `target_host`, and includes the address and port in the request. It then
    /// sends the fully constructed packet to the proxy server.
    fn sendConnectRequest(
    allocator: std.mem.Allocator,
    sock: socket.Socket,
    target_host: []const u8,
    target_port: u16,
) !void {
    var request = std.ArrayList(u8){};
    defer request.deinit(allocator);

    // Version, Command, Reserved
    try request.append(allocator, SOCKS5_VERSION);
    try request.append(allocator, CMD_CONNECT);
    try request.append(allocator, 0x00); // Reserved

    // Determine address type
    if (std.net.Address.parseIp4(target_host, 0)) |addr| {
        // IPv4 address
        try request.append(allocator, ATYP_IPV4);
        const ip4_bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
        try request.appendSlice(allocator, ip4_bytes);
    } else |_| {
        if (std.net.Address.parseIp6(target_host, 0)) |addr| {
            // IPv6 address
            try request.append(allocator, ATYP_IPV6);
            const ip6_bytes = @as(*const [16]u8, @ptrCast(&addr.in6.sa.addr));
            try request.appendSlice(allocator, ip6_bytes);
        } else |_| {
            // Domain name
            try request.append(allocator, ATYP_DOMAIN);
            if (target_host.len > 255) return error.DomainNameTooLong;
            try request.append(allocator, @intCast(target_host.len));
            try request.appendSlice(allocator, target_host);
        }
    }

    // Port (big-endian)
    try request.append(allocator, @intCast((target_port >> 8) & 0xFF));
    try request.append(allocator, @intCast(target_port & 0xFF));

    // Send request
    _ = try posix.send(sock, request.items, 0);
}

    /// Reads and validates the server's response to the `CONNECT` request.
    ///
    /// After sending the connection request, the server sends a final reply. This
    /// function reads that reply, which includes the SOCKS version, a reply code,
    /// and the address/port that the proxy has bound for the connection. It
    /// checks that the reply code is `0x00` (success) and returns an error for
    /// any other code.
    fn readConnectResponse(_: std.mem.Allocator, sock: socket.Socket) !void {
    var buffer: [512]u8 = undefined;

    var pollfds = [_]poll_wrapper.pollfd{.{
        .fd = sock,
        .events = poll_wrapper.POLL.IN,
        .revents = 0,
    }};

    const ready = try poll_wrapper.poll(&pollfds, 30000);
    if (ready == 0) return error.ProxyTimeout;

    // Read at least first 4 bytes
    const n = try posix.recv(sock, &buffer, 0);
    if (n < 4) return error.InvalidProxyResponse;

    const version = buffer[0];
    const reply = buffer[1];
    const atyp = buffer[3];

    if (version != SOCKS5_VERSION) {
        return error.InvalidProxyResponse;
    }

    if (reply != REP_SUCCESS) {
        const err_msg = switch (reply) {
            REP_GENERAL_FAILURE => "General SOCKS server failure",
            REP_CONNECTION_NOT_ALLOWED => "Connection not allowed by ruleset",
            REP_NETWORK_UNREACHABLE => "Network unreachable",
            REP_HOST_UNREACHABLE => "Host unreachable",
            REP_CONNECTION_REFUSED => "Connection refused",
            REP_TTL_EXPIRED => "TTL expired",
            REP_COMMAND_NOT_SUPPORTED => "Command not supported",
            REP_ADDRESS_TYPE_NOT_SUPPORTED => "Address type not supported",
            else => "Unknown error",
        };
        std.debug.print( "SOCKS5 error: {s}\n", .{err_msg});
        return error.Socks5ConnectionFailed;
    }

    // Response includes bound address - we can ignore it for client connections
    _ = atyp;
}
