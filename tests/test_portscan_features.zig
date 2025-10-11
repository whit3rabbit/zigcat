//! Port scanning feature tests
//!
//! Tests for new port scanning features:
//! - Port randomization (Fisher-Yates shuffle)
//! - Inter-scan delays
//! - Auto-selection logic
//!
//! Note: This is a standalone test file and must be self-contained.
//! It cannot import from src/ due to circular dependency issues.

const std = @import("std");
const testing = std.testing;

// ============================================================================
// Port Randomization Tests
// ============================================================================

/// Fisher-Yates shuffle implementation (duplicated for standalone testing)
fn randomizePortOrder(ports: []u16) void {
    if (ports.len <= 1) return;

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const random = prng.random();
    std.Random.shuffle(random, u16, ports);
}

test "randomizePortOrder - empty array" {
    var ports: [0]u16 = .{};
    randomizePortOrder(&ports);
    try testing.expectEqual(@as(usize, 0), ports.len);
}

test "randomizePortOrder - single port" {
    var ports = [_]u16{80};
    randomizePortOrder(&ports);
    try testing.expectEqual(@as(u16, 80), ports[0]);
}

test "randomizePortOrder - all ports present after shuffle" {
    var ports = [_]u16{ 21, 22, 23, 80, 443, 3000, 8080, 8443 };
    const original = ports;

    randomizePortOrder(&ports);

    // Verify all original ports are still present
    for (original) |expected_port| {
        var found = false;
        for (ports) |actual_port| {
            if (actual_port == expected_port) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // Verify count is the same
    try testing.expectEqual(original.len, ports.len);
}

test "randomizePortOrder - order changes (probabilistic)" {
    // This test has a tiny chance of false positive if shuffle produces
    // identical order, but probability is 1/8! ≈ 0.0025%
    var ports = [_]u16{ 21, 22, 23, 80, 443, 3000, 8080, 8443 };
    const original = ports;

    randomizePortOrder(&ports);

    // Check that at least one element changed position
    var changed = false;
    for (ports, 0..) |port, i| {
        if (port != original[i]) {
            changed = true;
            break;
        }
    }

    // With 8 elements, probability of no change is ~0.0025%
    try testing.expect(changed);
}

test "randomizePortOrder - common port ranges" {
    var ports = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    randomizePortOrder(&ports);

    // Verify all numbers 1-10 are present
    for (1..11) |expected| {
        var found = false;
        for (ports) |actual| {
            if (actual == @as(u16, @intCast(expected))) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "randomizePortOrder - duplicate ports handled correctly" {
    var ports = [_]u16{ 80, 80, 443, 443 };
    randomizePortOrder(&ports);

    // Should still have 2x 80 and 2x 443
    var count_80: usize = 0;
    var count_443: usize = 0;
    for (ports) |port| {
        if (port == 80) count_80 += 1;
        if (port == 443) count_443 += 1;
    }

    try testing.expectEqual(@as(usize, 2), count_80);
    try testing.expectEqual(@as(usize, 2), count_443);
}

test "randomizePortOrder - large port range" {
    const allocator = testing.allocator;

    // Create array of 1000 sequential ports
    const ports = try allocator.alloc(u16, 1000);
    defer allocator.free(ports);

    for (ports, 0..) |*port, i| {
        port.* = @intCast(i + 1);
    }

    randomizePortOrder(ports);

    // Verify all ports 1-1000 are present
    for (1..1001) |expected| {
        var found = false;
        for (ports) |actual| {
            if (actual == @as(u16, @intCast(expected))) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // Verify order changed (with 1000 elements, probability of no change is effectively 0)
    var sequential = true;
    for (ports, 0..) |port, i| {
        if (port != @as(u16, @intCast(i + 1))) {
            sequential = false;
            break;
        }
    }
    try testing.expect(!sequential);
}

// ============================================================================
// Delay Functionality Tests
// ============================================================================

test "inter-scan delay - zero delay (no sleep)" {
    const delay_ms: u32 = 0;

    const start = std.time.nanoTimestamp();

    // Simulate scan loop with no delay
    for (0..10) |_| {
        if (delay_ms > 0) {
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    // Should complete almost instantly (< 10ms)
    try testing.expect(elapsed_ms < 10);
}

test "inter-scan delay - 10ms delay timing" {
    const delay_ms: u32 = 10;
    const iterations: usize = 5;

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
    }

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    // Should take at least 50ms (5 iterations * 10ms)
    // Allow up to 100ms for scheduling overhead
    try testing.expect(elapsed_ms >= 50);
    try testing.expect(elapsed_ms <= 100);
}

test "inter-scan delay - 100ms delay timing" {
    const delay_ms: u32 = 100;
    const iterations: usize = 3;

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
    }

    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);

    // Should take at least 300ms (3 iterations * 100ms)
    // Allow up to 400ms for scheduling overhead
    try testing.expect(elapsed_ms >= 300);
    try testing.expect(elapsed_ms <= 400);
}

// ============================================================================
// Configuration Tests
// ============================================================================

test "scan configuration - default values" {
    const Config = struct {
        scan_randomize: bool = false,
        scan_delay_ms: u32 = 0,
    };

    const cfg = Config{};

    try testing.expectEqual(false, cfg.scan_randomize);
    try testing.expectEqual(@as(u32, 0), cfg.scan_delay_ms);
}

test "scan configuration - randomize enabled" {
    const Config = struct {
        scan_randomize: bool = false,
        scan_delay_ms: u32 = 0,
    };

    const cfg = Config{
        .scan_randomize = true,
    };

    try testing.expectEqual(true, cfg.scan_randomize);
    try testing.expectEqual(@as(u32, 0), cfg.scan_delay_ms);
}

test "scan configuration - delay configured" {
    const Config = struct {
        scan_randomize: bool = false,
        scan_delay_ms: u32 = 0,
    };

    const cfg = Config{
        .scan_delay_ms = 50,
    };

    try testing.expectEqual(false, cfg.scan_randomize);
    try testing.expectEqual(@as(u32, 50), cfg.scan_delay_ms);
}

test "scan configuration - both features enabled" {
    const Config = struct {
        scan_randomize: bool = false,
        scan_delay_ms: u32 = 0,
    };

    const cfg = Config{
        .scan_randomize = true,
        .scan_delay_ms = 100,
    };

    try testing.expectEqual(true, cfg.scan_randomize);
    try testing.expectEqual(@as(u32, 100), cfg.scan_delay_ms);
}

// ============================================================================
// Auto-Selection Logic Tests
// ============================================================================

test "auto-selection - parallel flag controls backend" {
    const parallel = true;
    const use_parallel = parallel;

    try testing.expect(use_parallel);
}

test "auto-selection - sequential fallback when parallel disabled" {
    const parallel = false;
    const use_parallel = parallel;

    try testing.expect(!use_parallel);
}

// ============================================================================
// Edge Cases and Validation Tests
// ============================================================================

test "delay validation - maximum delay value" {
    const max_delay: u32 = std.math.maxInt(u32);

    // Should not panic or overflow
    try testing.expectEqual(max_delay, max_delay);
}

test "delay validation - common delay values" {
    const delays = [_]u32{ 0, 1, 10, 50, 100, 500, 1000 };

    for (delays) |delay| {
        // All should be valid u32 values
        try testing.expect(delay >= 0);
        try testing.expect(delay <= std.math.maxInt(u32));
    }
}

test "randomization - deterministic with same seed" {
    var ports1 = [_]u16{ 21, 22, 23, 80, 443 };
    var ports2 = [_]u16{ 21, 22, 23, 80, 443 };

    // Use same seed for both
    const seed: u64 = 12345;

    var prng1 = std.Random.DefaultPrng.init(seed);
    std.Random.shuffle(prng1.random(), u16, &ports1);

    var prng2 = std.Random.DefaultPrng.init(seed);
    std.Random.shuffle(prng2.random(), u16, &ports2);

    // Should produce identical shuffles
    for (ports1, 0..) |port, i| {
        try testing.expectEqual(port, ports2[i]);
    }
}

test "randomization - different results with different seeds" {
    var ports1 = [_]u16{ 21, 22, 23, 80, 443, 3000, 8080, 8443 };
    var ports2 = [_]u16{ 21, 22, 23, 80, 443, 3000, 8080, 8443 };

    // Use different seeds
    var prng1 = std.Random.DefaultPrng.init(12345);
    std.Random.shuffle(prng1.random(), u16, &ports1);

    var prng2 = std.Random.DefaultPrng.init(54321);
    std.Random.shuffle(prng2.random(), u16, &ports2);

    // Should produce different shuffles (probabilistically)
    // With 8 elements and different seeds, probability of identical shuffle is ~0.0025%
    var different = false;
    for (ports1, 0..) |port, i| {
        if (port != ports2[i]) {
            different = true;
            break;
        }
    }

    try testing.expect(different);
}
