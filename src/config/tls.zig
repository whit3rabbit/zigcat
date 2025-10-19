// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! TLS configuration validation.

const std = @import("std");
const logging = @import("../util/logging.zig");
const path_safety = @import("../util/path_safety.zig");

const config_struct = @import("config_struct.zig");
const Config = config_struct.Config;

/// Errors related to TLS transfer configuration validation.
pub const TLSConfigError = error{
    // TLS configuration errors
    TlsNotEnabled,
    InvalidTlsConfiguration,
    TlsCertificateRequired,
    TlsKeyRequired,
    TlsCertificateNotFound,
    TlsKeyNotFound,
    TlsCertificateInvalid,
    TlsKeyInvalid,
    TlsCertificateKeyMismatch,
    InsecureFlagRequired,

    // TLS feature conflicts
    ConflictingTlsAndUnixSocket,
    ConflictingTlsAndUdp,
    ConflictingTlsOptions,

    // TLS version and cipher errors
    UnsupportedTlsVersion,
    UnsupportedCipherSuite,
    IncompatibleTlsSettings,

    // TLS certificate validation errors
    InvalidCertificateChain,
    UntrustedCertificate,
    CertificateExpired,
    CertificateRevoked,
    PathTraversalDetected,
};

/// Comprehensive TLS configuration validation with detailed error detection.
pub fn validateTlsConfiguration(cfg: *const Config) TLSConfigError!void {
    if (!cfg.ssl) return;

    const tls = @import("../tls/tls.zig");
    if (!tls.isTlsEnabled()) {
        tls.displayTlsNotAvailableError();
        return TLSConfigError.TlsNotEnabled;
    }

    try validateTlsConflicts(cfg);
    try validateTlsCertificates(cfg);
    try validateTlsProtocolSettings(cfg);
}

/// Validate TLS configuration conflicts with other features.
fn validateTlsConflicts(cfg: *const Config) TLSConfigError!void {
    if (cfg.unix_socket_path != null) {
        return TLSConfigError.ConflictingTlsAndUnixSocket;
    }

    if (cfg.udp_mode) {
        return TLSConfigError.ConflictingTlsAndUdp;
    }

    // SECURITY: Require explicit --insecure flag to disable certificate verification
    if (!cfg.ssl_verify and !cfg.insecure) {
        std.debug.print("\n", .{});
        std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ⚠️  SECURITY ERROR: Insecure TLS Configuration          ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Certificate verification is disabled, but the           ║\n", .{});
        std.debug.print("║  --insecure flag was not explicitly provided.            ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Disabling certificate verification makes connections    ║\n", .{});
        std.debug.print("║  vulnerable to man-in-the-middle attacks.                ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Solutions:                                               ║\n", .{});
        std.debug.print("║  • Re-enable certificate verification (recommended)       ║\n", .{});
        std.debug.print("║  • Add --insecure to explicitly allow insecure TLS        ║\n", .{});
        std.debug.print("║                                                           ║\n", .{});
        std.debug.print("║  Example:                                                 ║\n", .{});
        std.debug.print("║    zigcat --ssl --insecure <host> <port>                  ║\n", .{});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        return TLSConfigError.InsecureFlagRequired;
    }

    if (cfg.ssl_verify and cfg.ssl_trustfile == null and cfg.ssl_cert == null) {
        if (!cfg.listen_mode) {
            // Allow TLS library to decide when system CA store is available.
        }
    }
}

/// Display user-friendly error messages for TLS configuration errors.
fn displayTlsConfigurationError(err: TLSConfigError, file_path: []const u8) void {
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  ⚠️  TLS CONFIGURATION ERROR                             ║\n", .{});
    std.debug.print("║                                                           ║\n", .{});

    switch (err) {
        TLSConfigError.TlsCertificateNotFound => {
            std.debug.print("║  Certificate file not found:                             ║\n", .{});
            std.debug.print("║  {s:<57} ║\n", .{file_path});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Solutions:                                               ║\n", .{});
            std.debug.print("║  • Check the file path is correct                        ║\n", .{});
            std.debug.print("║  • Use absolute path if relative path fails              ║\n", .{});
            std.debug.print("║  • Generate self-signed cert:                            ║\n", .{});
            std.debug.print("║    openssl req -x509 -newkey rsa:2048 -keyout key.pem    ║\n", .{});
            std.debug.print("║    -out cert.pem -days 365 -nodes                        ║\n", .{});
        },
        TLSConfigError.TlsKeyNotFound => {
            std.debug.print("║  Private key file not found:                             ║\n", .{});
            std.debug.print("║  {s:<57} ║\n", .{file_path});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Solutions:                                               ║\n", .{});
            std.debug.print("║  • Check the file path is correct                        ║\n", .{});
            std.debug.print("║  • Use absolute path if relative path fails              ║\n", .{});
            std.debug.print("║  • Ensure the key file matches the certificate           ║\n", .{});
        },
        TLSConfigError.TlsCertificateInvalid => {
            std.debug.print("║  Certificate file access denied:                         ║\n", .{});
            std.debug.print("║  {s:<57} ║\n", .{file_path});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Solutions:                                               ║\n", .{});
            std.debug.print("║  • Check file permissions (should be readable)           ║\n", .{});
            std.debug.print("║  • Run: chmod 644 {s:<35} ║\n", .{file_path});
        },
        TLSConfigError.TlsKeyInvalid => {
            std.debug.print("║  Private key file access denied:                         ║\n", .{});
            std.debug.print("║  {s:<57} ║\n", .{file_path});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Solutions:                                               ║\n", .{});
            std.debug.print("║  • Check file permissions (should be readable)           ║\n", .{});
            std.debug.print("║  • Run: chmod 600 {s:<35} ║\n", .{file_path});
            std.debug.print("║  • Ensure only owner can read private keys               ║\n", .{});
        },
        TLSConfigError.PathTraversalDetected => {
            std.debug.print("║  Unsafe TLS file path detected:                          ║\n", .{});
            std.debug.print("║  {s:<57} ║\n", .{file_path});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Solutions:                                               ║\n", .{});
            std.debug.print("║  • Remove any '../' components from the path             ║\n", .{});
            std.debug.print("║  • Use a path within the current working directory       ║\n", .{});
            std.debug.print("║  • Specify an absolute path you trust explicitly         ║\n", .{});
        },
        else => {
            std.debug.print("║  TLS configuration error: {any}                          ║\n", .{err});
            std.debug.print("║  File: {s:<50} ║\n", .{file_path});
        },
    }

    std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

/// Validate TLS certificate and key configuration.
fn validateTlsCertificates(cfg: *const Config) TLSConfigError!void {
    if (cfg.listen_mode) {
        // Certificate and key are now OPTIONAL in server mode
        // If not provided, a temporary certificate will be auto-generated (matches ncat behavior)
        // If one is provided, both must be provided
        if ((cfg.ssl_cert != null and cfg.ssl_key == null) or
            (cfg.ssl_cert == null and cfg.ssl_key != null))
        {
            std.debug.print("\n", .{});
            std.debug.print("╔═══════════════════════════════════════════════════════════╗\n", .{});
            std.debug.print("║  ⚠️  TLS CONFIGURATION ERROR                             ║\n", .{});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Both --ssl-cert and --ssl-key must be provided together.║\n", .{});
            std.debug.print("║                                                           ║\n", .{});
            std.debug.print("║  Options:                                                 ║\n", .{});
            std.debug.print("║  1. Provide both --ssl-cert and --ssl-key                ║\n", .{});
            std.debug.print("║  2. Omit both for automatic temporary certificate         ║\n", .{});
            std.debug.print("╚═══════════════════════════════════════════════════════════╝\n", .{});
            std.debug.print("\n", .{});
            if (cfg.ssl_cert == null) {
                return TLSConfigError.TlsCertificateRequired;
            } else {
                return TLSConfigError.TlsKeyRequired;
            }
        }

        if (cfg.ssl_cert) |cert_path| {
            ensureSafeTlsPath(cert_path) catch {
                displayTlsConfigurationError(TLSConfigError.PathTraversalDetected, cert_path);
                return TLSConfigError.PathTraversalDetected;
            };
            std.fs.cwd().access(cert_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    displayTlsConfigurationError(TLSConfigError.TlsCertificateNotFound, cert_path);
                    return TLSConfigError.TlsCertificateNotFound;
                },
                error.AccessDenied => {
                    displayTlsConfigurationError(TLSConfigError.TlsCertificateInvalid, cert_path);
                    return TLSConfigError.TlsCertificateInvalid;
                },
                else => return TLSConfigError.InvalidTlsConfiguration,
            };
        }

        if (cfg.ssl_key) |key_path| {
            ensureSafeTlsPath(key_path) catch {
                displayTlsConfigurationError(TLSConfigError.PathTraversalDetected, key_path);
                return TLSConfigError.PathTraversalDetected;
            };
            std.fs.cwd().access(key_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    displayTlsConfigurationError(TLSConfigError.TlsKeyNotFound, key_path);
                    return TLSConfigError.TlsKeyNotFound;
                },
                error.AccessDenied => {
                    displayTlsConfigurationError(TLSConfigError.TlsKeyInvalid, key_path);
                    return TLSConfigError.TlsKeyInvalid;
                },
                else => return TLSConfigError.InvalidTlsConfiguration,
            };
        }
    }

    if (cfg.ssl_trustfile) |trust_path| {
        ensureSafeTlsPath(trust_path) catch {
            displayTlsConfigurationError(TLSConfigError.PathTraversalDetected, trust_path);
            return TLSConfigError.PathTraversalDetected;
        };
        std.fs.cwd().access(trust_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return TLSConfigError.UntrustedCertificate,
            error.AccessDenied => return TLSConfigError.InvalidTlsConfiguration,
            else => return TLSConfigError.InvalidTlsConfiguration,
        };
    }

    if (cfg.ssl_crl) |crl_path| {
        ensureSafeTlsPath(crl_path) catch {
            displayTlsConfigurationError(TLSConfigError.PathTraversalDetected, crl_path);
            return TLSConfigError.PathTraversalDetected;
        };
    }
}

/// Validate TLS protocol version and cipher suite settings.
fn validateTlsProtocolSettings(cfg: *const Config) TLSConfigError!void {
    if (cfg.ssl_ciphers) |ciphers| {
        if (ciphers.len == 0) {
            return TLSConfigError.UnsupportedCipherSuite;
        }
    }

    if (cfg.ssl_alpn) |alpn| {
        if (alpn.len == 0) {
            return TLSConfigError.IncompatibleTlsSettings;
        }
    }

    if (!cfg.listen_mode and cfg.ssl_servername != null) {
        if (cfg.ssl_servername.?.len == 0) {
            return TLSConfigError.InvalidTlsConfiguration;
        }
    }
}

fn ensureSafeTlsPath(path: []const u8) TLSConfigError!void {
    if (!path_safety.isSafePath(path)) {
        return TLSConfigError.PathTraversalDetected;
    }
}

test "validateTlsConfiguration no-op when TLS disabled" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.ssl = false;
    try validateTlsConfiguration(&cfg);
}

test "validateTlsProtocolSettings detects invalid inputs" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.ssl = true;
    cfg.ssl_ciphers = "";
    try testing.expectError(TLSConfigError.UnsupportedCipherSuite, validateTlsProtocolSettings(&cfg));
}
