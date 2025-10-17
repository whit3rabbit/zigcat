// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Top-level configuration validation orchestration.

const std = @import("std");

const config_struct = @import("config_struct.zig");
const Config = config_struct.Config;

const cli = @import("cli.zig");
const network = @import("network.zig");
const tls = @import("tls.zig");
const security_cfg = @import("security.zig");

/// Comprehensive configuration validation including I/O, TLS, Unix sockets,
/// exec mode checks, broker/chat enforcement, and basic conflict detection.
pub fn validate(cfg: *const Config) !void {
    const security = @import("../util/security.zig");

    try cli.validateIOControl(cfg);
    try security_cfg.validateBrokerChat(cfg);
    try network.validateUnixSocket(cfg);
    try tls.validateTlsConfiguration(cfg);

    if (cfg.ssl) {
        if (cfg.listen_mode and cfg.ssl_cert == null) {
            return error.SslCertRequired;
        }
    }

    if (cfg.exec_command != null or cfg.shell_command != null) {
        const exec_prog = cfg.exec_command orelse cfg.shell_command.?;

        security.displayExecWarning(exec_prog, cfg.allow_list.items.len);

        if (cfg.listen_mode and cfg.require_allow_with_exec) {
            try security.validateExecSecurity(
                exec_prog,
                cfg.allow_list.items.len,
                cfg.require_allow_with_exec,
            );
        }

        if (cfg.listen_mode and !cfg.allow_dangerous) {
            std.debug.print("Warning: -e/-c with -l is dangerous. Use --allow to permit.\n", .{});
            return error.DangerousOperation;
        }
    }

    if (cfg.udp_mode and cfg.sctp_mode) {
        return error.ConflictingModes;
    }

    if (cfg.ipv4_only and cfg.ipv6_only) {
        return error.ConflictingAddressFamilies;
    }

    // Validate gsocket configuration
    if (cfg.gsocket_secret != null) {
        // gsocket is TCP only
        if (cfg.udp_mode) {
            return error.ConflictingOptions; // gsocket incompatible with UDP
        }
        if (cfg.sctp_mode) {
            return error.ConflictingOptions; // gsocket incompatible with SCTP
        }
        if (cfg.unix_socket_path != null) {
            return error.ConflictingOptions; // gsocket incompatible with Unix sockets
        }
        if (cfg.proxy != null) {
            return error.ConflictingOptions; // gsocket has its own NAT traversal
        }
        if (cfg.ssl or cfg.dtls) {
            return error.ConflictingOptions; // gsocket has its own encryption
        }
        // In connect mode, gsocket doesn't use host/port args (uses secret instead)
        if (!cfg.listen_mode and cfg.positional_args.len > 0) {
            return error.ConflictingOptions;
        }
    }
}
