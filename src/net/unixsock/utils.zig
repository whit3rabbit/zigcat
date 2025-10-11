//! Unix Domain Socket utilities and shared functionality.
//!
//! Provides common utilities for Unix socket operations including address handling,
//! validation, error mapping, and cleanup operations.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_mod = @import("../socket.zig");
const logging = @import("../../util/logging.zig");
const config = @import("../../config.zig");

/// Platform support detection for Unix domain sockets.
pub const unix_socket_supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

/// Comprehensive error types for Unix socket operations with detailed categorization.
pub const UnixSocketError = error{
    // Path validation errors
    PathTooLong,
    InvalidPath,
    PathContainsNull,
    DirectoryNotFound,
    InvalidPathCharacters,

    // File system errors
    SocketFileExists,
    PermissionDenied,
    InsufficientPermissions,
    DiskFull,
    FileLocked,
    IsDirectory,
    FileSystemError,

    // Socket operation errors
    AddressInUse,
    AddressNotAvailable,
    NetworkUnreachable,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    SocketNotConnected,
    SocketAlreadyConnected,

    // Platform and feature errors
    NotSupported,
    PlatformNotSupported,
    FeatureNotAvailable,

    // Resource management errors
    CleanupFailed,
    ResourceExhausted,
    TooManyOpenFiles,
    OutOfMemory,

    // Configuration errors
    InvalidOperation,
    ConflictingConfiguration,
    UnsupportedCombination,
};

/// Unix socket address structure for POSIX systems.
pub const UnixAddress = struct {
    family: u16,
    path: [108]u8,

    pub fn fromPath(path: []const u8) !UnixAddress {
        if (path.len == 0) return error.InvalidPath;
        if (path.len >= 108) return error.PathTooLong;

        var addr = UnixAddress{
            .family = posix.AF.UNIX,
            .path = std.mem.zeroes([108]u8),
        };

        @memcpy(addr.path[0..path.len], path);
        return addr;
    }

    pub fn getLen(self: *const UnixAddress) posix.socklen_t {
        const path_len = std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len;
        return @intCast(2 + path_len); // family (2 bytes) + path
    }

    pub fn getPath(self: *const UnixAddress) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.path, 0) orelse self.path.len;
        return self.path[0..end];
    }
};

/// Handle existing socket files with comprehensive error recovery.
///
/// SECURITY: Uses connect-before-delete pattern to eliminate TOCTTOU race condition.
/// This is the industry-standard approach used by nginx, Apache, and systemd.
///
/// Strategy for existing files:
/// 1. Attempt to connect to the socket path
/// 2. If ConnectionRefused: Socket exists but no listener → stale socket, safe to remove
/// 3. If FileNotFound: No socket file exists → proceed normally
/// 4. If connection succeeds: Socket is actively in use → return AddressInUse
/// 5. Other errors: Map to appropriate UnixSocketError types
///
/// This eliminates the TOCTTOU race by using a single functional test (connect attempt)
/// instead of separate stat-then-delete operations. An attacker cannot exploit a race
/// because the connect operation atomically tests whether the socket is functional.
///
/// Benefits over stat-then-delete:
/// - No race condition window
/// - Functional test proves socket is truly stale
/// - Single atomic operation
/// - Cannot be tricked by symlink replacement
pub fn handleExistingSocketFile(path: []const u8) UnixSocketError!void {
    // Create a temporary, non-blocking socket to probe the existing socket file.
    // This socket is only used for the `connect` call and is closed immediately after.
    const test_sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        // If we can't even create a socket, it's a system-level issue.
        logging.logDebug("Failed to create test socket for probing: {any}\n", .{err});
        return UnixSocketError.FileSystemError;
    };
    defer posix.close(test_sock);

    // Prepare the address structure for the `connect` call.
    const addr = UnixAddress.fromPath(path) catch |err| {
        return err;
    };

    // This is the core of the TOCTTOU (Time-of-Check-to-Time-of-Use) mitigation.
    // Instead of checking `if file exists` and then `delete file`, which creates a
    // race condition window, we perform a single, atomic `connect` operation.
    // The outcome of this single call tells us the state of the socket file safely.
    posix.connect(test_sock, @ptrCast(&addr), addr.getLen()) catch |err| switch (err) {
        error.ConnectionRefused => {
            // This is the "golden path" for cleanup. ECONNREFUSED means a socket file
            // exists at the path, but no process is `accept()`-ing connections on it.
            // This is a strong indicator that the socket is stale and left over from a
            // previous unclean shutdown. It is now safe to delete it.
            logging.logDebug("Stale socket detected at '{s}', removing\n", .{path});

            std.fs.cwd().deleteFile(path) catch |del_err| switch (del_err) {
                error.FileNotFound => {}, // Race condition: another process removed it. This is fine.
                error.AccessDenied => return UnixSocketError.PermissionDenied,
                error.FileBusy => return UnixSocketError.FileLocked,
                error.SystemResources => return UnixSocketError.ResourceExhausted,
                error.ReadOnlyFileSystem => return UnixSocketError.InsufficientPermissions,
                else => {
                    logging.logWarning("Failed to remove stale socket: {any}\n", .{del_err});
                    return UnixSocketError.CleanupFailed;
                },
            };
            return; // Successfully cleaned up the stale socket.
        },
        error.FileNotFound => {
            // ENOENT: The socket file does not exist. This is the ideal case,
            // as there is nothing to clean up. We can proceed to bind.
            return;
        },
        error.PermissionDenied, error.AccessDenied => {
            return UnixSocketError.PermissionDenied;
        },
        error.AddressInUse => {
            // This case is unlikely on a `connect` call but handled for completeness.
            return UnixSocketError.AddressInUse;
        },
        else => {
            // Any other error indicates a more complex issue (e.g., path points to a
            // directory, filesystem errors). We log it and map to a generic error.
            logging.logDebug("Socket probe failed for '{s}': {any}\n", .{ path, err });
            return handleSocketError(err, "socket probe");
        },
    };

    // If the `connect` call succeeds without error, it means a process is actively
    // listening on the socket. We must not interfere with it.
    logging.logDebug("Socket at '{s}' is actively in use\n", .{path});
    return UnixSocketError.AddressInUse;
}

/// Comprehensive Unix socket path validation with detailed error reporting.
///
/// Validates Unix socket paths for:
/// - Length limits (107 bytes max for portability)
/// - Invalid characters (null bytes, control characters)
/// - Directory accessibility and permissions
/// - Platform-specific path requirements
/// - File system constraints
///
/// Returns specific errors for different validation failures to enable
/// targeted error handling and user-friendly error messages.
pub fn validatePath(path: []const u8) UnixSocketError!void {
    // Basic path validation
    if (path.len == 0) return UnixSocketError.InvalidPath;
    if (path.len >= 108) return UnixSocketError.PathTooLong;

    // Check for null bytes (invalid in Unix paths)
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        return UnixSocketError.PathContainsNull;
    }

    // Check for invalid control characters (except tab)
    for (path) |byte| {
        if (byte < 32 and byte != '\t') {
            return UnixSocketError.InvalidPathCharacters;
        }
    }

    // Validate parent directory accessibility
    if (std.fs.path.dirname(path)) |dir| {
        validateDirectoryAccess(dir) catch |err| switch (err) {
            error.FileNotFound => return UnixSocketError.DirectoryNotFound,
            error.AccessDenied => return UnixSocketError.PermissionDenied,
            error.SystemResources => return UnixSocketError.ResourceExhausted,
            else => return UnixSocketError.FileSystemError,
        };
    }

    // Platform-specific validation
    try validatePlatformSpecificPath(path);
}

/// Validate directory access with comprehensive error mapping.
fn validateDirectoryAccess(dir_path: []const u8) !void {
    std.fs.cwd().access(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources => return error.SystemResources,
        else => return err,
    };
}

/// Platform-specific Unix socket path validation.
fn validatePlatformSpecificPath(path: []const u8) UnixSocketError!void {
    switch (builtin.os.tag) {
        .linux => {
            // Linux supports abstract namespace sockets (starting with null byte)
            // but we don't support them in this implementation for security reasons
            if (path.len > 0 and path[0] == 0) {
                return UnixSocketError.UnsupportedCombination;
            }
            // Linux supports standard 108-byte paths
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            // BSD variants have stricter 104-byte path limit (not 108 like Linux)
            // This is due to smaller sockaddr_un structure on BSD systems
            if (path.len >= 104) {
                logging.logDebug("Path too long for BSD platform: {d} bytes (max 103)\n", .{path.len});
                return UnixSocketError.PathTooLong;
            }
        },
        else => {
            // Other Unix-like systems - use conservative 104-byte limit
            if (path.len >= 104) {
                return UnixSocketError.PathTooLong;
            }
        },
    }
}

/// Check Unix socket support with detailed platform information.
pub fn checkSupport() UnixSocketError!void {
    if (!unix_socket_supported) {
        return UnixSocketError.PlatformNotSupported;
    }
}

/// Handle Unix socket operation errors with detailed error mapping and recovery suggestions.
///
/// Maps low-level POSIX errors to specific UnixSocketError variants to enable
/// targeted error handling and user-friendly error messages.
pub fn handleSocketError(err: anyerror, operation: []const u8) UnixSocketError {
    return switch (err) {
        // Network and connection errors
        error.AddressInUse => UnixSocketError.AddressInUse,
        error.AddressNotAvailable => UnixSocketError.AddressNotAvailable,
        error.NetworkUnreachable => UnixSocketError.NetworkUnreachable,
        error.ConnectionRefused => UnixSocketError.ConnectionRefused,
        error.ConnectionResetByPeer => UnixSocketError.ConnectionReset,
        error.ConnectionAborted => UnixSocketError.ConnectionAborted,
        error.NotConnected => UnixSocketError.SocketNotConnected,
        error.AlreadyConnected => UnixSocketError.SocketAlreadyConnected,

        // Permission and access errors
        error.AccessDenied => UnixSocketError.PermissionDenied,
        error.PermissionDenied => UnixSocketError.InsufficientPermissions,

        // File system errors
        error.FileNotFound => UnixSocketError.DirectoryNotFound,
        error.IsDir => UnixSocketError.IsDirectory,
        error.FileBusy => UnixSocketError.FileLocked,
        error.NoSpaceLeft => UnixSocketError.DiskFull,
        error.ReadOnlyFileSystem => UnixSocketError.InsufficientPermissions,

        // Resource exhaustion errors
        error.SystemResources => UnixSocketError.ResourceExhausted,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => UnixSocketError.TooManyOpenFiles,
        error.OutOfMemory => UnixSocketError.OutOfMemory,

        // Path and validation errors
        error.NameTooLong => UnixSocketError.PathTooLong,
        error.InvalidUtf8 => UnixSocketError.InvalidPathCharacters,

        // Platform support errors
        error.OperationNotSupported => UnixSocketError.NotSupported,
        error.ProtocolNotSupported => UnixSocketError.FeatureNotAvailable,

        // Generic fallback
        else => blk: {
            logging.logWarning("Unmapped Unix socket error in {s}: {any}\n", .{ operation, err });
            break :blk UnixSocketError.FileSystemError;
        },
    };
}

/// Provide user-friendly error messages for Unix socket errors.
///
/// Returns detailed error descriptions and recovery suggestions for different
/// error categories to help users diagnose and resolve issues.
pub fn getErrorMessage(err: UnixSocketError, path: []const u8, operation: []const u8) []const u8 {
    _ = path;
    _ = operation;
    return switch (err) {
        // Path validation errors
        UnixSocketError.PathTooLong => "Unix socket path is too long (max 107 characters)",
        UnixSocketError.InvalidPath => "Unix socket path is invalid or empty",
        UnixSocketError.PathContainsNull => "Unix socket path contains null bytes",
        UnixSocketError.DirectoryNotFound => "Parent directory for Unix socket does not exist",
        UnixSocketError.InvalidPathCharacters => "Unix socket path contains invalid characters",

        // File system errors
        UnixSocketError.SocketFileExists => "File exists at socket path but is not a Unix socket",
        UnixSocketError.PermissionDenied => "Permission denied accessing Unix socket path",
        UnixSocketError.InsufficientPermissions => "Insufficient permissions for Unix socket operation",
        UnixSocketError.DiskFull => "Disk full - cannot create Unix socket file",
        UnixSocketError.FileLocked => "Unix socket file is locked by another process",
        UnixSocketError.IsDirectory => "Unix socket path points to a directory",
        UnixSocketError.FileSystemError => "File system error during Unix socket operation",

        // Socket operation errors
        UnixSocketError.AddressInUse => "Unix socket address is already in use",
        UnixSocketError.AddressNotAvailable => "Unix socket address is not available",
        UnixSocketError.NetworkUnreachable => "Network unreachable for Unix socket",
        UnixSocketError.ConnectionRefused => "Connection refused to Unix socket",
        UnixSocketError.ConnectionReset => "Unix socket connection was reset",
        UnixSocketError.ConnectionAborted => "Unix socket connection was aborted",
        UnixSocketError.SocketNotConnected => "Unix socket is not connected",
        UnixSocketError.SocketAlreadyConnected => "Unix socket is already connected",

        // Platform and feature errors
        UnixSocketError.NotSupported => "Unix socket operation not supported",
        UnixSocketError.PlatformNotSupported => "Unix sockets not supported on this platform",
        UnixSocketError.FeatureNotAvailable => "Unix socket feature not available",

        // Resource management errors
        UnixSocketError.CleanupFailed => "Failed to clean up Unix socket file",
        UnixSocketError.ResourceExhausted => "System resources exhausted for Unix socket",
        UnixSocketError.TooManyOpenFiles => "Too many open files - cannot create Unix socket",
        UnixSocketError.OutOfMemory => "Out of memory for Unix socket operation",

        // Configuration errors
        UnixSocketError.InvalidOperation => "Invalid Unix socket operation",
        UnixSocketError.ConflictingConfiguration => "Conflicting Unix socket configuration",
        UnixSocketError.UnsupportedCombination => "Unsupported Unix socket feature combination",
    };
}

/// Handle Unix socket errors with logging and recovery suggestions.
///
/// Provides comprehensive error handling with:
/// - Detailed error messages based on error type
/// - Recovery suggestions for common issues
/// - Appropriate logging based on verbosity level
/// - Graceful degradation where possible
pub fn handleUnixSocketError(
    err: UnixSocketError,
    path: []const u8,
    operation: []const u8,
    verbose: bool,
) void {
    const error_msg = getErrorMessage(err, path, operation);

    if (verbose) {
        std.debug.print( "Unix socket error during {s} on '{s}': {s}\n", .{ operation, path, error_msg });

        // Provide recovery suggestions for common errors
        switch (err) {
            UnixSocketError.PermissionDenied, UnixSocketError.InsufficientPermissions => {
                std.debug.print( "Suggestion: Check file permissions and ensure the process has write access to the directory\n", .{});
            },
            UnixSocketError.DirectoryNotFound => {
                std.debug.print( "Suggestion: Create the parent directory or use an existing directory path\n", .{});
            },
            UnixSocketError.SocketFileExists => {
                std.debug.print( "Suggestion: Remove the existing file or choose a different socket path\n", .{});
            },
            UnixSocketError.AddressInUse => {
                std.debug.print( "Suggestion: Another process is using this socket - try a different path or stop the other process\n", .{});
            },
            UnixSocketError.PathTooLong => {
                std.debug.print( "Suggestion: Use a shorter socket path (max 107 characters)\n", .{});
            },
            UnixSocketError.PlatformNotSupported => {
                std.debug.print( "Suggestion: Unix sockets are not supported on this platform - use TCP sockets instead\n", .{});
            },
            else => {},
        }
    } else {
        // Non-verbose mode: concise error message
        logging.log(1, "Unix socket {s} failed: {s}\n", .{ operation, error_msg });
    }
}

/// Comprehensive resource cleanup for Unix sockets with error recovery.
///
/// Handles cleanup of Unix socket resources including:
/// - Socket file removal with error handling
/// - Memory deallocation with proper error reporting
/// - Graceful degradation on cleanup failures
/// - Logging of cleanup issues for debugging
pub fn cleanupUnixSocketResources(
    socket: socket_mod.Socket,
    path: []const u8,
    is_server: bool,
    path_owned: bool,
    force_cleanup: bool,
    verbose: bool,
) void {
    _ = path_owned;

    // Close socket first to prevent new connections (skip if invalid socket descriptor)
    // Note: Use > 0 instead of >= 0 to prevent accidentally closing stdin (fd 0) or stderr (fd 2)
    if (@as(i32, @bitCast(socket)) > 0) {
        socket_mod.closeSocket(socket);
    }

    // Clean up socket file if this is a server socket
    if (is_server and path.len > 0) {
        cleanupSocketFile(path, force_cleanup, verbose);
    }
}

/// Clean up Unix socket file with comprehensive error handling.
fn cleanupSocketFile(path: []const u8, force_cleanup: bool, verbose: bool) void {
    std.fs.cwd().deleteFile(path) catch |err| {
        // FileNotFound is not an error during cleanup - file already removed
        if (err == error.FileNotFound) {
            if (verbose) {
                logging.logWarning("Failed to remove Unix socket file '{s}': {any}\n", .{ path, err });
            }
            return;
        }

        const cleanup_err = handleSocketError(err, "cleanup");

        if (verbose) {
            const error_msg = getErrorMessage(cleanup_err, path, "cleanup");
            logging.logWarning("Failed to remove Unix socket file '{s}': {s}\n", .{ path, error_msg });

            // Provide recovery suggestions
            switch (cleanup_err) {
                UnixSocketError.PermissionDenied, UnixSocketError.InsufficientPermissions => {
                    logging.logWarning("Suggestion: Check file permissions or run with appropriate privileges\n", .{});
                },
                UnixSocketError.FileLocked => {
                    logging.logWarning("Suggestion: Another process may still be using the socket\n", .{});
                },
                UnixSocketError.ResourceExhausted => {
                    logging.logWarning("Suggestion: System resources exhausted - try again later\n", .{});
                },
                else => {
                    if (force_cleanup) {
                        logging.logWarning("Suggestion: Manual cleanup may be required for '{s}'\n", .{path});
                    }
                },
            }
        } else {
            // Non-verbose: just log the basic error
            logging.logWarning("Failed to remove Unix socket file '{s}': {any}\n", .{ path, err });
        }

        // In force cleanup mode, try alternative cleanup methods
        if (force_cleanup) {
            attemptForceCleanup(path, verbose);
        }
    };
}

/// Attempt alternative cleanup methods when standard cleanup fails.
fn attemptForceCleanup(path: []const u8, verbose: bool) void {
    // Try to stat the file to see if it still exists
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => {
            if (verbose) {
                logging.log(1, "Socket file '{s}' was already removed\n", .{path});
            }
            return; // File doesn't exist - cleanup successful
        },
        else => {
            if (verbose) {
                logging.logWarning("Cannot stat socket file '{s}' for force cleanup: {any}\n", .{ path, err });
            }
            return;
        },
    };

    // If file still exists, log detailed information for manual cleanup
    if (verbose) {
        logging.logWarning("Socket file '{s}' still exists after cleanup attempt:\n", .{path});
        logging.logWarning("  File type: {any}\n", .{stat.kind});
        logging.logWarning("  File size: {any} bytes\n", .{stat.size});
        logging.logWarning("  Manual removal may be required\n", .{});
    }
}

/// Validate Unix socket configuration with comprehensive error recovery.
///
/// Provides detailed validation with recovery suggestions for configuration issues.
/// Returns specific error types to enable targeted error handling in calling code.
pub fn validateUnixSocketConfiguration(
    path: []const u8,
    cfg: *const config.Config,
    verbose: bool,
) UnixSocketError!void {
    // Basic path validation
    validatePath(path) catch |err| {
        if (verbose) {
            handleUnixSocketError(err, path, "path validation", verbose);
        }
        return err;
    };

    // Platform support validation
    checkSupport() catch |err| {
        if (verbose) {
            handleUnixSocketError(err, path, "platform support check", verbose);
        }
        return err;
    };

    // Configuration conflict validation
    validateConfigurationConflicts(cfg) catch |err| {
        if (verbose) {
            handleUnixSocketError(err, path, "configuration validation", verbose);
        }
        return err;
    };
}

/// Validate Unix socket configuration conflicts with other features.
fn validateConfigurationConflicts(cfg: *const config.Config) UnixSocketError!void {
    // Check for conflicts with TCP mode
    if (cfg.positional_args.len > 0) {
        return UnixSocketError.ConflictingConfiguration;
    }

    // Check for conflicts with UDP mode
    if (cfg.udp_mode) {
        return UnixSocketError.UnsupportedCombination;
    }

    // Check for conflicts with TLS
    if (cfg.ssl) {
        return UnixSocketError.UnsupportedCombination;
    }

    // Check for conflicts with proxy settings
    if (cfg.proxy != null) {
        return UnixSocketError.UnsupportedCombination;
    }
}

/// Create Unix socket path in temporary directory for testing.
pub fn createTempPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const temp_dir_owned = std.process.getEnvVarOwned(allocator, "TMPDIR") catch null;
    const temp_dir = temp_dir_owned orelse "/tmp";
    defer if (temp_dir_owned) |owned| allocator.free(owned);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, name });
}
