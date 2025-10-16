# Zigcat Test Suite Documentation

This document provides comprehensive information about the Zigcat test suite, including test counts, coverage, build targets, and troubleshooting guidance.

## Quick Start

```bash
# Run all tests
zig build test                    # Core unit tests (~2s)
zig build test-timeout            # Timeout tests (10 tests)
zig build test-features           # All feature tests
zig build test-validation         # Memory safety tests (13 tests)

# Run specific test suites
zig build test-udp                # UDP server tests (5 tests)
zig build test-zero-io            # Zero-I/O mode tests (6 tests)
zig build test-quit-eof           # Quit-after-EOF tests (9 tests)
zig build test-platform           # Platform detection tests (20 tests)
zig build test-portscan-features  # Port scanning features (23 tests)
zig build test-portscan-uring     # io_uring compile-time tests (7 tests)
```

## Test Suite Overview

### Unit Tests (built into src/)

**Test Count**: dynamic (`zig build test` aggregates all built-in tests)
**Build Command**: `zig build test`
**Coverage**: Core functionality embedded in source files
**Runtime**: ~2 seconds

Tests are embedded in source files using `test "name" { }` blocks. These tests validate:
- Configuration parsing
- Socket operations
- Network protocol handlers
- TLS functionality
- Utility functions
- Hex dump formatting, ASCII sanitisation, and configuration parsing

### Standalone Test Suites

#### 1. Timeout Tests
**File**: `tests/timeout_test.zig`
**Test Count**: 10 tests
**Build Command**: `zig build test-timeout`
**Purpose**: Validate timeout handling across all network operations

**Coverage**:
- TCP connect timeouts
- Idle timeouts
- Poll timeout enforcement
- TTY vs non-TTY timeout behavior
- Timeout value conversion

#### 2. UDP Tests
**File**: `tests/udp_test.zig`
**Test Count**: 5 tests
**Build Command**: `zig build test-udp`
**Purpose**: Validate UDP server functionality

**Coverage**:
- UDP socket creation
- Bind and listen operations
- Message send/receive
- Timeout handling for UDP
- Error conditions

#### 3. Zero-I/O Mode Tests
**File**: `tests/zero_io_test.zig`
**Test Count**: 6 tests
**Build Command**: `zig build test-zero-io`
**Purpose**: Validate port scanning without data transfer

**Coverage**:
- Port scanning basics
- Connection-only mode
- Scan result accuracy
- Timeout enforcement
- Error handling

#### 4. Quit-after-EOF Tests
**File**: `tests/quit_eof_test.zig`
**Test Count**: 9 tests
**Build Command**: `zig build test-quit-eof`
**Purpose**: Validate graceful shutdown on EOF

**Coverage**:
- EOF detection
- Clean shutdown
- Bidirectional EOF handling
- Resource cleanup
- Edge cases

#### 5. Platform Detection Tests
**File**: `tests/test_platform.zig`
**Test Count**: 20 tests
**Build Command**: `zig build test-platform`
**Purpose**: Validate kernel version parsing and platform detection

**Coverage**:
- Kernel version parsing (vanilla, Ubuntu, Fedora, RHEL, Arch formats)
- Version comparison logic
- io_uring availability detection
- Edge cases (invalid versions, zero versions, high version numbers)
- Platform-specific behavior

**Example Test Cases**:
```zig
test "parseKernelVersion - Ubuntu/Debian format" {
    const version = try parseKernelVersion("5.15.0-91-generic");
    try testing.expectEqual(@as(u32, 5), version.major);
    try testing.expectEqual(@as(u32, 15), version.minor);
}
```

#### 6. Port Scanning Feature Tests
**File**: `tests/test_portscan_features.zig`
**Test Count**: 23 tests
**Build Command**: `zig build test-portscan-features`
**Purpose**: Validate port randomization, delays, and auto-selection

**Coverage**:
- Port randomization (Fisher-Yates shuffle)
- Inter-scan delays
- Sequential vs parallel auto-selection
- Thread pool management
- Result consistency

**Key Features Tested**:
- Randomization prevents IDS/IPS signature detection
- Delays reduce network spike detection
- Auto-selection chooses optimal backend
- Results always sorted by port number

#### 7. io_uring Port Scanner Tests (NEW)
**File**: `tests/test_portscan_uring.zig`
**Test Count**: 7 tests
**Build Command**: `zig build test-portscan-uring`
**Purpose**: Validate io_uring compile-time availability and API

**Coverage**:
- io_uring compile-time availability on Linux
- io_uring compile-time unavailability on non-Linux
- io_uring initialization attempts
- SQE operations existence
- Platform detection
- Socket types for io_uring
- kernel_timespec for timeouts

**Platform Behavior**:
- **Linux**: Tests verify IO_Uring types and initialization
- **Non-Linux** (macOS, BSD, Windows): Tests gracefully skip
- **Linux < 5.1**: Init tests skip if kernel doesn't support io_uring

**Example Test**:
```zig
test "io_uring initialization attempt" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const IO_Uring = std.os.linux.IO_Uring;
    var ring = IO_Uring.init(1, 0) catch |err| {
        if (err == error.SystemResources) {
            return error.SkipZigTest; // Kernel < 5.1
        }
        return err;
    };
    defer ring.deinit();

    try testing.expect(true);
}
```

**Note**: These are compile-time and API tests only. Full integration testing of the io_uring scanner implementation is done through the main unit tests in `src/util/portscan_uring.zig`.

### Validation Tests

#### CRLF Memory Tests
**File**: `tests/crlf_memory_test.zig`
**Test Count**: 8 tests
**Build Command**: `zig build test-crlf`
**Purpose**: Validate CRLF conversion memory safety

#### Shell Memory Tests
**File**: `tests/shell_memory_test.zig`
**Test Count**: 5 tests
**Build Command**: `zig build test-shell`
**Purpose**: Validate shell command memory management

**Combined Command**: `zig build test-validation` (runs both)

### Performance Tests

#### I/O Control Performance
**File**: `tests/io_control_performance_test.zig`
**Build Command**: `zig build test-io-performance`
**Purpose**: Benchmark I/O control overhead

#### Broker Performance
**File**: `tests/broker_chat_performance_test.zig`
**Build Command**: `zig build test-broker-performance`
**Purpose**: Validate broker/chat performance

#### Multi-Client Integration
**File**: `tests/multi_client_integration_test.zig`
**Build Command**: `zig build test-multi-client`
**Purpose**: Test concurrent client handling

### Security Tests

#### Unix Socket Security
**File**: `tests/unix_socket_security_test.zig`
**Build Command**: `zig build test-unix-security`
**Purpose**: Validate Unix socket security (TOCTTOU, permissions, limits)

#### SSL/TLS Tests
**File**: `tests/test_ssl.zig`
**Test Count**: 31 tests
**Build Command**: `zig build test-ssl`
**Purpose**: Comprehensive SSL/TLS testing (cert generation, handshake, error handling)

### Exec Session Module Tests

#### Exec Session Modules (NEW)
**Location**: `src/server/exec_session/`
**Test Count**: 17 unit tests embedded in modules
**Build Command**: `zig build test` (includes all module tests)
**Purpose**: Validate modular exec session architecture

**Module Test Breakdown**:

1. **flow_control.zig** - 5 tests
   - Flow state pause/resume logic
   - Threshold calculation (75%/25% hysteresis)
   - Edge cases (zero buffers, 100% threshold)
   - Precision handling

2. **state.zig** - 5 tests
   - Generic SessionState instantiation
   - Stream closure tracking
   - Buffer management
   - IoRingBuffer integration
   - Mock buffer type support

3. **socket_io.zig** - 2 tests
   - SocketReadContext validation
   - SocketWriteContext validation
   - Compile-time type safety

4. **child_io.zig** - 3 tests
   - ChildReadContext validation
   - ChildWriteContext validation
   - Stream closure handling
   - Compile-time type safety

5. **mod.zig** - 2 tests
   - ExecSession union type validation
   - Backend dispatch (poll vs uring)

**Test Strategy**:
- **poll_backend.zig** and **uring_backend.zig**: Integration-heavy modules tested via end-to-end exec mode tests (no dedicated unit tests)
- **Helper modules**: Focused unit tests for reusable I/O logic
- **Flow control**: Edge case testing for threshold calculations
- **State management**: Generic type parameter validation

**Example Test (flow_control.zig)**:
```zig
test "FlowState pause and resume with hysteresis" {
    var flow = FlowState{
        .pause_threshold_bytes = 7500,   // 75%
        .resume_threshold_bytes = 2500,  // 25%
        .paused = false,
    };

    flow.update(8000);  // Above pause threshold
    try testing.expect(flow.shouldPause());

    flow.update(3000);  // Between thresholds (stays paused)
    try testing.expect(flow.shouldPause());

    flow.update(2000);  // Below resume threshold
    try testing.expect(!flow.shouldPause());
}
```

**Architecture Benefits**:
- ✅ Each module has focused unit tests
- ✅ Backend modules tested via integration (realistic scenarios)
- ✅ Generic types validated at compile time
- ✅ Context structs ensure type safety
- ✅ All tests pass via `zig build test`

### Thread Lifecycle Tests

#### Exec Thread Lifecycle
**File**: `tests/exec_thread_lifecycle_test.zig`
**Build Command**: `zig build test-exec-threads`
**Purpose**: Validate thread lifecycle management in exec mode

**Critical Pattern Tested**:
```zig
// ✅ CORRECT: Join threads BEFORE closing resources
stdin_thread.join();
stdout_thread.join();
child.wait();  // Closes pipes, but threads already exited

// ❌ WRONG: Resource cleanup before thread join
child.wait();  // Closes pipes immediately
stdin_thread.join();  // PANIC: Thread already terminated
```

### Protocol Tests

#### Telnet State Machine
**File**: `tests/telnet_state_machine_test.zig`
**Build Command**: `zig build test-telnet`
**Purpose**: Validate Telnet protocol handling

#### Poll Wrapper Tests
**File**: `tests/poll_wrapper_test.zig`
**Build Command**: `zig build test-poll-wrapper`
**Purpose**: Cross-platform poll wrapper validation

### Port Scanning Tests

#### Parallel Scan Tests
**File**: `tests/test_parallel_scan.zig`
**Build Command**: `zig build test-parallel-scan`
**Purpose**: PortRange parsing, parallel correctness, thread safety

## Test Coverage by Module

| **Module** | **Unit Tests** | **Standalone Tests** | **Total** |
|------------|----------------|----------------------|-----------|
| src/util/portscan.zig | Embedded | 23 (features) | 23+ |
| src/util/portscan_uring.zig | Embedded | 7 (compile-time) | 7+ |
| src/util/platform.zig | Embedded | 20 (parsing) | 20+ |
| src/io/transfer.zig | Embedded | 10 (timeout) | 10+ |
| src/io/linecodec.zig | Embedded | 8 (CRLF) | 8+ |
| src/net/tcp.zig | Embedded | - | ~5 |
| src/net/udp.zig | Embedded | 5 (UDP) | 5+ |
| src/tls/* | Embedded | 31 (SSL) | 31+ |
| src/server/exec.zig | Embedded | Thread lifecycle | 5+ |
| **src/server/exec_session/** | **17 (6 modules)** | **-** | **17** |
| ├─ flow_control.zig | 5 | - | 5 |
| ├─ state.zig | 5 | - | 5 |
| ├─ socket_io.zig | 2 | - | 2 |
| ├─ child_io.zig | 3 | - | 3 |
| ├─ mod.zig | 2 | - | 2 |
| └─ poll/uring backends | Integration tests | - | - |

## Running Tests

### All Tests
```bash
zig build test                 # All unit tests
zig build test-features        # All feature tests
zig build test-validation      # All validation tests
```

### Individual Suites
```bash
zig build test-timeout         # Timeout handling
zig build test-platform        # Platform detection
zig build test-portscan-features # Port scanning features
zig build test-portscan-uring  # io_uring compile-time tests
```

### Docker Cross-Platform Tests
```bash
zig build test-docker          # Requires Docker
```

## Test Best Practices

### Writing Standalone Tests

**Rule**: Standalone tests (in `tests/` directory) must be self-contained and CANNOT import from `src/`.

**✅ CORRECT - Self-contained**:
```zig
const std = @import("std");
const testing = std.testing;

test "example" {
    const sock = try std.posix.socket(...);
    defer std.posix.close(sock);
    // Test logic using only std library
}
```

**❌ WRONG - Importing from src**:
```zig
const config = @import("../src/config.zig");  // ERROR: Circular dependency
const tcp = @import("../src/net/tcp.zig");     // ERROR
```

### Platform-Specific Tests

Tests should gracefully skip on unsupported platforms:

```zig
test "Linux-specific feature" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    // Linux-specific test logic
}
```

### Adding New Tests

When creating a new test suite:

1. **Create test file**: `tests/my_test.zig`
2. **Add to build.zig**:
   ```zig
   const my_test_module = b.createModule(.{
       .root_source_file = b.path("tests/my_test.zig"),
       .target = target,
       .optimize = optimize,
   });
   const my_tests = b.addTest(.{ .root_module = my_test_module });
   my_tests.linkLibC();
   const run_my_tests = b.addRunArtifact(my_tests);
   const my_test_step = b.step("test-my-feature", "Description");
   my_test_step.dependOn(&run_my_tests.step);
   ```
3. **Update this file (TESTS.md)**:
   - Add test count to appropriate section
   - Document what the test validates
   - Add build command to Quick Start
   - Update Test Coverage table

## Troubleshooting

### Test Failures

**Timeout Tests Hanging**:
- Check if tests are using timeout_safety.zig wrappers
- Verify timeout values are in valid range (10ms-60s)
- See `/docs/TIMEOUT_SAFETY.md` for patterns

**Platform Tests Failing**:
- Ensure kernel version >= 5.1 for io_uring tests
- Check if running on expected platform (Linux vs macOS)
- Review test skip conditions

**Memory Tests Failing**:
- Run with leak detection: `zig build test --summary all`
- Check for missing `defer` statements
- Verify all allocations have corresponding frees

### Test Resources

- **Timeout Safety**: `/docs/TIMEOUT_SAFETY.md`
- **Validation Results**: `/docs/VALIDATION_RESULTS_FINAL.md`
- **Bug Analysis**: `/docs/TEST_VALIDATION_REPORT.md`
- **Exec Panic Testing**: `/tests/EXEC_PANIC_TESTING_SUMMARY.md`

## Test Counts Summary

| **Category** | **Test Count** |
|--------------|----------------|
| Unit Tests (src/) | 20 |
| Exec Session Modules | 17 |
| Timeout Tests | 10 |
| UDP Tests | 5 |
| Zero-I/O Tests | 6 |
| Quit-EOF Tests | 9 |
| Platform Tests | 20 |
| Port Scan Features | 23 |
| io_uring Tests | 7 |
| CRLF Memory Tests | 8 |
| Shell Memory Tests | 5 |
| SSL/TLS Tests | 31 |
| **Total Standalone** | **~124** |
| **Grand Total** | **~161+** |

## CI/CD Integration

Tests are designed to work in CI environments:

- All tests use timeout protection (max 5 minutes)
- Platform-specific tests skip gracefully
- No external dependencies required (except Docker for cross-platform tests)
- Clear exit codes for pass/fail

## Future Test Additions

Planned test suites:

- Full io_uring integration tests (requires Linux test environment)
- IPv6 connectivity tests
- TLS certificate validation tests
- Proxy chaining tests
- Broker flow control tests

## Contributing

When adding tests:

1. Follow the self-contained pattern for standalone tests
2. Use descriptive test names
3. Add timeout protection for network operations
4. Update this file with test counts and descriptions
5. Add skip conditions for platform-specific tests
6. Include example test cases in documentation
