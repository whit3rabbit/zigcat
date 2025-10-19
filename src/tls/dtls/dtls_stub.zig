// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! DTLS stub for builds where DTLS is unavailable.
//!
//! This module provides a stub implementation of DtlsConnection that is used when:
//! - TLS is disabled (-Dtls=false)
//! - wolfSSL backend is used (DTLS only supported with OpenSSL)
//!
//! IMPORTANT: This stub is shared across all modules to ensure type consistency.
//! Do NOT create separate stub definitions in different files.

const std = @import("std");
const posix = std.posix;

/// DTLS stub connection type.
/// These methods should never be called because connectDtls() returns an error first.
/// If called, indicates a logic error in the connection establishment code.
pub const DtlsConnection = struct {
    /// SAFETY: Should never be called - connectDtls() prevents DtlsConnection creation.
    /// Using unreachable instead of @panic() to signal this is a logic error.
    pub fn deinit(_: *DtlsConnection) void {
        unreachable; // connectDtls() prevents DtlsConnection creation
    }

    /// SAFETY: Should never be called - connectDtls() prevents DtlsConnection creation.
    pub fn close(_: *DtlsConnection) void {
        unreachable; // connectDtls() prevents DtlsConnection creation
    }

    /// SAFETY: Should never be called - connectDtls() prevents DtlsConnection creation.
    pub fn read(_: *DtlsConnection, _: []u8) !usize {
        unreachable; // connectDtls() prevents DtlsConnection creation
    }

    /// SAFETY: Should never be called - connectDtls() prevents DtlsConnection creation.
    pub fn write(_: *DtlsConnection, _: []const u8) !usize {
        unreachable; // connectDtls() prevents DtlsConnection creation
    }

    /// SAFETY: Should never be called - connectDtls() prevents DtlsConnection creation.
    pub fn getSocket(_: *DtlsConnection) posix.socket_t {
        unreachable; // connectDtls() prevents DtlsConnection creation
    }
};
