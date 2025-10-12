// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Hex dump configuration helpers.
//!
//! Centralizes validation and parsing of caller-supplied configuration used
//! by the hex dumper implementations.

const app_config = @import("../../config.zig");
const std = @import("std");

/// Lightweight configuration consumed by `HexDumper` implementations.
pub const HexDumpConfig = struct {
    path: ?[]const u8 = null,

    /// Returns true when file-backed output is requested.
    pub fn wantsFile(self: HexDumpConfig) bool {
        return self.path != null;
    }

    /// Provides the configured path when file-backed output is enabled.
    pub fn filePath(self: HexDumpConfig) ?[]const u8 {
        return self.path;
    }
};

/// Parse CLI/configuration input into a validated `HexDumpConfig`.
///
/// Rejects empty strings to align with the legacy behaviour of the hex
/// dumper setup code.
pub fn parse(path: ?[]const u8) !HexDumpConfig {
    if (path) |p| {
        if (p.len == 0) {
            return app_config.IOControlError.InvalidOutputPath;
        }
    }

    return HexDumpConfig{ .path = path };
}

test "parse accepts null and non-empty paths" {
    const cfg_null = try parse(null);
    try std.testing.expect(!cfg_null.wantsFile());
    try std.testing.expect(cfg_null.filePath() == null);

    const cfg_path = try parse("dump.hex");
    try std.testing.expect(cfg_path.wantsFile());
    try std.testing.expectEqualStrings("dump.hex", cfg_path.filePath().?);
}

test "parse rejects empty strings" {
    try std.testing.expectError(app_config.IOControlError.InvalidOutputPath, parse(""));
}
