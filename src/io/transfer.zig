// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Cross-platform I/O pipeline that mirrors ncat's interactive behavior.
//! This module owns the stdin/stdout ↔ socket event loop used by both client
//! and server paths, layering Telnet processing, logging, throttling, and
//! TLS-specific variants on top of a shared poll/select abstraction.
const std = @import("std");

const posix = std.posix;
const config = @import("../config.zig");
const linecodec = @import("linecodec.zig");
const line_editor = @import("line_editor.zig");
const output = @import("output.zig");
const hexdump = @import("hexdump.zig");
const poll_wrapper = @import("../util/poll_wrapper.zig");
const telnet = @import("../protocol/telnet.zig");
const logging = @import("../util/logging.zig");
const platform = @import("../util/platform.zig");
const UringEventLoop = @import("../util/io_uring_wrapper.zig").UringEventLoop;

const BUFFER_SIZE = 8192;

const stream_mod = @import("stream.zig");

/// Dispatches to the platform-specific transfer loop.
///
/// This function is the main entry point for bidirectional data transfer. It
/// uses an event-driven loop to relay data between standard input/output and a
/// network socket. The core logic involves waiting for I/O readiness on both
/// the stdin and socket file descriptors using an efficient OS-specific mechanism
/// (`io_uring`, `IOCP`, or `poll`). When data is ready on one, it's read and
/// then written to the other in a non-blocking fashion.
///
/// On Linux 5.1+, it automatically uses `io_uring` for high-performance async I/O.
/// On Windows, it uses `IOCP`. On other Unix-like systems, it falls back to `poll`.
pub fn bidirectionalTransfer(
    allocator: std.mem.Allocator,
    stream: stream_mod.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLoggerAuto,
    hex_dumper: ?*hexdump.HexDumperAuto,
) !void {
    const prefer_local_editor = cfg.telnet and cfg.telnet_edit_mode == .local;

    // Try io_uring on Linux 5.1+ (10-50x lower CPU usage for bidirectional I/O)
    if (platform.isIoUringSupported() and !prefer_local_editor) {
        logging.logVerbose(cfg, "Using io_uring for bidirectional I/O\n", .{});
        return bidirectionalTransferIoUring(allocator, stream, cfg, output_logger, hex_dumper) catch |err| {
            // Fall back to poll on io_uring errors
            logging.logVerbose(cfg, "io_uring failed ({any}), falling back to poll\n", .{err});
            return bidirectionalTransferPosix(allocator, stream, cfg, output_logger, hex_dumper);
        };
    }

    switch (@import("builtin").os.tag) {
        .linux, .macos => {
            return bidirectionalTransferPosix(allocator, stream, cfg, output_logger, hex_dumper);
        },
        .windows => {
            // Try IOCP on Windows for 4-10x better performance (5-10% CPU vs 30-50% with poll)
            const transfer_iocp = @import("transfer_iocp.zig");
            return transfer_iocp.bidirectionalTransferIocp(allocator, stream, cfg, output_logger, hex_dumper) catch |err| {
                // Fall back to poll-based implementation on IOCP errors
                logging.logVerbose(cfg, "IOCP failed ({any}), falling back to poll\n", .{err});
                return bidirectionalTransferWindows(allocator, stream, cfg, output_logger, hex_dumper);
            };
        },
        else => {
            // share Windows path where poll() is unavailable; select() handles the two-fd case portably.
            return bidirectionalTransferWindows(allocator, stream, cfg, output_logger, hex_dumper);
        },
    }
}

/// Windows bidirectional transfer using poll-based event-driven I/O
/// Matches POSIX implementation for platform parity with timeout support
pub fn bidirectionalTransferWindows(
    allocator: std.mem.Allocator,
    stream: stream_mod.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLoggerAuto,
    hex_dumper: ?*hexdump.HexDumperAuto,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    const enable_local_edit = cfg.telnet and cfg.telnet_edit_mode == .local and stdin.isTty();
    var editor_opt: ?line_editor.LineEditor = null;
    if (enable_local_edit) {
        editor_opt = line_editor.LineEditor.init(allocator, stdout, cfg.crlf) catch |err| blk: {
            logging.logWarning("Telnet local editing disabled: {any}\n", .{err});
            break :blk null;
        };
    }
    defer if (editor_opt) |*editor| editor.deinit();

    // Use poll-based event loop for timeout support and concurrent I/O
    var pollfds = [_]poll_wrapper.pollfd{
        .{ .fd = stdin.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
        .{ .fd = stream.handle(), .events = poll_wrapper.POLL.IN, .revents = 0 },
    };

    // Determine which directions to enable
    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    // Initialize Telnet processor if enabled
    var telnet_processor: ?telnet.TelnetProcessor = if (cfg.telnet)
        telnet.TelnetProcessor.init(allocator, "UNKNOWN", 80, 24, null)
    else
        null;
    defer if (telnet_processor) |*proc| proc.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    // Use unified timeout strategy (Windows doesn't have TTY, always 30s default)
    // Priority: explicit cfg.idle_timeout > platform default (30s)
    const timeout_ms = config.getConnectionTimeout(cfg, .tcp_server, null);

    while (!stdin_closed or !socket_closed) {
        defer _ = arena_state.reset(.retain_capacity);
        const scratch = arena_state.allocator();

        stream.maintain() catch |err| {
            logging.logVerbose(cfg, "Stream maintenance failed: {any}\n", .{err});
        };

        // Set poll events based on what's still open and direction flags
        pollfds[0].events = if (!stdin_closed and can_send) poll_wrapper.POLL.IN else 0;
        pollfds[1].events = if (!socket_closed and can_recv) poll_wrapper.POLL.IN else 0;

        const ready = poll_wrapper.poll(&pollfds, timeout_ms) catch |err| {
            logging.logError(err, "Poll error");
            return err;
        };

        if (ready == 0) {
            // Idle timeout reached
            logging.logVerbose(cfg, "Idle timeout reached\n", .{});
            break;
        }

        // Check for stdin data (send to socket)
        if (pollfds[0].revents & poll_wrapper.POLL.IN != 0) {
            const n = stdin.read(&buffer1) catch 0;

            if (n == 0) {
                stdin_closed = true;

                // Handle half-close: shutdown write-half but keep reading (Windows)
                if (!cfg.no_shutdown) {
                    poll_wrapper.shutdown(stream.handle(), .send) catch |err| {
                        logging.logVerbose(cfg, "Shutdown send failed: {any}\n", .{err});
                    };
                }

                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                if (editor_opt) |*editor| {
                    const sent = try editor.processInput(stream, buffer1[0..n]);
                    if (sent and cfg.delay_ms > 0) {
                        const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                        std.Thread.sleep(delay_ns);
                    }
                    logging.logVerbose(cfg, "Processed {any} bytes via local editor\n", .{n});
                } else {
                    const input_slice = buffer1[0..n];
                    const data = if (cfg.crlf)
                        // CRLF conversion has to allocate when translations occur; we keep
                        // zero-copy behavior for the common path where no conversion is required.
                        try linecodec.convertLfToCrlf(scratch, input_slice)
                    else
                        input_slice;

                    _ = try stream.write(data);

                    // Apply traffic shaping delay after send (Windows)
                    if (cfg.delay_ms > 0) {
                        const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                        std.Thread.sleep(delay_ns);
                    }

                    logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
                }
            }
        }

        // Check for socket data (send to stdout)
        if (pollfds[1].revents & poll_wrapper.POLL.IN != 0) {
            const n = stream.read(&buffer2) catch |err| {
                logging.logError(err, "Socket recv error");
                socket_closed = true;
                continue;
            };

            if (n == 0) {
                socket_closed = true;
                logging.logVerbose(cfg, "Connection closed by peer\n", .{});
            } else {
                var data = buffer2[0..n];

                // Process Telnet IAC sequences if enabled
                if (telnet_processor) |*proc| {
                    const result = try proc.processInputWithAllocator(scratch, data);

                    // Send Telnet response if negotiation generated one
                    if (result.response.len > 0) {
                        // Flush negotiation bytes immediately so the peer's state machine
                        // receives acknowledgements before more payload arrives.
                        _ = try stream.write(result.response);
                        logging.logDebug("Sent Telnet negotiation: {any} bytes\n", .{result.response.len});
                    }

                    // Use cleaned data for output
                    data = result.data;
                }

                // Write to stdout (unless hex dump is enabled and replaces normal output)
                if (!cfg.hex_dump) {
                    try stdout.writeAll(data);
                }

                // Write to output file if logger is configured with error recovery
                if (output_logger) |logger| {
                    logger.write(data) catch |err| {
                        switch (err) {
                            config.IOControlError.DiskFull => {
                                logging.logNormal(cfg, "Error: Disk full - stopping output logging to prevent data loss\n", .{});
                                // Continue without output logging
                            },
                            config.IOControlError.InsufficientPermissions => {
                                logging.logNormal(cfg, "Error: Permission denied - stopping output logging\n", .{});
                                // Continue without output logging
                            },
                            else => {
                                logging.logVerbose(cfg, "Warning: Output logging failed: {any}\n", .{err});
                                // Continue without output logging for this data
                            },
                        }
                    };
                }

                // Hex dump if requested with error recovery
                if (cfg.hex_dump) {
                    if (hex_dumper) |dumper| {
                        dumper.dump(data) catch |err| {
                            switch (err) {
                                config.IOControlError.DiskFull => {
                                    logging.logNormal(cfg, "Error: Disk full - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    hexdump.dumpToStdout(data);
                                },
                                config.IOControlError.InsufficientPermissions => {
                                    logging.logNormal(cfg, "Error: Permission denied - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    hexdump.dumpToStdout(data);
                                },
                                else => {
                                    logging.logVerbose(cfg, "Warning: Hex dump file logging failed: {any}\n", .{err});
                                    // Keep user-visible output even when the logging path fails.
                                    // Fallback to stdout hex dump
                                    hexdump.dumpToStdout(data);
                                },
                            }
                        };
                    } else {
                        // Fallback to inline hex dump if dumper not provided
                        hexdump.dumpToStdout(data);
                    }
                }

                logging.logVerbose(cfg, "Received {any} bytes\n", .{n});
            }
        }

        // Check for errors (HUP, ERR, NVAL)
        if (pollfds[0].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP | poll_wrapper.POLL.NVAL) != 0) {
            stdin_closed = true;
        }
        if (pollfds[1].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP | poll_wrapper.POLL.NVAL) != 0) {
            socket_closed = true;
        }
    }

    // Flush output files before closing with proper error handling
    if (output_logger) |logger| {
        logger.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush output file: {any}\n", .{err});
                },
            }
        };
    }

    if (hex_dumper) |dumper| {
        dumper.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush hex dump file: {any}\n", .{err});
                },
            }
        };
    }
}

/// Bidirectional data transfer between stdin/stdout and socket using `poll`.
///
/// This function implements the I/O event loop for Unix-like systems. It uses
/// the `poll()` system call to wait for I/O readiness on two file descriptors:
/// one for standard input and one for the network socket. The loop continues
/// as long as at least one of the connections is active. Inside the loop, it
/// checks the `revents` field of the `pollfd` structures to see which descriptor
/// is ready. If stdin has data, it's read and written to the socket. If the
/// socket has data, it's read and written to stdout. This ensures non-blocking
/// I/O and efficient data relay.
pub fn bidirectionalTransferPosix(
    allocator: std.mem.Allocator,
    stream: stream_mod.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLoggerAuto,
    hex_dumper: ?*hexdump.HexDumperAuto,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    const posix_local_edit = cfg.telnet and cfg.telnet_edit_mode == .local and stdin.isTty();
    var posix_editor: ?line_editor.LineEditor = null;
    if (posix_local_edit) {
        posix_editor = line_editor.LineEditor.init(allocator, stdout, cfg.crlf) catch |err| blk: {
            logging.logWarning("Telnet local editing disabled: {any}\n", .{err});
            break :blk null;
        };
    }
    defer if (posix_editor) |*editor| editor.deinit();

    var pollfds = [_]poll_wrapper.pollfd{
        .{ .fd = stdin.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
        .{ .fd = stream.handle(), .events = poll_wrapper.POLL.IN, .revents = 0 },
    };

    // Determine which directions to enable
    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    // Initialize Telnet processor if enabled
    var telnet_processor: ?telnet.TelnetProcessor = if (cfg.telnet)
        telnet.TelnetProcessor.init(allocator, "UNKNOWN", 80, 24, null)
    else
        null;
    defer if (telnet_processor) |*proc| proc.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    // Use unified timeout strategy (respects --idle-timeout, then TTY detection)
    // Priority: explicit cfg.idle_timeout > TTY detection > platform default
    const timeout_ms = config.getConnectionTimeout(cfg, .tcp_server, stdin.handle);

    while (!stdin_closed or !socket_closed) {
        defer _ = arena_state.reset(.retain_capacity);
        const scratch = arena_state.allocator();

        stream.maintain() catch |err| {
            logging.logVerbose(cfg, "Stream maintenance failed: {any}\n", .{err});
        };

        // Set poll events based on what's still open
        pollfds[0].events = if (!stdin_closed and can_send) poll_wrapper.POLL.IN else 0;
        pollfds[1].events = if (!socket_closed and can_recv) poll_wrapper.POLL.IN else 0;

        const ready = poll_wrapper.poll(&pollfds, timeout_ms) catch |err| {
            logging.logError(err, "Poll error");
            return err;
        };

        if (ready == 0) {
            // Timeout
            logging.logVerbose(cfg, "Idle timeout reached\n", .{});
            break;
        }

        // Check for stdin data (send to socket)
        if (pollfds[0].revents & poll_wrapper.POLL.IN != 0) {
            const n = stdin.read(&buffer1) catch 0;

            if (n == 0) {
                stdin_closed = true;

                // Handle half-close: shutdown write-half but keep reading
                if (!cfg.no_shutdown) {
                    posix.shutdown(stream.handle(), .send) catch |err| {
                        logging.logVerbose(cfg, "Shutdown send failed: {any}\n", .{err});
                    };
                }

                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                if (posix_editor) |*editor| {
                    const sent = try editor.processInput(stream, buffer1[0..n]);
                    if (sent and cfg.delay_ms > 0) {
                        const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                        std.Thread.sleep(delay_ns);
                    }
                    logging.logVerbose(cfg, "Processed {any} bytes via local editor\n", .{n});
                } else {
                    const input_slice = buffer1[0..n];
                    const data = if (cfg.crlf)
                        // CRLF translation allocates only when new bytes are needed; otherwise
                        // we reuse the original slice to keep the hot path zero-copy.
                        try linecodec.convertLfToCrlf(scratch, input_slice)
                    else
                        input_slice;

                    _ = try stream.write(data);

                    // Apply traffic shaping delay after send
                    if (cfg.delay_ms > 0) {
                        const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                        std.Thread.sleep(delay_ns);
                    }

                    logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
                }
            }
        }

        // Check for socket data (send to stdout)
        if (pollfds[1].revents & poll_wrapper.POLL.IN != 0) {
            const n = stream.read(&buffer2) catch |err| {
                logging.logError(err, "Socket recv error");
                socket_closed = true;
                continue;
            };

            if (n == 0) {
                socket_closed = true;
                logging.logVerbose(cfg, "Connection closed by peer\n", .{});
            } else {
                var data = buffer2[0..n];

                // Process Telnet IAC sequences if enabled
                if (telnet_processor) |*proc| {
                    const result = try proc.processInputWithAllocator(scratch, data);

                    // Send Telnet response if negotiation generated one
                    if (result.response.len > 0) {
                        // Telnet replies must go out immediately so the negotiation state on
                        // both sides stays synchronized; buffering delays can trigger loops.
                        _ = try stream.write(result.response);
                        logging.logDebug("Sent Telnet negotiation: {any} bytes\n", .{result.response.len});
                    }

                    // Use cleaned data for output
                    data = result.data;
                }

                // Write to stdout (unless hex dump is enabled and replaces normal output)
                if (!cfg.hex_dump) {
                    try stdout.writeAll(data);
                }

                // Write to output file if logger is configured with error recovery
                if (output_logger) |logger| {
                    logger.write(data) catch |err| {
                        switch (err) {
                            config.IOControlError.DiskFull => {
                                logging.logNormal(cfg, "Error: Disk full - stopping output logging to prevent data loss\n", .{});
                                // Continue without output logging
                            },
                            config.IOControlError.InsufficientPermissions => {
                                logging.logNormal(cfg, "Error: Permission denied - stopping output logging\n", .{});
                                // Continue without output logging
                            },
                            else => {
                                logging.logVerbose(cfg, "Warning: Output logging failed: {any}\n", .{err});
                                // Continue without output logging for this data
                            },
                        }
                    };
                }

                // Hex dump if requested with error recovery
                if (cfg.hex_dump) {
                    if (hex_dumper) |dumper| {
                        dumper.dump(data) catch |err| {
                            switch (err) {
                                config.IOControlError.DiskFull => {
                                    logging.logNormal(cfg, "Error: Disk full - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    hexdump.dumpToStdout(data);
                                },
                                config.IOControlError.InsufficientPermissions => {
                                    logging.logNormal(cfg, "Error: Permission denied - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    hexdump.dumpToStdout(data);
                                },
                                else => {
                                    logging.logVerbose(cfg, "Warning: Hex dump file logging failed: {any}\n", .{err});
                                    // Ensure the operator still sees the bytes even if the file path fails.
                                    // Fallback to stdout hex dump
                                    hexdump.dumpToStdout(data);
                                },
                            }
                        };
                    } else {
                        // Fallback to inline hex dump if dumper not provided
                        hexdump.dumpToStdout(data);
                    }
                }

                logging.logVerbose(cfg, "Received {any} bytes\n", .{n});
            }
        }

        // Check for errors
        if (pollfds[0].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP | poll_wrapper.POLL.NVAL) != 0) {
            stdin_closed = true;
        }
        if (pollfds[1].revents & (poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP | poll_wrapper.POLL.NVAL) != 0) {
            socket_closed = true;
        }
    }

    // Flush output files before closing with proper error handling
    if (output_logger) |logger| {
        logger.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush output file: {any}\n", .{err});
                },
            }
        };
    }

    if (hex_dumper) |dumper| {
        dumper.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush hex dump file: {any}\n", .{err});
                },
            }
        };
    }
}

/// Bidirectional data transfer using io_uring (Linux 5.1+ only)
///
/// This function implements a high-performance I/O event loop using Linux's
/// `io_uring` interface. Unlike `poll`, which requires separate `read` and
/// `write` syscalls, `io_uring` allows submitting multiple I/O requests to the
/// kernel at once and retrieving their results later.
///
/// The event loop works as follows:
/// 1. Initial `read` requests are submitted for both stdin and the socket.
/// 2. The loop calls `waitForCompletion` to wait for any I/O operation to finish.
/// 3. When a `read` completes, the received data is processed, and a `write`
///    request is submitted to the corresponding destination (e.g., data from
///    stdin is written to the socket).
/// 4. A new `read` request is immediately submitted for the original source to
///    continue listening for data.
/// This cycle of submitting requests and processing completions continues until
/// both connections are closed, enabling fully asynchronous, non-blocking I/O.
pub fn bidirectionalTransferIoUring(
    allocator: std.mem.Allocator,
    stream: stream_mod.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLoggerAuto,
    hex_dumper: ?*hexdump.HexDumperAuto,
) !void {
    // Initialize io_uring with 32-entry queue (2 FDs × 16 operations)
    var ring = try UringEventLoop.init(allocator, 32);
    defer ring.deinit();

    // Operation identifiers used in completion callbacks
    const user_data_stdin_poll: u64 = 0;
    const user_data_socket_read: u64 = 1;
    const user_data_write: u64 = 2;

    // Two separate buffers for concurrent reads
    var buffer_stdin: [BUFFER_SIZE]u8 = undefined;
    var buffer_socket: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Determine which directions to enable
    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    // Track which operations are pending to avoid double-submitting
    var socket_read_pending = false;

    // Initialize Telnet processor if enabled
    var telnet_processor: ?telnet.TelnetProcessor = if (cfg.telnet)
        telnet.TelnetProcessor.init(allocator, "UNKNOWN", 80, 24, null)
    else
        null;
    defer if (telnet_processor) |*proc| proc.deinit();

    // Use unified timeout strategy (respects --idle-timeout, then TTY detection)
    const timeout_ms = config.getConnectionTimeout(cfg, .tcp_server, stdin.handle);

    // Convert timeout to kernel_timespec for io_uring
    const timeout_spec = if (timeout_ms >= 0) blk: {
        const timeout_ns = @as(i64, timeout_ms) * std.time.ns_per_ms;
        break :blk std.os.linux.kernel_timespec{
            .sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
        };
    } else null;

    const poll_in_mask: u32 = @as(u32, @intCast(poll_wrapper.POLL.IN | poll_wrapper.POLL.ERR | poll_wrapper.POLL.HUP));

    // Submit initial operations for both FDs
    if (!stdin_closed and can_send) {
        try ring.submitPoll(stdin.handle, poll_in_mask, user_data_stdin_poll);
    }
    if (!socket_closed and can_recv) {
        try ring.submitRead(stream.handle(), &buffer_socket, user_data_socket_read);
        socket_read_pending = true;
    }

    // Main event loop: process completions until both FDs closed
    main_loop: while (!stdin_closed or !socket_closed) {
        stream.maintain() catch |err| {
            logging.logVerbose(cfg, "Stream maintenance failed: {any}\n", .{err});
        };

        // Wait for completion with timeout
        const cqe = if (timeout_spec) |ts|
            ring.waitForCompletion(&ts) catch |err| {
                if (err == error.Timeout) {
                    logging.logVerbose(cfg, "Idle timeout reached\n", .{});
                    break;
                }
                return err;
            }
        else
            try ring.waitForCompletion(null);

        // Process completion based on user_data
        switch (cqe.user_data) {
            // stdin readiness via io_uring poll
            user_data_stdin_poll => {
                if (cqe.res < 0) {
                    logging.logError(error.ReadError, "stdin poll error");
                    stdin_closed = true;
                } else {
                    const events = @as(u32, @intCast(cqe.res));
                    const mask_err = @as(u32, @intCast(poll_wrapper.POLL.ERR));
                    const mask_nval = @as(u32, @intCast(poll_wrapper.POLL.NVAL));

                    if (events & mask_nval != 0) {
                        logging.logError(error.ReadError, "stdin descriptor became invalid");
                        stdin_closed = true;
                    } else {
                        if (events & mask_err != 0) {
                            logging.logVerbose(cfg, "stdin poll reported error events: 0x{x}\n", .{events});
                        }

                        const n = stdin.read(&buffer_stdin) catch |err| {
                            logging.logError(err, "stdin read error");
                            stdin_closed = true;
                            continue :main_loop;
                        };

                        if (n == 0) {
                            stdin_closed = true;

                            // Handle half-close: shutdown write-half but keep reading
                            if (!cfg.no_shutdown) {
                                posix.shutdown(stream.handle(), .send) catch |err| {
                                    logging.logVerbose(cfg, "Shutdown send failed: {any}\n", .{err});
                                };
                            }

                            if (cfg.close_on_eof) {
                                break;
                            }
                        } else {
                            const input_slice = buffer_stdin[0..n];

                            // Apply CRLF conversion if enabled
                            const data = if (cfg.crlf)
                                try linecodec.convertLfToCrlf(allocator, input_slice)
                            else
                                input_slice;
                            defer if (data.ptr != input_slice.ptr) allocator.free(data);

                            // Submit write to socket (user_data=2 for writes)
                            try ring.submitWrite(stream.handle(), data, user_data_write);

                            // Apply traffic shaping delay after send
                            if (cfg.delay_ms > 0) {
                                const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                                std.Thread.sleep(delay_ns);
                            }

                            logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
                        }
                    }

                    // Resubmit stdin poll (io_uring poll entries are one-shot)
                    if (!stdin_closed and can_send) {
                        try ring.submitPoll(stdin.handle, poll_in_mask, user_data_stdin_poll);
                    }
                }
            },

            // socket read completion
            user_data_socket_read => {
                socket_read_pending = false;

                if (cqe.res < 0) {
                    // Read error (negative errno)
                    logging.logError(error.ReadError, "Socket recv error");
                    socket_closed = true;
                } else if (cqe.res == 0) {
                    // EOF on socket
                    socket_closed = true;
                    logging.logVerbose(cfg, "Connection closed by peer\n", .{});
                } else {
                    // Data read from socket
                    const n: usize = @intCast(cqe.res);
                    var data = buffer_socket[0..n];

                    // Process Telnet IAC sequences if enabled
                    var telnet_response: ?[]u8 = null;
                    if (telnet_processor) |*proc| {
                        const result = try proc.processInput(data);
                        defer allocator.free(result.data);

                        // Send Telnet response if negotiation generated one
                        if (result.response.len > 0) {
                            telnet_response = result.response;
                            // Submit Telnet negotiation write immediately
                            try ring.submitWrite(stream.handle(), result.response, 2);
                            logging.logDebug("Sent Telnet negotiation: {any} bytes\n", .{result.response.len});
                        } else {
                            allocator.free(result.response);
                        }

                        // Use cleaned data for output
                        data = result.data;
                    } else {
                        telnet_response = null;
                    }
                    defer if (telnet_response) |resp| allocator.free(resp);

                    // Write to stdout (unless hex dump is enabled and replaces normal output)
                    if (!cfg.hex_dump) {
                        try stdout.writeAll(data);
                    }

                    // Write to output file if logger is configured with error recovery
                    if (output_logger) |logger| {
                        logger.write(data) catch |err| {
                            switch (err) {
                                config.IOControlError.DiskFull => {
                                    logging.logNormal(cfg, "Error: Disk full - stopping output logging to prevent data loss\n", .{});
                                },
                                config.IOControlError.InsufficientPermissions => {
                                    logging.logNormal(cfg, "Error: Permission denied - stopping output logging\n", .{});
                                },
                                else => {
                                    logging.logVerbose(cfg, "Warning: Output logging failed: {any}\n", .{err});
                                },
                            }
                        };
                    }

                    // Hex dump if requested with error recovery
                    if (cfg.hex_dump) {
                        if (hex_dumper) |dumper| {
                            dumper.dump(data) catch |err| {
                                switch (err) {
                                    config.IOControlError.DiskFull => {
                                        logging.logNormal(cfg, "Error: Disk full - stopping hex dump file logging\n", .{});
                                        hexdump.dumpToStdout(data);
                                    },
                                    config.IOControlError.InsufficientPermissions => {
                                        logging.logNormal(cfg, "Error: Permission denied - stopping hex dump file logging\n", .{});
                                        hexdump.dumpToStdout(data);
                                    },
                                    else => {
                                        logging.logVerbose(cfg, "Warning: Hex dump file logging failed: {any}\n", .{err});
                                        hexdump.dumpToStdout(data);
                                    },
                                }
                            };
                        } else {
                            hexdump.dumpToStdout(data);
                        }
                    }

                    logging.logVerbose(cfg, "Received {any} bytes\n", .{n});

                    // Resubmit socket read (io_uring is one-shot)
                    if (!socket_closed and can_recv) {
                        try ring.submitRead(stream.handle(), &buffer_socket, user_data_socket_read);
                        socket_read_pending = true;
                    }
                }
            },

            // Write completion
            user_data_write => {
                // Write operations are fire-and-forget, just check for errors
                if (cqe.res < 0) {
                    logging.logError(error.WriteError, "Write failed");
                }
            },

            else => {
                // Unknown user_data - should never happen
                logging.logVerbose(cfg, "Warning: Unknown io_uring completion user_data: {any}\n", .{cqe.user_data});
            },
        }
    }

    // Flush output files before closing with proper error handling
    if (output_logger) |logger| {
        logger.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush output file: {any}\n", .{err});
                },
            }
        };
    }

    if (hex_dumper) |dumper| {
        dumper.flush() catch |err| {
            switch (err) {
                config.IOControlError.DiskFull => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal(cfg, "Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush hex dump file: {any}\n", .{err});
                },
            }
        };
    }
}
