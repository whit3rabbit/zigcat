//! TLS transfer facade.
//!
//! Exposes the public API for TLS-aware transfers while delegating detailed
//! logic to focused modules under `io/tls_transfer/`.

const transfer = @import("tls_transfer/transfer.zig");
const errors = @import("tls_transfer/errors.zig");
const cleanup = @import("tls_transfer/cleanup.zig");

pub const BUFFER_SIZE = transfer.BUFFER_SIZE;

pub const TLSTransferError = errors.TLSTransferError;

pub const tlsBidirectionalTransfer = transfer.tlsBidirectionalTransfer;
pub const tlsBidirectionalTransferWindows = transfer.tlsBidirectionalTransferWindows;
pub const tlsBidirectionalTransferPosix = transfer.tlsBidirectionalTransferPosix;

pub const mapTlsError = errors.mapTlsError;
pub const getTlsErrorMessage = errors.getTlsErrorMessage;
pub const isTlsErrorRecoverable = errors.isTlsErrorRecoverable;
pub const handleTlsError = errors.handleTlsError;
pub const handleOutputError = errors.handleOutputError;
pub const printHexDump = errors.printHexDump;

pub const cleanupTlsTransferResources = cleanup.cleanupTlsTransferResources;

comptime {
    if (@import("builtin").is_test) {
        _ = @import("tls_transfer/tests.zig");
    }
}
