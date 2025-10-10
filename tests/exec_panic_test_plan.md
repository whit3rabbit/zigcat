# Exec Mode Panic - Test Plan & Validation Strategy

**Agent**: Tester
**Date**: 2025-10-06
**Session**: swarm-1759749519297-akyo3wzay
**Priority**: CRITICAL

## Executive Summary

The exec mode panic occurs when `executeWithConnection()` completes and threads attempt to join on already-closed file descriptors. This test plan provides comprehensive coverage to isolate, reproduce, and validate the fix.

## Panic Analysis

### Observed Behavior
```bash
$ timeout 5 ./zig-out/bin/zigcat -l -e /bin/echo --allow --allow-ip 127.0.0.1 9999 &
$ echo "test" | nc localhost 9999

# Result:
thread 30428409 panic: reached unreachable code
Unable to dump stack trace: debug info stripped
```

### Root Cause Hypothesis
From `src/server/exec.zig:174-186`:
```zig
// Wait for child to exit
const term = child.wait() catch |err| {
    std.log.err("Failed to wait for child: {any}", .{err});
    stdin_thread.detach();
    stdout_thread.detach();
    stderr_thread.detach();
    return ExecError.ChildWaitFailed;
};

// Wait for I/O threads to complete
stdin_thread.join();  // ← PANIC HERE
stdout_thread.join();
stderr_thread.join();
```

**Problem**: When `child.wait()` succeeds, the child process exits and closes all pipe FDs. The I/O threads (`pipeToChild`, `pipeFromChild`) complete and return. However, attempting to `join()` threads that have already exited or were detached causes a panic.

### Thread Lifecycle Issue

**Current Flow**:
1. Spawn 3 I/O threads (stdin, stdout, stderr)
2. Call `child.wait()` - blocks until child exits
3. Child exits → pipes closed automatically by OS
4. I/O threads detect closed pipes and return
5. Main thread attempts to `join()` threads → **PANIC**

**Why Panic**:
- Threads may have already been cleaned up when pipes closed
- Calling `join()` on a thread that was implicitly detached causes unreachable code panic
- Thread cleanup order is non-deterministic when pipes close

## Test Strategy

### Test Categories

#### 1. Minimal Reproduction Tests
**Purpose**: Isolate the exact panic condition

**T1.1: Immediate Exit Command**
```zig
test "exec panic: immediate exit command" {
    // Command that exits immediately: /bin/true or /bin/echo
    // Should panic on thread join after child.wait()

    const allocator = std.testing.allocator;
    const config = ExecConfig{
        .mode = .direct,
        .program = "/bin/true",
        .args = &[_][]const u8{},
    };

    // Expect panic or ChildWaitFailed
    // This test validates the current broken behavior
}
```

**T1.2: Echo Command with Input**
```zig
test "exec panic: echo with immediate close" {
    // Reproduce exact scenario from manual test:
    // Server: -l -e /bin/echo --allow --allow-ip 127.0.0.1 9999
    // Client: echo "test" | nc localhost 9999

    // Setup mock socket pair
    // Execute echo command
    // Verify panic occurs on thread join
}
```

#### 2. Thread Lifecycle Validation Tests
**Purpose**: Verify correct thread management

**T2.1: Thread State Before Join**
```zig
test "thread lifecycle: verify thread alive before join" {
    // Track thread state throughout execution
    // Ensure threads are still joinable when join() is called
    // Use atomic flags to track thread completion
}
```

**T2.2: Thread Detachment Timing**
```zig
test "thread lifecycle: verify detach only on error" {
    // Ensure threads are ONLY detached on spawn failure
    // Not detached on successful completion
    // Verify detach() is never called in success path
}
```

**T2.3: Pipe Closure Detection**
```zig
test "thread lifecycle: pipe closure handling" {
    // Verify threads detect pipe closure gracefully
    // Ensure threads exit cleanly when pipes close
    // Validate thread return path doesn't cause panic
}
```

#### 3. Process Cleanup Sequence Tests
**Purpose**: Validate correct ordering of cleanup operations

**T3.1: Wait Before Join Order**
```zig
test "cleanup sequence: child.wait before thread.join" {
    // Validate that child.wait() completes first
    // Ensure thread.join() happens in correct order
    // Verify no race conditions
}
```

**T3.2: Pipe Lifetime Management**
```zig
test "cleanup sequence: pipe lifetime vs thread lifetime" {
    // Track pipe FD closure timing
    // Verify pipes stay open until threads need them
    // Ensure threads complete before pipes close
}
```

**T3.3: Error Path Cleanup**
```zig
test "cleanup sequence: error path uses detach correctly" {
    // Force child.wait() error
    // Verify all threads are detached
    // Ensure no join() calls in error path
}
```

#### 4. Edge Case Tests
**Purpose**: Cover unusual scenarios

**T4.1: Long-Running Command**
```zig
test "edge case: long-running command with early socket close" {
    // Command: sleep 10
    // Client closes socket after 1s
    // Verify thread cleanup when child still running
}
```

**T4.2: Command That Never Reads Stdin**
```zig
test "edge case: command ignores stdin" {
    // Command: /bin/true (closes stdin immediately)
    // Verify stdin thread handles BrokenPipe correctly
    // Ensure no deadlock or panic
}
```

**T4.3: Command That Never Writes Output**
```zig
test "edge case: silent command" {
    // Command: /bin/true or sleep 1
    // No stdout/stderr output
    // Verify stdout/stderr threads handle empty pipes
}
```

**T4.4: Concurrent Multiple Connections**
```zig
test "edge case: multiple simultaneous exec connections" {
    // Spawn 5 clients simultaneously
    // Each executes /bin/echo
    // Verify no race conditions or panics
}
```

**T4.5: Rapid Connect-Disconnect**
```zig
test "edge case: client connects and disconnects immediately" {
    // Client connects, sends no data, closes
    // Verify child process handles empty stdin
    // Ensure threads cleanup without panic
}
```

#### 5. Thread Detachment Scenarios
**Purpose**: Validate detach behavior

**T5.1: Spawn Failure Detaches Correctly**
```zig
test "detachment: stdin spawn failure" {
    // Force stdin thread spawn to fail
    // Verify no detach on already-failed thread
    // Ensure error returns correctly
}
```

**T5.2: Cascade Detachment on Multi-Failure**
```zig
test "detachment: stdout spawn failure after stdin success" {
    // stdin spawns successfully
    // stdout spawn fails
    // Verify stdin thread detached
    // Ensure no join() on detached thread
}
```

**T5.3: Wait Failure Detaches All**
```zig
test "detachment: child.wait failure detaches all threads" {
    // Force child.wait() to fail (e.g., process killed)
    // Verify all 3 threads are detached
    // Ensure function returns without join()
}
```

## Validation Strategy for Fix

### Expected Fix Pattern

**Before (Broken)**:
```zig
const term = child.wait() catch |err| {
    // detach threads on error
    return ExecError.ChildWaitFailed;
};

// PANIC: Threads may already be gone
stdin_thread.join();
stdout_thread.join();
stderr_thread.join();
```

**After (Fixed)** - Option A: Wait for threads first:
```zig
// Join threads BEFORE waiting for child
// (threads will exit when pipes close after child exits)
stdin_thread.join();
stdout_thread.join();
stderr_thread.join();

const term = child.wait() catch |err| {
    return ExecError.ChildWaitFailed;
};
```

**After (Fixed)** - Option B: Use detach pattern:
```zig
const term = child.wait() catch |err| {
    stdin_thread.detach();
    stdout_thread.detach();
    stderr_thread.detach();
    return ExecError.ChildWaitFailed;
};

// Only join if wait succeeded
stdin_thread.detach();
stdout_thread.detach();
stderr_thread.detach();
```

**After (Fixed)** - Option C: Track thread state:
```zig
var threads_joined = false;
defer if (!threads_joined) {
    stdin_thread.detach();
    stdout_thread.detach();
    stderr_thread.detach();
};

// Join threads first
stdin_thread.join();
stdout_thread.join();
stderr_thread.join();
threads_joined = true;

const term = child.wait() catch |err| {
    return ExecError.ChildWaitFailed;
};
```

### Validation Tests for Fix

**V1: No Panic on Immediate Exit**
```zig
test "validate fix: /bin/true completes without panic" {
    // Run /bin/true command
    // Verify no panic during cleanup
    // Ensure all resources freed
}
```

**V2: No Panic on Echo with Input**
```zig
test "validate fix: /bin/echo test completes without panic" {
    // Exact reproduction of manual test
    // Verify successful completion
    // Check thread cleanup order
}
```

**V3: Performance Unchanged**
```zig
test "validate fix: no performance regression" {
    // Run 100 iterations of /bin/echo
    // Measure total time vs baseline
    // Ensure < 5% performance impact
}
```

**V4: Error Paths Still Work**
```zig
test "validate fix: error handling still correct" {
    // Force various error conditions
    // Verify proper error returns
    // Ensure no resource leaks
}
```

## Test Coverage Matrix

| Scenario | Test ID | Priority | Status |
|----------|---------|----------|--------|
| Immediate exit panic | T1.1, T1.2 | P0 | Pending |
| Thread lifecycle | T2.1, T2.2, T2.3 | P0 | Pending |
| Cleanup sequence | T3.1, T3.2, T3.3 | P0 | Pending |
| Long-running command | T4.1 | P1 | Pending |
| No stdin reads | T4.2 | P1 | Pending |
| Silent command | T4.3 | P1 | Pending |
| Concurrent connections | T4.4 | P2 | Pending |
| Rapid disconnect | T4.5 | P2 | Pending |
| Spawn failures | T5.1, T5.2, T5.3 | P1 | Pending |
| Fix validation | V1, V2, V3, V4 | P0 | Pending (post-fix) |

## Implementation Notes

### Test Requirements
- Use `std.testing.allocator` for all allocations
- Mock socket pairs using `std.posix.socketpair()`
- Use short-lived commands to keep test time < 5s each
- Platform-specific skips for Windows (if needed)
- Timeout protection: all tests < 10s max

### Test Utilities Needed
```zig
// Helper: Create mock socket pair
fn createMockSocketPair() ![2]std.posix.socket_t

// Helper: Execute command with timeout
fn executeWithTimeout(config: ExecConfig, timeout_ms: u32) !void

// Helper: Verify thread state
fn isThreadJoinable(thread: std.Thread) bool

// Helper: Count open file descriptors
fn countOpenFDs() usize
```

### Coverage Goals
- **Line Coverage**: 95%+ of exec.zig
- **Branch Coverage**: 100% of thread spawn error paths
- **Edge Case Coverage**: 100% of identified edge cases
- **Platform Coverage**: macOS, Linux (CI)

## Test Execution Plan

### Phase 1: Reproduce Panic (Current)
1. Run T1.1, T1.2 to confirm panic
2. Verify panic stacktrace points to `join()`
3. Document exact panic conditions

### Phase 2: Validate Root Cause
1. Run T2.* thread lifecycle tests
2. Run T3.* cleanup sequence tests
3. Confirm hypothesis about join timing

### Phase 3: Test Edge Cases
1. Run T4.* edge case tests
2. Run T5.* detachment tests
3. Document any additional panics found

### Phase 4: Post-Fix Validation
1. Apply fix from coder agent
2. Run V1-V4 validation tests
3. Re-run ALL tests (T1-T5) to ensure fix doesn't break edge cases
4. Verify no regressions in existing test suite

## Integration with Existing Tests

### Existing Test Suite
- `/tests/exec_test.zig`: 14 tests (security, shell commands)
- **Gap**: No thread lifecycle tests
- **Gap**: No panic reproduction tests
- **Gap**: No cleanup sequence validation

### New Test File
Create `/tests/exec_thread_lifecycle_test.zig`:
- Contains T1-T5 test series
- Imports from `/src/server/exec.zig`
- Uses timeout wrappers from `/tests/utils/timeout_safety.zig`

### Build Integration
```zig
// Add to build.zig:
const exec_thread_tests = b.addTest(.{
    .root_source_file = b.path("tests/exec_thread_lifecycle_test.zig"),
});
exec_thread_tests.linkLibC();
const run_exec_thread_tests = b.addRunArtifact(exec_thread_tests);
const test_exec_threads = b.step("test-exec-threads", "Run exec thread lifecycle tests");
test_exec_threads.dependOn(&run_exec_thread_tests.step);
```

## Success Criteria

### Pre-Fix (Validation of Panic)
- [ ] T1.1 reproduces panic reliably
- [ ] T1.2 reproduces exact manual test scenario
- [ ] Root cause confirmed via T2.* tests

### Post-Fix (Validation of Solution)
- [ ] V1-V4 all pass without panic
- [ ] All T1-T5 tests pass
- [ ] No test takes > 5s
- [ ] No memory leaks detected
- [ ] No file descriptor leaks
- [ ] Existing test suite still passes

## Risk Assessment

### High Risk Areas
1. **Thread join timing**: Incorrect order causes panic
2. **Pipe lifetime**: Premature close breaks threads
3. **Error path detachment**: Missing detach() causes leak

### Mitigation Strategies
1. Use atomic flags to track thread state
2. Add explicit pipe lifetime management
3. Test all error paths with forced failures

## Coordination with Hive Mind

### Memory Keys
- `hive/tester/test-plan` - This document
- `hive/tester/panic-reproduction` - T1.1, T1.2 results
- `hive/tester/validation-results` - V1-V4 results

### Dependencies
- Waiting on: `hive/coder/implementation` (fix implementation)
- Blocking: `hive/reviewer/validation` (code review after fix)

### Handoff to Next Agent
**For Coder Agent**:
- Use Option A or C for fix (thread join order)
- Avoid Option B (full detachment breaks error handling)
- Ensure all error paths still detach correctly

**For Reviewer Agent**:
- Validate thread safety of fix
- Check for race conditions in cleanup
- Verify no resource leaks introduced

---

**Status**: Test plan complete, ready for implementation
**Next Step**: Implement T1.1, T1.2 minimal reproduction tests
**Estimated Time**: 2-3 hours for full test suite implementation
