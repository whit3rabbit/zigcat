// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Resource cleanup helpers for TLS transfers.

const std = @import("std");

const config = @import("../../config.zig");
const tls = @import("../../tls/tls.zig");
const output = @import("../output.zig");
const hexdump = @import("../hexdump.zig");
const logging = @import("../../util/logging.zig");

/// Comprehensive resource cleanup for TLS transfer operations.
pub fn cleanupTlsTransferResources(
    tls_conn: ?*tls.TlsConnection,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
    cfg: *const config.Config,
) void {
    flushOutputs(output_logger, hex_dumper, cfg);

    if (tls_conn) |conn| {
        cleanupTlsConnection(conn, cfg);
    }
}

fn cleanupTlsConnection(tls_conn: *tls.TlsConnection, cfg: *const config.Config) void {
    tls_conn.close();

    if (cfg.verbose) {
        logging.logVerbose(cfg, "TLS connection closed gracefully\n", .{});
    }

    tls_conn.deinit();
}

fn flushOutputs(
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
    cfg: *const config.Config,
) void {
    if (output_logger) |logger| {
        flushOutputLogger(logger, cfg);
    }

    if (hex_dumper) |dumper| {
        flushHexDumper(dumper, cfg);
    }
}

fn flushOutputLogger(logger: *output.OutputLogger, cfg: *const config.Config) void {
    var retry_count: u8 = 0;
    const max_retries: u8 = 3;

    while (retry_count < max_retries) {
        logger.flush() catch |err| {
            retry_count += 1;
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.log(1, "Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                    return;
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.log(1, "Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
                    return;
                },
                config.IOControlError.FileLocked => {
                    if (retry_count < max_retries) {
                        if (cfg.verbose) {
                            logging.logVerbose(cfg, "Warning: Output file locked, retrying flush ({any}/{any})\n", .{ retry_count, max_retries });
                        }
                        std.Thread.sleep(100_000_000);
                        continue;
                    } else {
                        logging.log(1, "Critical: Output file flush failed - file locked after {any} retries\n", .{max_retries});
                        return;
                    }
                },
                else => {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Warning: Failed to flush output file (attempt {any}/{any}): {any}\n", .{ retry_count, max_retries, err });
                    }
                    if (retry_count < max_retries) {
                        std.Thread.sleep(50_000_000);
                        continue;
                    } else {
                        logging.log(1, "Warning: Output file flush failed after {any} retries\n", .{max_retries});
                        return;
                    }
                },
            }
        };

        return;
    }
}

fn flushHexDumper(dumper: *hexdump.HexDumper, cfg: *const config.Config) void {
    var retry_count: u8 = 0;
    const max_retries: u8 = 3;

    while (retry_count < max_retries) {
        dumper.flush() catch |err| {
            retry_count += 1;
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.log(1, "Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                    return;
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.log(1, "Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                    return;
                },
                config.IOControlError.FileLocked => {
                    if (retry_count < max_retries) {
                        if (cfg.verbose) {
                            logging.logVerbose(cfg, "Warning: Hex dump file locked, retrying flush ({any}/{any})\n", .{ retry_count, max_retries });
                        }
                        std.Thread.sleep(100_000_000);
                        continue;
                    } else {
                        logging.log(1, "Critical: Hex dump file flush failed - file locked after {any} retries\n", .{max_retries});
                        return;
                    }
                },
                else => {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Warning: Failed to flush hex dump file (attempt {any}/{any}): {any}\n", .{ retry_count, max_retries, err });
                    }
                    if (retry_count < max_retries) {
                        std.Thread.sleep(50_000_000);
                        continue;
                    } else {
                        logging.log(1, "Warning: Hex dump file flush failed after {any} retries\n", .{max_retries});
                        return;
                    }
                },
            }
        };

        return;
    }
}

// -----------------------------------------------------------------------------+
// Tests                                                                         |
// -----------------------------------------------------------------------------+

test "cleanup handles null resources" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.verbose = true;

    cleanupTlsTransferResources(null, null, null, &cfg);

    cfg.verbose = false;
    cleanupTlsTransferResources(null, null, null, &cfg);
}
