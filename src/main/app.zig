// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! This file is the main application bootstrap. It is responsible for parsing arguments,
//! performing initial configuration validation, and dispatching to either client or
//! server mode.

const std = @import("std");

const cli = @import("../cli.zig");
const config = @import("../config.zig");
const client = @import("../client/mod.zig");
const net = @import("../net/socket.zig");
const logging = @import("../util/logging.zig");

const common = @import("common.zig");
const server_mode = @import("modes/server.zig");

/// The main application entry point, responsible for the entire program lifecycle.
///
/// This function orchestrates the application's execution by:
/// 1. Initializing the memory allocator and networking stack.
/// 2. Parsing command-line arguments into a `Config` struct.
/// 3. Handling special flags like `--help` and `--version`.
/// 4. Validating the final configuration.
/// 5. Dispatching control to either the server (`runServer`) or client (`runClient`)
///    logic based on the `-l` (`--listen`) flag.
pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try net.initPlatform();
    defer net.deinitPlatform();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = cli.parseArgs(allocator, args) catch |err| {
        switch (err) {
            cli.CliError.ShowHelp => {
                cli.printHelp();
                std.process.exit(0);
            },
            cli.CliError.ShowVersion => {
                cli.printVersion();
                std.process.exit(0);
            },
            else => return err,
        }
    };
    defer cfg.deinit(allocator);

    config.validate(&cfg) catch |err| {
        switch (err) {
            config.IOControlError.ConflictingIOModes,
            config.IOControlError.InvalidOutputPath,
            config.IOControlError.PathTraversalDetected,
            config.IOControlError.OutputFileCreateFailed,
            config.IOControlError.HexDumpFileCreateFailed,
            config.IOControlError.OutputFileWriteFailed,
            config.IOControlError.HexDumpFileWriteFailed,
            => common.handleIOInitError(&cfg, err, "configuration"),

            else => logging.logError(err, "configuration validation"),
        }
        std.process.exit(1);
    };

    if (cfg.listen_mode) {
        common.registerSignalHandlers(&cfg);
        try server_mode.runServer(allocator, &cfg);
    } else {
        try client.runClient(allocator, &cfg);
    }
}
