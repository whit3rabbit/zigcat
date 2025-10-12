//! Windows Named Pipes implementation as fallback for Unix domain sockets
//!
//! This module provides Windows Named Pipes support for older Windows systems
//! (pre-Windows 10 RS4) that don't support AF_UNIX sockets. It implements a
//! Unix socket-like API using Named Pipes.
//!
//! Architecture:
//! - Windows 10 RS4+ (Build 17063+): Use native AF_UNIX sockets (preferred)
//! - Windows 7/8/10 (older): Use Named Pipes (fallback)
//!
//! Key Differences from Unix Sockets:
//! - Named Pipes reuse same HANDLE for multiple clients (no new FD per accept)
//! - Must call DisconnectNamedPipe between clients
//! - ERROR_PIPE_CONNECTED is success, not failure
//! - Path: `\\.\pipe\name` instead of `/tmp/name.sock`
//!
//! Security Model:
//! - PIPE_REJECT_REMOTE_CLIENTS: Blocks network access (local-only)
//! - FILE_FLAG_FIRST_PIPE_INSTANCE: Prevents pipe hijacking
//! - Custom DACL: Owner-only access (System + Administrators)

const std = @import("std");
const builtin = @import("builtin");

// This module is Windows-only
comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_pipe.zig is Windows-only. Use Unix sockets on other platforms.");
    }
}

const windows = std.os.windows;
const kernel32 = windows.kernel32;
const logging = @import("../../util/logging.zig");
const win_security = @import("../../util/windows_security.zig");

// ============================================================================
// Windows API Declarations (not in Zig stdlib)
// ============================================================================

pub extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: [*:0]const u16,
    nTimeOut: windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn GetNamedPipeInfo(
    hNamedPipe: windows.HANDLE,
    lpFlags: ?*windows.DWORD,
    lpOutBufferSize: ?*windows.DWORD,
    lpInBufferSize: ?*windows.DWORD,
    lpMaxInstances: ?*windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

// ============================================================================
// Constants (missing from Zig stdlib)
// ============================================================================

pub const PIPE_UNLIMITED_INSTANCES = 255;

// WaitNamedPipe timeout constants
pub const NMPWAIT_WAIT_FOREVER: windows.DWORD = 0xffffffff;
pub const NMPWAIT_NOWAIT: windows.DWORD = 0x1;
pub const NMPWAIT_USE_DEFAULT_WAIT: windows.DWORD = 0x0;

// CreateNamedPipe security flags
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: windows.DWORD = 0x00080000;
pub const PIPE_REJECT_REMOTE_CLIENTS: windows.DWORD = 0x00000008;

// Error codes
pub const ERROR_PIPE_CONNECTED: windows.Win32Error = @enumFromInt(535);
pub const ERROR_NO_DATA: windows.Win32Error = @enumFromInt(232);
pub const ERROR_BROKEN_PIPE: windows.Win32Error = @enumFromInt(109);
pub const ERROR_PIPE_NOT_CONNECTED: windows.Win32Error = @enumFromInt(233);

// ============================================================================
// Named Pipe Configuration
// ============================================================================

/// Default buffer sizes for Named Pipes (8KB each direction)
pub const DEFAULT_BUFFER_SIZE: windows.DWORD = 8192;

/// Retry configuration for ERROR_PIPE_BUSY handling
pub const RetryConfig = struct {
    /// Maximum number of retry attempts
    max_retries: u32 = 5,

    /// Initial backoff delay in milliseconds
    initial_backoff_ms: u32 = 10,

    /// Maximum backoff delay in milliseconds
    max_backoff_ms: u32 = 5000,

    /// Backoff multiplier (2.0 = exponential doubling)
    backoff_multiplier: f32 = 2.0,

    /// Overall operation timeout in milliseconds (0 = use individual waits)
    total_timeout_ms: u32 = 0,
};

/// Configuration for Named Pipe creation
pub const PipeConfig = struct {
    /// Maximum number of pipe instances (default: unlimited)
    max_instances: windows.DWORD = PIPE_UNLIMITED_INSTANCES,

    /// Output buffer size in bytes
    out_buffer_size: windows.DWORD = DEFAULT_BUFFER_SIZE,

    /// Input buffer size in bytes
    in_buffer_size: windows.DWORD = DEFAULT_BUFFER_SIZE,

    /// Default timeout in milliseconds (0 = 50ms default)
    default_timeout: windows.DWORD = 0,

    /// Reject remote clients (local-only, recommended)
    reject_remote: bool = true,

    /// First instance flag (prevents hijacking, recommended)
    first_instance: bool = true,

    /// Use custom security descriptor (owner-only access)
    use_custom_security: bool = true,
};

// ============================================================================
// Path Translation
// ============================================================================

/// Translate Unix socket path to Windows Named Pipe path
///
/// Unix: `/tmp/zigcat.sock` → Windows: `\\.\pipe\zigcat`
///
/// Rules:
/// - Extract basename (remove directory path)
/// - Strip `.sock` extension
/// - Prefix with `\\.\pipe\`
/// - Max 256 chars total
///
/// Example:
/// ```zig
/// const pipe_name = try translatePath(allocator, "/tmp/myapp.sock");
/// defer allocator.free(pipe_name);
/// // Result: "\\.\pipe\myapp"
/// ```
pub fn translatePath(allocator: std.mem.Allocator, unix_path: []const u8) ![]u8 {
    // Extract basename (e.g., "/tmp/foo.sock" → "foo.sock")
    const basename = std.fs.path.basename(unix_path);

    // Strip .sock extension if present
    const name = if (std.mem.endsWith(u8, basename, ".sock"))
        basename[0 .. basename.len - 5]
    else
        basename;

    // Validate name length (max 256 chars total, prefix is 9 chars)
    if (name.len > 247) {
        return error.NameTooLong;
    }

    // Build pipe path: \\.\pipe\{name}
    return std.fmt.allocPrint(allocator, "\\\\.\\pipe\\{s}", .{name});
}

/// Convert UTF-8 pipe path to UTF-16 (null-terminated) for Windows APIs
pub fn pathToUtf16(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
    return try std.unicode.utf8ToUtf16LeWithNull(allocator, path);
}

// ============================================================================
// Named Pipe Server
// ============================================================================

/// Named Pipe server (analogous to Unix socket server)
pub const NamedPipeServer = struct {
    handle: windows.HANDLE,
    pipe_name: []const u8,
    pipe_name_w: [:0]u16, // UTF-16 version
    allocator: std.mem.Allocator,
    config: PipeConfig,
    connected: bool = false,

    /// Create Named Pipe server
    ///
    /// This creates a Named Pipe that can accept multiple clients sequentially.
    /// Unlike Unix sockets, the same HANDLE is reused for all clients via
    /// DisconnectNamedPipe + ConnectNamedPipe.
    ///
    /// Security:
    /// - PIPE_REJECT_REMOTE_CLIENTS: Local-only access
    /// - FILE_FLAG_FIRST_PIPE_INSTANCE: Prevents hijacking
    /// - Custom DACL: Owner-only access (if use_custom_security=true)
    ///
    /// Example:
    /// ```zig
    /// var server = try NamedPipeServer.init(allocator, "/tmp/app.sock", .{});
    /// defer server.deinit();
    /// ```
    pub fn init(
        allocator: std.mem.Allocator,
        unix_path: []const u8,
        config: PipeConfig,
    ) !NamedPipeServer {
        if (builtin.os.tag != .windows) {
            return error.NotSupported;
        }

        // Translate Unix path to Named Pipe path
        const pipe_name = try translatePath(allocator, unix_path);
        errdefer allocator.free(pipe_name);

        // Convert to UTF-16 for Windows API
        const pipe_name_w = try pathToUtf16(allocator, pipe_name);
        errdefer allocator.free(pipe_name_w);

        // Build open mode flags
        var open_mode: windows.DWORD = windows.PIPE_ACCESS_DUPLEX;
        if (config.reject_remote) {
            open_mode |= PIPE_REJECT_REMOTE_CLIENTS;
        }
        if (config.first_instance) {
            open_mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
        }

        // Pipe mode: byte stream, blocking (like TCP sockets)
        const pipe_mode: windows.DWORD = windows.PIPE_TYPE_BYTE |
            windows.PIPE_READMODE_BYTE |
            windows.PIPE_WAIT;

        // Create security attributes (optional)
        var security_attr: ?windows.SECURITY_ATTRIBUTES = null;
        var sec_desc: ?*anyopaque = null;
        if (config.use_custom_security) {
            // Create restrictive DACL using SDDL
            const sddl = win_security.SDDL.OWNER_ONLY;
            const sddl_w = try std.unicode.utf8ToUtf16LeWithNull(allocator, sddl);
            defer allocator.free(sddl_w);

            if (win_security.ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl_w.ptr,
                win_security.SDDL_REVISION_1,
                &sec_desc,
                null,
            ) != 0) {
                security_attr = windows.SECURITY_ATTRIBUTES{
                    .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
                    .lpSecurityDescriptor = sec_desc,
                    .bInheritHandle = 0,
                };
            }
        }
        defer if (sec_desc) |sd| _ = win_security.LocalFree(sd);

        // Create Named Pipe
        const handle = kernel32.CreateNamedPipeW(
            pipe_name_w.ptr,
            open_mode,
            pipe_mode,
            config.max_instances,
            config.out_buffer_size,
            config.in_buffer_size,
            config.default_timeout,
            if (security_attr) |*sa| sa else null,
        );

        if (handle == windows.INVALID_HANDLE_VALUE) {
            const err = windows.GetLastError();
            logging.logWarning("CreateNamedPipeW failed: {any}\n", .{err});
            return error.CreatePipeFailed;
        }

        logging.log(1, "Named Pipe created: {s}\n", .{pipe_name});

        return NamedPipeServer{
            .handle = handle,
            .pipe_name = pipe_name,
            .pipe_name_w = pipe_name_w,
            .allocator = allocator,
            .config = config,
        };
    }

    /// Wait for client connection (blocking)
    ///
    /// This is analogous to accept() for Unix sockets, but returns void instead
    /// of a new socket. The same pipe HANDLE is used for the connected client.
    ///
    /// CRITICAL: ERROR_PIPE_CONNECTED is **success**, not failure!
    /// This occurs when client connects before server calls ConnectNamedPipe.
    ///
    /// Example:
    /// ```zig
    /// try server.accept();  // Blocks until client connects
    /// // Now use server.handle for ReadFile/WriteFile
    /// ```
    pub fn accept(self: *NamedPipeServer) !void {
        if (self.connected) {
            return error.AlreadyConnected;
        }

        const result = ConnectNamedPipe(self.handle, null);

        if (result == 0) {
            const err = windows.GetLastError();
            // ERROR_PIPE_CONNECTED means client connected before we called ConnectNamedPipe
            // This is SUCCESS, not failure!
            if (err == ERROR_PIPE_CONNECTED) {
                logging.log(1, "Client connected to pipe (pre-connected)\n", .{});
                self.connected = true;
                return;
            }
            logging.logWarning("ConnectNamedPipe failed: {any}\n", .{err});
            return error.ConnectFailed;
        }

        logging.log(1, "Client connected to pipe\n", .{});
        self.connected = true;
    }

    /// Disconnect current client (required before accepting next client)
    ///
    /// Unlike Unix sockets where accept() returns a new FD, Named Pipes reuse
    /// the same HANDLE. You MUST call disconnect() between clients.
    ///
    /// Example:
    /// ```zig
    /// try server.accept();
    /// // ... handle client I/O ...
    /// try server.disconnect();  // REQUIRED before next accept
    /// try server.accept();      // Ready for next client
    /// ```
    pub fn disconnect(self: *NamedPipeServer) !void {
        if (!self.connected) {
            return error.NotConnected;
        }

        const result = DisconnectNamedPipe(self.handle);
        if (result == 0) {
            const err = windows.GetLastError();
            logging.logWarning("DisconnectNamedPipe failed: {any}\n", .{err});
            return error.DisconnectFailed;
        }

        logging.log(1, "Client disconnected from pipe\n", .{});
        self.connected = false;
    }

    /// Get pipe handle for I/O operations
    pub fn getHandle(self: *const NamedPipeServer) windows.HANDLE {
        return self.handle;
    }

    /// Get pipe name (UTF-8)
    pub fn getPipeName(self: *const NamedPipeServer) []const u8 {
        return self.pipe_name;
    }

    /// Check if client is connected
    pub fn isConnected(self: *const NamedPipeServer) bool {
        return self.connected;
    }

    /// Close pipe and free resources
    pub fn deinit(self: *NamedPipeServer) void {
        windows.CloseHandle(self.handle);
        self.allocator.free(self.pipe_name);
        self.allocator.free(self.pipe_name_w);
    }
};

// ============================================================================
// Named Pipe Client
// ============================================================================

/// Connect to Named Pipe server (client-side) with exponential backoff
///
/// This is analogous to connect() for Unix sockets, with robust retry logic.
///
/// Features:
/// - Exponential backoff for ERROR_PIPE_BUSY (default: 10ms → 5s)
/// - Configurable retry attempts (default: 5)
/// - Overall timeout enforcement
/// - Detailed error logging
///
/// Example:
/// ```zig
/// const handle = try connectToNamedPipe(allocator, "/tmp/app.sock", 5000, .{});
/// defer windows.CloseHandle(handle);
/// ```
pub fn connectToNamedPipe(
    allocator: std.mem.Allocator,
    unix_path: []const u8,
    timeout_ms: windows.DWORD,
) !windows.HANDLE {
    return connectToNamedPipeWithRetry(allocator, unix_path, timeout_ms, .{});
}

/// Connect to Named Pipe server with custom retry configuration
pub fn connectToNamedPipeWithRetry(
    allocator: std.mem.Allocator,
    unix_path: []const u8,
    timeout_ms: windows.DWORD,
    retry_config: RetryConfig,
) !windows.HANDLE {
    if (builtin.os.tag != .windows) {
        return error.NotSupported;
    }

    // Translate path and convert to UTF-16
    const pipe_name = try translatePath(allocator, unix_path);
    defer allocator.free(pipe_name);

    const pipe_name_w = try pathToUtf16(allocator, pipe_name);
    defer allocator.free(pipe_name_w);

    const start_time = std.time.milliTimestamp();
    const total_timeout: i64 = if (retry_config.total_timeout_ms > 0)
        retry_config.total_timeout_ms
    else
        timeout_ms;

    var current_backoff_ms: u32 = retry_config.initial_backoff_ms;
    var attempt: u32 = 0;

    while (attempt < retry_config.max_retries) : (attempt += 1) {
        // Check overall timeout
        if (retry_config.total_timeout_ms > 0 or timeout_ms > 0) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= total_timeout) {
                logging.logWarning("Overall timeout ({d}ms) exceeded after {d} attempts\n", .{ total_timeout, attempt + 1 });
                return error.ConnectionTimeout;
            }
        }

        // Try to open pipe
        const handle = kernel32.CreateFileW(
            pipe_name_w.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0, // No sharing
            null, // Default security
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null, // No template
        );

        // Success!
        if (handle != windows.INVALID_HANDLE_VALUE) {
            if (attempt > 0) {
                logging.log(1, "Connected to pipe: {s} (after {d} retries)\n", .{ pipe_name, attempt });
            } else {
                logging.log(1, "Connected to pipe: {s}\n", .{pipe_name});
            }
            return handle;
        }

        // Handle errors
        const err = windows.GetLastError();
        switch (err) {
            .PIPE_BUSY => {
                // Pipe exists but all instances are busy - retry with backoff
                if (attempt + 1 < retry_config.max_retries) {
                    logging.log(1, "Pipe busy (attempt {d}/{d}), waiting {d}ms before retry...\n", .{ attempt + 1, retry_config.max_retries, current_backoff_ms });

                    // Calculate remaining timeout
                    const elapsed = std.time.milliTimestamp() - start_time;
                    const remaining_timeout = total_timeout - elapsed;
                    const wait_time = @min(current_backoff_ms, @as(u32, @intCast(@max(0, remaining_timeout))));

                    // Wait for pipe to become available (or timeout)
                    const wait_result = WaitNamedPipeW(pipe_name_w.ptr, wait_time);
                    if (wait_result == 0) {
                        const wait_err = windows.GetLastError();
                        if (wait_err == .TIMEOUT or wait_err == .SEM_TIMEOUT) {
                            // Timeout is expected during backoff - continue to next iteration
                            logging.log(1, "WaitNamedPipeW timeout (expected), continuing...\n", .{});
                        } else {
                            logging.logWarning("WaitNamedPipeW failed: {any}\n", .{wait_err});
                        }
                    }

                    // Exponential backoff (capped at max_backoff_ms)
                    current_backoff_ms = @min(
                        @as(u32, @intFromFloat(@as(f32, @floatFromInt(current_backoff_ms)) * retry_config.backoff_multiplier)),
                        retry_config.max_backoff_ms,
                    );
                } else {
                    logging.logWarning("Pipe busy after {d} attempts, giving up\n", .{retry_config.max_retries});
                    return error.PipeBusy;
                }
            },
            .FILE_NOT_FOUND => {
                // Pipe doesn't exist (server not running)
                logging.logWarning("Named pipe not found: {s}\n", .{pipe_name});
                return error.FileNotFound;
            },
            .ACCESS_DENIED => {
                // Permission denied
                logging.logWarning("Access denied to named pipe: {s}\n", .{pipe_name});
                return error.AccessDenied;
            },
            else => {
                // Unexpected error
                logging.logWarning("CreateFileW failed with error: {any}\n", .{err});
                return error.ConnectFailed;
            },
        }
    }

    // Exhausted all retries
    logging.logWarning("Failed to connect after {d} attempts\n", .{retry_config.max_retries});
    return error.ConnectionFailed;
}

// ============================================================================
// I/O Helper Functions
// ============================================================================

/// Check if a Named Pipe error indicates the pipe is closed or broken
///
/// Returns true for errors that indicate the pipe is no longer usable:
/// - ERROR_NO_DATA: Pipe is closing (after DisconnectNamedPipe)
/// - ERROR_BROKEN_PIPE: Client disconnected abruptly
/// - ERROR_PIPE_NOT_CONNECTED: Pipe was never connected or already disconnected
///
/// Use this to distinguish graceful closure from other I/O errors.
pub fn isPipeClosedError(err: windows.Win32Error) bool {
    return switch (err) {
        ERROR_NO_DATA, ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED => true,
        else => false,
    };
}

/// Safe ReadFile wrapper for Named Pipes with proper error handling
///
/// Handles common Named Pipe read errors:
/// - ERROR_NO_DATA: Returns 0 bytes (EOF)
/// - ERROR_BROKEN_PIPE: Returns error.BrokenPipe
/// - ERROR_PIPE_NOT_CONNECTED: Returns error.NotConnected
///
/// Example:
/// ```zig
/// var buffer: [1024]u8 = undefined;
/// const bytes_read = try readNamedPipe(pipe_handle, &buffer);
/// if (bytes_read == 0) {
///     // EOF - pipe closed gracefully
/// }
/// ```
pub fn readNamedPipe(handle: windows.HANDLE, buffer: []u8) !usize {
    var bytes_read: windows.DWORD = 0;
    const result = kernel32.ReadFile(
        handle,
        buffer.ptr,
        @intCast(buffer.len),
        &bytes_read,
        null, // No overlapped I/O
    );

    if (result == 0) {
        const err = windows.GetLastError();
        switch (err) {
            ERROR_NO_DATA => {
                // Pipe is closing - return 0 (EOF)
                logging.log(1, "Named pipe read: ERROR_NO_DATA (pipe closing)\n", .{});
                return 0;
            },
            ERROR_BROKEN_PIPE => {
                // Client disconnected abruptly
                logging.log(1, "Named pipe read: ERROR_BROKEN_PIPE (client disconnected)\n", .{});
                return error.BrokenPipe;
            },
            ERROR_PIPE_NOT_CONNECTED => {
                // Pipe not connected
                logging.log(1, "Named pipe read: ERROR_PIPE_NOT_CONNECTED\n", .{});
                return error.NotConnected;
            },
            else => {
                // Other error
                logging.logWarning("ReadFile failed: {any}\n", .{err});
                return error.ReadFailed;
            },
        }
    }

    return bytes_read;
}

/// Safe WriteFile wrapper for Named Pipes with proper error handling
///
/// Handles common Named Pipe write errors:
/// - ERROR_NO_DATA: Returns error.PipeClosed
/// - ERROR_BROKEN_PIPE: Returns error.BrokenPipe
/// - ERROR_PIPE_NOT_CONNECTED: Returns error.NotConnected
///
/// Returns number of bytes actually written (may be less than buffer.len).
///
/// Example:
/// ```zig
/// const message = "Hello, pipe!";
/// const bytes_written = try writeNamedPipe(pipe_handle, message);
/// if (bytes_written < message.len) {
///     // Partial write - handle accordingly
/// }
/// ```
pub fn writeNamedPipe(handle: windows.HANDLE, buffer: []const u8) !usize {
    var bytes_written: windows.DWORD = 0;
    const result = kernel32.WriteFile(
        handle,
        buffer.ptr,
        @intCast(buffer.len),
        &bytes_written,
        null, // No overlapped I/O
    );

    if (result == 0) {
        const err = windows.GetLastError();
        switch (err) {
            ERROR_NO_DATA => {
                // Pipe is closing
                logging.log(1, "Named pipe write: ERROR_NO_DATA (pipe closing)\n", .{});
                return error.PipeClosed;
            },
            ERROR_BROKEN_PIPE => {
                // Client disconnected abruptly
                logging.log(1, "Named pipe write: ERROR_BROKEN_PIPE (client disconnected)\n", .{});
                return error.BrokenPipe;
            },
            ERROR_PIPE_NOT_CONNECTED => {
                // Pipe not connected
                logging.log(1, "Named pipe write: ERROR_PIPE_NOT_CONNECTED\n", .{});
                return error.NotConnected;
            },
            else => {
                // Other error
                logging.logWarning("WriteFile failed: {any}\n", .{err});
                return error.WriteFailed;
            },
        }
    }

    return bytes_written;
}

/// Check if there's data available to read from Named Pipe (non-blocking)
///
/// Uses PeekNamedPipe to check for available data without consuming it.
/// Returns the number of bytes available to read.
///
/// Example:
/// ```zig
/// const available = try peekNamedPipe(pipe_handle);
/// if (available > 0) {
///     // Data is available - safe to read without blocking
/// }
/// ```
pub fn peekNamedPipe(handle: windows.HANDLE) !usize {
    var bytes_available: windows.DWORD = 0;
    const result = PeekNamedPipe(
        handle,
        null, // Don't copy data
        0,
        null, // Don't care about bytes read
        &bytes_available,
        null, // Don't care about bytes left in message
    );

    if (result == 0) {
        const err = windows.GetLastError();
        if (isPipeClosedError(err)) {
            // Pipe closed - return 0
            return 0;
        }
        logging.logWarning("PeekNamedPipe failed: {any}\n", .{err});
        return error.PeekFailed;
    }

    return bytes_available;
}

// ============================================================================
// Tests
// ============================================================================

test "translatePath basic" {
    const allocator = std.testing.allocator;

    const pipe_name = try translatePath(allocator, "/tmp/test.sock");
    defer allocator.free(pipe_name);

    try std.testing.expectEqualStrings("\\\\.\\pipe\\test", pipe_name);
}

test "translatePath without extension" {
    const allocator = std.testing.allocator;

    const pipe_name = try translatePath(allocator, "/tmp/myapp");
    defer allocator.free(pipe_name);

    try std.testing.expectEqualStrings("\\\\.\\pipe\\myapp", pipe_name);
}

test "translatePath windows path" {
    const allocator = std.testing.allocator;

    const pipe_name = try translatePath(allocator, "C:\\temp\\app.sock");
    defer allocator.free(pipe_name);

    try std.testing.expectEqualStrings("\\\\.\\pipe\\app", pipe_name);
}
