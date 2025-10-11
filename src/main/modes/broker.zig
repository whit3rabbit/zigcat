//! Broker/chat server bootstrap.

const std = @import("std");

const config = @import("../../config.zig");
const logging = @import("../../util/logging.zig");
const allowlist = @import("../../net/allowlist.zig");
const broker = @import("../../server/broker.zig");

pub fn runBrokerServer(
    allocator: std.mem.Allocator,
    listen_socket: std.posix.socket_t,
    cfg: *const config.Config,
    access_list: *allowlist.AccessList,
) !void {
    const mode: broker.BrokerMode = if (cfg.chat_mode) .chat else .broker;

    logging.logNormal(cfg, "Starting {any} server on socket {}\n", .{ mode, listen_socket });
    logging.logDebugCfg(cfg, "Server configuration:\n", .{});
    logging.logDebugCfg(cfg, "  Max clients: {}\n", .{cfg.max_clients});
    logging.logDebugCfg(cfg, "  TLS enabled: {}\n", .{cfg.ssl});
    logging.logDebugCfg(cfg, "  Connect timeout: {}ms\n", .{cfg.connect_timeout});
    logging.logDebugCfg(cfg, "  Idle timeout: {}ms\n", .{cfg.idle_timeout});
    logging.logDebugCfg(cfg, "  Access control rules: {} allow, {} deny\n", .{
        access_list.allow_rules.items.len,
        access_list.deny_rules.items.len,
    });

    if (mode == .chat) {
        logging.logDebugCfg(cfg, "  Chat mode settings:\n", .{});
        logging.logDebugCfg(cfg, "    Max nickname length: {}\n", .{cfg.chat_max_nickname_len});
        logging.logDebugCfg(cfg, "    Max message length: {}\n", .{cfg.chat_max_message_len});
    }

    if (cfg.ssl) {
        logging.logDebugCfg(cfg, "  TLS configuration:\n", .{});
        logging.logDebugCfg(cfg, "    Certificate: {?s}\n", .{cfg.ssl_cert});
        logging.logDebugCfg(cfg, "    Private key: {?s}\n", .{cfg.ssl_key});
        logging.logDebugCfg(cfg, "    Verify peer: {}\n", .{cfg.ssl_verify});
    }

    var broker_server = broker.BrokerServer.init(
        allocator,
        listen_socket,
        mode,
        cfg,
        access_list,
    ) catch |err| {
        logging.logError(err, "broker server initialization");
        return err;
    };
    defer broker_server.deinit();

    logging.logDebugCfg(cfg, "Broker server initialized, entering main event loop\n", .{});

    broker_server.run() catch |err| {
        switch (err) {
            broker.BrokerError.MaxClientsReached => {
                logging.logDebugCfg(cfg, "Broker server: Maximum clients reached, continuing\n", .{});
            },
            broker.BrokerError.MultiplexingError => {
                logging.logError(err, "I/O multiplexing");
                return err;
            },
            broker.BrokerError.ListenSocketError => {
                logging.logError(err, "listen socket");
                return err;
            },
            broker.BrokerError.OutOfMemory => {
                logging.logError(err, "memory allocation");
                return err;
            },
            broker.BrokerError.InvalidConfiguration => {
                logging.logError(err, "configuration validation");
                return err;
            },
            else => {
                logging.logError(err, "broker server");
                logging.logWarning("Broker server encountered error, attempting graceful shutdown\n", .{});
            },
        }
    };

    logging.logNormal(cfg, "Broker server shutdown complete\n", .{});
}
