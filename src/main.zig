// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Entry point facade for zigcat.

const app = @import("main/app.zig");
pub const socket = @import("net/socket.zig");

pub fn main() !void {
    try app.run();
}
