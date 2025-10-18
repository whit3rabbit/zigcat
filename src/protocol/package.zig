//! # Network Protocol Package
//!
//! This package provides implementations and utilities for various network
//! protocols, with a primary focus on the Telnet protocol and ANSI escape
//! code processing. It encapsulates the logic for handling protocol-specific
//! negotiations, command processing, and data stream manipulation.
//!
//! ## Modules
//!
//! ### Telnet Protocol
//! - `telnet`: Core Telnet constants and data structures.
//! - `telnet_options`: Defines Telnet option codes used in negotiations.
//! - `telnet_processor`: A state machine for parsing and interpreting Telnet
//!   command sequences within a data stream.
//! - `telnet_environ`: NEW-ENVIRON option support for environment variable passing.
//!
//! ### ANSI/VT100 Escape Sequences
//! - `ansi_parser`: Paul Williams' VT100 state machine for parsing ANSI escape codes.
//! - `ansi_commands`: Command dispatchers for SGR, cursor movement, erase functions, mouse tracking.
//! - `ansi_state`: Terminal state tracking for active rendering mode.
//!
//! ### Terminal Control
//! - `tty_*`: Re-exports of terminal control modules, which are often used in
//!   conjunction with Telnet to manage the local terminal state.

const terminal = @import("terminal");

// Telnet protocol
pub const telnet = @import("telnet.zig");
pub const telnet_environ = @import("telnet_environ.zig");
pub const telnet_options = @import("telnet_options.zig");
pub const telnet_processor = @import("telnet_processor.zig");

// ANSI/VT100 escape sequence parsing
pub const ansi_parser = @import("ansi_parser.zig");
pub const ansi_commands = @import("ansi_commands.zig");
pub const ansi_state = @import("ansi_state.zig");

// Terminal control
pub const tty_state = terminal.tty_state;
pub const tty_control = terminal.tty_control;