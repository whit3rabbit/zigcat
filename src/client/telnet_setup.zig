// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Telnet client setup and configuration.
//!
//! This module handles the platform-specific setup required for Telnet client mode:
//! - TTY raw mode configuration (disables local echo, enables character-at-a-time input)
//! - Signal translation (SIGINT/TERM/QUIT → Telnet IAC IP/AO/BRK)
//! - SIGWINCH tracking (terminal window resize → Telnet NAWS negotiation)
//! - Initial window size detection (via ioctl TIOCGWINSZ)
//!
//! This setup is required for interactive Telnet sessions where local terminal
//! control characters need to be sent to the remote server instead of being
//! processed locally.
//!
//! Architecture:
//! - Separates TTY/signal configuration from protocol handling (src/protocol/telnet_connection.zig)
//! - Reusable by both client and server modes
//! - Clean teardown on exit (restores original terminal state and signal handlers)

const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const tty_state = @import("terminal").tty_state;
const tty_control = @import("terminal").tty_control;
const signal_handler = @import("terminal").signal_handler;
const signal_translation = @import("terminal").signal_translation;

/// Telnet client setup configuration.
///
/// Manages TTY state, signal handlers, and window size detection for
/// interactive Telnet sessions. Must be initialized before creating
/// TelnetConnection and deinitialized on cleanup.
///
/// Lifecycle:
/// 1. init() - Detect TTY, enable raw mode, install signal handlers
/// 2. Use local_tty_ptr, window_width, window_height to configure TelnetConnection
/// 3. deinit() - Restore terminal state and signal handlers
pub const TelnetSetup = struct {
    /// Local TTY state (null if stdin is not a TTY or raw mode unsupported)
    local_tty_state: ?tty_state.TtyState = null,

    /// Whether signal translation is active (SIGINT → Telnet IP, etc.)
    signal_translation_active: bool = false,

    /// Initial terminal window width (null if unknown)
    window_width: ?u16 = null,

    /// Initial terminal window height (null if unknown)
    window_height: ?u16 = null,

    /// Initialize Telnet setup for client mode.
    ///
    /// This function:
    /// 1. Detects if stdin is a TTY
    /// 2. Enables raw mode (disables local echo, line buffering)
    /// 3. Installs signal translation handlers (if requested)
    /// 4. Detects initial window size (if SIGWINCH supported)
    ///
    /// Parameters:
    ///   allocator: Memory allocator (currently unused, reserved for future use)
    ///   cfg: Configuration with telnet_signal_mode and telnet_edit_mode
    ///
    /// Returns: TelnetSetup with initialized state
    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !TelnetSetup {
        _ = allocator; // Reserved for future use

        var setup = TelnetSetup{};

        // Step 1: Attempt to enable TTY raw mode
        setup.local_tty_state = blk: {
            if (!tty_state.supportsRawMode()) {
                logging.logWarning("Telnet raw mode not supported on this platform; continuing without TTY control\n", .{});
                break :blk null;
            }

            const stdin_file = std.fs.File.stdin();
            var tty_candidate = tty_state.init(stdin_file.handle);

            if (!tty_state.isTerminal(&tty_candidate)) {
                logging.logWarning("Standard input is not a TTY; Telnet raw mode disabled\n", .{});
                break :blk null;
            }

            // Save original terminal settings
            tty_control.saveOriginalTermios(&tty_candidate) catch |err| {
                if (err == error.NotATerminal) {
                    logging.logWarning("Standard input is not a TTY; Telnet raw mode disabled\n", .{});
                    break :blk null;
                }
                return err;
            };

            // Enable raw mode (disables echo, line buffering, etc.)
            tty_control.enableRawMode(&tty_candidate) catch |err| {
                if (err == error.NotATerminal) {
                    logging.logWarning("Standard input is not a TTY; Telnet raw mode disabled\n", .{});
                    break :blk null;
                }
                return err;
            };

            if (cfg.verbose) {
                logging.logVerbose(cfg, "Telnet raw mode enabled on local TTY\n", .{});
            }

            break :blk tty_candidate;
        };

        // Step 2: Install signal translation (if requested and TTY available)
        if (cfg.telnet_signal_mode == .remote and setup.local_tty_state != null) {
            if (!signal_translation.supportsSignalTranslation()) {
                logging.logWarning("Telnet signal translation is not supported on this platform; using local signals\n", .{});
            } else {
                const tty_ptr = &setup.local_tty_state.?;

                // Re-enable signal processing in terminal (required for translation)
                tty_control.setSignalProcessing(tty_ptr, true) catch |err| {
                    logging.logWarning("Failed to re-enable terminal signal processing: {any}\n", .{err});
                };

                // Install signal handlers (SIGINT → Telnet IP, etc.)
                signal_translation.install(signal_translation.SignalMode.remote) catch |err| {
                    logging.logWarning("Failed to install Telnet signal handlers: {any}\n", .{err});
                };

                setup.signal_translation_active = true;

                if (cfg.verbose) {
                    logging.logVerbose(cfg, "Telnet signal translation enabled (SIGINT/TERM/QUIT → IAC)\n", .{});
                }
            }
        } else if (cfg.telnet_signal_mode == .remote and setup.local_tty_state == null) {
            logging.logVerbose(cfg, "Telnet signal translation requires a TTY; falling back to local behavior\n", .{});
        }

        // Step 3: Detect initial window size (if SIGWINCH supported and TTY available)
        if (setup.local_tty_state) |*tty| {
            if (signal_handler.supportsSigwinch()) {
                // Install SIGWINCH handler for dynamic window resize tracking
                signal_handler.setupSigwinchHandler() catch |err| {
                    if (err != error.UnsupportedPlatform) {
                        logging.logVerbose(cfg, "Failed to install SIGWINCH handler: {any}\n", .{err});
                    }
                };

                // Get initial window size
                if (signal_handler.isSigwinchEnabled()) {
                    const size = signal_handler.getWindowSizeForFd(tty.fd) catch |err| {
                        logging.logVerbose(cfg, "Unable to read terminal window size: {any}\n", .{err});
                        return setup; // Return with null window size
                    };

                    // Only set window size if both dimensions are non-zero
                    if (size.col != 0 and size.row != 0) {
                        setup.window_width = @intCast(size.col);
                        setup.window_height = @intCast(size.row);

                        if (cfg.verbose) {
                            logging.logVerbose(
                                cfg,
                                "Detected terminal window size: {d}x{d}\n",
                                .{ setup.window_width.?, setup.window_height.? },
                            );
                        }
                    }
                }
            }
        }

        return setup;
    }

    /// Clean up Telnet setup resources.
    ///
    /// This function:
    /// 1. Restores original terminal settings (if raw mode was enabled)
    /// 2. Tears down signal translation handlers (if installed)
    ///
    /// **CRITICAL**: Must be called before program exit to restore terminal state.
    /// Otherwise, the terminal will remain in raw mode (no echo, no line buffering).
    pub fn deinit(self: *TelnetSetup) void {
        // Restore signal handlers first (before terminal state)
        if (self.signal_translation_active) {
            signal_translation.teardown() catch |err| {
                logging.logWarning("Failed to restore signal handlers: {any}\n", .{err});
            };
            self.signal_translation_active = false;
        }

        // Restore terminal state
        if (self.local_tty_state) |*state| {
            tty_control.restoreOriginalTermios(state) catch |err| {
                logging.logWarning("Failed to restore terminal mode: {any}\n", .{err});
            };
            self.local_tty_state = null;
        }
    }

    /// Get pointer to local TTY state (for TelnetConnection initialization).
    ///
    /// Returns: Pointer to TtyState if available, null otherwise
    pub fn getLocalTtyPtr(self: *TelnetSetup) ?*tty_state.TtyState {
        if (self.local_tty_state) |*state| {
            return state;
        }
        return null;
    }

    /// Check if dynamic window tracking is enabled.
    ///
    /// Returns: true if SIGWINCH is active and TTY is available
    pub fn hasDynamicWindowTracking(self: *const TelnetSetup) bool {
        return self.local_tty_state != null and signal_handler.isSigwinchEnabled();
    }
};
