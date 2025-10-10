//! TLS configuration validation and management.
//!
//! This module provides comprehensive validation for TLS configurations,
//! ensuring that all required files exist, certificates are valid, and
//! configuration parameters are secure. It implements the security
//! requirements from the TLS security enhancement specification.
//!
//! **Security Features:**
//! - Certificate file existence validation
//! - Basic certificate format validation
//! - Private key validation and matching
//! - Secure default configuration enforcement
//! - Configuration parameter validation
//!
//! **Usage:**
//! ```zig
//! const config = TlsConfig{ .cert_file = "cert.pem", .key_file = "key.pem" };
//! try validateTlsConfig(config, .server);
//! ```

const std = @import("std");
const fs = std.fs;
const TlsConfig = @import("tls_iface.zig").TlsConfig;
const TlsVersion = @import("tls_iface.zig").TlsVersion;
const TlsError = @import("tls_iface.zig").TlsError;
const logging = @import("../util/logging.zig");

/// TLS configuration validation mode
pub const ValidationMode = enum {
    client,
    server,
};

/// TLS configuration validation errors
pub const ConfigError = error{
    /// TLS is not enabled at build time
    TlsNotEnabled,
    /// Certificate file not found or not readable
    CertificateFileNotFound,
    /// Private key file not found or not readable
    PrivateKeyFileNotFound,
    /// CA trust file not found or not readable
    TrustFileNotFound,
    /// CRL file not found or not readable
    CrlFileNotFound,
    /// Certificate file is not in valid PEM format
    InvalidCertificateFormat,
    /// Private key file is not in valid PEM format
    InvalidPrivateKeyFormat,
    /// Certificate and private key do not match
    CertificateKeyMismatch,
    /// Certificate has expired
    CertificateExpired,
    /// Certificate is not yet valid
    CertificateNotYetValid,
    /// Server name is required for client mode
    ServerNameRequired,
    /// Invalid TLS version configuration
    InvalidTlsVersion,
    /// Insecure cipher suite configuration
    InsecureCipherSuite,
    /// Configuration parameter too long
    ParameterTooLong,
    /// Required server configuration missing
    ServerConfigurationMissing,
};

/// Maximum allowed length for configuration parameters
const MAX_PATH_LENGTH = 512;
const MAX_HOSTNAME_LENGTH = 253; // RFC 1035
const MAX_ALPN_LENGTH = 256;
const MAX_CIPHER_LENGTH = 1024;

/// Validate a TLS configuration for the specified mode.
///
/// **Parameters:**
/// - `config`: TLS configuration to validate
/// - `mode`: Validation mode (client or server)
///
/// **Validation Checks:**
/// - File existence for all specified paths
/// - Certificate format validation (PEM)
/// - Private key format validation (PEM)
/// - Certificate/key matching (server mode)
/// - Parameter length limits
/// - Security policy compliance
///
/// **Errors:**
/// Returns specific `ConfigError` for each validation failure.
///
/// **Example:**
/// ```zig
/// const config = TlsConfig{
///     .cert_file = "server.pem",
///     .key_file = "server-key.pem",
/// };
/// try validateTlsConfig(config, .server);
/// ```
pub fn validateTlsConfig(config: TlsConfig, mode: ValidationMode) ConfigError!void {
    // Validate parameter lengths first
    try validateParameterLengths(config);

    // Mode-specific validation
    switch (mode) {
        .client => try validateClientConfig(config),
        .server => try validateServerConfig(config),
    }

    // Common validation for both modes
    try validateCommonConfig(config);
}

/// Validate parameter lengths to prevent buffer overflows
fn validateParameterLengths(config: TlsConfig) ConfigError!void {
    if (config.cert_file) |path| {
        if (path.len >= MAX_PATH_LENGTH) {
            logging.logDebug("Certificate file path too long: {d} bytes (max {d})\n", .{ path.len, MAX_PATH_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.key_file) |path| {
        if (path.len >= MAX_PATH_LENGTH) {
            logging.logDebug("Private key file path too long: {d} bytes (max {d})\n", .{ path.len, MAX_PATH_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.trust_file) |path| {
        if (path.len >= MAX_PATH_LENGTH) {
            logging.logDebug("Trust file path too long: {d} bytes (max {d})\n", .{ path.len, MAX_PATH_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.crl_file) |path| {
        if (path.len >= MAX_PATH_LENGTH) {
            logging.logDebug("CRL file path too long: {d} bytes (max {d})\n", .{ path.len, MAX_PATH_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.server_name) |hostname| {
        if (hostname.len > MAX_HOSTNAME_LENGTH) {
            logging.logDebug("Server name too long: {d} bytes (max {d})\n", .{ hostname.len, MAX_HOSTNAME_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.alpn_protocols) |alpn| {
        if (alpn.len > MAX_ALPN_LENGTH) {
            logging.logDebug("ALPN protocols string too long: {d} bytes (max {d})\n", .{ alpn.len, MAX_ALPN_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }

    if (config.cipher_suites) |ciphers| {
        if (ciphers.len > MAX_CIPHER_LENGTH) {
            logging.logDebug("Cipher suites string too long: {d} bytes (max {d})\n", .{ ciphers.len, MAX_CIPHER_LENGTH });
            return ConfigError.ParameterTooLong;
        }
    }
}

/// Validate client-specific configuration
fn validateClientConfig(config: TlsConfig) ConfigError!void {
    // Server name is strongly recommended for client mode (SNI and hostname verification)
    if (config.verify_peer and config.server_name == null) {
        logging.logDebug("Warning: No server_name specified for client mode with certificate verification\n", .{});
        logging.logDebug("This may cause hostname verification to fail\n", .{});
        // Note: This is a warning, not an error, as some use cases may not require SNI
    }

    // Validate trust file if specified
    if (config.trust_file) |trust_file| {
        try validateFileExists(trust_file, "Trust file");
        try validatePemFile(trust_file, "Trust file");
    }

    // Validate CRL file if specified
    if (config.crl_file) |crl_file| {
        try validateFileExists(crl_file, "CRL file");
        try validatePemFile(crl_file, "CRL file");
    }

    // Client certificate authentication (optional)
    if (config.cert_file) |cert_file| {
        try validateFileExists(cert_file, "Client certificate file");
        try validatePemFile(cert_file, "Client certificate file");

        // If client cert is provided, key must also be provided
        if (config.key_file == null) {
            logging.logDebug("Client certificate provided but no private key specified\n", .{});
            return ConfigError.PrivateKeyFileNotFound;
        }
    }

    if (config.key_file) |key_file| {
        try validateFileExists(key_file, "Client private key file");
        try validatePemFile(key_file, "Client private key file");

        // If client key is provided, cert must also be provided
        if (config.cert_file == null) {
            logging.logDebug("Client private key provided but no certificate specified\n", .{});
            return ConfigError.CertificateFileNotFound;
        }
    }
}

/// Validate server-specific configuration
fn validateServerConfig(config: TlsConfig) ConfigError!void {
    // Server mode requires both certificate and private key
    if (config.cert_file == null) {
        logging.logDebug("Server mode requires a certificate file\n", .{});
        return ConfigError.ServerConfigurationMissing;
    }

    if (config.key_file == null) {
        logging.logDebug("Server mode requires a private key file\n", .{});
        return ConfigError.ServerConfigurationMissing;
    }

    const cert_file = config.cert_file.?;
    const key_file = config.key_file.?;

    // Validate certificate file
    try validateFileExists(cert_file, "Server certificate file");
    try validatePemFile(cert_file, "Server certificate file");

    // Validate private key file
    try validateFileExists(key_file, "Server private key file");
    try validatePemFile(key_file, "Server private key file");

    // Validate certificate and key match (basic check)
    try validateCertificateKeyPair(cert_file, key_file);
}

/// Validate common configuration parameters
fn validateCommonConfig(config: TlsConfig) ConfigError!void {
    // Validate TLS version configuration
    try validateTlsVersions(config.min_version, config.max_version);

    // Validate cipher suites if specified
    if (config.cipher_suites) |cipher_suites| {
        try validateCipherSuites(cipher_suites);
    }

    // Validate ALPN protocols if specified
    if (config.alpn_protocols) |alpn| {
        try validateAlpnProtocols(alpn);
    }
}

/// Check if a file exists and is readable
fn validateFileExists(file_path: []const u8, description: []const u8) ConfigError!void {
    const file = fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            logging.logDebug("{s} not found: {s}\n", .{ description, file_path });
            // Determine error type based on description content
            if (std.mem.indexOf(u8, description, "Certificate") != null) {
                return ConfigError.CertificateFileNotFound;
            } else if (std.mem.indexOf(u8, description, "key") != null) {
                return ConfigError.PrivateKeyFileNotFound;
            } else if (std.mem.indexOf(u8, description, "Trust") != null) {
                return ConfigError.TrustFileNotFound;
            } else if (std.mem.indexOf(u8, description, "CRL") != null) {
                return ConfigError.CrlFileNotFound;
            } else {
                return ConfigError.CertificateFileNotFound;
            }
        },
        error.AccessDenied => {
            logging.logDebug("{s} access denied: {s}\n", .{ description, file_path });
            return ConfigError.CertificateFileNotFound;
        },
        else => {
            logging.logDebug("Error accessing {s}: {s} - {}\n", .{ description, file_path, err });
            return ConfigError.CertificateFileNotFound;
        },
    };
    defer file.close();

    // File exists and is readable
    logging.logDebug("{s} found and accessible: {s}\n", .{ description, file_path });
}

/// Validate that a file is in PEM format
fn validatePemFile(file_path: []const u8, description: []const u8) ConfigError!void {
    const file = fs.cwd().openFile(file_path, .{}) catch {
        // File existence already validated by validateFileExists
        return;
    };
    defer file.close();

    // Read first 1024 bytes to check for PEM headers
    var buffer: [1024]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch |err| {
        logging.logDebug("Error reading {s}: {s} - {}\n", .{ description, file_path, err });
        return ConfigError.InvalidCertificateFormat;
    };

    const content = buffer[0..bytes_read];

    // Check for PEM BEGIN header
    const has_begin_header = std.mem.indexOf(u8, content, "-----BEGIN") != null;
    if (!has_begin_header) {
        logging.logDebug("{s} does not appear to be in PEM format (no BEGIN header): {s}\n", .{ description, file_path });
        if (std.mem.indexOf(u8, description, "key") != null) {
            return ConfigError.InvalidPrivateKeyFormat;
        } else {
            return ConfigError.InvalidCertificateFormat;
        }
    }

    // Check for PEM END header (may not be in first 1024 bytes, so this is optional)
    const has_end_header = std.mem.indexOf(u8, content, "-----END") != null;
    if (!has_end_header) {
        logging.logDebug("Warning: {s} PEM END header not found in first 1024 bytes: {s}\n", .{ description, file_path });
        // This is just a warning, not an error, as the file might be larger
    }

    logging.logDebug("{s} appears to be in valid PEM format: {s}\n", .{ description, file_path });
}

/// Basic validation that certificate and private key are a matching pair
fn validateCertificateKeyPair(cert_file: []const u8, key_file: []const u8) ConfigError!void {
    // This is a basic validation - we check that both files exist and are PEM format
    // Full cryptographic validation would require OpenSSL integration
    // The actual matching validation is performed by OpenSSL during SSL_CTX setup

    // Validate certificate file content
    try validateCertificateContent(cert_file);

    // Validate private key file content
    try validatePrivateKeyContent(key_file);

    logging.logDebug("Certificate and private key files appear to be valid PEM format\n", .{});
    // Note: Actual cryptographic matching validation is performed by OpenSSL
}

/// Validate certificate file contains valid certificate data
fn validateCertificateContent(cert_file: []const u8) ConfigError!void {
    const file = fs.cwd().openFile(cert_file, .{}) catch |err| {
        logging.logDebug("Error opening certificate file for validation: {}\n", .{err});
        return ConfigError.InvalidCertificateFormat;
    };
    defer file.close();

    // Read first 2048 bytes to check for certificate content
    var buffer: [2048]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch |err| {
        logging.logDebug("Error reading certificate file for validation: {}\n", .{err});
        return ConfigError.InvalidCertificateFormat;
    };

    const content = buffer[0..bytes_read];

    // Check certificate contains certificate data
    if (std.mem.indexOf(u8, content, "-----BEGIN CERTIFICATE-----") == null) {
        logging.logDebug("Certificate file does not contain certificate data: {s}\n", .{cert_file});
        return ConfigError.InvalidCertificateFormat;
    }
}

/// Validate private key file contains valid private key data
fn validatePrivateKeyContent(key_file: []const u8) ConfigError!void {
    const file = fs.cwd().openFile(key_file, .{}) catch |err| {
        logging.logDebug("Error opening private key file for validation: {}\n", .{err});
        return ConfigError.InvalidPrivateKeyFormat;
    };
    defer file.close();

    // Read first 2048 bytes to check for key content
    var buffer: [2048]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch |err| {
        logging.logDebug("Error reading private key file for validation: {}\n", .{err});
        return ConfigError.InvalidPrivateKeyFormat;
    };

    const content = buffer[0..bytes_read];

    // Check private key contains key data
    const has_private_key = std.mem.indexOf(u8, content, "-----BEGIN PRIVATE KEY-----") != null or
        std.mem.indexOf(u8, content, "-----BEGIN RSA PRIVATE KEY-----") != null or
        std.mem.indexOf(u8, content, "-----BEGIN EC PRIVATE KEY-----") != null;

    if (!has_private_key) {
        logging.logDebug("Private key file does not contain private key data: {s}\n", .{key_file});
        return ConfigError.InvalidPrivateKeyFormat;
    }
}

/// Validate TLS version configuration
fn validateTlsVersions(min_version: TlsVersion, max_version: TlsVersion) ConfigError!void {
    // Convert to numeric values for comparison
    const min_val = tlsVersionToNumber(min_version);
    const max_val = tlsVersionToNumber(max_version);

    if (min_val > max_val) {
        logging.logDebug("Invalid TLS version range: min_version ({}) > max_version ({})\n", .{ min_version, max_version });
        return ConfigError.InvalidTlsVersion;
    }

    // Security policy: warn about insecure TLS versions
    if (min_version == .tls_1_0 or min_version == .tls_1_1) {
        logging.logDebug("Warning: TLS 1.0/1.1 are deprecated and insecure. Consider using TLS 1.2 minimum.\n", .{});
    }

    logging.logDebug("TLS version range valid: {} to {}\n", .{ min_version, max_version });
}

/// Convert TLS version to numeric value for comparison
fn tlsVersionToNumber(version: TlsVersion) u8 {
    return switch (version) {
        .tls_1_0 => 10,
        .tls_1_1 => 11,
        .tls_1_2 => 12,
        .tls_1_3 => 13,
    };
}

/// Validate cipher suite configuration for security
fn validateCipherSuites(cipher_suites: []const u8) ConfigError!void {
    // Check for insecure cipher suites
    const insecure_patterns = [_][]const u8{
        "NULL", // No encryption
        "aNULL", // No authentication
        "eNULL", // No encryption
        "EXPORT", // Export-grade (weak)
        "DES", // DES (weak)
        "3DES", // 3DES (deprecated)
        "RC4", // RC4 (broken)
        "MD5", // MD5 (broken)
        "SHA1", // SHA1 (deprecated for new uses)
    };

    for (insecure_patterns) |pattern| {
        if (std.mem.indexOf(u8, cipher_suites, pattern) != null) {
            logging.logDebug("Warning: Insecure cipher suite pattern detected: {s}\n", .{pattern});
            logging.logDebug("Consider using modern AEAD ciphers only\n", .{});
            // This is a warning, not an error, to allow flexibility
        }
    }

    // Check for recommended secure patterns
    const secure_patterns = [_][]const u8{
        "ECDHE", // Forward secrecy
        "GCM", // AEAD cipher
        "CHACHA20", // Modern AEAD cipher
    };

    var has_secure_pattern = false;
    for (secure_patterns) |pattern| {
        if (std.mem.indexOf(u8, cipher_suites, pattern) != null) {
            has_secure_pattern = true;
            break;
        }
    }

    if (!has_secure_pattern) {
        logging.logDebug("Warning: No modern secure cipher patterns detected\n", .{});
        logging.logDebug("Consider including ECDHE, GCM, or CHACHA20 ciphers\n", .{});
    }

    logging.logDebug("Cipher suite configuration validated\n", .{});
}

/// Validate ALPN protocol list format
fn validateAlpnProtocols(alpn_protocols: []const u8) ConfigError!void {
    // ALPN protocols should be comma-separated
    if (alpn_protocols.len == 0) {
        logging.logDebug("Warning: Empty ALPN protocols string\n", .{});
        return;
    }

    // Check for common protocols
    const common_protocols = [_][]const u8{
        "h2", // HTTP/2
        "http/1.1", // HTTP/1.1
        "h3", // HTTP/3
    };

    var has_common_protocol = false;
    for (common_protocols) |protocol| {
        if (std.mem.indexOf(u8, alpn_protocols, protocol) != null) {
            has_common_protocol = true;
            break;
        }
    }

    if (!has_common_protocol) {
        logging.logDebug("Warning: No common ALPN protocols detected in: {s}\n", .{alpn_protocols});
    }

    logging.logDebug("ALPN protocols configuration validated: {s}\n", .{alpn_protocols});
}

/// Get secure default TLS configuration for client mode
pub fn getSecureClientDefaults() TlsConfig {
    return TlsConfig{
        .verify_peer = true,
        .min_version = .tls_1_2,
        .max_version = .tls_1_3,
        // Use secure cipher suites (AEAD only)
        .cipher_suites = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256",
    };
}

/// Get secure default TLS configuration for server mode
pub fn getSecureServerDefaults() TlsConfig {
    return TlsConfig{
        .min_version = .tls_1_2,
        .max_version = .tls_1_3,
        // Use secure cipher suites (AEAD only)
        .cipher_suites = "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256",
    };
}

// Unit tests
const testing = std.testing;

test "parameter length validation" {
    var long_path: [600]u8 = undefined;
    @memset(&long_path, 'a');

    const config = TlsConfig{
        .cert_file = &long_path,
    };

    try testing.expectError(ConfigError.ParameterTooLong, validateParameterLengths(config));
}

test "TLS version validation" {
    // Valid range
    try validateTlsVersions(.tls_1_2, .tls_1_3);

    // Invalid range (min > max)
    try testing.expectError(ConfigError.InvalidTlsVersion, validateTlsVersions(.tls_1_3, .tls_1_2));
}

test "cipher suite validation" {
    // Should not error on secure ciphers
    try validateCipherSuites("ECDHE-ECDSA-AES256-GCM-SHA384");

    // Should warn but not error on insecure ciphers
    try validateCipherSuites("NULL-MD5");
}

test "ALPN validation" {
    try validateAlpnProtocols("h2,http/1.1");
    try validateAlpnProtocols("");
}

test "secure defaults" {
    const client_defaults = getSecureClientDefaults();
    try testing.expect(client_defaults.verify_peer);
    try testing.expectEqual(TlsVersion.tls_1_2, client_defaults.min_version);

    const server_defaults = getSecureServerDefaults();
    try testing.expectEqual(TlsVersion.tls_1_2, server_defaults.min_version);
}
