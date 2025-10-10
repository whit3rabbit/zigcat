//! TLS-aware bidirectional transfer dispatcher and platform backends.
//!
//! This module focuses on the I/O orchestration logic for TLS connections.
//! Error mapping, logging helpers, and resource cleanup live in sibling
//! modules to keep responsibilities separated.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const config = @import("../../config.zig");
const tls = @import("../../tls/tls.zig");
const linecodec = @import("../linecodec.zig");
const output = @import("../output.zig");
const hexdump = @import("../hexdump.zig");
const poll_wrapper = @import("../../util/poll_wrapper.zig");
const logging = @import("../../util/logging.zig");

const errors = @import("errors.zig");
const cleanup = @import("cleanup.zig");

pub const BUFFER_SIZE = 8192;

/// TLS-aware bidirectional data transfer between stdin/stdout and TLS connection.
///
/// Dispatches to platform-specific implementations while preserving the public API.
pub fn tlsBidirectionalTransfer(
    allocator: std.mem.Allocator,
    tls_conn: *tls.TlsConnection,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            return tlsBidirectionalTransferPosix(allocator, tls_conn, cfg, output_logger, hex_dumper);
        },
        .windows => {
            return tlsBidirectionalTransferWindows(allocator, tls_conn, cfg, output_logger, hex_dumper);
        },
        else => {
            // Fallback for other OSes mirrors Windows behaviour (blocking loop).
            return tlsBidirectionalTransferWindows(allocator, tls_conn, cfg, output_logger, hex_dumper);
        },
    }
}

/// Windows implementation of TLS bidirectional transfer.
///
/// Uses blocking I/O with manual polling simulation since Windows lacks a
/// uniform `poll()` implementation for all handle types.
pub fn tlsBidirectionalTransferWindows(
    allocator: std.mem.Allocator,
    tls_conn: *tls.TlsConnection,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    while (!stdin_closed or !socket_closed) {
        if (can_send and !stdin_closed) {
            const n = stdin.read(&buffer1) catch 0;
            if (n == 0) {
                stdin_closed = true;
                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                const input_slice = buffer1[0..n];
                const data = if (cfg.crlf)
                    try linecodec.convertLfToCrlf(allocator, input_slice)
                else
                    input_slice;
                defer if (data.ptr != input_slice.ptr) allocator.free(data);

                _ = tls_conn.write(data) catch |err| {
                    logging.logError(err, "TLS write");
                    socket_closed = true;
                    continue;
                };

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
                }
            }
        }

        if (can_recv and !socket_closed) {
            const n = tls_conn.read(&buffer2) catch |err| {
                const tls_err = errors.handleTlsError(err, "read", cfg);
                if (errors.isTlsErrorRecoverable(tls_err)) {
                    continue;
                } else {
                    return errors.mapTlsError(err);
                }
            };

            if (n == 0) {
                socket_closed = true;
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "TLS connection closed by peer\n", .{});
                }
            } else {
                const data = buffer2[0..n];

                if (!cfg.hex_dump) {
                    try stdout.writeAll(data);
                }

                if (output_logger) |logger| {
                    logger.write(data) catch |err| {
                        errors.handleOutputError(err, cfg, "output logging");
                    };
                }

                if (cfg.hex_dump) {
                    if (hex_dumper) |dumper| {
                        dumper.dump(data) catch |err| {
                            errors.handleOutputError(err, cfg, "hex dump file logging");
                            errors.printHexDump(data);
                        };
                    } else {
                        errors.printHexDump(data);
                    }
                }

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Received {any} bytes\n", .{n});
                }
            }
        }
    }

    cleanup.cleanupTlsTransferResources(null, output_logger, hex_dumper, cfg);
}

/// POSIX implementation of TLS bidirectional transfer using poll().
pub fn tlsBidirectionalTransferPosix(
    allocator: std.mem.Allocator,
    tls_conn: *tls.TlsConnection,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    const tls_socket = tls_conn.getSocket();
    var pollfds = [_]poll_wrapper.pollfd{
        .{ .fd = stdin.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
        .{ .fd = tls_socket, .events = poll_wrapper.POLL.IN, .revents = 0 },
    };

    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    const stdin_is_tty = posix.isatty(stdin.handle);
    const timeout_ms: i32 = if (cfg.idle_timeout > 0)
        @intCast(cfg.idle_timeout)
    else if (!stdin_is_tty)
        30000
    else
        -1;

    while (!stdin_closed or !socket_closed) {
        pollfds[0].events = if (!stdin_closed and can_send) poll_wrapper.POLL.IN else 0;
        pollfds[1].events = if (!socket_closed and can_recv) poll_wrapper.POLL.IN else 0;

        const ready = poll_wrapper.poll(&pollfds, timeout_ms) catch |err| {
            logging.logError(err, "Poll");
            return err;
        };

        if (ready == 0) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Idle timeout reached\n", .{});
            }
            break;
        }

        if (pollfds[1].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP) != 0) {
            socket_closed = true;
            continue;
        }

        if (pollfds[0].revents & poll_wrapper.POLL.IN != 0) {
            const n = stdin.read(&buffer1) catch 0;

            if (n == 0) {
                stdin_closed = true;
                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                const input_slice = buffer1[0..n];
                const data = if (cfg.crlf)
                    try linecodec.convertLfToCrlf(allocator, input_slice)
                else
                    input_slice;
                defer if (data.ptr != input_slice.ptr) allocator.free(data);

                _ = tls_conn.write(data) catch |err| {
                    const tls_err = errors.handleTlsError(err, "write", cfg);
                    if (!errors.isTlsErrorRecoverable(tls_err)) {
                        return errors.mapTlsError(err);
                    }
                    continue;
                };

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
                }
            }
        }

        if (can_recv and !socket_closed and (pollfds[1].revents & poll_wrapper.POLL.IN != 0)) {
            const n = tls_conn.read(&buffer2) catch |err| {
                const tls_err = errors.handleTlsError(err, "read", cfg);
                if (errors.isTlsErrorRecoverable(tls_err)) {
                    continue;
                } else {
                    return errors.mapTlsError(err);
                }
            };

            if (n == 0) {
                socket_closed = true;
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "TLS connection closed by peer\n", .{});
                }
            } else {
                const data = buffer2[0..n];

                if (!cfg.hex_dump) {
                    try stdout.writeAll(data);
                }

                if (output_logger) |logger| {
                    logger.write(data) catch |err| {
                        errors.handleOutputError(err, cfg, "output logging");
                    };
                }

                if (cfg.hex_dump) {
                    if (hex_dumper) |dumper| {
                        dumper.dump(data) catch |err| {
                            errors.handleOutputError(err, cfg, "hex dump file logging");
                            errors.printHexDump(data);
                        };
                    } else {
                        errors.printHexDump(data);
                    }
                }

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Received {any} bytes\n", .{n});
                }
            }
        }
    }

    cleanup.cleanupTlsTransferResources(null, output_logger, hex_dumper, cfg);
}

test "tlsBidirectionalTransfer function is callable" {
    const func = tlsBidirectionalTransfer;
    _ = func;
}
