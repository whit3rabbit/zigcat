// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Shared configuration types for zigcat.
//!
//! This module defines enums that are used across multiple
//! configuration domains (network, TLS, CLI, etc).

/// Verbosity levels for controlling output detail.
///
/// Usage:
/// - quiet: No output except errors (equivalent to -q)
/// - normal: Default output (connections, warnings)
/// - verbose: Connection details, transfer stats (equivalent to -v)
/// - debug: Protocol details, hex dumps (equivalent to -vv)
/// - trace: All internal state, detailed tracing (equivalent to -vvv)
pub const VerbosityLevel = enum(u8) {
    quiet = 0, // No output except errors
    normal = 1, // Default (connections, warnings)
    verbose = 2, // -v (connection details)
    debug = 3, // -vv (protocol details)
    trace = 4, // -vvv (all internal state)
};

/// Proxy protocol types supported by zigcat.
pub const ProxyType = enum {
    /// HTTP CONNECT proxy (most common)
    http,
    /// SOCKS4 proxy protocol
    socks4,
    /// SOCKS5 proxy protocol
    socks5,
};

/// DNS resolution modes for proxy connections.
pub const ProxyDns = enum {
    /// No DNS resolution through proxy
    none,
    /// Resolve DNS locally before connecting to proxy
    local,
    /// Resolve DNS remotely via proxy
    remote,
    /// Support both local and remote resolution
    both,
};

/// Telnet signal handling mode.
///
/// Determines how zigcat reacts to local terminal signals while in Telnet mode.
/// - `local`: behave like netcat, let SIGINT/SIGTSTP control the local client
/// - `remote`: translate Ctrl-C / Ctrl-Z into Telnet IP/SUSP without killing the client
pub const TelnetSignalMode = enum {
    local,
    remote,
};

/// Telnet editing strategy.
pub const TelnetEditMode = enum {
    remote,
    local,
};
