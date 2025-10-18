// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

const std = @import("std");

pub const Stream = struct {
    context: *anyopaque,
    readFn: *const fn (self: *anyopaque, buffer: []u8) anyerror!usize,
    writeFn: *const fn (self: *anyopaque, data: []const u8) anyerror!usize,
    closeFn: *const fn (self: *anyopaque) void,
    handleFn: *const fn (self: *anyopaque) std.posix.socket_t,
    maintenanceFn: ?*const fn (self: *anyopaque) anyerror!void = null,

    pub fn read(self: Stream, buffer: []u8) !usize {
        return self.readFn(self.context, buffer);
    }

    pub fn write(self: Stream, data: []const u8) !usize {
        return self.writeFn(self.context, data);
    }

    pub fn close(self: Stream) void {
        self.closeFn(self.context);
    }

    pub fn handle(self: Stream) std.posix.socket_t {
        return self.handleFn(self.context);
    }

    pub fn maintain(self: Stream) !void {
        if (self.maintenanceFn) |maintain_fn| {
            try maintain_fn(self.context);
        }
    }
};
