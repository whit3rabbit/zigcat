const std = @import("std");
const net = @import("socket.zig");
const posix = std.posix;

pub fn openSctpClient(host: []const u8, port: u16, timeout: i32) !net.Socket {
    const family = net.detectAddressFamily(host);
    const sock = try net.createSctpSocket(family);
    errdefer net.closeSocket(sock);

    try net.setNonBlocking(sock);

    const address = try std.net.resolveIp(host, port);
    _ = posix.connect(sock, &address.any, address.getOsSocklen()) catch |err| {
        if (err == error.InProgress) {
            // Wait for connection with timeout
            const pollfd = posix.pollfd{
                .fd = sock,
                .events = posix.POLL.OUT,
                .revents = 0,
            };

            const ready = try posix.poll(&[_]posix.pollfd{pollfd}, timeout);
            if (ready == 0) {
                return error.ConnectionTimedOut;
            }

            // Check for connection error
            var so_error: c_int = 0;
            var len = @sizeOf(@TypeOf(so_error));
            try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&so_error), &len);

            if (so_error != 0) {
                return std.os.unexpectedErrno(so_error);
            }
        } else {
            return err;
        }
    };

    return sock;
}

pub fn openSctpServer(bind_addr_str: []const u8, port: u16) !net.Socket {
    const family = net.detectAddressFamily(bind_addr_str);
    const sock = try net.createSctpSocket(family);
    errdefer net.closeSocket(sock);

    try net.setReuseAddr(sock);
    try net.setReusePort(sock);

    const bind_addr = try std.net.resolveIp(bind_addr_str, port);
    try posix.bind(sock, &bind_addr.any, bind_addr.getOsSocklen());

    try posix.listen(sock, 128);

    return sock;
}
