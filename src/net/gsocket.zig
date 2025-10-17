// gsocket.zig - Global Socket Relay Network (GSRN) protocol implementation
//
// This module implements the client-side GSRN protocol for NAT traversal through
// the Global Socket relay network (gs.thc.org). It provides:
//
// 1. Secret derivation (address and SRP password generation)
// 2. GSRN handshake protocol (Listen/Connect/Start packets)
// 3. Raw TCP tunnel establishment through relay
//
// The GSRN protocol works as follows:
// - Both peers derive a shared GS-Address from a secret
// - Server sends GsListen packet to relay with the address
// - Client sends GsConnect packet to relay with same address
// - Relay matches the addresses and sends GsStart to both peers
// - A raw TCP tunnel is established through the relay
// - SRP encryption is then layered on top (see tls/srp_openssl.zig)

const std = @import("std");
const config = @import("../config.zig");
const tcp = @import("tcp.zig");
const logging = @import("../util/logging.zig");
const posix = std.posix;

// ============================================================================
// Protocol Constants
// ============================================================================

/// Default GSRN relay server hostname
pub const GSRN_DEFAULT_HOST = "gs.thc.org";

/// Default GSRN relay server port (HTTPS)
pub const GSRN_DEFAULT_PORT = 443;

/// Protocol version (major)
pub const GS_PKT_PROTO_VERSION_MAJOR: u8 = 1;

/// Protocol version (minor)
pub const GS_PKT_PROTO_VERSION_MINOR: u8 = 3;

// Protocol packet types
pub const GS_PKT_TYPE_LISTEN: u8 = 0x01;
pub const GS_PKT_TYPE_CONNECT: u8 = 0x02;
pub const GS_PKT_TYPE_PING: u8 = 0x03;
pub const GS_PKT_TYPE_PONG: u8 = 0x04;
pub const GS_PKT_TYPE_START: u8 = 0x05;
pub const GS_PKT_TYPE_STATUS: u8 = 0x06;
pub const GS_PKT_TYPE_ACCEPT: u8 = 0x07;

// Protocol flags (used in Listen/Connect packets)
pub const GS_FL_PROTO_WAIT: u8 = 0x01; // Wait for server availability
pub const GS_FL_PROTO_CLIENT_OR_SERVER: u8 = 0x02; // First connector acts as server
pub const GS_FL_PROTO_FAST_CONNECT: u8 = 0x04; // Skip GSRN start message
pub const GS_FL_PROTO_LOW_LATENCY: u8 = 0x08; // Interactive shell/low latency mode
pub const GS_FL_PROTO_SERVER_CHECK: u8 = 0x10; // Verify listening status

// Start message flags (in GsStart.flags)
pub const GS_FL_PROTO_START_SERVER: u8 = 0x01; // Act as SSL server
pub const GS_FL_PROTO_START_CLIENT: u8 = 0x02; // Act as SSL client

// Key derivation constants (from gsocket-util.c)
const KD_ADDR_CONSTANT = "/kd/addr/2";
const KD_SRP_CONSTANT = "/kd/srp/1";

// ============================================================================
// Protocol Data Structures
// ============================================================================

/// GS-Address: 128-bit identifier derived from secret
pub const GsAddress = [16]u8;

/// SRP Password: 32 hex characters + null terminator
pub const SrpPassword = [33]u8;

/// GsListen packet: Sent by server to register on GSRN relay
/// Total size: 128 bytes (matches C struct layout)
pub const GsListen = extern struct {
    type: u8 = GS_PKT_TYPE_LISTEN,
    version_major: u8 = GS_PKT_PROTO_VERSION_MAJOR,
    version_minor: u8 = GS_PKT_PROTO_VERSION_MINOR,
    flags: u8 = GS_FL_PROTO_LOW_LATENCY,
    reserved1: [28]u8 = [_]u8{0} ** 28,
    addr: [16]u8,
    token: [16]u8 = [_]u8{0} ** 16, // Optional authentication token
    reserved2: [64]u8 = [_]u8{0} ** 64,

    comptime {
        if (@sizeOf(GsListen) != 128) {
            @compileError("GsListen must be exactly 128 bytes");
        }
    }
};

/// GsConnect packet: Sent by client to connect to listening peer
/// Total size: 128 bytes (matches C struct layout)
pub const GsConnect = extern struct {
    type: u8 = GS_PKT_TYPE_CONNECT,
    version_major: u8 = GS_PKT_PROTO_VERSION_MAJOR,
    version_minor: u8 = GS_PKT_PROTO_VERSION_MINOR,
    flags: u8 = GS_FL_PROTO_LOW_LATENCY,
    reserved1: [28]u8 = [_]u8{0} ** 28,
    addr: [16]u8,
    token: [16]u8 = [_]u8{0} ** 16,
    reserved2: [64]u8 = [_]u8{0} ** 64,

    comptime {
        if (@sizeOf(GsConnect) != 128) {
            @compileError("GsConnect must be exactly 128 bytes");
        }
    }
};

/// GsStart packet: Response from GSRN when peers are matched
/// Total size: 32 bytes
pub const GsStart = extern struct {
    type: u8,
    flags: u8,
    reserved: [30]u8,

    comptime {
        if (@sizeOf(GsStart) != 32) {
            @compileError("GsStart must be exactly 32 bytes");
        }
    }
};

// ============================================================================
// Secret Derivation Functions
// ============================================================================

/// Derives a 128-bit GS-Address from a secret using SHA256
///
/// Algorithm: SHA256("/kd/addr/2" || secret)[0..16]
///
/// The GS-Address is used to match peers on the GSRN relay. Both client and
/// server must derive the exact same address from the shared secret.
///
/// Args:
///     secret: Shared secret string
///
/// Returns:
///     16-byte GS-Address
pub fn deriveAddress(secret: []const u8) GsAddress {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(KD_ADDR_CONSTANT);
    sha.update(secret);
    var hash: [32]u8 = undefined;
    sha.final(&hash);
    return hash[0..16].*;
}

/// Derives an SRP password from a secret using SHA256
///
/// Algorithm: hex(SHA256("/kd/srp/1" || secret)[0..16]) + null terminator
///
/// The SRP password is used for the end-to-end encryption handshake after
/// the GSRN tunnel is established.
///
/// Args:
///     secret: Shared secret string
///
/// Returns:
///     33-byte array: 32 hex characters + null terminator
pub fn deriveSrpPassword(secret: []const u8) SrpPassword {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(KD_SRP_CONSTANT);
    sha.update(secret);
    var hash: [32]u8 = undefined;
    sha.final(&hash);

    var password: SrpPassword = undefined;

    // Convert first 16 bytes to lowercase hex (32 characters)
    const hex_chars = "0123456789abcdef";
    for (hash[0..16], 0..) |byte, i| {
        password[i * 2] = hex_chars[byte >> 4];
        password[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    // Null-terminate for C compatibility
    password[32] = 0;

    return password;
}

// ============================================================================
// GSRN Handshake
// ============================================================================

/// Establishes a raw TCP tunnel through the GSRN relay network
///
/// This function performs the GSRN handshake protocol:
/// 1. Connects to the GSRN relay server (gs.thc.org:443)
/// 2. Derives GS-Address from the secret
/// 3. Sends GsListen (server mode) or GsConnect (client mode) packet
/// 4. Waits for GsStart response from relay
/// 5. Returns the raw TCP stream (tunnel to peer)
///
/// After this function returns, the caller should perform an SRP handshake
/// to establish end-to-end encryption.
///
/// Args:
///     allocator: Memory allocator
///     cfg: Configuration containing gsocket_secret and listen_mode
///
/// Returns:
///     std.net.Stream: Raw TCP tunnel through GSRN relay
///
/// Errors:
///     - MissingSecret: cfg.gsocket_secret is null
///     - ConnectionError: Failed to connect to GSRN relay
///     - InvalidGsStartPacket: Received invalid response from relay
pub fn establishGsrnTunnel(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) !std.net.Stream {
    _ = allocator; // Reserved for future use

    const gsrn_host = GSRN_DEFAULT_HOST;
    const gsrn_port = GSRN_DEFAULT_PORT;

    logging.logNormal(cfg, "Connecting to GSRN relay at {s}:{d}...\n", .{ gsrn_host, gsrn_port });

    // Establish TCP connection to GSRN relay
    const socket = try tcp.openTcpClient(gsrn_host, gsrn_port, cfg.connect_timeout, cfg);
    const stream = std.net.Stream{ .handle = socket };

    // Derive GS-Address from secret
    const secret = cfg.gsocket_secret orelse return error.MissingSecret;
    const gs_addr = deriveAddress(secret);

    // Log the derived address in verbose mode
    if (cfg.verbose) {
        logging.logVerbose(cfg, "Derived GS-Address: ", .{});
        for (gs_addr) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // Send appropriate packet based on mode
    if (cfg.listen_mode) {
        const listen_pkt = GsListen{ .addr = gs_addr };
        const pkt_bytes = std.mem.asBytes(&listen_pkt);
        try stream.writeAll(pkt_bytes);
        logging.logVerbose(cfg, "Sent GsListen packet, waiting for peer...\n", .{});
    } else {
        const connect_pkt = GsConnect{ .addr = gs_addr };
        const pkt_bytes = std.mem.asBytes(&connect_pkt);
        try stream.writeAll(pkt_bytes);
        logging.logVerbose(cfg, "Sent GsConnect packet, waiting for peer...\n", .{});
    }

    // Wait for GsStart packet from relay
    var start_pkt_bytes: [32]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < 32) {
        const bytes_read = try stream.read(start_pkt_bytes[total_read..]);
        if (bytes_read == 0) {
            logging.logError(error.InvalidGsStartPacket, "Connection closed before receiving complete GsStart packet");
            return error.InvalidGsStartPacket;
        }
        total_read += bytes_read;
    }

    // Parse GsStart packet
    const start_pkt = @as(*const GsStart, @ptrCast(@alignCast(&start_pkt_bytes)));

    if (start_pkt.type != GS_PKT_TYPE_START) {
        logging.logError(error.InvalidGsStartPacket, "Received invalid packet type from GSRN");
        return error.InvalidGsStartPacket;
    }

    // Log connection establishment
    const role = if (start_pkt.flags & GS_FL_PROTO_START_SERVER != 0)
        "server"
    else if (start_pkt.flags & GS_FL_PROTO_START_CLIENT != 0)
        "client"
    else
        "unknown";

    logging.logNormal(cfg, "GSRN tunnel established (role: {s})\n", .{role});
    logging.logVerbose(cfg, "GsStart flags: 0x{x:0>2}\n", .{start_pkt.flags});

    // Return the raw TCP stream (tunnel is now established)
    return stream;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "gsocket packet structure sizes" {
    try std.testing.expectEqual(128, @sizeOf(GsListen));
    try std.testing.expectEqual(128, @sizeOf(GsConnect));
    try std.testing.expectEqual(32, @sizeOf(GsStart));
}

test "gsocket secret derivation - known values" {
    // Test with a simple secret to verify derivation algorithm
    const secret = "test";

    const addr = deriveAddress(secret);
    const pass = deriveSrpPassword(secret);

    // Verify address is deterministic (same secret = same address)
    const addr2 = deriveAddress(secret);
    try std.testing.expectEqualSlices(u8, &addr, &addr2);

    // Verify password is deterministic
    const pass2 = deriveSrpPassword(secret);
    try std.testing.expectEqualSlices(u8, &pass, &pass2);

    // Verify password is null-terminated
    try std.testing.expectEqual(@as(u8, 0), pass[32]);

    // Verify password is hex characters
    for (pass[0..32]) |byte| {
        try std.testing.expect(
            (byte >= '0' and byte <= '9') or
                (byte >= 'a' and byte <= 'f'),
        );
    }
}

test "gsocket secret derivation - different secrets produce different results" {
    const secret1 = "secret1";
    const secret2 = "secret2";

    const addr1 = deriveAddress(secret1);
    const addr2 = deriveAddress(secret2);

    const pass1 = deriveSrpPassword(secret1);
    const pass2 = deriveSrpPassword(secret2);

    // Different secrets should produce different addresses
    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));

    // Different secrets should produce different passwords
    try std.testing.expect(!std.mem.eql(u8, &pass1, &pass2));
}

test "gsocket packet initialization" {
    const test_addr: GsAddress = [_]u8{0x01} ++ [_]u8{0} ** 15;

    const listen_pkt = GsListen{ .addr = test_addr };
    try std.testing.expectEqual(GS_PKT_TYPE_LISTEN, listen_pkt.type);
    try std.testing.expectEqual(GS_PKT_PROTO_VERSION_MAJOR, listen_pkt.version_major);
    try std.testing.expectEqual(GS_PKT_PROTO_VERSION_MINOR, listen_pkt.version_minor);
    try std.testing.expectEqual(GS_FL_PROTO_LOW_LATENCY, listen_pkt.flags);
    try std.testing.expectEqualSlices(u8, &test_addr, &listen_pkt.addr);

    const connect_pkt = GsConnect{ .addr = test_addr };
    try std.testing.expectEqual(GS_PKT_TYPE_CONNECT, connect_pkt.type);
    try std.testing.expectEqual(GS_PKT_PROTO_VERSION_MAJOR, connect_pkt.version_major);
    try std.testing.expectEqual(GS_PKT_PROTO_VERSION_MINOR, connect_pkt.version_minor);
    try std.testing.expectEqual(GS_FL_PROTO_LOW_LATENCY, connect_pkt.flags);
    try std.testing.expectEqualSlices(u8, &test_addr, &connect_pkt.addr);
}

test "gsocket reference test vectors" {
    // This test validates secret derivation against known reference values
    // These values were computed using the same SHA256 algorithm as the original gsocket
    //
    // Algorithm verification:
    // - GS-Address: SHA256("/kd/addr/2" || secret)[0..16]
    // - SRP Password: hex(SHA256("/kd/srp/1" || secret)[0..16]) + null terminator

    const test_cases = [_]struct {
        secret: []const u8,
        expected_addr: [16]u8,
        expected_pass: [33]u8,
    }{
        // Test case 1: Simple secret "test"
        .{
            .secret = "test",
            // Expected: SHA256("/kd/addr/2test")[0..16]
            .expected_addr = [16]u8{
                0x59, 0x2e, 0x19, 0x98, 0x90, 0xcc, 0x7c, 0xb0,
                0x3c, 0x94, 0x4a, 0x1a, 0x78, 0x8c, 0xa0, 0x03,
            },
            // Expected: hex(SHA256("/kd/srp/1test")[0..16]) = "1bd96344e2452e50230..."
            .expected_pass = [33]u8{
                '1', 'b', 'd', '9', '6', '3', '4', '4',
                'e', '2', '4', '5', '2', 'e', '5', '0',
                '2', '3', '0', '3', '4', 'f', '2', 'd',
                '4', '9', '4', '3', '3', '1', '5', '9',
                0,
            },
        },
        // Test case 2: Secret "MySecret"
        .{
            .secret = "MySecret",
            // Expected: SHA256("/kd/addr/2MySecret")[0..16]
            .expected_addr = [16]u8{
                0xfd, 0x91, 0xe8, 0x7d, 0xc6, 0x26, 0x11, 0xf3,
                0x65, 0x9f, 0xbe, 0xee, 0x1a, 0xd1, 0xee, 0xc5,
            },
            // Expected: hex(SHA256("/kd/srp/1MySecret")[0..16]) = "e982b6cf1aea88bb7c2..."
            .expected_pass = [33]u8{
                'e', '9', '8', '2', 'b', '6', 'c', 'f',
                '1', 'a', 'e', 'a', '8', '8', 'b', 'b',
                '7', 'c', '2', '5', '0', '2', '7', 'd',
                'd', 'b', '5', 'a', 'f', '8', '3', '8',
                0,
            },
        },
    };

    for (test_cases) |tc| {
        const addr = deriveAddress(tc.secret);
        const pass = deriveSrpPassword(tc.secret);

        // Validate address derivation
        try std.testing.expectEqualSlices(u8, &tc.expected_addr, &addr);

        // Validate password derivation
        try std.testing.expectEqualSlices(u8, &tc.expected_pass, &pass);

        // Validate password is null-terminated
        try std.testing.expectEqual(@as(u8, 0), pass[32]);

        // Validate password is lowercase hex
        for (pass[0..32]) |byte| {
            try std.testing.expect(
                (byte >= '0' and byte <= '9') or
                    (byte >= 'a' and byte <= 'f'),
            );
        }
    }
}
