// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! This file defines handlers for individual Telnet options like ECHO, NAWS,
//! and Terminal Type. Each handler is a struct that implements the logic for
//! responding to WILL/WONT/DO/DONT commands for a specific option. This
//! modular approach keeps the core state machine in `telnet_processor.zig`
//! clean and focused on parsing, while the option-specific logic is
//! encapsulated here.

const std = @import("std");
const telnet = @import("telnet.zig");

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;
const TelnetError = telnet.TelnetError;

/// Echo option handler implementing RFC 857 echo negotiation
pub const EchoHandler = struct {
    /// Handle WILL echo from remote side - server will echo, client should disable local echo
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle DO echo request from remote side - client should enable local echo
    pub fn handleDo(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle WONT echo from remote side - we should handle echo locally
    pub fn handleWont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle DONT echo from remote side - remote doesn't want us to echo
    pub fn handleDont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.echo),
        });
    }
};

/// Terminal type handler implementing RFC 1091 with subnegotiation support
pub const TerminalTypeHandler = struct {
    terminal_type: []const u8,

    const SEND: u8 = 1;
    const IS: u8 = 0;

    /// Initialize terminal type handler with specified terminal type string
    pub fn init(terminal_type: []const u8) TerminalTypeHandler {
        return TerminalTypeHandler{
            .terminal_type = terminal_type,
        };
    }

    /// Handle WILL terminal type from remote side
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.terminal_type),
        });
    }

    /// Handle DO terminal type request from remote side
    pub fn handleDo(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.terminal_type),
        });
    }

    /// Handle WONT terminal type from remote side
    pub fn handleWont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.terminal_type),
        });
    }

    /// Handle DONT terminal type from remote side
    pub fn handleDont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.terminal_type),
        });
    }

    /// Handle terminal type subnegotiation - responds to SEND requests with configured terminal type
    /// 
    /// Parameters:
    /// - data: Subnegotiation data received from remote
    /// - response: Buffer to append response commands
    pub fn handleSubnegotiation(self: *const TerminalTypeHandler, allocator: std.mem.Allocator, data: []const u8, response: *std.ArrayList(u8)) !void {
        if (data.len == 0) return;

        switch (data[0]) {
            SEND => {
                try response.appendSlice(allocator, &[_]u8{
                    @intFromEnum(TelnetCommand.iac),
                    @intFromEnum(TelnetCommand.sb),
                    @intFromEnum(TelnetOption.terminal_type),
                    IS,
                });
                try response.appendSlice(allocator, self.terminal_type);
                try response.appendSlice(allocator, &[_]u8{
                    @intFromEnum(TelnetCommand.iac),
                    @intFromEnum(TelnetCommand.se),
                });
            },
            IS => {
                // Remote is providing their terminal type - store if needed
            },
            else => {
                // Unknown subnegotiation command
            },
        }
    }
};

/// NAWS (Negotiate About Window Size) handler implementing RFC 1073
pub const NAWSHandler = struct {
    width: u16,
    height: u16,

    /// Initialize NAWS handler with specified window dimensions
    pub fn init(width: u16, height: u16) NAWSHandler {
        return NAWSHandler{
            .width = width,
            .height = height,
        };
    }

    /// Handle WILL NAWS from remote side
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.naws),
        });
    }

    /// Handle DO NAWS request from remote side - immediately sends current window size
    pub fn handleDo(self: *const NAWSHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.naws),
        });

        try self.sendWindowSize(allocator, response);
    }

    /// Handle WONT NAWS from remote side
    pub fn handleWont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.naws),
        });
    }

    /// Handle DONT NAWS from remote side
    pub fn handleDont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.naws),
        });
    }

    /// Send window size information via subnegotiation
    /// Encodes width and height as 16-bit big-endian values
    pub fn sendWindowSize(self: *const NAWSHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.sb),
            @intFromEnum(TelnetOption.naws),
        });

        // Width (16-bit big-endian)
        try response.append(allocator, @intCast(self.width >> 8));
        try response.append(allocator, @intCast(self.width & 0xFF));

        // Height (16-bit big-endian)
        try response.append(allocator, @intCast(self.height >> 8));
        try response.append(allocator, @intCast(self.height & 0xFF));

        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.se),
        });
    }

    /// Parse NAWS subnegotiation data to extract window dimensions
    /// Returns window size struct or null if data is malformed
    pub fn handleSubnegotiation(data: []const u8) ?struct { width: u16, height: u16 } {
        if (data.len < 4) return null;

        const width = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
        const height = (@as(u16, data[2]) << 8) | @as(u16, data[3]);

        return .{ .width = width, .height = height };
    }

    /// Update stored window size and send NAWS subnegotiation
    pub fn updateWindowSize(self: *NAWSHandler, allocator: std.mem.Allocator, width: u16, height: u16, response: *std.ArrayList(u8)) !void {
        self.width = width;
        self.height = height;
        try self.sendWindowSize(allocator, response);
    }
};

/// Suppress Go Ahead handler implementing RFC 858
pub const SuppressGoAheadHandler = struct {
    /// Handle WILL suppress go ahead from remote side
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.suppress_ga),
        });
    }

    /// Handle DO suppress go ahead request from remote side
    pub fn handleDo(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.suppress_ga),
        });
    }

    /// Handle WONT suppress go ahead from remote side
    pub fn handleWont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.suppress_ga),
        });
    }

    /// Handle DONT suppress go ahead from remote side
    pub fn handleDont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.suppress_ga),
        });
    }
};

/// Linemode handler implementing RFC 1184 for line-oriented terminal operation
pub const LinemodeHandler = struct {
    const MODE: u8 = 1;
    const FORWARDMASK: u8 = 2;
    const SLC: u8 = 3;

    const MODE_EDIT: u8 = 0x01;
    const MODE_TRAPSIG: u8 = 0x02;
    const MODE_ACK: u8 = 0x04;
    const MODE_SOFT_TAB: u8 = 0x08;
    const MODE_LIT_ECHO: u8 = 0x10;

    /// Handle WILL linemode from remote side
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.linemode),
        });
    }

    /// Handle DO linemode request from remote side - sends preferred linemode settings
    pub fn handleDo(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.linemode),
        });

        try LinemodeHandler.sendLinemodeSettings(allocator, response);
    }

    /// Handle WONT linemode from remote side
    pub fn handleWont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.linemode),
        });
    }

    /// Handle DONT linemode from remote side
    pub fn handleDont(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.linemode),
        });
    }

    /// Send linemode settings enabling editing and signal trapping
    pub fn sendLinemodeSettings(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.sb),
            @intFromEnum(TelnetOption.linemode),
            MODE,
            MODE_EDIT | MODE_TRAPSIG,
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.se),
        });
    }

    /// Handle linemode subnegotiation commands (MODE, FORWARDMASK, SLC)
    pub fn handleSubnegotiation(allocator: std.mem.Allocator, data: []const u8, response: *std.ArrayList(u8)) !void {
        if (data.len == 0) return;

        switch (data[0]) {
            MODE => {
                if (data.len >= 2) {
                    const mode_byte = data[1];
                    if (mode_byte & MODE_ACK == 0) {
                        // Send acknowledgment
                        try response.appendSlice(allocator, &[_]u8{
                            @intFromEnum(TelnetCommand.iac),
                            @intFromEnum(TelnetCommand.sb),
                            @intFromEnum(TelnetOption.linemode),
                            MODE,
                            mode_byte | MODE_ACK,
                            @intFromEnum(TelnetCommand.iac),
                            @intFromEnum(TelnetCommand.se),
                        });
                    }
                }
            },
            FORWARDMASK => {
                // Echo back the forward mask for acknowledgment
                if (data.len >= 33) {
                    try response.appendSlice(allocator, &[_]u8{
                        @intFromEnum(TelnetCommand.iac),
                        @intFromEnum(TelnetCommand.sb),
                        @intFromEnum(TelnetOption.linemode),
                        FORWARDMASK,
                    });
                    try response.appendSlice(allocator, data[1..33]);
                    try response.appendSlice(allocator, &[_]u8{
                        @intFromEnum(TelnetCommand.iac),
                        @intFromEnum(TelnetCommand.se),
                    });
                }
            },
            SLC => {
                // Special Line Character subnegotiation - minimal implementation
            },
            else => {
                // Unknown subnegotiation command
            },
        }
    }
};

/// Registry for dispatching Telnet option negotiations to appropriate handlers
/// Aggregates per-option handlers and serializes their negotiation responses.
/// The registry queues every generated command into a shared buffer so the peer
/// observes a coherent sequence (e.g. WILL echo followed by DO suppress-go-ahead).
/// Unsupported options fall through to the refusal helper, ensuring we respond
/// with RFC 1143-compliant mirror commands and never leave the state machine in
/// limbo.
pub const OptionHandlerRegistry = struct {
    echo_handler: EchoHandler,
    terminal_type_handler: TerminalTypeHandler,
    naws_handler: NAWSHandler,
    suppress_ga_handler: SuppressGoAheadHandler,
    linemode_handler: LinemodeHandler,

    /// Initialize option handler registry with terminal configuration
    /// 
    /// Parameters:
    /// - terminal_type: Terminal type string (e.g., "xterm", "vt100")
    /// - window_width: Initial terminal width in characters
    /// - window_height: Initial terminal height in characters
    pub fn init(terminal_type: []const u8, window_width: u16, window_height: u16) OptionHandlerRegistry {
        return OptionHandlerRegistry{
            .echo_handler = EchoHandler{},
            .terminal_type_handler = TerminalTypeHandler.init(terminal_type),
            .naws_handler = NAWSHandler.init(window_width, window_height),
            .suppress_ga_handler = SuppressGoAheadHandler{},
            .linemode_handler = LinemodeHandler{},
        };
    }

    /// Dispatch negotiation command to appropriate option handler
    /// Unsupported options are automatically refused with appropriate response
    pub fn handleNegotiation(self: *OptionHandlerRegistry, allocator: std.mem.Allocator, command: TelnetCommand, option: TelnetOption, response: *std.ArrayList(u8)) !void {
        switch (option) {
            .echo => switch (command) {
                .will => try EchoHandler.handleWill(allocator, response),
                .wont => try EchoHandler.handleWont(allocator, response),
                .do => try EchoHandler.handleDo(allocator, response),
                .dont => try EchoHandler.handleDont(allocator, response),
                else => {},
            },
            .terminal_type => switch (command) {
                .will => try TerminalTypeHandler.handleWill(allocator, response),
                .wont => try TerminalTypeHandler.handleWont(allocator, response),
                .do => try TerminalTypeHandler.handleDo(allocator, response),
                .dont => try TerminalTypeHandler.handleDont(allocator, response),
                else => {},
            },
            .naws => switch (command) {
                .will => try NAWSHandler.handleWill(allocator, response),
                .wont => try NAWSHandler.handleWont(allocator, response),
                .do => try self.naws_handler.handleDo(allocator, response),
                .dont => try NAWSHandler.handleDont(allocator, response),
                else => {},
            },
            .suppress_ga => switch (command) {
                .will => try SuppressGoAheadHandler.handleWill(allocator, response),
                .wont => try SuppressGoAheadHandler.handleWont(allocator, response),
                .do => try SuppressGoAheadHandler.handleDo(allocator, response),
                .dont => try SuppressGoAheadHandler.handleDont(allocator, response),
                else => {},
            },
            .linemode => switch (command) {
                .will => try LinemodeHandler.handleWill(allocator, response),
                .wont => try LinemodeHandler.handleWont(allocator, response),
                .do => try LinemodeHandler.handleDo(allocator, response),
                .dont => try LinemodeHandler.handleDont(allocator, response),
                else => {},
            },
            else => {
                // Refuse unsupported options
                // We map WILL→DONT and DO→WONT per RFC 1143's Q-method so
                // peers receive mirrored refusals and avoid negotiation loops.
                const refusal_cmd: TelnetCommand = switch (command) {
                    .will => .dont,
                    .do => .wont,
                    .wont, .dont => return,
                    else => return,
                };

                try response.appendSlice(allocator, &[_]u8{
                    @intFromEnum(TelnetCommand.iac),
                    @intFromEnum(refusal_cmd),
                    @intFromEnum(option),
                });
            },
        }
    }

    /// Dispatch subnegotiation to appropriate option handler
    pub fn handleSubnegotiation(self: *OptionHandlerRegistry, allocator: std.mem.Allocator, option: TelnetOption, data: []const u8, response: *std.ArrayList(u8)) !void {
        switch (option) {
            .terminal_type => try self.terminal_type_handler.handleSubnegotiation(allocator, data, response),
            .naws => {
                if (NAWSHandler.handleSubnegotiation(data)) |window_info| {
                    _ = window_info; // Store window size if needed
                }
            },
            .linemode => try LinemodeHandler.handleSubnegotiation(allocator, data, response),
            else => {
                // Ignore unsupported subnegotiation
            },
        }
    }

    /// Update window size and send NAWS subnegotiation to remote
    pub fn updateWindowSize(self: *OptionHandlerRegistry, allocator: std.mem.Allocator, width: u16, height: u16, response: *std.ArrayList(u8)) !void {
        try self.naws_handler.updateWindowSize(allocator, width, height, response);
    }
};
