const std = @import("std");

pub const Stream = struct {
    context: *anyopaque,
    readFn: *const fn (self: *anyopaque, buffer: []u8) anyerror!usize,
    writeFn: *const fn (self: *anyopaque, data: []const u8) anyerror!usize,
    closeFn: *const fn (self: *anyopaque) void,
    handleFn: *const fn (self: *anyopaque) std.posix.socket_t,

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
};