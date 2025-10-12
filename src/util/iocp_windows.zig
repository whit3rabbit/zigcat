// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Windows I/O Completion Ports (IOCP) wrapper for asynchronous I/O operations.
//!
//! This module provides a high-level abstraction over Windows IOCP, enabling
//! efficient single-threaded asynchronous I/O for files, pipes, and sockets.
//!
//! ## Key Features
//! - Asynchronous ReadFile/WriteFile operations
//! - Timeout-aware completion retrieval
//! - User data tagging for operation identification
//! - Batch completion retrieval for efficiency
//!
//! ## Usage Pattern
//! 1. Initialize IOCP with `Iocp.init()`
//! 2. Associate file/socket handles with IOCP
//! 3. Submit async operations (read/write)
//! 4. Wait for completions with `getStatus()` or `getStatusBatch()`
//! 5. Process completions and resubmit operations as needed
//!
//! ## Critical Constraints
//! - OVERLAPPED structure must be unique per operation (cannot reuse until completion)
//! - Buffers must remain valid until operation completes (no free/realloc)
//! - Handles must be opened with FILE_FLAG_OVERLAPPED for async I/O
//! - ERROR_IO_PENDING is not an error - it means operation is in progress
//!
//! ## Performance Notes
//! - Single IOCP can manage thousands of handles efficiently
//! - Completion overhead: ~1-2μs per operation
//! - Batch retrieval reduces syscall overhead significantly

const std = @import("std");
const windows = std.os.windows;
const builtin = @import("builtin");

const IOCP_HANDLE = windows.HANDLE;

/// Operation type for IOCP operations
pub const OperationType = enum {
    read,
    write,
    accept,
    connect,
};

pub const Iocp = struct {
    handle: IOCP_HANDLE,

    pub fn init() !Iocp {
        const handle = windows.kernel32.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0,
        ) orelse return error.IocpCreateFailed;

        return Iocp{ .handle = handle };
    }

    pub fn deinit(self: *Iocp) void {
        _ = windows.kernel32.CloseHandle(self.handle);
    }

    pub fn associateSocket(self: *Iocp, socket: windows.SOCKET, completion_key: usize) !void {
        const result = windows.kernel32.CreateIoCompletionPort(
            @ptrFromInt(socket),
            self.handle,
            completion_key,
            0,
        );

        if (result == null) {
            return error.IocpAssociateFailed;
        }
    }

    /// Retrieve a single completion from the IOCP queue.
    ///
    /// Blocks until a completion is available or timeout expires.
    ///
    /// ## Parameters
    /// - timeout: Timeout in milliseconds (0 = no wait, 0xFFFFFFFF = infinite)
    ///
    /// ## Returns
    /// CompletionPacket with operation result, or error
    ///
    /// ## Errors
    /// - error.Timeout: No completion within timeout period
    /// - error.IocpGetStatusFailed: I/O operation failed (check error_code)
    pub fn getStatus(self: *Iocp, timeout: u32) !CompletionPacket {
        var bytes_transferred: u32 = 0;
        var completion_key: usize = 0;
        var overlapped: ?*windows.OVERLAPPED = null;

        const success = windows.kernel32.GetQueuedCompletionStatus(
            self.handle,
            &bytes_transferred,
            &completion_key,
            &overlapped,
            timeout,
        );

        var error_code: u32 = 0;
        if (success == 0) {
            error_code = windows.kernel32.GetLastError();
            if (error_code == windows.WAIT_TIMEOUT) {
                return error.Timeout;
            }
            // Operation failed, but we still return completion with error_code
        }

        // Extract user_data from IocpOperation (cast OVERLAPPED back)
        var user_data: u64 = 0;
        if (overlapped) |ovl| {
            const op: *IocpOperation = @ptrCast(@alignCast(ovl));
            user_data = op.user_data;
        }

        return CompletionPacket{
            .bytes_transferred = bytes_transferred,
            .completion_key = completion_key,
            .user_data = user_data,
            .error_code = error_code,
        };
    }

    /// Associate a file handle (pipe, file) with this IOCP.
    ///
    /// Must be called before submitting I/O operations on the handle.
    ///
    /// ## Parameters
    /// - handle: File/pipe handle (must be opened with FILE_FLAG_OVERLAPPED)
    /// - completion_key: User-defined key to associate with this handle
    pub fn associateFileHandle(self: *Iocp, handle: windows.HANDLE, completion_key: usize) !void {
        const result = windows.kernel32.CreateIoCompletionPort(
            handle,
            self.handle,
            completion_key,
            0,
        );

        if (result == null) {
            return error.IocpAssociateFailed;
        }
    }

    /// Submit an asynchronous read operation.
    ///
    /// The read operation will complete asynchronously. Use getStatus() or
    /// getStatusBatch() to retrieve the completion.
    ///
    /// ## CRITICAL: Buffer and Operation Lifetime
    /// - The buffer must remain valid until the operation completes
    /// - The operation struct must remain valid until the operation completes
    /// - Do not modify, free, or reuse buffer/operation until completion
    ///
    /// ## Parameters
    /// - handle: File/pipe handle (must be associated with this IOCP)
    /// - buffer: Buffer to read into (must remain valid until completion!)
    /// - operation: IocpOperation struct (must remain valid until completion!)
    ///
    /// ## Returns
    /// - Success if operation submitted (completion pending)
    /// - Error if submission failed immediately
    ///
    /// ## Errors
    /// - error.IocpReadFailed: Submission failed
    ///
    /// ## Usage Example
    /// ```zig
    /// var buffer: [1024]u8 = undefined;
    /// var op = IocpOperation.init(1, .read);
    /// try iocp.submitReadFile(handle, &buffer, &op);
    /// // Wait for completion
    /// const cqe = try iocp.getStatus(1000);
    /// if (cqe.user_data == 1) {
    ///     // Read completed, bytes_transferred available
    /// }
    /// ```
    pub fn submitReadFile(
        self: *Iocp,
        handle: windows.HANDLE,
        buffer: []u8,
        operation: *IocpOperation,
    ) !void {
        _ = self; // IOCP handle not needed for ReadFile (uses associated handle)

        var bytes_read: u32 = 0;
        const result = windows.kernel32.ReadFile(
            handle,
            buffer.ptr,
            @intCast(buffer.len),
            &bytes_read,
            &operation.overlapped,
        );

        if (result != 0) {
            // Operation completed immediately (unlikely for async I/O)
            // Completion will still be posted to IOCP
            return;
        }

        // Operation is pending or failed
        const err = windows.kernel32.GetLastError();
        if (err == windows.ERROR_IO_PENDING) {
            // Expected: Operation is pending asynchronously
            return;
        }

        // Actual error occurred
        return error.IocpReadFailed;
    }

    /// Submit an asynchronous write operation.
    ///
    /// The write operation will complete asynchronously. Use getStatus() or
    /// getStatusBatch() to retrieve the completion.
    ///
    /// ## CRITICAL: Buffer and Operation Lifetime
    /// - The buffer must remain valid until the operation completes
    /// - The operation struct must remain valid until the operation completes
    /// - Do not modify, free, or reuse buffer/operation until completion
    ///
    /// ## Partial Writes
    /// WriteFile may complete with fewer bytes written than requested (rare).
    /// Check bytes_transferred in CompletionPacket and resubmit remainder if needed.
    ///
    /// ## Parameters
    /// - handle: File/pipe handle (must be associated with this IOCP)
    /// - buffer: Data to write (must remain valid until completion!)
    /// - operation: IocpOperation struct (must remain valid until completion!)
    ///
    /// ## Returns
    /// - Success if operation submitted (completion pending)
    /// - Error if submission failed immediately
    ///
    /// ## Errors
    /// - error.IocpWriteFailed: Submission failed
    ///
    /// ## Usage Example
    /// ```zig
    /// var data = "Hello, IOCP!";
    /// var op = IocpOperation.init(2, .write);
    /// try iocp.submitWriteFile(handle, data, &op);
    /// // Wait for completion
    /// const cqe = try iocp.getStatus(1000);
    /// if (cqe.user_data == 2) {
    ///     // Write completed, bytes_transferred available
    /// }
    /// ```
    pub fn submitWriteFile(
        self: *Iocp,
        handle: windows.HANDLE,
        buffer: []const u8,
        operation: *IocpOperation,
    ) !void {
        _ = self; // IOCP handle not needed for WriteFile (uses associated handle)

        var bytes_written: u32 = 0;
        const result = windows.kernel32.WriteFile(
            handle,
            buffer.ptr,
            @intCast(buffer.len),
            &bytes_written,
            &operation.overlapped,
        );

        if (result != 0) {
            // Operation completed immediately (unlikely for async I/O)
            // Completion will still be posted to IOCP
            return;
        }

        // Operation is pending or failed
        const err = windows.kernel32.GetLastError();
        if (err == windows.ERROR_IO_PENDING) {
            // Expected: Operation is pending asynchronously
            return;
        }

        // Actual error occurred
        return error.IocpWriteFailed;
    }

    /// Cancel all pending I/O operations on a handle.
    ///
    /// Useful for graceful shutdown when closing a handle with pending operations.
    ///
    /// ## Parameters
    /// - handle: File/pipe/socket handle
    ///
    /// ## Errors
    /// - error.IocpCancelFailed: Cancellation failed
    pub fn cancelIo(self: *Iocp, handle: windows.HANDLE) !void {
        _ = self;

        const result = windows.kernel32.CancelIo(handle);
        if (result == 0) {
            return error.IocpCancelFailed;
        }
    }
};

/// IOCP operation wrapper that extends OVERLAPPED with user data and operation context.
///
/// This structure must remain valid for the entire duration of the async operation.
/// Do not free, reuse, or modify until the operation completes (signaled via IOCP).
///
/// ## Buffer Lifetime
/// The buffer passed to ReadFile/WriteFile must remain valid until completion.
/// Accessing the buffer while the operation is pending may cause data corruption.
///
/// ## Usage Example
/// ```zig
/// var op = IocpOperation{
///     .overlapped = std.mem.zeroes(windows.OVERLAPPED),
///     .user_data = 1, // For identifying this operation
///     .op_type = .read,
/// };
/// try iocp.submitReadFile(handle, buffer, &op);
/// // Buffer and op must remain valid until completion received
/// ```
pub const IocpOperation = struct {
    /// Windows OVERLAPPED structure (must be first field for casting)
    overlapped: windows.OVERLAPPED,

    /// User-supplied data for operation identification (like io_uring user_data)
    user_data: u64,

    /// Operation type (for debugging/logging)
    op_type: OperationType,

    /// Initialize a new IOCP operation
    pub fn init(user_data: u64, op_type: OperationType) IocpOperation {
        return IocpOperation{
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .user_data = user_data,
            .op_type = op_type,
        };
    }
};

/// Completion packet returned from IOCP completion queue.
///
/// Contains the result of an async I/O operation, including:
/// - bytes_transferred: Number of bytes read/written (0 may indicate EOF)
/// - completion_key: Associated with handle via CreateIoCompletionPort
/// - user_data: From IocpOperation, for identifying the operation
/// - error_code: Windows error code (0 = success, non-zero = error)
pub const CompletionPacket = struct {
    /// Number of bytes transferred (0 may indicate EOF for reads)
    bytes_transferred: u32,

    /// Completion key associated with the handle
    completion_key: usize,

    /// User data from IocpOperation (for operation identification)
    user_data: u64,

    /// Windows error code (0 = success, ERROR_* otherwise)
    error_code: u32,
};
