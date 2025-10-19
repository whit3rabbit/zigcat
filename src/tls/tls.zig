// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! TLS interface for secure network connections.
//!
//! Provides client and server TLS functionality with configuration validation.
//! Supports multiple TLS backends:
//! - **OpenSSL** (default): `-Dtls=true -Dtls-backend=openssl`
//! - **wolfSSL** (opt-in): `-Dtls=true -Dtls-backend=wolfssl`
//!
//! Backend is selected at build time via the `tls_backend` build option.

pub const TlsConnection = @import("tls_iface.zig").TlsConnection;
pub const TlsConfig = @import("tls_iface.zig").TlsConfig;
pub const TlsVersion = @import("tls_iface.zig").TlsVersion;
pub const TlsError = @import("tls_iface.zig").TlsError;

pub const validateTlsConfig = @import("tls_config.zig").validateTlsConfig;
pub const ValidationMode = @import("tls_config.zig").ValidationMode;
pub const ConfigError = @import("tls_config.zig").ConfigError;
pub const getSecureClientDefaults = @import("tls_config.zig").getSecureClientDefaults;
pub const getSecureServerDefaults = @import("tls_config.zig").getSecureServerDefaults;

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Conditional backend imports: Only import the backend that's actually enabled
// This prevents compiling unused TLS backends and their dependencies
const enable_tls = @hasDecl(build_options, "enable_tls") and build_options.enable_tls;
const use_wolfssl = enable_tls and @hasDecl(build_options, "use_wolfssl") and build_options.use_wolfssl;
pub const use_openssl = enable_tls and !use_wolfssl;
const OpenSslTls = if (enable_tls and !use_wolfssl) @import("tls_openssl.zig").OpenSslTls else void;
const WolfSslTls = if (enable_tls and use_wolfssl) @import("tls_wolfssl.zig").WolfSslTls else void;

const tls_config = @import("tls_config.zig");
const posix = std.posix;
const logging = @import("../util/logging.zig");

/// TLS backend selection type
pub const TlsBackend = enum {
    openssl,
    wolfssl,

    /// Get the active TLS backend from build options
    pub fn active() TlsBackend {
        // Default to openssl if use_wolfssl is not defined
        return if (@hasDecl(build_options, "use_wolfssl") and build_options.use_wolfssl)
            .wolfssl
        else
            .openssl;
    }
};

/// Create a TLS client connection wrapping an existing socket.
/// Validates configuration before attempting connection.
/// Returns error if TLS was disabled at build time.
pub fn connectTls(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    config: TlsConfig,
) !TlsConnection {
    if (!build_options.enable_tls) {
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .disabled = {} },
        };
    }

    comptime {
        if (!build_options.enable_tls) {
            @compileError(
                \\TLS support requires OpenSSL.
                \\
                \\To fix this:
                \\  1. Install OpenSSL: apt-get install libssl-dev (Debian/Ubuntu)
                \\                      brew install openssl (macOS)
                \\  2. Rebuild with: zig build
                \\
                \\Alternatively, disable TLS: zig build -Dtls=false
            );
        }
    }

    tls_config.validateTlsConfig(config, .client) catch |err| {
        displayTlsConfigError(err, "client");
        switch (err) {
            tls_config.ConfigError.TlsNotEnabled => return TlsError.TlsNotEnabled,
            tls_config.ConfigError.CertificateFileNotFound, tls_config.ConfigError.PrivateKeyFileNotFound, tls_config.ConfigError.TrustFileNotFound, tls_config.ConfigError.CrlFileNotFound => return TlsError.CertificateInvalid,
            tls_config.ConfigError.InvalidCertificateFormat, tls_config.ConfigError.InvalidPrivateKeyFormat, tls_config.ConfigError.CertificateKeyMismatch, tls_config.ConfigError.CertificateExpired, tls_config.ConfigError.CertificateNotYetValid => return TlsError.CertificateInvalid,
            tls_config.ConfigError.ServerNameRequired => return TlsError.HandshakeFailed,
            tls_config.ConfigError.InvalidTlsVersion => return TlsError.ProtocolVersionMismatch,
            tls_config.ConfigError.InsecureCipherSuite => return TlsError.InvalidCipherSuite,
            tls_config.ConfigError.ParameterTooLong => return TlsError.HandshakeFailed,
            tls_config.ConfigError.ServerConfigurationMissing => return TlsError.CertificateInvalid,
        }
    };

    // Select TLS backend at compile time to avoid linking unused libraries
    if (use_wolfssl) {
        const tls = try WolfSslTls.initClient(allocator, socket, config);
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .wolfssl = tls },
        };
    } else {
        const tls = try OpenSslTls.initClient(allocator, socket, config);
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .openssl = tls },
        };
    }
}

/// Create a TLS server connection for an accepted client socket.
/// Validates server configuration (cert_file and key_file required).
/// Returns error if TLS was disabled at build time.
pub fn acceptTls(
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    config: TlsConfig,
) !TlsConnection {
    if (!build_options.enable_tls) {
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .disabled = {} },
        };
    }

    comptime {
        if (!build_options.enable_tls) {
            @compileError(
                \\TLS support requires OpenSSL.
                \\
                \\To fix this:
                \\  1. Install OpenSSL: apt-get install libssl-dev (Debian/Ubuntu)
                \\                      brew install openssl (macOS)
                \\  2. Rebuild with: zig build
                \\
                \\Alternatively, disable TLS: zig build -Dtls=false
            );
        }
    }

    tls_config.validateTlsConfig(config, .server) catch |err| {
        displayTlsConfigError(err, "server");
        switch (err) {
            tls_config.ConfigError.TlsNotEnabled => return TlsError.TlsNotEnabled,
            tls_config.ConfigError.CertificateFileNotFound, tls_config.ConfigError.PrivateKeyFileNotFound, tls_config.ConfigError.TrustFileNotFound, tls_config.ConfigError.CrlFileNotFound => return TlsError.CertificateInvalid,
            tls_config.ConfigError.InvalidCertificateFormat, tls_config.ConfigError.InvalidPrivateKeyFormat, tls_config.ConfigError.CertificateKeyMismatch, tls_config.ConfigError.CertificateExpired, tls_config.ConfigError.CertificateNotYetValid => return TlsError.CertificateInvalid,
            tls_config.ConfigError.ServerNameRequired => return TlsError.HandshakeFailed,
            tls_config.ConfigError.InvalidTlsVersion => return TlsError.ProtocolVersionMismatch,
            tls_config.ConfigError.InsecureCipherSuite => return TlsError.InvalidCipherSuite,
            tls_config.ConfigError.ParameterTooLong => return TlsError.HandshakeFailed,
            tls_config.ConfigError.ServerConfigurationMissing => return TlsError.CertificateInvalid,
        }
    };

    // Select TLS backend at compile time to avoid linking unused libraries
    if (use_wolfssl) {
        const tls = try WolfSslTls.initServer(allocator, socket, config);
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .wolfssl = tls },
        };
    } else {
        const tls = try OpenSslTls.initServer(allocator, socket, config);
        return TlsConnection{
            .allocator = allocator,
            .backend = .{ .openssl = tls },
        };
    }
}

/// Check if TLS support is enabled at build time.
pub fn isTlsEnabled() bool {
    return build_options.enable_tls;
}

/// Display error message when TLS is requested but not available at build time.
pub fn displayTlsNotAvailableError() void {
    logging.log(0, "\n", .{});
    logging.log(0, "╔═══════════════════════════════════════════════════════════╗\n", .{});
    logging.log(0, "║  ⚠️  TLS/SSL SUPPORT NOT AVAILABLE                       ║\n", .{});
    logging.log(0, "║                                                           ║\n", .{});
    logging.log(0, "║  TLS support was disabled when this binary was built.    ║\n", .{});
    logging.log(0, "║  To use TLS/SSL features, rebuild with TLS enabled:      ║\n", .{});
    logging.log(0, "║                                                           ║\n", .{});
    logging.log(0, "║    zig build -Dtls=true                                   ║\n", .{});
    logging.log(0, "║                                                           ║\n", .{});
    logging.log(0, "║  Note: This requires OpenSSL development libraries.      ║\n", .{});
    logging.log(0, "║  See build documentation for installation instructions.  ║\n", .{});
    logging.log(0, "╚═══════════════════════════════════════════════════════════╝\n", .{});
    logging.log(0, "\n", .{});
}

/// Display error message for TLS configuration validation failures.
pub fn displayTlsConfigError(err: tls_config.ConfigError, context: []const u8) void {
    logging.log(0, "\n", .{});
    logging.log(0, "╔═══════════════════════════════════════════════════════════╗\n", .{});
    logging.log(0, "║  ⚠️  TLS CONFIGURATION ERROR                             ║\n", .{});
    logging.log(0, "║                                                           ║\n", .{});

    switch (err) {
        tls_config.ConfigError.CertificateFileNotFound => {
            logging.log(0, "║  Certificate file not found or not readable.             ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Check the certificate file path is correct            ║\n", .{});
            logging.log(0, "║  • Ensure the file exists and is readable                ║\n", .{});
            logging.log(0, "║  • Use absolute path if relative path fails              ║\n", .{});
        },
        tls_config.ConfigError.PrivateKeyFileNotFound => {
            logging.log(0, "║  Private key file not found or not readable.             ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Check the private key file path is correct            ║\n", .{});
            logging.log(0, "║  • Ensure the file exists and is readable                ║\n", .{});
            logging.log(0, "║  • Use absolute path if relative path fails              ║\n", .{});
        },
        tls_config.ConfigError.InvalidCertificateFormat => {
            logging.log(0, "║  Certificate file is not in valid PEM format.            ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Ensure certificate is in PEM format (not DER/P12)    ║\n", .{});
            logging.log(0, "║  • Check file contains -----BEGIN CERTIFICATE-----       ║\n", .{});
            logging.log(0, "║  • Convert from other formats: openssl x509 -inform ... ║\n", .{});
        },
        tls_config.ConfigError.InvalidPrivateKeyFormat => {
            logging.log(0, "║  Private key file is not in valid PEM format.            ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Ensure key is in PEM format (not DER/P12)             ║\n", .{});
            logging.log(0, "║  • Check file contains -----BEGIN PRIVATE KEY-----       ║\n", .{});
            logging.log(0, "║  • Convert from other formats: openssl rsa -inform ...   ║\n", .{});
        },
        tls_config.ConfigError.ServerConfigurationMissing => {
            logging.log(0, "║  Server mode requires both certificate and private key.  ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Provide --ssl-cert and --ssl-key options              ║\n", .{});
            logging.log(0, "║  • Generate self-signed cert: openssl req -x509 -newkey ║\n", .{});
            logging.log(0, "║    rsa:2048 -keyout key.pem -out cert.pem -days 365      ║\n", .{});
        },
        tls_config.ConfigError.ServerNameRequired => {
            logging.log(0, "║  Server name required for certificate verification.       ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Provide --ssl-servername option                       ║\n", .{});
            logging.log(0, "║  • Use --ssl-verify=false to disable verification        ║\n", .{});
            logging.log(0, "║    (NOT recommended for production)                      ║\n", .{});
        },
        tls_config.ConfigError.InvalidTlsVersion => {
            logging.log(0, "║  Invalid TLS version configuration.                       ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Solutions:                                               ║\n", .{});
            logging.log(0, "║  • Ensure min_version <= max_version                     ║\n", .{});
            logging.log(0, "║  • Use TLS 1.2 or higher for security                    ║\n", .{});
        },
        else => {
            logging.log(0, "║  TLS configuration validation failed.                     ║\n", .{});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Error: {any}                                 ║\n", .{err});
            logging.log(0, "║                                                           ║\n", .{});
            logging.log(0, "║  Check your TLS configuration and try again.             ║\n", .{});
        },
    }

    logging.log(0, "║                                                           ║\n", .{});
    logging.log(0, "║  Context: {s} mode                                    ║\n", .{context});
    logging.log(0, "╚═══════════════════════════════════════════════════════════╝\n", .{});
    logging.log(0, "\n", .{});
}
