// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Entry point facade for zigcat.

const std = @import("std");
const app = @import("main/app.zig");
pub const socket = @import("net/socket.zig");
pub const gsocket = @import("net/gsocket.zig");
pub const build_options = @import("build_options");

// Conditionally import SRP module only when using OpenSSL backend
// wolfSSL does not provide OpenSSL-compatible SRP headers
pub const srp_openssl = if (build_options.enable_tls and std.mem.eql(u8, build_options.tls_backend, "openssl"))
    @import("tls/srp_openssl.zig")
else
    struct {};

/// The executable's main entry point.
///
/// This function serves as a thin wrapper that calls the primary application
/// logic in `app.run()`.
pub fn main() !void {
    try app.run();
}
