//! Cross-platform I/O pipeline that mirrors ncat's interactive behavior.
//! This module owns the stdin/stdout ↔ socket event loop used by both client
//! and server paths, layering Telnet processing, logging, throttling, and
//! TLS-specific variants on top of a shared poll/select abstraction.
const std = @import("std");
const posix = std.posix;
const config = @import("../config.zig");
const linecodec = @import("linecodec.zig");
const output = @import("output.zig");
const hexdump = @import("hexdump.zig");
const poll_wrapper = @import("../util/poll_wrapper.zig");
const telnet = @import("../protocol/telnet.zig");
const logging = @import("../util/logging.zig");

const BUFFER_SIZE = 8192;

/// Dispatches to the platform-specific transfer loop.
/// Non-Windows targets prefer the POSIX poll-based implementation, while the
/// fallback case intentionally reuses the Windows path because the select()
/// shim works anywhere Zig lacks native poll support (e.g. niche Unix targets).
pub fn bidirectionalTransfer(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    switch (@import("builtin").os.tag) {
        .linux, .macos => {
            return bidirectionalTransferPosix(allocator, stream, cfg, output_logger, hex_dumper);
        },
        .windows => {
            return bidirectionalTransferWindows(allocator, stream, cfg, output_logger, hex_dumper);
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
    stream: std.net.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Use poll-based event loop for timeout support and concurrent I/O
    var pollfds = [_]poll_wrapper.pollfd{
        .{ .fd = stdin.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
        .{ .fd = stream.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
    };

    // Determine which directions to enable
    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    // Initialize Telnet processor if enabled
    var telnet_processor: ?telnet.TelnetProcessor = if (cfg.telnet)
        telnet.TelnetProcessor.init(allocator, "UNKNOWN", 80, 24)
    else
        null;
    defer if (telnet_processor) |*proc| proc.deinit();

    // Use unified timeout strategy (Windows doesn't have TTY, always 30s default)
    // Priority: explicit cfg.idle_timeout > platform default (30s)
    const timeout_ms = config.getConnectionTimeout(cfg, .tcp_server, null);

    while (!stdin_closed or !socket_closed) {
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
                    poll_wrapper.shutdown(stream.handle, .send) catch |err| {
                        logging.logVerbose(cfg, "Shutdown send failed: {any}\n", .{err});
                    };
                }

                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                const input_slice = buffer1[0..n];
                const data = if (cfg.crlf)
                    // CRLF conversion has to allocate when translations occur; we keep
                    // zero-copy behavior for the common path where no conversion is required.
                    try linecodec.convertLfToCrlf(allocator, input_slice)
                else
                    input_slice;
                // Only free if a new buffer was allocated
                defer if (data.ptr != input_slice.ptr) allocator.free(data);

                _ = try stream.write(data);

                // Apply traffic shaping delay after send (Windows)
                if (cfg.delay_ms > 0) {
                    const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                    std.Thread.sleep(delay_ns);
                }

                logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
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
                var telnet_response: ?[]u8 = null;
                if (telnet_processor) |*proc| {
                    const result = try proc.processInput(data);
                    defer allocator.free(result.data);

                    // Send Telnet response if negotiation generated one
                    if (result.response.len > 0) {
                        telnet_response = result.response;
                        // Flush negotiation bytes immediately so the peer's state machine
                        // receives acknowledgements before more payload arrives.
                        _ = try stream.write(result.response);
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
                                logging.logNormal("Error: Disk full - stopping output logging to prevent data loss\n", .{});
                                // Continue without output logging
                            },
                            config.IOControlError.InsufficientPermissions => {
                                logging.logNormal("Error: Permission denied - stopping output logging\n", .{});
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
                                    logging.logNormal("Error: Disk full - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    printHexDump(data);
                                },
                                config.IOControlError.InsufficientPermissions => {
                                    logging.logNormal("Error: Permission denied - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    printHexDump(data);
                                },
                                else => {
                                    logging.logVerbose(cfg, "Warning: Hex dump file logging failed: {any}\n", .{err});
                                    // Keep user-visible output even when the logging path fails.
                                    // Fallback to stdout hex dump
                                    printHexDump(data);
                                },
                            }
                        };
                    } else {
                        // Fallback to inline hex dump if dumper not provided
                        printHexDump(data);
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
                    logging.logNormal("Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal("Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
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
                    logging.logNormal("Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal("Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush hex dump file: {any}\n", .{err});
                },
            }
        };
    }
}

/// Bidirectional data transfer between stdin/stdout and socket
pub fn bidirectionalTransferPosix(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    cfg: *const config.Config,
    output_logger: ?*output.OutputLogger,
    hex_dumper: ?*hexdump.HexDumper,
) !void {
    var buffer1: [BUFFER_SIZE]u8 = undefined;
    var buffer2: [BUFFER_SIZE]u8 = undefined;

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var pollfds = [_]poll_wrapper.pollfd{
        .{ .fd = stdin.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
        .{ .fd = stream.handle, .events = poll_wrapper.POLL.IN, .revents = 0 },
    };

    // Determine which directions to enable
    const can_send = !cfg.recv_only;
    const can_recv = !cfg.send_only;

    var stdin_closed = false;
    var socket_closed = false;

    // Initialize Telnet processor if enabled
    var telnet_processor: ?telnet.TelnetProcessor = if (cfg.telnet)
        telnet.TelnetProcessor.init(allocator, "UNKNOWN", 80, 24)
    else
        null;
    defer if (telnet_processor) |*proc| proc.deinit();

    // Use unified timeout strategy (respects --idle-timeout, then TTY detection)
    // Priority: explicit cfg.idle_timeout > TTY detection > platform default
    const timeout_ms = config.getConnectionTimeout(cfg, .tcp_server, stdin.handle);

    while (!stdin_closed or !socket_closed) {
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
                    posix.shutdown(stream.handle, .send) catch |err| {
                        logging.logVerbose(cfg, "Shutdown send failed: {any}\n", .{err});
                    };
                }

                if (cfg.close_on_eof) {
                    break;
                }
            } else {
                const input_slice = buffer1[0..n];
                const data = if (cfg.crlf)
                    // CRLF translation allocates only when new bytes are needed; otherwise
                    // we reuse the original slice to keep the hot path zero-copy.
                    try linecodec.convertLfToCrlf(allocator, input_slice)
                else
                    input_slice;
                // Only free if a new buffer was allocated
                defer if (data.ptr != input_slice.ptr) allocator.free(data);

                _ = try posix.send(stream.handle, data, 0);

                // Apply traffic shaping delay after send
                if (cfg.delay_ms > 0) {
                    const delay_ns = cfg.delay_ms * std.time.ns_per_ms;
                    std.Thread.sleep(delay_ns);
                }

                logging.logVerbose(cfg, "Sent {any} bytes\n", .{data.len});
            }
        }

        // Check for socket data (send to stdout)
        if (pollfds[1].revents & poll_wrapper.POLL.IN != 0) {
            const n = posix.recv(stream.handle, &buffer2, 0) catch |err| {
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
                var telnet_response: ?[]u8 = null;
                if (telnet_processor) |*proc| {
                    const result = try proc.processInput(data);
                    defer allocator.free(result.data);

                    // Send Telnet response if negotiation generated one
                    if (result.response.len > 0) {
                        telnet_response = result.response;
                        // Telnet replies must go out immediately so the negotiation state on
                        // both sides stays synchronized; buffering delays can trigger loops.
                        _ = try posix.send(stream.handle, result.response, 0);
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
                                logging.logNormal("Error: Disk full - stopping output logging to prevent data loss\n", .{});
                                // Continue without output logging
                            },
                            config.IOControlError.InsufficientPermissions => {
                                logging.logNormal("Error: Permission denied - stopping output logging\n", .{});
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
                                    logging.logNormal("Error: Disk full - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    printHexDump(data);
                                },
                                config.IOControlError.InsufficientPermissions => {
                                    logging.logNormal("Error: Permission denied - stopping hex dump file logging\n", .{});
                                    // Continue with stdout hex dump only
                                    printHexDump(data);
                                },
                                else => {
                                    logging.logVerbose(cfg, "Warning: Hex dump file logging failed: {any}\n", .{err});
                                    // Ensure the operator still sees the bytes even if the file path fails.
                                    // Fallback to stdout hex dump
                                    printHexDump(data);
                                },
                            }
                        };
                    } else {
                        // Fallback to inline hex dump if dumper not provided
                        printHexDump(data);
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
                    logging.logNormal("Critical: Output file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal("Critical: Output file flush failed - permission denied. Data may be lost.\n", .{});
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
                    logging.logNormal("Critical: Hex dump file flush failed - disk full. Data may be lost.\n", .{});
                },
                config.IOControlError.InsufficientPermissions => {
                    logging.logNormal("Critical: Hex dump file flush failed - permission denied. Data may be lost.\n", .{});
                },
                else => {
                    logging.logVerbose(cfg, "Warning: Failed to flush hex dump file: {any}\n", .{err});
                },
            }
        };
    }
}

fn printHexDump(data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        std.debug.print("{x:0>8}: ", .{i});

        // Hex bytes
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                std.debug.print("{x:0>2} ", .{data[i + j]});
            } else {
                std.debug.print("   ", .{});
            }
        }

        std.debug.print(" |", .{});

        // ASCII representation
        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (c >= 32 and c <= 126) {
                std.debug.print("{c}", .{c});
            } else {
                std.debug.print(".", .{});
            }
        }

        std.debug.print("|\n", .{});
    }
}
