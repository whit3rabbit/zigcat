// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Client mode implementation for zigcat.
//!
//! This module serves as the public API for client mode functionality.
//! The implementation has been refactored into specialized modules under
//! src/client/ for improved maintainability and testability.
//!
//! Module structure:
//! - client/mod.zig: Main orchestrator and mode dispatch
//! - client/tcp_client.zig: TCP/UDP/SCTP/Proxy connection logic
//! - client/tls_client.zig: TLS/DTLS handshake and encryption
//! - client/gsocket_client.zig: NAT-traversal via GSRN relay
//! - client/unix_client.zig: Unix domain socket connections
//! - client/stream_adapters.zig: Stream interface adapters
//! - client/transfer_context.zig: Reusable transfer context
//!
//! Client workflow:
//! 1. Parse target host:port from positional arguments
//! 2. Establish connection (direct or via proxy)
//! 3. Optional TLS handshake
//! 4. Handle zero-I/O mode (connect and close immediately)
//! 5. Execute command (-e flag) or bidirectional transfer
//!
//! Timeout enforcement:
//! - Uses wait_time (-w flag) if set, else connect_timeout
//! - All connections use poll()-based non-blocking I/O
//! - See TIMEOUT_SAFETY.md for timeout patterns

// Re-export the main entry point from the refactored client module
pub const runClient = @import("client/mod.zig").runClient;

// Re-export stream adapters for use by server mode (exec sessions, etc.)
const adapters = @import("client/stream_adapters.zig");
pub const telnetConnectionToStream = adapters.telnetConnectionToStream;
pub const tlsConnectionToStream = adapters.tlsConnectionToStream;
pub const srpConnectionToStream = adapters.srpConnectionToStream;
pub const dtlsConnectionToStream = adapters.dtlsConnectionToStream;
pub const netStreamToStream = adapters.netStreamToStream;
