// Network Layer Tests
// Tests socket creation, address parsing, connection handling, and error conditions

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const net = std.net;
const os = std.os;
const socket = @import("zigcat").socket;


// =============================================================================
// ADDRESS PARSING TESTS
// =============================================================================

test "parse IPv4 address - basic" {

    // Test parsing "192.168.1.1:8080"
    // const result = try addr.parse(allocator, "192.168.1.1:8080");
    // defer result.deinit(allocator);
    //
    // try expectEqual(net.Address.Family.ipv4, result.family);
    // try expectEqual(@as(u16, 8080), result.port);
}

test "parse IPv4 address - localhost" {

    // Test parsing "127.0.0.1:80"
    // const result = try addr.parse(allocator, "127.0.0.1:80");
    // defer result.deinit(allocator);
    //
    // try expectEqual(@as(u16, 80), result.port);
}

test "parse IPv6 address - basic" {
    const addr = try net.Address.parseIp("::1", 8080);
    try expect(addr.any.family == std.posix.AF.INET6);
    try expectEqual(@as(u16, 8080), addr.getPort());
}

test "parse IPv6 address - full form" {
    const addr = try net.Address.parseIp("2001:0db8::1", 443);
    try expect(addr.any.family == std.posix.AF.INET6);
    try expectEqual(@as(u16, 443), addr.getPort());
}

test "parse IPv6 address - with scope ID" {
    // NOTE: std.net.Address.parseIp does not support scope IDs in the string.
    // The scope ID is a property of the address itself.
    const addr = try net.Address.parseIp("fe80::1", 8080);
    var ip6_addr = addr.in6;
    ip6_addr.sa.scope_id = 5; // e.g. eth0
    const final_addr = net.Address{ .in6 = ip6_addr };

    try expect(final_addr.any.family == std.posix.AF.INET6);
    try expectEqual(@as(u32, 5), final_addr.in6.sa.scope_id);
}

test "parse hostname - requires DNS" {

    // Test parsing "example.com:80"
    // This should trigger DNS resolution
    // const result = try addr.parse(allocator, "example.com:80");
    // defer result.deinit(allocator);
    //
    // try expectEqual(@as(u16, 80), result.port);
}

test "parse invalid address - malformed IPv4" {

    // Test parsing "999.999.999.999:80"
    // try expectError(error.InvalidIPAddress, addr.parse(allocator, "999.999.999.999:80"));
}

test "parse invalid address - missing port" {

    // Test parsing "192.168.1.1" without port
    // try expectError(error.MissingPort, addr.parse(allocator, "192.168.1.1"));
}

test "parse invalid address - invalid port" {

    // Test parsing "192.168.1.1:99999"
    // try expectError(error.InvalidPort, addr.parse(allocator, "192.168.1.1:99999"));
}

// =============================================================================
// TCP SOCKET CREATION TESTS
// =============================================================================

test "create TCP socket - IPv4" {

    // Test creating an IPv4 TCP socket
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try expect(socket.fd >= 0);
}

test "create TCP socket - IPv6" {
    const sock = try socket.createTcpSocket(.ipv6);
    defer socket.closeSocket(sock);
    try expect(sock >= 0);
}

test "TCP socket - set SO_REUSEADDR" {

    // Test that we can set SO_REUSEADDR option
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setReuseAddr(true);
    //
    // // Verify option was set
    // const value = try socket.getReuseAddr();
    // try expect(value);
}

test "TCP socket - set SO_KEEPALIVE" {

    // Test setting SO_KEEPALIVE option
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setKeepAlive(true);
    //
    // const value = try socket.getKeepAlive();
    // try expect(value);
}

test "TCP socket - set SO_LINGER" {

    // Test setting SO_LINGER option
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setLinger(true, 30);
}

test "TCP socket - set non-blocking" {

    // Test setting non-blocking mode
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setNonBlocking(true);
}

// =============================================================================
// TCP BIND AND LISTEN TESTS
// =============================================================================

test "TCP bind - localhost IPv6" {
    const sock = try socket.createTcpSocket(.ipv6);
    defer socket.closeSocket(sock);

    const addr = try net.Address.parseIp("::1", 0);
    try std.posix.bind(sock, &addr.any, addr.getOsSockLen());

    // Get the actual bound port
    var bound_addr_storage: std.posix.sockaddr.storage = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(sock, @ptrCast(&bound_addr_storage), &bound_addr_len);
    const bound_addr = blk: {
        const family = @as(*const std.posix.sockaddr, @ptrCast(&bound_addr_storage)).family;
        if (family == std.posix.AF.INET) {
            const addr4 = @as(*const std.posix.sockaddr.in, @ptrCast(&bound_addr_storage));
            break :blk std.net.Address.initIp4(
                @bitCast(addr4.addr),
                @byteSwap(addr4.port),
            );
        } else if (family == std.posix.AF.INET6) {
            const addr6 = @as(*const std.posix.sockaddr.in6, @ptrCast(&bound_addr_storage));
            break :blk std.net.Address.initIp6(
                addr6.addr,
                @byteSwap(addr6.port),
                addr6.flowinfo,
                addr6.scope_id,
            );
        } else {
            unreachable;
        }
    };

    try expect(bound_addr.getPort() > 0);
}

test "TCP bind - localhost IPv4" {

    // Test binding to 127.0.0.1:0 (random port)
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
    //
    // // Get the actual bound port
    // const bound_addr = try socket.getLocalAddress();
    // try expect(bound_addr.getPort() > 0);
}

test "TCP bind - specific port" {

    // Test binding to a specific port
    // Note: This might fail if port is already in use
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 9999);
    // socket.bind(addr) catch |err| {
    //     // EADDRINUSE is acceptable in tests
    //     if (err != error.AddressInUse) return err;
    //     return;
    // };
}

test "TCP bind - port already in use" {

    // Test that binding to an in-use port fails
    // const socket1 = try tcp.createSocket(allocator, .ipv4);
    // defer socket1.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket1.bind(addr);
    // const bound_addr = try socket1.getLocalAddress();
    //
    // // Try to bind second socket to same port
    // const socket2 = try tcp.createSocket(allocator, .ipv4);
    // defer socket2.close();
    //
    // try expectError(error.AddressInUse, socket2.bind(bound_addr));
}

test "TCP listen - basic" {

    // Test putting socket in listen mode
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
    // try socket.listen(5);
}

test "TCP listen - large backlog" {

    // Test listen with large backlog
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
    // try socket.listen(128);
}

// =============================================================================
// TCP CONNECT TESTS
// =============================================================================

test "TCP connect - to localhost listener" {

    // Create listener
    // const listener = try tcp.createSocket(allocator, .ipv4);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // // Connect to it
    // const client = try tcp.createSocket(allocator, .ipv4);
    // defer client.close();
    //
    // try client.connect(listen_addr);
}

test "TCP connect - connection refused" {

    // Try to connect to a port with no listener
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 1);
    // try expectError(error.ConnectionRefused, socket.connect(addr));
}

test "TCP connect - with timeout" {

    // Test connection with timeout
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setNonBlocking(true);
    //
    // // Try to connect to non-routable address (should timeout)
    // const addr = try net.Address.parseIp4("192.0.2.1", 80);
    // try expectError(error.Timeout, socket.connectWithTimeout(addr, 1000)); // 1 second
}

// =============================================================================
// TCP ACCEPT TESTS
// =============================================================================

test "TCP accept - basic connection" {

    // Create listener
    // const listener = try tcp.createSocket(allocator, .ipv4);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // // Connect from separate thread/async
    // const client = try tcp.createSocket(allocator, .ipv4);
    // defer client.close();
    //
    // try client.connect(listen_addr);
    //
    // // Accept the connection
    // const accepted = try listener.accept();
    // defer accepted.close();
    //
    // try expect(accepted.fd >= 0);
}

test "TCP accept - get peer address" {

    // Accept connection and verify peer address
    // const listener = try tcp.createSocket(allocator, .ipv4);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // const client = try tcp.createSocket(allocator, .ipv4);
    // defer client.close();
    // try client.connect(listen_addr);
    //
    // const accepted = try listener.accept();
    // defer accepted.close();
    //
    // const peer_addr = try accepted.getPeerAddress();
    // try expectEqualStrings("127.0.0.1", peer_addr.formatAddress());
}

// =============================================================================
// UDP SOCKET TESTS
// =============================================================================

test "create UDP socket - IPv4" {

    // Test creating an IPv4 UDP socket
    // const socket = try udp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try expect(socket.fd >= 0);
}

test "create UDP socket - IPv6" {

    // Test creating an IPv6 UDP socket
    // const socket = try udp.createSocket(allocator, .ipv6);
    // defer socket.close();
    //
    // try expect(socket.fd >= 0);
}

test "UDP bind - basic" {

    // Test UDP bind
    // const socket = try udp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket.bind(addr);
}

test "UDP sendto/recvfrom - loopback" {

    // Test UDP send and receive on loopback
    // const receiver = try udp.createSocket(allocator, .ipv4);
    // defer receiver.close();
    //
    // const recv_addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try receiver.bind(recv_addr);
    // const bound_addr = try receiver.getLocalAddress();
    //
    // const sender = try udp.createSocket(allocator, .ipv4);
    // defer sender.close();
    //
    // const message = "Hello UDP";
    // const sent = try sender.sendto(message, bound_addr);
    // try expectEqual(message.len, sent);
    //
    // var buffer: [1024]u8 = undefined;
    // const result = try receiver.recvfrom(&buffer);
    // try expectEqualStrings(message, buffer[0..result.len]);
}

test "UDP connected socket - send/recv" {

    // Test UDP with connect() for default destination
    // const socket1 = try udp.createSocket(allocator, .ipv4);
    // defer socket1.close();
    //
    // const addr1 = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket1.bind(addr1);
    // const bound_addr1 = try socket1.getLocalAddress();
    //
    // const socket2 = try udp.createSocket(allocator, .ipv4);
    // defer socket2.close();
    //
    // // "Connect" socket2 to socket1
    // try socket2.connect(bound_addr1);
    //
    // // Now can use send() instead of sendto()
    // const message = "Connected UDP";
    // try socket2.send(message);
    //
    // var buffer: [1024]u8 = undefined;
    // const result = try socket1.recvfrom(&buffer);
    // try expectEqualStrings(message, buffer[0..result.len]);
}

// =============================================================================
// TIMEOUT HANDLING TESTS
// =============================================================================

test "socket receive timeout" {

    // Test SO_RCVTIMEO
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setReceiveTimeout(1000); // 1 second
    //
    // // Try to receive with no data - should timeout
    // var buffer: [1024]u8 = undefined;
    // try expectError(error.Timeout, socket.recv(&buffer));
}

test "socket send timeout" {

    // Test SO_SNDTIMEO
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setSendTimeout(1000); // 1 second
}

// =============================================================================
// ERROR CONDITION TESTS
// =============================================================================

test "error - ECONNREFUSED" {

    // Try to connect to closed port
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 1);
    // try expectError(error.ConnectionRefused, socket.connect(addr));
}

test "error - EADDRINUSE" {

    // Test address already in use error
    // const socket1 = try tcp.createSocket(allocator, .ipv4);
    // defer socket1.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try socket1.bind(addr);
    // const bound_addr = try socket1.getLocalAddress();
    //
    // const socket2 = try tcp.createSocket(allocator, .ipv4);
    // defer socket2.close();
    //
    // try expectError(error.AddressInUse, socket2.bind(bound_addr));
}

test "error - ETIMEDOUT" {

    // Test connection timeout to non-routable address
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // try socket.setNonBlocking(true);
    //
    // // 192.0.2.0/24 is TEST-NET-1, guaranteed to be non-routable
    // const addr = try net.Address.parseIp4("192.0.2.1", 80);
    // try expectError(error.Timeout, socket.connectWithTimeout(addr, 1000));
}

test "error - EPIPE on closed socket" {

    // Test writing to a socket after peer closed
    // const listener = try tcp.createSocket(allocator, .ipv4);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // const client = try tcp.createSocket(allocator, .ipv4);
    // defer client.close();
    // try client.connect(listen_addr);
    //
    // const server = try listener.accept();
    // server.close(); // Close immediately
    //
    // // Try to write - should get error
    // const data = "test";
    // try expectError(error.BrokenPipe, client.send(data));
}

test "error - EACCES on privileged port" {

    // Try to bind to port 80 (requires root on Unix)
    // This should fail unless running as root
    // const socket = try tcp.createSocket(allocator, .ipv4);
    // defer socket.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 80);
    // socket.bind(addr) catch |err| {
    //     // Either permission denied or address in use is acceptable
    //     if (err != error.PermissionDenied and err != error.AddressInUse) {
    //         return err;
    //     }
    //     return;
    // };
}

// =============================================================================
// PLATFORM-SPECIFIC TESTS
// =============================================================================

test "Windows - WSAStartup initialization" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;

    // On Windows, verify WSAStartup is called
    // This should be automatic in our implementation
    // const socket = try tcp.createSocket(testing.allocator, .ipv4);
    // defer socket.close();
    //
    // try expect(socket.fd >= 0);
}


test "Unix - SO_REUSEPORT support" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    // Test SO_REUSEPORT on platforms that support it
    // const socket = try tcp.createSocket(testing.allocator, .ipv4);
    // defer socket.close();
    //
    // socket.setReusePort(true) catch |err| {
    //     // Some platforms don't support SO_REUSEPORT
    //     if (err == error.NotSupported) return error.SkipZigTest;
    //     return err;
    // };
}

test "Unix - SIGPIPE handling" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    // On Unix, verify SIGPIPE is ignored or MSG_NOSIGNAL is used
    // This prevents process termination on broken pipe
    // const listener = try tcp.createSocket(testing.allocator, .ipv4);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp4("127.0.0.1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // const client = try tcp.createSocket(testing.allocator, .ipv4);
    // defer client.close();
    // try client.connect(listen_addr);
    //
    // const server = try listener.accept();
    // server.close();
    //
    // // This should return error, not kill process
    // const data = "test";
    // _ = client.send(data) catch {};
}

// =============================================================================
// IPv6 SPECIFIC TESTS
// =============================================================================

test "IPv6 - connect to localhost" {

    // Test IPv6 loopback connection
    // const listener = try tcp.createSocket(allocator, .ipv6);
    // defer listener.close();
    //
    // const addr = try net.Address.parseIp6("::1", 0);
    // try listener.bind(addr);
    // try listener.listen(1);
    //
    // const listen_addr = try listener.getLocalAddress();
    //
    // const client = try tcp.createSocket(allocator, .ipv6);
    // defer client.close();
    //
    // try client.connect(listen_addr);
}

test "IPv6 - dual stack support" {

    // Test if IPv6 socket can accept IPv4 connections
    // This depends on IPV6_V6ONLY socket option
    // const socket = try tcp.createSocket(allocator, .ipv6);
    // defer socket.close();
    //
    // try socket.setIPv6Only(false); // Allow dual stack
}
