// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! This module provides functions for creating and managing Stream Control
//! Transmission Protocol (SCTP) sockets. It offers platform-agnostic wrappers
//! around the low-level POSIX socket APIs for SCTP, handling both client-side
//! connections and server-side listeners.
//!
//! SCTP support is an optional feature and may not be available on all
//! platforms. The functions here will fail if the underlying OS does not
//! support the `IPPROTO_SCTP` protocol.

const std = @import("std");
const net = @import("socket.zig");
const posix = std.posix;

/// Opens an SCTP client connection to a specified host and port.
///
/// This function creates an SCTP socket, resolves the host address, and
/// establishes a connection. It handles non-blocking connection logic with a
/// timeout, using `poll` to wait for the connection to complete.
///
/// - `host`: The hostname or IP address to connect to.
/// - `port`: The port number to connect to.
/// - `timeout`: The connection timeout in milliseconds.
///
/// Returns the connected socket descriptor (`net.Socket`) or an error if the
/// connection fails, times out, or the host cannot be resolved.
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

/// Opens an SCTP server socket bound to a specific address and port.
///
/// This function creates an SCTP socket, sets standard socket options like
/// `SO_REUSEADDR` and `SO_REUSEPORT`, binds it to the specified address, and
/// puts it into listening mode.
///
/// - `bind_addr_str`: The IP address or hostname to bind to.
/// - `port`: The port number to listen on.
///
/// Returns the listening socket descriptor (`net.Socket`) or an error if the
/// socket cannot be created, bound, or set to listen.
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
