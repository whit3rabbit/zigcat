// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Type definitions for the exec module.
const std = @import("std");
const timeout = @import("../util/timeout_tracker.zig");

/// Execution mode for command invocation
pub const ExecMode = enum {
    /// Direct execution: -e program args
    /// Executes program directly with argument array
    direct,

    /// Shell execution: -c "command string"
    /// Invokes platform shell (cmd.exe or /bin/sh) with command string
    shell,
};

/// Buffer sizing for exec session I/O channels.
pub const ExecBufferConfig = struct {
    /// Bytes allocated for client → child stdin buffering
    stdin_capacity: usize = 32 * 1024,
    /// Bytes allocated for child stdout → client buffering
    stdout_capacity: usize = 64 * 1024,
    /// Bytes allocated for child stderr → client buffering
    stderr_capacity: usize = 32 * 1024,
};

/// Flow control thresholds to prevent memory exhaustion.
pub const ExecFlowConfig = struct {
    /// Maximum total buffered bytes across all I/O channels (0 = auto)
    max_total_buffer_bytes: usize = 256 * 1024,
    /// Pause reading when buffered bytes exceed this percentage
    pause_threshold_percent: f32 = 0.85,
    /// Resume reading after buffered bytes drop below this percentage
    resume_threshold_percent: f32 = 0.60,
};

/// Aggregated configuration for exec session runtime.
pub const ExecSessionConfig = struct {
    buffers: ExecBufferConfig = .{},
    timeouts: timeout.TimeoutConfig = .{},
    flow: ExecFlowConfig = .{},
};

/// Configuration for command execution on connection
pub const ExecConfig = struct {
    /// Execution mode (direct vs shell)
    mode: ExecMode,

    /// Program path to execute (e.g., "/bin/sh", "cmd.exe")
    program: []const u8,

    /// Argument array for program (MEMORY: caller must free if heap-allocated)
    args: []const []const u8,

    /// SECURITY: Require --allow flag for access control (default: true)
    /// Setting to false allows ANY client to execute the program
    require_allow: bool = true,

    /// Runtime configuration for buffers, timeouts, and flow control
    session_config: ExecSessionConfig = .{},

    /// Redirect socket to child process stdin
    redirect_stdin: bool = true,
    /// Redirect child process stdout to socket
    redirect_stdout: bool = true,
    /// Redirect child process stderr to socket
    redirect_stderr: bool = true,
};

/// Errors that can occur during command execution
pub const ExecError = error{
    /// Failed to spawn child process (program not found, permissions, etc.)
    SpawnFailed,

    /// Failed to create pipe for stdin/stdout/stderr redirection
    PipeFailed,

    /// Failed to spawn I/O thread (socket↔child communication)
    ThreadSpawnFailed,

    /// Failed to wait for child process termination
    ChildWaitFailed,

    /// Memory allocation failed during command setup
    OutOfMemory,

    /// poll() system call failed
    PollFailed,

    /// Execution time exceeded configured limit
    TimeoutExecution,

    /// Idle timeout exceeded without I/O
    TimeoutIdle,

    /// Connection timeout exceeded without initial activity
    TimeoutConnection,

    /// Flow control hard limit exceeded
    FlowControlTriggered,

    /// General I/O failure on socket or child pipes
    IoError,

    /// Invalid session configuration detected
    InvalidConfiguration,
};
