//! TLS transfer error mapping, messaging, and logging helpers.

const std = @import("std");

const config = @import("../../config.zig");
const logging = @import("../../util/logging.zig");

/// Comprehensive error set for TLS transfer operations.
pub const TLSTransferError = error{
    // Protocol errors
    AlertReceived,
    InvalidState,
    HandshakeFailed,
    HandshakeIncomplete,
    ProtocolVersionMismatch,
    CipherSuiteNegotiationFailed,
    UnexpectedMessage,
    InvalidRecord,
    RecordTooLarge,

    // Certificate errors
    CertificateVerificationFailed,
    UntrustedCertificate,
    CertificateExpired,
    CertificateRevoked,
    InvalidCertificate,
    CertificateChainTooLong,
    UnknownCA,

    // Buffer/memory errors
    BufferTooSmall,
    OutOfMemory,
    InsufficientBuffer,

    // Network errors
    ConnectionClosed,
    ConnectionReset,
    ConnectionAborted,
    NetworkTimeout,
    WouldBlock,

    // Configuration errors
    TlsNotEnabled,
    InvalidConfiguration,
    UnsupportedFeature,
    IncompatibleVersion,

    // Resource errors
    ResourceExhausted,
    TooManyConnections,
    SystemError,
};

/// Map backend errors to transfer error classification.
pub fn mapTlsError(err: anyerror) TLSTransferError {
    return switch (err) {
        error.AlertReceived => TLSTransferError.AlertReceived,
        error.InvalidState => TLSTransferError.InvalidState,
        error.HandshakeFailed => TLSTransferError.HandshakeFailed,
        error.CertificateVerificationFailed => TLSTransferError.CertificateVerificationFailed,
        error.BufferTooSmall => TLSTransferError.BufferTooSmall,
        error.TlsNotEnabled => TLSTransferError.TlsNotEnabled,
        error.WouldBlock => TLSTransferError.WouldBlock,
        error.ProtocolVersionMismatch => TLSTransferError.ProtocolVersionMismatch,
        error.CipherSuiteNegotiationFailed => TLSTransferError.CipherSuiteNegotiationFailed,
        error.UnexpectedMessage => TLSTransferError.UnexpectedMessage,
        error.InvalidStateTransition => TLSTransferError.InvalidState,
        error.InvalidRecord => TLSTransferError.InvalidRecord,
        error.RecordOverflow => TLSTransferError.RecordTooLarge,
        error.CertificateExpired => TLSTransferError.CertificateExpired,
        error.CertificateRevoked => TLSTransferError.CertificateRevoked,
        error.InvalidCertificate => TLSTransferError.InvalidCertificate,
        error.CertificateChainTooLong => TLSTransferError.CertificateChainTooLong,
        error.UnknownIssuer => TLSTransferError.UnknownCA,
        error.ConnectionResetByPeer => TLSTransferError.ConnectionReset,
        error.ConnectionAborted => TLSTransferError.ConnectionAborted,
        error.BrokenPipe => TLSTransferError.ConnectionClosed,
        error.Timeout => TLSTransferError.NetworkTimeout,
        error.OutOfMemory => TLSTransferError.OutOfMemory,
        error.OutOfRange => TLSTransferError.InvalidConfiguration,
        error.UnsupportedFeature => TLSTransferError.UnsupportedFeature,
        error.UnsupportedVersion => TLSTransferError.IncompatibleVersion,
        error.SystemResources => TLSTransferError.ResourceExhausted,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => TLSTransferError.TooManyConnections,
        else => TLSTransferError.SystemError,
    };
}

/// Provide user-friendly messages for TLS transfer errors.
pub fn getTlsErrorMessage(err: TLSTransferError, operation: []const u8) []const u8 {
    _ = operation;
    return switch (err) {
        TLSTransferError.AlertReceived => "TLS alert received from peer - connection terminated",
        TLSTransferError.InvalidState => "TLS connection in invalid state - handshake may be incomplete",
        TLSTransferError.HandshakeFailed => "TLS handshake failed - certificate or protocol issue",
        TLSTransferError.HandshakeIncomplete => "TLS handshake not yet complete",
        TLSTransferError.ProtocolVersionMismatch => "TLS protocol version mismatch",
        TLSTransferError.CipherSuiteNegotiationFailed => "Failed to negotiate TLS cipher suite",
        TLSTransferError.UnexpectedMessage => "Received unexpected TLS message",
        TLSTransferError.InvalidRecord => "Invalid TLS record format",
        TLSTransferError.RecordTooLarge => "TLS record exceeds maximum size",

        TLSTransferError.CertificateVerificationFailed => "TLS certificate verification failed",
        TLSTransferError.UntrustedCertificate => "TLS certificate is not trusted",
        TLSTransferError.CertificateExpired => "TLS certificate has expired",
        TLSTransferError.CertificateRevoked => "TLS certificate has been revoked",
        TLSTransferError.InvalidCertificate => "TLS certificate is invalid or malformed",
        TLSTransferError.CertificateChainTooLong => "TLS certificate chain is too long",
        TLSTransferError.UnknownCA => "TLS certificate signed by unknown CA",

        TLSTransferError.BufferTooSmall => "Buffer too small for TLS record",
        TLSTransferError.OutOfMemory => "Out of memory during TLS operation",
        TLSTransferError.InsufficientBuffer => "Insufficient buffer space for TLS data",

        TLSTransferError.ConnectionClosed => "TLS connection closed by peer",
        TLSTransferError.ConnectionReset => "TLS connection reset by peer",
        TLSTransferError.ConnectionAborted => "TLS connection aborted",
        TLSTransferError.NetworkTimeout => "TLS operation timed out",
        TLSTransferError.WouldBlock => "TLS operation would block",

        TLSTransferError.TlsNotEnabled => "TLS support not enabled at build time",
        TLSTransferError.InvalidConfiguration => "Invalid TLS configuration",
        TLSTransferError.UnsupportedFeature => "TLS feature not supported",
        TLSTransferError.IncompatibleVersion => "Incompatible TLS version",

        TLSTransferError.ResourceExhausted => "System resources exhausted for TLS",
        TLSTransferError.TooManyConnections => "Too many TLS connections",
        TLSTransferError.SystemError => "System error during TLS operation",
    };
}

/// Identify which TLS errors can be retried.
pub fn isTlsErrorRecoverable(err: TLSTransferError) bool {
    return switch (err) {
        TLSTransferError.WouldBlock => true,
        TLSTransferError.BufferTooSmall => true,
        TLSTransferError.NetworkTimeout => true,
        else => false,
    };
}

/// Handle TLS errors: log context and return classification.
pub fn handleTlsError(err: anyerror, operation: []const u8, cfg: *const config.Config) TLSTransferError {
    const tls_err = mapTlsError(err);
    const error_msg = getTlsErrorMessage(tls_err, operation);
    const recoverable = isTlsErrorRecoverable(tls_err);

    if (!@import("builtin").is_test) {
        if (cfg.verbose) {
            logging.logVerbose(cfg, "TLS {s} error: {s}\n", .{ operation, error_msg });
            switch (tls_err) {
                TLSTransferError.HandshakeFailed => {
                    logging.logVerbose(cfg, "Suggestion: Check certificate validity, cipher suite compatibility, and TLS version support\n", .{});
                },
                TLSTransferError.CertificateVerificationFailed => {
                    logging.logVerbose(cfg, "Suggestion: Verify certificate chain, check system time, or use --ssl-verify=false for testing\n", .{});
                },
                TLSTransferError.InvalidState => {
                    logging.logVerbose(cfg, "Suggestion: Ensure TLS handshake completed before attempting data transfer\n", .{});
                },
                TLSTransferError.BufferTooSmall => {
                    logging.logVerbose(cfg, "Suggestion: This is usually handled automatically - may indicate memory constraints\n", .{});
                },
                TLSTransferError.TlsNotEnabled => {
                    logging.logVerbose(cfg, "Suggestion: Rebuild with TLS support enabled or use plain TCP connection\n", .{});
                },
                TLSTransferError.NetworkTimeout => {
                    logging.logVerbose(cfg, "Suggestion: Check network connectivity or increase timeout values\n", .{});
                },
                TLSTransferError.ConnectionReset, TLSTransferError.ConnectionClosed => {
                    logging.logVerbose(cfg, "Suggestion: Peer closed connection - this may be normal or indicate protocol mismatch\n", .{});
                },
                else => {},
            }

            if (recoverable) {
                logging.logVerbose(cfg, "Note: This error is recoverable - operation will be retried\n", .{});
            } else {
                logging.logVerbose(cfg, "Note: This error requires connection termination\n", .{});
            }
        } else {
            if (recoverable) {
                logging.logWarning("TLS {s} warning: {s} (retrying)\n", .{ operation, error_msg });
            } else {
                logging.log(1, "TLS {s} error: {s}\n", .{ operation, error_msg });
            }
        }
    }

    return tls_err;
}

/// Handle output file errors with appropriate logging and recovery suggestions.
pub fn handleOutputError(err: anyerror, cfg: *const config.Config, operation: []const u8) void {
    if (@import("builtin").is_test) return;

    switch (err) {
        config.IOControlError.DiskFull => {
            logging.log(1, "Error: Disk full - stopping {s} to prevent data loss\n", .{operation});
        },
        config.IOControlError.InsufficientPermissions => {
            logging.log(1, "Error: Permission denied - stopping {s}\n", .{operation});
        },
        else => {
            if (cfg.verbose) {
                logging.logVerbose(cfg, "Warning: {s} failed: {any}\n", .{ operation, err });
            }
        },
    }
}

/// Print data as hex dump to stdout with ASCII sidebar.
pub fn printHexDump(data: []const u8) void {
    if (@import("builtin").is_test) return;

    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        logging.log(1, "{x:0>8}: ", .{i});

        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                logging.log(1, "{x:0>2} ", .{data[i + j]});
            } else {
                logging.log(1, "   ", .{});
            }
        }

        logging.log(1, " |", .{});

        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (c >= 32 and c <= 126) {
                logging.log(1, "{c}", .{c});
            } else {
                logging.log(1, ".", .{});
            }
        }

        logging.log(1, "|\n", .{});
    }
}

// -----------------------------------------------------------------------------+
// Tests                                                                         |
// -----------------------------------------------------------------------------+

test "TLS error mapping and recoverability" {
    const mapped_err = mapTlsError(error.AlertReceived);
    try std.testing.expectEqual(TLSTransferError.AlertReceived, mapped_err);

    const network_err = mapTlsError(error.ConnectionResetByPeer);
    try std.testing.expectEqual(TLSTransferError.ConnectionReset, network_err);

    const memory_err = mapTlsError(error.OutOfMemory);
    try std.testing.expectEqual(TLSTransferError.OutOfMemory, memory_err);

    try std.testing.expect(isTlsErrorRecoverable(TLSTransferError.WouldBlock));
    try std.testing.expect(isTlsErrorRecoverable(TLSTransferError.BufferTooSmall));
    try std.testing.expect(!isTlsErrorRecoverable(TLSTransferError.HandshakeFailed));
}

test "TLS error messaging" {
    const alert_msg = getTlsErrorMessage(TLSTransferError.AlertReceived, "read");
    try std.testing.expect(alert_msg.len > 0);

    const handshake_msg = getTlsErrorMessage(TLSTransferError.HandshakeFailed, "write");
    try std.testing.expect(handshake_msg.len > 0);

    const cert_msg = getTlsErrorMessage(TLSTransferError.CertificateVerificationFailed, "connect");
    try std.testing.expect(cert_msg.len > 0);
}

test "handleTlsError returns mapped error" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.verbose = false;

    const alert_err = handleTlsError(error.AlertReceived, "test", &cfg);
    try std.testing.expect(alert_err == TLSTransferError.AlertReceived);

    const invalid_err = handleTlsError(error.InvalidState, "test", &cfg);
    try std.testing.expect(invalid_err == TLSTransferError.InvalidState);
}

test "handleOutputError tolerates errors" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    cfg.verbose = true;

    handleOutputError(config.IOControlError.DiskFull, &cfg, "test operation");
    handleOutputError(error.OutOfMemory, &cfg, "test operation");
}

test "printHexDump handles sample data" {
    printHexDump("Hello, World!\x00\x01\x02");
    printHexDump("");
}
