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
const telnet_environ = @import("telnet_environ.zig");
const posix = std.posix;
const terminal = @import("terminal");
const tty_state = terminal.tty_state;
const tty_control = terminal.tty_control;

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;
const TelnetError = telnet.TelnetError;

/// Echo option handler implementing RFC 857 echo negotiation
pub const EchoHandler = struct {
    tty: ?*tty_state.TtyState = null,

    pub fn init(tty: ?*tty_state.TtyState) EchoHandler {
        return EchoHandler{
            .tty = tty,
        };
    }

    fn setLocalEcho(self: *EchoHandler, enable: bool) void {
        if (self.tty) |state| {
            tty_control.setLocalEcho(state, enable) catch {};
        }
    }

    /// Handle WILL echo from remote side - server will echo, client should disable local echo
    pub fn handleWill(self: *EchoHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        self.setLocalEcho(false);
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle DO echo request from remote side - client should enable local echo
    pub fn handleDo(self: *EchoHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        self.setLocalEcho(true);
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle WONT echo from remote side - we should handle echo locally
    pub fn handleWont(self: *EchoHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        self.setLocalEcho(true);
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.echo),
        });
    }

    /// Handle DONT echo from remote side - remote doesn't want us to echo
    pub fn handleDont(self: *EchoHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        self.setLocalEcho(false);
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

/// NEW-ENVIRON handler implementing RFC 1572
pub const NewEnvironHandler = struct {
    const NewEnviron = telnet_environ.NewEnviron;
    const FetchError = std.mem.Allocator.Error || std.process.GetEnvVarOwnedError;
    const FetchFn = *const fn (std.mem.Allocator, []const []const u8) FetchError!telnet_environ.Collection;

    const ALLOWED_VARS = [_][]const u8{
        "TERM",
        "USER",
        "LANG",
        "LC_ALL",
        "COLORTERM",
        "DISPLAY",
        "SYSTEMTYPE",
    };

    fetch_fn: FetchFn = defaultFetch,

    pub fn init() NewEnvironHandler {
        return .{};
    }

    pub fn handleWill(self: *NewEnvironHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        _ = self;
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.new_environ),
        });
    }

    pub fn handleDo(self: *NewEnvironHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        _ = self;
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.new_environ),
        });
    }

    pub fn handleWont(self: *NewEnvironHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        _ = self;
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.dont),
            @intFromEnum(TelnetOption.new_environ),
        });
    }

    pub fn handleDont(self: *NewEnvironHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        _ = self;
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.wont),
            @intFromEnum(TelnetOption.new_environ),
        });
    }

    pub fn handleSubnegotiation(
        self: *NewEnvironHandler,
        allocator: std.mem.Allocator,
        data: []const u8,
        response: *std.ArrayList(u8),
    ) !void {
        if (data.len == 0) return;

        switch (data[0]) {
            NewEnviron.SEND, NewEnviron.INFO => {
                var requested = try parseRequestedNames(allocator, data[1..]);
                defer freeRequestedNames(&requested, allocator);

                var requested_refs = std.ArrayList([]const u8){};
                defer requested_refs.deinit(allocator);
                for (requested.items) |name| {
                    try requested_refs.append(allocator, name);
                }

                var filtered = try filterAllowedNames(allocator, requested_refs.items);
                defer filtered.deinit(allocator);

                const desired = if (filtered.items.len > 0) filtered.items else ALLOWED_VARS[0..];

                var collection = try self.fetch_fn(allocator, desired);
                defer collection.deinit();

                const payload = try telnet_environ.buildIsResponse(allocator, collection.items());
                defer allocator.free(payload);

                try response.appendSlice(allocator, &[_]u8{
                    @intFromEnum(TelnetCommand.iac),
                    @intFromEnum(TelnetCommand.sb),
                    @intFromEnum(TelnetOption.new_environ),
                });
                try response.appendSlice(allocator, payload);
                try response.appendSlice(allocator, &[_]u8{
                    @intFromEnum(TelnetCommand.iac),
                    @intFromEnum(TelnetCommand.se),
                });
            },
            else => {},
        }
    }

    fn filterAllowedNames(
        allocator: std.mem.Allocator,
        names: []const []const u8,
    ) std.mem.Allocator.Error!std.ArrayList([]const u8) {
        var filtered = std.ArrayList([]const u8){};
        errdefer filtered.deinit(allocator);

        for (names) |name| {
            if (isAllowed(name)) {
                try filtered.append(allocator, name);
            }
        }

        return filtered;
    }

    fn parseRequestedNames(
        allocator: std.mem.Allocator,
        data: []const u8,
    ) std.mem.Allocator.Error!std.ArrayList([]u8) {
        var result = std.ArrayList([]u8){};
        errdefer freeRequestedNames(&result, allocator);

        var i: usize = 0;
        while (i < data.len) {
            const marker = data[i];
            i += 1;
            switch (marker) {
                NewEnviron.VAR, NewEnviron.USERVAR => {
                    var buffer = std.ArrayList(u8){};
                    defer buffer.deinit(allocator);

                    while (i < data.len) {
                        const b = data[i];
                        if (b == NewEnviron.VAR or b == NewEnviron.USERVAR or b == NewEnviron.VALUE) break;
                        if (b == NewEnviron.ESC) {
                            i += 1;
                            if (i >= data.len) break;
                            try buffer.append(allocator, data[i]);
                            i += 1;
                        } else {
                            try buffer.append(allocator, b);
                            i += 1;
                        }
                    }

                    const owned = try allocator.dupe(u8, buffer.items);
                    errdefer allocator.free(owned);
                    try result.append(allocator, owned);
                },
                NewEnviron.VALUE => {
                    while (i < data.len) {
                        const b = data[i];
                        if (b == NewEnviron.VAR or b == NewEnviron.USERVAR or b == NewEnviron.VALUE) break;
                        if (b == NewEnviron.ESC and i + 1 < data.len) {
                            i += 2;
                        } else {
                            i += 1;
                        }
                    }
                },
                NewEnviron.ESC => {
                    if (i < data.len) {
                        i += 1;
                    }
                },
                else => {},
            }
        }

        return result;
    }

    fn freeRequestedNames(list: *std.ArrayList([]u8), allocator: std.mem.Allocator) void {
        for (list.items) |name| {
            allocator.free(name);
        }
        list.deinit(allocator);
    }

    fn isAllowed(name: []const u8) bool {
        for (ALLOWED_VARS) |allowed| {
            if (std.mem.eql(u8, allowed, name)) {
                return true;
            }
        }
        return false;
    }

    fn defaultFetch(
        allocator: std.mem.Allocator,
        requested: []const []const u8,
    ) FetchError!telnet_environ.Collection {
        return telnet_environ.collectEnvironmentVariables(allocator, requested);
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
///
/// RFC 1184 defines three subnegotiation commands:
/// - MODE: Controls local line editing and signal processing
/// - FORWARDMASK: Specifies which characters trigger line forwarding
/// - SLC: Special Line Characters mapping for terminal control
pub const LinemodeHandler = struct {
    tty: ?*tty_state.TtyState,
    slc_values: [256]u8 = [_]u8{0xFF} ** 256,
    slc_flags: [256]u8 = [_]u8{0} ** 256,
    // Subnegotiation commands (RFC 1184 Section 3)
    const MODE: u8 = 1;
    const FORWARDMASK: u8 = 2;
    const SLC: u8 = 3;

    // MODE flags (RFC 1184 Section 4)
    const MODE_EDIT: u8 = 0x01; // Enable local line editing
    const MODE_TRAPSIG: u8 = 0x02; // Trap signals locally
    const MODE_ACK: u8 = 0x04; // Acknowledge mode change
    const MODE_SOFT_TAB: u8 = 0x08; // Expand tabs to spaces
    const MODE_LIT_ECHO: u8 = 0x10; // Literal echo (no editing)

    // SLC Function Codes - Control Functions (RFC 1184 Section 5)
    /// Synch signal (typically ^O)
    const SLC_SYNCH: u8 = 1;
    /// Break signal
    const SLC_BRK: u8 = 2;
    /// Interrupt Process (typically ^C)
    const SLC_IP: u8 = 3;
    /// Abort Output (typically ^O)
    const SLC_AO: u8 = 4;
    /// Are You There (typically ^T)
    const SLC_AYT: u8 = 5;
    /// End of Record
    const SLC_EOR: u8 = 6;
    /// Abort process (typically ^\)
    const SLC_ABORT: u8 = 7;
    /// End of File (typically ^D)
    const SLC_EOF: u8 = 8;
    /// Suspend process (typically ^Z)
    const SLC_SUSP: u8 = 9;

    // SLC Function Codes - Editing Functions (RFC 1184 Section 5)
    /// Erase Character (typically ^H or DEL)
    const SLC_EC: u8 = 10;
    /// Erase Line (typically ^U)
    const SLC_EL: u8 = 11;
    /// Erase Word (typically ^W)
    const SLC_EW: u8 = 12;
    /// Reprint line (typically ^R)
    const SLC_RP: u8 = 13;
    /// Literal Next - escape next character (typically ^V)
    const SLC_LNEXT: u8 = 14;
    /// Resume output (typically ^Q)
    const SLC_XON: u8 = 15;
    /// Stop output (typically ^S)
    const SLC_XOFF: u8 = 16;
    /// Forward 1 character
    const SLC_FORW1: u8 = 17;
    /// Forward 2 characters
    const SLC_FORW2: u8 = 18;

    // SLC Function Codes - Extended Cursor Movement (RFC 1184 Appendix)
    /// Move cursor left
    const SLC_MCL: u8 = 19;
    /// Move cursor right
    const SLC_MCR: u8 = 20;
    /// Move cursor word left
    const SLC_MCWL: u8 = 21;
    /// Move cursor word right
    const SLC_MCWR: u8 = 22;
    /// Move cursor to beginning of line
    const SLC_MCBOL: u8 = 23;
    /// Move cursor to end of line
    const SLC_MCEOL: u8 = 24;
    /// Toggle insert mode
    const SLC_INSRT: u8 = 25;
    /// Toggle overwrite mode
    const SLC_OVER: u8 = 26;
    /// Erase character to the right
    const SLC_ECR: u8 = 27;
    /// Erase word to the right
    const SLC_EWR: u8 = 28;
    /// Erase to beginning of line
    const SLC_EBOL: u8 = 29;
    /// Erase to end of line
    const SLC_EEOL: u8 = 30;

    // SLC Modifier Flags (RFC 1184 Section 5.2)
    /// Function not supported by implementation
    const SLC_NOSUPPORT: u8 = 0x00;
    /// Value cannot be changed
    const SLC_CANTCHANGE: u8 = 0x01;
    /// Current value provided
    const SLC_VALUE: u8 = 0x02;
    /// Use default value
    const SLC_DEFAULT: u8 = 0x03;
    /// Mask for extracting level bits
    const SLC_LEVELBITS: u8 = 0x03;
    /// Acknowledgment flag (bit 7)
    const SLC_ACK: u8 = 0x80;
    /// Flush input on this character (bit 6)
    const SLC_FLUSHIN: u8 = 0x40;
    /// Flush output on this character (bit 5)
    const SLC_FLUSHOUT: u8 = 0x20;

    /// Handle WILL linemode from remote side
    pub fn handleWill(allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.do),
            @intFromEnum(TelnetOption.linemode),
        });
    }

    /// Handle DO linemode request from remote side - sends preferred linemode settings
    pub fn handleDo(self: *LinemodeHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.will),
            @intFromEnum(TelnetOption.linemode),
        });

        try self.sendLinemodeSettings(allocator, response);
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
    pub fn sendLinemodeSettings(self: *LinemodeHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.sb),
            @intFromEnum(TelnetOption.linemode),
            MODE,
            MODE_EDIT | MODE_TRAPSIG,
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.se),
        });

        try self.sendSlcTable(allocator, response);
    }

    /// Handle linemode subnegotiation commands (MODE, FORWARDMASK, SLC)
    pub fn handleSubnegotiation(self: *LinemodeHandler, allocator: std.mem.Allocator, data: []const u8, response: *std.ArrayList(u8)) !void {
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
            SLC => try self.handleSlcSubnegotiation(data[1..]),
            else => {
                // Unknown subnegotiation command
            },
        }
    }

    fn sendSlcTable(self: *LinemodeHandler, allocator: std.mem.Allocator, response: *std.ArrayList(u8)) !void {
        const termios_opt = if (self.tty) |tty| tty.ops.tcgetattr(tty.fd) catch null else null;
        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.sb),
            @intFromEnum(TelnetOption.linemode),
            SLC,
        });

        const Binding = struct { func: u8, name: []const u8, flush: u8 = 0 };
        const bindings = [_]Binding{
            .{ .func = SLC_IP, .name = "INTR", .flush = SLC_FLUSHIN | SLC_FLUSHOUT },
            .{ .func = SLC_ABORT, .name = "QUIT", .flush = SLC_FLUSHIN | SLC_FLUSHOUT },
            .{ .func = SLC_EOF, .name = "EOF" },
            .{ .func = SLC_EC, .name = "ERASE" },
            .{ .func = SLC_EL, .name = "KILL" },
            .{ .func = SLC_EW, .name = "WERASE" },
            .{ .func = SLC_RP, .name = "REPRINT" },
            .{ .func = SLC_LNEXT, .name = "LNEXT" },
            .{ .func = SLC_XON, .name = "START" },
            .{ .func = SLC_XOFF, .name = "STOP" },
            .{ .func = SLC_AYT, .name = "STATUS" },
        };

        inline for (bindings) |binding| {
            if (!@hasField(posix.V, binding.name)) continue;
            const cc_enum = @field(posix.V, binding.name);
            const value_opt = if (termios_opt) |term| getControlChar(term, cc_enum) else null;
            const flags: u8 = if (value_opt) |_| (SLC_VALUE | binding.flush) else SLC_NOSUPPORT;
            const char_value: u8 = value_opt orelse 0;
            self.slc_flags[binding.func] = flags;
            self.slc_values[binding.func] = char_value;
            try appendSlcTriplet(allocator, response, binding.func, flags, char_value);
        }

        try response.appendSlice(allocator, &[_]u8{
            @intFromEnum(TelnetCommand.iac),
            @intFromEnum(TelnetCommand.se),
        });
    }

    fn getControlChar(termios_value: posix.termios, cc: posix.V) ?u8 {
        const idx = @intFromEnum(cc);
        if (idx >= termios_value.cc.len) return null;
        const val = termios_value.cc[idx];
        return if (val == 0 or val == 0xFF) null else val;
    }

    fn appendSlcTriplet(allocator: std.mem.Allocator, response: *std.ArrayList(u8), func: u8, flags: u8, value: u8) !void {
        try response.append(allocator, func);
        try response.append(allocator, flags);
        if (value == 0xFF) {
            try response.appendSlice(allocator, &[_]u8{ 0xFF, 0xFF });
        } else {
            try response.append(allocator, value);
        }
    }

    pub fn init(local_tty: ?*tty_state.TtyState) LinemodeHandler {
        return .{ .tty = local_tty };
    }

    fn handleSlcSubnegotiation(self: *LinemodeHandler, payload: []const u8) !void {
        var i: usize = 0;
        while (i < payload.len) {
            const func = payload[i];
            if (func == 0) break;
            if (i + 1 >= payload.len) break;
            const flags = payload[i + 1];
            const value_index = i + 2;
            if (value_index >= payload.len) break;
            const value = payload[value_index];
            var consumed: usize = 3;
            if (value == 0xFF and value_index + 1 < payload.len and payload[value_index + 1] == 0xFF) {
                consumed = 4;
            }

            self.slc_flags[func] = flags;
            if (flags & SLC_NOSUPPORT != 0) {
                self.slc_values[func] = 0xFF;
            } else if (flags & SLC_ACK == 0) {
                self.slc_values[func] = value;
            }

            i += consumed;
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
    new_environ_handler: NewEnvironHandler,

    /// Initialize option handler registry with terminal configuration
    ///
    /// Parameters:
    /// - terminal_type: Terminal type string (e.g., "xterm", "vt100")
    /// - window_width: Initial terminal width in characters
    /// - window_height: Initial terminal height in characters
    pub fn init(terminal_type: []const u8, window_width: u16, window_height: u16, local_tty: ?*tty_state.TtyState) OptionHandlerRegistry {
        return OptionHandlerRegistry{
            .echo_handler = EchoHandler.init(local_tty),
            .terminal_type_handler = TerminalTypeHandler.init(terminal_type),
            .naws_handler = NAWSHandler.init(window_width, window_height),
            .suppress_ga_handler = SuppressGoAheadHandler{},
            .linemode_handler = LinemodeHandler.init(local_tty),
            .new_environ_handler = NewEnvironHandler.init(),
        };
    }

    /// Dispatch negotiation command to appropriate option handler
    /// Unsupported options are automatically refused with appropriate response
    pub fn handleNegotiation(self: *OptionHandlerRegistry, allocator: std.mem.Allocator, command: TelnetCommand, option: TelnetOption, response: *std.ArrayList(u8)) !void {
        switch (option) {
            .echo => switch (command) {
                .will => try self.echo_handler.handleWill(allocator, response),
                .wont => try self.echo_handler.handleWont(allocator, response),
                .do => try self.echo_handler.handleDo(allocator, response),
                .dont => try self.echo_handler.handleDont(allocator, response),
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
                .do => try self.linemode_handler.handleDo(allocator, response),
                .dont => try LinemodeHandler.handleDont(allocator, response),
                else => {},
            },
            .new_environ => switch (command) {
                .will => try self.new_environ_handler.handleWill(allocator, response),
                .wont => try self.new_environ_handler.handleWont(allocator, response),
                .do => try self.new_environ_handler.handleDo(allocator, response),
                .dont => try self.new_environ_handler.handleDont(allocator, response),
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
            .linemode => try self.linemode_handler.handleSubnegotiation(allocator, data, response),
            .new_environ => try self.new_environ_handler.handleSubnegotiation(allocator, data, response),
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
