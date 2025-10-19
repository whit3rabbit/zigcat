// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Temporary SSL/TLS certificate generation.
//!
//! This module provides automatic generation of temporary self-signed
//! certificates for SSL/TLS server mode when explicit certificates are
//! not provided. This matches ncat's behavior of generating a temporary
//! 2048-bit RSA certificate on-the-fly.
//!
//! **Security Notes:**
//! - Temporary certificates are NOT TRUSTED by clients
//! - Clients must use --insecure flag to accept self-signed certificates
//! - For production use, provide explicit certificates via --ssl-cert/--ssl-key
//!
//! **Usage:**
//! ```zig
//! var cert = try generateTemporaryCertificate(allocator, "modern");
//! defer cert.deinit(allocator);
//!
//! // Use cert.cert_pem and cert.key_pem with SSL_CTX
//! ```

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../util/logging.zig");

// OpenSSL/wolfSSL detection
const tls = @import("tls.zig");
const enable_tls = @import("build_options").enable_tls;
const use_wolfssl = enable_tls and @hasDecl(@import("build_options"), "use_wolfssl") and @import("build_options").use_wolfssl;
const use_openssl = enable_tls and !use_wolfssl;

// OpenSSL version detection for API compatibility
// EVP_RSA_gen() and EVP_EC_gen() were added in OpenSSL 3.0
// OpenSSL 1.1.1 requires EVP_PKEY_CTX-based key generation
const OPENSSL_VERSION_3_0_0: c_long = 0x30000000;

// Conditional imports based on TLS backend
const c = if (use_openssl)
    @cImport({
        @cInclude("openssl/rsa.h");
        @cInclude("openssl/evp.h");
        @cInclude("openssl/x509.h");
        @cInclude("openssl/x509v3.h");
        @cInclude("openssl/pem.h");
        @cInclude("openssl/bn.h");
        @cInclude("openssl/bio.h");
        @cInclude("openssl/err.h");
        @cInclude("openssl/ec.h");  // EC_KEY for OpenSSL 1.1.1 ECDSA generation
    })
else if (use_wolfssl)
    @cImport({
        @cInclude("wolfssl/options.h");
        @cInclude("wolfssl/ssl.h");
        @cInclude("wolfssl/wolfcrypt/asn.h");
        @cInclude("wolfssl/wolfcrypt/asn_public.h");
        @cInclude("wolfssl/wolfcrypt/coding.h");
    })
else
    struct {};

/// Errors that can occur during temporary certificate generation.
pub const TempCertError = error{
    /// TLS support not compiled in
    TlsNotAvailable,
    /// Failed to generate RSA key
    RsaKeyGenerationFailed,
    /// Failed to generate ECDSA key
    EcdsaKeyGenerationFailed,
    /// Failed to create X.509 certificate
    CertificateCreationFailed,
    /// Failed to sign certificate
    CertificateSigningFailed,
    /// Failed to encode certificate to PEM
    PemEncodingFailed,
    /// Failed to allocate memory
    OutOfMemory,
    /// Unsupported cipher profile
    UnsupportedProfile,
};

/// Temporary certificate container with PEM-encoded certificate and private key.
pub const TemporaryCertificate = struct {
    /// PEM-encoded certificate (null-terminated for C interop)
    cert_pem: []u8,
    /// PEM-encoded private key (null-terminated for C interop)
    key_pem: []u8,

    /// Free allocated memory.
    pub fn deinit(self: *TemporaryCertificate, allocator: std.mem.Allocator) void {
        allocator.free(self.cert_pem);
        allocator.free(self.key_pem);
    }
};

/// Generate a temporary self-signed certificate based on cipher suite profile.
///
/// **Parameters:**
/// - `allocator`: Memory allocator for PEM buffers
/// - `profile`: Cipher suite profile ("modern", "intermediate", "compatible")
///
/// **Returns:**
/// - `TemporaryCertificate` with PEM-encoded cert and key
///
/// **Profiles:**
/// - "modern": ECDSA P-256 certificate (for ECDHE-ECDSA cipher suites)
/// - "intermediate": RSA 2048-bit certificate (broader compatibility)
/// - "compatible": RSA 2048-bit certificate (maximum compatibility)
///
/// **Security:**
/// - Certificates are valid for 365 days
/// - Subject: CN=localhost
/// - Self-signed (issuer == subject)
/// - Serial number: random 64-bit value
///
/// **Example:**
/// ```zig
/// var cert = try generateTemporaryCertificate(allocator, "modern");
/// defer cert.deinit(allocator);
/// logging.logVerbose(cfg, "Generated temporary certificate\n", .{});
/// ```
pub fn generateTemporaryCertificate(
    allocator: std.mem.Allocator,
    profile: []const u8,
) TempCertError!TemporaryCertificate {
    // Check TLS availability
    if (!tls.isTlsEnabled()) {
        return TempCertError.TlsNotAvailable;
    }

    // Determine certificate type based on profile
    if (std.mem.eql(u8, profile, "modern")) {
        // Modern profile: Try ECDSA P-256, fallback to RSA 2048
        return generateEcdsaP256Certificate(allocator) catch |err| {
            logging.logDebug("ECDSA certificate generation failed ({any}), falling back to RSA 2048\n", .{err});
            return generateRsa2048Certificate(allocator);
        };
    } else if (std.mem.eql(u8, profile, "intermediate") or std.mem.eql(u8, profile, "compatible")) {
        // Intermediate/compatible profiles: RSA 2048 for broader compatibility
        return generateRsa2048Certificate(allocator);
    } else {
        logging.logDebug("Unsupported cipher profile: {s}\n", .{profile});
        return TempCertError.UnsupportedProfile;
    }
}

/// Generate a temporary RSA 2048-bit self-signed certificate.
///
/// This matches ncat's behavior of generating a 2048-bit RSA key on-the-fly.
/// Compatible with all TLS 1.2/1.3 clients supporting RSA certificates.
///
/// **OpenSSL Implementation:**
/// - Uses EVP_RSA_gen(2048) for key generation (OpenSSL 3.x)
/// - Falls back to RSA_generate_key_ex() for OpenSSL 1.1.x
/// - X.509v3 certificate with 365-day validity
/// - SHA-256 signature
fn generateRsa2048Certificate(allocator: std.mem.Allocator) TempCertError!TemporaryCertificate {
    if (!use_openssl and !use_wolfssl) {
        return TempCertError.TlsNotAvailable;
    }

    if (use_openssl) {
        return generateRsa2048CertificateOpenssl(allocator);
    } else {
        return generateRsa2048CertificateWolfssl(allocator);
    }
}

/// Generate RSA 2048-bit certificate using OpenSSL.
fn generateRsa2048CertificateOpenssl(allocator: std.mem.Allocator) TempCertError!TemporaryCertificate {
    if (!use_openssl) {
        return TempCertError.TlsNotAvailable;
    }

    logging.logDebug("Generating temporary 2048-bit RSA key. Use --ssl-cert and --ssl-key for permanent certificates.\n", .{});

    // 1. Generate RSA 2048-bit private key
    // Use different code paths based on OpenSSL version
    const pkey = if (comptime c.OPENSSL_VERSION_NUMBER >= OPENSSL_VERSION_3_0_0) blk: {
        // OpenSSL 3.0+: Use EVP_PKEY_Q_keygen() wrapper (simpler than EVP_RSA_gen)
        logging.logDebug("Using OpenSSL 3.0+ EVP_PKEY_Q_keygen API for RSA\n", .{});
        break :blk c.EVP_PKEY_Q_keygen(null, null, "RSA", @as(c_uint, 2048));
    } else blk: {
        // OpenSSL 1.1.1: Use EVP_PKEY_CTX-based key generation
        logging.logDebug("Using OpenSSL 1.1.1 EVP_PKEY_CTX API for RSA\n", .{});

        const ctx = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_RSA, null);
        if (ctx == null) {
            logging.logDebug("Failed to create EVP_PKEY_CTX for RSA\n", .{});
            break :blk null;
        }
        defer c.EVP_PKEY_CTX_free(ctx);

        if (c.EVP_PKEY_keygen_init(ctx) <= 0) {
            logging.logDebug("Failed to initialize RSA key generation\n", .{});
            break :blk null;
        }

        if (c.EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) <= 0) {
            logging.logDebug("Failed to set RSA key size to 2048 bits\n", .{});
            break :blk null;
        }

        var pkey_ptr: ?*c.EVP_PKEY = null;
        if (c.EVP_PKEY_keygen(ctx, &pkey_ptr) <= 0) {
            logging.logDebug("Failed to generate RSA key\n", .{});
            break :blk null;
        }

        break :blk pkey_ptr;
    };

    if (pkey == null) {
        logging.logDebug("Failed to generate RSA key\n", .{});
        return TempCertError.RsaKeyGenerationFailed;
    }
    defer c.EVP_PKEY_free(pkey);

    // 2. Create X.509 certificate
    const x509 = c.X509_new();
    if (x509 == null) {
        logging.logDebug("Failed to create X.509 certificate\n", .{});
        return TempCertError.CertificateCreationFailed;
    }
    defer c.X509_free(x509);

    // 3. Set certificate version (X.509v3 = 2)
    _ = c.X509_set_version(x509, 2);

    // 4. Set serial number (random 64-bit value)
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = prng.random();
    const serial = random.int(u64);
    const asn1_serial = c.X509_get_serialNumber(x509);
    _ = c.ASN1_INTEGER_set(asn1_serial, @intCast(serial));

    // 5. Set validity period (365 days)
    _ = c.X509_gmtime_adj(c.X509_get_notBefore(x509), 0); // Valid from now
    _ = c.X509_gmtime_adj(c.X509_get_notAfter(x509), 365 * 24 * 60 * 60); // Valid for 1 year

    // 6. Set public key
    _ = c.X509_set_pubkey(x509, pkey);

    // 7. Set subject name (CN=localhost)
    const name = c.X509_get_subject_name(x509);
    _ = c.X509_NAME_add_entry_by_txt(
        name,
        "CN",
        c.MBSTRING_ASC,
        "localhost",
        -1,
        -1,
        0,
    );

    // 8. Set issuer name (self-signed, so issuer == subject)
    _ = c.X509_set_issuer_name(x509, name);

    // 9. Sign the certificate with SHA-256
    _ = c.X509_sign(x509, pkey, c.EVP_sha256());

    // 10. Encode certificate to PEM
    const cert_bio = c.BIO_new(c.BIO_s_mem());
    if (cert_bio == null) {
        return TempCertError.PemEncodingFailed;
    }
    defer _ = c.BIO_free(cert_bio);

    if (c.PEM_write_bio_X509(cert_bio, x509) != 1) {
        logging.logDebug("Failed to write certificate to PEM\n", .{});
        return TempCertError.PemEncodingFailed;
    }

    // 11. Encode private key to PEM
    const key_bio = c.BIO_new(c.BIO_s_mem());
    if (key_bio == null) {
        return TempCertError.PemEncodingFailed;
    }
    defer _ = c.BIO_free(key_bio);

    if (c.PEM_write_bio_PrivateKey(key_bio, pkey, null, null, 0, null, null) != 1) {
        logging.logDebug("Failed to write private key to PEM\n", .{});
        return TempCertError.PemEncodingFailed;
    }

    // 12. Read PEM data from BIO into buffers
    const cert_pem = try readBioToBuffer(allocator, cert_bio.?);
    errdefer allocator.free(cert_pem);

    const key_pem = try readBioToBuffer(allocator, key_bio.?);
    errdefer allocator.free(key_pem);

    logging.logDebug("Successfully generated temporary RSA 2048-bit certificate\n", .{});

    return TemporaryCertificate{
        .cert_pem = cert_pem,
        .key_pem = key_pem,
    };
}

/// Generate RSA 2048-bit certificate using wolfSSL.
fn generateRsa2048CertificateWolfssl(allocator: std.mem.Allocator) TempCertError!TemporaryCertificate {
    _ = allocator;
    // TODO: Implement wolfSSL-based temporary certificate generation
    // wolfSSL requires different APIs (wc_MakeRsaKey, wc_InitCert, wc_MakeSelfCert)
    logging.logDebug("wolfSSL temporary certificate generation not yet implemented\n", .{});
    return TempCertError.TlsNotAvailable;
}

/// Generate a temporary ECDSA P-256 self-signed certificate.
///
/// Used for "modern" cipher profile to support ECDHE-ECDSA cipher suites.
/// Provides smaller key size (256-bit) with equivalent security to RSA 3072-bit.
///
/// **OpenSSL Implementation:**
/// - Uses EVP_EC_gen("prime256v1") for key generation
/// - X.509v3 certificate with 365-day validity
/// - SHA-256 signature
fn generateEcdsaP256Certificate(allocator: std.mem.Allocator) TempCertError!TemporaryCertificate {
    if (!use_openssl) {
        return TempCertError.TlsNotAvailable;
    }

    logging.logDebug("Generating temporary ECDSA P-256 key. Use --ssl-cert and --ssl-key for permanent certificates.\n", .{});

    // 1. Generate ECDSA P-256 private key (prime256v1 curve)
    // Use different code paths based on OpenSSL version
    const pkey = if (comptime c.OPENSSL_VERSION_NUMBER >= OPENSSL_VERSION_3_0_0) blk: {
        // OpenSSL 3.0+: Use EVP_PKEY_Q_keygen() wrapper (simpler than EVP_EC_gen)
        logging.logDebug("Using OpenSSL 3.0+ EVP_PKEY_Q_keygen API for ECDSA\n", .{});
        break :blk c.EVP_PKEY_Q_keygen(null, null, "EC", "prime256v1");
    } else blk: {
        // OpenSSL 1.1.1: Use EVP_PKEY_CTX-based key generation with EC_KEY
        logging.logDebug("Using OpenSSL 1.1.1 EVP_PKEY_CTX API for ECDSA\n", .{});

        const ctx = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_EC, null);
        if (ctx == null) {
            logging.logDebug("Failed to create EVP_PKEY_CTX for EC\n", .{});
            break :blk null;
        }
        defer c.EVP_PKEY_CTX_free(ctx);

        if (c.EVP_PKEY_keygen_init(ctx) <= 0) {
            logging.logDebug("Failed to initialize EC key generation\n", .{});
            break :blk null;
        }

        // Set curve to prime256v1 (NID_X9_62_prime256v1)
        if (c.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(ctx, c.NID_X9_62_prime256v1) <= 0) {
            logging.logDebug("Failed to set EC curve to prime256v1\n", .{});
            break :blk null;
        }

        var pkey_ptr: ?*c.EVP_PKEY = null;
        if (c.EVP_PKEY_keygen(ctx, &pkey_ptr) <= 0) {
            logging.logDebug("Failed to generate EC key\n", .{});
            break :blk null;
        }

        break :blk pkey_ptr;
    };

    if (pkey == null) {
        logging.logDebug("Failed to generate ECDSA P-256 key\n", .{});
        return TempCertError.EcdsaKeyGenerationFailed;
    }
    defer c.EVP_PKEY_free(pkey);

    // 2. Create X.509 certificate (same process as RSA)
    const x509 = c.X509_new();
    if (x509 == null) {
        logging.logDebug("Failed to create X.509 certificate\n", .{});
        return TempCertError.CertificateCreationFailed;
    }
    defer c.X509_free(x509);

    // 3. Set certificate version (X.509v3 = 2)
    _ = c.X509_set_version(x509, 2);

    // 4. Set serial number (random 64-bit value)
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = prng.random();
    const serial = random.int(u64);
    const asn1_serial = c.X509_get_serialNumber(x509);
    _ = c.ASN1_INTEGER_set(asn1_serial, @intCast(serial));

    // 5. Set validity period (365 days)
    _ = c.X509_gmtime_adj(c.X509_get_notBefore(x509), 0);
    _ = c.X509_gmtime_adj(c.X509_get_notAfter(x509), 365 * 24 * 60 * 60);

    // 6. Set public key
    _ = c.X509_set_pubkey(x509, pkey);

    // 7. Set subject name (CN=localhost)
    const name = c.X509_get_subject_name(x509);
    _ = c.X509_NAME_add_entry_by_txt(
        name,
        "CN",
        c.MBSTRING_ASC,
        "localhost",
        -1,
        -1,
        0,
    );

    // 8. Set issuer name (self-signed)
    _ = c.X509_set_issuer_name(x509, name);

    // 9. Sign the certificate with SHA-256
    if (c.X509_sign(x509, pkey, c.EVP_sha256()) == 0) {
        logging.logDebug("Failed to sign ECDSA certificate\n", .{});
        return TempCertError.CertificateSigningFailed;
    }

    // 10. Encode certificate to PEM
    const cert_bio = c.BIO_new(c.BIO_s_mem());
    if (cert_bio == null) {
        return TempCertError.PemEncodingFailed;
    }
    defer _ = c.BIO_free(cert_bio);

    if (c.PEM_write_bio_X509(cert_bio, x509) != 1) {
        logging.logDebug("Failed to write ECDSA certificate to PEM\n", .{});
        return TempCertError.PemEncodingFailed;
    }

    // 11. Encode private key to PEM
    const key_bio = c.BIO_new(c.BIO_s_mem());
    if (key_bio == null) {
        return TempCertError.PemEncodingFailed;
    }
    defer _ = c.BIO_free(key_bio);

    if (c.PEM_write_bio_PrivateKey(key_bio, pkey, null, null, 0, null, null) != 1) {
        logging.logDebug("Failed to write ECDSA private key to PEM\n", .{});
        return TempCertError.PemEncodingFailed;
    }

    // 12. Read PEM data from BIO into buffers
    const cert_pem = try readBioToBuffer(allocator, cert_bio.?);
    errdefer allocator.free(cert_pem);

    const key_pem = try readBioToBuffer(allocator, key_bio.?);
    errdefer allocator.free(key_pem);

    logging.logDebug("Successfully generated temporary ECDSA P-256 certificate\n", .{});

    return TemporaryCertificate{
        .cert_pem = cert_pem,
        .key_pem = key_pem,
    };
}

/// Read BIO contents into a Zig-allocated buffer (null-terminated for C interop).
///
/// **OpenSSL BIO Memory Management:**
/// - BIO_get_mem_data() returns pointer to internal BIO buffer
/// - Internal buffer is freed when BIO is freed
/// - We MUST copy data to our own allocation
fn readBioToBuffer(allocator: std.mem.Allocator, bio: *c.BIO) TempCertError![]u8 {
    if (!use_openssl) {
        return TempCertError.TlsNotAvailable;
    }

    // Get pointer to BIO's internal buffer
    var data_ptr: [*c]u8 = undefined;
    const data_len = c.BIO_get_mem_data(bio, &data_ptr);
    if (data_len <= 0 or data_ptr == null) {
        logging.logDebug("Failed to read BIO data\n", .{});
        return TempCertError.PemEncodingFailed;
    }

    // Allocate buffer with extra byte for null terminator
    const buffer = allocator.alloc(u8, @intCast(data_len + 1)) catch {
        return TempCertError.OutOfMemory;
    };
    errdefer allocator.free(buffer);

    // Copy PEM data from BIO to our buffer
    const data_slice = data_ptr[0..@intCast(data_len)];
    @memcpy(buffer[0..@intCast(data_len)], data_slice);
    buffer[@intCast(data_len)] = 0; // Null terminator for C interop

    return buffer;
}

// Unit tests
const testing = std.testing;

test "generateTemporaryCertificate - modern profile (ECDSA)" {
    if (!tls.isTlsEnabled()) {
        return error.SkipZigTest; // Skip if TLS not compiled in
    }

    var cert = try generateTemporaryCertificate(testing.allocator, "modern");
    defer cert.deinit(testing.allocator);

    // Verify PEM format
    try testing.expect(std.mem.indexOf(u8, cert.cert_pem, "-----BEGIN CERTIFICATE-----") != null);
    try testing.expect(std.mem.indexOf(u8, cert.cert_pem, "-----END CERTIFICATE-----") != null);
    try testing.expect(std.mem.indexOf(u8, cert.key_pem, "-----BEGIN") != null);
    try testing.expect(std.mem.indexOf(u8, cert.key_pem, "-----END") != null);

    // Verify null termination
    try testing.expectEqual(@as(u8, 0), cert.cert_pem[cert.cert_pem.len - 1]);
    try testing.expectEqual(@as(u8, 0), cert.key_pem[cert.key_pem.len - 1]);
}

test "generateTemporaryCertificate - intermediate profile (RSA)" {
    if (!tls.isTlsEnabled()) {
        return error.SkipZigTest;
    }

    var cert = try generateTemporaryCertificate(testing.allocator, "intermediate");
    defer cert.deinit(testing.allocator);

    // Verify PEM format
    try testing.expect(std.mem.indexOf(u8, cert.cert_pem, "-----BEGIN CERTIFICATE-----") != null);
    try testing.expect(std.mem.indexOf(u8, cert.key_pem, "-----BEGIN") != null);
}

test "generateTemporaryCertificate - compatible profile (RSA)" {
    if (!tls.isTlsEnabled()) {
        return error.SkipZigTest;
    }

    var cert = try generateTemporaryCertificate(testing.allocator, "compatible");
    defer cert.deinit(testing.allocator);

    // Verify PEM format
    try testing.expect(std.mem.indexOf(u8, cert.cert_pem, "-----BEGIN CERTIFICATE-----") != null);
    try testing.expect(std.mem.indexOf(u8, cert.key_pem, "-----BEGIN") != null);
}

test "generateTemporaryCertificate - unsupported profile" {
    if (!tls.isTlsEnabled()) {
        return error.SkipZigTest;
    }

    const result = generateTemporaryCertificate(testing.allocator, "invalid_profile");
    try testing.expectError(TempCertError.UnsupportedProfile, result);
}

test "generateRsa2048Certificate - basic functionality" {
    if (!tls.isTlsEnabled()) {
        return error.SkipZigTest;
    }

    var cert = try generateRsa2048Certificate(testing.allocator);
    defer cert.deinit(testing.allocator);

    // Verify certificate contains "RSA" or is valid PEM
    try testing.expect(cert.cert_pem.len > 100); // Reasonable size check
    try testing.expect(cert.key_pem.len > 100);
}

test "generateEcdsaP256Certificate - basic functionality" {
    if (!tls.isTlsEnabled() or !use_openssl) {
        return error.SkipZigTest;
    }

    const cert = generateEcdsaP256Certificate(testing.allocator) catch |err| {
        // ECDSA might not be available on all OpenSSL builds
        if (err == TempCertError.EcdsaKeyGenerationFailed) {
            return error.SkipZigTest;
        }
        return err;
    };
    var cert_mut = cert;
    defer cert_mut.deinit(testing.allocator);

    // Verify certificate is valid PEM
    try testing.expect(cert_mut.cert_pem.len > 100);
    try testing.expect(cert_mut.key_pem.len > 100);
}
