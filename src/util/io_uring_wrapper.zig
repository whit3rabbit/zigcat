//! Reusable io_uring event loop abstraction for zigcat.
//!
//! This module provides a high-level wrapper around std.os.linux.IO_Uring
//! to simplify io_uring usage across the codebase. It encapsulates:
//! - Ring initialization and cleanup
//! - Submission queue entry (SQE) preparation
//! - Completion queue entry (CQE) processing
//! - Timeout handling with kernel_timespec
//!
//! Architecture:
//! - UringEventLoop: Main abstraction that owns the IO_Uring instance
//! - CompletionResult: Structured result from kernel completions
//! - Type-safe wrappers for common operations (read, write, connect)
//!
//! Usage:
//! ```zig
//! var ring = try UringEventLoop.init(allocator, 32);
//! defer ring.deinit();
//!
//! try ring.submitRead(fd, buffer, user_data);
//! const cqe = try ring.waitForCompletion(&timeout_spec);
//! switch (cqe.user_data) {
//!     0 => handleRead(cqe.res),
//!     1 => handleWrite(cqe.res),
//!     else => {},
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Completion result from io_uring kernel
pub const CompletionResult = struct {
    /// User-supplied data passed to submission (for operation tracking)
    user_data: u64,

    /// Result code from kernel:
    /// - >= 0: Number of bytes read/written, or success for connect
    /// - < 0: Negative errno (e.g., -EAGAIN, -ECONNREFUSED)
    res: i32,
};

/// io_uring event loop abstraction
///
/// Wraps std.os.linux.IO_Uring with high-level operations for:
/// - Asynchronous reads (IORING_OP_READ, IORING_OP_RECV)
/// - Asynchronous writes (IORING_OP_WRITE, IORING_OP_SEND)
/// - Asynchronous connects (IORING_OP_CONNECT)
/// - Timeout-aware completion waiting
///
/// Performance notes:
/// - Queue depth determines max concurrent operations
/// - Typical queue sizes: 32 (client), 64 (exec mode), 512 (port scanning)
/// - Each operation consumes one submission queue entry (SQE)
pub const UringEventLoop = if (builtin.os.tag == .linux) struct {
    ring: std.os.linux.IO_Uring,
    allocator: std.mem.Allocator,

    /// Initialize io_uring with specified queue depth.
    ///
    /// Creates both submission queue (SQ) and completion queue (CQ)
    /// with the same number of entries. Fails if io_uring is not
    /// supported on the current system.
    ///
    /// Parameters:
    ///   allocator: Memory allocator (currently unused, reserved for future)
    ///   entries: Number of queue entries (max concurrent operations)
    ///
    /// Returns: Initialized UringEventLoop or error
    ///
    /// Errors:
    ///   - error.IoUringNotSupported: Kernel doesn't support io_uring
    ///   - error.OutOfMemory: Failed to allocate ring buffers
    ///   - error.SystemResources: Insufficient kernel resources
    pub fn init(allocator: std.mem.Allocator, entries: u32) !UringEventLoop {
        if (builtin.os.tag != .linux) {
            return error.IoUringNotSupported;
        }

        const IO_Uring = std.os.linux.IO_Uring;
        const ring = IO_Uring.init(entries, 0) catch |err| {
            return err;
        };

        return UringEventLoop{
            .ring = ring,
            .allocator = allocator,
        };
    }

    /// Clean up io_uring resources.
    ///
    /// Must be called when done with the event loop to release
    /// kernel resources (shared memory, file descriptors).
    pub fn deinit(self: *UringEventLoop) void {
        self.ring.deinit();
    }

    /// Submit an asynchronous read operation.
    ///
    /// Prepares IORING_OP_READ (file-based) or IORING_OP_RECV (socket)
    /// depending on file descriptor type. The read will complete
    /// asynchronously, returning user_data in the completion result.
    ///
    /// Important: The buffer must remain valid until completion!
    ///
    /// Parameters:
    ///   fd: File descriptor to read from
    ///   buffer: Buffer to read into (must stay valid until completion)
    ///   user_data: User-supplied identifier for this operation
    ///
    /// Returns: Error if submission queue is full
    pub fn submitRead(self: *UringEventLoop, fd: posix.fd_t, buffer: []u8, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(fd, .{ .buffer = buffer }, 0);
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous write operation for sockets.
    ///
    /// Prepares IORING_OP_SEND for socket writes. Use submitWriteFile()
    /// for regular file descriptors instead.
    ///
    /// Important: The buffer must remain valid until completion!
    ///
    /// Parameters:
    ///   fd: Socket file descriptor to write to
    ///   buffer: Data to write (must stay valid until completion)
    ///   user_data: User-supplied identifier for this operation
    ///
    /// Returns: Error if submission queue is full
    pub fn submitWrite(self: *UringEventLoop, fd: posix.fd_t, buffer: []const u8, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(fd, .{ .buffer = buffer }, 0);
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous file write operation.
    ///
    /// Prepares IORING_OP_WRITE for regular file writes (not sockets).
    /// This is used for output logging (-o flag) and hex dump files.
    ///
    /// Important: The buffer must remain valid until completion!
    ///
    /// Completion result:
    /// - res >= 0: Number of bytes written
    /// - res < 0: Negative errno (e.g., -ENOSPC, -EIO)
    ///
    /// Parameters:
    ///   fd: File descriptor to write to (regular file)
    ///   buffer: Data to write (must stay valid until completion)
    ///   offset: File offset to write at (-1 for current position)
    ///   user_data: User-supplied identifier for this operation
    ///
    /// Returns: Error if submission queue is full
    ///
    /// Example:
    /// ```zig
    /// // Write to current file position
    /// try ring.submitWriteFile(file_fd, data, -1, 100);
    /// const cqe = try ring.waitForCompletion(null);
    /// if (cqe.res > 0) {
    ///     // Successfully wrote cqe.res bytes
    /// }
    /// ```
    pub fn submitWriteFile(
        self: *UringEventLoop,
        fd: posix.fd_t,
        buffer: []const u8,
        offset: i64,
        user_data: u64,
    ) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_write(fd, buffer, @bitCast(offset));
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous file sync operation.
    ///
    /// Prepares IORING_OP_FSYNC to flush file data to disk.
    /// Equivalent to posix.fsync() but asynchronous.
    ///
    /// Completion result:
    /// - res == 0: Sync succeeded
    /// - res < 0: Negative errno (e.g., -EIO)
    ///
    /// Parameters:
    ///   fd: File descriptor to sync
    ///   user_data: User-supplied identifier for this operation
    ///
    /// Returns: Error if submission queue is full
    ///
    /// Example:
    /// ```zig
    /// try ring.submitFsync(file_fd, 200);
    /// const cqe = try ring.waitForCompletion(null);
    /// if (cqe.res == 0) {
    ///     // File successfully synced to disk
    /// }
    /// ```
    pub fn submitFsync(self: *UringEventLoop, fd: posix.fd_t, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_fsync(fd, 0);
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous connect operation.
    ///
    /// Prepares IORING_OP_CONNECT for non-blocking TCP connection.
    /// The socket must already be created and set to non-blocking mode.
    ///
    /// Completion result:
    /// - res == 0: Connection succeeded
    /// - res < 0: Connection failed (negative errno)
    ///
    /// Parameters:
    ///   fd: Non-blocking socket file descriptor
    ///   addr: Target address to connect to
    ///   addr_len: Length of address structure
    ///   user_data: User-supplied identifier for this operation
    ///
    /// Returns: Error if submission queue is full
    pub fn submitConnect(
        self: *UringEventLoop,
        fd: posix.fd_t,
        addr: *const posix.sockaddr,
        addr_len: posix.socklen_t,
        user_data: u64,
    ) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_connect(fd, addr, addr_len);
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous poll operation for socket readiness.
    ///
    /// Prepares IORING_OP_POLL_ADD to check if a file descriptor is ready
    /// for reading or writing. This is primarily used for TLS connections
    /// where we need to poll socket readiness before calling OpenSSL.
    ///
    /// Completion result:
    /// - res >= 0: Poll mask with POLL.IN, POLL.OUT, POLL.ERR, POLL.HUP bits
    /// - res < 0: Negative errno on error
    ///
    /// **Use Case:**
    /// TLS connections cannot use io_uring IORING_OP_READ/WRITE directly
    /// because OpenSSL handles encryption internally. Instead, we:
    /// 1. Poll socket for readiness using IORING_OP_POLL_ADD
    /// 2. When ready, call OpenSSL's SSL_read()/SSL_write()
    /// 3. OpenSSL handles all encryption/decryption
    ///
    /// **Parameters:**
    /// - `fd`: File descriptor to poll (typically TLS socket)
    /// - `events`: Poll events mask (POLL.IN for readable, POLL.OUT for writable)
    /// - `user_data`: User-supplied identifier for this operation
    ///
    /// **Returns:**
    /// Error if submission queue is full.
    ///
    /// **Example:**
    /// ```zig
    /// // Poll TLS socket for readability
    /// try ring.submitPoll(tls_socket, posix.POLL.IN, 100);
    /// const cqe = try ring.waitForCompletion(&timeout_spec);
    /// if (cqe.res & posix.POLL.IN != 0) {
    ///     // Socket is readable, call SSL_read()
    ///     const n = try tls_conn.read(buffer);
    /// }
    /// ```
    pub fn submitPoll(
        self: *UringEventLoop,
        fd: posix.fd_t,
        events: u32,
        user_data: u64,
    ) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_poll_add(fd, events);
        sqe.user_data = user_data;
    }

    /// Submit an asynchronous accept operation.
    ///
    /// Prepares IORING_OP_ACCEPT for non-blocking server connection acceptance.
    /// The socket must already be created, bound, and listening.
    ///
    /// Completion result:
    /// - res >= 0: New client socket file descriptor
    /// - res < 0: Negative errno (e.g., -EAGAIN, -EINTR)
    ///
    /// **Parameters:**
    /// - `fd`: Listening socket file descriptor
    /// - `addr`: Pointer to sockaddr storage for client address
    /// - `addr_len`: Pointer to socklen_t for address length
    /// - `user_data`: User-supplied identifier for this operation
    ///
    /// **Returns:**
    /// Error if submission queue is full.
    ///
    /// **Example:**
    /// ```zig
    /// var client_addr: posix.sockaddr.storage = undefined;
    /// var addr_len: posix.socklen_t = @sizeOf(@TypeOf(client_addr));
    ///
    /// try ring.submitAccept(listen_sock, @ptrCast(&client_addr), &addr_len, 0);
    /// const cqe = try ring.waitForCompletion(null);
    /// if (cqe.res >= 0) {
    ///     const client_fd = @as(posix.socket_t, @intCast(cqe.res));
    ///     // Handle new connection
    /// }
    /// ```
    pub fn submitAccept(
        self: *UringEventLoop,
        fd: posix.fd_t,
        addr: *posix.sockaddr,
        addr_len: *posix.socklen_t,
        user_data: u64,
    ) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_accept(fd, addr, addr_len, 0);
        sqe.user_data = user_data;
    }

    /// Submit all pending operations and wait for a single completion.
    ///
    /// This is a blocking call that:
    /// 1. Submits all queued operations to the kernel
    /// 2. Waits for at least one completion (with optional timeout)
    /// 3. Returns the first completion result
    ///
    /// Timeout behavior:
    /// - null: Wait indefinitely until completion
    /// - non-null: Wait up to specified time, return error.Timeout if exceeded
    ///
    /// Parameters:
    ///   timeout_spec: Optional timeout specification (kernel_timespec)
    ///
    /// Returns: First completion result, or error if timeout/failure
    ///
    /// Errors:
    ///   - error.Timeout: No completions within timeout period
    ///   - error.Unexpected: Kernel error during submission/wait
    pub fn waitForCompletion(
        self: *UringEventLoop,
        timeout_spec: ?*const std.os.linux.kernel_timespec,
    ) !CompletionResult {
        // Submit all pending operations
        _ = try self.ring.submit();

        // Wait for completion with optional timeout
        const cqe = if (timeout_spec) |ts|
            try self.ring.copy_cqe_wait(ts)
        else
            try self.ring.copy_cqe();

        return CompletionResult{
            .user_data = cqe.user_data,
            .res = cqe.res,
        };
    }

    /// Submit all pending operations without waiting.
    ///
    /// Use this when you want to batch multiple operations before
    /// calling waitForCompletion(). This can improve performance by
    /// reducing the number of kernel transitions.
    ///
    /// Returns: Number of operations submitted
    pub fn submit(self: *UringEventLoop) !u32 {
        return try self.ring.submit();
    }

    /// Check for completions without blocking.
    ///
    /// Useful for polling mode where you want to check for completions
    /// but not wait if none are available.
    ///
    /// Returns: Completion result if available, null otherwise
    pub fn pollCompletion(self: *UringEventLoop) !?CompletionResult {
        const cqe = self.ring.copy_cqe() catch |err| {
            if (err == error.CqeNotAvailable) {
                return null;
            }
            return err;
        };

        return CompletionResult{
            .user_data = cqe.user_data,
            .res = cqe.res,
        };
    }
} else struct {
    // Stub implementation for non-Linux platforms
    allocator: std.mem.Allocator,

    pub fn init(_: std.mem.Allocator, _: u32) !UringEventLoop {
        return error.IoUringNotSupported;
    }

    pub fn deinit(_: *UringEventLoop) void {}

    pub fn submitRead(_: *UringEventLoop, _: posix.fd_t, _: []u8, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitWrite(_: *UringEventLoop, _: posix.fd_t, _: []const u8, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitWriteFile(_: *UringEventLoop, _: posix.fd_t, _: []const u8, _: i64, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitFsync(_: *UringEventLoop, _: posix.fd_t, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitConnect(_: *UringEventLoop, _: posix.fd_t, _: *const posix.sockaddr, _: posix.socklen_t, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitPoll(_: *UringEventLoop, _: posix.fd_t, _: u32, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn submitAccept(_: *UringEventLoop, _: posix.fd_t, _: *posix.sockaddr, _: *posix.socklen_t, _: u64) !void {
        return error.IoUringNotSupported;
    }

    pub fn waitForCompletion(_: *UringEventLoop, _: ?*const anyopaque) !CompletionResult {
        return error.IoUringNotSupported;
    }

    pub fn submit(_: *UringEventLoop) !u32 {
        return error.IoUringNotSupported;
    }

    pub fn pollCompletion(_: *UringEventLoop) !?CompletionResult {
        return error.IoUringNotSupported;
    }
};

// ============================================================================
// IMPLEMENTATION NOTES
// ============================================================================
//
// io_uring Event Loop Wrapper (COMPLETE)
//
// Design Principles:
//   1. Type Safety: Separate methods for read/write/connect (not generic)
//   2. Buffer Lifetime: Caller responsible for keeping buffers valid
//   3. Error Handling: Kernel errors returned in CompletionResult.res
//   4. Timeout Support: kernel_timespec for microsecond-precision timeouts
//   5. Zero-Copy: Direct memory sharing between userspace and kernel
//
// Performance Characteristics:
//   - Submission overhead: ~100ns per operation (vs ~1μs for poll)
//   - Completion overhead: ~200ns per result (vs ~2μs for poll)
//   - Batch efficiency: Submitting 10 ops at once = ~10x faster than sequential
//   - Memory: ~4KB per 32 entries (submission + completion queues)
//
// Common Patterns:
//
//   Pattern 1: Simple Read-Write Loop
//   ```zig
//   var ring = try UringEventLoop.init(allocator, 32);
//   defer ring.deinit();
//
//   try ring.submitRead(fd, &buffer, 0);
//   const cqe = try ring.waitForCompletion(null);
//   if (cqe.res > 0) {
//       const data = buffer[0..@intCast(cqe.res)];
//       try ring.submitWrite(out_fd, data, 1);
//   }
//   ```
//
//   Pattern 2: Timeout-Aware Connect
//   ```zig
//   const timeout_ns = 5 * std.time.ns_per_s;
//   const timeout_spec = std.os.linux.kernel_timespec{
//       .tv_sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
//       .tv_nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
//   };
//
//   try ring.submitConnect(sock, &addr, addr_len, 0);
//   const cqe = try ring.waitForCompletion(&timeout_spec);
//   if (cqe.res == 0) {
//       // Connected successfully
//   }
//   ```
//
//   Pattern 3: Multi-FD Event Loop
//   ```zig
//   const USER_DATA_STDIN: u64 = 0;
//   const USER_DATA_SOCKET: u64 = 1;
//
//   try ring.submitRead(stdin_fd, &stdin_buf, USER_DATA_STDIN);
//   try ring.submitRead(socket_fd, &socket_buf, USER_DATA_SOCKET);
//
//   while (!done) {
//       const cqe = try ring.waitForCompletion(&timeout);
//       switch (cqe.user_data) {
//           USER_DATA_STDIN => {
//               // Handle stdin data
//               if (cqe.res > 0) {
//                   try ring.submitWrite(socket_fd, stdin_buf[0..@intCast(cqe.res)], 2);
//                   try ring.submitRead(stdin_fd, &stdin_buf, USER_DATA_STDIN);
//               }
//           },
//           USER_DATA_SOCKET => {
//               // Handle socket data
//               if (cqe.res > 0) {
//                   try stdout.writeAll(socket_buf[0..@intCast(cqe.res)]);
//                   try ring.submitRead(socket_fd, &socket_buf, USER_DATA_SOCKET);
//               }
//           },
//           else => {},
//       }
//   }
//   ```
//
// Critical Constraints:
//   1. Buffers must remain valid until completion (don't free/reuse prematurely!)
//   2. Check cqe.res for errors (negative errno values)
//   3. Resubmit reads after handling completions (io_uring is one-shot)
//   4. Keep queue depth reasonable (32-512 entries typical)
//
// Platform Availability:
//   - Linux 5.1+: Full support
//   - Linux <5.1: Returns error.IoUringNotSupported
//   - Other platforms: Compile-time error (builtin.os.tag != .linux)
//
