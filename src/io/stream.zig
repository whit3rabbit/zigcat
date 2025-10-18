// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.
//
//! This module defines a generic `Stream` interface for I/O operations.
//! It abstracts over various connection types, such as raw TCP, TLS-encrypted sockets,
//! or Unix domain sockets, allowing higher-level code to handle them uniformly.
//! This is achieved through a vtable-like struct containing function pointers
//! for read, write, close, and handle retrieval operations.

const std = @import("std");

/// A generic interface for a stream-oriented connection.
/// This struct acts as a type-erased wrapper around different kinds of I/O objects
/// (e.g., `std.net.Stream`, a TLS-wrapped stream, etc.). It uses a `context` pointer
/// and a set of function pointers (`readFn`, `writeFn`, etc.) to delegate
/// operations to the underlying concrete implementation.
pub const Stream = struct {
    context: *anyopaque,
    readFn: *const fn (self: *anyopaque, buffer: []u8) anyerror!usize,
    writeFn: *const fn (self: *anyopaque, data: []const u8) anyerror!usize,
    closeFn: *const fn (self: *anyopaque) void,
    handleFn: *const fn (self: *anyopaque) std.posix.socket_t,

    /// Reads data from the stream into the provided buffer.
    ///
    /// - `buffer`: The slice to write the read data into.
    ///
    /// Returns the number of bytes read, or an error if the operation fails.
    /// A return value of 0 typically indicates that the stream has been closed
    /// by the peer.
    pub fn read(self: Stream, buffer: []u8) !usize {
        return self.readFn(self.context, buffer);
    }

    /// Writes data from the provided buffer to the stream.
    ///
    /// - `data`: The slice of data to write.
    ///
    /// Returns the number of bytes written, or an error if the operation fails.
    pub fn write(self: Stream, data: []const u8) !usize {
        return self.writeFn(self.context, data);
    }

    /// Closes the stream, releasing any underlying resources.
    /// This should be called when the stream is no longer needed.
    pub fn close(self: Stream) void {
        self.closeFn(self.context);
    }

    /// Returns the underlying OS handle (e.g., file descriptor or socket)
    /// for the stream. This is useful for integrating with platform-specific
    /// I/O mechanisms like `poll` or `epoll`.
    pub fn handle(self: Stream) std.posix.socket_t {
        return self.handleFn(self.context);
    }
};