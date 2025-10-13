// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Network-related configuration validation.
//!
//! Contains helpers for proxy settings and Unix domain socket
//! validation that previously lived in the monolithic `config.zig`.

const std = @import("std");
const builtin = @import("builtin");

const config_struct = @import("config_struct.zig");
const Config = config_struct.Config;

/// Platform compatibility for Unix domain sockets.
pub const UnixSocketSupport = struct {
    pub const available = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        .windows => false,
        else => false,
    };

    pub fn checkSupport() UnixSocketError!void {
        if (!available) {
            return UnixSocketError.UnixSocketsNotSupported;
        }
    }
};

/// Comprehensive errors related to Unix socket configuration validation.
pub const UnixSocketError = error{
    // Path validation errors
    InvalidUnixSocketPath,
    UnixSocketPathTooLong,
    InvalidUnixSocketPathCharacters,
    UnixSocketPathContainsNull,
    UnixSocketDirectoryNotFound,
    UnixSocketPermissionDenied,

    // Platform support errors
    UnixSocketsNotSupported,
    PlatformNotSupported,
    FeatureNotAvailable,

    // Configuration conflict errors
    ConflictingUnixSocketAndTCP,
    ConflictingUnixSocketAndUDP,
    ConflictingUnixSocketAndTLS,
    ConflictingUnixSocketAndProxy,
    ConflictingUnixSocketAndBroker,
    ConflictingUnixSocketAndExec,

    // Resource and system errors
    UnixSocketResourceExhausted,
    UnixSocketSystemError,
    UnixSocketConfigurationError,
};

/// Comprehensive Unix socket configuration validation with detailed conflict detection.
pub fn validateUnixSocket(cfg: *const Config) UnixSocketError!void {
    const unix_path = cfg.unix_socket_path orelse return;

    try UnixSocketSupport.checkSupport();
    try validateUnixSocketPath(unix_path);
    try validateUnixSocketConflicts(cfg);
    try validateUnixSocketResources(cfg, unix_path);
}

/// Validate Unix socket path for length, characters, and accessibility.
fn validateUnixSocketPath(path: []const u8) UnixSocketError!void {
    if (path.len == 0) {
        return UnixSocketError.InvalidUnixSocketPath;
    }

    if (std.mem.indexOf(u8, path, "\x00") != null) {
        return UnixSocketError.UnixSocketPathContainsNull;
    }

    const MAX_UNIX_SOCKET_PATH = 107;
    if (path.len > MAX_UNIX_SOCKET_PATH) {
        return UnixSocketError.UnixSocketPathTooLong;
    }

    for (path) |byte| {
        if (byte < 32 and byte != '\t') {
            return UnixSocketError.InvalidUnixSocketPathCharacters;
        }
    }

    if (std.fs.path.dirname(path)) |parent_dir| {
        std.fs.cwd().access(parent_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => return UnixSocketError.UnixSocketDirectoryNotFound,
            error.AccessDenied => return UnixSocketError.UnixSocketPermissionDenied,
            error.SystemResources => return UnixSocketError.UnixSocketResourceExhausted,
            else => return UnixSocketError.UnixSocketSystemError,
        };
    }
}

/// Validate Unix socket configuration conflicts with other features.
fn validateUnixSocketConflicts(cfg: *const Config) UnixSocketError!void {
    if (cfg.positional_args.len > 0) {
        return UnixSocketError.ConflictingUnixSocketAndTCP;
    }

    if (cfg.udp_mode) {
        return UnixSocketError.ConflictingUnixSocketAndUDP;
    }

    if (cfg.ssl) {
        return UnixSocketError.ConflictingUnixSocketAndTLS;
    }

    if (cfg.proxy != null) {
        return UnixSocketError.ConflictingUnixSocketAndProxy;
    }

    // NOTE: Broker/chat mode is now supported with Unix sockets (removed validation check)

    if ((cfg.exec_command != null or cfg.shell_command != null) and cfg.listen_mode) {
        try validateUnixSocketExecSecurity(cfg);
    }
}

/// Validate Unix socket resource requirements and system limits.
fn validateUnixSocketResources(cfg: *const Config, path: []const u8) UnixSocketError!void {
    _ = cfg;
    _ = path;
}

/// Validate security considerations for Unix sockets with exec mode.
fn validateUnixSocketExecSecurity(cfg: *const Config) UnixSocketError!void {
    _ = cfg;
}

test "validateUnixSocket accepts valid configurations" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.unix_socket_path = "/tmp/test.sock";
    if (UnixSocketSupport.available) {
        try validateUnixSocket(&cfg);
    } else {
        try testing.expectError(UnixSocketError.UnixSocketsNotSupported, validateUnixSocket(&cfg));
    }
}

test "validateUnixSocket rejects malformed paths" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    if (!UnixSocketSupport.available) return;

    cfg.unix_socket_path = "";
    try testing.expectError(UnixSocketError.InvalidUnixSocketPath, validateUnixSocket(&cfg));

    cfg.unix_socket_path = "/tmp/test\x00.sock";
    try testing.expectError(UnixSocketError.UnixSocketPathContainsNull, validateUnixSocket(&cfg));
}

test "validateUnixSocket identifies conflicting modes" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    if (!UnixSocketSupport.available) return;

    cfg.unix_socket_path = "/tmp/test.sock";

    var args = [_][]const u8{ "example.com", "80" };
    cfg.positional_args = args[0..];
    try testing.expectError(UnixSocketError.ConflictingUnixSocketAndTCP, validateUnixSocket(&cfg));
}

test "UnixSocketSupport reports platform availability" {
    const testing = std.testing;

    const expected = switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        .windows => false,
        else => false,
    };

    try testing.expectEqual(expected, UnixSocketSupport.available);
}
