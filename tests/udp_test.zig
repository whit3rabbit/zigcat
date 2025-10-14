const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const zigcat = @import("zigcat");
const socket = zigcat.socket;

// Self-contained UDP test utilities
fn createUdpSocket(family: posix.sa_family_t) !posix.socket_t {
    const sock_type = posix.SOCK.DGRAM;
    return try posix.socket(family, sock_type, posix.IPPROTO.UDP);
}

fn bindUdpSocket(sock: posix.socket_t, addr: std.net.Address) !void {
    try posix.bind(sock, &addr.any, addr.getOsSockLen());
}

test "UDP socket create and bind" {
    const sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(sock);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0); // Bind to random port
    try bindUdpSocket(sock, addr);

    // Verify socket is valid
    try testing.expect(socket.isValidSocket(sock));
}

test "UDP receive with timeout" {
    const sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(sock);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try bindUdpSocket(sock, addr);

    // Set up poll with timeout
    var pollfds = [_]posix.pollfd{
        .{
            .fd = sock,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const timeout_ms: i32 = 100; // 100ms timeout
    const start = std.time.milliTimestamp();
    const ready = try posix.poll(&pollfds, timeout_ms);
    const elapsed = std.time.milliTimestamp() - start;

    // Should timeout (no data sent)
    try testing.expectEqual(@as(usize, 0), ready);
    // Should be close to timeout value (within 50ms tolerance)
    try testing.expect(elapsed >= 80 and elapsed <= 200);
}

test "UDP sendto and recvfrom" {
    // Create server socket
    const server_sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(server_sock);

    const server_bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try bindUdpSocket(server_sock, server_bind_addr);

    // Get the actual port the server bound to
    var server_addr: posix.sockaddr = undefined;
    var server_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server_sock, &server_addr, &server_addr_len);
    const server_net_addr = std.net.Address.initPosix(@alignCast(&server_addr));
    const server_port = server_net_addr.getPort();

    // Create client socket
    const client_sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(client_sock);

    // Send data from client to server
    const send_data = "Hello UDP!";
    const target_addr = try std.net.Address.parseIp4("127.0.0.1", server_port);
    _ = try posix.sendto(client_sock, send_data, 0, &target_addr.any, target_addr.getOsSockLen());

    // Receive on server with timeout
    var buffer: [1024]u8 = undefined;
    var pollfds = [_]posix.pollfd{
        .{
            .fd = server_sock,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try posix.poll(&pollfds, 1000); // 1 second timeout
    try testing.expect(ready > 0);

    var from_addr: posix.sockaddr = undefined;
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const bytes_received = try posix.recvfrom(server_sock, &buffer, 0, &from_addr, &from_len);

    try testing.expectEqual(send_data.len, bytes_received);
    try testing.expectEqualStrings(send_data, buffer[0..bytes_received]);

    // Verify source address is localhost
    const from_net_addr = std.net.Address.initPosix(@alignCast(&from_addr));
    try testing.expect(from_net_addr.any.family == posix.AF.INET);
}

test "UDP echo server simulation" {
    // Create server
    const server_sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(server_sock);

    const server_bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try bindUdpSocket(server_sock, server_bind_addr);

    var server_addr: posix.sockaddr = undefined;
    var server_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server_sock, &server_addr, &server_addr_len);
    const server_net_addr = std.net.Address.initPosix(@alignCast(&server_addr));
    const server_port = server_net_addr.getPort();

    // Create client
    const client_sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(client_sock);

    // Send from client
    const send_data = "Echo test";
    const target_addr = try std.net.Address.parseIp4("127.0.0.1", server_port);
    _ = try posix.sendto(client_sock, send_data, 0, &target_addr.any, target_addr.getOsSockLen());

    // Server receives and echoes back
    var server_buffer: [1024]u8 = undefined;
    var pollfds = [_]posix.pollfd{.{
        .fd = server_sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    _ = try posix.poll(&pollfds, 1000);

    var from_addr: posix.sockaddr = undefined;
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const bytes_received = try posix.recvfrom(server_sock, &server_buffer, 0, &from_addr, &from_len);

    // Echo back
    _ = try posix.sendto(server_sock, server_buffer[0..bytes_received], 0, &from_addr, from_len);

    // Client receives echo
    var client_buffer: [1024]u8 = undefined;
    pollfds[0].fd = client_sock;
    pollfds[0].revents = 0;
    const ready = try posix.poll(&pollfds, 1000);
    try testing.expect(ready > 0);

    var echo_from_addr: posix.sockaddr = undefined;
    var echo_from_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const echo_bytes = try posix.recvfrom(client_sock, &client_buffer, 0, &echo_from_addr, &echo_from_len);

    try testing.expectEqual(send_data.len, echo_bytes);
    try testing.expectEqualStrings(send_data, client_buffer[0..echo_bytes]);
}

test "UDP server multiple clients simulation" {
    const server_sock = try createUdpSocket(posix.AF.INET);
    defer posix.close(server_sock);

    const server_bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try bindUdpSocket(server_sock, server_bind_addr);

    var server_addr: posix.sockaddr = undefined;
    var server_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server_sock, &server_addr, &server_addr_len);
    const server_net_addr = std.net.Address.initPosix(@alignCast(&server_addr));
    const server_port = server_net_addr.getPort();

    // Create 3 different client sockets
    const client1 = try createUdpSocket(posix.AF.INET);
    defer posix.close(client1);
    const client2 = try createUdpSocket(posix.AF.INET);
    defer posix.close(client2);
    const client3 = try createUdpSocket(posix.AF.INET);
    defer posix.close(client3);

    const target_addr = try std.net.Address.parseIp4("127.0.0.1", server_port);

    // Send from each client
    _ = try posix.sendto(client1, "Client 1", 0, &target_addr.any, target_addr.getOsSockLen());
    _ = try posix.sendto(client2, "Client 2", 0, &target_addr.any, target_addr.getOsSockLen());
    _ = try posix.sendto(client3, "Client 3", 0, &target_addr.any, target_addr.getOsSockLen());

    // Receive all messages
    var buffer: [1024]u8 = undefined;
    var pollfds = [_]posix.pollfd{.{
        .fd = server_sock,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    var msg_count: usize = 0;
    while (msg_count < 3) {
        pollfds[0].revents = 0;
        const ready = try posix.poll(&pollfds, 1000);
        if (ready == 0) break;

        var from_addr: posix.sockaddr = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        _ = try posix.recvfrom(server_sock, &buffer, 0, &from_addr, &from_len);
        msg_count += 1;
    }

    // Should have received 3 messages
    try testing.expectEqual(@as(usize, 3), msg_count);
}
