//! This module provides high-level functions for controlling terminal (TTY)
//! behavior. It abstracts the low-level `termios` manipulations to offer
//! simple, safe APIs for common terminal operations like enabling raw mode or
//! toggling local echo.
//!
//! All functions operate on a `TtyState` object, which must be initialized
//! with the original terminal settings before any modifications are made. This
//! ensures that the terminal can be reliably restored to its original state.
//! The functions are platform-dependent and will return `UnsupportedPlatform`
//! on systems that do not provide a `termios`-compatible interface (e.g., Windows).

const std = @import("std");
const posix = std.posix;

const tty_state = @import("tty_state.zig");

const has_termios = @hasDecl(posix, "tcgetattr");

pub const TtyError = if (has_termios)
    posix.TermiosGetError || posix.TermiosSetError || error{TermiosNotSaved}
else
    error{UnsupportedPlatform};

/// Saves the current terminal attributes to the `TtyState` object.
///
/// This function must be called before any other terminal modifications are made.
/// It retrieves the current `termios` settings and stores them in the
/// `original_termios` field of the provided state object. This saved state is
/// essential for restoring the terminal later.
///
/// - `state`: A pointer to the `TtyState` object where the original settings
///   will be stored.
///
/// Returns an error if the file descriptor is not a TTY or if the attributes
/// cannot be retrieved.
pub fn saveOriginalTermios(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.ops.isatty(state.fd)) {
        return error.NotATerminal;
    }

    const original = try state.ops.tcgetattr(state.fd);
    state.original_termios = original;
    state.is_raw = false;
}

/// Enables raw mode for the terminal.
///
/// Raw mode disables input processing features like echoing, canonical mode
/// (line buffering), and signal generation (e.g., Ctrl-C). This is useful
/// for applications that need to process key presses individually and immediately.
/// The original terminal settings must be saved via `saveOriginalTermios` first.
///
/// - `state`: A pointer to the `TtyState` object managing the terminal.
///
/// Returns an error if the original settings were not saved or if the new
/// attributes cannot be applied.
pub fn enableRawMode(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (state.is_raw) return;

    const original = state.original_termios orelse return error.TermiosNotSaved;

    var raw = original;
    inline for (.{ "BRKINT", "ICRNL", "INPCK", "ISTRIP", "IXON" }) |flag| {
        setBoolFlag(&raw.iflag, flag, false);
    }

    setBoolFlag(&raw.oflag, "OPOST", false);

    if (@hasField(@TypeOf(raw.cflag), "CSIZE")) {
        const FieldType = @TypeOf(@field(raw.cflag, "CSIZE"));
        if (@hasField(FieldType, "CS8")) {
            @field(raw.cflag, "CSIZE") = FieldType.CS8;
        }
    }

    inline for (.{ "ECHO", "ICANON", "IEXTEN", "ISIG" }) |flag| {
        setBoolFlag(&raw.lflag, flag, false);
    }
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try state.ops.tcsetattr(state.fd, .FLUSH, raw);
    state.is_raw = true;
}

/// Disables raw mode by restoring the original terminal settings.
///
/// This function is a convenience wrapper around `restoreOriginalTermios`. It
/// should be called to exit raw mode and return the terminal to its normal,
/// cooked state. It does nothing if raw mode is not currently active.
///
/// - `state`: A pointer to the `TtyState` object managing the terminal.
///
/// Returns an error if the original settings cannot be restored.
pub fn disableRawMode(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.is_raw) return;
    try restoreOriginalTermios(state);
}

/// Restores the terminal to its original saved state.
///
/// This function applies the `termios` settings that were saved by
/// `saveOriginalTermios`. It is critical for ensuring the terminal behaves
/// correctly after the application exits. It also marks the TTY state as
/// no longer being in raw mode.
///
/// - `state`: A pointer to the `TtyState` object containing the original settings.
///
/// Returns an error if the original settings were not saved or cannot be applied.
pub fn restoreOriginalTermios(state: *tty_state.TtyState) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    if (!state.is_raw) return;

    const original = state.original_termios orelse return error.TermiosNotSaved;
    try state.ops.tcsetattr(state.fd, .FLUSH, original);
    state.is_raw = false;
}

/// Enables or disables local echo on the terminal.
///
/// This function modifies the `ECHO` flag in the terminal's `lflag` settings.
/// When echo is disabled, characters typed by the user are not automatically
/// displayed on the screen. The original terminal settings must be saved first.
///
/// - `state`: A pointer to the `TtyState` object managing the terminal.
/// - `enable`: `true` to enable local echo, `false` to disable it.
///
/// Returns an error if the terminal attributes cannot be read or written.
pub fn setLocalEcho(state: *tty_state.TtyState, enable: bool) TtyError!void {
    if (!has_termios) {
        return error.UnsupportedPlatform;
    }

    _ = state.original_termios orelse return error.TermiosNotSaved;

    var term = try state.ops.tcgetattr(state.fd);

    setBoolFlag(&term.lflag, "ECHO", enable);

    try state.ops.tcsetattr(state.fd, .NOW, term);
}

fn setBoolFlag(ptr: anytype, comptime name: []const u8, value: bool) void {
    if (@hasField(@TypeOf(ptr.*), name)) {
        @field(ptr.*, name) = value;
    }
}
