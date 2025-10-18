// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! ANSI/VT100 escape sequence parser implementing Paul Williams' state machine.
//!
//! This module provides a streaming parser for ANSI escape codes, supporting:
//! - VT100 core sequences (SGR, cursor movement, erase functions)
//! - xterm extensions (256-color, true-color, SGR mouse tracking)
//! - Robust error handling with pass-through for invalid sequences
//!
//! The parser implements the canonical state machine from vt100.net:
//! https://vt100.net/emu/dec_ansi_parser
//!
//! Key features:
//! - Streaming: Maintains state across buffer boundaries
//! - Complete: Handles all character ranges and transitions
//! - Resilient: Gracefully handles malformed input
//! - Zero-copy: Uses callbacks instead of buffering (except OSC strings)

const std = @import("std");

/// Parser states following Paul Williams' VT100 state machine
pub const State = enum {
    /// Initial state, processing normal data
    ground,
    /// Received ESC, waiting for next character
    escape,
    /// Collecting intermediate characters in escape sequence
    escape_intermediate,
    /// Entered CSI sequence, processing first character
    csi_entry,
    /// Collecting parameter bytes in CSI sequence
    csi_param,
    /// Collecting intermediate bytes in CSI sequence
    csi_intermediate,
    /// Ignoring malformed CSI sequence
    csi_ignore,
    /// Entered DCS (Device Control String)
    dcs_entry,
    /// Collecting DCS parameters
    dcs_param,
    /// Collecting DCS intermediate bytes
    dcs_intermediate,
    /// Passing through DCS data to handler
    dcs_passthrough,
    /// Ignoring malformed DCS
    dcs_ignore,
    /// Collecting OSC (Operating System Command) string
    osc_string,
    /// Collecting SOS/PM/APC string
    sos_pm_apc_string,
};

/// Handler interface for parser actions
///
/// Clients implement this interface to receive parsed events.
/// All callbacks are optional (can be null if not needed).
pub const Handler = struct {
    /// Print a displayable character to the screen
    print_fn: ?*const fn (ctx: *anyopaque, ch: u8) void = null,

    /// Execute a C0 or C1 control function
    execute_fn: ?*const fn (ctx: *anyopaque, ch: u8) void = null,

    /// CSI sequence completed
    csi_dispatch_fn: ?*const fn (
        ctx: *anyopaque,
        params: []const u16,
        intermediates: []const u8,
        private_marker: u8,
        final: u8,
    ) void = null,

    /// Escape sequence completed
    esc_dispatch_fn: ?*const fn (
        ctx: *anyopaque,
        intermediates: []const u8,
        final: u8,
    ) void = null,

    /// OSC string completed
    osc_dispatch_fn: ?*const fn (ctx: *anyopaque, data: []const u8) void = null,

    /// DCS sequence started, establish handler channel
    hook_fn: ?*const fn (
        ctx: *anyopaque,
        params: []const u16,
        intermediates: []const u8,
        private_marker: u8,
        final: u8,
    ) void = null,

    /// Pass DCS data character to handler
    put_fn: ?*const fn (ctx: *anyopaque, ch: u8) void = null,

    /// DCS sequence terminated, close handler channel
    unhook_fn: ?*const fn (ctx: *anyopaque) void = null,

    /// Opaque context pointer passed to all callbacks
    context: *anyopaque,

    pub fn print(self: *const Handler, ch: u8) void {
        if (self.print_fn) |f| f(self.context, ch);
    }

    pub fn execute(self: *const Handler, ch: u8) void {
        if (self.execute_fn) |f| f(self.context, ch);
    }

    pub fn csiDispatch(
        self: *const Handler,
        params: []const u16,
        intermediates: []const u8,
        private_marker: u8,
        final: u8,
    ) void {
        if (self.csi_dispatch_fn) |f| f(self.context, params, intermediates, private_marker, final);
    }

    pub fn escDispatch(self: *const Handler, intermediates: []const u8, final: u8) void {
        if (self.esc_dispatch_fn) |f| f(self.context, intermediates, final);
    }

    pub fn oscDispatch(self: *const Handler, data: []const u8) void {
        if (self.osc_dispatch_fn) |f| f(self.context, data);
    }

    pub fn hook(
        self: *const Handler,
        params: []const u16,
        intermediates: []const u8,
        private_marker: u8,
        final: u8,
    ) void {
        if (self.hook_fn) |f| f(self.context, params, intermediates, private_marker, final);
    }

    pub fn put(self: *const Handler, ch: u8) void {
        if (self.put_fn) |f| f(self.context, ch);
    }

    pub fn unhook(self: *const Handler) void {
        if (self.unhook_fn) |f| f(self.context);
    }
};

/// ANSI escape sequence parser
pub const Parser = struct {
    /// Current parser state
    state: State = .ground,

    /// Parameter storage (up to 16 parameters per sequence)
    params: [16]u16 = [_]u16{0} ** 16,
    param_idx: u8 = 0,
    current_param: u16 = 0,

    /// Intermediate character storage (up to 2 bytes)
    intermediates: [2]u8 = [_]u8{0} ** 2,
    intermediate_idx: u8 = 0,

    /// Private marker for CSI sequences (0x3C-0x3F)
    private_marker: u8 = 0,

    /// OSC/SOS/PM/APC string buffer
    osc_buffer: std.ArrayList(u8),

    /// Handler for parser events
    handler: Handler,

    /// Allocator for OSC buffer
    allocator: std.mem.Allocator,

    /// Maximum OSC string length (prevent DoS)
    const MAX_OSC_LENGTH: usize = 4096;

    /// Maximum parameter value (cap to prevent overflow)
    const MAX_PARAM_VALUE: u16 = 9999;

    pub fn init(allocator: std.mem.Allocator, handler: Handler) Parser {
        return .{
            .osc_buffer = std.ArrayList(u8).init(allocator),
            .handler = handler,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.osc_buffer.deinit();
    }

    /// Parse a buffer of data through the state machine
    ///
    /// The parser maintains state across calls, so incomplete sequences
    /// at buffer boundaries are automatically handled.
    pub fn parse(self: *Parser, data: []const u8) !void {
        for (data) |byte| {
            try self.processChar(byte);
        }
    }

    /// Process a single character through the state machine
    fn processChar(self: *Parser, ch: u8) !void {
        // ANYWHERE transitions (highest priority, can occur from any state)
        switch (ch) {
            0x18, 0x1A => { // CAN (Cancel), SUB (Substitute)
                // Immediately terminate current sequence and return to ground
                self.reset();
                self.handler.execute(ch);
                return;
            },
            0x1B => { // ESC (Escape)
                // Cancel current sequence (except in DCS_PASSTHROUGH/string states)
                if (self.state != .dcs_passthrough and
                    self.state != .osc_string and
                    self.state != .sos_pm_apc_string)
                {
                    self.clear();
                    self.state = .escape;
                    return;
                }
            },
            else => {},
        }

        // C0 controls (0x00-0x1F) execute immediately in most states
        if (ch < 0x20 and ch != 0x18 and ch != 0x1A and ch != 0x1B) {
            // Execute immediately, but don't change state (except in string states)
            if (self.state == .osc_string or self.state == .sos_pm_apc_string) {
                // In string states, some C0 controls terminate the string
                if (ch == 0x07) { // BEL terminates OSC/SOS/PM/APC
                    if (self.state == .osc_string) {
                        self.handler.oscDispatch(self.osc_buffer.items);
                    }
                    self.state = .ground;
                    return;
                }
                // Other C0 controls are collected in the string
            } else {
                self.handler.execute(ch);
                return;
            }
        }

        // C1 controls (0x80-0x9F) - 8-bit sequences
        if (ch >= 0x80 and ch <= 0x9F) {
            return self.handleC1(ch);
        }

        // State-specific transitions
        switch (self.state) {
            .ground => try self.handleGround(ch),
            .escape => try self.handleEscape(ch),
            .escape_intermediate => try self.handleEscapeIntermediate(ch),
            .csi_entry => try self.handleCsiEntry(ch),
            .csi_param => try self.handleCsiParam(ch),
            .csi_intermediate => try self.handleCsiIntermediate(ch),
            .csi_ignore => try self.handleCsiIgnore(ch),
            .dcs_entry => try self.handleDcsEntry(ch),
            .dcs_param => try self.handleDcsParam(ch),
            .dcs_intermediate => try self.handleDcsIntermediate(ch),
            .dcs_passthrough => try self.handleDcsPassthrough(ch),
            .dcs_ignore => try self.handleDcsIgnore(ch),
            .osc_string => try self.handleOscString(ch),
            .sos_pm_apc_string => try self.handleSosPmApcString(ch),
        }
    }

    // State handlers

    fn handleGround(self: *Parser, ch: u8) !void {
        if (ch >= 0x20) { // Printable character
            self.handler.print(ch);
        }
    }

    fn handleEscape(self: *Parser, ch: u8) !void {
        switch (ch) {
            '[' => { // CSI - Control Sequence Introducer
                self.clear();
                self.state = .csi_entry;
            },
            'P' => { // DCS - Device Control String
                self.clear();
                self.state = .dcs_entry;
            },
            ']' => { // OSC - Operating System Command
                self.osc_buffer.clearRetainingCapacity();
                self.state = .osc_string;
            },
            'X', '^', '_' => { // SOS, PM, APC
                self.osc_buffer.clearRetainingCapacity();
                self.state = .sos_pm_apc_string;
            },
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
                self.state = .escape_intermediate;
            },
            0x30...0x7E => { // Final character
                self.handler.escDispatch(self.getIntermediates(), ch);
                self.state = .ground;
            },
            else => {
                // Invalid - ignore and return to ground
                self.state = .ground;
            },
        }
    }

    fn handleEscapeIntermediate(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
            },
            0x30...0x7E => { // Final character
                self.handler.escDispatch(self.getIntermediates(), ch);
                self.state = .ground;
            },
            else => {
                // Invalid - ignore and return to ground
                self.state = .ground;
            },
        }
    }

    fn handleCsiEntry(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x3C...0x3F => { // Private marker (< = > ?)
                self.private_marker = ch;
                self.state = .csi_param;
            },
            0x30...0x39, ':' => { // Digit or colon
                self.param(ch);
                self.state = .csi_param;
            },
            ';' => { // Parameter separator
                self.pushParam();
                self.state = .csi_param;
            },
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
                self.state = .csi_intermediate;
            },
            0x40...0x7E => { // Final character
                self.handler.csiDispatch(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .ground;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .csi_ignore;
            },
        }
    }

    fn handleCsiParam(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x30...0x39, ':' => { // Digit or colon
                self.param(ch);
            },
            ';' => { // Parameter separator
                self.pushParam();
            },
            0x20...0x2F => { // Intermediate character
                self.pushParam();
                self.collect(ch);
                self.state = .csi_intermediate;
            },
            0x40...0x7E => { // Final character
                self.pushParam();
                self.handler.csiDispatch(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .ground;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .csi_ignore;
            },
        }
    }

    fn handleCsiIntermediate(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
            },
            0x40...0x7E => { // Final character
                self.handler.csiDispatch(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .ground;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .csi_ignore;
            },
        }
    }

    fn handleCsiIgnore(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x40...0x7E => { // Final character - return to ground
                self.state = .ground;
            },
            else => {
                // Continue ignoring
            },
        }
    }

    fn handleDcsEntry(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x3C...0x3F => { // Private marker
                self.private_marker = ch;
                self.state = .dcs_param;
            },
            0x30...0x39, ':' => { // Digit or colon
                self.param(ch);
                self.state = .dcs_param;
            },
            ';' => { // Parameter separator
                self.pushParam();
                self.state = .dcs_param;
            },
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
                self.state = .dcs_intermediate;
            },
            0x40...0x7E => { // Final character
                self.handler.hook(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .dcs_passthrough;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .dcs_ignore;
            },
        }
    }

    fn handleDcsParam(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x30...0x39, ':' => { // Digit or colon
                self.param(ch);
            },
            ';' => { // Parameter separator
                self.pushParam();
            },
            0x20...0x2F => { // Intermediate character
                self.pushParam();
                self.collect(ch);
                self.state = .dcs_intermediate;
            },
            0x40...0x7E => { // Final character
                self.pushParam();
                self.handler.hook(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .dcs_passthrough;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .dcs_ignore;
            },
        }
    }

    fn handleDcsIntermediate(self: *Parser, ch: u8) !void {
        switch (ch) {
            0x20...0x2F => { // Intermediate character
                self.collect(ch);
            },
            0x40...0x7E => { // Final character
                self.handler.hook(
                    self.getParams(),
                    self.getIntermediates(),
                    self.private_marker,
                    ch,
                );
                self.state = .dcs_passthrough;
            },
            else => {
                // Invalid - transition to ignore state
                self.state = .dcs_ignore;
            },
        }
    }

    fn handleDcsPassthrough(self: *Parser, ch: u8) !void {
        // In DCS passthrough, ESC is handled specially
        if (ch == 0x1B) {
            // ESC in DCS data - could be start of ST terminator
            // Let processChar handle it on next call
            return;
        }

        // Check for ST terminator (ESC \)
        // This is handled by the ANYWHERE check for ESC

        // Pass character to DCS handler
        self.handler.put(ch);
    }

    fn handleDcsIgnore(self: *Parser, ch: u8) !void {
        // Ignore characters until we see ESC (handled by ANYWHERE)
        _ = ch;
    }

    fn handleOscString(self: *Parser, ch: u8) !void {
        // OSC strings are terminated by BEL (0x07) or ST (ESC \)
        // BEL is handled at the top of processChar
        // ST (ESC \) - ESC is handled by ANYWHERE, \ is checked here

        if (ch == '\\' and self.osc_buffer.items.len > 0) {
            // Check if previous character was ESC (would have been added to buffer)
            const last_idx = self.osc_buffer.items.len - 1;
            if (self.osc_buffer.items[last_idx] == 0x1B) {
                // Remove the ESC and dispatch
                _ = self.osc_buffer.pop();
                self.handler.oscDispatch(self.osc_buffer.items);
                self.state = .ground;
                return;
            }
        }

        // Collect character in OSC buffer
        if (self.osc_buffer.items.len < MAX_OSC_LENGTH) {
            try self.osc_buffer.append(ch);
        } else {
            // Buffer full - terminate and dispatch what we have
            self.handler.oscDispatch(self.osc_buffer.items);
            self.state = .ground;
        }
    }

    fn handleSosPmApcString(self: *Parser, ch: u8) !void {
        // SOS/PM/APC strings are terminated by ST (ESC \)
        // We collect but don't dispatch (these are rarely used)

        if (ch == '\\' and self.osc_buffer.items.len > 0) {
            const last_idx = self.osc_buffer.items.len - 1;
            if (self.osc_buffer.items[last_idx] == 0x1B) {
                // ST terminator - discard and return to ground
                self.state = .ground;
                return;
            }
        }

        // Collect character (but don't grow beyond limit)
        if (self.osc_buffer.items.len < MAX_OSC_LENGTH) {
            try self.osc_buffer.append(ch);
        }
    }

    fn handleC1(self: *Parser, ch: u8) !void {
        // C1 controls (8-bit sequences)
        // Cancel any sequence in progress and handle as immediate control

        switch (ch) {
            0x84 => { // IND - Index
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x85 => { // NEL - Next Line
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x88 => { // HTS - Horizontal Tab Set
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x8D => { // RI - Reverse Index
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x8E => { // SS2 - Single Shift 2
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x8F => { // SS3 - Single Shift 3
                self.handler.execute(ch);
                self.state = .ground;
            },
            0x90 => { // DCS - Device Control String
                self.clear();
                self.state = .dcs_entry;
            },
            0x9B => { // CSI - Control Sequence Introducer
                self.clear();
                self.state = .csi_entry;
            },
            0x9C => { // ST - String Terminator
                // Terminates OSC/DCS/SOS/PM/APC
                if (self.state == .osc_string) {
                    self.handler.oscDispatch(self.osc_buffer.items);
                } else if (self.state == .dcs_passthrough) {
                    self.handler.unhook();
                }
                self.state = .ground;
            },
            0x9D => { // OSC - Operating System Command
                self.osc_buffer.clearRetainingCapacity();
                self.state = .osc_string;
            },
            0x98, 0x9E, 0x9F => { // SOS, PM, APC
                self.osc_buffer.clearRetainingCapacity();
                self.state = .sos_pm_apc_string;
            },
            else => {
                // Other C1 controls - execute and continue
                self.handler.execute(ch);
            },
        }
    }

    // Helper functions

    /// Clear all parser state except the current state enum
    fn clear(self: *Parser) void {
        self.params = [_]u16{0} ** 16;
        self.param_idx = 0;
        self.current_param = 0;
        self.intermediates = [_]u8{0} ** 2;
        self.intermediate_idx = 0;
        self.private_marker = 0;
    }

    /// Reset parser to ground state
    fn reset(self: *Parser) void {
        self.clear();
        self.state = .ground;
    }

    /// Collect an intermediate character
    fn collect(self: *Parser, ch: u8) void {
        if (self.intermediate_idx < self.intermediates.len) {
            self.intermediates[self.intermediate_idx] = ch;
            self.intermediate_idx += 1;
        }
    }

    /// Process a parameter character (digit or colon)
    fn param(self: *Parser, ch: u8) void {
        if (ch >= '0' and ch <= '9') {
            // Accumulate digit into current parameter
            self.current_param = self.current_param *% 10 +% (ch - '0');
            if (self.current_param > MAX_PARAM_VALUE) {
                self.current_param = MAX_PARAM_VALUE;
            }
        }
        // Note: colon (:) is used in some sequences but we don't process it specially yet
    }

    /// Push current parameter to parameter array
    fn pushParam(self: *Parser) void {
        if (self.param_idx < self.params.len) {
            self.params[self.param_idx] = self.current_param;
            self.param_idx += 1;
            self.current_param = 0;
        }
    }

    /// Get slice of collected parameters
    fn getParams(self: *const Parser) []const u16 {
        return self.params[0..self.param_idx];
    }

    /// Get slice of collected intermediate characters
    fn getIntermediates(self: *const Parser) []const u8 {
        return self.intermediates[0..self.intermediate_idx];
    }

    /// Get current parser state (for testing/debugging)
    pub fn getState(self: *const Parser) State {
        return self.state;
    }
};
