# TODO: io_uring Provided Buffers Implementation for ExecSession

> **Project Status**: Planning Phase
> **Target Kernel**: Linux 5.7+ (provided buffers with automatic selection)
> **Expected Performance Gain**: 10-15% CPU reduction, 2-3x throughput improvement vs standard io_uring
> **Fallback Strategy**: uring_provided → uring_standard → poll (3-tier system)

---

## Executive Summary

This document outlines the implementation plan for adding `io_uring` provided buffer support to the `ExecSession` backend in zigcat. Provided buffers (introduced in Linux kernel 5.7) allow the kernel to automatically select buffers from a pre-registered pool, eliminating per-operation buffer mapping overhead and improving cache locality.

### Why Provided Buffers?

**Current State**: The existing `UringSession` backend passes buffers with each I/O request, requiring the kernel to:
1. Map user-space buffer addresses for each operation
2. Perform virtual-to-physical address translation
3. Pin pages in memory during I/O

**With Provided Buffers**: The kernel:
1. Pre-maps an entire buffer pool once during registration
2. Automatically selects an available buffer for each operation
3. Returns the buffer index via CQE flags (no address translation needed)

### Terminology Clarification

There are **two distinct buffer registration mechanisms** in io_uring:

| Feature | Kernel Version | Operation | Use Case |
|---------|---------------|-----------|----------|
| **Fixed Buffers** | 5.1+ | `IORING_REGISTER_BUFFERS` + `IORING_OP_READ_FIXED` | O_DIRECT file I/O, explicit buffer indices |
| **Provided Buffers** | 5.7+ | `IORING_OP_PROVIDE_BUFFERS` + automatic selection | Network I/O, kernel picks buffer |

**This implementation targets Provided Buffers** because:
- ✅ Designed for socket I/O (our primary use case)
- ✅ Automatic buffer management (simpler state tracking)
- ✅ Works with standard recv/send operations
- ✅ Better fit for variable-length network messages

---

## Research Findings

### 1. Kernel API Requirements

#### Provided Buffers API (Kernel 5.7+)

```c
// C API (for reference)
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_provide_buffers(sqe, buffers, buffer_len, nr_buffers, bgid, bid);

// On completion:
if (cqe->flags & IORING_CQE_F_BUFFER) {
    int buffer_id = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
    // Use buffer_id to find the buffer in your pool
}
```

#### Zig Implementation Strategy

Since Zig 0.15.1's `std.os.linux.IO_Uring` does not expose `prep_provide_buffers()` directly, we must:

1. **Option A**: Use raw SQE manipulation:
```zig
const sqe = try ring.get_sqe();
sqe.opcode = .PROVIDE_BUFFERS;
sqe.fd = -1;
sqe.addr = @intFromPtr(buffer_pool.ptr);
sqe.len = buffer_size;
sqe.off = buffer_start_id;
sqe.buf_index = buffer_group_id;
```

2. **Option B**: Extend `io_uring_wrapper.zig` with proper helper:
```zig
pub fn submitProvideBuffers(
    self: *UringEventLoop,
    buffers: []u8,
    buffer_len: u32,
    nr_buffers: u16,
    bgid: u16,
    bid: u16,
) !void {
    const sqe = try self.ring.get_sqe();
    // Manually prepare PROVIDE_BUFFERS SQE
    sqe.opcode = std.os.linux.IORING_OP.PROVIDE_BUFFERS;
    sqe.fd = -1;
    sqe.addr = @intFromPtr(buffers.ptr);
    sqe.len = buffer_len;
    sqe.off = bid;
    sqe.buf_index = bgid;
}
```

**Recommendation**: Use Option B to maintain consistency with existing wrapper API.

### 2. Buffer Pool Sizing

#### Optimal Configuration

Based on typical exec session workloads and kernel recommendations:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **Buffer Count** | 16 | Balance between concurrency and memory usage |
| **Buffer Size** | 8KB | Matches typical TCP receive window segment size |
| **Total Pool Size** | 128KB per session | 16 buffers × 8KB each |
| **Buffer Group ID (BGID)** | 0 (stdin), 1 (stdout), 2 (stderr) | One pool per stream direction |

#### Per-FD Buffer Pools

```
Socket → Child stdin:   BGID 0 (16 buffers × 8KB = 128KB)
Child stdout → Socket:  BGID 1 (16 buffers × 8KB = 128KB)
Child stderr → Socket:  BGID 2 (16 buffers × 8KB = 128KB)
───────────────────────────────────────────────────────────
Total per ExecSession:  384KB (vs 64KB in current implementation)
```

**Trade-off**: Higher memory usage (+320KB per session) for 10-15% CPU savings.

### 3. CQE Flag Handling

When a completion arrives for a read operation using provided buffers:

```zig
// Check if kernel provided a buffer
if (cqe.flags & IORING_CQE_F_BUFFER != 0) {
    // Extract buffer ID from upper 16 bits of flags
    const buffer_id: u16 = @intCast((cqe.flags >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF);

    // Access buffer from pool
    const buffer = pool.getBuffer(buffer_id);
    const bytes_read = @as(usize, @intCast(cqe.res));
    const data = buffer[0..bytes_read];

    // Process data...

    // Return buffer to pool when done
    try pool.releaseBuffer(buffer_id);
}
```

**Critical**: Buffers must be returned to the pool via `PROVIDE_BUFFERS` after processing, or the pool will exhaust.

### 4. Stream Adapter Design Challenge

#### The Problem

**Current**: `IoRingBuffer` provides a contiguous stream view:
```zig
pub fn writableSlice(self: *IoRingBuffer) []u8  // Returns single contiguous slice
pub fn readableSlice(self: *const IoRingBuffer) []const u8
```

**With Provided Buffers**: Data arrives in discrete 8KB chunks:
```
Buffer 0: [████████] (8KB)
Buffer 3: [██████  ] (6KB used)
Buffer 7: [████████] (8KB)
          ↓
Logical Stream: [████████ ██████   ████████]
```

#### Proposed Solution: BufferChain

```zig
pub const BufferChain = struct {
    segments: std.ArrayList(Segment),
    total_bytes: usize,

    pub const Segment = struct {
        buffer_id: u16,
        offset: usize,   // Start offset within buffer
        len: usize,      // Valid bytes in this segment
    };

    /// Add a new buffer segment to the chain
    pub fn append(self: *BufferChain, buffer_id: u16, len: usize) !void {
        try self.segments.append(.{ .buffer_id = buffer_id, .offset = 0, .len = len });
        self.total_bytes += len;
    }

    /// Consume bytes from the front of the chain
    pub fn consume(self: *BufferChain, amount: usize, pool: *BufferPool) !void {
        var remaining = amount;
        while (remaining > 0 and self.segments.items.len > 0) {
            var segment = &self.segments.items[0];
            const consumable = @min(remaining, segment.len);

            segment.offset += consumable;
            segment.len -= consumable;
            remaining -= consumable;
            self.total_bytes -= consumable;

            // If segment fully consumed, return buffer to pool
            if (segment.len == 0) {
                try pool.returnBuffer(segment.buffer_id);
                _ = self.segments.orderedRemove(0);
            }
        }
    }

    /// Get first readable slice (may be < total_bytes due to fragmentation)
    pub fn firstReadableSlice(self: *const BufferChain, pool: *const BufferPool) []const u8 {
        if (self.segments.items.len == 0) return &[_]u8{};
        const segment = self.segments.items[0];
        const buffer = pool.getBuffer(segment.buffer_id);
        return buffer[segment.offset..segment.offset + segment.len];
    }
};
```

### 5. Performance Expectations

Based on kernel benchmarks and literature review:

| Metric | poll | io_uring (standard) | io_uring (provided) | Improvement |
|--------|------|---------------------|---------------------|-------------|
| **CPU Usage** | 40-50% | 5-10% | 3-7% | 30-40% reduction |
| **Syscalls per 1MB** | ~2,000 | 0 | 0 | Same as standard |
| **Buffer Setup Cost** | Per-op | Per-op | One-time | ~500ns saved per op |
| **Throughput (10MB)** | 200 MB/s | 1,200 MB/s | 1,800 MB/s | 50% gain |

**Note**: Actual gains depend on workload characteristics (message size, frequency, CPU model).

---

## Implementation Phases

### Phase 0: Pre-Implementation Research & Prototyping

**Goal**: Validate the approach with a minimal working prototype before integrating into zigcat.

- [ ] **0.1. Review Reference Implementations**
  - [ ] Study tokio-uring's provided buffer implementation ([GitHub link](https://github.com/tokio-rs/tokio-uring/blob/main/src/buf/pool.rs))
  - [ ] Review glommio's buffer management strategy
  - [ ] Read Lord of the io_uring tutorial on provided buffers ([unixism.net](https://unixism.net/loti/tutorial/provided_buffers.html))
  - [ ] Document common pitfalls from io_uring mailing list archives

- [ ] **0.2. Create Standalone Prototype**
  - [ ] Build `prototype/uring_provided_buffers.zig` (200-300 lines)
  - [ ] Implement minimal buffer pool (8 buffers × 4KB)
  - [ ] Test `PROVIDE_BUFFERS` registration
  - [ ] Test socket read with automatic buffer selection
  - [ ] Verify buffer ID extraction from `cqe.flags`
  - [ ] Test buffer return to pool
  - [ ] Measure CPU usage vs standard io_uring

- [ ] **0.3. Document Prototype Findings**
  - [ ] Record any unexpected kernel behaviors
  - [ ] Note API quirks in Zig's io_uring bindings
  - [ ] Identify missing helpers in `std.os.linux.IO_Uring`
  - [ ] Update this TODO with lessons learned

**Acceptance Criteria**:
- ✅ Prototype successfully reads from socket using provided buffers
- ✅ Buffer IDs are correctly extracted from completions
- ✅ Buffers are successfully returned to the pool
- ✅ CPU usage is measurably lower than standard io_uring (even by 1-2%)

---

### Phase 1: Foundational Work & Design

**Goal**: Establish core abstractions and platform detection.

#### 1.1. Platform Detection

- [ ] **1.1.1. Add Kernel Version Check**
  - [ ] In `src/util/platform.zig`, add:
    ```zig
    pub fn isIoUringProvidedBuffersSupported() bool {
        if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return false;
        const version = getLinuxKernelVersion() catch return false;
        return version.isAtLeast(5, 7);  // Provided buffers require 5.7+
    }
    ```
  - [ ] Write unit test for version detection with mock kernel strings:
    - Test: `"5.6.0-generic"` → `false`
    - Test: `"5.7.0-generic"` → `true`
    - Test: `"6.1.0-arch1-1"` → `true`

#### 1.2. Buffer Pool Design

- [ ] **1.2.1. Define Buffer Pool Configuration**
  - [ ] Create `src/server/exec_session/buffer_pool.zig`
  - [ ] Define constants:
    ```zig
    pub const DEFAULT_BUFFER_COUNT: u16 = 16;
    pub const DEFAULT_BUFFER_SIZE: usize = 8192;  // 8KB
    pub const MAX_BUFFER_GROUPS: u8 = 3;  // stdin, stdout, stderr
    ```

- [ ] **1.2.2. Implement FixedBufferPool Struct**
  - [ ] Define struct:
    ```zig
    pub const FixedBufferPool = struct {
        allocator: std.mem.Allocator,
        storage: []u8,              // Single large allocation
        buffer_size: usize,
        buffer_count: u16,
        bgid: u16,                  // Buffer group ID
        free_list: std.ArrayList(u16),  // Available buffer indices

        pub fn init(allocator: std.mem.Allocator, buffer_count: u16, buffer_size: usize, bgid: u16) !FixedBufferPool
        pub fn deinit(self: *FixedBufferPool) void
        pub fn acquireBuffer(self: *FixedBufferPool) ?u16
        pub fn releaseBuffer(self: *FixedBufferPool, buffer_id: u16) !void
        pub fn getBuffer(self: *const FixedBufferPool, buffer_id: u16) []u8
        pub fn getConstBuffer(self: *const FixedBufferPool, buffer_id: u16) []const u8
    };
    ```

- [ ] **1.2.3. Implement Buffer Pool Methods**
  - [ ] `init()`: Allocate single large buffer, populate free list
  - [ ] `deinit()`: Free storage and free list
  - [ ] `acquireBuffer()`: Pop from free list, return buffer ID or null if exhausted
  - [ ] `releaseBuffer()`: Push buffer ID back to free list, validate not already free
  - [ ] `getBuffer()`: Return mutable slice at `storage[buffer_id * buffer_size..(buffer_id + 1) * buffer_size]`
  - [ ] Add bounds checking and debug assertions

#### 1.3. Stream Adapter Architecture

- [ ] **1.3.1. Design BufferChain for Stream Abstraction**
  - [ ] Create `src/server/exec_session/buffer_chain.zig`
  - [ ] Define struct (see "Proposed Solution" above for full API)
  - [ ] Implement `append()`, `consume()`, `firstReadableSlice()`, `totalAvailable()`

- [ ] **1.3.2. Create Compatibility Shim for IoRingBuffer API**
  - [ ] Create `src/server/exec_session/provided_stream.zig`
  - [ ] Wrap `BufferChain` to expose `IoRingBuffer`-like interface:
    ```zig
    pub const ProvidedStream = struct {
        chain: BufferChain,
        pool: *FixedBufferPool,

        /// Add data from a provided buffer (called on read completion)
        pub fn commitProvidedBuffer(self: *ProvidedStream, buffer_id: u16, len: usize) !void;

        /// Consume bytes (returns buffers to pool when fully consumed)
        pub fn consume(self: *ProvidedStream, amount: usize) !void;

        /// Get first readable slice (for writing to socket/pipe)
        pub fn readableSlice(self: *const ProvidedStream) []const u8;

        /// Total bytes available across all chained buffers
        pub fn availableRead(self: *const ProvidedStream) usize;
    };
    ```

- [ ] **1.3.3. Handle Edge Cases**
  - [ ] Test: Empty chain (no buffers)
  - [ ] Test: Single buffer
  - [ ] Test: Fragmented chain (3+ buffers)
  - [ ] Test: Partial consumption (consume less than first segment)
  - [ ] Test: Full consumption (chain becomes empty)
  - [ ] Test: Buffer pool exhaustion (acquire returns null)

---

### Phase 2: Core Implementation (uring_provided_backend.zig)

**Goal**: Implement the new backend with provided buffer support.

#### 2.1. Create New Backend File

- [ ] **2.1.1. Initialize File Structure**
  - [ ] Create `src/server/exec_session/uring_provided_backend.zig`
  - [ ] Add copyright header and module documentation
  - [ ] Import required modules:
    ```zig
    const std = @import("std");
    const builtin = @import("builtin");
    const posix = std.posix;
    const FixedBufferPool = @import("./buffer_pool.zig").FixedBufferPool;
    const BufferChain = @import("./buffer_chain.zig").BufferChain;
    const ProvidedStream = @import("./provided_stream.zig").ProvidedStream;
    const UringEventLoop = @import("../../util/io_uring_wrapper.zig").UringEventLoop;
    const TelnetConnection = @import("../../protocol/telnet_connection.zig").TelnetConnection;
    const ExecSessionConfig = @import("../exec_types.zig").ExecSessionConfig;
    const FlowState = @import("./flow_control.zig").FlowState;
    const TimeoutTracker = @import("../../util/timeout_tracker.zig").TimeoutTracker;
    ```

#### 2.2. Define UringProvidedSession Struct

- [ ] **2.2.1. Define Core Fields**
  - [ ] Create struct skeleton:
    ```zig
    pub const UringProvidedSession = struct {
        // User data constants for operation tracking
        const USER_DATA_SOCKET_READ: u64 = 1;
        const USER_DATA_SOCKET_WRITE: u64 = 2;
        const USER_DATA_STDIN_WRITE: u64 = 3;
        const USER_DATA_STDOUT_READ: u64 = 4;
        const USER_DATA_STDERR_READ: u64 = 5;
        const USER_DATA_PROVIDE_STDIN_BUFS: u64 = 10;
        const USER_DATA_PROVIDE_STDOUT_BUFS: u64 = 11;
        const USER_DATA_PROVIDE_STDERR_BUFS: u64 = 12;

        // Buffer Group IDs
        const BGID_STDIN: u16 = 0;
        const BGID_STDOUT: u16 = 1;
        const BGID_STDERR: u16 = 2;

        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        socket_fd: posix.fd_t,
        child: *std.process.Child,
        stdin_fd: posix.fd_t,
        stdout_fd: posix.fd_t,
        stderr_fd: posix.fd_t,

        // Buffer pools (one per stream)
        stdin_pool: FixedBufferPool,
        stdout_pool: FixedBufferPool,
        stderr_pool: FixedBufferPool,

        // Stream abstractions
        stdin_stream: ProvidedStream,
        stdout_stream: ProvidedStream,
        stderr_stream: ProvidedStream,

        flow_state: FlowState,
        tracker: TimeoutTracker,
        config: ExecSessionConfig,
        ring: UringEventLoop,

        // State flags
        socket_read_closed: bool = false,
        socket_write_closed: bool = false,
        child_stdin_closed: bool = false,
        child_stdout_closed: bool = false,
        child_stderr_closed: bool = false,

        // Pending operations
        socket_read_pending: bool = false,
        socket_write_pending: bool = false,
        stdin_write_pending: bool = false,
        stdout_read_pending: bool = false,
        stderr_read_pending: bool = false,
    };
    ```

#### 2.3. Extend io_uring_wrapper.zig

- [ ] **2.3.1. Add PROVIDE_BUFFERS Support**
  - [ ] In `src/util/io_uring_wrapper.zig`, add method:
    ```zig
    /// Submit buffer registration for automatic buffer selection.
    ///
    /// Registers a pool of buffers with the kernel, allowing it to automatically
    /// select a buffer when a read operation completes. Requires kernel 5.7+.
    ///
    /// Parameters:
    ///   buffers: Contiguous memory region containing all buffers
    ///   buffer_len: Size of each individual buffer (e.g., 8192)
    ///   nr_buffers: Number of buffers in the pool
    ///   bgid: Buffer group ID (0-65535)
    ///   bid_start: Starting buffer ID for this batch (typically 0)
    ///
    /// Returns: Error if submission queue is full
    pub fn submitProvideBuffers(
        self: *UringEventLoop,
        buffers: []u8,
        buffer_len: u32,
        nr_buffers: u16,
        bgid: u16,
        bid_start: u16,
    ) !void {
        const sqe = try self.ring.get_sqe();

        // Manually prepare PROVIDE_BUFFERS operation
        sqe.opcode = std.os.linux.IORING_OP.PROVIDE_BUFFERS;
        sqe.fd = -1;
        sqe.addr = @intFromPtr(buffers.ptr);
        sqe.len = buffer_len;
        sqe.off = bid_start;
        sqe.buf_index = bgid;
        sqe.flags = 0;
    }
    ```

- [ ] **2.3.2. Add Constants for CQE Flags**
  - [ ] Add to `io_uring_wrapper.zig`:
    ```zig
    // CQE flag constants
    pub const IORING_CQE_F_BUFFER: u32 = 1 << 0;  // Buffer was provided by kernel
    pub const IORING_CQE_BUFFER_SHIFT: u5 = 16;   // Buffer ID starts at bit 16
    ```

#### 2.4. Implement init() for UringProvidedSession

- [ ] **2.4.1. Initialize Buffer Pools**
  - [ ] Allocate and register three buffer pools:
    ```zig
    pub fn init(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !UringProvidedSession {
        // Platform check
        if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
            return error.IoUringNotSupported;
        }

        // Initialize io_uring
        var ring = try UringEventLoop.init(allocator, 64);
        errdefer ring.deinit();

        // Initialize buffer pools
        const buffer_count: u16 = 16;
        const buffer_size: usize = 8192;

        var stdin_pool = try FixedBufferPool.init(allocator, buffer_count, buffer_size, BGID_STDIN);
        errdefer stdin_pool.deinit();

        var stdout_pool = try FixedBufferPool.init(allocator, buffer_count, buffer_size, BGID_STDOUT);
        errdefer stdout_pool.deinit();

        var stderr_pool = try FixedBufferPool.init(allocator, buffer_count, buffer_size, BGID_STDERR);
        errdefer stderr_pool.deinit();

        // Register buffer pools with kernel
        try ring.submitProvideBuffers(
            stdin_pool.storage,
            @intCast(buffer_size),
            buffer_count,
            BGID_STDIN,
            0,  // Start at buffer ID 0
        );
        _ = try ring.submit();  // Submit immediately
        _ = try ring.waitForCompletion(null);  // Wait for registration

        // Repeat for stdout and stderr pools...

        // Initialize stream abstractions
        var stdin_stream = ProvidedStream.init(allocator, &stdin_pool);
        errdefer stdin_stream.deinit();

        // ... initialize stdout_stream and stderr_stream

        // Set FDs to non-blocking
        const socket_fd = telnet_conn.getSocket();
        try setFdNonBlocking(socket_fd);
        // ... set stdin/stdout/stderr non-blocking

        return UringProvidedSession{
            .allocator = allocator,
            .telnet_conn = telnet_conn,
            .socket_fd = socket_fd,
            .child = child,
            .stdin_fd = ...,
            .stdout_fd = ...,
            .stderr_fd = ...,
            .stdin_pool = stdin_pool,
            .stdout_pool = stdout_pool,
            .stderr_pool = stderr_pool,
            .stdin_stream = stdin_stream,
            .stdout_stream = stdout_stream,
            .stderr_stream = stderr_stream,
            .flow_state = FlowState{ ... },
            .tracker = TimeoutTracker.init(cfg.timeouts),
            .config = cfg,
            .ring = ring,
        };
    }
    ```

#### 2.5. Implement run() Event Loop

- [ ] **2.5.1. Core Event Loop Structure**
  - [ ] Implement main loop:
    ```zig
    pub fn run(self: *UringProvidedSession) !void {
        // Submit initial reads
        try self.submitInitialReads();

        while (self.shouldContinue()) {
            try self.checkTimeouts();

            const timeout_spec = self.computeTimeout();
            const cqe = self.ring.waitForCompletion(timeout_spec) catch |err| {
                if (err == error.Timeout) {
                    try self.checkTimeouts();
                    continue;
                }
                return err;
            };

            // Dispatch completion
            try self.handleCompletion(cqe);

            // Resubmit operations
            try self.resubmitOperations();
        }

        // Final flush
        try self.flushBuffers();
    }
    ```

- [ ] **2.5.2. Implement Completion Handler**
  - [ ] Handle provided buffer completions:
    ```zig
    fn handleCompletion(self: *UringProvidedSession, cqe: CompletionResult) !void {
        switch (cqe.user_data) {
            USER_DATA_SOCKET_READ => {
                self.socket_read_pending = false;

                // Check if kernel provided a buffer
                if (cqe.flags & IORING_CQE_F_BUFFER != 0) {
                    const buffer_id: u16 = @intCast((cqe.flags >> IORING_CQE_BUFFER_SHIFT) & 0xFFFF);
                    const bytes_read = @as(usize, @intCast(cqe.res));

                    // Add buffer to stdin stream
                    try self.stdin_stream.commitProvidedBuffer(buffer_id, bytes_read);

                    self.tracker.markActivity();
                    try self.updateFlow();
                } else if (cqe.res == 0) {
                    self.socket_read_closed = true;
                } else if (cqe.res < 0) {
                    // Error occurred
                    self.socket_read_closed = true;
                }
            },

            USER_DATA_STDOUT_READ => {
                // Similar to socket read...
            },

            USER_DATA_SOCKET_WRITE => {
                self.socket_write_pending = false;
                if (cqe.res > 0) {
                    const bytes_written = @as(usize, @intCast(cqe.res));
                    try self.stdout_stream.consume(bytes_written);
                    self.tracker.markActivity();
                    try self.updateFlow();
                }
            },

            // ... handle other operations

            else => {},
        }
    }
    ```

- [ ] **2.5.3. Implement Buffer Replenishment**
  - [ ] After consuming buffers, replenish the pool:
    ```zig
    fn replenishBufferPool(self: *UringProvidedSession, bgid: u16, pool: *FixedBufferPool) !void {
        // Count how many buffers were consumed (returned to pool)
        const available = pool.free_list.items.len;

        // Only replenish if we have buffers to provide
        if (available > 0) {
            try self.ring.submitProvideBuffers(
                pool.storage,
                @intCast(pool.buffer_size),
                @intCast(available),
                bgid,
                0,
            );
        }
    }
    ```

---

### Phase 3: Integration and Fallback

**Goal**: Integrate the new backend into the ExecSession union and implement graceful fallback.

#### 3.1. Update ExecSession Union

- [ ] **3.1.1. Add New Variant**
  - [ ] In `src/server/exec_session/mod.zig`, update union:
    ```zig
    pub const ExecSession = union(enum) {
        poll: PollSession,
        uring: UringSession,
        uring_provided: UringProvidedSession,  // NEW
        iocp: IocpSession,

        // ...
    };
    ```

#### 3.2. Update ExecSession.init() Factory

- [ ] **3.2.1. Add Tiered Backend Selection**
  - [ ] Modify `init()` to prioritize provided buffers:
    ```zig
    pub fn init(
        allocator: std.mem.Allocator,
        telnet_conn: *TelnetConnection,
        child: *std.process.Child,
        cfg: ExecSessionConfig,
    ) !ExecSession {
        // Windows: IOCP first
        if (builtin.os.tag == .windows) {
            if (IocpSession.init(allocator, telnet_conn, child, cfg)) |iocp_session| {
                return ExecSession{ .iocp = iocp_session };
            } else |_| {
                // Fall through
            }
        }

        // Linux: Try provided buffers first (5.7+)
        if (builtin.os.tag == .linux and platform.isIoUringProvidedBuffersSupported()) {
            if (UringProvidedSession.init(allocator, telnet_conn, child, cfg)) |provided_session| {
                if (cfg.verbose) {
                    std.debug.print("[DEBUG] Using io_uring with provided buffers (kernel 5.7+)\n", .{});
                }
                return ExecSession{ .uring_provided = provided_session };
            } else |err| {
                if (cfg.verbose) {
                    std.debug.print("[WARN] Provided buffers failed ({s}), falling back to standard io_uring\n", .{@errorName(err)});
                }
                // Fall through to standard io_uring
            }
        }

        // Linux: Try standard io_uring (5.1+)
        if (builtin.os.tag == .linux and platform.isIoUringSupported()) {
            if (UringSession.init(allocator, telnet_conn, child, cfg)) |uring_session| {
                return ExecSession{ .uring = uring_session };
            } else |_| {
                // Fall through to poll
            }
        }

        // Universal fallback: poll
        const poll_session = try PollSession.init(allocator, telnet_conn, child, cfg);
        return ExecSession{ .poll = poll_session };
    }
    ```

#### 3.3. Update deinit() and run() Dispatch

- [ ] **3.3.1. Add uring_provided Cases**
  - [ ] Update `deinit()`:
    ```zig
    pub fn deinit(self: *ExecSession) void {
        switch (self.*) {
            .poll => |*poll_session| poll_session.deinit(),
            .uring => |*uring_session| uring_session.deinit(),
            .uring_provided => |*provided_session| provided_session.deinit(),  // NEW
            .iocp => |*iocp_session| iocp_session.deinit(),
        }
    }
    ```

  - [ ] Update `run()`:
    ```zig
    pub fn run(self: *ExecSession) !void {
        switch (self.*) {
            .poll => |*poll_session| try poll_session.run(),
            .uring => |*uring_session| try uring_session.run(),
            .uring_provided => |*provided_session| try provided_session.run(),  // NEW
            .iocp => |*iocp_session| try iocp_session.run(),
        }
    }
    ```

#### 3.4. Update Documentation

- [ ] **3.4.1. Update Module Documentation**
  - [ ] In `src/server/exec_session/mod.zig`, update backend priority:
    ```zig
    /// Backend selection priority:
    /// 1. Windows: IOCP (10-20% CPU usage)
    /// 2. Linux 5.7+: io_uring with provided buffers (3-7% CPU usage)  // NEW
    /// 3. Linux 5.1+: io_uring with standard buffers (5-10% CPU usage)
    /// 4. Other Unix: poll (30-50% CPU usage)
    ```

---

### Phase 4: Testing

**Goal**: Ensure correctness, robustness, and performance of the new backend.

#### 4.1. Unit Tests

- [ ] **4.1.1. Test FixedBufferPool**
  - [ ] Create `src/server/exec_session/buffer_pool_test.zig`
  - [ ] Test: Acquire all buffers, verify exhaustion
  - [ ] Test: Acquire → Release → Acquire (verify reuse)
  - [ ] Test: Double release detection (should error)
  - [ ] Test: Invalid buffer ID (should panic in debug mode)
  - [ ] Test: getBuffer() returns correct slice

- [ ] **4.1.2. Test BufferChain**
  - [ ] Create `src/server/exec_session/buffer_chain_test.zig`
  - [ ] Test: Empty chain (availableRead = 0)
  - [ ] Test: Append single buffer
  - [ ] Test: Append multiple buffers (fragmented)
  - [ ] Test: Partial consume (consume < first segment)
  - [ ] Test: Full segment consume (segment removed)
  - [ ] Test: Multi-segment consume (remove 2+ segments)
  - [ ] Test: Verify buffers returned to pool after consumption

- [ ] **4.1.3. Test Platform Detection**
  - [ ] Test `isIoUringProvidedBuffersSupported()`:
    - Mock kernel 5.6.0 → false
    - Mock kernel 5.7.0 → true
    - Mock kernel 6.1.0 → true
    - Non-Linux OS → false

#### 4.2. Integration Tests

- [ ] **4.2.1. Test ExecSession Backend Selection**
  - [ ] Create `src/server/exec_session/integration_test.zig`
  - [ ] Test: On kernel 5.7+, verify `uring_provided` is selected
  - [ ] Test: On kernel 5.1-5.6, verify `uring` is selected
  - [ ] Test: On kernel <5.1, verify `poll` is selected

- [ ] **4.2.2. Test Provided Buffer I/O**
  - [ ] Test: Spawn `cat`, send data via socket, verify echo
  - [ ] Test: Spawn `yes | head -n 1000`, verify stdout captured
  - [ ] Test: Spawn command that writes to stderr, verify stderr captured
  - [ ] Test: Large data transfer (10MB), verify no data loss
  - [ ] Test: Rapid short messages (1000 × 10 bytes), verify all received

- [ ] **4.2.3. Test Buffer Pool Exhaustion**
  - [ ] Test: Flood input faster than output drains
  - [ ] Verify: Flow control pauses reads when pool exhausted
  - [ ] Verify: Reads resume after buffers are returned to pool
  - [ ] Verify: No crash or data corruption on exhaustion

- [ ] **4.2.4. Test Fallback Behavior**
  - [ ] Mock: `UringProvidedSession.init()` fails
  - [ ] Verify: Falls back to standard `UringSession`
  - [ ] Verify: Warning logged if verbose mode enabled

#### 4.3. Performance Benchmarks

- [ ] **4.3.1. Create Benchmark Harness**
  - [ ] Create `tests/bench_exec_backends.zig`
  - [ ] Implement test scenarios:
    - Small messages: 1000 × 100 bytes
    - Large streams: 1 × 10MB
    - Mixed workload: Random sizes 10B-10KB

- [ ] **4.3.2. Measure Metrics**
  - [ ] Throughput (MB/s)
  - [ ] CPU usage (%)
  - [ ] Memory usage (RSS)
  - [ ] Latency (p50, p95, p99)

- [ ] **4.3.3. Compare Backends**
  - [ ] Run benchmarks on:
    - `PollSession`
    - `UringSession` (standard buffers)
    - `UringProvidedSession` (provided buffers)
  - [ ] Document results in `PERFORMANCE.md`

- [ ] **4.3.4. Verify Performance Targets**
  - [ ] ✅ Provided buffers 10-15% lower CPU vs standard io_uring
  - [ ] ✅ Provided buffers 50%+ higher throughput vs standard io_uring
  - [ ] ✅ Memory usage within acceptable range (+320KB per session)

#### 4.4. Docker Cross-Platform Tests

- [ ] **4.4.1. Test on Multiple Kernel Versions**
  - [ ] Create `docker-tests/Dockerfile.kernel-5.6`
  - [ ] Create `docker-tests/Dockerfile.kernel-5.7`
  - [ ] Create `docker-tests/Dockerfile.kernel-6.1`
  - [ ] Run exec tests on each kernel version
  - [ ] Verify correct backend is selected for each version

---

### Phase 5: Documentation and Cleanup

**Goal**: Document the feature, update guides, and polish the implementation.

#### 5.1. Code Documentation

- [ ] **5.1.1. Add Module-Level Documentation**
  - [ ] `uring_provided_backend.zig`: Explain provided buffers, benefits, kernel requirements
  - [ ] `buffer_pool.zig`: Document buffer lifecycle, thread safety (none)
  - [ ] `buffer_chain.zig`: Document fragmentation handling, memory management

- [ ] **5.1.2. Add Inline Comments**
  - [ ] Document critical sections:
    - Buffer ID extraction from CQE flags
    - Buffer replenishment logic
    - Stream adapter consume logic
  - [ ] Add warnings for common pitfalls:
    - Buffer must remain valid until completion
    - Must return buffers to pool after use
    - Pool exhaustion requires flow control

#### 5.2. Update User Documentation

- [ ] **5.2.1. Update CLAUDE.md**
  - [ ] Add section: "ExecSession Backend Selection (4-tier)"
  - [ ] Document provided buffer benefits
  - [ ] List kernel requirements
  - [ ] Explain fallback strategy

- [ ] **5.2.2. Update TESTS.md**
  - [ ] Add section: "Provided Buffer Tests"
  - [ ] Document new test targets:
    - `zig build test-buffer-pool`
    - `zig build test-buffer-chain`
    - `zig build test-exec-provided`

- [ ] **5.2.3. Create PERFORMANCE.md**
  - [ ] Document benchmark methodology
  - [ ] Include performance comparison tables
  - [ ] Add CPU/memory/throughput graphs
  - [ ] List hardware tested (CPU model, kernel version)
  - [ ] Provide tuning recommendations (buffer count/size)

#### 5.3. Observability & Debugging

- [ ] **5.3.1. Add Telemetry Logging**
  - [ ] Log backend selection at startup:
    ```zig
    if (cfg.verbose) {
        std.debug.print("[INFO] Backend: io_uring provided buffers (pool: {d}x{d}KB)\n",
                        .{buffer_count, buffer_size / 1024});
    }
    ```

- [ ] **5.3.2. Add Debug Statistics**
  - [ ] Track per-session:
    - Total buffers acquired
    - Total buffers released
    - Peak buffer pool usage
    - Buffer pool exhaustion events
  - [ ] Print stats on session end if verbose

- [ ] **5.3.3. Add Error Context**
  - [ ] Improve error messages:
    - "Buffer pool exhausted (all 16 buffers in use)"
    - "Kernel does not support provided buffers (requires 5.7+, found 5.6.0)"
    - "Failed to register buffer pool: ENOMEM (try reducing buffer count)"

#### 5.4. Code Review & Cleanup

- [ ] **5.4.1. Run Static Analysis**
  - [ ] `zig fmt` on all new files
  - [ ] `zlint` on all new files (if available)
  - [ ] Fix any compiler warnings

- [ ] **5.4.2. Review for Memory Leaks**
  - [ ] Verify all `errdefer` cleanup paths
  - [ ] Verify buffer pool deinit
  - [ ] Verify BufferChain cleanup
  - [ ] Run with leak sanitizer (if available)

- [ ] **5.4.3. Review for Thread Safety**
  - [ ] Document: ExecSession is single-threaded (no locks needed)
  - [ ] Verify: No shared state between sessions
  - [ ] Verify: Buffer pools are session-local

- [ ] **5.4.4. Code Review Checklist**
  - [ ] All functions have doc comments
  - [ ] All error paths tested
  - [ ] No magic numbers (use named constants)
  - [ ] No unsafe casts (use explicit conversions)
  - [ ] Consistent naming conventions

---

## Acceptance Criteria (Final Checklist)

Before marking this TODO as complete, verify all of the following:

### Functionality
- [ ] ✅ Provided buffer backend works correctly on kernel 5.7+
- [ ] ✅ Fallback to standard io_uring on kernel 5.1-5.6
- [ ] ✅ Fallback to poll on kernel <5.1
- [ ] ✅ All three backends produce identical output for same input
- [ ] ✅ No data loss or corruption under high load

### Performance
- [ ] ✅ Provided buffers use 10-15% less CPU than standard io_uring
- [ ] ✅ Provided buffers achieve 50%+ higher throughput than standard io_uring
- [ ] ✅ Memory usage is within budget (+320KB per session acceptable)
- [ ] ✅ No performance regression for poll or standard io_uring backends

### Testing
- [ ] ✅ All unit tests pass (`zig build test`)
- [ ] ✅ All integration tests pass
- [ ] ✅ Docker cross-platform tests pass on kernel 5.6, 5.7, 6.1
- [ ] ✅ Performance benchmarks meet targets

### Documentation
- [ ] ✅ Module documentation complete
- [ ] ✅ User documentation updated (CLAUDE.md, TESTS.md)
- [ ] ✅ PERFORMANCE.md created with benchmark results
- [ ] ✅ All functions have doc comments

### Code Quality
- [ ] ✅ No compiler warnings
- [ ] ✅ All files formatted (`zig fmt`)
- [ ] ✅ No memory leaks detected
- [ ] ✅ Error paths have proper cleanup
- [ ] ✅ Code review completed

---

## Known Issues & Future Work

### Known Limitations

1. **Memory Overhead**: +320KB per exec session (trade-off for CPU savings)
2. **Kernel Dependency**: Requires Linux 5.7+ for optimal performance
3. **Buffer Fragmentation**: Stream adapter may introduce latency for very small messages
4. **Pool Exhaustion**: Flow control required to prevent deadlock

### Future Optimizations

- [ ] **Adaptive Buffer Pool Sizing**: Dynamically adjust pool size based on workload
- [ ] **Zero-Copy Writes**: Use `IORING_OP_SPLICE` for socket → pipe transfers
- [ ] **Multi-Shot Operations**: Use `IORING_RECVSEND_POLL_FIRST` (kernel 6.0+)
- [ ] **Buffer Coalescing**: Merge adjacent buffers before writing to socket
- [ ] **Per-Connection Tuning**: Allow custom buffer count/size via config

### Related Issues

- [ ] Investigate `IORING_REGISTER_PBUF_RING` (kernel 5.19+) as alternative to `PROVIDE_BUFFERS`
- [ ] Explore `IORING_OP_READ_MULTISHOT` for reduced submission overhead

---

## References

### Documentation
- [Lord of the io_uring - Provided Buffers Tutorial](https://unixism.net/loti/tutorial/provided_buffers.html)
- [io_uring(7) Manual Page](https://man7.org/linux/man-pages/man7/io_uring.7.html)
- [io_uring_prep_provide_buffers(3)](https://man7.org/linux/man-pages/man3/io_uring_prep_provide_buffers.3.html)
- [Efficient IO with io_uring (PDF)](https://kernel.dk/io_uring.pdf)

### Reference Implementations
- [tokio-uring buffer pool](https://github.com/tokio-rs/tokio-uring/blob/main/src/buf/pool.rs)
- [glommio buffer management](https://github.com/DataDog/glommio)

### Performance Analysis
- [IO_uring Fixed Buffer vs Non-Fixed Performance](https://00pauln00.medium.com/io-uring-fixed-buffer-versus-non-fixed-buffer-performance-comparison-9fd506de6829)
- [Building a buffer pool with io_uring in Zig](https://gavinray97.github.io/blog/io-uring-fixed-bufferpool-zig)

---

**Last Updated**: 2025-01-13
**Status**: Ready for Phase 0 (Prototyping)
**Estimated Total Effort**: 20-30 hours across 6 phases
