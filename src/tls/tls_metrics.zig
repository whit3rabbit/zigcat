//! TLS connection metrics collection with thread-safe atomic counters.
//!
//! This module provides detailed metrics tracking for TLS connections:
//! - Cipher suite and protocol version information
//! - Certificate verification status
//! - Encrypted data throughput (bytes sent/received)
//! - Handshake performance timing
//! - Atomic counter updates for thread safety
//!
//! **Usage:**
//! ```zig
//! var metrics = TlsMetrics.init();
//! metrics.recordHandshake(cipher, version, true, duration_ns);
//! metrics.recordWrite(1024); // 1KB encrypted
//! metrics.recordRead(2048);  // 2KB decrypted
//! metrics.logSummary();      // Print metrics
//! ```
//!
//! **Thread Safety:**
//! All counter updates use atomic operations for safe concurrent access.

const std = @import("std");
const logging = @import("../util/logging.zig");
const config = @import("../config.zig");

/// TLS connection metrics with atomic thread-safe counters.
///
/// **Fields:**
/// - cipher_suite: Negotiated cipher (e.g., "TLS_AES_256_GCM_SHA384")
/// - protocol_version: TLS version (e.g., "TLSv1.3")
/// - certificate_verified: Peer certificate validation status
/// - bytes_encrypted: Plaintext bytes written (encrypted before sending)
/// - bytes_decrypted: Encrypted bytes read (decrypted after receiving)
/// - handshake_duration_ns: TLS handshake time in nanoseconds
/// - connection_start_ns: Connection start timestamp
///
/// **Atomics:**
/// bytes_encrypted and bytes_decrypted use atomic operations.
/// Safe for concurrent read/write operations.
pub const TlsMetrics = struct {
    /// Negotiated cipher suite name
    cipher_suite: [128]u8,
    cipher_suite_len: usize,

    /// TLS protocol version (e.g., "TLSv1.2", "TLSv1.3")
    protocol_version: [16]u8,
    protocol_version_len: usize,

    /// Certificate verification status
    certificate_verified: bool,

    /// Bytes encrypted and sent (atomic counter)
    bytes_encrypted: std.atomic.Value(u64),

    /// Bytes received and decrypted (atomic counter)
    bytes_decrypted: std.atomic.Value(u64),

    /// TLS handshake duration in nanoseconds
    handshake_duration_ns: i128,

    /// Connection start timestamp (nanoseconds since epoch)
    connection_start_ns: i128,

    /// Initialize metrics with default values.
    pub fn init() TlsMetrics {
        return .{
            .cipher_suite = [_]u8{0} ** 128,
            .cipher_suite_len = 0,
            .protocol_version = [_]u8{0} ** 16,
            .protocol_version_len = 0,
            .certificate_verified = false,
            .bytes_encrypted = std.atomic.Value(u64).init(0),
            .bytes_decrypted = std.atomic.Value(u64).init(0),
            .handshake_duration_ns = 0,
            .connection_start_ns = std.time.nanoTimestamp(),
        };
    }

    /// Record successful TLS handshake with negotiated parameters.
    ///
    /// **Parameters:**
    /// - cipher: Cipher suite string (e.g., "ECDHE-RSA-AES256-GCM-SHA384")
    /// - version: Protocol version string (e.g., "TLSv1.3")
    /// - verified: Certificate verification result
    /// - duration_ns: Handshake duration in nanoseconds
    pub fn recordHandshake(
        self: *TlsMetrics,
        cipher: []const u8,
        version: []const u8,
        verified: bool,
        duration_ns: i128,
    ) void {
        // Copy cipher suite (truncate if too long)
        const cipher_len = @min(cipher.len, self.cipher_suite.len);
        @memcpy(self.cipher_suite[0..cipher_len], cipher[0..cipher_len]);
        self.cipher_suite_len = cipher_len;

        // Copy protocol version
        const version_len = @min(version.len, self.protocol_version.len);
        @memcpy(self.protocol_version[0..version_len], version[0..version_len]);
        self.protocol_version_len = version_len;

        self.certificate_verified = verified;
        self.handshake_duration_ns = duration_ns;

        logging.logDebug("TLS handshake complete: {s} with {s} (verified={any}, {d}ms)\n", .{
            version[0..version_len],
            cipher[0..cipher_len],
            verified,
            @divTrunc(duration_ns, 1_000_000),
        });
    }

    /// Record encrypted data write operation.
    ///
    /// **Parameters:**
    /// - bytes: Number of plaintext bytes encrypted and sent
    ///
    /// **Thread Safety:** Atomic increment, safe for concurrent calls.
    pub fn recordWrite(self: *TlsMetrics, bytes: u64) void {
        _ = self.bytes_encrypted.fetchAdd(bytes, .monotonic);
    }

    /// Record encrypted data read operation.
    ///
    /// **Parameters:**
    /// - bytes: Number of encrypted bytes received and decrypted
    ///
    /// **Thread Safety:** Atomic increment, safe for concurrent calls.
    pub fn recordRead(self: *TlsMetrics, bytes: u64) void {
        _ = self.bytes_decrypted.fetchAdd(bytes, .monotonic);
    }

    /// Get current encrypted bytes counter (atomic read).
    pub fn getBytesEncrypted(self: *const TlsMetrics) u64 {
        return self.bytes_encrypted.load(.monotonic);
    }

    /// Get current decrypted bytes counter (atomic read).
    pub fn getBytesDecrypted(self: *const TlsMetrics) u64 {
        return self.bytes_decrypted.load(.monotonic);
    }

    /// Get cipher suite as string slice.
    pub fn getCipherSuite(self: *const TlsMetrics) []const u8 {
        return self.cipher_suite[0..self.cipher_suite_len];
    }

    /// Get protocol version as string slice.
    pub fn getProtocolVersion(self: *const TlsMetrics) []const u8 {
        return self.protocol_version[0..self.protocol_version_len];
    }

    /// Log metrics summary at verbose level.
    ///
    /// **Output:**
    /// - TLS protocol version and cipher suite
    /// - Certificate verification status
    /// - Handshake duration
    /// - Data throughput (encrypted/decrypted bytes)
    /// - Connection duration
    pub fn logSummary(self: *const TlsMetrics) void {
        const cipher = self.getCipherSuite();
        const version = self.getProtocolVersion();
        const encrypted = self.getBytesEncrypted();
        const decrypted = self.getBytesDecrypted();

        logging.logDebug("\nTLS Metrics Summary:\n", .{});
        logging.logDebug("  Protocol: {s}\n", .{version});
        logging.logDebug("  Cipher: {s}\n", .{cipher});
        logging.logDebug("  Certificate Verified: {any}\n", .{self.certificate_verified});
        logging.logDebug("  Handshake Duration: {d}ms\n", .{
            @divTrunc(self.handshake_duration_ns, 1_000_000),
        });
        logging.logDebug("  Bytes Encrypted: {d}\n", .{encrypted});
        logging.logDebug("  Bytes Decrypted: {d}\n", .{decrypted});

        const now = std.time.nanoTimestamp();
        const duration_s = @divTrunc(now - self.connection_start_ns, 1_000_000_000);
        logging.logDebug("  Connection Duration: {d}s\n", .{duration_s});
    }

    /// Log metrics summary with config-based verbosity control.
    ///
    /// **Parameters:**
    /// - cfg: Configuration with verbosity level
    /// - level: Minimum verbosity level to log (verbose, debug, trace)
    ///
    /// **Usage:**
    /// ```zig
    /// metrics.logSummaryWithConfig(&cfg, .verbose); // Log at -v
    /// metrics.logSummaryWithConfig(&cfg, .debug);   // Log at -vv
    /// ```
    pub fn logSummaryWithConfig(
        self: *const TlsMetrics,
        cfg: *const config.Config,
        comptime level: config.VerbosityLevel,
    ) void {
        if (!logging.isVerbosityEnabled(cfg, level)) {
            return;
        }

        const cipher = self.getCipherSuite();
        const version = self.getProtocolVersion();
        const encrypted = self.getBytesEncrypted();
        const decrypted = self.getBytesDecrypted();

        logging.logVerbose(cfg, "\nTLS Metrics:\n", .{});
        logging.logVerbose(cfg, "  Protocol: {s}\n", .{version});
        logging.logVerbose(cfg, "  Cipher: {s}\n", .{cipher});
        logging.logVerbose(cfg, "  Verified: {any}\n", .{self.certificate_verified});
        logging.logVerbose(cfg, "  Handshake: {d}ms\n", .{
            @divTrunc(self.handshake_duration_ns, 1_000_000),
        });
        logging.logVerbose(cfg, "  Sent: {d} bytes\n", .{encrypted});
        logging.logVerbose(cfg, "  Received: {d} bytes\n", .{decrypted});
    }

    /// Export metrics as JSON-compatible structure (for integration).
    ///
    /// **Returns:** Formatted metrics string for logging or monitoring.
    ///
    /// **Note:** Caller does NOT own returned string (uses internal buffer).
    pub fn exportJson(self: *const TlsMetrics, buffer: []u8) ![]const u8 {
        const cipher = self.getCipherSuite();
        const version = self.getProtocolVersion();
        const encrypted = self.getBytesEncrypted();
        const decrypted = self.getBytesDecrypted();
        const handshake_ms = @divTrunc(self.handshake_duration_ns, 1_000_000);

        return std.fmt.bufPrint(buffer,
            \\{{"protocol":"{s}","cipher":"{s}","verified":{any},"handshake_ms":{d},"bytes_encrypted":{d},"bytes_decrypted":{d}}}
        , .{
            version,
            cipher,
            self.certificate_verified,
            handshake_ms,
            encrypted,
            decrypted,
        });
    }
};

// Unit tests
const testing = std.testing;

test "TlsMetrics init" {
    const metrics = TlsMetrics.init();
    try testing.expectEqual(@as(u64, 0), metrics.getBytesEncrypted());
    try testing.expectEqual(@as(u64, 0), metrics.getBytesDecrypted());
    try testing.expectEqual(false, metrics.certificate_verified);
}

test "TlsMetrics recordHandshake" {
    var metrics = TlsMetrics.init();
    metrics.recordHandshake("TLS_AES_256_GCM_SHA384", "TLSv1.3", true, 50_000_000);

    try testing.expectEqualStrings("TLS_AES_256_GCM_SHA384", metrics.getCipherSuite());
    try testing.expectEqualStrings("TLSv1.3", metrics.getProtocolVersion());
    try testing.expectEqual(true, metrics.certificate_verified);
    try testing.expectEqual(@as(i128, 50_000_000), metrics.handshake_duration_ns);
}

test "TlsMetrics recordWrite and recordRead" {
    var metrics = TlsMetrics.init();

    metrics.recordWrite(1024);
    metrics.recordWrite(2048);
    try testing.expectEqual(@as(u64, 3072), metrics.getBytesEncrypted());

    metrics.recordRead(512);
    metrics.recordRead(256);
    try testing.expectEqual(@as(u64, 768), metrics.getBytesDecrypted());
}

test "TlsMetrics concurrent updates" {
    var metrics = TlsMetrics.init();

    // Simulate concurrent writes (single-threaded test, but uses atomic API)
    metrics.recordWrite(100);
    metrics.recordWrite(200);
    metrics.recordRead(150);

    try testing.expectEqual(@as(u64, 300), metrics.getBytesEncrypted());
    try testing.expectEqual(@as(u64, 150), metrics.getBytesDecrypted());
}

test "TlsMetrics exportJson" {
    var metrics = TlsMetrics.init();
    metrics.recordHandshake("ECDHE-RSA-AES256-GCM-SHA384", "TLSv1.2", true, 25_000_000);
    metrics.recordWrite(1024);
    metrics.recordRead(2048);

    var buffer: [512]u8 = undefined;
    const json = try metrics.exportJson(&buffer);

    // Verify JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, json, "TLSv1.2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "ECDHE-RSA-AES256-GCM-SHA384") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"verified\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"bytes_encrypted\":1024") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"bytes_decrypted\":2048") != null);
}
