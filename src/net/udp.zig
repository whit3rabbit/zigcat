//! UDP socket operations for Zigcat.
//!
//! This module provides UDP (User Datagram Protocol) socket functionality for both
//! client and server modes. UDP is a connectionless protocol, so "connections" are
//! virtual associations that set default destination addresses.
//!
//! ## UDP vs TCP
//!
//! - **Connectionless**: No handshake, packets sent independently
//! - **Unreliable**: No delivery guarantees, packets may be lost, duplicated, or reordered
//! - **Message-oriented**: Preserves message boundaries (unlike TCP's byte stream)
//! - **Lower overhead**: No connection state, minimal header overhead
//!
//! ## Client Mode
//!
//! UDP "client connections" use `connect()` to associate a default destination:
//! ```zig
//! const sock = try openUdpClient("example.com", 8080);
//! defer socket.closeSocket(sock);
//! _ = try sendUdp(sock, "hello");  // Sent to example.com:8080
//! ```
//!
//! ## Server Mode
//!
//! UDP servers bind to a local address and receive from any source:
//! ```zig
//! const sock = try openUdpServer("0.0.0.0", 8080);
//! defer socket.closeSocket(sock);
//! var buf: [1024]u8 = undefined;
//! const result = try recvFromUdp(sock, &buf);  // result.addr has sender info
//! ```
//!
//! ## Memory Safety
//! All UDP operations return socket descriptors that must be closed via `socket.closeSocket()`.

const std = @import("std");
const posix = std.posix;
const socket = @import("socket.zig");
const logging = @import("../util/logging.zig");

/// Open a UDP "connection" by creating socket and associating with remote address.
///
/// UDP is connectionless, but calling `connect()` on a UDP socket sets the default
/// destination address for `send()` operations and filters incoming packets.
///
/// ## Parameters
/// - `host`: Remote hostname or IP address
/// - `port`: Remote port number
///
/// ## Returns
/// Socket descriptor associated with the remote endpoint
///
/// ## Errors
/// - `error.UnknownHost`: DNS resolution failed for hostname
/// - Socket creation errors (see `socket.createUdpSocket()`)
/// - `error.ConnectionRefused`: ICMP port unreachable received (rare for UDP)
///
/// ## Memory Safety
/// Caller must close socket via `socket.closeSocket()` or use `defer`/`errdefer`.
///
/// ## Example
/// ```zig
/// const sock = try openUdpClient("dns.google", 53);
/// defer socket.closeSocket(sock);
/// ```
pub fn openUdpClient(host: []const u8, port: u16) !socket.Socket {
    const family = socket.detectAddressFamily(host);
    const sock = try socket.createUdpSocket(family);
    errdefer socket.closeSocket(sock);

    // For UDP client, we "connect" to set the default destination
    const addr_list = try std.net.getAddressList(
        std.heap.page_allocator,
        host,
        port,
    );
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    // Connect UDP socket (sets default destination)
    try posix.connect(sock, &addr_list.addrs[0].any, addr_list.addrs[0].getOsSockLen());

    return sock;
}

/// Create a UDP server socket bound to local address.
///
/// Creates, configures, and binds a UDP socket for receiving datagrams.
/// Automatically enables SO_REUSEADDR and SO_REUSEPORT for server scenarios.
///
/// ## Parameters
/// - `bind_addr`: Local IP address to bind (use "0.0.0.0" for all IPv4 interfaces, "::" for IPv6)
/// - `port`: Local port number
///
/// ## Returns
/// Socket descriptor bound and ready to receive datagrams
///
/// ## Errors
/// - `error.AddressInUse`: Port already in use (even with SO_REUSEADDR)
/// - `error.AddressNotAvailable`: Invalid bind address for this system
/// - `error.PermissionDenied`: Insufficient privileges (ports < 1024 require root)
/// - Socket creation errors (see `socket.createUdpSocket()`)
///
/// ## Socket Configuration
/// - SO_REUSEADDR: Enabled (allows quick restart)
/// - SO_REUSEPORT: Enabled if platform supports (allows multiple servers on same port)
///
/// ## Memory Safety
/// Caller must close socket via `socket.closeSocket()` or use `defer`/`errdefer`.
///
/// ## Example
/// ```zig
/// const sock = try openUdpServer("0.0.0.0", 8080);
/// defer socket.closeSocket(sock);
/// ```
pub fn openUdpServer(bind_addr: []const u8, port: u16) !socket.Socket {
    const family = socket.detectAddressFamily(bind_addr);
    const sock = try socket.createUdpSocket(family);
    errdefer socket.closeSocket(sock);

    try socket.setReuseAddr(sock);
    try socket.setReusePort(sock);

    const addr = try std.net.Address.parseIp(bind_addr, port);
    try posix.bind(sock, &addr.any, addr.getOsSockLen());

    return sock;
}

/// Send data over connected UDP socket.
///
/// Sends datagram to the default destination set by `connect()` or `openUdpClient()`.
/// For unconnected sockets, use `sendToUdp()` instead.
///
/// ## Parameters
/// - `sock`: UDP socket (must be "connected" via connect() or openUdpClient())
/// - `data`: Data buffer to send
///
/// ## Returns
/// Number of bytes sent (may be less than data.len on some platforms)
///
/// ## Errors
/// - `error.WouldBlock`: Socket is non-blocking and send buffer is full
/// - `error.NetworkUnreachable`: No route to destination
/// - `error.MessageTooBig`: Datagram exceeds MTU (typically ~1500 bytes)
/// - Other POSIX send errors
///
/// ## UDP Delivery
/// - **No guarantees**: Packet may be lost, duplicated, or reordered
/// - **Atomic**: Entire datagram sent or none (no partial sends for UDP)
/// - **Size limits**: Practical limit ~1400 bytes to avoid IP fragmentation
///
/// ## Example
/// ```zig
/// const sock = try openUdpClient("example.com", 8080);
/// const sent = try sendUdp(sock, "hello");
/// ```
pub fn sendUdp(sock: socket.Socket, data: []const u8) !usize {
    return posix.send(sock, data, 0) catch |err| {
        logging.logDebug("UDP send failed: {any}\n", .{err});
        return err;
    };
}

/// Receive data from connected UDP socket.
///
/// Receives datagram from the associated remote endpoint (set by connect()).
/// For receiving from any source, use `recvFromUdp()` instead.
///
/// ## Parameters
/// - `sock`: UDP socket (should be "connected" via connect())
/// - `buffer`: Buffer to store received data
///
/// ## Returns
/// Number of bytes received (0 is valid for zero-length datagrams)
///
/// ## Errors
/// - `error.WouldBlock`: Socket is non-blocking and no data available
/// - `error.ConnectionRefused`: ICMP port unreachable received
/// - Other POSIX recv errors
///
/// ## UDP Message Boundaries
/// - **Preserves boundaries**: Each recv() returns exactly one complete datagram
/// - **Truncation**: If buffer too small, excess data is DISCARDED (MSG_TRUNC behavior)
/// - **Recommended**: Use buffers >= 1500 bytes to avoid truncation
///
/// ## Example
/// ```zig
/// var buf: [1500]u8 = undefined;
/// const received = try recvUdp(sock, &buf);
/// const data = buf[0..received];
/// ```
pub fn recvUdp(sock: socket.Socket, buffer: []u8) !usize {
    return posix.recv(sock, buffer, 0) catch |err| {
        logging.logDebug("UDP recv failed: {any}\n", .{err});
        return err;
    };
}

/// Receive data with source address information from any sender.
///
/// Used for server sockets to receive datagrams from any source and identify the sender.
/// Essential for UDP server reply logic.
///
/// ## Parameters
/// - `sock`: UDP socket (typically bound via `openUdpServer()`)
/// - `buffer`: Buffer to store received data
///
/// ## Returns
/// Anonymous struct containing:
/// - `bytes`: Number of bytes received
/// - `addr`: Source address (IP + port) of sender
///
/// ## Errors
/// - `error.WouldBlock`: Socket is non-blocking and no data available
/// - Other POSIX recvfrom errors
///
/// ## Usage Pattern
/// This is the standard server pattern for UDP request-response:
/// ```zig
/// const sock = try openUdpServer("0.0.0.0", 8080);
/// var buf: [1500]u8 = undefined;
/// const result = try recvFromUdp(sock, &buf);
/// const request = buf[0..result.bytes];
/// // Process request...
/// _ = try sendToUdp(sock, response, result.addr);  // Reply to sender
/// ```
///
/// ## Example
/// ```zig
/// var buf: [1500]u8 = undefined;
/// const result = try recvFromUdp(sock, &buf);
/// std.debug.print("Received {} bytes from {}\n", .{result.bytes, result.addr});
/// ```
pub fn recvFromUdp(sock: socket.Socket, buffer: []u8) !struct { bytes: usize, addr: std.net.Address } {
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    const bytes = try posix.recvfrom(sock, buffer, 0, &addr, &addr_len);

    const net_addr = std.net.Address.initPosix(@alignCast(&addr));

    return .{ .bytes = bytes, .addr = net_addr };
}

/// Send data to specific address without "connecting" socket.
///
/// Used for server reply scenarios or client sockets that need to send to multiple destinations.
/// Can be used on any UDP socket, connected or not.
///
/// ## Parameters
/// - `sock`: UDP socket (any state)
/// - `data`: Data buffer to send
/// - `addr`: Destination address (IP + port)
///
/// ## Returns
/// Number of bytes sent (typically equals data.len for UDP)
///
/// ## Errors
/// - `error.WouldBlock`: Socket is non-blocking and send buffer is full
/// - `error.NetworkUnreachable`: No route to destination
/// - `error.MessageTooBig`: Datagram exceeds MTU
/// - Other POSIX sendto errors
///
/// ## Usage Pattern
/// Server reply scenario:
/// ```zig
/// const result = try recvFromUdp(sock, &buf);  // Get request + sender addr
/// const response = "ACK";
/// _ = try sendToUdp(sock, response, result.addr);  // Reply to sender
/// ```
///
/// ## Example
/// ```zig
/// const addr = try std.net.Address.parseIp("192.168.1.100", 8080);
/// const sent = try sendToUdp(sock, "hello", addr);
/// ```
pub fn sendToUdp(sock: socket.Socket, data: []const u8, addr: std.net.Address) !usize {
    return posix.sendto(sock, data, 0, &addr.any, addr.getOsSockLen()) catch |err| {
        logging.logDebug("UDP sendto failed: {any}\n", .{err});
        return err;
    };
}
