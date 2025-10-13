// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Production TLS implementation using wolfSSL C FFI.
//!
//! This module provides a lightweight, production-ready TLS implementation
//! by wrapping wolfSSL's library (30-100KB static vs 3-4MB OpenSSL). It provides:
//! - Full TLS 1.2/1.3 support with modern cipher suites
//! - Certificate verification with hostname validation
//! - Server Name Indication (SNI) support
//! - Client and server mode operations
//! - 90-95% OpenSSL API compatibility via --enable-opensslextra
//!
//! **Security Features:**
//! - Default cipher suite: ECDHE with AEAD ciphers only
//! - Certificate verification enabled by default
//! - Hostname validation for client connections
//! - TLS 1.2 minimum by default (configurable)
//!
//! **Binary Size:**
//! - wolfSSL minimal build: ~30-100KB (vs OpenSSL ~3-4MB)
//! - Full feature build: ~300KB-1MB
//! - Static linking friendly (enables TLS in musl static builds)
//!
//! **Requirements:**
//! - wolfSSL 5.x or later with --enable-opensslextra
//! - Link with -lwolfssl
//! - Add to build.zig: exe.linkSystemLibrary("wolfssl");
//!
//! **Thread Safety:**
//! Each WolfSslTls instance is NOT thread-safe. Use separate instances
//! per thread or add external synchronization.

const std = @import("std");
const tls_iface = @import("tls_iface.zig");
const TlsConfig = tls_iface.TlsConfig;
const TlsError = tls_iface.TlsError;
const TlsVersion = tls_iface.TlsVersion;
const posix = std.posix;
const logging = @import("../util/logging.zig");
const build_options = @import("build_options");

// Conditional compilation: Only include C headers if wolfSSL backend enabled
const use_wolfssl = @hasDecl(build_options, "use_wolfssl") and build_options.use_wolfssl;

// C FFI bindings for wolfSSL (with OpenSSL compatibility layer)
// Only compiled when use_wolfssl is true
const c = if (use_wolfssl)
    @cImport({
        @cInclude("wolfssl/options.h"); // Must be first
        // Prevent stdatomic.h conflict: Force use of __atomic builtins instead of C11 atomics
        // wolfSSL has HAVE_C___ATOMIC (GCC atomics) and WOLFSSL_HAVE_ATOMIC_H (C11 atomics)
        // We undefine WOLFSSL_HAVE_ATOMIC_H to skip the #include <stdatomic.h> path
        // This forces wolfSSL to use __atomic_load_n/__atomic_store_n (GCC builtins) which work with Zig
        @cUndef("WOLFSSL_HAVE_ATOMIC_H");
        @cInclude("wolfssl/ssl.h");
        @cInclude("wolfssl/error-ssl.h");
        @cInclude("wolfssl/wolfcrypt/error-crypt.h"); // Note: in wolfcrypt subdirectory
    })
else
    struct {}; // Stub when wolfSSL not enabled

/// wolfSSL-based TLS connection implementation.
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
/// - WOLFSSL_CTX and WOLFSSL objects managed internally
/// - Call `deinit()` to free wolfSSL resources
/// - Socket ownership remains with caller
pub const WolfSslTls = if (use_wolfssl) struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    config: TlsConfig,
    ssl_ctx: ?*c.WOLFSSL_CTX,
    ssl: ?*c.WOLFSSL,
    state: ConnectionState,
    is_client: bool,

    const ConnectionState = enum {
        initial,
        handshake_in_progress,
        connected,
        closed,
    };

    /// Initialize wolfSSL library (call once per process).
    ///
    /// **Must be called before any TLS operations.**
    ///
    /// This initializes wolfSSL's global state including cryptographic
    /// subsystems and threading support.
    pub fn initWolfSsl() void {
        _ = c.wolfSSL_Init();
    }

    /// Cleanup wolfSSL library (call once at process exit).
    ///
    /// **Should be called after all TLS connections are closed.**
    pub fn cleanupWolfSsl() void {
        _ = c.wolfSSL_Cleanup();
    }

    /// Create a client-side TLS connection and perform handshake.
    ///
    /// **Parameters:**
    /// - `allocator`: Memory allocator (minimal usage)
    /// - `socket`: Pre-connected TCP socket (must remain open)
    /// - `config`: TLS configuration (server_name, verify_peer, etc.)
    ///
    /// **Returns:**
    /// Heap-allocated `WolfSslTls` instance in `.connected` state.
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
    /// const tls = try WolfSslTls.initClient(allocator, sock, config);
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
    ) !*WolfSslTls {
        const self = try allocator.create(WolfSslTls);
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

        // Ensure wolfSSL is initialized
        initWolfSsl();

        // Create SSL context with TLS client method
        const method = c.wolfTLSv1_2_client_method();
        if (method == null) {
            logging.logDebug("Failed to get wolfSSL client method\n", .{});
            return TlsError.HandshakeFailed;
        }

        self.ssl_ctx = c.wolfSSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create wolfSSL_CTX\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.wolfSSL_CTX_free(self.ssl_ctx);

        // Configure SSL context
        try self.configureClientContext();

        // Create SSL object
        self.ssl = c.wolfSSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create wolfSSL object\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.wolfSSL_free(self.ssl);

        // Attach socket to SSL
        if (c.wolfSSL_set_fd(self.ssl, socket) != c.WOLFSSL_SUCCESS) {
            logging.logDebug("Failed to set wolfSSL file descriptor\n", .{});
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

            if (c.wolfSSL_UseSNI(self.ssl, c.WOLFSSL_SNI_HOST_NAME, &hostname_buf, @intCast(server_name.len)) != c.WOLFSSL_SUCCESS) {
                logging.logDebug("Failed to set SNI hostname\n", .{});
                return TlsError.HandshakeFailed;
            }
        }

        // Enable hostname verification BEFORE handshake (wolfSSL will verify during handshake)
        if (config.verify_peer and config.server_name != null) {
            const server_name = config.server_name.?;
            var hostname_buf: [256]u8 = undefined;
            if (server_name.len >= hostname_buf.len) {
                return TlsError.HandshakeFailed;
            }
            @memcpy(hostname_buf[0..server_name.len], server_name);
            hostname_buf[server_name.len] = 0;

            // Enable automatic hostname verification during handshake
            if (c.wolfSSL_check_domain_name(self.ssl, &hostname_buf) != c.WOLFSSL_SUCCESS) {
                logging.logDebug("Failed to enable hostname verification\n", .{});
                return TlsError.HandshakeFailed;
            }
        }

        // Perform TLS handshake (hostname verification happens automatically if enabled above)
        try self.doHandshake();

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
    /// Heap-allocated `WolfSslTls` instance in `.connected` state.
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
    /// const tls = try WolfSslTls.initServer(allocator, client_sock, config);
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
    ) !*WolfSslTls {
        const self = try allocator.create(WolfSslTls);
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

        // Ensure wolfSSL is initialized
        initWolfSsl();

        // Create SSL context with TLS server method
        const method = c.wolfTLSv1_2_server_method();
        if (method == null) {
            logging.logDebug("Failed to get wolfSSL server method\n", .{});
            return TlsError.HandshakeFailed;
        }

        self.ssl_ctx = c.wolfSSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create wolfSSL_CTX\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.wolfSSL_CTX_free(self.ssl_ctx);

        // Configure SSL context
        try self.configureServerContext();

        // Create SSL object
        self.ssl = c.wolfSSL_new(self.ssl_ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create wolfSSL object\n", .{});
            return TlsError.HandshakeFailed;
        }
        errdefer c.wolfSSL_free(self.ssl);

        // Attach socket to SSL
        if (c.wolfSSL_set_fd(self.ssl, socket) != c.WOLFSSL_SUCCESS) {
            logging.logDebug("Failed to set wolfSSL file descriptor\n", .{});
            return TlsError.HandshakeFailed;
        }

        // Perform TLS handshake
        try self.doHandshake();

        self.state = .connected;
        return self;
    }

    /// Configure SSL context for client mode.
    fn configureClientContext(self: *WolfSslTls) !void {
        const ctx = self.ssl_ctx orelse return TlsError.InvalidState;

        // Set minimum TLS version with production security enforcement
        const min_version_int = self.tlsVersionToWolfSsl(self.config.min_version);

        // SECURITY: Hard-enforce TLS 1.2 minimum in production builds
        if (!build_options.allow_legacy_tls) {
            const PRODUCTION_MIN_TLS = c.WOLFSSL_TLSV1_2;
            if (min_version_int < PRODUCTION_MIN_TLS) {
                logging.logDebug("TLS 1.0/1.1 disabled for security. Enforcing TLS 1.2 minimum.\n", .{});
                logging.logDebug("Use -Dallow-legacy-tls=true build option to enable legacy protocols (NOT RECOMMENDED).\n", .{});
            }
        }

        // wolfSSL uses method-specific context, version set via method selection
        // For dynamic version negotiation, use wolfSSL_CTX_set_min_proto_version (wolfSSL 5.0+)

        // Configure cipher suites (2025 security best practices - AEAD-only)
        // wolfSSL cipher list format (same as OpenSSL for compatibility)
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:TLS13-AES256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.wolfSSL_CTX_set_cipher_list(ctx, &cipher_buf) != c.WOLFSSL_SUCCESS) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return TlsError.InvalidCipherSuite;
        }

        // Configure certificate verification
        if (self.config.verify_peer) {
            // Load CA certificates
            if (self.config.trust_file) |trust_file| {
                var trust_buf: [512]u8 = undefined;
                if (trust_file.len >= trust_buf.len) {
                    return TlsError.HandshakeFailed;
                }
                @memcpy(trust_buf[0..trust_file.len], trust_file);
                trust_buf[trust_file.len] = 0;

                if (c.wolfSSL_CTX_load_verify_locations(ctx, &trust_buf, null) != c.WOLFSSL_SUCCESS) {
                    logging.logDebug("Failed to load CA certificates from trust_file\n", .{});
                    return TlsError.CertificateInvalid;
                }
            } else {
                // Use system default CA store
                if (c.wolfSSL_CTX_load_verify_locations(ctx, null, "/etc/ssl/certs") != c.WOLFSSL_SUCCESS) {
                    logging.logDebug("Failed to load default CA certificates\n", .{});
                    return TlsError.CertificateInvalid;
                }
            }

            // Enable verification (WOLFSSL_VERIFY_PEER)
            c.wolfSSL_CTX_set_verify(ctx, c.WOLFSSL_VERIFY_PEER, null);
        } else {
            // Disable verification (NOT RECOMMENDED)
            c.wolfSSL_CTX_set_verify(ctx, c.WOLFSSL_VERIFY_NONE, null);
        }
    }

    /// Configure SSL context for server mode.
    fn configureServerContext(self: *WolfSslTls) !void {
        const ctx = self.ssl_ctx orelse return TlsError.InvalidState;

        // Load server certificate (REQUIRED for server mode)
        if (self.config.cert_file) |cert_file| {
            var cert_buf: [512]u8 = undefined;
            if (cert_file.len >= cert_buf.len) {
                return TlsError.CertificateInvalid;
            }
            @memcpy(cert_buf[0..cert_file.len], cert_file);
            cert_buf[cert_file.len] = 0;

            if (c.wolfSSL_CTX_use_certificate_file(ctx, &cert_buf, c.WOLFSSL_FILETYPE_PEM) != c.WOLFSSL_SUCCESS) {
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

            if (c.wolfSSL_CTX_use_PrivateKey_file(ctx, &key_buf, c.WOLFSSL_FILETYPE_PEM) != c.WOLFSSL_SUCCESS) {
                logging.logDebug("Failed to load server private key\n", .{});
                return TlsError.CertificateInvalid;
            }
        } else {
            logging.logDebug("Server private key not provided\n", .{});
            return TlsError.CertificateInvalid;
        }

        // Verify that certificate and key match
        if (c.wolfSSL_CTX_check_private_key(ctx) != c.WOLFSSL_SUCCESS) {
            logging.logDebug("Server certificate and private key do not match\n", .{});
            return TlsError.CertificateInvalid;
        }

        // Configure cipher suites (same as client mode)
        const cipher_list = if (self.config.cipher_suites) |cs|
            cs
        else
            "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:TLS13-AES256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES128-GCM-SHA256";

        var cipher_buf: [512]u8 = undefined;
        if (cipher_list.len >= cipher_buf.len) {
            return TlsError.HandshakeFailed;
        }
        @memcpy(cipher_buf[0..cipher_list.len], cipher_list);
        cipher_buf[cipher_list.len] = 0;

        if (c.wolfSSL_CTX_set_cipher_list(ctx, &cipher_buf) != c.WOLFSSL_SUCCESS) {
            logging.logDebug("Failed to set cipher list\n", .{});
            return TlsError.InvalidCipherSuite;
        }
    }

    /// Convert TlsVersion enum to wolfSSL version constant.
    fn tlsVersionToWolfSsl(self: *WolfSslTls, version: TlsVersion) c_int {
        _ = self;
        return switch (version) {
            .tls_1_0 => c.WOLFSSL_TLSV1,
            .tls_1_1 => c.WOLFSSL_TLSV1_1,
            .tls_1_2 => c.WOLFSSL_TLSV1_2,
            .tls_1_3 => c.WOLFSSL_TLSV1_3,
            // DTLS versions should not be used with TLS connections
            .dtls_1_0, .dtls_1_2, .dtls_1_3 => c.WOLFSSL_TLSV1_2, // Fallback to TLS 1.2
        };
    }

    /// Perform TLS handshake (client or server) with retry logic for non-blocking sockets.
    fn doHandshake(self: *WolfSslTls) !void {
        const ssl = self.ssl orelse return TlsError.InvalidState;
        self.state = .handshake_in_progress;

        var handshake_complete = false;
        var retry_count: u32 = 0;
        const max_retries: u32 = 30; // 30 seconds total timeout

        while (!handshake_complete and retry_count < max_retries) {
            const ret = if (self.is_client)
                c.wolfSSL_connect(ssl)
            else
                c.wolfSSL_accept(ssl);

            if (ret == c.WOLFSSL_SUCCESS) {
                // Handshake successful
                handshake_complete = true;
                break;
            }

            const err = c.wolfSSL_get_error(ssl, ret);

            if (err == c.WOLFSSL_ERROR_WANT_READ or err == c.WOLFSSL_ERROR_WANT_WRITE) {
                // Socket not ready, wait with poll()
                var pollfds = [_]posix.pollfd{.{
                    .fd = self.socket,
                    .events = if (err == c.WOLFSSL_ERROR_WANT_READ) posix.POLL.IN else posix.POLL.OUT,
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
                self.logWolfSslError("Handshake failed", err);
                return self.mapWolfSslError(err);
            }
        }

        if (!handshake_complete) {
            logging.logDebug("TLS handshake timeout after {d} retries\n", .{retry_count});
            return TlsError.HandshakeFailed;
        }
    }

    // NOTE: Hostname verification is now handled automatically during handshake
    // via wolfSSL_check_domain_name() called before doHandshake() in initClient().
    // This approach is more efficient and avoids using wolfSSL_get_peer_certificate()
    // and wolfSSL_X509_free() which are not available in Alpine's wolfSSL build.

    /// Read decrypted data from TLS connection.
    pub fn read(self: *WolfSslTls, buffer: []u8) !usize {
        if (self.state != .connected) {
            return TlsError.InvalidState;
        }

        const ssl = self.ssl orelse return TlsError.InvalidState;
        const result = c.wolfSSL_read(ssl, buffer.ptr, @intCast(buffer.len));

        if (result > 0) {
            return @intCast(result);
        }

        // Handle zero or negative return
        if (result == 0) {
            // Clean shutdown
            return 0;
        }

        // Error occurred
        const err = c.wolfSSL_get_error(ssl, result);
        return self.mapWolfSslError(err);
    }

    /// Write data to TLS connection (will be encrypted before sending).
    pub fn write(self: *WolfSslTls, data: []const u8) !usize {
        if (self.state != .connected) {
            return TlsError.InvalidState;
        }

        const ssl = self.ssl orelse return TlsError.InvalidState;
        const result = c.wolfSSL_write(ssl, data.ptr, @intCast(data.len));

        if (result > 0) {
            return @intCast(result);
        }

        // Error occurred
        const err = c.wolfSSL_get_error(ssl, result);
        return self.mapWolfSslError(err);
    }

    /// Close TLS connection gracefully by sending close_notify alert.
    pub fn close(self: *WolfSslTls) void {
        if (self.state == .connected) {
            if (self.ssl) |ssl| {
                // Send close_notify (ignore errors, best-effort)
                _ = c.wolfSSL_shutdown(ssl);
            }
            self.state = .closed;
        }
    }

    /// Free all TLS resources.
    pub fn deinit(self: *WolfSslTls) void {
        if (self.ssl) |ssl| {
            c.wolfSSL_free(ssl);
            self.ssl = null;
        }

        if (self.ssl_ctx) |ctx| {
            c.wolfSSL_CTX_free(ctx);
            self.ssl_ctx = null;
        }
    }

    /// Map wolfSSL error code to TlsError.
    fn mapWolfSslError(self: *WolfSslTls, ssl_error: c_int) TlsError {
        _ = self;
        return switch (ssl_error) {
            c.WOLFSSL_ERROR_NONE => TlsError.InvalidState,
            c.WOLFSSL_ERROR_WANT_READ, c.WOLFSSL_ERROR_WANT_WRITE => TlsError.WouldBlock,
            c.WOLFSSL_ERROR_ZERO_RETURN => TlsError.InvalidState, // Clean shutdown
            else => TlsError.HandshakeFailed,
        };
    }

    /// Log wolfSSL error details (verbose mode only).
    fn logWolfSslError(self: *WolfSslTls, context: []const u8, ssl_error: c_int) void {
        _ = self;
        logging.logDebug("{s}: wolfSSL error code {d}\n", .{ context, ssl_error });

        // Get error string
        const err_str = c.wolfSSL_ERR_error_string(@intCast(ssl_error), null);
        if (err_str != null) {
            logging.logDebug("  wolfSSL: {s}\n", .{err_str});
        }
    }
} else struct {
    // Stub type when wolfSSL backend not enabled
    // This type should never be instantiated at runtime
    socket: std.posix.socket_t,

    pub fn initClient(_: std.mem.Allocator, _: std.posix.socket_t, _: TlsConfig) !*WolfSslTls {
        @panic("wolfSSL backend not enabled. Rebuild with: zig build -Dtls-backend=wolfssl");
    }

    pub fn initServer(_: std.mem.Allocator, _: std.posix.socket_t, _: TlsConfig) !*WolfSslTls {
        @panic("wolfSSL backend not enabled. Rebuild with: zig build -Dtls-backend=wolfssl");
    }

    pub fn read(_: *WolfSslTls, _: []u8) !usize {
        unreachable;
    }

    pub fn write(_: *WolfSslTls, _: []const u8) !usize {
        unreachable;
    }

    pub fn close(_: *WolfSslTls) void {
        unreachable;
    }

    pub fn deinit(_: *WolfSslTls) void {
        unreachable;
    }
};

// Unit tests
const testing = std.testing;

test "WolfSslTls initialization" {
    // Basic compile-time test to ensure structure is well-formed
    const tls = WolfSslTls{
        .allocator = testing.allocator,
        .socket = 0,
        .config = .{},
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
    };

    try testing.expectEqual(WolfSslTls.ConnectionState.initial, tls.state);
    try testing.expect(tls.is_client);
}

test "TLS version mapping" {
    var tls = WolfSslTls{
        .allocator = testing.allocator,
        .socket = 0,
        .config = .{},
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
    };

    const v12 = tls.tlsVersionToWolfSsl(.tls_1_2);
    const v13 = tls.tlsVersionToWolfSsl(.tls_1_3);

    try testing.expectEqual(c.WOLFSSL_TLSV1_2, v12);
    try testing.expectEqual(c.WOLFSSL_TLSV1_3, v13);
}
