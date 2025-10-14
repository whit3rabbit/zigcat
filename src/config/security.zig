// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Security-oriented configuration validation.

const std = @import("std");
const builtin = @import("builtin");

const config_struct = @import("config_struct.zig");
const Config = config_struct.Config;
const poll_wrapper = @import("../util/poll_wrapper.zig");

/// Errors related to broker/chat mode configuration validation.
pub const BrokerChatError = error{
    /// Both --broker and --chat flags specified
    ConflictingBrokerChatModes,
    /// Broker/chat mode requires listen mode (-l flag)
    RequiresListenMode,
    /// Broker/chat mode is incompatible with exec mode (-e/-c flags)
    IncompatibleWithExecMode,
    /// Broker/chat mode is incompatible with I/O control modes (--send-only/--recv-only)
    IncompatibleWithIOControl,
    /// Maximum client limit is invalid (zero or too large)
    InvalidMaxClients,
    /// Chat nickname length limit is invalid
    InvalidNicknameLength,
    /// Chat message length limit is invalid
    InvalidMessageLength,
};

/// Validate broker/chat mode configuration for conflicts and requirements.
pub fn validateBrokerChat(cfg: *const Config) BrokerChatError!void {
    if (cfg.broker_mode and cfg.chat_mode) {
        return BrokerChatError.ConflictingBrokerChatModes;
    }

    if (!cfg.broker_mode and !cfg.chat_mode) {
        return;
    }

    if (!cfg.listen_mode) {
        return BrokerChatError.RequiresListenMode;
    }

    if (cfg.exec_command != null or cfg.shell_command != null) {
        return BrokerChatError.IncompatibleWithExecMode;
    }

    if (cfg.send_only or cfg.recv_only) {
        return BrokerChatError.IncompatibleWithIOControl;
    }

    if (cfg.max_clients == 0 or cfg.max_clients > 1000) {
        return BrokerChatError.InvalidMaxClients;
    }

    // SECURITY: Windows select() backend has FD_SETSIZE limitation (~64 on Windows)
    // Each client requires ~3 fd_set entries (read/write/error sets) plus 1 for listen socket
    // Safe limit: (FD_SETSIZE - 1) / 3 ≈ 21 clients with select() backend
    // The WSAPoll backend (Windows Vista+) has no such limitation
    if (builtin.os.tag == .windows) {
        // Conservative safe limit for select() backend
        // Enforced only when runtime detection indicates select() fallback
        const windows_select_safe_limit = 20;

        if (cfg.max_clients > windows_select_safe_limit and poll_wrapper.windowsPollBackend() == .select) {
            std.debug.print(
                "\n" ++
                "┌────────────────────────────────────────────────────────────────┐\n" ++
                "│ ERROR: Windows Connection Limit Exceeded                       │\n" ++
                "├────────────────────────────────────────────────────────────────┤\n" ++
                "│ Configured max_clients: {d: >3}                                   │\n" ++
                "│ Safe limit (select):    {d: >3}                                   │\n" ++
                "├────────────────────────────────────────────────────────────────┤\n" ++
                "│ The Windows select() backend is limited by FD_SETSIZE (64).   │\n" ++
                "│ Exceeding this limit may cause:                               │\n" ++
                "│   • Silent connection failures                                 │\n" ++
                "│   • Denial of Service conditions                              │\n" ++
                "│   • Server instability                                         │\n" ++
                "├────────────────────────────────────────────────────────────────┤\n" ++
                "│ Recommendations:                                               │\n" ++
                "│   1. Use --max-clients {d} or less                              │\n" ++
                "│   2. Wait for WSAPoll backend (removes limitation)             │\n" ++
                "│   Server start aborted to avoid instability.                   │\n" ++
                "└────────────────────────────────────────────────────────────────┘\n" ++
                "\n",
                .{cfg.max_clients, windows_select_safe_limit, windows_select_safe_limit}
            );

            return BrokerChatError.InvalidMaxClients;
        }
    }

    if (cfg.chat_mode) {
        if (cfg.chat_max_nickname_len == 0 or cfg.chat_max_nickname_len > 255) {
            return BrokerChatError.InvalidNicknameLength;
        }

        if (cfg.chat_max_message_len == 0 or cfg.chat_max_message_len > 65536) {
            return BrokerChatError.InvalidMessageLength;
        }
    }
}

test "validateBrokerChat enforces listen mode requirement" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.broker_mode = true;
    cfg.listen_mode = false;

    try testing.expectError(BrokerChatError.RequiresListenMode, validateBrokerChat(&cfg));
}

test "validateBrokerChat rejects unsafe select backend configuration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.broker_mode = true;
    cfg.listen_mode = true;
    cfg.max_clients = 50;

    poll_wrapper.testingOverrideWindowsBackend(.select);
    defer poll_wrapper.testingOverrideWindowsBackend(null);

    try testing.expectError(BrokerChatError.InvalidMaxClients, validateBrokerChat(&cfg));
}

test "validateBrokerChat passes valid chat configuration" {
    const testing = std.testing;

    var cfg = Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    cfg.chat_mode = true;
    cfg.listen_mode = true;
    cfg.max_clients = 50;
    cfg.chat_max_nickname_len = 32;
    cfg.chat_max_message_len = 1024;

    try validateBrokerChat(&cfg);
}
