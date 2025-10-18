// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Stream adapters for client connections.
//!
//! This module provides unified stream wrappers for different connection types:
//! - Telnet protocol connections (with IAC processing)
//! - TLS encrypted connections (TCP-based)
//! - SRP encrypted connections (gsocket mode)
//! - DTLS encrypted connections (UDP-based)
//! - Plain network sockets (TCP/UDP)
//!
//! All adapters implement the stream.Stream interface for compatibility with
//! bidirectionalTransfer().

const std = @import("std");
const posix = std.posix;
const stream = @import("../io/stream.zig");
const tls = @import("../tls/tls.zig");
const TelnetConnection = @import("../protocol/telnet_connection.zig").TelnetConnection;

// DTLS support (conditional compilation)
const build_options = @import("build_options");
const dtls_enabled = build_options.enable_tls and (!@hasDecl(build_options, "use_wolfssl") or !build_options.use_wolfssl);
const dtls = if (dtls_enabled) @import("../tls/dtls/dtls.zig") else struct {
    pub const DtlsConnection = struct {
        pub fn deinit(_: *DtlsConnection) void {}
        pub fn close(_: *DtlsConnection) void {}
        pub fn read(_: *DtlsConnection, _: []u8) !usize {
            return error.DtlsNotAvailableWithWolfSSL;
        }
        pub fn write(_: *DtlsConnection, _: []const u8) !usize {
            return error.DtlsNotAvailableWithWolfSSL;
        }
        pub fn getSocket(_: *DtlsConnection) posix.socket_t {
            return 0;
        }
    };
};

/// Helper function to safely cast context pointer to typed pointer.
///
/// This pattern is used in all stream adapters to convert the opaque context
/// pointer back to the concrete type. Ensures proper alignment before casting.
///
/// Parameters:
///   T: Target type
///   context: Opaque context pointer
///
/// Returns: Typed pointer to T
inline fn contextToPtr(comptime T: type, context: *anyopaque) *T {
    const aligned_ctx: *align(@alignOf(T)) anyopaque = @alignCast(context);
    return @ptrCast(aligned_ctx);
}

/// Wrap TelnetConnection in generic stream.Stream interface.
///
/// Provides protocol-aware I/O with IAC sequence processing:
/// - read(): Processes IAC sequences, returns application data
/// - write(): May insert IAC sequences (e.g., for option negotiation)
/// - close(): Closes underlying connection
/// - handle(): Returns socket handle for poll()
/// - maintain(): Handles SIGWINCH (window resize) and sends Telnet NAWS updates
///
/// The maintenanceFn callback is critical for dynamic window resize support.
/// It checks for SIGWINCH signals and sends Telnet NAWS (Negotiate About Window Size)
/// updates to the remote server when the terminal window is resized.
///
/// Parameters:
///   telnet_conn: Pointer to TelnetConnection
///
/// Returns: stream.Stream with vtable pointing to Telnet methods
pub fn telnetConnectionToStream(telnet_conn: *TelnetConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(telnet_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(TelnetConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(TelnetConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(TelnetConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(TelnetConnection, context);
                return c.getSocket();
            }
        }.handle,
        .maintenanceFn = struct {
            fn maintain(context: *anyopaque) anyerror!void {
                const c = contextToPtr(TelnetConnection, context);
                try c.handleMaintenance();
            }
        }.maintain,
    };
}

/// Wrap TLS connection in generic stream.Stream interface.
///
/// Provides encrypted stream I/O over TCP:
/// - read(): Decrypts data from TLS stream
/// - write(): Encrypts data before sending
/// - close(): Sends TLS close_notify
/// - handle(): Returns underlying socket handle for poll()
///
/// Parameters:
///   tls_conn: Pointer to TlsConnection
///
/// Returns: stream.Stream with vtable pointing to TLS methods
pub fn tlsConnectionToStream(tls_conn: *tls.TlsConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(tls_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(tls.TlsConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(tls.TlsConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

/// Wrap SRP connection in generic stream.Stream interface.
///
/// This adapter allows SrpConnection to work with bidirectionalTransfer(),
/// which expects a unified Stream interface (same pattern as TLS, DTLS, Telnet).
///
/// The wrapper provides:
/// - read(): Decrypts data from SRP-AES-256-CBC-SHA stream
/// - write(): Encrypts data before sending
/// - close(): Sends TLS close_notify
/// - handle(): Returns underlying socket handle for poll()
///
/// Parameters:
///   srp_conn: Heap-allocated SrpConnection pointer
///
/// Returns: stream.Stream with vtable pointing to SRP methods
pub fn srpConnectionToStream(srp_conn: anytype) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(@constCast(srp_conn)),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const srp = @import("../tls/srp_openssl.zig");
                const c = contextToPtr(srp.SrpConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const srp = @import("../tls/srp_openssl.zig");
                const c = contextToPtr(srp.SrpConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const srp = @import("../tls/srp_openssl.zig");
                const c = contextToPtr(srp.SrpConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const srp = @import("../tls/srp_openssl.zig");
                const c = contextToPtr(srp.SrpConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

/// Wrap DTLS connection in generic stream.Stream interface.
///
/// Provides encrypted datagram I/O over UDP:
/// - read(): Decrypts data from DTLS stream
/// - write(): Encrypts data before sending
/// - close(): Sends DTLS close_notify
/// - handle(): Returns underlying socket handle for poll()
///
/// Note: DTLS is only available with OpenSSL backend. wolfSSL builds
/// use a stub implementation that returns error.DtlsNotAvailableWithWolfSSL.
///
/// Parameters:
///   dtls_conn: Pointer to DtlsConnection
///
/// Returns: stream.Stream with vtable pointing to DTLS methods
pub fn dtlsConnectionToStream(dtls_conn: *dtls.DtlsConnection) stream.Stream {
    return stream.Stream{
        .context = @ptrCast(dtls_conn),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const c = contextToPtr(dtls.DtlsConnection, context);
                c.close();
            }
        }.close,
        .handleFn = struct {
            fn handle(context: *anyopaque) std.posix.socket_t {
                const c = contextToPtr(dtls.DtlsConnection, context);
                return c.getSocket();
            }
        }.handle,
    };
}

/// Wrap std.net.Stream in generic stream.Stream interface.
///
/// Provides plain socket I/O without encryption or protocol processing:
/// - read(): Raw socket read
/// - write(): Raw socket write
/// - close(): Close socket
/// - handle(): Returns socket handle
///
/// This adapter is used for unencrypted TCP/UDP connections.
///
/// **CRITICAL FIX**: Previous implementation stored a pointer to the stack-allocated
/// net_stream parameter, causing use-after-free bugs. Now stores the socket handle
/// directly and reconstructs std.net.Stream on each call.
///
/// Parameters:
///   net_stream: std.net.Stream (value, not pointer - extracts handle)
///
/// Returns: stream.Stream with vtable pointing to socket methods
pub fn netStreamToStream(net_stream: std.net.Stream) stream.Stream {
    // Store the socket handle directly (not a pointer to the struct)
    const sock_fd = net_stream.handle;

    return stream.Stream{
        .context = @ptrFromInt(@as(usize, @intCast(sock_fd))),
        .readFn = struct {
            fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
                const fd: posix.socket_t = @intCast(@intFromPtr(context));
                const s = std.net.Stream{ .handle = fd };
                return s.read(buffer);
            }
        }.read,
        .writeFn = struct {
            fn write(context: *anyopaque, data: []const u8) anyerror!usize {
                const fd: posix.socket_t = @intCast(@intFromPtr(context));
                const s = std.net.Stream{ .handle = fd };
                return s.write(data);
            }
        }.write,
        .closeFn = struct {
            fn close(context: *anyopaque) void {
                const fd: posix.socket_t = @intCast(@intFromPtr(context));
                const s = std.net.Stream{ .handle = fd };
                s.close();
            }
        }.close,
        .handleFn = struct {
            fn getHandle(context: *anyopaque) std.posix.socket_t {
                const fd: posix.socket_t = @intCast(@intFromPtr(context));
                return fd;
            }
        }.getHandle,
    };
}
