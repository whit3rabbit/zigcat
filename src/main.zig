//! Entry point facade for zigcat.

const app = @import("main/app.zig");
pub const socket = @import("net/socket.zig");

pub fn main() !void {
    try app.run();
}
