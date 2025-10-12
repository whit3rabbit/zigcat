// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


const std = @import("std");
const net = @import("socket.zig");
const posix = std.posix;

pub fn openSctpClient(host: []const u8, port: u16, timeout: i32) !net.Socket {
    const family = net.detectAddressFamily(host);
    const sock = try net.createSctpSocket(family);
    errdefer net.closeSocket(sock);

    try net.setNonBlocking(sock);

    const addr_list = try std.net.getAddressList(std.heap.page_allocator, host, port);
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    const address = addr_list.addrs[0];
    _ = posix.connect(sock, &address.any, address.getOsSockLen()) catch |err| {
        if (err == error.InProgress) {
            // Wait for connection with timeout
            var pollfds = [_]posix.pollfd{.{
                .fd = sock,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};

            const ready = try posix.poll(&pollfds, timeout);
            if (ready == 0) {
                return error.ConnectionTimedOut;
            }

            // Check for connection error
            var so_error: i32 = undefined;
            const len: posix.socklen_t = @sizeOf(i32);
            try posix.getsockopt(sock, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&so_error)[0..len]);

            if (so_error != 0) {
                return error.ConnectionFailed;
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

    const addr_list = try std.net.getAddressList(std.heap.page_allocator, bind_addr_str, port);
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return error.UnknownHost;
    }

    const bind_addr = addr_list.addrs[0];
    try posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

    try posix.listen(sock, 128);

    return sock;
}
