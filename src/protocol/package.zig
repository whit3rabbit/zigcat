//! # Network Protocol Package
//!
//! This package provides implementations and utilities for various network
//! protocols, with a primary focus on the Telnet protocol. It encapsulates
//! the logic for handling protocol-specific negotiations, command processing,
//! and data stream manipulation.
//!
//! ## Modules
//!
//! - `telnet`: Core Telnet constants and data structures.
//! - `telnet_options`: Defines Telnet option codes used in negotiations.
//! - `telnet_processor`: A state machine for parsing and interpreting Telnet
//!   command sequences within a data stream.
//! - `tty_*`: Re-exports of terminal control modules, which are often used in
//!   conjunction with Telnet to manage the local terminal state.

const terminal = @import("terminal");

pub const telnet = @import("telnet.zig");
pub const telnet_environ = @import("telnet_environ.zig");
pub const telnet_options = @import("telnet_options.zig");
pub const telnet_processor = @import("telnet_processor.zig");
pub const tty_state = terminal.tty_state;
pub const tty_control = terminal.tty_control;