// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! This module contains the server logic specific to Unix Domain Sockets,
//! including path validation, socket cleanup, and managing the accept loop for
//! local IPC.

const std = @import("std");
const posix = std.posix;

const config = @import("../../config.zig");
const common = @import("../common.zig");
const logging = @import("../../util/logging.zig");
const unixsock = @import("../../net/unixsock.zig");
const security = @import("../../util/security.zig");
const output = @import("../../io/output.zig");
const hexdump = @import("../../io/hexdump.zig");
const exec = @import("../../server/exec.zig");
const client = @import("../../client.zig");
const transfer = @import("../../io/transfer.zig");
const Connection = @import("../../net/connection.zig").Connection;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;

pub fn runUnixSocketServer(allocator: std.mem.Allocator, cfg: *const config.Config, socket_path: []const u8) !void {
    if (!unixsock.unix_socket_supported) {
        logging.logError(error.UnixSocketsNotSupported, "Unix domain sockets not supported on this platform");
        return error.UnixSocketsNotSupported;
    }

    if (cfg.ssl) {
        logging.logError(error.InvalidConfiguration, "TLS not meaningful with Unix domain sockets (local communication)");
        return error.InvalidConfiguration;
    }

    if (cfg.udp_mode) {
        logging.logError(error.InvalidConfiguration, "UDP mode not supported with Unix domain sockets");
        return error.InvalidConfiguration;
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Unix socket server configuration:\n", .{});
        logging.logVerbose(cfg, "  Socket path: {s}\n", .{socket_path});
        logging.logVerbose(cfg, "  Keep-open: {}\n", .{cfg.keep_listening});
        logging.logVerbose(cfg, "  Max connections: {}\n", .{cfg.max_conns});
        logging.logVerbose(cfg, "  Connect timeout: {}ms\n", .{cfg.connect_timeout});
        logging.logVerbose(cfg, "  Idle timeout: {}ms\n", .{cfg.idle_timeout});
        if (cfg.exec_command) |cmd| {
            logging.logVerbose(cfg, "  Exec command: {s}\n", .{cmd});
        }
        if (cfg.shell_command) |cmd| {
            logging.logVerbose(cfg, "  Shell command: {s}\n", .{cmd});
        }
    }

    try unixsock.validatePath(socket_path);

    if (cfg.drop_privileges_user) |user| {
        try security.dropPrivileges(user);
    }

    var unix_server = unixsock.UnixSocket.initServer(allocator, socket_path) catch |err| {
        logging.logError(err, "creating Unix socket server");
        logging.logWarning("  Socket path: {s}\n", .{socket_path});
        logging.logWarning("  Check path, permissions, and available resources\n", .{});
        return err;
    };
    defer unix_server.cleanup();

    logging.logNormal(cfg, "Listening on Unix socket: {s}\n", .{socket_path});

    if (cfg.broker_mode or cfg.chat_mode) {
        logging.logError(error.NotImplemented, "Broker/Chat mode not yet supported with Unix domain sockets");
        return error.NotImplemented;
    }

    var connection_count: u32 = 0;

    while (!common.shutdown_requested.load(.seq_cst)) {
        if (cfg.verbose and cfg.keep_listening) {
            logging.logVerbose(cfg, "Waiting for next Unix socket connection...\n", .{});
        }

        var client_conn = acceptUnixSocketWithTimeout(&unix_server, cfg) catch |err| {
            switch (err) {
                error.AcceptTimeout => {
                    if (common.shutdown_requested.load(.seq_cst)) {
                        if (cfg.verbose) {
                            logging.logVerbose(cfg, "Unix socket server shutdown requested\n", .{});
                        }
                        break;
                    }
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Unix socket accept timeout, continuing\n", .{});
                    }
                    continue;
                },
                else => return err,
            }
        };

        const stream = std.net.Stream{ .handle = client_conn.getSocket() };
        const unix_addr = std.net.Address.initUnix(client_conn.getPath()) catch |err| {
            client_conn.close();
            return err;
        };

        connection_count += 1;

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Unix socket connection #{d} from {s}\n", .{ connection_count, client_conn.getPath() });
        }

        if (cfg.max_conns > 0 and connection_count > cfg.max_conns) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Max connections ({any}) reached, closing new Unix connection.\n", .{cfg.max_conns});
            }
            client_conn.close();
            continue;
        }

        if (cfg.max_conns > 0) {
            const ctx = try allocator.create(UnixThreadContext);
            ctx.* = .{
                .allocator = allocator,
                .conn = client_conn,
                .cfg = cfg,
                .connection_id = connection_count,
            };

            var thread = try std.Thread.spawn(.{}, handleUnixClientThread, .{ctx});
            thread.detach();
        } else {
            handleUnixSocketClient(allocator, stream, unix_addr, cfg, connection_count) catch |err| {
                logging.logError(err, "Unix socket client handler");
            };
            client_conn.close();
        }

        if (!cfg.keep_listening) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Not in keep-listening mode, exiting\n", .{});
            }
            break;
        }
    }

    if (common.shutdown_requested.load(.seq_cst)) {
        logging.logNormal(cfg, "Unix socket server shutting down gracefully...\n", .{});
    }
}

const UnixThreadContext = struct {
    allocator: std.mem.Allocator,
    conn: unixsock.UnixSocket,
    cfg: *const config.Config,
    connection_id: u32,
};

fn handleUnixClientThread(ctx: *UnixThreadContext) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.close();

    const stream = std.net.Stream{ .handle = ctx.conn.getSocket() };
    const unix_addr = std.net.Address.initUnix(ctx.conn.getPath()) catch |err| {
        logging.logError(err, "creating Unix address");
        return;
    };

    handleUnixSocketClient(ctx.allocator, stream, unix_addr, ctx.cfg, ctx.connection_id) catch |err| {
        logging.logError(err, "Unix socket client handler");
    };
}

fn acceptUnixSocketWithTimeout(unix_server: *unixsock.UnixSocket, cfg: *const config.Config) !unixsock.UnixSocket {
    const socket = unix_server.getSocket();

    // Use unified timeout for accept (respects accept_timeout, then idle_timeout, then defaults)
    const timeout_ms: i32 = if (cfg.accept_timeout > 0)
        @intCast(cfg.accept_timeout)
    else
        // Use unified timeout for fallback (respects --idle-timeout, then 30s default)
        config.getConnectionTimeout(cfg, .unix_server, null);

    var pollfds = [_]posix.pollfd{
        .{
            .fd = socket,
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = posix.poll(&pollfds, timeout_ms) catch |err| {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Poll error during Unix socket accept: {}\n", .{err});
        }
        return err;
    };

    if (ready == 0) {
        return error.AcceptTimeout;
    }

    if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Socket error during Unix socket accept\n", .{});
        }
        return error.SocketError;
    }

    return unix_server.accept();
}

fn handleUnixSocketClient(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    client_address: std.net.Address,
    cfg: *const config.Config,
    connection_id: u32,
) !void {
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Unix socket client #{} connected\n", .{connection_id});
    }

    if (cfg.exec_command != null or cfg.shell_command != null) {
        const exec_config = if (cfg.exec_command) |prog| blk: {
            break :blk exec.ExecConfig{
                .mode = .direct,
                .program = prog,
                .args = cfg.exec_args.items,
                .require_allow = false,
                .session_config = config.buildExecSessionConfig(cfg),
            };
        } else blk: {
            const shell_cmd = try exec.buildShellCommand(allocator, cfg.shell_command.?);
            defer allocator.free(shell_cmd.args);

            break :blk exec.ExecConfig{
                .mode = .shell,
                .program = shell_cmd.program,
                .args = shell_cmd.args,
                .require_allow = false,
                .session_config = config.buildExecSessionConfig(cfg),
            };
        };

        try exec.executeWithConnection(allocator, stream, exec_config, client_address, cfg);

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Unix socket client #{}: Exec mode completed\n", .{connection_id});
        }
        return;
    }

    var output_logger = output.OutputLoggerAuto.init(allocator, cfg.output_file, cfg.append_output) catch |err| {
        common.handleIOInitError(cfg, err, "output logger");
        return err;
    };
    defer output_logger.deinit();

    var hex_dumper = hexdump.HexDumperAuto.initFromPath(allocator, cfg.hex_dump_file) catch |err| {
        common.handleIOInitError(cfg, err, "hex dumper");
        return err;
    };
    defer hex_dumper.deinit();

    if (cfg.telnet) {
        const connection = Connection.fromSocket(stream.handle);
        var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null);
        defer telnet_conn.deinit();

        try telnet_conn.performServerNegotiation();
        const s = client.telnetConnectionToStream(&telnet_conn);
        try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
    } else {
        const s = client.netStreamToStream(stream);
        try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
    }
}
