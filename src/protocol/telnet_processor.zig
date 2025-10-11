//! Telnet protocol state machine that filters IAC sequences and brokers
//! option negotiation per RFC 854/855. The processor collaborates with
//! `OptionHandlerRegistry` so each option handler can emit responses while
//! the core loop focuses on state tracking, buffering, and allocator hygiene.
const std = @import("std");
const telnet = @import("telnet.zig");
const telnet_options = @import("telnet_options.zig");

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

/// Telnet protocol processor with state machine
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
    pub fn init(allocator: std.mem.Allocator, terminal_type: []const u8, window_width: u16, window_height: u16) TelnetProcessor {
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
            .option_handlers = OptionHandlerRegistry.init(terminal_type, window_width, window_height),
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

            // Update our internal state based on the negotiation
            switch (command) {
                .will => try self.handleWill(option, current_state, response),
                .wont => try self.handleWont(option, current_state, response),
                .do => try self.handleDo(option, current_state, response),
                .dont => try self.handleDont(option, current_state, response),
                else => return TelnetError.InvalidCommand,
            }
        } else {
            // For unsupported options, use default handling
            switch (command) {
                .will => try self.handleWill(option, current_state, response),
                .wont => try self.handleWont(option, current_state, response),
                .do => try self.handleDo(option, current_state, response),
                .dont => try self.handleDont(option, current_state, response),
                else => return TelnetError.InvalidCommand,
            }
        }
    }
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
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

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
