//! # Terminal Control Package
//!
//! This package provides a set of modules for interacting with and controlling
//! the terminal (TTY). It encapsulates platform-specific logic for operations
//! like reading and setting terminal attributes, which is essential for features
//! such as disabling local echo (`-q` flag) or handling raw terminal I/O.
//!
//! ## Modules
//!
//! - `tty_state`: Manages the state of the terminal by storing and restoring
//!   `termios` attributes. This is crucial for ensuring the terminal is returned
//!   to its original state upon application exit.
//! - `tty_control`: Contains high-level functions for manipulating terminal
//!   behavior, such as `setNoEcho()`, which builds upon the state management
//!   provided by `tty_state`.

pub const tty_state = @import("tty_state.zig");
pub const tty_control = @import("tty_control.zig");