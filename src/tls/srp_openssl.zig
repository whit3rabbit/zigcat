// srp_openssl.zig - SRP (Secure Remote Password) encryption using OpenSSL
//
// This module implements end-to-end SRP encryption for gsocket connections.
// It provides password-based authentication and encryption without X.509 certificates.
//
// **Protocol Flow:**
// 1. Raw GSRN tunnel established (see net/gsocket.zig)
// 2. SRP handshake performed over tunnel (this module)
// 3. AES-256 encrypted stream ready for bidirectional transfer
//
// **Key Features:**
// - Password-based authentication (no certificates)
// - Cipher: SRP-AES-256-CBC-SHA (required for gs-netcat compatibility)
// - Client and server modes
// - Compatible with original gsocket implementation
//
// **Security Notes:**
// - Uses SHA-1 MAC (weak, but required for gsocket compatibility)
// - SRP provides mutual authentication without PKI
// - Password derived from secret (see gsocket.deriveSrpPassword)

const std = @import("std");
const gsocket = @import("../net/gsocket.zig");
const logging = @import("../util/logging.zig");
const posix = std.posix;

// Check if TLS is enabled at compile time
const build_options = @import("build_options");
comptime {
    if (!build_options.enable_tls) {
        @compileError("srp_openssl.zig requires TLS to be enabled. SRP encryption depends on OpenSSL. Build with -Dtls=true or use a different connection mode.");
    }
}

// C FFI bindings for OpenSSL
pub const c = @cImport({
    // Suppress deprecation warnings for SRP (no replacement API in OpenSSL 3.x)
    @cDefine("OPENSSL_SUPPRESS_DEPRECATED", "1");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/srp.h");
    @cInclude("openssl/bn.h"); // BIGNUM operations for SRP verifier
    @cInclude("openssl/safestack.h"); // STACK operations for OpenSSL 1.1.1 compatibility
});

// OpenSSL version detection for API compatibility
// OpenSSL 3.0.0+ has public SRP_user_pwd_new() API
// OpenSSL 1.1.1 requires manual struct population (internal API)
const OPENSSL_VERSION_3_0_0: c_long = 0x30000000;
const has_srp_user_pwd_api = c.OPENSSL_VERSION_NUMBER >= OPENSSL_VERSION_3_0_0;

// ============================================================================
// OpenSSL 1.1.1 Compatibility Structures
// ============================================================================
// NOTE: These structures are INTERNAL in OpenSSL 1.1.1 but we need them for
// backward compatibility. In OpenSSL 3.0+, use the public API instead.
//
// Structure layout verified from OpenSSL 1.1.1 source:
// https://github.com/openssl/openssl/blob/OpenSSL_1_1_1-stable/include/openssl/srp.h

/// SRP_gN_cache structure (RFC 5054 group parameters)
const SRP_gN_cache = extern struct {
    b64_bn_N: [*c]u8,  // Base64-encoded N (modulus)
    b64_bn_g: [*c]u8,  // Base64-encoded g (generator)
    bn_N: ?*c.BIGNUM,  // Decoded N
    bn_g: ?*c.BIGNUM,  // Decoded g
};

/// SRP_user_pwd structure (user verifier record)
/// Memory ownership:
/// - id, info, s, v: Owned by this struct (must be allocated/freed)
/// - g, N: Not owned (point to external SRP_gN_cache data)
const SRP_user_pwd_compat = extern struct {
    id: [*c]u8,           // Username (owned, must be freed)
    s: ?*c.BIGNUM,        // Salt (owned)
    v: ?*c.BIGNUM,        // Verifier (owned)
    g: ?*const c.BIGNUM,  // Generator (not owned, points to gN cache)
    N: ?*const c.BIGNUM,  // Modulus (not owned, points to gN cache)
    info: [*c]u8,         // User info (owned, can be NULL)
};

// SRP password callback type
const SrpClientPwdCallback = ?*const fn (?*c.SSL, ?*anyopaque) callconv(std.builtin.CallingConvention.c) [*c]u8;

// ============================================================================
// Error Types
// ============================================================================

pub const SrpError = error{
    InitFailed,
    HandshakeFailed,
    WouldBlock,
    SystemError,
    ProtocolError,
    SyscallError,
    InvalidState,
    MissingPassword,
    SrpNotSupported,
    InvalidSecret,
};

// ============================================================================
// Secret Validation
// ============================================================================

/// Validate secret length for cryptographic strength.
///
/// **Security Requirements:**
/// - Minimum 8 bytes (64-bit entropy) to prevent brute-force attacks
/// - Maximum 1024 bytes to prevent DoS via excessive memory usage
/// - Empty secrets are rejected (would derive predictable password)
///
/// **Attack Scenarios Prevented:**
/// 1. Empty secret → predictable SRP verifier → authentication bypass
/// 2. Very long secret → memory exhaustion → DoS
///
/// Parameters:
///   secret: User-provided secret for SRP password derivation
///
/// Returns: error.InvalidSecret if validation fails
fn validateSecret(secret: []const u8) !void {
    if (secret.len < 8) {
        logging.logDebug("SRP secret too short (minimum 8 bytes required for 64-bit entropy)\n", .{});
        return SrpError.InvalidSecret;
    }

    if (secret.len > 1024) {
        logging.logDebug("SRP secret too long (maximum 1024 bytes to prevent DoS)\n", .{});
        return SrpError.InvalidSecret;
    }
}

// ============================================================================
// SRP Connection Structure
// ============================================================================

// Client password callback context (passed to OpenSSL)
const SrpClientContext = struct {
    password: gsocket.SrpPassword,
};

// Server username callback context
const SrpServerContext = struct {
    password: gsocket.SrpPassword,
    srp_vbase: ?*c.SRP_VBASE,
};

/// SRP-encrypted connection using OpenSSL
///
/// **Lifecycle:**
/// 1. Create via `initClient()` or `initServer()`
/// 2. Use `read()`/`write()` for encrypted I/O
/// 3. Call `close()` to send TLS close_notify
/// 4. Call `deinit(allocator)` to free all resources (including self)
///
/// **Memory Management:**
/// - SSL_CTX and SSL objects managed internally
/// - Call `deinit(allocator)` to free OpenSSL resources AND the structure itself
/// - Underlying stream ownership remains with caller
/// - SECURITY FIX: deinit() now frees the structure to prevent memory leaks
pub const SrpConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream, // Underlying GSRN tunnel
    ssl_ctx: ?*c.SSL_CTX,
    ssl: ?*c.SSL,
    state: ConnectionState,
    is_client: bool,
    srp_client_ctx: ?*SrpClientContext, // Only for client mode
    srp_server_ctx: ?*SrpServerContext, // Only for server mode

    pub const ConnectionState = enum {
        initial,
        handshake_in_progress,
        connected,
        closed,
    };

    /// Initialize OpenSSL library (call once per process)
    pub fn initOpenSsl() void {
        _ = c.OPENSSL_init_ssl(0, null);
    }

    /// SRP client password callback (called by OpenSSL during handshake)
    fn srpClientPasswordCallback(ssl: ?*c.SSL, arg: ?*anyopaque) callconv(std.builtin.CallingConvention.c) [*c]u8 {
        _ = ssl;
        if (arg) |ctx_ptr| {
            const ctx: *SrpClientContext = @ptrCast(@alignCast(ctx_ptr));
            // Return pointer to our null-terminated password
            return @constCast(@ptrCast(&ctx.password));
        }
        return null;
    }

    /// SRP server username callback (called by OpenSSL during handshake)
    ///
    /// This callback is invoked when the server receives a client's SRP handshake.
    /// It must provide the SRP parameters (N, g, salt, verifier) for the requested username.
    ///
    /// **Parameters:**
    /// - ssl: SSL connection pointer
    /// - ad: Alert descriptor (writable, for setting error alerts)
    /// - arg: User-defined argument (SRP_VBASE pointer via SSL_CTX_set_srp_cb_arg)
    ///
    /// **Returns:**
    /// - SSL_ERROR_NONE (0): Success, proceed with handshake
    /// - SSL3_AL_FATAL: Fatal error, abort handshake
    ///
    /// **Memory Management:**
    /// CRITICAL: SRP_VBASE_get1_by_user() returns a NEW structure that MUST be freed
    /// with SRP_user_pwd_free() to prevent memory leak.
    fn srpServerUsernameCallback(
        ssl: ?*c.SSL,
        ad: [*c]c_int,
        arg: ?*anyopaque,
    ) callconv(std.builtin.CallingConvention.c) c_int {
        // *** FIX: Use standard OpenSSL error reporting (not -1) ***
        // Validate inputs
        if (ssl == null) {
            logging.logDebug("SRP server callback: null SSL pointer\n", .{});
            ad[0] = c.SSL_AD_INTERNAL_ERROR;
            return c.SSL3_AL_FATAL;
        }

        if (arg == null) {
            logging.logDebug("SRP server callback: null arg pointer (SRP_VBASE not initialized)\n", .{});
            ad[0] = c.SSL_AD_INTERNAL_ERROR;
            return c.SSL3_AL_FATAL;
        }

        // Cast arg to SRP_VBASE pointer
        const srp_vbase = @as(*c.SRP_VBASE, @ptrCast(@alignCast(arg)));

        // Retrieve user credentials from database (hardcoded username "user")
        // SECURITY NOTE: Hardcoded username enables offline credential enumeration
        // Future: Consider deriving username from secret for stronger authentication
        // CRITICAL: get1 returns NEW structure, caller must free
        const username: [*:0]const u8 = "user";
        const username_ptr: [*c]u8 = @constCast(@ptrCast(username));
        const p = c.SRP_VBASE_get1_by_user(srp_vbase, username_ptr);
        if (p == null) {
            logging.logDebug("SRP server callback: user not found in database\n", .{});
            ad[0] = c.SSL_AD_UNKNOWN_PSK_IDENTITY; // Set alert descriptor
            return c.SSL3_AL_FATAL; // Fatal error
        }

        // Set SRP parameters for this connection
        // Parameters: N (prime), g (generator), s (salt), v (verifier), info (optional)
        if (c.SSL_set_srp_server_param(ssl, p.*.N, p.*.g, p.*.s, p.*.v, null) != 1) {
            logging.logDebug("SRP server callback: SSL_set_srp_server_param failed\n", .{});
            logOpenSslErrors();
            c.SRP_user_pwd_free(p); // MUST free before returning
            ad[0] = c.SSL_AD_INTERNAL_ERROR;
            return c.SSL3_AL_FATAL;
        }

        // Free the returned structure (CRITICAL: prevent memory leak)
        c.SRP_user_pwd_free(p);

        logging.logDebug("SRP server callback: Successfully set SRP parameters\n", .{});
        return c.SSL_ERROR_NONE; // Success
    }

    /// Create a client-side SRP connection and perform handshake
    ///
    /// **Parameters:**
    /// - allocator: Memory allocator
    /// - stream: Pre-established GSRN tunnel (from gsocket.establishGsrnTunnel)
    /// - secret: Shared secret for SRP password derivation
    /// - timeout_ms: Handshake timeout in milliseconds
    ///
    /// **Returns:**
    /// Heap-allocated SrpConnection in `.connected` state
    ///
    /// **Errors:**
    /// - error.HandshakeFailed: SRP handshake failed
    /// - error.SrpNotSupported: OpenSSL compiled without SRP support
    pub fn initClient(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        secret: []const u8,
        timeout_ms: u32,
    ) !*SrpConnection {
        const self = try allocator.create(SrpConnection);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = true,
            .srp_client_ctx = null,
            .srp_server_ctx = null,
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // SECURITY FIX: Validate secret length
        try validateSecret(secret);

        // Derive SRP password from secret
        const srp_password = gsocket.deriveSrpPassword(secret);

        // Create client context for callback
        const client_ctx = try allocator.create(SrpClientContext);
        errdefer allocator.destroy(client_ctx);
        client_ctx.* = .{ .password = srp_password };
        self.srp_client_ctx = client_ctx;

        // Create SSL context with TLS method
        const method = c.TLS_client_method();
        if (method == null) {
            logging.logDebug("Failed to get TLS client method\n", .{});
            return SrpError.InitFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return SrpError.InitFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        const ctx = self.ssl_ctx.?;

        // Set SRP cipher suite (CRITICAL: Must match gsocket)
        const srp_cipher = "SRP-AES-256-CBC-SHA";
        if (c.SSL_CTX_set_cipher_list(ctx, srp_cipher) != 1) {
            logging.logDebug("Failed to set SRP cipher suite (OpenSSL may not support SRP)\n", .{});
            logOpenSslErrors();
            return SrpError.SrpNotSupported;
        }

        // SECURITY WARNING: SHA-1 MAC is deprecated (required for gs-netcat compatibility)
        logging.logDebug("WARNING: Using SRP-AES-256-CBC-SHA (SHA-1 MAC is deprecated, required for gs-netcat compatibility)\n", .{});

        // Set SRP username (always "user" in gsocket protocol)
        // SECURITY NOTE: Hardcoded username enables offline credential enumeration
        // Future: Consider deriving username from secret for stronger authentication
        const username: [*:0]const u8 = "user";
        const username_ptr: [*c]u8 = @constCast(@ptrCast(username));
        if (c.SSL_CTX_set_srp_username(ctx, username_ptr) != 1) {
            logging.logDebug("Failed to set SRP username\n", .{});
            logOpenSslErrors();
            return SrpError.InitFailed;
        }

        // Set SRP password callback
        _ = c.SSL_CTX_set_srp_client_pwd_callback(ctx, srpClientPasswordCallback);

        // Pass our context to the callback
        _ = c.SSL_CTX_set_srp_cb_arg(ctx, client_ctx);

        // Create SSL object
        self.ssl = c.SSL_new(ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return SrpError.InitFailed;
        }
        errdefer c.SSL_free(self.ssl);

        const ssl = self.ssl.?;

        // Attach socket to SSL
        const socket_fd = stream.handle;
        if (c.SSL_set_fd(ssl, socket_fd) != 1) {
            logging.logDebug("Failed to set SSL file descriptor\n", .{});
            return SrpError.InitFailed;
        }

        // Perform SRP handshake
        try self.doHandshake(timeout_ms);

        self.state = .connected;
        logging.logDebug("SRP client handshake complete\n", .{});

        return self;
    }

    /// Initialize SRP verifier database with derived password
    ///
    /// This function creates an SRP_VBASE structure and registers a single user ("user")
    /// with the provided password. The verifier is computed using SRP-6a protocol with
    /// a 4096-bit group from RFC 5054.
    ///
    /// **Parameters:**
    /// - password: Null-terminated SRP password (32 hex chars + null)
    ///
    /// **Returns:**
    /// Pointer to initialized SRP_VBASE structure
    ///
    /// **Errors:**
    /// - error.InitFailed: OpenSSL SRP initialization failed
    ///
    /// **Memory Management:**
    /// - Caller MUST call SRP_VBASE_free() on returned pointer
    /// - salt/verifier ownership transferred to SRP_VBASE (don't free manually)
    fn setupSrpVbase(password: gsocket.SrpPassword) !*c.SRP_VBASE {
        // 1. Allocate SRP_VBASE structure
        const srp_vbase = c.SRP_VBASE_new(null);
        if (srp_vbase == null) {
            logging.logDebug("Failed to create SRP_VBASE\n", .{});
            return SrpError.InitFailed;
        }
        errdefer c.SRP_VBASE_free(srp_vbase);

        // 2. Get default 4096-bit SRP group parameters (RFC 5054)
        // NOTE: Returns pointer to STATIC data (valid for process lifetime)
        const gN = c.SRP_get_default_gN("4096");
        if (gN == null) {
            logging.logDebug("Failed to get SRP group parameters\n", .{});
            return SrpError.InitFailed;
        }

        // SECURITY FIX: Validate pointers before dereferencing
        if (gN.*.g == null or gN.*.N == null) {
            logging.logDebug("Invalid SRP group parameters (null pointers)\n", .{});
            return SrpError.InitFailed;
        }

        // 3. Validate group parameters (security check)
        const group_check = c.SRP_check_known_gN_param(gN.*.g, gN.*.N);
        if (group_check == null) {
            logging.logDebug("Invalid SRP group parameters\n", .{});
            return SrpError.InitFailed;
        }

        // 4. Generate salt and verifier from password
        // CRITICAL: salt and verifier are allocated by OpenSSL (BIGNUM structures)
        var salt: ?*c.BIGNUM = null;
        var verifier: ?*c.BIGNUM = null;
        // SECURITY NOTE: Hardcoded username "user" (required for gs-netcat compatibility)
        const username: [*:0]const u8 = "user";
        const password_ptr: [*:0]const u8 = @ptrCast(&password);

        // SECURITY FIX: Check return value (0 on error, nonzero on success)
        // SRP_create_verifier_BN returns int (1 on success, 0 on error per OpenSSL docs)
        const result = c.SRP_create_verifier_BN(
            username,
            password_ptr,
            &salt,
            &verifier,
            gN.*.N,
            gN.*.g,
        );

        if (result == 0) {
            logging.logDebug("Failed to create SRP verifier (OpenSSL returned 0)\n", .{});
            logOpenSslErrors();
            // Defensive cleanup (even though OpenSSL should have freed on error)
            if (salt != null) c.BN_free(salt);
            if (verifier != null) c.BN_free(verifier);
            return SrpError.InitFailed;
        }

        // Additional validation after successful return
        if (salt == null or verifier == null) {
            logging.logDebug("SRP_create_verifier_BN returned success but null parameters\n", .{});
            logOpenSslErrors();
            // Free salt/verifier if they were allocated before error
            if (salt != null) c.BN_free(salt);
            if (verifier != null) c.BN_free(verifier);
            return SrpError.InitFailed;
        }

        // At this point, salt and verifier are allocated and must be freed or transferred

        // 5-9. Create and populate SRP_user_pwd structure
        // Use different code paths based on OpenSSL version
        if (comptime has_srp_user_pwd_api) {
            // ===== OpenSSL 3.0+ Modern API =====
            logging.logDebug("Using OpenSSL 3.0+ SRP_user_pwd API\n", .{});

            const user_pwd = c.SRP_user_pwd_new();
            if (user_pwd == null) {
                logging.logDebug("Failed to create SRP_user_pwd\n", .{});
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }

            // Set username and info (NULL for info)
            if (c.SRP_user_pwd_set1_ids(user_pwd, username, null) != 1) {
                logging.logDebug("Failed to set SRP username\n", .{});
                c.SRP_user_pwd_free(user_pwd);
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }

            // Transfer ownership of salt/verifier to user_pwd (zero-copy)
            if (c.SRP_user_pwd_set0_sv(user_pwd, salt, verifier) != 1) {
                logging.logDebug("Failed to set SRP salt/verifier\n", .{});
                c.SRP_user_pwd_free(user_pwd);
                return SrpError.InitFailed;
            }

            // Set group parameters (gN->g and gN->N are referenced, not copied)
            c.SRP_user_pwd_set_gN(user_pwd, gN.*.g, gN.*.N);

            // Add user to SRP_VBASE database (transfers ownership)
            if (c.SRP_VBASE_add0_user(srp_vbase, user_pwd) != 1) {
                logging.logDebug("Failed to add user to SRP database\n", .{});
                c.SRP_user_pwd_free(user_pwd);
                return SrpError.InitFailed;
            }
        } else {
            // ===== OpenSSL 1.1.1 Manual Population (Compatibility Path) =====
            logging.logDebug("Using OpenSSL 1.1.1 manual SRP_user_pwd population\n", .{});

            // Allocate SRP_user_pwd structure manually
            const user_pwd_mem = c.OPENSSL_malloc(@sizeOf(SRP_user_pwd_compat));
            if (user_pwd_mem == null) {
                logging.logDebug("Failed to allocate SRP_user_pwd\n", .{});
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }
            const user_pwd: *SRP_user_pwd_compat = @ptrCast(@alignCast(user_pwd_mem));

            // Duplicate username string (owned by user_pwd)
            const username_dup = c.OPENSSL_strdup(username);
            if (username_dup == null) {
                logging.logDebug("Failed to duplicate username\n", .{});
                c.OPENSSL_free(user_pwd_mem);
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }

            // Populate structure fields
            user_pwd.id = username_dup;
            user_pwd.s = salt;      // Transfer ownership
            user_pwd.v = verifier;  // Transfer ownership
            user_pwd.g = gN.*.g;    // Reference (not owned)
            user_pwd.N = gN.*.N;    // Reference (not owned)
            user_pwd.info = null;   // No additional info

            // Add to SRP_VBASE manually (OpenSSL 1.1.1 doesn't have SRP_VBASE_add0_user)
            // We need to access the internal users_pwd STACK and push our user_pwd
            // CRITICAL: This is internal API access - only for OpenSSL 1.1.1 compatibility
            const vbase_ptr: [*c]u8 = @ptrCast(srp_vbase);
            // SRP_VBASE layout: users_pwd is the first field (STACK_OF(SRP_user_pwd)*)
            const users_pwd_ptr: *?*anyopaque = @ptrCast(@alignCast(vbase_ptr));

            if (users_pwd_ptr.* == null) {
                logging.logDebug("SRP_VBASE->users_pwd is null, cannot add user\n", .{});
                c.OPENSSL_free(username_dup);
                c.OPENSSL_free(user_pwd_mem);
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }

            // Use sk_push to add user_pwd to the stack
            // Note: This is internal OpenSSL API but necessary for 1.1.1 compatibility
            const stack = users_pwd_ptr.*;
            const push_result = c.OPENSSL_sk_push(@ptrCast(stack), user_pwd_mem);
            if (push_result == 0) {
                logging.logDebug("Failed to push user_pwd to SRP_VBASE stack\n", .{});
                c.OPENSSL_free(username_dup);
                c.OPENSSL_free(user_pwd_mem);
                c.BN_free(salt);
                c.BN_free(verifier);
                return SrpError.InitFailed;
            }

            logging.logDebug("Successfully added user to SRP_VBASE (OpenSSL 1.1.1 compat path)\n", .{});
        }

        logging.logDebug("SRP_VBASE initialized successfully (username: user, 4096-bit group)\n", .{});
        return srp_vbase.?;
    }

    /// Create a server-side SRP connection and perform handshake
    ///
    /// **Parameters:**
    /// - allocator: Memory allocator
    /// - stream: Pre-established GSRN tunnel
    /// - secret: Shared secret for SRP password derivation
    /// - timeout_ms: Handshake timeout in milliseconds
    ///
    /// **Returns:**
    /// Heap-allocated SrpConnection in `.connected` state
    ///
    /// **Errors:**
    /// - error.HandshakeFailed: SRP handshake failed
    /// - error.SrpNotSupported: OpenSSL compiled without SRP support
    pub fn initServer(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        secret: []const u8,
        timeout_ms: u32,
    ) !*SrpConnection {
        const self = try allocator.create(SrpConnection);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .ssl_ctx = null,
            .ssl = null,
            .state = .initial,
            .is_client = false, // SERVER mode
            .srp_client_ctx = null,
            .srp_server_ctx = null,
        };

        // Ensure OpenSSL is initialized
        initOpenSsl();

        // SECURITY FIX: Validate secret length
        try validateSecret(secret);

        // Derive SRP password from secret
        const srp_password = gsocket.deriveSrpPassword(secret);

        // Create server context for SRP_VBASE storage
        const server_ctx = try allocator.create(SrpServerContext);
        errdefer allocator.destroy(server_ctx);
        server_ctx.* = .{
            .password = srp_password,
            .srp_vbase = null, // Will be initialized below
        };
        self.srp_server_ctx = server_ctx;

        // Create SSL context with TLS server method
        const method = c.TLS_server_method();
        if (method == null) {
            logging.logDebug("Failed to get TLS server method\n", .{});
            return SrpError.InitFailed;
        }

        self.ssl_ctx = c.SSL_CTX_new(method);
        if (self.ssl_ctx == null) {
            logging.logDebug("Failed to create SSL_CTX\n", .{});
            return SrpError.InitFailed;
        }
        errdefer c.SSL_CTX_free(self.ssl_ctx);

        const ctx = self.ssl_ctx.?;

        // Set SRP cipher suite (CRITICAL: Must match gsocket)
        const srp_cipher = "SRP-AES-256-CBC-SHA";
        if (c.SSL_CTX_set_cipher_list(ctx, srp_cipher) != 1) {
            logging.logDebug("Failed to set SRP cipher suite (OpenSSL may not support SRP)\n", .{});
            logOpenSslErrors();
            return SrpError.SrpNotSupported;
        }

        // SECURITY WARNING: SHA-1 MAC is deprecated (required for gs-netcat compatibility)
        logging.logDebug("WARNING: Using SRP-AES-256-CBC-SHA (SHA-1 MAC is deprecated, required for gs-netcat compatibility)\n", .{});

        // Initialize SRP_VBASE with derived password
        const srp_vbase = try setupSrpVbase(srp_password);
        errdefer c.SRP_VBASE_free(srp_vbase);
        server_ctx.srp_vbase = srp_vbase;

        // Register SRP username callback
        _ = c.SSL_CTX_set_srp_username_callback(ctx, srpServerUsernameCallback);

        // Pass SRP_VBASE to callback via arg
        _ = c.SSL_CTX_set_srp_cb_arg(ctx, srp_vbase);

        // Create SSL object
        self.ssl = c.SSL_new(ctx);
        if (self.ssl == null) {
            logging.logDebug("Failed to create SSL object\n", .{});
            return SrpError.InitFailed;
        }
        errdefer c.SSL_free(self.ssl);

        const ssl = self.ssl.?;

        // Attach socket to SSL
        const socket_fd = stream.handle;
        if (c.SSL_set_fd(ssl, socket_fd) != 1) {
            logging.logDebug("Failed to set SSL file descriptor\n", .{});
            return SrpError.InitFailed;
        }

        // Perform SRP handshake (uses SSL_accept for server)
        try self.doHandshake(timeout_ms);

        self.state = .connected;
        logging.logDebug("SRP server handshake complete\n", .{});

        return self;
    }

    /// Perform SRP handshake with retry logic for non-blocking sockets
    fn doHandshake(self: *SrpConnection, timeout_ms: u32) !void {
        const ssl = self.ssl orelse return SrpError.InvalidState;
        self.state = .handshake_in_progress;

        var handshake_complete = false;
        const start_time = std.time.milliTimestamp();

        while (!handshake_complete) {
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
                // Recalculate elapsed on each iteration (tolerate clock adjustments)
                const current_time = std.time.milliTimestamp();

                // Handle clock going backwards (defensive)
                if (current_time < start_time) {
                    logging.logDebug("System clock went backwards during SRP handshake\n", .{});
                    return SrpError.HandshakeFailed;
                }

                const elapsed = @as(u64, @intCast(current_time - start_time));

                // Check timeout BEFORE calculating remaining (prevents underflow)
                if (elapsed >= timeout_ms) {
                    logging.logDebug("SRP handshake timeout after {d}ms\n", .{elapsed});
                    return SrpError.HandshakeFailed;
                }

                // Safe remaining calculation (no underflow possible due to check above)
                const elapsed_u32 = @as(u32, @intCast(@min(elapsed, std.math.maxInt(u32))));
                const remaining: i32 = @intCast(timeout_ms - elapsed_u32);

                // Paranoid check (should never trigger after elapsed >= timeout_ms check)
                if (remaining <= 0) {
                    logging.logDebug("SRP handshake timeout (remaining <= 0)\n", .{});
                    return SrpError.HandshakeFailed;
                }

                // Wait for socket readiness with poll()
                const events: i16 = if (err == c.SSL_ERROR_WANT_READ) posix.POLL.IN else posix.POLL.OUT;

                var pollfds = [_]posix.pollfd{.{
                    .fd = self.stream.handle,
                    .events = events,
                    .revents = 0,
                }};

                const ready = try posix.poll(&pollfds, remaining);
                if (ready == 0) {
                    // Timeout
                    logging.logDebug("SRP handshake poll timeout\n", .{});
                    return SrpError.HandshakeFailed;
                }

                // Check for socket errors (including POLL.NVAL for redirected stdin)
                if (pollfds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) {
                    logging.logDebug("Socket error during SRP handshake\n", .{});
                    return SrpError.HandshakeFailed;
                }

                // Socket ready, retry handshake
                continue;
            } else {
                // Real error, not just blocking
                logging.logDebug("SRP handshake failed with error: {d}\n", .{err});
                logOpenSslErrors();
                return mapSslError(err);
            }
        }
    }

    /// Read decrypted data from SRP connection
    pub fn read(self: *SrpConnection, buffer: []u8) !usize {
        if (self.state != .connected) {
            return SrpError.InvalidState;
        }

        const ssl = self.ssl orelse return SrpError.InvalidState;
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
        return mapSslError(err);
    }

    /// Write data to SRP connection (will be encrypted before sending)
    pub fn write(self: *SrpConnection, data: []const u8) !usize {
        if (self.state != .connected) {
            return SrpError.InvalidState;
        }

        const ssl = self.ssl orelse return SrpError.InvalidState;
        const result = c.SSL_write(ssl, data.ptr, @intCast(data.len));

        if (result > 0) {
            return @intCast(result);
        }

        // Error occurred
        const err = c.SSL_get_error(ssl, result);
        return mapSslError(err);
    }

    /// Close SRP connection gracefully
    ///
    /// **Security Fix:** Performs bidirectional SSL shutdown
    /// - First call sends close_notify to peer
    /// - Second call waits for peer's close_notify (prevents session key leakage)
    /// - Errors ignored (best-effort, connection may already be broken)
    pub fn close(self: *SrpConnection) void {
        if (self.state == .connected) {
            if (self.ssl) |ssl| {
                // First SSL_shutdown sends close_notify
                const ret = c.SSL_shutdown(ssl);
                if (ret == 0) {
                    // Second call waits for peer's close_notify (non-blocking)
                    // Ignore return value (best-effort, connection may already be broken)
                    _ = c.SSL_shutdown(ssl);
                }
            }
            self.state = .closed;
        }
    }

    /// Get the underlying socket handle
    pub fn getSocket(self: *SrpConnection) posix.socket_t {
        return self.stream.handle;
    }

    /// Free all SRP resources
    ///
    /// **Memory Management:**
    /// - Frees SSL and SSL_CTX structures
    /// - Frees client context (if client mode)
    /// - Frees server context including SRP_VBASE (if server mode)
    /// - CRITICAL: SRP_VBASE_free() also frees all user_pwd structures added to it
    /// - SECURITY FIX: Now frees the SrpConnection structure itself
    ///
    /// **Parameters:**
    /// - allocator: Must be the same allocator used in initClient/initServer
    pub fn deinit(self: *SrpConnection, allocator: std.mem.Allocator) void {
        if (self.ssl) |ssl| {
            c.SSL_free(ssl);
            self.ssl = null;
        }

        if (self.ssl_ctx) |ctx| {
            c.SSL_CTX_free(ctx);
            self.ssl_ctx = null;
        }

        // Free client context if allocated
        if (self.srp_client_ctx) |client_ctx| {
            self.allocator.destroy(client_ctx);
            self.srp_client_ctx = null;
        }

        // Free server context if allocated
        if (self.srp_server_ctx) |server_ctx| {
            // Free SRP_VBASE (CRITICAL: This also frees all user_pwd structures)
            if (server_ctx.srp_vbase) |vbase| {
                c.SRP_VBASE_free(vbase);
                // Note: Do NOT free individual user_pwd structures - SRP_VBASE_free does it
            }
            self.allocator.destroy(server_ctx);
            self.srp_server_ctx = null;
        }

        // SECURITY FIX: Free the structure itself to prevent memory leak
        allocator.destroy(self);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Map OpenSSL error code to SrpError
fn mapSslError(ssl_error: c_int) SrpError {
    return switch (ssl_error) {
        c.SSL_ERROR_NONE => SrpError.InvalidState,
        c.SSL_ERROR_ZERO_RETURN => SrpError.InvalidState,
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => SrpError.WouldBlock,
        c.SSL_ERROR_SYSCALL => SrpError.SyscallError,
        c.SSL_ERROR_SSL => SrpError.ProtocolError,
        else => SrpError.SystemError,
    };
}

/// Log OpenSSL error queue (for debugging)
fn logOpenSslErrors() void {
    var err = c.ERR_get_error();
    while (err != 0) : (err = c.ERR_get_error()) {
        var buf: [256]u8 = undefined;
        c.ERR_error_string_n(err, &buf, buf.len);
        const err_str = std.mem.sliceTo(&buf, 0);
        logging.logDebug("  OpenSSL: {s}\n", .{err_str});
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "SrpConnection initialization" {
    // Basic compile-time test
    const conn = SrpConnection{
        .allocator = testing.allocator,
        .stream = undefined,
        .ssl_ctx = null,
        .ssl = null,
        .state = .initial,
        .is_client = true,
        .srp_client_ctx = null,
        .srp_server_ctx = null,
    };

    try testing.expectEqual(SrpConnection.ConnectionState.initial, conn.state);
    try testing.expect(conn.is_client);
}
