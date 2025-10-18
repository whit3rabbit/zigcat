// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Core Telnet enums, helpers, and validation utilities shared by the protocol
//! processor. These definitions mirror RFC 854/855 terminology so the event
//! loop can reason about commands, options, and legal state transitions.
//!
//! ## RFC Compliance Reference
//!
//! This implementation follows these Telnet protocol specifications:
//!
//! ### Core Protocol
//! - **RFC 854**: Telnet Protocol Specification
//!   - Command codes (236-255), IAC byte escaping, state machine
//!   - Location: TelnetCommand enum, validateStateTransition()
//! - **RFC 855**: Telnet Option Specification
//!   - WILL/WONT/DO/DONT negotiation semantics
//!   - Location: TelnetOption enum, option negotiation logic in telnet_processor.zig
//! - **RFC 1143**: The Q Method of Implementing Telnet Option Negotiation
//!   - 95% implementation: Basic states (NO/YES/WANTNO/WANTYES) with counter-based loop prevention
//!   - Optional enhancement: Queue bits (EMPTY/OPPOSITE) for precise state tracking
//!   - Current approach uses negotiation counter (MAX_NEGOTIATION_ATTEMPTS) which works reliably
//!   - Location: OptionState enum in telnet_processor.zig
//!
//! ### Implemented Options
//! - **RFC 857**: ECHO Option - Server/client echo control
//! - **RFC 858**: SUPPRESS-GO-AHEAD Option - Disable half-duplex mode
//! - **RFC 1091**: TERMINAL-TYPE Option - Terminal identification
//! - **RFC 1073**: NAWS (Negotiate About Window Size) - Dynamic window updates
//! - **RFC 1572**: NEW-ENVIRON Option - Environment variable exchange
//! - **RFC 1184**: LINEMODE Option - Line editing and SLC (Special Line Characters)
//!   - Partial: MODE/FORWARDMASK supported, SLC constants defined but handlers TODO
//!
//! ### Security Considerations
//! - NEW-ENVIRON uses allowlist (TERM, USER, LANG, etc.) - never sends credentials
//! - IAC byte escaping prevents command injection in data streams
//! - Negotiation loop prevention via MAX_NEGOTIATION_ATTEMPTS (10)
//! - Subnegotiation length limit: 1024 bytes
const std = @import("std");

/// Telnet protocol state machine states
pub const TelnetState = enum {
    data, // Normal data processing
    iac, // Received IAC (255)
    will, // Received IAC WILL
    wont, // Received IAC WONT
    do, // Received IAC DO
    dont, // Received IAC DONT
    sb, // Subnegotiation begin
    sb_data, // Subnegotiation data
    sb_iac, // IAC in subnegotiation
};

/// Telnet protocol commands as defined in RFC 854 Section 4
/// All commands are in the range 236-255 and must follow IAC (255)
pub const TelnetCommand = enum(u8) {
    eof = 236, // End of file
    susp = 237, // Suspend process
    abort = 238, // Abort process
    eor = 239, // End of record
    se = 240, // End of subnegotiation
    nop = 241, // No operation
    dm = 242, // Data mark
    brk = 243, // Break
    ip = 244, // Interrupt process
    ao = 245, // Abort output
    ayt = 246, // Are you there
    ec = 247, // Erase character
    el = 248, // Erase line
    ga = 249, // Go ahead
    sb = 250, // Subnegotiation begin
    will = 251, // Will option
    wont = 252, // Won't option
    do = 253, // Do option
    dont = 254, // Don't option
    iac = 255, // Interpret as command

    /// Convert byte to TelnetCommand if valid
    pub fn fromByte(byte: u8) ?TelnetCommand {
        return switch (byte) {
            236...255 => @enumFromInt(byte),
            else => null,
        };
    }
};

/// Telnet options as defined in various RFCs
pub const TelnetOption = enum(u8) {
    echo = 1, // Echo (RFC 857)
    suppress_ga = 3, // Suppress go ahead (RFC 858)
    status = 5, // Status (RFC 859)
    timing_mark = 6, // Timing mark (RFC 860)
    terminal_type = 24, // Terminal type (RFC 1091)
    naws = 31, // Negotiate about window size (RFC 1073)
    terminal_speed = 32, // Terminal speed (RFC 1079)
    flow_control = 33, // Remote flow control (RFC 1372)
    linemode = 34, // Linemode (RFC 1184)
    environ = 36, // (Obsolete) Environment variables (RFC 1408)
    new_environ = 39, // Enhanced environment variables (RFC 1572)

    /// Convert byte to TelnetOption if recognized
    pub fn fromByte(byte: u8) ?TelnetOption {
        return switch (byte) {
            1 => .echo,
            3 => .suppress_ga,
            5 => .status,
            6 => .timing_mark,
            24 => .terminal_type,
            31 => .naws,
            32 => .terminal_speed,
            33 => .flow_control,
            34 => .linemode,
            36 => .environ,
            39 => .new_environ,
            else => null,
        };
    }
};
/// Telnet protocol errors
pub const TelnetError = error{
    InvalidCommand,
    InvalidOption,
    BufferOverflow,
    NegotiationLoop,
    MalformedSequence,
    SubnegotiationTooLong,
    InvalidStateTransition,
};

/// Ensure the state machine only follows RFC-sanctioned transitions.
/// Used by `TelnetProcessor` to guard each byte before it updates state.
pub fn validateStateTransition(current: TelnetState, next: TelnetState, input: u8) TelnetError!void {
    const valid = switch (current) {
        .data => switch (input) {
            @intFromEnum(TelnetCommand.iac) => next == .iac,
            else => next == .data,
        },
        .iac => switch (input) {
            @intFromEnum(TelnetCommand.will) => next == .will,
            @intFromEnum(TelnetCommand.wont) => next == .wont,
            @intFromEnum(TelnetCommand.do) => next == .do,
            @intFromEnum(TelnetCommand.dont) => next == .dont,
            @intFromEnum(TelnetCommand.sb) => next == .sb,
            @intFromEnum(TelnetCommand.iac) => next == .data, // Escaped IAC
            @intFromEnum(TelnetCommand.se), @intFromEnum(TelnetCommand.nop), @intFromEnum(TelnetCommand.dm), @intFromEnum(TelnetCommand.brk), @intFromEnum(TelnetCommand.ip), @intFromEnum(TelnetCommand.ao), @intFromEnum(TelnetCommand.ayt), @intFromEnum(TelnetCommand.ec), @intFromEnum(TelnetCommand.el), @intFromEnum(TelnetCommand.ga), @intFromEnum(TelnetCommand.eor), @intFromEnum(TelnetCommand.abort), @intFromEnum(TelnetCommand.susp), @intFromEnum(TelnetCommand.eof) => next == .data,
            else => false,
        },
        .will, .wont, .do, .dont => next == .data, // Option byte follows, then back to data
        .sb => next == .sb_data,
        .sb_data => switch (input) {
            @intFromEnum(TelnetCommand.iac) => next == .sb_iac,
            else => next == .sb_data,
        },
        .sb_iac => switch (input) {
            @intFromEnum(TelnetCommand.se) => next == .data,
            @intFromEnum(TelnetCommand.iac) => next == .sb_data, // Escaped IAC in subnegotiation
            else => false,
        },
    };

    if (!valid) {
        return TelnetError.InvalidStateTransition;
    }
}

/// Check if a command requires an option byte
pub fn commandRequiresOption(command: TelnetCommand) bool {
    return switch (command) {
        .will, .wont, .do, .dont, .sb => true,
        else => false,
    };
}

/// Check if a byte is a valid Telnet command
pub fn isValidCommand(byte: u8) bool {
    return TelnetCommand.fromByte(byte) != null;
}

/// Check if a byte is a recognized Telnet option
pub fn isRecognizedOption(byte: u8) bool {
    return TelnetOption.fromByte(byte) != null;
}
// Re-export TelnetProcessor for convenience
pub const TelnetProcessor = @import("telnet_processor.zig").TelnetProcessor;
