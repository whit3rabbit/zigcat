// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! # Core Broker Server Module
//!
//! This module implements the central broker server that manages multiple client
//! connections and provides data relay functionality for both broker and chat modes.
//! It is built around a single-threaded, event-driven architecture using `poll()`
//! for I/O multiplexing.
//!
//! ## Design Goals
//!
//! - **I/O Multiplexing**: Efficiently handles many concurrent, mostly idle clients
//!   using a non-blocking, `poll()`-based event loop.
//! - **Event-Driven**: The `BrokerServer.run()` method contains the main event loop
//!   that processes network events (new connections, incoming data, disconnects).
//! - **Resource Management**: Integrates a `BufferPool` for recycling I/O buffers to
//!   reduce memory allocation overhead and a `FlowControlManager` to prevent
//!   resource exhaustion under heavy load.
//! - **Mode Agnostic**: The core relay logic is shared between the simple `--broker`
//!   mode (raw data relay) and the more complex `--chat` mode (line-based messages
//!   with nickname handling).
//!
//! ## Architecture Overview
//!
//! ```text
//! +------------------+      +--------------------+      +------------------+
//! | Listen Socket    |<---->| BrokerServer       |<---->| ClientPool       |
//! | (Accepts new     |      | (Main Event Loop)  |      | (Manages active  |
//! |  connections)    |      |                    |      |  client state)   |
//! +------------------+      +--------------------+      +------------------+
//!                             |                ^
//!                             |                |
//!                             v                |
//!                           +--------------------+
//!                           | PollContext        |
//!                           | (Manages poll()     |
//!                           |  file descriptors) |
//!                           +--------------------+
//! ```
//!
//! ## Event Loop Logic
//!
//! The `run()` function orchestrates the server's operation:
//! 1.  **Poll**: It calls `poll()` on the listen socket and all connected client sockets,
//!     waiting for I/O events or a timeout.
//! 2.  **Accept**: If the listen socket is readable, `acceptNewClient()` is called to
//!     handle the new connection, including access control checks and TLS handshakes.
//! 3.  **Read**: If a client socket is readable, `message_handler.handleClientData()` is
//!     invoked to read the data, process it according to the server mode (`broker` or
//!     `chat`), and queue it for relaying.
//! 4.  **Write**: If a client socket is writable (meaning its send buffer has space),
//!     `flushWriteBuffer()` is called to send any pending data from its write buffer.
//! 5.  **Disconnect**: If a socket has a `HUP` or `ERR` event, `removeClient()` is
//!     called to clean up the client's resources.
//! 6.  **Maintenance**: On a poll timeout, `performMaintenance()` is called to check
//!     for and remove idle clients.
//!
//! ## Thread Safety
//!
//! The `BrokerServer` and its components are designed to be run in a single thread.
//! All state is managed within this thread, avoiding the need for complex synchronization
//! primitives.

const std = @import("std");
const builtin = @import("builtin");
const Connection = @import("../net/connection.zig").Connection;
const ClientPool = @import("broker/client_manager.zig").ClientPool;
const ClientInfo = @import("broker/client_manager.zig").ClientInfo;
const BufferPool = @import("buffer_pool.zig").BufferPool;
const BufferPoolConfig = @import("buffer_pool.zig").BufferPoolConfig;
const FlowControlManager = @import("flow_control.zig").FlowControlManager;
const FlowControlConfig = @import("flow_control.zig").FlowControlConfig;
const PerformanceMonitor = @import("performance_monitor.zig").PerformanceMonitor;
const PerformanceConfig = @import("performance_monitor.zig").PerformanceConfig;
const allowlist = @import("../net/allowlist.zig");
const Config = @import("../config.zig").Config;
const tls = @import("../tls/tls.zig");
const logging = @import("../util/logging.zig");
const message_handler = @import("broker/message_handler.zig");
const protocols = @import("broker/protocols.zig");
const main_common = @import("../main/common.zig");

/// Broker operation modes
pub const BrokerMode = enum {
    /// Raw data relay mode - forwards all data as-is
    broker,
    /// Line-oriented chat mode with nicknames and formatting
    chat,
};

/// Broker server errors
pub const BrokerError = error{
    /// Maximum number of clients reached
    MaxClientsReached,
    /// Client not found in pool
    ClientNotFound,
    /// Failed to relay data to clients
    RelayFailed,
    /// I/O multiplexing error (poll/select failed)
    MultiplexingError,
    /// Listen socket error
    ListenSocketError,
    /// Client socket error
    ClientSocketError,
    /// Memory allocation error
    OutOfMemory,
    /// Configuration error
    InvalidConfiguration,
    /// Message exceeds maximum buffer size
    MessageTooLong,
    /// Access denied by ACL
    AccessDenied,

    /// Client disconnected after too many failed nickname attempts
    TooManyFailedAttempts,
};

/// DoS Protection: Maximum lines to process per poll tick
/// Prevents unbounded message processing that can freeze the server
/// with rapid message flooding (e.g., 5000 newlines causing 41-second freeze).
/// Remaining lines stay buffered for next poll event.
pub const MAX_LINES_PER_TICK: usize = 100;

/// Poll context for I/O multiplexing
const PollContext = struct {
    /// Listen socket poll descriptor
    listen_fd: std.posix.pollfd,
    /// Client socket poll descriptors
    client_fds: std.ArrayList(std.posix.pollfd),
    /// Mapping from socket descriptor to client ID
    /// SECURITY FIX (2025-10-10): Changed from u32 to u64 to match ClientPool.addClient() return type
    client_id_map: std.AutoHashMap(std.posix.socket_t, u64),
    /// Persistent cache for poll array (optimization to avoid repeated allocations)
    /// This cache is reused across poll() calls, only reallocating when growing
    poll_fds_cache: std.ArrayList(std.posix.pollfd),
    /// Allocator for dynamic arrays
    allocator: std.mem.Allocator,

    /// Initialize poll context with listen socket
    pub fn init(allocator: std.mem.Allocator, listen_socket: std.posix.socket_t) PollContext {
        return PollContext{
            .listen_fd = std.posix.pollfd{
                .fd = listen_socket,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .client_fds = std.ArrayList(std.posix.pollfd){},
            .client_id_map = std.AutoHashMap(std.posix.socket_t, u64).init(allocator),
            .poll_fds_cache = std.ArrayList(std.posix.pollfd){},
            .allocator = allocator,
        };
    }

    /// Clean up poll context resources
    pub fn deinit(self: *PollContext) void {
        self.client_fds.deinit(self.allocator);
        self.client_id_map.deinit();
        self.poll_fds_cache.deinit(self.allocator);
    }

    /// Add a client socket to the poll set
    pub fn addClient(self: *PollContext, socket: std.posix.socket_t, client_id: u64) !void {
        // Add to poll descriptor list
        try self.client_fds.append(self.allocator, std.posix.pollfd{
            .fd = socket,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });

        // Add to socket-to-ID mapping
        try self.client_id_map.put(socket, client_id);
    }

    /// Update poll events for a client socket (add/remove POLL.OUT)
    pub fn updateClientEvents(self: *PollContext, socket: std.posix.socket_t, enable_write: bool) void {
        for (self.client_fds.items) |*client_fd| {
            if (client_fd.fd == socket) {
                if (enable_write) {
                    // Enable both read and write events
                    client_fd.events = std.posix.POLL.IN | std.posix.POLL.OUT;
                } else {
                    // Only read events (default)
                    client_fd.events = std.posix.POLL.IN;
                }
                return;
            }
        }
    }

    /// Remove a client socket from the poll set
    pub fn removeClient(self: *PollContext, socket: std.posix.socket_t) void {
        // Remove from socket-to-ID mapping
        _ = self.client_id_map.remove(socket);

        // Remove from poll descriptor list
        var i: usize = 0;
        while (i < self.client_fds.items.len) {
            if (self.client_fds.items[i].fd == socket) {
                _ = self.client_fds.swapRemove(i);
                break;
            }
            i += 1;
        }
    }

    /// Perform poll operation on all sockets
    /// OPTIMIZATION: Uses persistent cache to avoid allocating new poll array on every iteration
    /// This reduces CPU overhead by 5-10% at high connection rates (10K-20K polls/second)
    pub fn poll(self: *PollContext, timeout_ms: i32) !i32 {
        // Create combined poll array: [listen_fd, ...client_fds]
        const total_fds = 1 + self.client_fds.items.len;

        // Reuse cache - only reallocates if growing beyond current capacity
        try self.poll_fds_cache.resize(self.allocator, total_fds);
        const poll_fds = self.poll_fds_cache.items;

        // Add listen socket
        poll_fds[0] = self.listen_fd;

        // Add client sockets
        for (self.client_fds.items, 0..) |client_fd, i| {
            poll_fds[i + 1] = client_fd;
        }

        // Perform poll operation
        const result = std.posix.poll(poll_fds, timeout_ms) catch {
            return BrokerError.MultiplexingError;
        };

        // Update revents in our structures
        self.listen_fd.revents = poll_fds[0].revents;
        for (self.client_fds.items, 0..) |*client_fd, i| {
            client_fd.revents = poll_fds[i + 1].revents;
        }

        return @intCast(result);
    }

    /// Get client ID from socket descriptor
    pub fn getClientId(self: *PollContext, socket: std.posix.socket_t) ?u64 {
        return self.client_id_map.get(socket);
    }
};

/// Core broker server managing multiple client connections
pub const BrokerServer = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Listen socket for accepting new connections
    listen_socket: std.posix.socket_t,
    /// Client connection pool
    clients: ClientPool,
    /// Buffer pool for efficient memory management
    buffer_pool: BufferPool,
    /// Flow control manager for resource management
    flow_control: FlowControlManager,
    /// Performance monitor for metrics and optimization
    performance_monitor: PerformanceMonitor,
    /// Broker operation mode
    mode: BrokerMode,
    /// Configuration reference
    config: *const Config,
    /// Access control list
    access_list: *allowlist.AccessList,
    /// I/O multiplexing context
    poll_context: PollContext,
    /// Server running flag
    running: bool = false,
    /// Maximum number of clients allowed
    max_clients: u32,
    /// Active nicknames for chat mode duplicate detection
    /// SECURITY FIX (2025-10-10): Changed from u32 to u64 to match ClientPool client IDs
    chat_nicknames: std.StringHashMap(u64),

    /// Initialize broker server
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for server resources
    /// - `listen_socket`: Pre-configured listen socket
    /// - `mode`: Broker operation mode (broker or chat)
    /// - `config`: Configuration reference
    /// - `access_list`: Access control list for client filtering
    ///
    /// ## Returns
    /// Initialized broker server ready to run
    pub fn init(
        allocator: std.mem.Allocator,
        listen_socket: std.posix.socket_t,
        mode: BrokerMode,
        config: *const Config,
        access_list: *allowlist.AccessList,
    ) !BrokerServer {
        // Configure buffer pool based on expected load
        const buffer_config = BufferPoolConfig{
            .buffer_size = 4096,
            .initial_pool_size = 32,
            .max_pool_size = @min(config.max_clients * 4, 512), // 4 buffers per client, max 512
            .max_memory_usage = 32 * 1024 * 1024, // 32MB default
            .flow_control_threshold = 0.8,
            .cleanup_threshold = 0.9,
        };

        // Configure flow control based on system resources
        const flow_config = FlowControlConfig{
            .max_memory_usage = buffer_config.max_memory_usage,
            .flow_control_threshold = 0.75,
            .throttle_threshold = 0.85,
            .emergency_threshold = 0.95,
            .max_bytes_per_second_per_client = 1024 * 1024, // 1MB/s per client
            .max_pending_bytes_per_client = 64 * 1024, // 64KB pending
            .adaptive_flow_control = true,
        };

        // Configure performance monitoring
        const perf_config = PerformanceConfig{
            .monitoring_interval_ms = 1000,
            .history_size = 300, // 5 minutes of history
            .enable_memory_monitoring = true,
            .enable_cpu_monitoring = true,
            .enable_network_monitoring = true,
            .memory_alert_threshold = 85.0,
            .cpu_alert_threshold = 90.0,
        };

        return BrokerServer{
            .allocator = allocator,
            .listen_socket = listen_socket,
            .clients = ClientPool.init(allocator),
            .buffer_pool = try BufferPool.init(allocator, buffer_config),
            .flow_control = FlowControlManager.init(allocator, flow_config),
            .performance_monitor = try PerformanceMonitor.init(allocator, perf_config),
            .mode = mode,
            .config = config,
            .access_list = access_list,
            .poll_context = PollContext.init(allocator, listen_socket),
            .max_clients = if (config.max_conns > 0) config.max_conns else 50, // Default to 50 clients
            .chat_nicknames = std.StringHashMap(u64).init(allocator),
        };
    }

    /// Clean up broker server resources
    pub fn deinit(self: *BrokerServer) void {
        self.clearChatNicknames();
        self.chat_nicknames.deinit();
        self.clients.deinit();
        self.buffer_pool.deinit();
        self.flow_control.deinit();
        self.performance_monitor.deinit();
        self.poll_context.deinit();
    }

    /// Main broker server event loop with enhanced logging and timeout handling
    ///
    /// Runs the main event loop that:
    /// 1. Polls for I/O events on all sockets
    /// 2. Accepts new client connections
    /// 3. Reads data from clients
    /// 4. Relays data to other clients
    /// 5. Handles client disconnections
    ///
    /// ## Returns
    /// Error if server cannot continue operation
    pub fn run(self: *BrokerServer) !void {
        self.running = true;

        // Log server startup with comprehensive information
        logging.logNormal(self.config, "Broker server starting in {any} mode (max {} clients, TLS: {}, Access control: {})\n", .{ self.mode, self.max_clients, self.config.ssl, self.access_list.allow_rules.items.len > 0 or self.access_list.deny_rules.items.len > 0 });

        logging.logDebugCfg(self.config, "Server configuration: connect_timeout={}ms, idle_timeout={}ms\n", .{
            self.config.connect_timeout,
            self.config.idle_timeout,
        });

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        while (self.running and !main_common.shutdown_requested.load(.seq_cst)) {
            defer _ = arena_state.reset(.retain_capacity);
            const scratch = arena_state.allocator();

            // Update performance monitoring
            self.performance_monitor.update();

            // Update flow control with current resource usage
            const memory_info = self.buffer_pool.getMemoryInfo();
            self.flow_control.updateResourceInfo(memory_info.current_usage);

            // Calculate poll timeout based on configuration and flow control
            var poll_timeout_ms = if (self.config.idle_timeout > 0)
                @min(1000, self.config.idle_timeout / 2) // Check for idle clients more frequently
            else
                1000; // Default 1 second timeout

            // Reduce timeout under high load for more responsive flow control
            const flow_level = self.flow_control.getCurrentLevel();
            poll_timeout_ms = switch (flow_level) {
                .normal => poll_timeout_ms,
                .light => @min(poll_timeout_ms, 500),
                .moderate => @min(poll_timeout_ms, 250),
                .heavy => @min(poll_timeout_ms, 100),
                .emergency => @min(poll_timeout_ms, 50),
            };

            // Poll for I/O events
            const events = self.poll_context.poll(@intCast(poll_timeout_ms)) catch |err| {
                logging.logError(err, "poll");
                logging.logDebug("Poll error, continuing: {}\n", .{err});
                self.performance_monitor.recordError();
                continue;
            };

            if (events == 0) {
                // Timeout - perform maintenance tasks
                logging.logTrace("Poll timeout, performing maintenance (flow level: {})\n", .{flow_level});
                self.performMaintenance(scratch);
                continue;
            }

            logging.logTrace("Poll returned {} events\n", .{events});

            // Check for new client connections
            if (self.poll_context.listen_fd.revents & std.posix.POLL.IN != 0) {
                logging.logTrace("New client connection available\n", .{});
                self.acceptNewClient(scratch) catch |err| {
                    logging.logError(err, "accept");
                    logging.logDebug("Accept error: {}\n", .{err});
                };
            }

            // Check for client data and connection events
            for (self.poll_context.client_fds.items) |client_fd| {
                if (client_fd.revents & std.posix.POLL.IN != 0) {
                    if (self.poll_context.getClientId(client_fd.fd)) |client_id| {
                        logging.logTrace("Data available from client {}\n", .{client_id});
                        message_handler.handleClientData(self, client_id, scratch) catch |err| {
                            logging.logError(err, "client data handling");
                            logging.logDebug("Client {} data error: {}\n", .{ client_id, err });
                            // Remove problematic client
                            self.removeClient(client_id, scratch);
                        };
                    }
                }

                // Check for client disconnection or errors
                if (client_fd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                    if (self.poll_context.getClientId(client_fd.fd)) |client_id| {
                        // Log the specific type of disconnection with enhanced detail
                        const event_type = if (client_fd.revents & std.posix.POLL.HUP != 0)
                            "hangup"
                        else if (client_fd.revents & std.posix.POLL.ERR != 0)
                            "error"
                        else
                            "invalid";

                        logging.logDebug("Client {} disconnected ({s})\n", .{ client_id, event_type });
                        logging.logTrace("Client {} poll events: HUP={}, ERR={}, NVAL={}\n", .{
                            client_id,
                            client_fd.revents & std.posix.POLL.HUP != 0,
                            client_fd.revents & std.posix.POLL.ERR != 0,
                            client_fd.revents & std.posix.POLL.NVAL != 0,
                        });

                        self.removeClient(client_id, scratch);
                    }
                }

                // Check for write readiness (for clients with pending data)
                if (client_fd.revents & std.posix.POLL.OUT != 0) {
                    if (self.poll_context.getClientId(client_fd.fd)) |client_id| {
                        logging.logTrace("Client {} ready for write\n", .{client_id});
                        self.flushWriteBuffer(client_id) catch |err| {
                            logging.logError(err, "write buffer flush");
                            logging.logDebug("Client {} flush error: {}\n", .{ client_id, err });
                            // Remove problematic client
                            self.removeClient(client_id, scratch);
                        };
                    }
                }
            }
        }

        // Check if shutdown was requested
        if (main_common.shutdown_requested.load(.seq_cst)) {
            logging.log(1, "Broker server received shutdown signal\n", .{});
        }

        logging.log(1, "Broker server shutting down\n", .{});
        logging.logDebug("Final client count: {}\n", .{self.clients.getClientCount()});

        // Send shutdown notification to all clients
        if (self.mode == .chat) {
            const shutdown_msg = "*** Server is shutting down\n";
            self.relayToClients(shutdown_msg, 0) catch |err| {
                logging.logError(err, "shutdown notification");
            };
        }

        // Log final performance summary
        const perf_summary = self.performance_monitor.getPerformanceSummary();
        logging.log(1, "Performance summary: {d:.1}% memory, {d:.1}% CPU, {d:.1} msg/s, {} errors\n", .{
            perf_summary.memory_usage_percent,
            perf_summary.cpu_usage_percent,
            perf_summary.messages_per_second,
            perf_summary.relay_errors,
        });
    }

    /// Accept a new client connection with access control, TLS support, and comprehensive logging
    fn acceptNewClient(self: *BrokerServer, scratch: std.mem.Allocator) !void {
        // Check client limit before accepting
        const current_clients = self.clients.getClientCount();
        if (current_clients >= self.max_clients) {
            // Accept and immediately close to clear the pending connection
            var client_addr: std.posix.sockaddr = undefined;
            var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const client_socket = std.posix.accept(
                self.listen_socket,
                &client_addr,
                &client_addr_len,
                0,
            ) catch {
                return BrokerError.ListenSocketError;
            };

            // Convert sockaddr to std.net.Address for logging
            const client_address = std.net.Address.initPosix(@alignCast(&client_addr));

            // Log the rejected connection with verbosity-aware logging
            logging.logDebug("Client limit reached ({}/{}), connection from {any} rejected\n", .{ current_clients, self.max_clients, client_address });
            if (self.config.verbose) {
                logging.logWarning("Client limit reached, connection rejected from {any}\n", .{client_address});
            }

            std.posix.close(client_socket);
            return BrokerError.MaxClientsReached;
        }

        // Accept the connection
        var client_addr: std.posix.sockaddr = undefined;
        var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const client_socket = std.posix.accept(
            self.listen_socket,
            &client_addr,
            &client_addr_len,
            0,
        ) catch {
            logging.logError(error.ListenSocketError, "accept");
            return BrokerError.ListenSocketError;
        };

        // Convert sockaddr to std.net.Address for access control and logging
        // NOTE: std.net.Address.initPosix() only supports IPv4/IPv6, not Unix sockets.
        // For Unix sockets (AF.UNIX), we create a dummy localhost address since
        // access control lists don't apply to local Unix socket connections.
        const is_unix_socket = client_addr.family == std.posix.AF.UNIX;
        const client_address = if (is_unix_socket)
            std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0) // Dummy localhost for Unix sockets
        else
            std.net.Address.initPosix(@alignCast(&client_addr));

        // Check access control with enhanced logging
        // NOTE: For Unix socket clients, IP-based access control is bypassed by using
        // a dummy localhost address. This ensures IP allow/deny lists don't affect
        // local Unix socket connections, which is the correct behavior.
        if (!self.access_list.isAllowed(client_address)) {
            if (!is_unix_socket) {
                logging.logConnection(client_address, "DENIED");
                logging.logDebug("Access control denied connection from {any}\n", .{client_address});
            }
            std.posix.close(client_socket);
            return BrokerError.AccessDenied;
        }

        // Apply connection timeout if configured
        if (self.config.connect_timeout > 0) {
            const timeout_ms = self.config.connect_timeout;
            logging.logTrace("Setting connection timeout to {}ms for client socket\n", .{timeout_ms});

            // Set socket timeout options using struct timeval (required on macOS/Unix)
            const timeval = std.posix.timeval{
                .sec = @intCast(timeout_ms / 1000),
                .usec = @intCast((timeout_ms % 1000) * 1000),
            };

            // Set receive timeout
            std.posix.setsockopt(client_socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch |err| {
                logging.logDebug("Failed to set receive timeout: {}\n", .{err});
                std.posix.close(client_socket);
                return BrokerError.ClientSocketError;
            };

            // Set send timeout
            std.posix.setsockopt(client_socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeval)) catch |err| {
                logging.logDebug("Failed to set send timeout: {}\n", .{err});
                std.posix.close(client_socket);
                return BrokerError.ClientSocketError;
            };
        }

        // Create connection wrapper (plain or TLS)
        var connection = if (self.config.ssl) blk: {
            logging.logTrace("Establishing TLS connection for client from {any}\n", .{client_address});

            // Create TLS configuration for server
            const tls_config = tls.TlsConfig{
                .cert_file = self.config.ssl_cert,
                .key_file = self.config.ssl_key,
                .verify_peer = false, // Server doesn't verify client certs by default
                .server_name = null,
            };

            // Perform TLS handshake
            const tls_conn = tls.acceptTls(self.allocator, client_socket, tls_config) catch |err| {
                logging.logError(err, "TLS handshake");
                logging.logDebug("TLS handshake failed for client from {any}: {}\n", .{ client_address, err });
                std.posix.close(client_socket);
                return err;
            };

            logging.logDebug("TLS handshake completed for client from {any}\n", .{client_address});
            break :blk Connection.fromTls(tls_conn);
        } else Connection.fromSocket(client_socket);

        // Add client to pool
        const client_id = self.clients.addClient(connection) catch |err| {
            logging.logError(err, "client pool add");
            connection.close();
            return err;
        };

        // Add to flow control tracking
        self.flow_control.addClient(client_id) catch |err| {
            logging.logError(err, "flow control add");
            self.clients.removeClient(client_id);
            return err;
        };

        // Add to poll context
        self.poll_context.addClient(client_socket, client_id) catch |err| {
            logging.logError(err, "poll context add");
            self.flow_control.removeClient(client_id);
            self.clients.removeClient(client_id);
            return err;
        };

        // Log successful connection with appropriate verbosity
        logging.logConnection(client_address, "ACCEPT");
        logging.logDebug("Client {} connected from {any} (TLS: {}, Total clients: {})\n", .{ client_id, client_address, connection.isTls(), current_clients + 1 });

        // Handle mode-specific client initialization
        switch (self.mode) {
            .broker => {
                logging.logTrace("Client {} initialized in broker mode\n", .{client_id});
            },
            .chat => {
                // Chat mode - send welcome message and prompt for nickname
                protocols.initializeChatClient(self, client_id) catch |err| {
                    logging.logError(err, "chat initialization");
                    logging.logDebug("Chat initialization failed for client {}: {}\n", .{ client_id, err });
                    self.removeClient(client_id, scratch);
                    return err;
                };
            },
        }
    }

    /// Remove a client from the server with comprehensive cleanup and enhanced logging
    fn removeClient(self: *BrokerServer, client_id: u64, scratch: std.mem.Allocator) void {
        // Get client info before removal for chat mode cleanup and statistics
        var client_nickname: ?[]const u8 = null;
        var client_stats: ?struct {
            connect_time: i64,
            bytes_sent: u64,
            bytes_received: u64,
            was_tls: bool,
        } = null;
        var client_socket: ?std.posix.socket_t = null;

        if (self.clients.getClient(client_id)) |client| {
            // Save nickname for chat mode announcement
            if (client.nickname) |nick| {
                client_nickname = scratch.dupe(u8, nick) catch null;
            }

            if (self.mode == .chat) {
                self.unregisterChatNicknameById(client_id);
            }

            // Save statistics for logging
            client_stats = .{
                .connect_time = client.connect_time,
                .bytes_sent = client.bytes_sent,
                .bytes_received = client.bytes_received,
                .was_tls = client.connection.isTls(),
            };

            // Save socket FD for poll context removal
            client_socket = client.connection.getSocket();
        }

        // Remove from flow control tracking
        self.flow_control.removeClient(client_id);

        // Remove from client pool (this closes the connection and frees resources)
        self.clients.removeClient(client_id);
        logging.logTrace("Removed client {} from client pool\n", .{client_id});

        // Remove from poll context AFTER closing connection to prevent use-after-free
        if (client_socket) |socket| {
            self.poll_context.removeClient(socket);
            logging.logTrace("Removed client {} socket from poll context\n", .{client_id});
        }

        // Handle chat mode leave announcement
        if (self.mode == .chat and client_nickname != null) {
            const leave_msg = std.fmt.allocPrint(
                scratch,
                "*** {s} left the chat\n",
                .{client_nickname.?},
            ) catch {
                logging.logError(error.OutOfMemory, "chat leave message");
                return;
            };

            // Relay leave message (no sender to exclude)
            self.relayToClients(leave_msg, 0) catch |err| {
                logging.logError(err, "chat leave relay");
            };

            // Log chat client disconnection with enhanced details
            logging.log(1, "Client {} ({s}) left the chat", .{ client_id, client_nickname.? });
            if (client_stats) |stats| {
                const now = std.time.timestamp();
                const duration = now - stats.connect_time;
                logging.log(1, " ({}s, {}↑/{}↓ bytes, TLS: {})", .{ duration, stats.bytes_sent, stats.bytes_received, stats.was_tls });
            }
            logging.log(1, "\n", .{});
        } else {
            // Log regular client disconnection
            logging.logDebug("Client {} disconnected", .{client_id});
            if (client_stats) |stats| {
                const now = std.time.timestamp();
                const duration = now - stats.connect_time;
                logging.logDebug(" ({}s, {}↑/{}↓ bytes, TLS: {})", .{ duration, stats.bytes_sent, stats.bytes_received, stats.was_tls });
            }
            logging.logDebug("\n", .{});
        }

        // Log current client count after removal
        const remaining_clients = self.clients.getClientCount();
        logging.logDebug("Active clients after removal: {} / {} max\n", .{ remaining_clients, self.max_clients });

        // Log capacity utilization for trace level
        if (logging.isVerbosityEnabled(self.config, .debug)) {
            const utilization = @as(f64, @floatFromInt(remaining_clients)) / @as(f64, @floatFromInt(self.max_clients)) * 100.0;
            logging.logTraceCfg(self.config, "Server capacity utilization: {d:.1}%\n", .{utilization});
        }
    }

    /// Log detailed client statistics for debugging
    fn logClientStatistics(self: *BrokerServer, scratch: std.mem.Allocator) void {
        const stats = self.clients.getClientStatistics(scratch) catch {
            logging.logError(error.OutOfMemory, "client statistics");
            return;
        };
        defer {
            for (stats) |*stat| {
                stat.deinit(scratch);
            }
            scratch.free(stats);
        }

        logging.logTrace("=== Client Statistics ===\n", .{});
        for (stats) |stat| {
            logging.logTrace("Client {}: ", .{stat.client_id});
            if (stat.nickname) |nick| {
                logging.logTrace("'{s}' ", .{nick});
            }
            logging.logTrace("({}s connected, {}s idle, {}↑/{}↓ bytes)\n", .{
                stat.connection_duration,
                stat.idle_time,
                stat.bytes_sent,
                stat.bytes_received,
            });
        }
        logging.logTrace("=== End Statistics ===\n", .{});
    }

    /// Perform periodic maintenance tasks with enhanced logging
    fn performMaintenance(self: *BrokerServer, scratch: std.mem.Allocator) void {
        logging.logTrace("Performing maintenance tasks\n", .{});

        // Remove idle clients if timeout is configured
        if (self.config.idle_timeout > 0) {
            const timeout_seconds = self.config.idle_timeout / 1000; // Convert ms to seconds
            const removed = self.clients.removeIdleClients(@intCast(timeout_seconds));
            if (removed > 0) {
                logging.logDebug("Removed {} idle clients (timeout: {}s)\n", .{ removed, timeout_seconds });
            }
        }

        // Perform connection health checks
        self.performConnectionHealthCheck(scratch);

        // Log client statistics periodically
        const client_count = self.clients.getClientCount();
        if (client_count > 0) {
            logging.logTrace("Active clients: {} / {} max\n", .{ client_count, self.max_clients });

            // Log detailed client statistics if very verbose
            if (logging.isVerbosityEnabled(self.config, .trace)) {
                self.logClientStatistics(scratch);
            }
        }
    }

    /// Check if an error indicates a connection failure that should trigger client removal
    fn isConnectionError(self: *BrokerServer, err: anyerror) bool {
        _ = self; // Suppress unused parameter warning
        return switch (err) {
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ConnectionAborted,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.ConnectionTimedOut,
            error.NotConnected,
            => true,
            else => false,
        };
    }

    /// Perform connection health checks on all clients with enhanced logging
    ///
    /// ## Performance
    /// Uses callback pattern to eliminate client ID list allocation, reducing allocation overhead
    /// during periodic maintenance checks.
    fn performConnectionHealthCheck(self: *BrokerServer, scratch: std.mem.Allocator) void {
        var failed_clients = std.ArrayList(u64){};
        defer failed_clients.deinit(scratch);

        // Context for health check callback (stack-allocated)
        const HealthCheckContext = struct {
            server: *BrokerServer,
            failed_clients: *std.ArrayList(u64),
            client_count: usize,
            allocator: std.mem.Allocator,
        };

        var context = HealthCheckContext{
            .server = self,
            .failed_clients = &failed_clients,
            .client_count = 0,
            .allocator = scratch,
        };

        // Use callback pattern to iterate clients without allocating client ID list
        self.clients.forEachClient(&context, struct {
            fn healthCheckCallback(ctx: *HealthCheckContext, client_id: u64, client: *ClientInfo) void {
                ctx.client_count += 1;

                // Check if connection is still valid by attempting to get socket status
                const socket = client.connection.getSocket();

                // Use SO_ERROR to check for socket errors
                var error_code: i32 = 0;
                const error_bytes = std.mem.asBytes(&error_code);

                std.posix.getsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.ERROR, error_bytes) catch |err| {
                    // If getsockopt fails, assume socket is bad
                    logging.logTrace("Client {} health check failed (getsockopt): {}\n", .{ client_id, err });
                    error_code = 1;
                };

                if (error_code != 0) {
                    logging.logDebug("Client {} failed health check (socket error: {})\n", .{ client_id, error_code });
                    ctx.failed_clients.append(ctx.allocator, client_id) catch {};
                } else {
                    logging.logTrace("Client {} health check passed\n", .{client_id});
                }
            }
        }.healthCheckCallback);

        if (context.client_count == 0) return;

        logging.logTrace("Performing health check on {} clients\n", .{context.client_count});

        // Remove failed clients
        const removed_count = self.clients.removeFailedClients(failed_clients.items);
        if (removed_count > 0) {
            logging.logDebug("Health check removed {} failed clients\n", .{removed_count});
        }
    }

    /// Get performance and resource information
    pub fn getPerformanceInfo(self: *const BrokerServer) struct {
        client_count: usize,
        memory_usage_percent: f32,
        flow_control_level: @import("flow_control.zig").FlowControlLevel,
        messages_per_second: f32,
        bytes_per_second: f32,
        active_alerts: usize,
    } {
        const perf_summary = self.performance_monitor.getPerformanceSummary();
        const memory_info = self.buffer_pool.getMemoryInfo();

        return .{
            .client_count = self.clients.getClientCount(),
            .memory_usage_percent = memory_info.usage_percent,
            .flow_control_level = self.flow_control.getCurrentLevel(),
            .messages_per_second = perf_summary.messages_per_second,
            .bytes_per_second = perf_summary.bytes_per_second,
            .active_alerts = perf_summary.active_alerts,
        };
    }

    /// Relay data to all clients except the sender
    ///
    /// Broadcasts the given data to all connected clients, excluding the sender.
    /// This is used for both broker mode (raw relay) and chat mode (formatted messages).
    ///
    /// ## Parameters
    /// - `data`: Data to relay to clients
    /// - `exclude_client_id`: Client ID to exclude from relay (typically the sender), or 0 for broadcast to all
    ///
    /// ## Returns
    /// Error if relay fails critically (individual client failures are logged but don't stop relay)
    ///
    /// ## Performance
    /// Uses zero-allocation callback pattern instead of allocating client ID list on every relay.
    /// This eliminates heap allocation churn in high-traffic scenarios.
    pub fn relayToClients(self: *BrokerServer, data: []const u8, exclude_client_id: u64) !void {
        if (data.len == 0) {
            logging.logTrace("Relay called with empty data, skipping\n", .{});
            return;
        }

        // Context for relay callback (stack-allocated, no heap allocation)
        const RelayContext = struct {
            data: []const u8,
            exclude_client_id: u64,
            server: *BrokerServer,
            successful_relays: usize,
            failed_relays: usize,
        };

        var context = RelayContext{
            .data = data,
            .exclude_client_id = exclude_client_id,
            .server = self,
            .successful_relays = 0,
            .failed_relays = 0,
        };

        // Use callback pattern to iterate clients without heap allocation
        self.clients.forEachClient(&context, struct {
            fn relayCallback(ctx: *RelayContext, client_id: u64, client: *ClientInfo) void {
                // Skip the sender
                if (client_id == ctx.exclude_client_id) {
                    return;
                }

                const was_empty = client.write_buffer.items.len == 0;

                client.write_buffer.appendSlice(ctx.server.allocator, ctx.data) catch |err| {
                    logging.logDebug("Failed to queue relay data for client {}: {}\n", .{ client_id, err });
                    ctx.failed_relays += 1;
                    if (ctx.server.isConnectionError(err)) {
                        logging.logTrace("Client {} connection error during relay queue, will be removed\n", .{client_id});
                    }
                    return;
                };

                ctx.server.flow_control.recordDataPending(client_id, @intCast(ctx.data.len));

                // Attempt immediate flush to minimize latency
                ctx.server.flushWriteBuffer(client_id) catch |err| {
                    logging.logDebug("Failed to flush relay buffer for client {}: {}\n", .{ client_id, err });
                    ctx.failed_relays += 1;
                    if (ctx.server.isConnectionError(err)) {
                        logging.logTrace("Client {} connection error during relay flush, will be removed\n", .{client_id});
                    }
                    return;
                };

                ctx.successful_relays += 1;

                logging.logTrace("Queued {} bytes to client {} (buffer was {s})\n", .{
                    ctx.data.len,
                    client_id,
                    if (was_empty) "empty" else "pending",
                });
            }
        }.relayCallback);

        // Record relay statistics
        self.performance_monitor.recordRelay(data.len, context.successful_relays);
        if (context.failed_relays > 0) {
            logging.logDebug("Relay complete: {} successful, {} failed\n", .{ context.successful_relays, context.failed_relays });
        } else {
            logging.logTrace("Relay complete: {} clients\n", .{context.successful_relays});
        }
    }

    pub fn isChatNicknameTaken(self: *BrokerServer, nickname: []const u8, exclude_client_id: u64) bool {
        if (self.mode != .chat) return false;

        if (self.chat_nicknames.get(nickname)) |existing_id| {
            return existing_id != exclude_client_id;
        }

        return false;
    }

    pub fn registerChatNickname(self: *BrokerServer, nickname: []const u8, client_id: u64) !void {
        if (self.mode != .chat) return;

        if (self.chat_nicknames.fetchRemove(nickname)) |kv| {
            self.allocator.free(@constCast(kv.key));
        }

        const nickname_copy = try self.allocator.dupe(u8, nickname);
        errdefer self.allocator.free(nickname_copy);

        try self.chat_nicknames.put(nickname_copy, client_id);
    }

    pub fn unregisterChatNickname(self: *BrokerServer, nickname: []const u8) void {
        if (self.chat_nicknames.fetchRemove(nickname)) |kv| {
            self.allocator.free(@constCast(kv.key));
        }
    }

    fn unregisterChatNicknameById(self: *BrokerServer, client_id: u64) void {
        var it = self.chat_nicknames.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == client_id) {
                const key = entry.key_ptr.*;
                if (self.chat_nicknames.fetchRemove(key)) |kv| {
                    self.allocator.free(@constCast(kv.key));
                }
                return;
            }
        }
    }

    fn clearChatNicknames(self: *BrokerServer) void {
        var it = self.chat_nicknames.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.chat_nicknames.clearRetainingCapacity();
    }

    /// Flush pending write data for a client
    ///
    /// Called when a client socket becomes writable (POLL.OUT event) or when new
    /// data has been queued. Attempts to drain the client's write buffer using
    /// non-blocking writes, leaving any unsent data queued for the next POLL.OUT.
    ///
    /// ## Parameters
    /// - `client_id`: Client ID to flush
    ///
    /// ## Returns
    /// Error if flush fails critically
    fn flushWriteBuffer(self: *BrokerServer, client_id: u64) !void {
        const client = self.clients.getClient(client_id) orelse return BrokerError.ClientNotFound;

        if (client.write_buffer.items.len == 0) {
            // Nothing to flush; ensure we are not polling for write events unnecessarily.
            self.poll_context.updateClientEvents(client.connection.getSocket(), false);
            return;
        }

        var total_bytes_written: usize = 0;

        flush_loop: while (client.write_buffer.items.len > 0) {
            const buffer_len = client.write_buffer.items.len;
            const bytes_written = client.connection.write(client.write_buffer.items) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        // Socket not ready for more writes; keep data queued.
                        logging.logTrace("Client {} write would block, {} bytes remain queued\n", .{
                            client_id,
                            client.write_buffer.items.len,
                        });
                        self.poll_context.updateClientEvents(client.connection.getSocket(), true);
                        break :flush_loop;
                    },
                    else => return err,
                }
            };

            if (bytes_written == 0) {
                // Treat zero-byte write as temporary backpressure to avoid busy loop.
                logging.logTrace("Client {} write returned 0 bytes, {} bytes remain queued\n", .{
                    client_id,
                    client.write_buffer.items.len,
                });
                self.poll_context.updateClientEvents(client.connection.getSocket(), true);
                break;
            }

            const remaining = buffer_len - bytes_written;
            if (remaining > 0) {
                std.mem.copyForwards(u8, client.write_buffer.items[0..remaining], client.write_buffer.items[bytes_written..buffer_len]);
            }
            client.write_buffer.shrinkRetainingCapacity(remaining);

            total_bytes_written += bytes_written;

            const written_u64: u64 = @intCast(bytes_written);
            client.bytes_sent += written_u64;
            client.updateActivity();
            self.flow_control.recordDataSent(client_id, written_u64);

            logging.logTrace("Flushed {} bytes to client {} ({} bytes remain)\n", .{
                bytes_written,
                client_id,
                client.write_buffer.items.len,
            });
        }

        if (client.write_buffer.items.len == 0) {
            self.poll_context.updateClientEvents(client.connection.getSocket(), false);
        } else {
            self.poll_context.updateClientEvents(client.connection.getSocket(), true);
        }

        if (total_bytes_written > 0) {
            logging.logTrace("Client {} total flushed bytes this cycle: {}\n", .{ client_id, total_bytes_written });
        }
    }

    /// Gracefully shutdown the broker server with enhanced logging
    pub fn shutdown(self: *BrokerServer) void {
        self.running = false;

        logging.log(1, "Broker server shutdown requested\n", .{});
        logging.logDebug("Shutting down with {} active clients\n", .{self.clients.getClientCount()});

        // Send shutdown notification to all clients in chat mode
        if (self.mode == .chat) {
            const shutdown_msg = "*** Server is shutting down\n";
            self.relayToClients(shutdown_msg, 0) catch |err| {
                logging.logError(err, "shutdown notification");
            };
            logging.logDebug("Sent shutdown notification to chat clients\n", .{});
        }

        // Log final statistics and performance summary
        if (logging.isVerbosityEnabled(self.config, .verbose)) {
            self.logClientStatistics();
        }

        // Log final performance summary
        const perf_summary = self.performance_monitor.getPerformanceSummary();
        logging.log(1, "Performance summary: {d:.1}% memory, {d:.1}% CPU, {d:.1} msg/s, {} errors\n", .{
            perf_summary.memory_usage_percent,
            perf_summary.cpu_usage_percent,
            perf_summary.messages_per_second,
            perf_summary.relay_errors,
        });
    }
};

// Tests
test "BrokerServer initialization" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create mock configuration
    var config = Config.init(allocator);
    defer config.deinit(allocator);

    // Create mock access list
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Create broker server (using invalid socket for testing)
    const mock_socket: std.posix.socket_t = 0;
    var server = try BrokerServer.init(allocator, mock_socket, .broker, &config, &access_list);
    defer server.deinit();

    try testing.expect(server.mode == .broker);
    try testing.expect(server.max_clients == 50); // Default value
    try testing.expect(!server.running);
}

test "PollContext operations" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const mock_listen_socket: std.posix.socket_t = 1;
    var poll_ctx = PollContext.init(allocator, mock_listen_socket);
    defer poll_ctx.deinit();

    // Test initial state
    try testing.expect(poll_ctx.listen_fd.fd == mock_listen_socket);
    try testing.expect(poll_ctx.client_fds.items.len == 0);

    // Test adding client
    const mock_client_socket: std.posix.socket_t = 2;
    try poll_ctx.addClient(mock_client_socket, 1);

    try testing.expect(poll_ctx.client_fds.items.len == 1);
    try testing.expect(poll_ctx.client_fds.items[0].fd == mock_client_socket);
    try testing.expect(poll_ctx.getClientId(mock_client_socket) == 1);

    // Test removing client
    poll_ctx.removeClient(mock_client_socket);
    try testing.expect(poll_ctx.client_fds.items.len == 0);
    try testing.expect(poll_ctx.getClientId(mock_client_socket) == null);
}

test "BrokerServer connection error detection" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create mock configuration
    var config = Config.init(allocator);
    defer config.deinit(allocator);

    // Create mock access list
    var access_list = allowlist.AccessList.init(allocator);
    defer access_list.deinit();

    // Create broker server
    const mock_socket: std.posix.socket_t = 0;
    var server = try BrokerServer.init(allocator, mock_socket, .broker, &config, &access_list);
    defer server.deinit();

    // Test connection error detection
    try testing.expect(server.isConnectionError(error.ConnectionResetByPeer));
    try testing.expect(server.isConnectionError(error.BrokenPipe));
    try testing.expect(server.isConnectionError(error.ConnectionAborted));
    try testing.expect(!server.isConnectionError(error.OutOfMemory));
    try testing.expect(!server.isConnectionError(error.InvalidArgument));
}
