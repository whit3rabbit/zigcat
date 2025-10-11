# DTLS Module

Datagram Transport Layer Security (DTLS) implementation for ZigCat, providing encrypted UDP connections.

## Overview

DTLS is a protocol that provides TLS-like security for datagram protocols (UDP). It prevents:
- **Eavesdropping**: All data is encrypted
- **Tampering**: Cryptographic integrity checks detect modifications
- **Replay attacks**: Sequence numbers prevent packet replay
- **DoS attacks**: Stateless cookie exchange protects servers

## Architecture

```
Client Mode:
  UDP socket → DTLS handshake → Encrypted datagrams

Server Mode:
  UDP socket → Cookie exchange → Per-client DTLS sessions
```

### Key Differences from TLS

| Feature | TLS (TCP) | DTLS (UDP) |
|---------|-----------|------------|
| Transport | Stream (TCP) | Datagrams (UDP) |
| Handshake | Reliable (TCP retransmit) | Explicit retransmission |
| Message boundaries | Byte stream | Preserved per datagram |
| Reordering | Impossible (TCP seq) | Possible, handled by DTLS |
| DoS protection | SYN cookies (kernel) | Application cookies (DTLS) |

## Module Structure

```
src/tls/dtls/
├── dtls.zig              # Public API (connectDtls, acceptDtls)
├── dtls_iface.zig        # Connection interface and types
├── dtls_openssl.zig      # OpenSSL DTLS implementation
├── dtls_cookie.zig       # Cookie generation/verification
└── README.md             # This file
```

## Usage Examples

### Client Mode

```zig
const std = @import("std");
const dtls = @import("tls/dtls/dtls.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure DTLS client
    const config = dtls.DtlsConfig{
        .verify_peer = true,
        .server_name = "example.com",
        .mtu = 1200,
    };

    // Connect to DTLS server
    const conn = try dtls.connectDtls(allocator, "example.com", 4433, config);
    defer conn.deinit();

    // Send encrypted datagram
    const message = "Hello DTLS!";
    _ = try conn.write(message);

    // Receive encrypted datagram
    var buffer: [2048]u8 = undefined;
    const n = try conn.read(&buffer);
    std.debug.print("Received: {s}\n", .{buffer[0..n]});
}
```

### Server Mode

```zig
const std = @import("std");
const dtls = @import("tls/dtls/dtls.zig");
const posix = std.posix;
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(sock);

    const bind_addr = try net.Address.parseIp4("0.0.0.0", 4433);
    try posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

    // Configure DTLS server
    const config = dtls.DtlsConfig{
        .cert_file = "server.pem",
        .key_file = "key.pem",
        .mtu = 1200,
    };

    // Wait for client connection (simplified - production needs session manager)
    var buffer: [2048]u8 = undefined;
    var client_addr: posix.sockaddr = undefined;
    var client_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    _ = try posix.recvfrom(sock, &buffer, 0, &client_addr, &client_len);
    const client_net_addr = net.Address.initPosix(@alignCast(&client_addr));

    // Accept DTLS connection (performs cookie exchange and handshake)
    const conn = try dtls.acceptDtls(allocator, sock, client_net_addr, config);
    defer conn.deinit();

    // Echo loop
    while (true) {
        const n = try conn.read(&buffer);
        if (n == 0) break; // Connection closed

        _ = try conn.write(buffer[0..n]);
    }
}
```

## Configuration Options

### DtlsConfig Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cert_file` | `?[]const u8` | `null` | Server certificate (PEM) |
| `key_file` | `?[]const u8` | `null` | Private key (PEM) |
| `verify_peer` | `bool` | `true` | Verify peer certificate |
| `trust_file` | `?[]const u8` | `null` | CA bundle path |
| `server_name` | `?[]const u8` | `null` | Expected hostname (SNI) |
| `mtu` | `u16` | `1200` | Path MTU (bytes) |
| `initial_timeout_ms` | `u32` | `1000` | Handshake retransmission timeout |
| `replay_window` | `u32` | `64` | Anti-replay window size |
| `min_version` | `DtlsVersion` | `.dtls_1_2` | Minimum protocol version |
| `max_version` | `DtlsVersion` | `.dtls_1_2` | Maximum protocol version |

### MTU Selection Guidelines

| Network | Recommended MTU | Notes |
|---------|-----------------|-------|
| Internet | 1200 bytes | Conservative, avoids most fragmentation |
| LAN | 1400 bytes | Safe for most Ethernet networks |
| VPN | 1000 bytes | Accounts for tunnel overhead |
| Mobile | 1280 bytes | IPv6 minimum, works on most cellular |

## Security Considerations

### Cookie Exchange (Server DoS Protection)

DTLS servers use stateless cookies to prevent DoS attacks:

1. Client sends `ClientHello`
2. Server responds with `HelloVerifyRequest` containing cookie
3. Client resends `ClientHello` with cookie
4. Server verifies cookie and completes handshake

**Cookie generation**: HMAC-SHA256(server_secret, client_ip || client_port)

### Replay Attack Prevention

DTLS maintains a sliding window of received sequence numbers. Packets outside the window or duplicates are rejected.

**Window size**: Configurable (default 64 packets)

### Cipher Suites

Only AEAD cipher suites are allowed (no CBC mode):
- `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`
- `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`
- `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`
- `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384`

## Performance Characteristics

### Handshake Latency

| Scenario | RTT | Handshake Time |
|----------|-----|----------------|
| LAN | 1ms | 3-4ms (2 RTTs) |
| Internet | 50ms | 100-150ms (2-3 RTTs) |
| Packet loss (10%) | 50ms | 150-300ms (retransmissions) |

### Throughput

DTLS adds ~40-60 bytes overhead per datagram:
- 13 bytes: DTLS record header
- 8 bytes: Explicit nonce (GCM)
- 16 bytes: Authentication tag (GCM)
- Variable: Padding (block cipher only, not used with AEAD)

**Effective MTU**: `configured_mtu - 60 bytes`

### CPU Overhead

- Encryption/decryption: ~2-5% CPU per 100 Mbps
- Handshake: ~0.5-1ms CPU time per connection

## Troubleshooting

### Common Issues

**Issue**: Handshake timeout
**Cause**: Firewall blocking UDP, MTU too large causing fragmentation
**Fix**: Check firewall rules, reduce MTU to 1000 bytes

**Issue**: Connection drops after idle period
**Cause**: NAT/firewall timeout
**Fix**: Implement application-level keepalives

**Issue**: "DTLS not available" error
**Cause**: OpenSSL not linked or version < 1.0.2
**Fix**: Ensure OpenSSL 1.0.2+ is installed and linked

**Issue**: High packet loss
**Cause**: Network congestion, incorrect MTU
**Fix**: Use `--dtls-mtu 1000`, check network conditions

### Debugging

Enable verbose logging:
```bash
zigcat -v --ssl -u example.com 4433
```

Check DTLS statistics:
```zig
const stats = conn.getStats();
std.debug.print("Retransmissions: {}\n", .{stats.retransmissions});
```

## References

- [RFC 6347 - DTLS 1.2](https://datatracker.ietf.org/doc/html/rfc6347)
- [RFC 9147 - DTLS 1.3](https://datatracker.ietf.org/doc/html/rfc9147)
- [OpenSSL DTLS Guide](https://wiki.openssl.org/index.php/Datagram_Transport_Layer_Security)
- [DTLS Best Practices](https://datatracker.ietf.org/doc/html/rfc7525)

## License

Same as ZigCat project (see root LICENSE file).
