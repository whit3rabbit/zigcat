// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! TLS abstraction interface providing a uniform API for TLS operations.
//!
//! This module defines the TLS connection trait that supports multiple backends:
//! - **OpenSSL** (default): Ubiquitous, production-ready TLS library
//! - **wolfSSL** (opt-in): Lightweight TLS library for size-critical builds
//!
//! **Features:**
//! - Encrypted read/write operations
//! - Connection lifecycle management
//! - Error types for TLS operations
//! - Configuration structures
//! - Backend selection at build time
//!
//! **Backend Selection:**
//! ```bash
//! zig build -Dtls-backend=openssl  # Default, ubiquitous
//! zig build -Dtls-backend=wolfssl  # Lightweight, 92% smaller
//! ```
//!
//! **Security:**
//! Both backends provide production-ready encryption and certificate validation.
//!
//! **Thread Safety:**
//! TlsConnection is NOT thread-safe. Each connection should be accessed
//! by a single thread at a time.

const std = @import("std");
const build_options = @import("build_options");

/// TLS connection interface that wraps socket operations with encryption.
///
/// **Backend Support:**
/// - `.openssl`: OpenSSL/LibreSSL backend (default, production-ready)
/// - `.wolfssl`: wolfSSL backend (opt-in, lightweight, 92% smaller)
/// - `.disabled`: Stub backend when TLS is disabled at build time
///
/// **Backend Selection:**
/// The backend is selected at build time via the `tls_backend` build option.
/// Both backends provide full TLS 1.2/1.3 support with modern cipher suites.
///
/// **Lifecycle:**
/// 1. Create via `tls.connectTls()` or `tls.acceptTls()`
/// 2. Use `read()`/`write()` for encrypted I/O
/// 3. Call `close()` to send TLS close_notify
/// 4. Call `deinit()` to free all resources
///
/// **Important:**
/// Always call `deinit()` to prevent memory leaks, even if `close()` was called.
pub const TlsConnection = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    // Backend union is compile-time generated based on which backend is enabled
    // This avoids requiring both backend types to be valid even when only one is used
    pub const Backend = if (use_wolfssl) union(enum) {
        wolfssl: *WolfSslTls,
        disabled: void,
    } else union(enum) {
        openssl: *OpenSslTls,
        disabled: void,
    };

    /// Reads and decrypts data from the TLS stream into the provided buffer.
    ///
    /// This function handles the TLS record layer, decrypting incoming data. A
    /// return value of 0 indicates that the peer has gracefully closed the
    /// connection by sending a `close_notify` alert.
    ///
    /// If the underlying socket is in non-blocking mode, this function may
    /// return `error.WouldBlock`.
    ///
    /// @param self The `TlsConnection` instance.
    /// @param buffer The buffer to store the decrypted plaintext data.
    /// @return The number of bytes read into `buffer`, or any `TlsError`.
    pub fn read(self: *TlsConnection, buffer: []u8) !usize {
        if (use_wolfssl) {
            return switch (self.backend) {
                .wolfssl => |tls| try tls.read(buffer),
                .disabled => error.TlsNotEnabled,
            };
        } else {
            return switch (self.backend) {
                .openssl => |tls| try tls.read(buffer),
                .disabled => error.TlsNotEnabled,
            };
        }
    }

    /// Encrypts and writes data to the TLS stream.
    ///
    /// This function takes plaintext data, encrypts it, and sends it over the
    /// underlying socket. The return value is the number of plaintext bytes
    /// from `data` that were successfully processed and buffered for sending.
    ///
    /// If the underlying socket is in non-blocking mode, this function may
    /// return `error.WouldBlock`.
    ///
    /// @param self The `TlsConnection` instance.
    /// @param data The plaintext data to encrypt and send.
    /// @return The number of bytes from `data` that were written, or any `TlsError`.
    pub fn write(self: *TlsConnection, data: []const u8) !usize {
        if (use_wolfssl) {
            return switch (self.backend) {
                .wolfssl => |tls| try tls.write(data),
                .disabled => error.TlsNotEnabled,
            };
        } else {
            return switch (self.backend) {
                .openssl => |tls| try tls.write(data),
                .disabled => error.TlsNotEnabled,
            };
        }
    }

    /// Initiates a graceful shutdown of the TLS connection.
    ///
    /// This function sends a `close_notify` alert to the peer, signaling the
    /// end of the stream. It is the recommended way to close a TLS connection.
    ///
    /// **Important**: This function does **not** close the underlying socket.
    /// The caller is responsible for closing the socket after calling `close()`.
    /// It also does **not** free the memory associated with the `TlsConnection`;
    /// `deinit()` must still be called.
    ///
    /// This function is idempotent; subsequent calls after the first have no effect.
    ///
    /// @param self The `TlsConnection` instance.
    pub fn close(self: *TlsConnection) void {
        if (use_wolfssl) {
            switch (self.backend) {
                .wolfssl => |tls| tls.close(),
                .disabled => {},
            }
        } else {
            switch (self.backend) {
                .openssl => |tls| tls.close(),
                .disabled => {},
            }
        }
    }

    /// Deinitialize and free all TLS resources.
    ///
    /// **Behavior:**
    /// - Frees all heap-allocated buffers
    /// - Destroys TLS session state
    /// - Destroys the TLS backend object itself
    ///
    /// **Important:**
    /// - Does NOT close the underlying socket
    /// - Does NOT send close_notify (call `close()` first if needed)
    /// - MUST be called to prevent memory leaks
    ///
    /// **Usage:**
    /// ```zig
    /// defer tls_conn.deinit();  // Idiomatic cleanup
    /// ```
    pub fn deinit(self: *TlsConnection) void {
        if (use_wolfssl) {
            switch (self.backend) {
                .wolfssl => |tls| {
                    tls.deinit();
                    self.allocator.destroy(tls);
                },
                .disabled => {},
            }
        } else {
            switch (self.backend) {
                .openssl => |tls| {
                    tls.deinit();
                    self.allocator.destroy(tls);
                },
                .disabled => {},
            }
        }
    }

    /// Get the underlying socket file descriptor.
    ///
    /// **Returns:**
    /// The raw socket file descriptor used by the TLS connection.
    ///
    /// **Use cases:**
    /// - Polling for socket readiness with poll()/select()
    /// - Setting socket options
    /// - Monitoring socket state
    ///
    /// **Warning:**
    /// - Do NOT close this socket directly - use `close()` instead
    /// - Do NOT perform I/O on this socket - use `read()`/`write()` instead
    pub fn getSocket(self: *TlsConnection) std.posix.socket_t {
        if (use_wolfssl) {
            return switch (self.backend) {
                .wolfssl => |tls| tls.socket,
                .disabled => unreachable,
            };
        } else {
            return switch (self.backend) {
                .openssl => |tls| tls.socket,
                .disabled => unreachable,
            };
        }
    }
};

/// Configuration for TLS connections (client and server mode).
///
/// **Client Mode Fields:**
/// - `server_name`: Hostname for SNI and certificate validation
/// - `verify_peer`: Enable/disable certificate verification (default: true)
/// - `trust_file`: CA certificate bundle (system default if null)
/// - `crl_file`: Certificate Revocation List (optional)
/// - `alpn_protocols`: Comma-separated ALPN list (e.g., "h2,http/1.1")
///
/// **Server Mode Fields:**
/// - `cert_file`: Path to server certificate (PEM format)
/// - `key_file`: Path to private key (PEM format)
/// - `alpn_protocols`: Advertise ALPN support
///
/// **Security:**
/// - Always set `server_name` in client mode for proper validation
/// - Never disable `verify_peer` unless testing on trusted networks
/// - Use `cipher_suites` to restrict to secure algorithms only
/// - Prefer `min_version = .tls_1_2` or higher
/// - Use `crl_file` for enhanced security in enterprise environments
pub const TlsConfig = struct {
    /// Certificate file path (server mode or client verification)
    cert_file: ?[]const u8 = null,

    /// Private key file path (server mode)
    key_file: ?[]const u8 = null,

    /// Verify peer certificates (client mode)
    verify_peer: bool = true,

    /// Trust store file path (CA certificates)
    trust_file: ?[]const u8 = null,

    /// Certificate Revocation List file path (optional)
    crl_file: ?[]const u8 = null,

    /// Server name for SNI (client mode)
    server_name: ?[]const u8 = null,

    /// ALPN protocols (e.g., "h2,http/1.1")
    alpn_protocols: ?[]const u8 = null,

    /// Cipher suites (comma-separated)
    cipher_suites: ?[]const u8 = null,

    /// Minimum TLS version
    min_version: TlsVersion = .tls_1_2,

    /// Maximum TLS version
    max_version: TlsVersion = .tls_1_3,
};

/// TLS/DTLS protocol version enumeration.
///
/// **Supported TLS Versions:**
/// - `.tls_1_0`: TLS 1.0 (RFC 2246) - **DEPRECATED, insecure**
/// - `.tls_1_1`: TLS 1.1 (RFC 4346) - **DEPRECATED, insecure**
/// - `.tls_1_2`: TLS 1.2 (RFC 5246) - **Minimum recommended**
/// - `.tls_1_3`: TLS 1.3 (RFC 8446) - **Preferred**
///
/// **Supported DTLS Versions:**
/// - `.dtls_1_0`: DTLS 1.0 (RFC 4347, based on TLS 1.1) - **DEPRECATED**
/// - `.dtls_1_2`: DTLS 1.2 (RFC 6347, based on TLS 1.2) - **Minimum recommended**
/// - `.dtls_1_3`: DTLS 1.3 (RFC 9147, based on TLS 1.3) - **Preferred, requires OpenSSL 3.2+**
///
/// **DTLS Version Numbering:**
/// DTLS version numbers are deliberately offset from TLS:
/// - DTLS 1.0 is based on TLS 1.1 (skipped TLS 1.0)
/// - DTLS 1.2 is based on TLS 1.2 (skipped DTLS 1.1)
/// - DTLS 1.3 is based on TLS 1.3
///
/// **Security Recommendation:**
/// - TLS: Use `min_version = .tls_1_2` at minimum
/// - DTLS: Use `min_version = .dtls_1_2` at minimum
/// TLS 1.0/1.1 and DTLS 1.0 have known vulnerabilities and are deprecated.
pub const TlsVersion = enum {
    // TLS versions (stream-oriented, TCP)
    tls_1_0,
    tls_1_1,
    tls_1_2,
    tls_1_3,

    // DTLS versions (datagram-oriented, UDP)
    dtls_1_0, // Based on TLS 1.1
    dtls_1_2, // Based on TLS 1.2
    dtls_1_3, // Based on TLS 1.3 (OpenSSL 3.2+)

    /// Check if this is a DTLS version
    pub fn isDtls(self: TlsVersion) bool {
        return switch (self) {
            .dtls_1_0, .dtls_1_2, .dtls_1_3 => true,
            else => false,
        };
    }

    /// Check if this is a TLS version
    pub fn isTls(self: TlsVersion) bool {
        return !self.isDtls();
    }

    /// Get the minimum OpenSSL version required for this protocol version
    pub fn minOpenSslVersion(self: TlsVersion) u32 {
        return switch (self) {
            .tls_1_0, .tls_1_1 => 0x1000000f, // OpenSSL 1.0.0
            .tls_1_2 => 0x1000100f, // OpenSSL 1.0.1
            .tls_1_3 => 0x1010100f, // OpenSSL 1.1.1
            .dtls_1_0, .dtls_1_2 => 0x1000200f, // OpenSSL 1.0.2
            .dtls_1_3 => 0x30200000, // OpenSSL 3.2.0
        };
    }

    /// Check if this version is at least the specified version
    /// Note: Cannot compare TLS and DTLS versions (returns false)
    pub fn isAtLeast(self: TlsVersion, other: TlsVersion) bool {
        // Cannot compare across TLS/DTLS boundary
        if (self.isDtls() != other.isDtls()) return false;

        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

/// TLS-specific error types for connection and cryptographic operations.
///
/// **Handshake Errors:**
/// - `HandshakeFailed`: General handshake failure
/// - `ProtocolVersionMismatch`: Version negotiation failed
/// - `InvalidCipherSuite`: No common cipher suite
///
/// **Certificate Errors:**
/// - `CertificateInvalid`: Malformed or corrupted certificate
/// - `CertificateExpired`: Certificate validity period expired
/// - `CertificateVerificationFailed`: Signature verification failed
/// - `UntrustedCertificate`: Not signed by trusted CA
/// - `HostnameMismatch`: Certificate CN/SAN doesn't match server_name
///
/// **State Errors:**
/// - `InvalidState`: Operation invalid in current connection state
/// - `AlertReceived`: Peer sent fatal alert
/// - `BufferTooSmall`: Record too large for buffer
/// - `WouldBlock`: Non-blocking operation would block
/// - `TlsNotEnabled`: TLS support disabled at build time
pub const TlsError = error{
    HandshakeFailed,
    CertificateInvalid,
    CertificateExpired,
    CertificateVerificationFailed,
    UntrustedCertificate,
    HostnameMismatch,
    InvalidCipherSuite,
    ProtocolVersionMismatch,
    AlertReceived,
    InvalidState,
    BufferTooSmall,
    WouldBlock,
    TlsNotEnabled,
};

// TLS backend imports - conditional based on build options
// Backend is selected at build time via -Dtls-backend flag
// Only import the backend that's actually enabled to avoid linking unused libraries
const use_wolfssl = @hasDecl(build_options, "use_wolfssl") and build_options.use_wolfssl;
const OpenSslTls = if (!use_wolfssl) @import("tls_openssl.zig").OpenSslTls else void;
const WolfSslTls = if (use_wolfssl) @import("tls_wolfssl.zig").WolfSslTls else void;
