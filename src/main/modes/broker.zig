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
    logging.setVerbosity(cfg.verbose_level);

    const mode: broker.BrokerMode = if (cfg.chat_mode) .chat else .broker;

    logging.log(1, "Starting {any} server on socket {}\n", .{ mode, listen_socket });
    logging.logDebug("Server configuration:\n", .{});
    logging.logDebug("  Max clients: {}\n", .{cfg.max_clients});
    logging.logDebug("  TLS enabled: {}\n", .{cfg.ssl});
    logging.logDebug("  Connect timeout: {}ms\n", .{cfg.connect_timeout});
    logging.logDebug("  Idle timeout: {}ms\n", .{cfg.idle_timeout});
    logging.logDebug("  Access control rules: {} allow, {} deny\n", .{
        access_list.allow_rules.items.len,
        access_list.deny_rules.items.len,
    });

    if (mode == .chat) {
        logging.logDebug("  Chat mode settings:\n", .{});
        logging.logDebug("    Max nickname length: {}\n", .{cfg.chat_max_nickname_len});
        logging.logDebug("    Max message length: {}\n", .{cfg.chat_max_message_len});
    }

    if (cfg.ssl) {
        logging.logDebug("  TLS configuration:\n", .{});
        logging.logDebug("    Certificate: {?s}\n", .{cfg.ssl_cert});
        logging.logDebug("    Private key: {?s}\n", .{cfg.ssl_key});
        logging.logDebug("    Verify peer: {}\n", .{cfg.ssl_verify});
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

    logging.logDebug("Broker server initialized, entering main event loop\n", .{});

    broker_server.run() catch |err| {
        switch (err) {
            broker.BrokerError.MaxClientsReached => {
                logging.logDebug("Broker server: Maximum clients reached, continuing\n", .{});
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

    logging.log(1, "Broker server shutdown complete\n", .{});
}
