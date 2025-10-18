// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! HTTP CONNECT proxy implementation (RFC 7231 Section 4.3.6).
//!
//! Establishes a TCP tunnel through an HTTP proxy server using the
//! CONNECT method. After successful connection, the proxy becomes
//! transparent and forwards all data bidirectionally.
//!
//! **Protocol Flow:**
//! 1. Client connects to proxy server
//! 2. Client sends: `CONNECT target:port HTTP/1.1`
//! 3. Proxy connects to target
//! 4. Proxy responds: `HTTP/1.1 200 Connection Established`
//! 5. Tunnel active - all subsequent data is forwarded
//!
//! **Authentication:**
//! Supports HTTP Basic authentication via `Proxy-Authorization` header.
//! Credentials are base64-encoded (username:password).
//!
//! **Use Cases:**
//! - HTTPS through corporate proxy
//! - SSH tunneling through HTTP proxy
//! - Any TCP protocol through HTTP infrastructure
//!
//! **Security:**
//! - CONNECT method creates end-to-end encrypted tunnel (for TLS)
//! - Basic auth sends credentials in base64 (use HTTPS to proxy if possible)
//! - Proxy can see connection metadata (target host:port)
//!
//! **References:**
//! - RFC 7231 Section 4.3.6: CONNECT method
//! - RFC 7235: HTTP Authentication
//! - RFC 4648: Base64 encoding

const std = @import("std");
const posix = std.posix;
const socket = @import("../socket.zig");
const tcp = @import("../tcp.zig");
const poll_wrapper = @import("../../util/poll_wrapper.zig");
const logging = @import("../../util/logging.zig");
const config = @import("../../config.zig");

/// Proxy authentication credentials for HTTP Basic authentication.
///
/// **Format:**
/// Sent as: `Proxy-Authorization: Basic base64(username:password)`
///
/// **Security:**
/// Credentials are base64-encoded (NOT encrypted). Use HTTPS connection
/// to proxy server to protect credentials in transit.
pub const ProxyAuth = struct {
    username: []const u8,
    password: []const u8,
};

/// Connect to target through HTTP CONNECT proxy.
///
/// **Parameters:**
/// - `allocator`: Memory allocator for request/response buffers
/// - `proxy_host`: HTTP proxy hostname or IP
/// - `proxy_port`: HTTP proxy port (typically 8080, 3128, or 8888)
/// - `target_host`: Destination hostname or IP
/// - `target_port`: Destination port
/// - `auth`: Optional Basic authentication credentials
/// - `timeout_ms`: Connection timeout in milliseconds
///
/// **Returns:**
/// Socket connected to target through proxy tunnel.
///
/// **Errors:**
/// - `error.UnknownHost`: Proxy hostname resolution failed
/// - `error.ConnectionTimeout`: Proxy connect timeout
/// - `error.ProxyConnectionFailed`: Proxy returned non-200 status
/// - `error.InvalidProxyResponse`: Malformed HTTP response
/// - `error.ProxyTimeout`: Response read timeout (30s)
///
/// **Example:**
/// ```zig
/// const auth = ProxyAuth{ .username = "user", .password = "pass" };
/// const sock = try connect(
///     allocator,
///     "proxy.example.com",
///     8080,
///     "target.com",
///     443,
///     auth,
///     30000
/// );
/// defer socket.closeSocket(sock);
/// // Now use sock for TLS/SSH/etc to target.com:443
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
    // Step 1: Connect to proxy server
    const proxy_sock = try connectToProxy(proxy_host, proxy_port, cfg);
    errdefer socket.closeSocket(proxy_sock);

    // Step 2: Send CONNECT request
    try sendConnectRequest(
        allocator,
        proxy_sock,
        target_host,
        target_port,
        auth,
    );

    // Step 3: Read and parse response
    try readConnectResponse(allocator, proxy_sock);

    // Step 4: Connection established, return socket
    return proxy_sock;
}

    /// Establishes a TCP connection to the proxy server.
    ///
    /// This function resolves the proxy's hostname, iterates through the available
    /// addresses, and attempts to connect to each one until a connection succeeds.
    /// It respects the `--ipv4-only` and `--ipv6-only` flags and uses the
    /// configured connection timeout.
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

    /// Constructs and sends the `CONNECT` request to the proxy server.
    ///
    /// This function builds the HTTP `CONNECT` request string, including the
    /// `Host` header and an optional `Proxy-Authorization` header for Basic
    /// authentication. It then sends the complete request over the socket.
    fn sendConnectRequest(
    allocator: std.mem.Allocator,
    sock: socket.Socket,
    target_host: []const u8,
    target_port: u16,
    auth: ?ProxyAuth,
) !void {
    var request = std.ArrayList(u8){};
    defer request.deinit(allocator);

    // Build CONNECT request
    try request.writer(allocator).print("CONNECT {s}:{d} HTTP/1.1\r\n", .{ target_host, target_port });
    try request.writer(allocator).print("Host: {s}:{d}\r\n", .{ target_host, target_port });

    // Add authentication if provided
    if (auth) |credentials| {
        const auth_str = try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ credentials.username, credentials.password },
        );
        errdefer allocator.free(auth_str);

        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(auth_str.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);

        _ = encoder.encode(encoded, auth_str);

        try request.writer(allocator).print("Proxy-Authorization: Basic {s}\r\n", .{encoded});

        allocator.free(encoded);
        allocator.free(auth_str);
    }

    try request.appendSlice(allocator, "\r\n");

    // Send request
    const bytes_to_send = request.items;
    var sent: usize = 0;
    while (sent < bytes_to_send.len) {
        const n = try posix.send(sock, bytes_to_send[sent..], 0);
        sent += n;
    }
}

/// Read and validate HTTP CONNECT response.
///
/// **TCP Fragmentation Handling:**
/// HTTP responses can be fragmented across multiple TCP packets.
/// This function implements buffered reading, continuously receiving
/// data until the end-of-headers marker (\r\n\r\n) is detected.
///
/// **Timeout Protection:**
/// Uses poll() with 30-second timeout for each recv() attempt.
/// If any individual recv() times out, returns error.ProxyTimeout.
///
/// **Edge Cases:**
/// - Partial response received: Continues reading until complete
/// - Buffer overflow: Returns error if response exceeds 4KB
/// - Connection closed early: Returns error.UnexpectedEof
/// - Malformed response: Returns error.InvalidProxyResponse
fn readConnectResponse(_: std.mem.Allocator, sock: socket.Socket) !void {
    var buffer: [4096]u8 = undefined;
    var received: usize = 0;

    // CRITICAL: Buffered reading loop to handle TCP fragmentation
    // TCP is a stream protocol - response may arrive in multiple packets
    // Continue reading until we find end-of-headers marker (\r\n\r\n)
    while (received < buffer.len) {
        // Poll with timeout before each recv (30s timeout)
        var pollfds = [_]poll_wrapper.pollfd{.{
            .fd = sock,
            .events = poll_wrapper.POLL.IN,
            .revents = 0,
        }};

        const ready = try poll_wrapper.poll(&pollfds, 30000);
        if (ready == 0) return error.ProxyTimeout;

        // Check for error conditions on socket
        if (pollfds[0].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP | poll_wrapper.POLL.NVAL) != 0) {
            return error.ProxyConnectionClosed;
        }

        // Read next chunk of data
        const n = try posix.recv(sock, buffer[received..], 0);
        if (n == 0) return error.UnexpectedEof; // Connection closed before complete headers

        received += n;

        // Check if we have complete headers (end marker: \r\n\r\n)
        if (std.mem.indexOf(u8, buffer[0..received], "\r\n\r\n")) |_| {
            break; // Complete HTTP headers received
        }

        // If we've filled the buffer and still no end-of-headers, response is too large
        if (received == buffer.len) {
            return error.InvalidProxyResponse; // Response exceeds buffer size
        }
    }

    // Parse HTTP status line (now safe - we have complete headers)
    const response = buffer[0..received];
    const status_line_end = std.mem.indexOf(u8, response, "\r\n") orelse return error.InvalidProxyResponse;
    const status_line = response[0..status_line_end];

    // Check for "HTTP/1.x 200"
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) {
        return error.InvalidProxyResponse;
    }

    // Find status code
    const space_idx = std.mem.indexOf(u8, status_line, " ") orelse return error.InvalidProxyResponse;
    const status_code_start = space_idx + 1;
    const status_code_end = std.mem.indexOfPos(u8, status_line, status_code_start, " ") orelse status_line.len;

    const status_code_str = status_line[status_code_start..status_code_end];
    const status_code = std.fmt.parseInt(u16, status_code_str, 10) catch return error.InvalidProxyResponse;

    if (status_code != 200) {
        std.debug.print("Proxy returned status code: {d}\n", .{status_code});
        return error.ProxyConnectionFailed;
    }
}

/// Parse proxy address from "host:port" format.
///
/// **Parameters:**
/// - `proxy_str`: String in format "hostname:port" or "IP:port"
///
/// **Returns:**
/// Struct with separated host and port fields.
///
/// **Errors:**
/// - `error.InvalidProxyFormat`: Missing colon or malformed
///
/// **Examples:**
/// - "proxy.example.com:8080" → { "proxy.example.com", 8080 }
/// - "192.168.1.1:3128" → { "192.168.1.1", 3128 }
/// - "[::1]:8888" → { "[::1]", 8888 } (IPv6)
pub fn parseProxyAddress(_: std.mem.Allocator, proxy_str: []const u8) !struct { host: []const u8, port: u16 } {
    const colon_idx = std.mem.lastIndexOf(u8, proxy_str, ":") orelse return error.InvalidProxyFormat;

    const host = proxy_str[0..colon_idx];
    const port_str = proxy_str[colon_idx + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    return .{ .host = host, .port = port };
}

/// Parse proxy authentication credentials from "username:password" format.
///
/// **Parameters:**
/// - `auth_str`: Credentials string in format "user:pass"
///
/// **Returns:**
/// `ProxyAuth` struct with separated username and password.
///
/// **Errors:**
/// - `error.InvalidAuthFormat`: Missing colon separator
///
/// **Example:**
/// ```zig
/// const auth = try parseProxyAuth(allocator, "alice:secret123");
/// // auth.username = "alice"
/// // auth.password = "secret123"
/// ```
pub fn parseProxyAuth(_: std.mem.Allocator, auth_str: []const u8) !ProxyAuth {
    const colon_idx = std.mem.indexOf(u8, auth_str, ":") orelse return error.InvalidAuthFormat;

    return ProxyAuth{
        .username = auth_str[0..colon_idx],
        .password = auth_str[colon_idx + 1 ..],
    };
}
