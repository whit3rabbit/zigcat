//! Proxy support module providing HTTP CONNECT, SOCKS4, and SOCKS5 protocols.
//!
//! This module implements proxy connection establishment for:
//! - **HTTP CONNECT** (RFC 7231 Section 4.3.6): Tunneling via HTTP proxy
//! - **SOCKS4** (Legacy): IPv4-only proxy protocol
//! - **SOCKS5** (RFC 1928): Modern SOCKS with authentication and IPv6
//!
//! **Usage:**
//! ```zig
//! const sock = try proxy.connectThroughProxy(
//!     allocator,
//!     cfg,
//!     "example.com",
//!     443
//! );
//! defer socket.closeSocket(sock);
//! ```
//!
//! **Configuration:**
//! Set these fields in `config.Config`:
//! - `proxy`: Proxy address (format: "host:port")
//! - `proxy_type`: `.http`, `.socks4`, or `.socks5`
//! - `proxy_auth`: Optional "username:password"
//!
//! **Supported Features:**
//! - Authentication (HTTP Basic, SOCKS5 user/pass, SOCKS4 user-id)
//! - IPv4 and IPv6 (SOCKS5 only, SOCKS4 is IPv4-only)
//! - Domain name resolution (SOCKS5 and HTTP CONNECT)
//! - Timeout support for all operations

const std = @import("std");
const socket = @import("../socket.zig");
const config = @import("../../config.zig");

pub const http_connect = @import("http_connect.zig");
pub const socks5 = @import("socks5.zig");
pub const socks4 = @import("socks4.zig");

pub const ProxyAuth = http_connect.ProxyAuth;

/// Connect to target host through configured proxy server.
///
/// **Parameters:**
/// - `allocator`: Memory allocator for transient data
/// - `cfg`: Zigcat configuration (must have proxy settings)
/// - `target_host`: Destination hostname or IP
/// - `target_port`: Destination port
///
/// **Returns:**
/// Connected socket tunneled through proxy to target.
///
/// **Errors:**
/// - `error.NoProxyConfigured`: `cfg.proxy` is null
/// - `error.InvalidProxyFormat`: Proxy address malformed
/// - `error.ConnectionTimeout`: Proxy connect timeout
/// - `error.ProxyConnectionFailed`: Proxy rejected connection
/// - `error.AuthenticationFailed`: Proxy auth failed
///
/// **Protocol Selection:**
/// Based on `cfg.proxy_type`:
/// - `.http`: Uses HTTP CONNECT method
/// - `.socks5`: Uses SOCKS5 protocol (RFC 1928)
/// - `.socks4`: Uses SOCKS4 protocol (IPv4 only)
///
/// **Example:**
/// ```zig
/// var cfg = Config{
///     .proxy = "proxy.example.com:8080",
///     .proxy_type = .http,
///     .proxy_auth = "user:pass",
///     .connect_timeout = 30000,
/// };
/// const sock = try connectThroughProxy(allocator, &cfg, "target.com", 443);
/// ```
pub fn connectThroughProxy(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    target_host: []const u8,
    target_port: u16,
) !socket.Socket {
    const proxy_str = cfg.proxy orelse return error.NoProxyConfigured;

    // Parse proxy address
    const proxy_addr = try http_connect.parseProxyAddress(allocator, proxy_str);

    // Parse authentication if provided
    const auth = if (cfg.proxy_auth) |auth_str|
        try http_connect.parseProxyAuth(allocator, auth_str)
    else
        null;

    // Connect based on proxy type
    return switch (cfg.proxy_type) {
        .http => try http_connect.connect(
            allocator,
            proxy_addr.host,
            proxy_addr.port,
            target_host,
            target_port,
            auth,
            cfg.connect_timeout,
        ),
        .socks5 => try socks5.connect(
            allocator,
            proxy_addr.host,
            proxy_addr.port,
            target_host,
            target_port,
            auth,
            cfg.connect_timeout,
        ),
        .socks4 => blk: {
            // SOCKS4 uses user_id instead of username/password
            const user_id = if (auth) |a| a.username else "";
            break :blk try socks4.connect(
                allocator,
                proxy_addr.host,
                proxy_addr.port,
                target_host,
                target_port,
                user_id,
                cfg.connect_timeout,
            );
        },
    };
}
