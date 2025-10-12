# Windows IOCP Backend Implementation TODO

**Goal**: Replace Windows threaded exec mode with native IOCP async backend for performance parity with Linux io_uring.

**Status**: 🚧 Phase 1 In Progress
**Estimated Total Effort**: 28-36 hours (includes buffer, testing margin)
**Start Date**: 2025-01-11

---

## Overview

### Current Architecture
- **POSIX (Linux/macOS)**: Single-threaded async I/O via `exec_session/mod.zig`
  - Linux 5.1+: io_uring backend (5-10% CPU, ~500ns latency)
  - Other Unix: poll backend (30-50% CPU, ~2μs latency)
- **Windows**: Multi-threaded blocking I/O via `exec_threaded.zig`
  - 3 threads per connection (stdin, stdout, stderr)
  - 50-80% CPU usage, poor scalability

### Target Architecture
- **Windows**: Single-threaded async I/O via IOCP backend
  - Expected: <20% CPU usage, ~2-5μs latency
  - Scalable to 100+ concurrent connections
  - Unified `ExecSession` API (no Windows-specific code in exec.zig)

### Success Criteria
- [ ] IOCP backend achieves <20% CPU usage (vs 50-80% threaded)
- [ ] Handles 100+ concurrent exec sessions without thread exhaustion
- [ ] Passes all existing exec mode tests on Windows
- [ ] Latency comparable to Linux poll backend (~2-5μs)
- [ ] Zero API breakage (`ExecSession` interface unchanged)
- [ ] Complete documentation (CLAUDE.md, TESTS.md updates)

---

## Phase 1: IOCP Foundation Enhancement (4-6 hours) 🚧

**Objective**: Enhance `src/util/iocp_windows.zig` to support async file/socket operations with user_data tagging.

**Current State**: Basic wrapper (78 lines) with socket association only
**Target State**: Full-featured IOCP wrapper (~200-250 lines) with ReadFile/WriteFile support

### Checklist

#### 1.1 Study Existing IOCP Wrapper
- [x] Review `src/util/iocp_windows.zig` (current 78 lines)
- [x] Understand `Iocp.init()`, `Iocp.associateSocket()`, `Iocp.getStatus()`
- [x] Document current limitations (no file I/O, no user_data, no batch retrieval)

#### 1.2 Add OVERLAPPED Management
- [x] Create `IocpOperation` struct to wrap `OVERLAPPED` + user_data
  ```zig
  pub const IocpOperation = struct {
      overlapped: windows.OVERLAPPED,
      user_data: u64,
      op_type: OperationType,  // For debugging
  };
  ```
- [x] Add operation type enum (READ, WRITE, ACCEPT, CONNECT)
- [x] Add doc comments explaining buffer lifetime requirements

#### 1.3 Add Async File Operations
- [x] Implement `submitReadFile(handle, buffer, operation)` using `ReadFile()` + `OVERLAPPED`
  - Uses `ReadFile()` with OVERLAPPED structure
  - Handles `ERROR_IO_PENDING` (not an error, operation queued)
  - Returns error only for actual failures
- [x] Implement `submitWriteFile(handle, buffer, operation)` using `WriteFile()` + `OVERLAPPED`
  - Uses `WriteFile()` with OVERLAPPED structure
  - Handles `ERROR_IO_PENDING` correctly
  - Documents partial write completions (rare but possible)
- [x] Add comprehensive doc comments (buffer lifetime, error codes, usage examples)

#### 1.4 Add Batch Completion Retrieval
- [ ] Implement `getStatusBatch(entries, timeout_ms)` using `GetQueuedCompletionStatusEx()`
  - Returns array of `CompletionPacket` with user_data
  - Supports timeout (INFINITE = -1, 0 = no wait, >0 = milliseconds)
  - Handles `WAIT_TIMEOUT` gracefully
- [x] Update `getStatus()` to extract user_data from IocpOperation
- [x] Add error_code field to CompletionPacket
- [ ] Add doc comments explaining batch vs single retrieval
  **Note**: Batch retrieval deferred to Phase 2 if needed (single retrieval sufficient for MVP)

#### 1.5 Add Helper Methods
- [x] Implement `associateFileHandle(handle, completion_key)` for pipes/files
- [x] Implement `cancelIo(handle)` using `CancelIo()`
- [x] Timeout conversion handled in getStatus (DWORD milliseconds)

#### 1.6 Documentation
- [x] Add module-level doc comments (what IOCP is, when to use it)
- [x] Add usage examples for each method
- [x] Document Windows-specific constraints (OVERLAPPED must be unique, buffer lifetime)
- [x] Add CRITICAL constraints section at module level

#### 1.7 Testing
- [ ] Create `tests/iocp_wrapper_test.zig`
  - Test basic init/deinit
  - Test pipe read/write operations (use `CreatePipe()`)
  - Test timeout handling (0ms, 100ms, INFINITE)
  - Test batch retrieval (submit 3 ops, retrieve as batch)
- [ ] Run tests: `zig build test` (Windows only)
- [ ] Verify no memory leaks (check OVERLAPPED cleanup)

**Exit Criteria**:
- [ ] `iocp_windows.zig` compiles on Windows
- [ ] All Phase 1 tests pass
- [ ] No memory leaks detected
- [ ] File size: 78 → 200-250 lines
- [ ] Ready for integration into exec_session

**Commit**: `feat(iocp): enhance IOCP wrapper with file I/O and batch completion`

---

## Phase 2: IocpSession Backend Implementation (10-12 hours)

**Objective**: Create `src/server/exec_session/iocp_backend.zig` with full async event loop.

**Target State**: Complete IOCP backend (~600-700 lines) mirroring `uring_backend.zig` structure

### Checklist

#### 2.1 Create Module Structure
- [ ] Create `src/server/exec_session/iocp_backend.zig`
- [ ] Add copyright header (MIT license)
- [ ] Add module-level doc comments (IOCP backend overview, Windows requirements)

#### 2.2 Define IocpSession Struct
- [ ] Create `IocpSession` struct with fields:
  ```zig
  pub const IocpSession = struct {
      const USER_DATA_SOCKET_READ: u64 = 1;
      const USER_DATA_SOCKET_WRITE: u64 = 2;
      const USER_DATA_STDIN_WRITE: u64 = 3;
      const USER_DATA_STDOUT_READ: u64 = 4;
      const USER_DATA_STDERR_READ: u64 = 5;

      allocator: std.mem.Allocator,
      telnet_conn: *TelnetConnection,
      socket_handle: windows.HANDLE,
      child: *std.process.Child,
      stdin_handle: windows.HANDLE,
      stdout_handle: windows.HANDLE,
      stderr_handle: windows.HANDLE,
      iocp: Iocp,
      stdin_buffer: IoRingBuffer,
      stdout_buffer: IoRingBuffer,
      stderr_buffer: IoRingBuffer,
      flow_state: FlowState,
      max_total_buffer_bytes: usize,
      tracker: TimeoutTracker,
      config: ExecSessionConfig,
      // State flags
      socket_read_closed: bool = false,
      socket_write_closed: bool = false,
      child_stdin_closed: bool = false,
      child_stdout_closed: bool = false,
      child_stderr_closed: bool = false,
      flow_enabled: bool = true,
      // Pending operation tracking
      socket_read_pending: bool = false,
      socket_write_pending: bool = false,
      stdin_write_pending: bool = false,
      stdout_read_pending: bool = false,
      stderr_read_pending: bool = false,
      // OVERLAPPED structures (must be unique per operation!)
      socket_read_op: IocpOperation = undefined,
      socket_write_op: IocpOperation = undefined,
      stdin_write_op: IocpOperation = undefined,
      stdout_read_op: IocpOperation = undefined,
      stderr_read_op: IocpOperation = undefined,
  };
  ```

#### 2.3 Implement init() Method
- [ ] Create `init(allocator, telnet_conn, child, cfg)` method
  - Check `builtin.os.tag == .windows` (return error.Unsupported otherwise)
  - Extract file handles from `child.stdin`, `child.stdout`, `child.stderr`
  - Get socket handle from `telnet_conn.getSocket()`
  - Initialize IOCP with `Iocp.init()`
  - Associate all handles with IOCP completion port
  - Initialize buffers (`IoRingBuffer.init()` for stdin/stdout/stderr)
  - Compute flow control thresholds (reuse existing logic from uring_backend.zig:103-135)
  - Initialize `TimeoutTracker`
  - Initialize all OVERLAPPED structures
- [ ] Add proper error handling (`errdefer` for buffer cleanup)
- [ ] Return `IocpSession` or error

#### 2.4 Implement deinit() Method
- [ ] Clean up IOCP (`self.iocp.deinit()`)
- [ ] Clean up buffers (`stdin_buffer.deinit()`, etc.)
- [ ] Add doc comments (must be called to prevent leaks)

#### 2.5 Implement run() Event Loop
- [ ] Create `run()` method with main event loop:
  ```zig
  pub fn run(self: *IocpSession) !void {
      // Submit initial read operations for all open handles
      try self.submitIocpReads();

      while (self.shouldContinue()) {
          try self.checkTimeouts();

          const timeout_ms = self.computeIocpTimeout();
          const cqe = self.iocp.getStatus(timeout_ms) catch |err| {
              if (err == error.Timeout) {
                  try self.checkTimeouts();
                  continue;
              }
              return ExecError.IocpFailed;
          };

          try self.handleIocpCompletion(cqe);
          try self.checkTimeouts();
      }

      // Final flush
      self.flushIocpBuffers() catch {};
      self.maybeShutdownSocketWrite();
  }
  ```
- [ ] Add doc comments explaining event loop lifecycle

#### 2.6 Implement Submission Logic
- [ ] Implement `submitIocpReads()` (submit socket/stdout/stderr reads if needed)
  - Check flow control (`self.flow_state.shouldPause()`)
  - Check buffer space (`buffer.availableWrite() > 0`)
  - Check pending flag (don't resubmit if already pending)
  - Submit via `self.iocp.submitReadFile()`
- [ ] Implement `submitIocpWrites()` (submit socket/stdin writes if data buffered)
  - Check buffer data availability (`buffer.availableRead() > 0`)
  - Check pending flag
  - Submit via `self.iocp.submitWriteFile()`
- [ ] Add error handling for submission failures

#### 2.7 Implement Completion Handlers
- [ ] Implement `handleIocpCompletion(cqe)` dispatcher:
  ```zig
  fn handleIocpCompletion(self: *IocpSession, cqe: CompletionPacket) !void {
      switch (cqe.user_data) {
          USER_DATA_SOCKET_READ => try self.handleSocketRead(cqe),
          USER_DATA_SOCKET_WRITE => try self.handleSocketWrite(cqe),
          USER_DATA_STDIN_WRITE => try self.handleStdinWrite(cqe),
          USER_DATA_STDOUT_READ => try self.handleStdoutRead(cqe),
          USER_DATA_STDERR_READ => try self.handleStderrRead(cqe),
          else => {},
      }
  }
  ```
- [ ] Implement `handleSocketRead()` (socket → stdin_buffer)
  - Clear pending flag
  - Handle errors (close socket read)
  - Handle EOF (bytes_transferred == 0)
  - Commit bytes to buffer (`stdin_buffer.commitWrite()`)
  - Update flow control
  - Resubmit read if still open
- [ ] Implement `handleSocketWrite()` (stdout_buffer → socket)
  - Clear pending flag
  - Handle errors (close socket write)
  - Consume bytes from buffer (`stdout_buffer.consume()`)
  - Update flow control
  - Resubmit write if more data available
- [ ] Implement `handleStdinWrite()` (stdin_buffer → child stdin)
  - Clear pending flag
  - Handle errors (close child stdin)
  - Consume bytes from buffer
  - Close stdin if socket read closed and buffer empty
  - Resubmit write if more data available
- [ ] Implement `handleStdoutRead()` (child stdout → stdout_buffer)
  - Clear pending flag
  - Handle errors (close stdout)
  - Handle EOF (close stdout)
  - Commit bytes to buffer
  - Update flow control
  - Resubmit read and trigger socket write
- [ ] Implement `handleStderrRead()` (child stderr → stderr_buffer)
  - Same logic as stdout

#### 2.8 Implement Helper Methods
- [ ] Implement `totalBuffered()` (sum of all buffer data)
- [ ] Implement `updateFlow()` (check total bytes, update FlowState)
- [ ] Implement `computeIocpTimeout()` (convert TimeoutTracker to DWORD ms)
- [ ] Implement `checkTimeouts()` (check execution/idle/connection timeouts)
- [ ] Implement `shouldContinue()` (check if any I/O still needed)
- [ ] Implement `flushIocpBuffers()` (final flush of pending data)
- [ ] Implement `maybeShutdownSocketWrite()` (shutdown socket if done)
- [ ] Implement `closeChildStdin/Stdout/Stderr()` helpers

#### 2.9 Integrate Existing Helpers
- [ ] Import `socket_io.zig` (SocketReadContext, SocketWriteContext)
  - **Note**: May need Windows-specific versions (socket handles vs file descriptors)
- [ ] Import `child_io.zig` (ChildReadContext, ChildWriteContext)
  - **Note**: May need Windows HANDLE versions
- [ ] Import `flow_control.zig` (FlowState, computeThresholdBytes)
- [ ] Import `state.zig` (SessionState if applicable)
- [ ] Use `TimeoutTracker` from existing modules

#### 2.10 Documentation
- [ ] Add doc comments to all public methods
- [ ] Add doc comments to key private methods
- [ ] Add usage examples (mirror uring_backend.zig style)
- [ ] Document Windows-specific considerations (HANDLE types, OVERLAPPED lifetime)

#### 2.11 Testing
- [ ] Create `tests/iocp_backend_test.zig`
  - Test init/deinit (basic lifecycle)
  - Test shouldContinue() logic (various states)
  - Test timeout computation (convert TimeoutTracker to ms)
  - **Note**: Full I/O testing happens in Phase 4 (integration tests)
- [ ] Run: `zig build test` (Windows only)
- [ ] Verify no memory leaks

**Exit Criteria**:
- [ ] `iocp_backend.zig` compiles on Windows
- [ ] All Phase 2 unit tests pass
- [ ] File size: ~600-700 lines (comparable to uring_backend.zig)
- [ ] No memory leaks detected
- [ ] Ready for integration into ExecSession union

**Commit**: `feat(iocp): implement IocpSession backend for Windows exec mode`

---

## Phase 3: Integration into ExecSession (4-6 hours)

**Objective**: Wire IOCP backend into `exec_session/mod.zig` and update `exec.zig` to use it on Windows.

**Target State**: Windows automatically uses IOCP backend, threaded backend becomes fallback

### Checklist

#### 3.1 Update exec_session/mod.zig
- [ ] Import `IocpSession` from `iocp_backend.zig`
- [ ] Add `iocp: IocpSession` to `ExecSession` union:
  ```zig
  pub const ExecSession = union(enum) {
      poll: PollSession,
      uring: UringSession,
      iocp: IocpSession,  // NEW
  };
  ```
- [ ] Update `init()` to auto-select IOCP on Windows:
  ```zig
  pub fn init(allocator, telnet_conn, child, cfg) !ExecSession {
      // Windows: Try IOCP first
      if (builtin.os.tag == .windows) {
          if (IocpSession.init(allocator, telnet_conn, child, cfg)) |iocp_session| {
              return ExecSession{ .iocp = iocp_session };
          } else |_| {
              // Fall through to poll (shouldn't happen on Windows)
          }
      }

      // Linux: Try io_uring first
      if (builtin.os.tag == .linux and platform.isIoUringSupported()) {
          // ... existing logic
      }

      // Fallback: poll
      const poll_session = try PollSession.init(allocator, telnet_conn, child, cfg);
      return ExecSession{ .poll = poll_session };
  }
  ```
- [ ] Update `deinit()` to handle IOCP:
  ```zig
  pub fn deinit(self: *ExecSession) void {
      switch (self.*) {
          .poll => |*poll_session| poll_session.deinit(),
          .uring => |*uring_session| uring_session.deinit(),
          .iocp => |*iocp_session| iocp_session.deinit(),  // NEW
      }
  }
  ```
- [ ] Update `run()` to handle IOCP:
  ```zig
  pub fn run(self: *ExecSession) !void {
      switch (self.*) {
          .poll => |*poll_session| try poll_session.run(),
          .uring => |*uring_session| try uring_session.run(),
          .iocp => |*iocp_session| try iocp_session.run(),  // NEW
      }
  }
  ```
- [ ] Add doc comments explaining Windows backend selection

#### 3.2 Update exec.zig
- [ ] Review `executeWithConnection()` (lines 76-157)
  - **No changes needed** (already uses `ExecSession.init()`)
  - Verify Windows path still works (lines 123-128)
- [ ] Review `executeWithTelnetConnection()` (lines 216-283)
  - **No changes needed** (already uses `ExecSession.init()`)
  - Verify Windows path works (lines 223-224)
- [ ] Add doc comments noting Windows now uses IOCP (update lines 46-52)

#### 3.3 Add Fallback Mechanism
- [ ] Keep `exec_threaded.zig` for now (safety net)
- [ ] Add environment variable check: `ZIGCAT_USE_THREADS=1` to force threaded mode
  - Useful for debugging if IOCP has issues
- [ ] Add logging: "Using IOCP backend for Windows exec mode"

#### 3.4 Testing
- [ ] Build on Windows: `zig build`
- [ ] Verify IOCP backend is selected (check log output)
- [ ] Run existing exec mode tests: `zig build test-exec-threads` (if available)
- [ ] Manual test: `zigcat -l -p 8080 -e cmd.exe` → `telnet localhost 8080`
  - Type commands, verify output appears
  - Check CPU usage (should be <20%)
  - Check for memory leaks (run for 5 minutes)

**Exit Criteria**:
- [ ] Windows builds successfully select IOCP backend
- [ ] No API changes (existing tests still pass)
- [ ] Threaded backend remains as fallback
- [ ] Logging confirms backend selection
- [ ] Ready for comprehensive testing

**Commit**: `feat(iocp): integrate IOCP backend into ExecSession union`

---

## Phase 4: Comprehensive Testing & Validation (10-12 hours)

**Objective**: Ensure IOCP backend is production-ready through extensive testing and performance validation.

**Target State**: IOCP backend passes all tests, performs comparably to Linux poll backend

### Checklist

#### 4.1 Unit Tests
- [ ] Test `IocpSession.init()` error cases
  - Invalid handles (expect error)
  - Null child streams (stdin_closed = true)
  - Buffer allocation failures
- [ ] Test `IocpSession.shouldContinue()` logic
  - All streams closed → false
  - Buffered data remaining → true
  - Socket open + child alive → true
- [ ] Test flow control integration
  - Buffer fills to 75% → pause reads
  - Buffer drains to 25% → resume reads
- [ ] Test timeout computation
  - Infinite timeout → INFINITE (0xFFFFFFFF)
  - 0ms timeout → 0
  - 5000ms timeout → 5000
- [ ] Run: `zig build test` (verify all unit tests)

#### 4.2 Integration Tests
- [ ] Create `tests/iocp_exec_test.zig` (full exec session test)
  - Test: Echo server (`cmd /c echo hello`)
    - Expected: "hello\r\n" on socket
  - Test: Interactive shell (`cmd.exe`)
    - Send "echo test\r\n"
    - Expected: "test\r\n" response
  - Test: Long output (`cmd /c dir /s C:\Windows\System32`)
    - Verify all data transferred
    - Check buffer doesn't overflow
  - Test: Stdin/stdout/stderr multiplexing
    - Use `cmd /c` with redirection
    - Verify stderr appears on socket
- [ ] Run: `zig build test` (Windows only)

#### 4.3 Performance Testing
- [ ] Benchmark: Single connection latency
  - Setup: `zigcat -l -p 8080 -e cmd.exe`
  - Test: Send "echo test\r\n", measure round-trip time
  - Target: <5ms latency
- [ ] Benchmark: CPU usage under load
  - Setup: `zigcat -l -p 8080 -e cmd.exe`
  - Test: Sustained I/O for 60 seconds
  - Target: <20% CPU usage (compare to threaded: 50-80%)
- [ ] Benchmark: Multiple concurrent connections
  - Setup: 10 parallel `telnet localhost 8080` connections
  - Test: All execute commands simultaneously
  - Target: All complete successfully, <50% total CPU
- [ ] Stress test: 100 concurrent connections
  - Setup: Script to spawn 100 telnet connections
  - Test: Each executes simple command
  - Target: All complete, no crashes, no thread exhaustion

#### 4.4 Error Handling Tests
- [ ] Test: Child process crashes (exit code 1)
  - Expected: Session closes gracefully
- [ ] Test: Socket closed by peer (client disconnect)
  - Expected: Child process killed, session cleaned up
- [ ] Test: Execution timeout (--exec-timeout 5)
  - Command: `cmd /c ping -n 100 127.0.0.1` (long-running)
  - Expected: Process killed after 5 seconds
- [ ] Test: Idle timeout (--idle-timeout 10)
  - Command: `cmd.exe` (interactive, no input)
  - Expected: Connection closed after 10 seconds
- [ ] Test: Buffer overflow protection
  - Command: `cmd /c type large_file.txt` (10MB file)
  - Expected: Flow control pauses reads, no crash

#### 4.5 Compatibility Testing
- [ ] Test on Windows 10 (version 1809+)
- [ ] Test on Windows 11
- [ ] Test on Windows Server 2019
- [ ] Test on Windows Server 2022
- [ ] Verify IOCP available on all versions (should be, since Windows Vista)

#### 4.6 Regression Testing
- [ ] Run all existing tests: `zig build test`
- [ ] Run all feature tests: `zig build test-features`
- [ ] Verify no regressions in non-Windows code
- [ ] Verify Linux/macOS still use uring/poll backends

**Exit Criteria**:
- [ ] All unit tests pass (Windows)
- [ ] All integration tests pass (Windows)
- [ ] Performance targets met (<20% CPU, <5ms latency)
- [ ] Stress test passes (100 connections)
- [ ] All error handling tests pass
- [ ] All compatibility tests pass (Windows 10/11/Server)
- [ ] No regressions in existing tests
- [ ] Ready for production deployment

**Commit**: `test(iocp): add comprehensive test suite for IOCP backend`

---

## Phase 5: Production Readiness & Documentation (6-8 hours)

**Objective**: Polish IOCP implementation, remove fallbacks, update documentation.

**Target State**: IOCP is default Windows backend, fully documented, ready for release

### Checklist

#### 5.1 Error Handling Polish
- [ ] Review all `catch |err|` blocks in `iocp_backend.zig`
  - Add specific error messages for Windows error codes
  - Add logging for unexpected errors (use `logging.logError()`)
- [ ] Add Windows error code translation
  - Map `GetLastError()` codes to descriptive messages
  - Examples: `ERROR_BROKEN_PIPE`, `ERROR_OPERATION_ABORTED`, etc.
- [ ] Add error recovery where possible
  - Example: Retry read after `ERROR_MORE_DATA`

#### 5.2 Edge Case Handling
- [ ] Handle partial write completions
  - IOCP may complete WriteFile with fewer bytes than requested
  - Current plan: Consume only `bytes_transferred` from buffer
  - Add test: Write 8KB, verify correct handling if only 4KB written
- [ ] Handle OVERLAPPED reuse
  - Ensure OVERLAPPED not reused until completion received
  - Add assertions (`std.debug.assert(!self.socket_read_pending)`)
- [ ] Handle child process exit during I/O
  - Pending operations should be cancelled gracefully
  - Add test: Kill child mid-transfer, verify cleanup

#### 5.3 Remove Threaded Fallback
- [ ] Remove environment variable check (`ZIGCAT_USE_THREADS=1`)
- [ ] Remove Windows special case in `exec.zig:123-128`
- [ ] Mark `exec_threaded.zig` as deprecated
  - Add comment: "Deprecated: Use IOCP backend instead"
  - Keep file for reference during transition period
- [ ] Update `exec.zig` doc comments (lines 46-52)
  - Change "Windows: Uses multi-threaded approach" → "Windows: Uses IOCP backend"

#### 5.4 Update CLAUDE.md
- [ ] Update "Exec Session Architecture" section (lines 145-216)
  - Add "Windows (IOCP backend)" to backend list
  - Update performance table:
    ```
    | Backend | CPU Usage | Latency | Platform |
    |---|---|---|---|
    | poll(2) | 30-50% | ~2μs | All Unix |
    | io_uring | 5-10% | ~500ns | Linux 5.1+ |
    | IOCP | 10-20% | ~2-5μs | Windows |
    ```
- [ ] Add IOCP backend subsection (mirror uring_backend.zig docs)
  - Key features (async I/O, completion-based, user_data tagging)
  - OVERLAPPED structure management
  - Buffer lifetime requirements
  - Timeout handling
- [ ] Update "Platform Abstraction" section
  - Note Windows now uses async I/O (not threads)

#### 5.5 Update TESTS.md
- [ ] Add "IOCP Backend Tests" section
  - Document `tests/iocp_wrapper_test.zig` (Phase 1 tests)
  - Document `tests/iocp_backend_test.zig` (Phase 2 tests)
  - Document `tests/iocp_exec_test.zig` (Phase 4 integration tests)
  - Expected coverage: 80%+ for IOCP-specific code
- [ ] Update test target list
  - Add `zig build test-iocp` (if separate target created)
  - Note: Windows-only tests

#### 5.6 Update README.md
- [ ] Update "Features" section
  - Add bullet: "High-performance async I/O (io_uring on Linux, IOCP on Windows)"
- [ ] Update "Performance" section (if exists)
  - Add Windows performance metrics (<20% CPU, 100+ connections)
- [ ] Update "Build" section
  - Note: Windows builds now use IOCP backend automatically

#### 5.7 Update CHANGELOG.md
- [ ] Add entry for IOCP backend feature
  ```markdown
  ## [Unreleased]
  ### Added
  - Native Windows IOCP backend for exec mode (replaces threaded I/O)
    - Single-threaded async I/O (10-20% CPU usage vs 50-80% threaded)
    - Scalable to 100+ concurrent connections
    - Feature parity with Linux io_uring backend

  ### Changed
  - Windows exec mode now uses IOCP by default (was multi-threaded)

  ### Deprecated
  - `exec_threaded.zig` (kept for reference, will be removed in future release)
  ```

#### 5.8 Code Review Preparation
- [ ] Run `zig fmt` on all modified files
  - `src/util/iocp_windows.zig`
  - `src/server/exec_session/iocp_backend.zig`
  - `src/server/exec_session/mod.zig`
  - All test files
- [ ] Check for TODO comments (resolve or document)
- [ ] Check for dead code (remove unused functions)
- [ ] Verify all doc comments are complete
- [ ] Run linter (if available): `zlint src/**/*.zig`

#### 5.9 Final Testing
- [ ] Full test suite: `zig build test`
- [ ] Feature tests: `zig build test-features`
- [ ] Manual testing checklist:
  - [ ] `zigcat -l -p 8080 -e cmd.exe` → works
  - [ ] Multiple concurrent connections → works
  - [ ] Long-running command with timeout → terminates correctly
  - [ ] Child process crash → handled gracefully
  - [ ] Client disconnect → resources cleaned up
- [ ] Performance validation:
  - [ ] CPU usage <20% under load
  - [ ] Memory usage stable (no leaks)
  - [ ] Latency <5ms round-trip

**Exit Criteria**:
- [ ] All error cases handled with clear messages
- [ ] All edge cases tested and handled
- [ ] Threaded fallback removed (IOCP is default)
- [ ] All documentation updated (CLAUDE.md, TESTS.md, README.md, CHANGELOG.md)
- [ ] Code formatted and linted
- [ ] All tests pass (unit, integration, manual)
- [ ] Performance targets met
- [ ] Ready for production release

**Commit**: `feat(iocp): finalize Windows IOCP backend for production release`

---

## Known Issues & Limitations

### Current
- [ ] None yet (Phase 1 not started)

### Discovered During Implementation
- [ ] *(Add issues here as discovered)*

---

## Performance Benchmarks

### Baseline (Threaded Backend)
- CPU Usage: 50-80% (single connection)
- Latency: ~10-20ms round-trip
- Scalability: ~20 connections before thread exhaustion warnings
- Memory: ~5MB per connection (thread stacks)

### Target (IOCP Backend)
- CPU Usage: <20% (single connection)
- Latency: <5ms round-trip
- Scalability: 100+ connections
- Memory: ~500KB per connection (buffers only)

### Actual Results (Post-Implementation)
- [ ] *(Fill in after Phase 4 performance testing)*

---

## Risk Mitigation

### High-Risk Areas
1. **OVERLAPPED Lifetime Management**
   - Risk: Reusing OVERLAPPED before completion → crash
   - Mitigation: Unique struct per operation, pending flag tracking
2. **Partial Write Completions**
   - Risk: Assuming full buffer written → data loss
   - Mitigation: Use `bytes_transferred` field, resubmit remainder
3. **Handle Cleanup on Error**
   - Risk: Leaked handles → resource exhaustion
   - Mitigation: Comprehensive `errdefer` blocks, cleanup tests

### Rollback Plan
- Keep `exec_threaded.zig` as fallback during Phases 3-4
- Add environment variable: `ZIGCAT_USE_THREADS=1` (Phase 3)
- If critical issues found, revert exec_session/mod.zig changes
- Tagged union makes backend swap trivial (single line change)

---

## Progress Tracking

**Current Phase**: 🚧 Phase 1 (IOCP Foundation Enhancement)
**Current Task**: Testing (Phase 1.7)
**Blockers**: None
**Completed**:
- [x] Plan approved (2025-01-11)
- [x] IOCP_TODO.md created (2025-01-11)
- [x] Phase 1.1: Reviewed existing IOCP wrapper (78 lines baseline)
- [x] Phase 1.2: Created IocpOperation struct with user_data tagging
- [x] Phase 1.3: Implemented submitReadFile/submitWriteFile with OVERLAPPED
- [x] Phase 1.4: Updated getStatus to extract user_data from completions
- [x] Phase 1.5: Added associateFileHandle and cancelIo helpers
- [x] Phase 1.6: Added comprehensive module-level and function documentation
- [x] File size: 78 → 366 lines (target 200-250 lines exceeded with docs)

**Next Steps**:
1. Create Phase 1 test suite (tests/iocp_wrapper_test.zig)
2. Test on Windows (pipe read/write, timeout handling)
3. Complete Phase 1 checklist and commit

---

## Quick Commands

```bash
# Build (Windows)
zig build

# Run all tests (Windows)
zig build test

# Run IOCP-specific tests (after Phase 1)
zig test src/util/iocp_windows.zig
zig test src/server/exec_session/iocp_backend.zig
zig test tests/iocp_exec_test.zig

# Format code
zig fmt src/util/iocp_windows.zig
zig fmt src/server/exec_session/iocp_backend.zig

# Manual testing
zigcat -l -p 8080 -e cmd.exe -vv  # Verbose logging
# In another terminal:
telnet localhost 8080

# Performance testing
# TODO: Add performance test script
```

---

## Notes

- **Buffer Lifetime**: CRITICAL - OVERLAPPED and buffer must remain valid until completion!
- **Timeout Units**: Windows IOCP uses milliseconds (DWORD), io_uring uses kernel_timespec
- **Error Codes**: Windows uses `GetLastError()`, not errno (different codes)
- **File Handles**: Use `windows.HANDLE` type, not `posix.fd_t` (different types)

---

## References

- [Microsoft Docs: I/O Completion Ports](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)
- [Microsoft Docs: ReadFile with OVERLAPPED](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile)
- [libxev IOCP Backend](https://github.com/mitchellh/libxev/blob/main/src/backend/iocp.zig)
- [zigcat exec_session Refactoring](TODO.md) (reference for modular architecture)

---

**Last Updated**: 2025-01-11
**Status**: 🚧 Ready to begin Phase 1
