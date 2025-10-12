// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Server/broker entrypoints for zigcat.

const std = @import("std");
const posix = std.posix;

const config = @import("../../config.zig");
const common = @import("../common.zig");
const logging = @import("../../util/logging.zig");

const net = @import("../../net/socket.zig");
const tcp = @import("../../net/tcp.zig");
const udp = @import("../../net/udp.zig");
const unixsock = @import("../../net/unixsock.zig");
const allowlist = @import("../../net/allowlist.zig");
const listen = @import("../../server/listen.zig");
const exec = @import("../../server/exec.zig");
const security = @import("../../util/security.zig");
const tls = @import("../../tls/tls.zig");
const client = @import("../../client.zig");
const output = @import("../../io/output.zig");
const hexdump = @import("../../io/hexdump.zig");
const transfer = @import("../../io/transfer.zig");
const tls_transfer = @import("../../io/tls_transfer.zig");
const Connection = @import("../../net/connection.zig").Connection;
const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;

const broker_mode = @import("broker.zig");
const unix_mode = @import("unix.zig");

fn runDualStackServer(allocator: std.mem.Allocator, cfg: *const config.Config, port: u16) !void {
    var server_v4 = std.net.Address.parseIp("0.0.0.0", port) catch |err| {
        logging.logError(err, "parsing IPv4 address");
        return err;
    };
    var listener_v4 = server_v4.listen(.{ .reuse_address = true }) catch |err| {
        logging.logError(err, "listening on IPv4");
        return err;
    };
    defer listener_v4.deinit();

    var server_v6 = std.net.Address.parseIp("::", port) catch |err| {
        logging.logError(err, "parsing IPv6 address");
        return err;
    };
    var listener_v6 = server_v6.listen(.{ .reuse_address = true }) catch |err| {
        logging.logError(err, "listening on IPv6");
        return err;
    };
    defer listener_v6.deinit();

    logging.logNormal(cfg, "Listening on 0.0.0.0:{d} and :::_:{d} (dual-stack)...\n", .{ port, port });

    var access_list_obj: ?allowlist.AccessList = null;
    if (cfg.allow_list.items.len > 0 or cfg.deny_list.items.len > 0 or cfg.allow_file != null or cfg.deny_file != null) {
        access_list_obj = try listen.createAccessListFromConfig(allocator, cfg);
    }
    defer if (access_list_obj) |*al| al.deinit();

    var pollfds = [_]std.posix.pollfd{
        .{ .fd = listener_v4.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = listener_v6.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var connection_count: u32 = 0;
    while (!common.shutdown_requested.load(.seq_cst)) {
        const ready = std.posix.poll(&pollfds, -1) catch |err| {
            if (common.shutdown_requested.load(.seq_cst)) break;
            return err;
        };

        if (ready == 0) continue;

        if (pollfds[0].revents != 0) {
            const conn = if (access_list_obj) |*al|
                listen.acceptWithAccessControl(allocator, &listener_v4, al, cfg.verbose) catch {
                    if (common.shutdown_requested.load(.seq_cst)) break;
                    continue;
                }
            else
                listener_v4.accept() catch {
                    if (common.shutdown_requested.load(.seq_cst)) break;
                    continue;
                };
            connection_count += 1;
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Accepted connection #{any} from {any} (IPv4)\n", .{ connection_count, conn.address });
            }
            if (cfg.max_conns > 0) {
                const ctx = try allocator.create(ThreadContext);
                ctx.* = .{ .allocator = allocator, .conn = conn, .cfg = cfg };
                var thread = try std.Thread.spawn(.{}, handleClientThread, .{ctx});
                thread.detach();
            } else {
                handleClient(allocator, conn.stream, conn.address, cfg) catch |err| {
                    logging.logError(err, "handling client");
                };
                conn.stream.close();
            }
        }

        if (pollfds[1].revents != 0) {
            const conn = if (access_list_obj) |*al|
                listen.acceptWithAccessControl(allocator, &listener_v6, al, cfg.verbose) catch {
                    if (common.shutdown_requested.load(.seq_cst)) break;
                    continue;
                }
            else
                listener_v6.accept() catch {
                    if (common.shutdown_requested.load(.seq_cst)) break;
                    continue;
                };
            connection_count += 1;
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Accepted connection #{any} from {any} (IPv6)\n", .{ connection_count, conn.address });
            }
            if (cfg.max_conns > 0) {
                const ctx = try allocator.create(ThreadContext);
                ctx.* = .{ .allocator = allocator, .conn = conn, .cfg = cfg };
                var thread = try std.Thread.spawn(.{}, handleClientThread, .{ctx});
                thread.detach();
            } else {
                handleClient(allocator, conn.stream, conn.address, cfg) catch |err| {
                    logging.logError(err, "handling client");
                };
                conn.stream.close();
            }
        }

        if (!cfg.keep_listening and connection_count > 0) {
            break;
        }
    }
}

pub fn runServer(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    if (cfg.unix_socket_path) |socket_path| {
        return unix_mode.runUnixSocketServer(allocator, cfg, socket_path);
    }

    const port = if (cfg.positional_args.len > 0)
        try std.fmt.parseInt(u16, cfg.positional_args[0], 10)
    else
        0;

    const bind_addr_str = if (cfg.bind_addr) |addr|
        addr
    else if (cfg.listen_mode and cfg.positional_args.len > 1)
        cfg.positional_args[1]
    else
        null;

    if (bind_addr_str == null and !cfg.ipv4_only and !cfg.ipv6_only) {
        return runDualStackServer(allocator, cfg, port);
    }

    const final_bind_addr_str = if (bind_addr_str) |s| s else if (cfg.ipv6_only) "::" else "0.0.0.0";

    const bind_addr = try std.net.Address.resolveIp(final_bind_addr_str, port);

    const should_drop_privileges = cfg.drop_privileges_user != null;
    const is_privileged_port = port < 1024;

    if (should_drop_privileges and !is_privileged_port) {
        try security.dropPrivileges(cfg.drop_privileges_user.?);
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "Server configuration:\n", .{});
        logging.logVerbose(cfg, "  Bind address: {s}:{d}\n", .{ final_bind_addr_str, port });
        logging.logVerbose(cfg, "  Protocol: {s}\n", .{if (cfg.udp_mode) "UDP" else "TCP"});
        logging.logVerbose(cfg, "  Keep-open: {}\n", .{cfg.keep_listening});
        logging.logVerbose(cfg, "  Max connections: {}\n", .{cfg.max_conns});
        if (cfg.exec_command) |cmd| {
            logging.logVerbose(cfg, "  Exec command: {s}\n", .{cmd});
        }
        if (cfg.shell_command) |cmd| {
            logging.logVerbose(cfg, "  Shell command: {s}\n", .{cmd});
        }
    }

    const has_access_control = cfg.allow_list.items.len > 0 or cfg.deny_list.items.len > 0 or cfg.allow_file != null or cfg.deny_file != null;

    if (cfg.udp_mode) {
        const udp_socket = try udp.openUdpServer(final_bind_addr_str, port);
        defer net.closeSocket(udp_socket);

        if (should_drop_privileges and is_privileged_port) {
            try security.dropPrivileges(cfg.drop_privileges_user.?);
        }

        logging.logNormal(cfg, "Listening on {s}:{d} (UDP)...\n", .{ final_bind_addr_str, port });
        try handleUdpServer(allocator, udp_socket, cfg);
        return;
    }

    if (cfg.sctp_mode) {
        logging.logWarning("Note: SCTP mode not fully implemented\n", .{});
    }

    var server = try bind_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    if (should_drop_privileges and is_privileged_port) {
        try security.dropPrivileges(cfg.drop_privileges_user.?);
    }

    var access_list_obj: ?allowlist.AccessList = null;
    defer if (access_list_obj) |*al| al.deinit();

    if (has_access_control) {
        access_list_obj = try listen.createAccessListFromConfig(allocator, cfg);
        if (cfg.verbose) {
            logging.logVerbose(cfg, "Access control enabled:\n", .{});
            logging.logVerbose(cfg, "  Allow rules: {any}\n", .{access_list_obj.?.allow_rules.items.len});
            logging.logVerbose(cfg, "  Deny rules: {any}\n", .{access_list_obj.?.deny_rules.items.len});
        }
    }

    if (cfg.broker_mode or cfg.chat_mode) {
        var default_access_list = allowlist.AccessList.init(allocator);
        defer if (access_list_obj == null) default_access_list.deinit();
        const access_list_ptr = if (access_list_obj) |*al| al else &default_access_list;
        try broker_mode.runBrokerServer(allocator, server.stream.handle, cfg, access_list_ptr);
        return;
    }

    logging.logNormal(cfg, "Listening on {s}:{d}...\n", .{ final_bind_addr_str, port });

    var connection_count: u32 = 0;

    while (!common.shutdown_requested.load(.seq_cst)) {
        if (cfg.verbose and cfg.keep_listening) {
            logging.logVerbose(cfg, "Waiting for next connection...\n", .{});
        }

        const conn = if (access_list_obj) |*al|
            listen.acceptWithAccessControl(allocator, &server, al, cfg.verbose) catch |err| {
                if (common.shutdown_requested.load(.seq_cst)) {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Server shutdown requested, stopping accept loop\n", .{});
                    }
                    break;
                }
                return err;
            }
        else
            server.accept() catch |err| {
                if (common.shutdown_requested.load(.seq_cst)) {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Server shutdown requested, stopping accept loop\n", .{});
                    }
                    break;
                }
                return err;
            };

        if (common.shutdown_requested.load(.seq_cst)) {
            conn.stream.close();
            break;
        }

        connection_count += 1;

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Accepted connection #{any} from {any}\n", .{ connection_count, conn.address });
        }

        if (cfg.max_conns > 0 and connection_count > cfg.max_conns) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Max connections ({any}) reached, closing new connection.\n", .{cfg.max_conns});
            }
            conn.stream.close();
            continue;
        }

        if (cfg.max_conns > 0) {
            const ctx = try allocator.create(ThreadContext);
            ctx.* = .{
                .allocator = allocator,
                .conn = conn,
                .cfg = cfg,
            };

            var thread = try std.Thread.spawn(.{}, handleClientThread, .{ctx});
            thread.detach();
        } else {
            handleClient(allocator, conn.stream, conn.address, cfg) catch |err| {
                logging.logError(err, "handling client");
            };
            conn.stream.close();
        }

        if (!cfg.keep_listening) {
            break;
        }
    }

    if (common.shutdown_requested.load(.seq_cst)) {
        logging.logNormal(cfg, "Server shutting down gracefully...\n", .{});
    }
}

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    conn: std.net.Server.Connection,
    cfg: *const config.Config,
};

fn handleClientThread(ctx: *ThreadContext) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.conn.stream.close();

    handleClient(ctx.allocator, ctx.conn.stream, ctx.conn.address, ctx.cfg) catch |err| {
        logging.logError(err, "client handler");
    };
}

fn handleClient(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    client_address: std.net.Address,
    cfg: *const config.Config,
) !void {
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Handling client from {any}\n", .{client_address});
    }

    if (cfg.exec_command != null or cfg.shell_command != null) {
        const exec_config = if (cfg.exec_command) |prog| blk: {
            break :blk exec.ExecConfig{
                .mode = .direct,
                .program = prog,
                .args = cfg.exec_args.items,
                .require_allow = cfg.require_allow_with_exec,
                .session_config = config.buildExecSessionConfig(cfg),
                .redirect_stdin = cfg.exec_redirect_stdin,
                .redirect_stdout = cfg.exec_redirect_stdout,
                .redirect_stderr = cfg.exec_redirect_stderr,
            };
        } else blk: {
            const shell_cmd = try exec.buildShellCommand(allocator, cfg.shell_command.?);
            defer allocator.free(shell_cmd.args);

            break :blk exec.ExecConfig{
                .mode = .shell,
                .program = shell_cmd.program,
                .args = shell_cmd.args,
                .require_allow = cfg.require_allow_with_exec,
                .session_config = config.buildExecSessionConfig(cfg),
                .redirect_stdin = cfg.exec_redirect_stdin,
                .redirect_stdout = cfg.exec_redirect_stdout,
                .redirect_stderr = cfg.exec_redirect_stderr,
            };
        };

        if (cfg.telnet) {
            const connection = Connection.fromSocket(stream.handle);
            var telnet_conn = try TelnetConnection.init(connection, allocator, null, null, null);
            defer telnet_conn.deinit();

            if (cfg.verbose) {
                logging.logVerbose(cfg, "Telnet protocol mode enabled for exec mode (server), performing server negotiation...\n", .{});
            }

            try telnet_conn.performServerNegotiation();
            try exec.executeWithTelnetConnection(allocator, &telnet_conn, exec_config, client_address, cfg);
        } else {
            try exec.executeWithConnection(allocator, stream, exec_config, client_address, cfg);
        }
        return;
    }

    var output_logger = output.OutputLoggerAuto.init(allocator, cfg.output_file, cfg.append_output) catch |err| {
        common.handleIOInitError(cfg, err, "output logger");
        return err;
    };
    defer output_logger.deinit();

    var hex_dumper = hexdump.HexDumperAuto.init(allocator, cfg.hex_dump_file) catch |err| {
        common.handleIOInitError(cfg, err, "hex dumper");
        return err;
    };
    defer hex_dumper.deinit();

    if (cfg.verbose) {
        if (output_logger.isEnabled()) {
            const mode = if (output_logger.isAppendMode()) "append" else "truncate";
            logging.logVerbose(cfg, "Output logging enabled: {s} (mode: {s})\n", .{ output_logger.getPath().?, mode });
        }
        if (hex_dumper.isFileEnabled()) {
            logging.logVerbose(cfg, "Hex dump file enabled: {s}\n", .{hex_dumper.getPath().?});
        }
        if (cfg.hex_dump and !hex_dumper.isFileEnabled()) {
            logging.logVerbose(cfg, "Hex dump to stdout enabled\n", .{});
        }
        if (cfg.send_only) {
            logging.logVerbose(cfg, "I/O mode: send-only\n", .{});
        } else if (cfg.recv_only) {
            logging.logVerbose(cfg, "I/O mode: receive-only\n", .{});
        }
    }

    if (cfg.ssl) {
        if (!cfg.ssl_verify) {
            logging.logWarning("⚠️  SSL certificate verification is DISABLED in server mode.", .{});
        }

        const tls_config = tls.TlsConfig{
            .cert_file = cfg.ssl_cert,
            .key_file = cfg.ssl_key,
            .verify_peer = cfg.ssl_verify,
            .trust_file = cfg.ssl_trustfile,
            .crl_file = cfg.ssl_crl,
            .cipher_suites = cfg.ssl_ciphers,
            .server_name = cfg.ssl_servername,
            .alpn_protocols = cfg.ssl_alpn,
        };

        if (tls.isTlsEnabled()) {
            var tls_conn = try tls.acceptTls(allocator, stream.handle, tls_config);
            defer tls_conn.deinit();

            if (cfg.telnet) {
                const telnet_connection = Connection.fromTls(tls_conn);
                var telnet_conn = try TelnetConnection.init(telnet_connection, allocator, null, null, null);
                defer telnet_conn.deinit();

                try telnet_conn.performServerNegotiation();
                const s = client.telnetConnectionToStream(&telnet_conn);
                try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
            } else {
                const s = client.tlsConnectionToStream(&tls_conn);
                try transfer.bidirectionalTransfer(allocator, s, cfg, &output_logger, &hex_dumper);
            }
            return;
        } else {
            tls.displayTlsNotAvailableError();
            return error.TlsNotEnabled;
        }
    }

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

fn handleUdpServer(
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    cfg: *const config.Config,
) !void {
    var buffer: [8192]u8 = undefined;
    var client_map = std.AutoHashMap([64]u8, u32).init(allocator);
    defer client_map.deinit();

    var connection_count: u32 = 0;

    while (!common.shutdown_requested.load(.seq_cst)) {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = socket,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        // Use unified timeout strategy (UDP uses 30s default, changed from 1s for consistency)
        const timeout_ms = config.getConnectionTimeout(cfg, .udp_server, null);

        const ready = posix.poll(&pollfds, timeout_ms) catch |err| {
            if (common.shutdown_requested.load(.seq_cst)) {
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "UDP server shutdown requested during poll\n", .{});
                }
                break;
            }
            logging.logError(err, "poll");
            return err;
        };

        if (ready == 0) {
            if (common.shutdown_requested.load(.seq_cst)) {
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "UDP server shutdown requested\n", .{});
                }
                break;
            }

            if (cfg.idle_timeout > 0) {
                if (cfg.verbose) {
                    logging.logVerbose(cfg, "UDP server idle timeout reached\n", .{});
                }
                break;
            }

            continue;
        }

        if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
            logging.logError(error.SocketError, "UDP server socket");
            break;
        }

        const result = udp.recvFromUdp(socket, &buffer) catch |err| {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "UDP recv error: {}\n", .{err});
            }
            continue;
        };

        var addr_key: [64]u8 = [_]u8{0} ** 64;
        const addr_str = try std.fmt.bufPrint(&addr_key, "{any}", .{result.addr});
        _ = addr_str; // addr_key already contains the formatted address
        const entry = try client_map.getOrPut(addr_key);
        if (!entry.found_existing) {
            connection_count += 1;
            entry.value_ptr.* = connection_count;

            if (cfg.verbose) {
                logging.logVerbose(cfg, "New UDP client #{d} from {any}\n", .{ connection_count, result.addr });
            }
        }

        if (cfg.verbose) {
            logging.logVerbose(cfg, "Received {d} bytes from {any}\n", .{ result.bytes, result.addr });
        }

        if (cfg.exec_command != null or cfg.shell_command != null) {
            logging.logWarning("Exec mode with UDP is not fully supported\n", .{});
            logging.logNormal(cfg, "{s}\n", .{buffer[0..result.bytes]});
        } else {
            const data = buffer[0..result.bytes];
            // Data output handled by output_logger and hex_dumper below

            var output_logger = output.OutputLoggerAuto.init(allocator, cfg.output_file, cfg.append_output) catch |err| blk: {
                if (cfg.verbose) {
                    logging.logWarning("Failed to initialize output logger for UDP: {}\n", .{err});
                }
                break :blk output.OutputLoggerAuto.init(allocator, null, false) catch unreachable;
            };
            defer output_logger.deinit();

            var hex_dumper = hexdump.HexDumperAuto.init(allocator, cfg.hex_dump_file) catch |err| blk: {
                if (cfg.verbose) {
                    logging.logWarning("Failed to initialize hex dumper for UDP: {}\n", .{err});
                }
                break :blk hexdump.HexDumperAuto.init(allocator, null) catch unreachable;
            };
            defer hex_dumper.deinit();

            output_logger.write(data) catch |err| {
                if (cfg.verbose) {
                    logging.logWarning("Failed to write to output file: {}\n", .{err});
                }
            };

            if (cfg.hex_dump) {
                hex_dumper.dump(data) catch |err| {
                    if (cfg.verbose) {
                        logging.logWarning("Failed to write hex dump: {}\n", .{err});
                    }
                };
            }

            if (!cfg.recv_only) {
                _ = udp.sendToUdp(socket, data, result.addr) catch |err| {
                    if (cfg.verbose) {
                        logging.logVerbose(cfg, "Failed to send response: {}\n", .{err});
                    }
                };
            }
        }

        if (!cfg.keep_listening) {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Not in keep-listening mode, exiting after first datagram\n", .{});
            }
            break;
        }
    }

    if (common.shutdown_requested.load(.seq_cst)) {
        logging.logNormal(cfg, "UDP server shutting down gracefully...\n", .{});
    }

    if (cfg.verbose) {
        logging.logVerbose(cfg, "UDP server shutting down, handled {d} unique clients\n", .{connection_count});
    }
}
