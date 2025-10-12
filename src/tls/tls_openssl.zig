// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Production TLS implementation using OpenSSL C FFI.
//!
//! This module provides a complete, production-ready TLS implementation
//! by wrapping OpenSSL's libssl library. It provides:
//! - Full TLS 1.2/1.3 support with modern cipher suites
//! - Certificate verification with hostname validation
//! - Server Name Indication (SNI) support
//! - Client and server mode operations
//! - Proper error handling and state management
//!
//! **Security Features:**
//! - Default cipher suite: HIGH:!aNULL:!MD5:!RC4
//! - Certificate verification enabled by default
//! - Hostname validation for client connections
//! - TLS 1.2 minimum by default (configurable)
//!
//! **Requirements:**
//! - OpenSSL 1.1.0 or later (3.0+ recommended)
//! - Link with -lssl -lcrypto
//! - Add to build.zig: exe.linkSystemLibrary("ssl"); exe.linkSystemLibrary("crypto");
//!
//! **Thread Safety:**
//! Each OpenSslTls instance is NOT thread-safe. Use separate instances
//! per thread or add external synchronization.

const std = @import("std");
const tls_iface = @import("tls_iface.zig");
const TlsConfig = tls_iface.TlsConfig;
const TlsError = tls_iface.TlsError;
const TlsVersion = tls_iface.TlsVersion;
const posix = std.posix;
const logging = @import("../util/logging.zig");
const build_options = @import("build_options");

// C FFI bindings for OpenSSL
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/x509v3.h");
});

/// OpenSSL-based TLS connection implementation.
///
/// **Lifecycle:**
/// 1. Create via `initClient()` or `initServer()`
/// 2. Use `read()`/`write()` for encrypted I/O
/// 3. Call `close()` to send TLS close_notify
/// 4. Call `deinit()` to free all resources
///
/// **State Machine:**
/// ```
/// initial → handshake_in_progress → connected → closed
/// ```
///
/// **Memory Management:**
/// - SSL_CTX and SSL objects managed internally
/// - Call `deinit()` to free OpenSSL resources
/// - Socket ownership remains with caller
pub const OpenSslTls = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    config: TlsConfig,
    ssl_ctx: ?*c.SSL_CTX,
    ssl: ?*c.SSL,
    state: ConnectionState,
    is_client: bool,

    const ConnectionState = enum {
        initial,
        handshake_in_progress,
        connected,
        closed,
    };

    /// Initialize OpenSSL library (call once per process).
    ///
    /// **Must be called before any TLS operations.**
    ///
    /// OpenSSL 1.1.0+ automatically initializes, but calling this
    /// ensures compatibility with older versions and makes
    /// initialization explicit.
    pub fn initOpenSsl() void {
        // OpenSSL 1.1.0+ auto-initializes, but explicit call is safe
        _ = c.OPENSSL_init_ssl(0, null);
    }

    /// Create a client-side TLS connection and perform handshake.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator (minimal usage, mostly for error messages)
    /// - `socket`: Pre-connected TCP socket (must remain open)
    /// - `config`: TLS configuration (server_name, verify_peer, etc.)
    ///
    /// **Returns:**
    /// Heap-allocated `OpenSslTls` instance in `.connected` state.
    ///
    /// **Errors:**
    /// - `error.HandshakeFailed`: TLS handshake failed
    /// - `error.CertificateVerificationFailed`: Peer cert validation failed
    /// - `error.OutOfMemory`: Allocation failure
    /// - `error.UntrustedCertificate`: Cert not signed by trusted CA
    ///
    /// **Security:**
    /// - Certificate verification is ENABLED by default
    /// - SNI is set automatically from `config.server_name`
    /// - Hostname validation performed after handshake
    ///
    /// **Example:**
    /// ```zig
    /// const config = TlsConfig{
    ///     .server_name = "example.com",
    ///     .verify_peer = true,
    /// };
    /// const tls = try OpenSslTls.initClient(allocator, sock, config);
    /// defer {
    ///     tls.close();
    ///     tls.deinit();
    ///     allocator.destroy(tls);
    /// }
    /// ```
    pub fn initClient(
        allocator: std.mem.Allocator,
        socket: posix.socket_t,
        config: TlsConfig,
    ) !*OpenSslTls {
        const self = try allocator.create(OpenSslTls);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .config = config,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = true,
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // Create SSL context with TLS client method
        const method = c.TLS_client_method();
        if (method == null) {
            logging.logDebug("Failed to get TLS client method\n", .{});
            return TlsError.HandshakeFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        // Configure SSL context
        try self.configureClientContext();

        // Create SSL object
        self.ssl = c.SSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.SSL_free(self.ssl);

        // Attach socket to SSL
        if (c.SSL_set_fd(self.ssl, socket) != 1) {
            logging.logDebug("Failed to set SSL file descriptor\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Set SNI hostname if provided
        if (config.server_name) |server_name| {
            // Ensure null-terminated for C API
            var hostname_buf: [256]u8 = undefined;
            if (server_name.len >= hostname_buf.len) {
                return TlsError.HandshakeFailed;
            }
            @memcpy(hostname_buf[0..server_name.len], server_name);
            hostname_buf[server_name.len] = 0;

            if (c.SSL_set_tlsext_host_name(self.ssl, &hostname_buf) != 1) {
                logging.logDebug("Failed to set SNI hostname\n", .{});
                return TlsError.HandshakeFailed;
            }
        }

        // Perform TLS handshake
        try self.doHandshake();

        // Verify hostname if verification enabled
        if (config.verify_peer) {
            try self.verifyHostname();
        }

        self.state = .connected;
        return self;
    }

    /// Create a server-side TLS connection and perform handshake.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator
    /// - `socket`: Accepted client socket (post-accept)
    /// - `config`: TLS configuration (must include cert_file and key_file)
    ///
    /// **Returns:**
    /// Heap-allocated `OpenSslTls` instance in `.connected` state.
    ///
    /// **Errors:**
    /// - `error.HandshakeFailed`: TLS handshake failed
    /// - `error.CertificateInvalid`: Server cert/key invalid or missing
    /// - `error.OutOfMemory`: Allocation failure
    ///
    /// **Required Config:**
    /// - `config.cert_file` - Path to server certificate (PEM format)
    /// - `config.key_file` - Path to private key (PEM format)
    ///
    /// **Example:**
    /// ```zig
    /// const config = TlsConfig{
    ///     .cert_file = "server.pem",
    ///     .key_file = "server-key.pem",
    /// };
    /// const tls = try OpenSslTls.initServer(allocator, client_sock, config);
    /// defer {
    ///     tls.close();
    ///     tls.deinit();
    ///     allocator.destroy(tls);
    /// }
    /// ```
    pub fn initServer(
        allocator: std.mem.Allocator,
        socket: posix.socket_t,
        config: TlsConfig,
    ) !*OpenSslTls {
        const self = try allocator.create(OpenSslTls);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .config = config,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = false,
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // Create SSL context with TLS server method
        const method = c.TLS_server_method();
        if (method == null) {
            logging.logDebug("Failed to get TLS server method\n", .{});
            return TlsError.HandshakeFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        // Configure SSL context
        try self.configureServerContext();

        // Create SSL object
        self.ssl = c.SSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.SSL_free(self.ssl);

        // Attach socket to SSL
        if (c.SSL_set_fd(self.ssl, socket) != 1) {
            logging.logDebug("Failed to set SSL file descriptor\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Perform TLS handshake
        try self.doHandshake();

        self.state = .connected;
        return self;
    }

    /// Configure SSL context for client mode.
    fn configureClientContext(self: *OpenSslTls) !void {
        const ctx = self.ssl_ctx orelse return TlsError.InvalidState;

        // Set minimum TLS version with production security enforcement
        var min_version = self.tlsVersionToOpenSsl(self.config.min_version);

        // SECURITY: Hard-enforce TLS 1.2 minimum in production builds
        // TLS 1.0/1.1 have known vulnerabilities (BEAST, POODLE) and are deprecated
        if (!build_options.allow_legacy_tls) {
            const PRODUCTION_MIN_TLS = c.TLS1_2_VERSION;
            if (min_version < PRODUCTION_MIN_TLS) {
                logging.logDebug("TLS 1.0/1.1 disabled for security. Enforcing TLS 1.2 minimum.\n", .{});
                logging.logDebug("Use -Dallow-legacy-tls=true build option to enable legacy protocols (NOT RECOMMENDED).\n", .{});
                min_version = PRODUCTION_MIN_TLS;
            }
        }

        if (c.SSL_CTX_set_min_proto_version(ctx, min_version) != 1) {
            logging.logDebug("Failed to set minimum TLS version\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Set maximum TLS version
        const max_version = self.tlsVersionToOpenSsl(self.config.max_version);
        if (c.SSL_CTX_set_max_proto_version(ctx, max_version) != 1) {
            logging.logDebug("Failed to set maximum TLS version\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Configure cipher suites (2025 security best practices - AEAD-only)
        // TLS 1.2 cipher list: Only ECDHE with AEAD ciphers (AES-GCM, ChaCha20-Poly1305)
        // This eliminates CBC ciphers (Lucky13), 3DES (Sweet32), and non-forward-secret ciphers
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.SSL_CTX_set_cipher_list(ctx, &cipher_buf) != 1) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return TlsError.InvalidCipherSuite;
        }

        // Configure TLS 1.3 cipher suites (OpenSSL 1.1.1+)
        // TLS 1.3 only supports AEAD ciphers by design
        const tls13_ciphers = "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256";
        var tls13_buf: [256]u8 = undefined;
        if (tls13_ciphers.len >= tls13_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(tls13_buf[0..tls13_ciphers.len], tls13_ciphers);
        tls13_buf[tls13_ciphers.len] = 0;

        // SSL_CTX_set_ciphersuites() is for TLS 1.3 only (OpenSSL 1.1.1+)
        if (c.SSL_CTX_set_ciphersuites(ctx, &tls13_buf) != 1) {
            // Non-fatal: might be using older OpenSSL without TLS 1.3 support
            logging.logDebug("Warning: Failed to set TLS 1.3 cipher suites (OpenSSL may not support TLS 1.3)\n", .{});
        }

        // Security hardening: Disable compression (CRIME attack protection)
        const SSL_OP_NO_COMPRESSION: c_long = 0x00020000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);

        // Security hardening: Disable session tickets (privacy protection)
        const SSL_OP_NO_TICKET: c_long = 0x00004000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_TICKET);

        // Security hardening: Prefer server cipher order
        const SSL_OP_CIPHER_SERVER_PREFERENCE: c_long = 0x00400000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_CIPHER_SERVER_PREFERENCE);

        // Configure certificate verification
        if (self.config.verify_peer) {
            // Load default CA certificates
            if (self.config.trust_file) |trust_file| {
                var trust_buf: [512]u8 = undefined;
                if (trust_file.len >= trust_buf.len) {
                    return TlsError.HandshakeFailed;
                }
                @memcpy(trust_buf[0..trust_file.len], trust_file);
                trust_buf[trust_file.len] = 0;

                if (c.SSL_CTX_load_verify_locations(ctx, &trust_buf, null) != 1) {
                    logging.logDebug("Failed to load CA certificates from trust_file\n", .{});
                    return TlsError.CertificateInvalid;
                }
            } else {
                // Use system default CA store
                if (c.SSL_CTX_set_default_verify_paths(ctx) != 1) {
                    logging.logDebug("Failed to load default CA certificates\n", .{});
                    return TlsError.CertificateInvalid;
                }
            }

            // Enable verification
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        } else {
            // Disable verification (NOT RECOMMENDED)
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
        }
    }

    /// Configure SSL context for server mode.
    fn configureServerContext(self: *OpenSslTls) !void {
        const ctx = self.ssl_ctx orelse return TlsError.InvalidState;

        // Set minimum TLS version with production security enforcement
        var min_version = self.tlsVersionToOpenSsl(self.config.min_version);

        // SECURITY: Hard-enforce TLS 1.2 minimum in production builds
        // TLS 1.0/1.1 have known vulnerabilities (BEAST, POODLE) and are deprecated
        if (!build_options.allow_legacy_tls) {
            const PRODUCTION_MIN_TLS = c.TLS1_2_VERSION;
            if (min_version < PRODUCTION_MIN_TLS) {
                logging.logDebug("TLS 1.0/1.1 disabled for security. Enforcing TLS 1.2 minimum.\n", .{});
                logging.logDebug("Use -Dallow-legacy-tls=true build option to enable legacy protocols (NOT RECOMMENDED).\n", .{});
                min_version = PRODUCTION_MIN_TLS;
            }
        }

        if (c.SSL_CTX_set_min_proto_version(ctx, min_version) != 1) {
            logging.logDebug("Failed to set minimum TLS version\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Set maximum TLS version
        const max_version = self.tlsVersionToOpenSsl(self.config.max_version);
        if (c.SSL_CTX_set_max_proto_version(ctx, max_version) != 1) {
            logging.logDebug("Failed to set maximum TLS version\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Load server certificate (REQUIRED for server mode)
        if (self.config.cert_file) |cert_file| {
            var cert_buf: [512]u8 = undefined;
            if (cert_file.len >= cert_buf.len) {
                return TlsError.CertificateInvalid;
            }
            @memcpy(cert_buf[0..cert_file.len], cert_file);
            cert_buf[cert_file.len] = 0;

            if (c.SSL_CTX_use_certificate_file(ctx, &cert_buf, c.SSL_FILETYPE_PEM) != 1) {
                logging.logDebug("Failed to load server certificate\n", .{});
                return TlsError.CertificateInvalid;
            }
        } else {
            logging.logDebug("Server certificate not provided\n", .{});
            return TlsError.CertificateInvalid;
        }

        // Load server private key (REQUIRED for server mode)
        if (self.config.key_file) |key_file| {
            var key_buf: [512]u8 = undefined;
            if (key_file.len >= key_buf.len) {
                return TlsError.CertificateInvalid;
            }
            @memcpy(key_buf[0..key_file.len], key_file);
            key_buf[key_file.len] = 0;

            if (c.SSL_CTX_use_PrivateKey_file(ctx, &key_buf, c.SSL_FILETYPE_PEM) != 1) {
                logging.logDebug("Failed to load server private key\n", .{});
                return TlsError.CertificateInvalid;
            }
        } else {
            logging.logDebug("Server private key not provided\n", .{});
            return TlsError.CertificateInvalid;
        }

        // Verify that certificate and key match
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            logging.logDebug("Server certificate and private key do not match\n", .{});
            return TlsError.CertificateInvalid;
        }

        // Configure cipher suites (2025 security best practices - AEAD-only)
        // TLS 1.2 cipher list: Only ECDHE with AEAD ciphers (AES-GCM, ChaCha20-Poly1305)
        // This eliminates CBC ciphers (Lucky13), 3DES (Sweet32), and non-forward-secret ciphers
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.SSL_CTX_set_cipher_list(ctx, &cipher_buf) != 1) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return TlsError.InvalidCipherSuite;
        }

        // Configure TLS 1.3 cipher suites (OpenSSL 1.1.1+)
        // TLS 1.3 only supports AEAD ciphers by design
        const tls13_ciphers = "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256";
        var tls13_buf: [256]u8 = undefined;
        if (tls13_ciphers.len >= tls13_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(tls13_buf[0..tls13_ciphers.len], tls13_ciphers);
        tls13_buf[tls13_ciphers.len] = 0;

        // SSL_CTX_set_ciphersuites() is for TLS 1.3 only (OpenSSL 1.1.1+)
        if (c.SSL_CTX_set_ciphersuites(ctx, &tls13_buf) != 1) {
            // Non-fatal: might be using older OpenSSL without TLS 1.3 support
            logging.logDebug("Warning: Failed to set TLS 1.3 cipher suites (OpenSSL may not support TLS 1.3)\n", .{});
        }

        // Security hardening: Disable compression (CRIME attack protection)
        const SSL_OP_NO_COMPRESSION: c_long = 0x00020000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);

        // Security hardening: Disable session tickets (privacy protection)
        const SSL_OP_NO_TICKET: c_long = 0x00004000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_TICKET);

        // Security hardening: Prefer server cipher order
        const SSL_OP_CIPHER_SERVER_PREFERENCE: c_long = 0x00400000;
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_CIPHER_SERVER_PREFERENCE);
    }

    /// Convert TlsVersion enum to OpenSSL version constant.
    fn tlsVersionToOpenSsl(self: *OpenSslTls, version: TlsVersion) c_int {
        _ = self;
        return switch (version) {
            .tls_1_0 => c.TLS1_VERSION,
            .tls_1_1 => c.TLS1_1_VERSION,
            .tls_1_2 => c.TLS1_2_VERSION,
            .tls_1_3 => c.TLS1_3_VERSION,
            // DTLS versions should not be used with TLS connections
            .dtls_1_0, .dtls_1_2, .dtls_1_3 => c.TLS1_2_VERSION, // Fallback to TLS 1.2
        };
    }

    /// Perform TLS handshake (client or server) with retry logic for non-blocking sockets.
    ///
    /// **Behavior:**
    /// - Retries handshake when socket returns WANT_READ/WANT_WRITE
    /// - Uses poll() with 1-second timeout per retry
    /// - Maximum 30 retries (30 seconds total timeout)
    /// - Returns error on real handshake failures
    fn doHandshake(self: *OpenSslTls) !void {
        const ssl = self.ssl orelse return TlsError.InvalidState;
        self.state = .handshake_in_progress;

        var handshake_complete = false;
        var retry_count: u32 = 0;
        const max_retries: u32 = 30; // 30 seconds total timeout

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
                // Socket not ready, wait with poll()
                var pollfds = [_]posix.pollfd{.{
                    .fd = self.socket,
                    .events = if (err == c.SSL_ERROR_WANT_READ) posix.POLL.IN else posix.POLL.OUT,
                    .revents = 0,
                }};

                const ready = try posix.poll(&pollfds, 1000); // 1 second timeout
                if (ready == 0) {
                    retry_count += 1;
                    continue; // Timeout, retry
                }

                // Check for socket errors
                if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                    logging.logDebug("Socket error during TLS handshake\n", .{});
                    return TlsError.HandshakeFailed;
                }

                // Socket ready, retry handshake
                continue;
            } else {
                // Real error, not just blocking
                self.logOpenSslError("Handshake failed", err);
                return self.mapOpenSslError(err);
            }
        }

        if (!handshake_complete) {
            logging.logDebug("TLS handshake timeout after {d} retries\n", .{retry_count});
            return TlsError.HandshakeFailed;
        }
    }

    /// Verify hostname matches certificate (client mode only).
    fn verifyHostname(self: *OpenSslTls) !void {
        const ssl = self.ssl orelse return TlsError.InvalidState;

        // Get server name from config
        const server_name = self.config.server_name orelse {
            logging.logDebug("No server_name provided for hostname verification\n", .{});
            return TlsError.HostnameMismatch;
        };

        // Get peer certificate
        const cert = c.SSL_get_peer_certificate(ssl);
        if (cert == null) {
            logging.logDebug("No peer certificate received\n", .{});
            return TlsError.CertificateVerificationFailed;
        }
        defer c.X509_free(cert);

        // Verify hostname using OpenSSL's built-in verification
        var hostname_buf: [256]u8 = undefined;
        if (server_name.len >= hostname_buf.len) {
            return TlsError.HostnameMismatch;
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
            return TlsError.HostnameMismatch;
        }
    }

    /// Read decrypted data from TLS connection.
    ///
    /// **Parameters:**
    /// - `buffer`: Destination buffer for plaintext data
    ///
    /// **Returns:**
    /// Number of bytes read (0 indicates clean shutdown by peer).
    ///
    /// **Errors:**
    /// - `error.InvalidState`: Connection not in `.connected` state
    /// - `error.AlertReceived`: Received TLS alert from peer
    /// - `error.WouldBlock`: No data available (non-blocking mode)
    ///
    /// **Blocking Behavior:**
    /// This call blocks until data is available. For non-blocking I/O,
    /// set the underlying socket to non-blocking mode before calling.
    pub fn read(self: *OpenSslTls, buffer: []u8) !usize {
        if (self.state != .connected) {
            return TlsError.InvalidState;
        }

        const ssl = self.ssl orelse return TlsError.InvalidState;
        const result = c.SSL_read(ssl, buffer.ptr, @intCast(buffer.len));

        if (result > 0) {
            return @intCast(result);
        }

        // Handle zero or negative return
        if (result == 0) {
            // Clean shutdown
            return 0;
        }

        // Error occurred
        const err = c.SSL_get_error(ssl, result);
        return self.mapOpenSslError(err);
    }

    /// Write data to TLS connection (will be encrypted before sending).
    ///
    /// **Parameters:**
    /// - `data`: Plaintext data to encrypt and send
    ///
    /// **Returns:**
    /// Number of plaintext bytes written.
    ///
    /// **Errors:**
    /// - `error.InvalidState`: Connection not in `.connected` state
    /// - `error.WouldBlock`: Send buffer full (non-blocking mode)
    ///
    /// **Note:**
    /// The return value indicates how many plaintext bytes were accepted,
    /// not how many encrypted bytes were sent over the wire.
    pub fn write(self: *OpenSslTls, data: []const u8) !usize {
        if (self.state != .connected) {
            return TlsError.InvalidState;
        }

        const ssl = self.ssl orelse return TlsError.InvalidState;
        const result = c.SSL_write(ssl, data.ptr, @intCast(data.len));

        if (result > 0) {
            return @intCast(result);
        }

        // Error occurred
        const err = c.SSL_get_error(ssl, result);
        return self.mapOpenSslError(err);
    }

    /// Close TLS connection gracefully by sending close_notify alert.
    ///
    /// **Behavior:**
    /// - Sends TLS close_notify alert to peer (best-effort)
    /// - Does NOT close the underlying socket
    /// - Does NOT free memory (call `deinit()` separately)
    ///
    /// **Safe to call multiple times:**
    /// Subsequent calls are no-ops.
    pub fn close(self: *OpenSslTls) void {
        if (self.state == .connected) {
            if (self.ssl) |ssl| {
                // Send close_notify (ignore errors, best-effort)
                _ = c.SSL_shutdown(ssl);
            }
            self.state = .closed;
        }
    }

    /// Free all TLS resources.
    ///
    /// **Behavior:**
    /// - Frees SSL object and SSL_CTX
    /// - Does NOT close the underlying socket
    /// - Does NOT send close_notify (call `close()` first if needed)
    ///
    /// **MUST be called** to prevent memory leaks.
    pub fn deinit(self: *OpenSslTls) void {
        if (self.ssl) |ssl| {
            c.SSL_free(ssl);
            self.ssl = null;
        }

        if (self.ssl_ctx) |ctx| {
            c.SSL_CTX_free(ctx);
            self.ssl_ctx = null;
        }
    }

    /// Map OpenSSL error code to TlsError.
    fn mapOpenSslError(self: *OpenSslTls, ssl_error: c_int) TlsError {
        _ = self;
        return switch (ssl_error) {
            c.SSL_ERROR_NONE => TlsError.InvalidState, // Should not reach here
            c.SSL_ERROR_ZERO_RETURN => TlsError.InvalidState, // Clean shutdown (handled separately)
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => TlsError.WouldBlock, // Non-blocking I/O
            c.SSL_ERROR_SYSCALL => TlsError.AlertReceived,
            c.SSL_ERROR_SSL => TlsError.HandshakeFailed,
            else => TlsError.AlertReceived,
        };
    }

    /// Log OpenSSL error details (verbose mode only).
    fn logOpenSslError(self: *OpenSslTls, context: []const u8, ssl_error: c_int) void {
        _ = self;
        logging.logDebug("{s}: SSL error code {d}\n", .{ context, ssl_error });

        // Print error queue
        var err = c.ERR_get_error();
        while (err != 0) : (err = c.ERR_get_error()) {
            var buf: [256]u8 = undefined;
            c.ERR_error_string_n(err, &buf, buf.len);
            logging.logDebug("  OpenSSL: {s}\n", .{buf});
        }
    }
};

// Unit tests
const testing = std.testing;

test "OpenSslTls initialization" {
    // Basic compile-time test to ensure structure is well-formed
    const tls = OpenSslTls{
        .allocator = testing.allocator,
        .socket = 0,
        .config = .{},
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
    };

    try testing.expectEqual(OpenSslTls.ConnectionState.initial, tls.state);
    try testing.expect(tls.is_client);
}

test "TLS version mapping" {
    var tls = OpenSslTls{
        .allocator = testing.allocator,
        .socket = 0,
        .config = .{},
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
    };

    const v12 = tls.tlsVersionToOpenSsl(.tls_1_2);
    const v13 = tls.tlsVersionToOpenSsl(.tls_1_3);

    try testing.expectEqual(c.TLS1_2_VERSION, v12);
    try testing.expectEqual(c.TLS1_3_VERSION, v13);
}
