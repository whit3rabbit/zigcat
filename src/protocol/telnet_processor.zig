// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! This file implements the core Telnet command/option state machine. The
//! `TelnetProcessor` struct is responsible for parsing the incoming byte stream,
//! identifying Telnet commands (like IAC, WILL, DO), and managing the negotiation
//! state for each option. It separates raw application data from protocol
// commands, handing off option-specific logic to the handlers in
//! `telnet_options.zig`.

const std = @import("std");
const telnet = @import("telnet.zig");
const telnet_options = @import("telnet_options.zig");
const tty_state = @import("terminal").tty_state;

const TelnetState = telnet.TelnetState;
const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;
const TelnetError = telnet.TelnetError;
const OptionHandlerRegistry = telnet_options.OptionHandlerRegistry;

/// Option negotiation state for each Telnet option
pub const OptionState = enum {
    no,
    yes,
    wantno,
    wantyes,
};

/// A state machine for processing the Telnet protocol (RFC 854).
///
/// This struct implements a byte-by-byte state machine that parses an incoming
/// stream of data, filtering out Telnet commands and handling option negotiations
/// (`WILL`, `WON'T`, `DO`, `DON'T`) and sub-negotiations (`SB`...`SE`).
///
/// ## State Management
/// The processor's current state is stored in the `state` field, which is an
/// instance of `telnet.TelnetState`. As each byte is processed, the `getNextState`
/// function determines the next state based on the current state and the input byte.
///
/// ## Option Negotiation
/// The state of each Telnet option (e.g., `ECHO`, `NAWS`) is tracked in the
/// `option_states` map. The processor follows the negotiation logic described in
/// RFC 854, responding to requests from the peer and updating its internal state.
/// To prevent infinite negotiation loops, it also tracks the number of negotiation
/// attempts for each option.
///
/// ## Sub-negotiation
/// For complex options that require exchanging more data (like `NAWS` or
/// `TERMINAL-TYPE`), the processor buffers the sub-negotiation data between
/// `SB` (Sub-negotiation Begin) and `SE` (Sub-negotiation End) commands and passes
/// it to the appropriate handler.
///
/// ## Buffering
/// The processor maintains two internal buffers:
/// - `sb_buffer`: For accumulating data during a sub-negotiation.
/// - `partial_buffer`: For storing incomplete Telnet command sequences that are
///   split across multiple input reads.
pub const TelnetProcessor = struct {
    state: TelnetState,
    option_states: std.EnumMap(TelnetOption, OptionState),
    sb_buffer: std.ArrayList(u8),
    current_option: ?TelnetOption,
    allocator: std.mem.Allocator,
    scratch_allocator: ?std.mem.Allocator = null,
    negotiation_count: std.EnumMap(TelnetOption, u32),
    partial_buffer: std.ArrayList(u8),
    option_handlers: OptionHandlerRegistry,

    const MAX_SUBNEGOTIATION_LENGTH = 1024; // Cap subnegotiations at 1 KiB to match legacy ncat limits and avoid abuse.
    const MAX_NEGOTIATION_ATTEMPTS = 10; // Mirrors RFC 1143 guidance on breaking negotiation loops (Q-method).
    const MAX_PARTIAL_BUFFER_SIZE = 16; // Long enough for "IAC SB <option> ... IAC" fragments per RFC 854/1143.

    /// Initialize a new Telnet processor with all options disabled
    pub fn init(
        allocator: std.mem.Allocator,
        terminal_type: []const u8,
        window_width: u16,
        window_height: u16,
        local_tty: ?*tty_state.TtyState,
    ) TelnetProcessor {
        var option_states = std.EnumMap(TelnetOption, OptionState){};
        var negotiation_count = std.EnumMap(TelnetOption, u32){};

        inline for (std.meta.fields(TelnetOption)) |field| {
            const option = @field(TelnetOption, field.name);
            option_states.put(option, .no);
            negotiation_count.put(option, 0);
        }

        return TelnetProcessor{
            .state = .data,
            .option_states = option_states,
            .sb_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .current_option = null,
            .allocator = allocator,
            .negotiation_count = negotiation_count,
            .partial_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .option_handlers = OptionHandlerRegistry.init(terminal_type, window_width, window_height, local_tty),
        };
    }

    /// Clean up allocated resources
    pub fn deinit(self: *TelnetProcessor) void {
        self.sb_buffer.deinit(self.allocator);
        self.partial_buffer.deinit(self.allocator);
    }

    pub const ProcessResult = struct {
        data: []u8,
        response: []u8,
    };

    /// Process input data through the Telnet state machine.
    /// Filters out Telnet IAC sequences and handles option negotiation.
    /// Maintains state across calls to handle partial sequences.
    ///
    /// Returns ProcessResult containing filtered application data and any
    /// negotiation responses to send to the peer. The caller owns both slices and
    /// must free them with the same allocator passed to `init`.
    pub fn processInput(self: *TelnetProcessor, input: []const u8) (TelnetError || std.mem.Allocator.Error)!ProcessResult {
        return self.processInputWithAllocator(self.allocator, input);
    }

    pub fn processInputWithAllocator(self: *TelnetProcessor, scratch: std.mem.Allocator, input: []const u8) (TelnetError || std.mem.Allocator.Error)!ProcessResult {
        var app_data = try std.ArrayList(u8).initCapacity(scratch, 0);
        defer app_data.deinit(scratch);

        var response = try std.ArrayList(u8).initCapacity(scratch, 0);
        defer response.deinit(scratch);

        var combined_input = try std.ArrayList(u8).initCapacity(scratch, 0);
        defer combined_input.deinit(scratch);

        self.scratch_allocator = scratch;
        defer self.scratch_allocator = null;

        try combined_input.appendSlice(scratch, self.partial_buffer.items);
        try combined_input.appendSlice(scratch, input);
        self.partial_buffer.clearRetainingCapacity();

        var i: usize = 0;
        while (i < combined_input.items.len) {
            const byte = combined_input.items[i];
            const next_state = self.getNextState(byte) catch |err| {
                if (self.isIncompleteSequence(combined_input.items[i..])) {
                    const remaining = combined_input.items[i..];
                    if (remaining.len > MAX_PARTIAL_BUFFER_SIZE) {
                        return TelnetError.BufferOverflow;
                    }
                    try self.partial_buffer.appendSlice(self.allocator, remaining);
                    break;
                }
                return err;
            };

            try telnet.validateStateTransition(self.state, next_state, byte);
            try self.processByte(byte, next_state, &app_data, &response);
            self.state = next_state;
            i += 1;
        }

        return ProcessResult{
            .data = try app_data.toOwnedSlice(scratch),
            .response = try response.toOwnedSlice(scratch),
        };
    }

    fn isIncompleteSequence(self: *const TelnetProcessor, remaining: []const u8) bool {
        if (remaining.len == 0) return false;

        if (remaining[0] == @intFromEnum(TelnetCommand.iac)) {
            if (remaining.len == 1) return true;

            const command = TelnetCommand.fromByte(remaining[1]);
            if (command) |cmd| {
                if (telnet.commandRequiresOption(cmd) and remaining.len == 2) {
                    return true;
                }
            }
        }

        if (self.state == .sb_data or self.state == .sb_iac) {
            return true;
        }

        return false;
    }

    /// Process outgoing application data, escaping IAC bytes per RFC 854.
    /// Optionally injects Telnet commands before the data.
    pub fn processOutput(self: *TelnetProcessor, data: []const u8, inject_commands: ?[]const u8) std.mem.Allocator.Error![]u8 {
        return self.processOutputWithAllocator(self.allocator, data, inject_commands);
    }

    pub fn processOutputWithAllocator(self: *TelnetProcessor, scratch: std.mem.Allocator, data: []const u8, inject_commands: ?[]const u8) std.mem.Allocator.Error![]u8 {
        self.scratch_allocator = scratch;
        defer self.scratch_allocator = null;

        var output = try std.ArrayList(u8).initCapacity(scratch, 0);
        defer output.deinit(scratch);

        if (inject_commands) |commands| {
            try output.appendSlice(self.outputAllocator(), commands);
        }

        for (data) |byte| {
            if (byte == @intFromEnum(TelnetCommand.iac)) {
                try output.appendSlice(self.outputAllocator(), &[_]u8{ @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.iac) });
            } else {
                try output.append(self.outputAllocator(), byte);
            }
        }

        return try output.toOwnedSlice(scratch);
    }

    /// Create a properly formatted Telnet command sequence.
    /// Option parameter is required for negotiation commands (WILL/WONT/DO/DONT/SB).
    pub fn createCommand(self: *TelnetProcessor, command: TelnetCommand, option: ?TelnetOption) (TelnetError || std.mem.Allocator.Error)![]u8 {
        const out_allocator = self.outputAllocator();
        var cmd_data = try std.ArrayList(u8).initCapacity(out_allocator, 0);
        defer cmd_data.deinit(out_allocator);

        try cmd_data.append(out_allocator, @intFromEnum(TelnetCommand.iac));
        try cmd_data.append(out_allocator, @intFromEnum(command));

        if (telnet.commandRequiresOption(command)) {
            const opt = option orelse return TelnetError.InvalidCommand;
            try cmd_data.append(out_allocator, @intFromEnum(opt));
        }

        return try cmd_data.toOwnedSlice(out_allocator);
    }

    /// Determines the next state of the state machine based on the current state
    /// and an input byte.
    ///
    /// This function implements the core Telnet state transition logic as
    /// described in RFC 854. For example, if the current state is `.data` and
    /// the input byte is an `IAC` command, the next state will be `.iac`.
    fn getNextState(self: *const TelnetProcessor, byte: u8) TelnetError!TelnetState {
        // The transition table mirrors the RFC 854 state diagram so every byte keeps
        // the processor in a well-defined mode before validation/dispatch occur.
        return switch (self.state) {
            .data => if (byte == @intFromEnum(TelnetCommand.iac)) .iac else .data,
            .iac => switch (byte) {
                @intFromEnum(TelnetCommand.will) => .will,
                @intFromEnum(TelnetCommand.wont) => .wont,
                @intFromEnum(TelnetCommand.do) => .do,
                @intFromEnum(TelnetCommand.dont) => .dont,
                @intFromEnum(TelnetCommand.sb) => .sb,
                @intFromEnum(TelnetCommand.iac) => .data,
                else => if (telnet.isValidCommand(byte)) .data else return TelnetError.InvalidCommand,
            },
            .will, .wont, .do, .dont => .data,
            .sb => .sb_data,
            .sb_data => if (byte == @intFromEnum(TelnetCommand.iac)) .sb_iac else .sb_data,
            .sb_iac => switch (byte) {
                @intFromEnum(TelnetCommand.se) => .data,
                @intFromEnum(TelnetCommand.iac) => .sb_data,
                else => return TelnetError.MalformedSequence,
            },
        };
    }

    /// Processes a single byte based on the current state of the state machine.
    ///
    /// This function is the action-taking counterpart to `getNextState`. After a
    /// state transition is determined, this function is called to perform the
    /// associated action. For example:
    /// - If the state is `.data`, the byte is appended to the application data buffer.
    /// - If the state is `.will`, the byte is interpreted as a Telnet option, and
    ///   the negotiation logic is triggered.
    /// - If the state is `.sb_data`, the byte is added to the sub-negotiation buffer.
    fn processByte(self: *TelnetProcessor, byte: u8, _: TelnetState, app_data: *std.ArrayList(u8), response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        // Data states emit straight into app_data, while negotiation states funnel
        // through OptionHandlerRegistry so each RFC-specific handler can craft replies.
        switch (self.state) {
            .data => {
                if (byte != @intFromEnum(TelnetCommand.iac)) {
                    try app_data.append(self.outputAllocator(), byte);
                }
            },
            .iac => {
                if (byte == @intFromEnum(TelnetCommand.iac)) {
                    try app_data.append(self.outputAllocator(), byte);
                } else if (telnet.commandRequiresOption(TelnetCommand.fromByte(byte) orelse return TelnetError.InvalidCommand)) {} else {
                    try self.handleSimpleCommand(TelnetCommand.fromByte(byte) orelse return TelnetError.InvalidCommand, response);
                }
            },
            .will => {
                const option = TelnetOption.fromByte(byte);
                // Hand the negotiation off to the centralized option registry so each
                // handler can emit protocol-specific replies.
                try self.handleNegotiation(.will, option, response);
            },
            .wont => {
                const option = TelnetOption.fromByte(byte);
                try self.handleNegotiation(.wont, option, response);
            },
            .do => {
                const option = TelnetOption.fromByte(byte);
                try self.handleNegotiation(.do, option, response);
            },
            .dont => {
                const option = TelnetOption.fromByte(byte);
                try self.handleNegotiation(.dont, option, response);
            },
            .sb => {
                self.current_option = TelnetOption.fromByte(byte);
                self.sb_buffer.clearRetainingCapacity();
            },
            .sb_data => {
                if (byte != @intFromEnum(TelnetCommand.iac)) {
                    if (self.sb_buffer.items.len > MAX_SUBNEGOTIATION_LENGTH - 1) {
                        return TelnetError.SubnegotiationTooLong;
                    }
                    try self.sb_buffer.append(self.allocator, byte);
                }
            },
            .sb_iac => {
                if (byte == @intFromEnum(TelnetCommand.se)) {
                    try self.handleSubnegotiation(self.current_option, self.sb_buffer.items, response);
                    self.current_option = null;
                } else if (byte == @intFromEnum(TelnetCommand.iac)) {
                    if (self.sb_buffer.items.len > MAX_SUBNEGOTIATION_LENGTH - 1) {
                        return TelnetError.SubnegotiationTooLong;
                    }
                    try self.sb_buffer.append(self.allocator, byte);
                }
            },
        }
    }

    fn handleSimpleCommand(self: *TelnetProcessor, command: TelnetCommand, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        _ = self;
        _ = response;

        switch (command) {
            .nop => {},
            .dm => {},
            .brk => {},
            .ip => {},
            .ao => {},
            .ayt => {},
            .ec => {},
            .el => {},
            .ga => {},
            .se => return TelnetError.MalformedSequence,
            else => return TelnetError.InvalidCommand,
        }
    }

    fn handleNegotiation(self: *TelnetProcessor, command: TelnetCommand, option: ?TelnetOption, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        const opt = option orelse {
            const refusal_cmd: TelnetCommand = switch (command) {
                .will => .dont,
                .do => .wont,
                .wont, .dont => return,
                else => return TelnetError.InvalidCommand,
            };

            try response.appendSlice(self.outputAllocator(), &[_]u8{
                @intFromEnum(TelnetCommand.iac),
                @intFromEnum(refusal_cmd),
                0,
            });
            return;
        };

        const count = self.negotiation_count.get(opt) orelse 0;
        if (count >= MAX_NEGOTIATION_ATTEMPTS) {
            return TelnetError.NegotiationLoop;
        }
        self.negotiation_count.put(opt, count + 1);

        try self.processNegotiation(command, opt, response);
    }

    fn processNegotiation(self: *TelnetProcessor, command: TelnetCommand, option: TelnetOption, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        const current_state = self.option_states.get(option) orelse .no;

        // Use option handlers for supported options
        if (self.isOptionSupported(option)) {
            try self.option_handlers.handleNegotiation(self.outputAllocator(), command, option, response);

            // Update our internal state based on the negotiation (no response generation)
            switch (command) {
                .will => self.updateStateForWill(option, current_state),
                .wont => self.updateStateForWont(option, current_state),
                .do => self.updateStateForDo(option, current_state),
                .dont => self.updateStateForDont(option, current_state),
                else => return TelnetError.InvalidCommand,
            }
        } else {
            // For unsupported options, use default handling (generates refusal responses)
            switch (command) {
                .will => try self.handleWill(option, current_state, response),
                .wont => try self.handleWont(option, current_state, response),
                .do => try self.handleDo(option, current_state, response),
                .dont => try self.handleDont(option, current_state, response),
                else => return TelnetError.InvalidCommand,
            }
        }
    }
    // State-only update functions (no response generation - used for supported options)
    fn updateStateForWill(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState) void {
        switch (current_state) {
            .no, .wantno, .wantyes => {
                self.option_states.put(option, .yes);
            },
            .yes => {},
        }
    }

    fn updateStateForWont(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState) void {
        switch (current_state) {
            .yes, .wantno, .wantyes => {
                self.option_states.put(option, .no);
            },
            .no => {},
        }
    }

    fn updateStateForDo(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState) void {
        switch (current_state) {
            .no, .wantno, .wantyes => {
                self.option_states.put(option, .yes);
            },
            .yes => {},
        }
    }

    fn updateStateForDont(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState) void {
        switch (current_state) {
            .yes, .wantno, .wantyes => {
                self.option_states.put(option, .no);
            },
            .no => {},
        }
    }

    // Full handlers with response generation (used for unsupported options)
    fn handleWill(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        switch (current_state) {
            .no => {
                self.option_states.put(option, .yes);
                try self.sendResponse(.do, option, response);
            },
            .yes => {},
            .wantno => {
                self.option_states.put(option, .yes);
            },
            .wantyes => {
                self.option_states.put(option, .yes);
            },
        }
    }

    fn handleWont(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        switch (current_state) {
            .no => {},
            .yes => {
                self.option_states.put(option, .no);
                try self.sendResponse(.dont, option, response);
            },
            .wantno => {
                self.option_states.put(option, .no);
            },
            .wantyes => {
                self.option_states.put(option, .no);
            },
        }
    }

    fn handleDo(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        switch (current_state) {
            .no => {
                if (self.isOptionSupported(option)) {
                    self.option_states.put(option, .yes);
                    try self.sendResponse(.will, option, response);
                } else {
                    try self.sendResponse(.wont, option, response);
                }
            },
            .yes => {},
            .wantno => {
                try self.sendResponse(.wont, option, response);
                self.option_states.put(option, .no);
            },
            .wantyes => {
                self.option_states.put(option, .yes);
            },
        }
    }

    fn handleDont(self: *TelnetProcessor, option: TelnetOption, current_state: OptionState, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        switch (current_state) {
            .no => {},
            .yes => {
                self.option_states.put(option, .no);
                try self.sendResponse(.wont, option, response);
            },
            .wantno => {
                self.option_states.put(option, .no);
            },
            .wantyes => {
                self.option_states.put(option, .no);
            },
        }
    }

    fn sendResponse(self: *TelnetProcessor, command: TelnetCommand, option: TelnetOption, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        try response.appendSlice(self.outputAllocator(), &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(command),
            @intFromEnum(option),
        });
    }

    fn isOptionSupported(self: *const TelnetProcessor, option: TelnetOption) bool {
        _ = self;
        return switch (option) {
            .echo => true,
            .suppress_ga => true,
            .terminal_type => true,
            .naws => true,
            .linemode => true,
            else => false,
        };
    }

    fn handleSubnegotiation(self: *TelnetProcessor, option: ?TelnetOption, data: []const u8, response: *std.ArrayList(u8)) (TelnetError || std.mem.Allocator.Error)!void {
        const opt = option orelse return;

        // Use option handlers for subnegotiation
        try self.option_handlers.handleSubnegotiation(self.outputAllocator(), opt, data, response);
    }

    fn outputAllocator(self: *const TelnetProcessor) std.mem.Allocator {
        return self.scratch_allocator orelse self.allocator;
    }

    pub fn resetNegotiation(self: *TelnetProcessor) void {
        inline for (std.meta.fields(TelnetOption)) |field| {
            const option = @field(TelnetOption, field.name);
            self.option_states.put(option, .no);
            self.negotiation_count.put(option, 0);
        }
        self.state = .data;
        self.current_option = null;
        self.sb_buffer.clearRetainingCapacity();
    }

    pub fn clearBuffers(self: *TelnetProcessor) void {
        self.sb_buffer.clearRetainingCapacity();
        self.partial_buffer.clearRetainingCapacity();
    }

    /// Update window size and send NAWS subnegotiation if enabled
    pub fn updateWindowSize(self: *TelnetProcessor, width: u16, height: u16) std.mem.Allocator.Error![]u8 {
        var response = std.ArrayList(u8){};
        defer response.deinit(self.allocator);

        // Only send if NAWS is enabled
        if (self.option_states.get(.naws) == .yes) {
            try self.option_handlers.updateWindowSize(self.allocator, width, height, &response);
        }

        return try response.toOwnedSlice();
    }

    /// Get the current state of a Telnet option
    pub fn getOptionState(self: *const TelnetProcessor, option: TelnetOption) OptionState {
        return self.option_states.get(option) orelse .no;
    }
};
