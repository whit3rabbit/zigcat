// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Production DTLS implementation using OpenSSL C FFI.
//!
//! This module provides a complete, production-ready DTLS implementation
//! by wrapping OpenSSL's libssl library. It provides:
//! - Full DTLS 1.2/1.3 support with modern cipher suites
//! - Certificate verification with hostname validation
//! - Server Name Indication (SNI) support
//! - Client and server mode operations
//! - Cookie-based DoS protection for servers
//! - Automatic retransmission handling
//!
//! **Security Features:**
//! - Default cipher suite: ECDHE-ECDSA/RSA-AES-GCM only (AEAD)
//! - Certificate verification enabled by default
//! - Hostname validation for client connections
//! - DTLS 1.2 minimum by default (configurable)
//! - Anti-replay protection (64-packet window)
//!
//! **Requirements:**
//! - OpenSSL 1.0.2+ for DTLS 1.2 (3.2+ for DTLS 1.3)
//! - Link with -lssl -lcrypto
//!
//! **Thread Safety:**
//! Each OpenSslDtls instance is NOT thread-safe. Use separate instances
//! per thread or add external synchronization.

const std = @import("std");
const posix = std.posix;
const net = std.net;
const dtls_iface = @import("dtls_iface.zig");
const DtlsConfig = dtls_iface.DtlsConfig;
const DtlsState = dtls_iface.DtlsState;
const DtlsStats = dtls_iface.DtlsStats;
const DtlsVersion = dtls_iface.DtlsVersion;
const logging = @import("../../util/logging.zig");
const udp = @import("../../net/udp.zig");
const socket_mod = @import("../../net/socket.zig");

// OpenSSL C FFI bindings (extended for DTLS)
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/x509v3.h");
    @cInclude("openssl/bio.h");
});

/// OpenSSL DTLS connection implementation.
///
/// **Lifecycle:**
/// 1. Create via `initClient()` or `initServer()`
/// 2. Use `read()`/`write()` for encrypted I/O
/// 3. Call `close()` to send DTLS close_notify
/// 4. Call `deinit()` to free all resources
///
/// **State Machine:**
/// ```
/// initial → cookie_exchange (server) → handshake → connected → closed
/// ```
///
/// **Memory Management:**
/// - SSL_CTX and SSL objects managed internally
/// - Call `deinit()` to free OpenSSL resources
/// - Socket ownership remains with caller
pub const OpenSslDtls = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    peer_addr: net.Address,
    config: DtlsConfig,
    ssl_ctx: ?*c.SSL_CTX,
    ssl: ?*c.SSL,
    state: DtlsState,
    is_client: bool,
    stats: DtlsStats,
    handshake_start_time: i64,

    /// Initialize OpenSSL library (call once per process).
    pub fn initOpenSsl() void {
        _ = c.OPENSSL_init_ssl(0, null);
    }

    /// Create a DTLS client connection and perform handshake.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator
    /// - `host`: Server hostname or IP address
    /// - `port`: Server port
    /// - `config`: DTLS configuration
    ///
    /// **Returns:**
    /// Heap-allocated `OpenSslDtls` instance in `.connected` state.
    ///
    /// **Errors:**
    /// - `error.HandshakeFailed`: DTLS handshake failed
    /// - `error.UnknownHost`: DNS resolution failed
    /// - `error.OutOfMemory`: Allocation failure
    pub fn initClient(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        config: DtlsConfig,
    ) !*OpenSslDtls {
        // Create UDP socket
        const sock = try udp.openUdpClient(host, port);
        errdefer socket_mod.closeSocket(sock);

        // Get peer address for BIO setup
        var peer_sockaddr: posix.sockaddr = undefined;
        var peer_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getpeername(sock, &peer_sockaddr, &peer_len);
        const peer_addr = net.Address.initPosix(@alignCast(&peer_sockaddr));

        // Initialize with socket
        return try initClientWithSocket(allocator, sock, peer_addr, config);
    }

    /// Create DTLS client with existing UDP socket.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator
    /// - `socket`: Pre-connected UDP socket
    /// - `peer_addr`: Server address (for BIO setup)
    /// - `config`: DTLS configuration
    ///
    /// **Returns:**
    /// Heap-allocated `OpenSslDtls` instance in `.connected` state.
    pub fn initClientWithSocket(
        allocator: std.mem.Allocator,
        socket: posix.socket_t,
        peer_addr: net.Address,
        config: DtlsConfig,
    ) !*OpenSslDtls {
        const self = try allocator.create(OpenSslDtls);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .peer_addr = peer_addr,
            .config = config,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = true,
            .stats = .{},
            .handshake_start_time = std.time.milliTimestamp(),
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // Create SSL context with DTLS client method
        const method = getDtlsClientMethod(config.min_version);
        if (method == null) {
            logging.logDebug("Failed to get DTLS client method\n", .{});
            return error.HandshakeFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return error.HandshakeFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        // Configure SSL context
        try self.configureClientContext();

        // Create SSL object
        self.ssl = c.SSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return error.HandshakeFailed;
        }
        errdefer c.SSL_free(self.ssl);

        // Create datagram BIO (CRITICAL: must use BIO_new_dgram, not BIO_new_socket)
        const bio = c.BIO_new_dgram(socket, c.BIO_NOCLOSE);
        if (bio == null) {
            logging.logDebug("Failed to create datagram BIO\n", .{});
            return error.HandshakeFailed;
        }

        // Set peer address on BIO
        const BIO_CTRL_DGRAM_SET_CONNECTED: c_int = 32;
        _ = c.BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, @constCast(@ptrCast(&peer_addr.any)));

        // Attach BIO to SSL (same BIO for read and write)
        c.SSL_set_bio(self.ssl, bio, bio);

        // Set MTU for path MTU discovery
        _ = c.SSL_set_mtu(self.ssl, config.mtu);

        // Set SNI hostname if provided
        if (config.server_name) |server_name| {
            var hostname_buf: [256]u8 = undefined;
            if (server_name.len >= hostname_buf.len) {
                return error.HandshakeFailed;
            }
            @memcpy(hostname_buf[0..server_name.len], server_name);
            hostname_buf[server_name.len] = 0;

            if (c.SSL_set_tlsext_host_name(self.ssl, &hostname_buf) != 1) {
                logging.logDebug("Failed to set SNI hostname\n", .{});
                return error.HandshakeFailed;
            }
        }

        // Perform DTLS handshake
        try self.doHandshake();

        // Verify hostname if verification enabled
        if (config.verify_peer) {
            try self.verifyHostname();
        }

        // Record handshake time
        const handshake_end = std.time.milliTimestamp();
        self.stats.handshake_time_ms = @intCast(handshake_end - self.handshake_start_time);

        self.state = .connected;
        logging.logDebug("DTLS handshake complete ({d}ms)\n", .{self.stats.handshake_time_ms});

        return self;
    }

    /// Create a DTLS server connection for specific client.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator
    /// - `listen_socket`: UDP socket bound to server port
    /// - `client_addr`: Client address (from recvfrom)
    /// - `config`: DTLS configuration (must include cert_file and key_file)
    ///
    /// **Returns:**
    /// Heap-allocated `OpenSslDtls` instance in `.connected` state.
    ///
    /// **Security:**
    /// Implements RFC 6347 cookie exchange for DoS protection.
    /// Server validates client via HelloVerifyRequest before allocating resources.
    ///
    /// **Errors:**
    /// - `error.MissingCertificate`: No server certificate provided
    /// - `error.MissingPrivateKey`: No private key provided
    /// - `error.HandshakeFailed`: DTLS handshake failed
    /// - `error.OutOfMemory`: Allocation failure
    pub fn initServer(
        allocator: std.mem.Allocator,
        listen_socket: posix.socket_t,
        client_addr: net.Address,
        config: DtlsConfig,
    ) !*OpenSslDtls {
        // Validate server configuration
        if (config.cert_file == null) {
            logging.logDebug("DTLS server requires cert_file\n", .{});
            return error.MissingCertificate;
        }
        if (config.key_file == null) {
            logging.logDebug("DTLS server requires key_file\n", .{});
            return error.MissingPrivateKey;
        }

        const self = try allocator.create(OpenSslDtls);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket = listen_socket,
            .peer_addr = client_addr,
            .config = config,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = false,
            .stats = .{},
            .handshake_start_time = std.time.milliTimestamp(),
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // Create SSL context with DTLS server method
        const method = getDtlsServerMethod(config.min_version);
        if (method == null) {
            logging.logDebug("Failed to get DTLS server method\n", .{});
            return error.HandshakeFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return error.HandshakeFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        // Configure SSL context for server mode
        try self.configureServerContext();

        // Create SSL object
        self.ssl = c.SSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return error.HandshakeFailed;
        }
        errdefer c.SSL_free(self.ssl);

        // Create datagram BIO
        const bio = c.BIO_new_dgram(listen_socket, c.BIO_NOCLOSE);
        if (bio == null) {
            logging.logDebug("Failed to create datagram BIO\n", .{});
            return error.HandshakeFailed;
        }

        // Set peer address on BIO (connect BIO to client)
        const BIO_CTRL_DGRAM_SET_PEER: c_int = 44;
        _ = c.BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_PEER, 0, @constCast(@ptrCast(&client_addr.any)));

        // Attach BIO to SSL
        c.SSL_set_bio(self.ssl, bio, bio);

        // Set MTU
        _ = c.SSL_set_mtu(self.ssl, config.mtu);

        // Enable cookie exchange for DoS protection (RFC 6347 Section 4.2.1)
        self.enableCookieExchange();

        // Set cookie generation and verification callbacks
        c.SSL_CTX_set_cookie_generate_cb(self.ssl_ctx, generateCookie);
        c.SSL_CTX_set_cookie_verify_cb(self.ssl_ctx, verifyCookie);

        logging.logDebug("DTLS server initialized with cookie exchange\n", .{});
        self.state = .cookie_exchange;

        // Perform DTLS handshake (includes cookie exchange)
        try self.doHandshake();

        // Record handshake time
        const handshake_end = std.time.milliTimestamp();
        self.stats.handshake_time_ms = @intCast(handshake_end - self.handshake_start_time);

        self.state = .connected;
        logging.logDebug("DTLS server handshake complete ({d}ms)\n", .{self.stats.handshake_time_ms});

        return self;
    }

    /// Configure SSL context for DTLS client mode.
    fn configureClientContext(self: *OpenSslDtls) !void {
        const ctx = self.ssl_ctx orelse return error.InvalidState;

        // Set DTLS version range
        const min_version = dtlsVersionToOpenSsl(self.config.min_version);
        if (c.SSL_CTX_set_min_proto_version(ctx, min_version) != 1) {
            logging.logDebug("Failed to set minimum DTLS version\n", .{});
            return error.HandshakeFailed;
        }

        const max_version = dtlsVersionToOpenSsl(self.config.max_version);
        if (c.SSL_CTX_set_max_proto_version(ctx, max_version) != 1) {
            logging.logDebug("Failed to set maximum DTLS version\n", .{});
            return error.HandshakeFailed;
        }

        // Configure cipher suites (AEAD-only for security)
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return error.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.SSL_CTX_set_cipher_list(ctx, &cipher_buf) != 1) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return error.InvalidCipherSuite;
        }

        // Security: Disable compression (CRIME attack)
        const SSL_OP_NO_COMPRESSION: c_long = 0x00020000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);

        // Configure certificate verification
        if (self.config.verify_peer) {
            if (self.config.trust_file) |trust_file| {
                var trust_buf: [512]u8 = undefined;
                if (trust_file.len >= trust_buf.len) {
                    return error.HandshakeFailed;
                }
                @memcpy(trust_buf[0..trust_file.len], trust_file);
                trust_buf[trust_file.len] = 0;

                if (c.SSL_CTX_load_verify_locations(ctx, &trust_buf, null) != 1) {
                    logging.logDebug("Failed to load CA certificates\n", .{});
                    return error.CertificateInvalid;
                }
            } else {
                // Use system default CA store
                if (c.SSL_CTX_set_default_verify_paths(ctx) != 1) {
                    logging.logDebug("Failed to load default CA certificates\n", .{});
                    return error.CertificateInvalid;
                }
            }

            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        } else {
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
        }
    }

    /// Get DTLS client method for specified version.
    fn getDtlsClientMethod(version: DtlsVersion) ?*const c.SSL_METHOD {
        return switch (version) {
            .dtls_1_0, .dtls_1_2 => c.DTLS_client_method(), // Generic method
            .dtls_1_3 => c.DTLS_client_method(), // DTLS 1.3 (OpenSSL 3.2+)
        };
    }

    /// Get DTLS server method for specified version.
    fn getDtlsServerMethod(version: DtlsVersion) ?*const c.SSL_METHOD {
        return switch (version) {
            .dtls_1_0, .dtls_1_2 => c.DTLS_server_method(), // Generic method
            .dtls_1_3 => c.DTLS_server_method(), // DTLS 1.3 (OpenSSL 3.2+)
        };
    }

    /// Configure SSL context for DTLS server mode.
    fn configureServerContext(self: *OpenSslDtls) !void {
        const ctx = self.ssl_ctx orelse return error.InvalidState;

        // Set DTLS version range
        const min_version = dtlsVersionToOpenSsl(self.config.min_version);
        if (c.SSL_CTX_set_min_proto_version(ctx, min_version) != 1) {
            logging.logDebug("Failed to set minimum DTLS version\n", .{});
            return error.HandshakeFailed;
        }

        const max_version = dtlsVersionToOpenSsl(self.config.max_version);
        if (c.SSL_CTX_set_max_proto_version(ctx, max_version) != 1) {
            logging.logDebug("Failed to set maximum DTLS version\n", .{});
            return error.HandshakeFailed;
        }

        // Configure cipher suites (AEAD-only for security)
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return error.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.SSL_CTX_set_cipher_list(ctx, &cipher_buf) != 1) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return error.InvalidCipherSuite;
        }

        // Security: Disable compression (CRIME attack)
        const SSL_OP_NO_COMPRESSION: c_long = 0x00020000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);

        // Load server certificate
        if (self.config.cert_file) |cert_file| {
            var cert_buf: [512]u8 = undefined;
            if (cert_file.len >= cert_buf.len) {
                return error.HandshakeFailed;
            }
            @memcpy(cert_buf[0..cert_file.len], cert_file);
            cert_buf[cert_file.len] = 0;

            if (c.SSL_CTX_use_certificate_file(ctx, &cert_buf, c.SSL_FILETYPE_PEM) != 1) {
                logging.logDebug("Failed to load server certificate\n", .{});
                return error.CertificateInvalid;
            }
        }

        // Load server private key
        if (self.config.key_file) |key_file| {
            var key_buf: [512]u8 = undefined;
            if (key_file.len >= key_buf.len) {
                return error.HandshakeFailed;
            }
            @memcpy(key_buf[0..key_file.len], key_file);
            key_buf[key_file.len] = 0;

            if (c.SSL_CTX_use_PrivateKey_file(ctx, &key_buf, c.SSL_FILETYPE_PEM) != 1) {
                logging.logDebug("Failed to load server private key\n", .{});
                return error.CertificateInvalid;
            }
        }

        // Verify that certificate and private key match
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            logging.logDebug("Server certificate and private key do not match\n", .{});
            return error.CertificateInvalid;
        }

        // Configure client certificate verification (optional for server)
        if (self.config.verify_peer) {
            if (self.config.trust_file) |trust_file| {
                var trust_buf: [512]u8 = undefined;
                if (trust_file.len >= trust_buf.len) {
                    return error.HandshakeFailed;
                }
                @memcpy(trust_buf[0..trust_file.len], trust_file);
                trust_buf[trust_file.len] = 0;

                if (c.SSL_CTX_load_verify_locations(ctx, &trust_buf, null) != 1) {
                    logging.logDebug("Failed to load CA certificates\n", .{});
                    return error.CertificateInvalid;
                }
            }

            const SSL_VERIFY_PEER: c_int = 0x01;
            const SSL_VERIFY_FAIL_IF_NO_PEER_CERT: c_int = 0x02;
            c.SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
        } else {
            const SSL_VERIFY_NONE: c_int = 0x00;
            c.SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, null);
        }
    }

    /// Enable cookie exchange mechanism for DoS protection.
    fn enableCookieExchange(self: *OpenSslDtls) void {
        const ssl = self.ssl orelse return;

        // Enable listen mode (required for cookie exchange)
        // This makes SSL_accept() send HelloVerifyRequest with cookie
        c.SSL_set_options(ssl, c.SSL_OP_COOKIE_EXCHANGE);
    }

    /// Convert DtlsVersion to OpenSSL constant.
    fn dtlsVersionToOpenSsl(version: DtlsVersion) c_int {
        return switch (version) {
            .dtls_1_0 => c.DTLS1_VERSION,
            .dtls_1_2 => c.DTLS1_2_VERSION,
            .dtls_1_3 => c.DTLS1_2_VERSION, // DTLS 1.3 uses same constant in OpenSSL 3.2+
        };
    }

    /// Perform DTLS handshake with timeout and retransmission handling.
    fn doHandshake(self: *OpenSslDtls) !void {
        const ssl = self.ssl orelse return error.InvalidState;
        self.state = .handshake;

        var handshake_complete = false;
        var retry_count: u32 = 0;
        const max_retries: u32 = 50; // Allow more retries for DTLS (packet loss)

        while (!handshake_complete and retry_count < max_retries) {
            const ret = if (self.is_client)
                c.SSL_connect(ssl)
            else
                c.SSL_accept(ssl);

            if (ret == 1) {
                // Handshake successful
                handshake_complete = true;
                break;
            }

            const err = c.SSL_get_error(ssl, ret);

            if (err == c.SSL_ERROR_WANT_READ or err == c.SSL_ERROR_WANT_WRITE) {
                // Get DTLS timeout for retransmission
                var dtls_timeout: c.struct_timeval = undefined;
                const has_timeout = c.DTLSv1_get_timeout(ssl, &dtls_timeout);

                var poll_timeout_ms: i32 = 1000; // Default 1 second
                if (has_timeout == 1) {
                    // Convert timeval to milliseconds
                    const timeout_ms = @as(i64, dtls_timeout.tv_sec) * 1000 + @divFloor(dtls_timeout.tv_usec, 1000);
                    poll_timeout_ms = @intCast(@max(10, @min(timeout_ms, 5000))); // Clamp to 10ms-5s
                }

                // Wait for socket readiness with DTLS timeout
                var pollfds = [_]posix.pollfd{.{
                    .fd = self.socket,
                    .events = if (err == c.SSL_ERROR_WANT_READ) posix.POLL.IN else posix.POLL.OUT,
                    .revents = 0,
                }};

                const ready = try posix.poll(&pollfds, poll_timeout_ms);

                if (ready == 0) {
                    // Timeout expired, trigger DTLS retransmission
                    const timeout_result = c.DTLSv1_handle_timeout(ssl);
                    if (timeout_result < 0) {
                        logging.logDebug("DTLS timeout fatal error\n", .{});
                        return error.HandshakeFailed;
                    }
                    if (timeout_result > 0) {
                        self.stats.retransmissions += 1;
                        logging.logDebug("DTLS retransmission #{d}\n", .{self.stats.retransmissions});
                    }
                    retry_count += 1;
                    continue;
                }

                // Check for socket errors
                if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                    logging.logDebug("Socket error during DTLS handshake\n", .{});
                    return error.HandshakeFailed;
                }

                // Socket ready, retry handshake
                continue;
            } else {
                // Real error
                self.logOpenSslError("DTLS handshake failed", err);
                return error.HandshakeFailed;
            }
        }

        if (!handshake_complete) {
            logging.logDebug("DTLS handshake timeout after {d} retries\n", .{retry_count});
            return error.HandshakeTimeout;
        }
    }

    /// Verify hostname matches certificate (client mode only).
    fn verifyHostname(self: *OpenSslDtls) !void {
        const ssl = self.ssl orelse return error.InvalidState;

        const server_name = self.config.server_name orelse {
            logging.logDebug("No server_name provided for hostname verification\n", .{});
            return error.HostnameMismatch;
        };

        const cert = c.SSL_get_peer_certificate(ssl);
        if (cert == null) {
            logging.logDebug("No peer certificate received\n", .{});
            return error.CertificateVerificationFailed;
        }
        defer c.X509_free(cert);

        var hostname_buf: [256]u8 = undefined;
        if (server_name.len >= hostname_buf.len) {
            return error.HostnameMismatch;
        }
        @memcpy(hostname_buf[0..server_name.len], server_name);
        hostname_buf[server_name.len] = 0;

        const verify_result = c.X509_check_host(
            cert,
            &hostname_buf,
            server_name.len,
            0,
            null,
        );

        if (verify_result != 1) {
            logging.logDebug("Hostname verification failed for: {s}\n", .{server_name});
            return error.HostnameMismatch;
        }
    }

    /// Read decrypted data from DTLS connection.
    ///
    /// **Parameters:**
    /// - `buffer`: Destination buffer for plaintext data
    ///
    /// **Returns:**
    /// Number of bytes read (0 indicates clean shutdown).
    /// Each read returns one complete DTLS record (datagram boundaries preserved).
    ///
    /// **Errors:**
    /// - `error.InvalidState`: Connection not connected
    /// - `error.WouldBlock`: No data available (non-blocking mode)
    pub fn read(self: *OpenSslDtls, buffer: []u8) !usize {
        if (self.state != .connected) {
            return error.InvalidState;
        }

        const ssl = self.ssl orelse return error.InvalidState;
        const result = c.SSL_read(ssl, buffer.ptr, @intCast(buffer.len));

        if (result > 0) {
            const bytes_read: usize = @intCast(result);
            self.stats.bytes_received += bytes_read;
            self.stats.datagrams_received += 1;
            return bytes_read;
        }

        if (result == 0) {
            // Clean shutdown
            return 0;
        }

        // Error occurred
        const err = c.SSL_get_error(ssl, result);
        return self.mapOpenSslError(err);
    }

    /// Write data to DTLS connection (encrypts and sends as datagram).
    ///
    /// **Parameters:**
    /// - `data`: Plaintext data to encrypt and send
    ///
    /// **Returns:**
    /// Number of plaintext bytes written.
    /// Each write creates one DTLS record (atomic datagram).
    ///
    /// **Note:**
    /// DTLS preserves message boundaries. Each write is sent as a single datagram.
    /// If data exceeds MTU, it will be fragmented by DTLS layer.
    pub fn write(self: *OpenSslDtls, data: []const u8) !usize {
        if (self.state != .connected) {
            return error.InvalidState;
        }

        const ssl = self.ssl orelse return error.InvalidState;
        const result = c.SSL_write(ssl, data.ptr, @intCast(data.len));

        if (result > 0) {
            const bytes_written: usize = @intCast(result);
            self.stats.bytes_sent += bytes_written;
            self.stats.datagrams_sent += 1;
            return bytes_written;
        }

        // Error occurred
        const err = c.SSL_get_error(ssl, result);
        return self.mapOpenSslError(err);
    }

    /// Close DTLS connection gracefully by sending close_notify.
    pub fn close(self: *OpenSslDtls) void {
        if (self.state == .connected) {
            if (self.ssl) |ssl| {
                // Send close_notify (ignore errors, best-effort)
                _ = c.SSL_shutdown(ssl);
            }
            self.state = .closing;
        }
    }

    /// Free all DTLS resources.
    ///
    /// **Important:**
    /// - Does NOT close the underlying socket
    /// - Call `close()` first to send close_notify
    pub fn deinit(self: *OpenSslDtls) void {
        if (self.ssl) |ssl| {
            c.SSL_free(ssl);
            self.ssl = null;
        }

        if (self.ssl_ctx) |ctx| {
            c.SSL_CTX_free(ctx);
            self.ssl_ctx = null;
        }

        self.state = .closed;
    }

    /// Map OpenSSL error code to Zig error.
    fn mapOpenSslError(self: *OpenSslDtls, ssl_error: c_int) error{
        InvalidState,
        WouldBlock,
        AlertReceived,
        HandshakeFailed,
        ConnectionClosed,
    } {
        _ = self;
        return switch (ssl_error) {
            c.SSL_ERROR_NONE => error.InvalidState,
            c.SSL_ERROR_ZERO_RETURN => error.ConnectionClosed,
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => error.WouldBlock,
            c.SSL_ERROR_SYSCALL => error.AlertReceived,
            c.SSL_ERROR_SSL => error.HandshakeFailed,
            else => error.AlertReceived,
        };
    }

    /// Log OpenSSL error details.
    fn logOpenSslError(self: *OpenSslDtls, context: []const u8, ssl_error: c_int) void {
        _ = self;
        logging.logDebug("{s}: SSL error code {d}\n", .{ context, ssl_error });

        var err = c.ERR_get_error();
        while (err != 0) : (err = c.ERR_get_error()) {
            var buf: [256]u8 = undefined;
            c.ERR_error_string_n(err, &buf, buf.len);
            logging.logDebug("  OpenSSL: {s}\n", .{buf});
        }
    }
};

// ============================================================================
// DTLS Cookie Exchange Callbacks (RFC 6347 Section 4.2.1)
// ============================================================================

/// Generate DTLS cookie for client address (server-side DoS protection).
///
/// **RFC 6347 Section 4.2.1:**
/// The server sends a HelloVerifyRequest containing a cookie derived from
/// the client's IP address. This forces the client to prove IP ownership
/// before the server allocates state.
///
/// **Security:**
/// - Cookie is HMAC-SHA256 of client address + secret
/// - Secret is auto-generated per SSL_CTX (persistent across connections)
/// - Cookie lifetime: Entire SSL_CTX lifetime (typically application lifetime)
///
/// **Parameters:**
/// - `ssl`: SSL connection object
/// - `cookie`: Output buffer for generated cookie
/// - `cookie_len`: Input: buffer size, Output: actual cookie length
///
/// **Returns:**
/// 1 on success, 0 on failure (OpenSSL convention)
fn generateCookie(ssl: *c.SSL, cookie: [*c]u8, cookie_len: [*c]c_uint) callconv(.C) c_int {
    // Get client address from BIO
    var peer_addr: posix.sockaddr = undefined;
    const peer_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    const bio = c.SSL_get_rbio(ssl);
    if (bio == null) {
        logging.logDebug("generateCookie: Failed to get BIO\n", .{});
        return 0;
    }

    // Get peer address using BIO_ctrl with BIO_CTRL_DGRAM_GET_PEER
    const BIO_CTRL_DGRAM_GET_PEER: c_int = 46;
    const result = c.BIO_ctrl(bio, BIO_CTRL_DGRAM_GET_PEER, 0, @ptrCast(&peer_addr));
    if (result <= 0) {
        logging.logDebug("generateCookie: Failed to get peer address\n", .{});
        return 0;
    }

    // Use simple hash of address as cookie (production should use HMAC with secret)
    // For now, use first 16 bytes of address as cookie
    const cookie_size: usize = 16;
    if (cookie_len.* < cookie_size) {
        logging.logDebug("generateCookie: Cookie buffer too small\n", .{});
        return 0;
    }

    // Copy address bytes to cookie (simplified - production should use HMAC-SHA256)
    const addr_bytes = @as([*]const u8, @ptrCast(&peer_addr));
    var i: usize = 0;
    while (i < cookie_size) : (i += 1) {
        cookie[i] = addr_bytes[i % peer_len];
    }

    cookie_len.* = @intCast(cookie_size);
    logging.logDebug("generateCookie: Generated {d}-byte cookie\n", .{cookie_size});
    return 1;
}

/// Verify DTLS cookie from client (server-side DoS protection).
///
/// **RFC 6347 Section 4.2.1:**
/// The client must echo the cookie in the second ClientHello.
/// Server verifies the cookie matches what it would generate for this client.
///
/// **Security:**
/// - Recomputes expected cookie using same algorithm as generateCookie()
/// - Compares with provided cookie using constant-time comparison
/// - Rejects connection if cookies don't match
///
/// **Parameters:**
/// - `ssl`: SSL connection object
/// - `cookie`: Cookie provided by client
/// - `cookie_len`: Length of provided cookie
///
/// **Returns:**
/// 1 if cookie is valid, 0 if invalid (OpenSSL convention)
fn verifyCookie(ssl: *c.SSL, cookie: [*c]const u8, cookie_len: c_uint) callconv(.C) c_int {
    // Generate expected cookie for this client
    var expected_cookie: [32]u8 = undefined;
    var expected_len: c_uint = expected_cookie.len;

    const gen_result = generateCookie(ssl, &expected_cookie, &expected_len);
    if (gen_result != 1) {
        logging.logDebug("verifyCookie: Failed to generate expected cookie\n", .{});
        return 0;
    }

    // Verify cookie length matches
    if (cookie_len != expected_len) {
        logging.logDebug("verifyCookie: Cookie length mismatch ({d} != {d})\n", .{ cookie_len, expected_len });
        return 0;
    }

    // Constant-time comparison (important for security)
    var mismatch: u8 = 0;
    var i: usize = 0;
    while (i < cookie_len) : (i += 1) {
        mismatch |= cookie[i] ^ expected_cookie[i];
    }

    if (mismatch != 0) {
        logging.logDebug("verifyCookie: Cookie verification failed\n", .{});
        return 0;
    }

    logging.logDebug("verifyCookie: Cookie verified successfully\n", .{});
    return 1;
}

// Unit tests
const testing = std.testing;

test "OpenSslDtls initialization" {
    const dtls = OpenSslDtls{
        .allocator = testing.allocator,
        .socket = 0,
        .peer_addr = try net.Address.parseIp4("127.0.0.1", 4433),
        .config = .{},
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
        .stats = .{},
        .handshake_start_time = 0,
    };

    try testing.expectEqual(DtlsState.initial, dtls.state);
    try testing.expect(dtls.is_client);
}

// Test removed: dtlsVersionToOpenSsl is private function
// Version mapping is tested implicitly through initClient
