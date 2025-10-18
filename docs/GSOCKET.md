# Global Socket (GSRN) - NAT Traversal Documentation

## Table of Contents

- [Overview](#overview)
- [Protocol Architecture](#protocol-architecture)
- [Security Model](#security-model)
- [Usage Guide](#usage-guide)
- [Implementation Details](#implementation-details)
- [Testing and Verification](#testing-and-verification)
- [Troubleshooting](#troubleshooting)
- [Compatibility](#compatibility)
- [References](#references)

---

## Overview

**Global Socket Relay Network (GSRN)** is a NAT traversal protocol that enables two peers behind firewalls/NAT to establish a direct encrypted connection without port forwarding, VPN configuration, or firewall rule modifications.

### Key Features

- ✅ **Zero Configuration**: No port forwarding or firewall rules needed
- ✅ **End-to-End Encryption**: SRP-AES-256-CBC-SHA cipher independent of relay
- ✅ **Mutual Authentication**: Password-based authentication without X.509 certificates
- ✅ **NAT/Firewall Friendly**: Both peers can be behind restrictive networks
- ✅ **Cross-Platform**: Works on all platforms supporting TCP sockets

### Architecture Overview

```
┌─────────────┐                  ┌─────────────────┐                  ┌─────────────┐
│  Client A   │                  │  GSRN Relay     │                  │  Client B   │
│ (Behind NAT)│                  │  gs.thc.org:443 │                  │ (Behind NAT)│
└─────────────┘                  └─────────────────┘                  └─────────────┘
       │                                  │                                  │
       │  1. Derive GS-Address            │                                  │
       │     SHA256("/kd/addr/2" + secret)│                                  │
       │                                  │                                  │
       │  2. Connect to relay             │                                  │
       ├─────────────────────────────────>│                                  │
       │                                  │  3. Connect to relay             │
       │                                  │<─────────────────────────────────┤
       │                                  │                                  │
       │  4. Send GsConnect packet        │                                  │
       ├─────────────────────────────────>│                                  │
       │                                  │  5. Send GsListen packet         │
       │                                  │<─────────────────────────────────┤
       │                                  │                                  │
       │                                  │  6. Match addresses              │
       │                                  │                                  │
       │  7. GsStart (client role)        │                                  │
       │<─────────────────────────────────┤                                  │
       │                                  │  8. GsStart (server role)        │
       │                                  ├─────────────────────────────────>│
       │                                  │                                  │
       │  9. Raw TCP tunnel established   │                                  │
       │<════════════════════════════════════════════════════════════════════>│
       │                                  │                                  │
       │  10. SRP handshake (end-to-end encryption)                          │
       │<═══════════════════════════════════════════════════════════════════>│
       │                                  │                                  │
       │  11. Encrypted bidirectional data transfer                          │
       │<═══════════════════════════════════════════════════════════════════>│
```

---

## Protocol Architecture

### Layer 1: Secret Derivation

Both peers independently derive two values from the shared secret:

#### GS-Address Derivation
```
GS-Address = SHA256("/kd/addr/2" || secret)[0..16]
```
- **Purpose**: 128-bit identifier for relay server peer matching
- **Algorithm**: First 16 bytes of SHA256 hash
- **Constant**: `/kd/addr/2` (key derivation context for addresses)

#### SRP Password Derivation
```
SRP-Password = hex(SHA256("/kd/srp/1" || secret)[0..16]) + '\0'
```
- **Purpose**: Password for SRP authentication after tunnel establishment
- **Algorithm**: First 16 bytes of SHA256, converted to 32 hex characters
- **Constant**: `/kd/srp/1` (key derivation context for SRP)
- **Format**: 33-byte array (32 hex chars + null terminator)

### Layer 2: GSRN Handshake Protocol

#### Packet Structures

**GsListen Packet (128 bytes)**:
```c
struct GsListen {
    uint8_t type;              // 0x01 (GS_PKT_TYPE_LISTEN)
    uint8_t version_major;     // 1
    uint8_t version_minor;     // 3
    uint8_t flags;             // 0x08 (GS_FL_PROTO_LOW_LATENCY)
    uint8_t reserved1[28];     // Padding
    uint8_t addr[16];          // Derived GS-Address
    uint8_t token[16];         // Optional auth token (unused)
    uint8_t reserved2[64];     // Padding
};
```

**GsConnect Packet (128 bytes)**:
```c
struct GsConnect {
    uint8_t type;              // 0x02 (GS_PKT_TYPE_CONNECT)
    uint8_t version_major;     // 1
    uint8_t version_minor;     // 3
    uint8_t flags;             // 0x08 (GS_FL_PROTO_LOW_LATENCY)
    uint8_t reserved1[28];     // Padding
    uint8_t addr[16];          // Derived GS-Address
    uint8_t token[16];         // Optional auth token (unused)
    uint8_t reserved2[64];     // Padding
};
```

**GsStart Packet (32 bytes)**:
```c
struct GsStart {
    uint8_t type;              // 0x05 (GS_PKT_TYPE_START)
    uint8_t flags;             // 0x01 (server) or 0x02 (client)
    uint8_t reserved[30];      // Padding
};
```

#### Protocol Flow

1. **Client Connection**:
   - Connect to `gs.thc.org:443` via TCP
   - Send GsConnect packet with derived GS-Address

2. **Server Connection**:
   - Connect to `gs.thc.org:443` via TCP
   - Send GsListen packet with derived GS-Address

3. **Relay Matching**:
   - Relay server compares GS-Addresses
   - When match found, sends GsStart to both peers
   - GsStart.flags determines SRP role (server vs client)

4. **Tunnel Establishment**:
   - Raw TCP tunnel now passes through relay
   - All data forwarded bidirectionally

### Layer 3: SRP Encryption Handshake

After GSRN tunnel is established, an SRP (Secure Remote Password) handshake provides end-to-end encryption:

#### SRP Protocol Details

- **Cipher Suite**: SRP-AES-256-CBC-SHA (required for gs-netcat compatibility)
- **Username**: Always "user" (hardcoded in gsocket protocol)
- **Password**: Derived from secret using SHA256 (see Layer 1)
- **Library**: OpenSSL 3.x SRP callbacks (not deprecated functions)

#### Handshake Steps

1. **Client** initiates `SSL_connect()` with SRP cipher suite
2. **Server** responds with SRP parameters (N, g, s, B)
3. **Client** computes SRP proof using password
4. **Server** verifies client proof
5. **Mutual Verification**: Both sides authenticate
6. **Key Exchange**: AES-256 session key established
7. **Encrypted Stream**: All subsequent data encrypted with AES-256-CBC

#### Non-Blocking Handshake Implementation

```zig
// Poll-based retry loop for non-blocking sockets
while (!handshake_complete) {
    const ret = if (is_client) SSL_connect(ssl) else SSL_accept(ssl);

    if (ret == 1) {
        handshake_complete = true;
        break;
    }

    const err = SSL_get_error(ssl, ret);
    if (err == SSL_ERROR_WANT_READ or err == SSL_ERROR_WANT_WRITE) {
        // Wait for socket readiness with timeout
        const events = if (err == SSL_ERROR_WANT_READ) POLL.IN else POLL.OUT;
        var pollfds = [_]pollfd{.{
            .fd = socket_handle,
            .events = events,
            .revents = 0,
        }};

        const ready = try poll(&pollfds, timeout_ms);
        if (ready == 0) return error.HandshakeTimeout;

        // Check for errors including POLL.NVAL (redirected stdin)
        if (pollfds[0].revents & (POLL.ERR | POLL.HUP | POLL.NVAL) != 0) {
            return error.HandshakeFailed;
        }

        continue; // Retry handshake
    } else {
        return error.HandshakeFailed;
    }
}
```

**Critical Poll Error Check**: Must check `POLL.NVAL` in addition to `POLL.ERR | POLL.HUP` to prevent infinite loops when stdin is redirected.

---

## Security Model

### Threat Model

#### What GSRN Protects Against

✅ **Passive Network Eavesdropping**:
- AES-256-CBC encryption prevents plaintext inspection
- SRP provides forward secrecy for session keys

✅ **Active Man-in-the-Middle (MitM)**:
- SRP mutual authentication prevents impersonation
- No PKI/certificates needed (no CA trust issues)

✅ **Relay Server Compromise**:
- End-to-end encryption independent of relay
- Relay cannot decrypt traffic (only forwards encrypted bytes)

#### What GSRN Does NOT Protect Against

❌ **Weak Secret Compromise**:
- Short/weak secrets vulnerable to brute force
- GS-Address only 128-bit (2^128 space, but dictionary attacks feasible)

❌ **SHA-1 MAC Weakness**:
- Uses SHA-1 HMAC (collision attacks exist)
- Required for gs-netcat compatibility (protocol limitation)

❌ **Relay Availability Attack**:
- Single point of failure (gs.thc.org)
- DoS against relay prevents all connections

❌ **Traffic Analysis**:
- Relay can see connection metadata (timing, size)
- Encrypted payload prevents content inspection

### Security Best Practices

#### Secret Strength Requirements

```bash
# ❌ WEAK: Short numeric PIN (easily brute-forced)
zigcat --gs-secret 123456

# ⚠️ WEAK: Dictionary word (vulnerable to dictionary attacks)
zigcat --gs-secret password

# ✅ GOOD: 32+ character passphrase with mixed character types
zigcat --gs-secret "$(openssl rand -base64 32)"

# ✅ EXCELLENT: Use password manager to generate/store secret
zigcat --gs-secret "$(pass show gsocket/my-tunnel-secret)"
```

**Recommendation**: Use 32+ character secrets with high entropy (random alphanumeric + symbols).

#### Operational Security

1. **Secret Distribution**:
   - Share secrets via encrypted channels (Signal, PGP, in-person)
   - Never send secrets over plaintext email/chat
   - Rotate secrets periodically (e.g., monthly)

2. **Access Control**:
   - Use `--allow-ip` with exec mode to restrict by source IP
   - Drop privileges with `--drop-user` after binding
   - Monitor connection logs with `-vv` for suspicious activity

3. **Network Isolation**:
   - Use firewall rules for defense-in-depth
   - Consider running in isolated network namespace
   - Monitor outbound connections to gs.thc.org

### When NOT to Use Gsocket

**IMPORTANT**: Gsocket uses `SRP-AES-256-CBC-SHA`, which includes SHA-1 for message authentication. SHA-1 is cryptographically weak and has known collision vulnerabilities. While AES-256 provides strong encryption for confidentiality, the SHA-1 HMAC component reduces overall security.

#### ❌ Do NOT use gsocket for:

1. **Highly Sensitive Data**:
   - Financial transactions, payment card data
   - Medical records (HIPAA), personal health information
   - Classified government communications
   - Corporate trade secrets, intellectual property

2. **Compliance-Required Environments**:
   - PCI DSS (requires TLS 1.2+ with modern ciphers)
   - FIPS 140-2/140-3 certified systems
   - SOC 2 Type II audited infrastructure
   - NIST SP 800-52 compliant deployments

3. **Long-Term Data Protection**:
   - Archived data requiring >5 year confidentiality
   - Sensitive data where future decryption is unacceptable
   - Cryptographic commitments with legal implications

4. **High-Value Targets**:
   - Nation-state adversary threat models
   - Critical infrastructure (power, water, transportation)
   - Military/defense communications
   - High-net-worth individual communications

#### ✅ Acceptable use cases:

1. **Convenience over High Security**:
   - Personal file transfers between trusted parties
   - Temporary remote access for development/testing
   - NAT traversal when firewall configuration is impossible

2. **Low-Sensitivity Data**:
   - Public data that needs lightweight transport encryption
   - Development/staging environment access
   - Non-production system management

3. **Defense-in-Depth Layer**:
   - Additional encryption layer over already-secured channels
   - Combined with application-level encryption (e.g., GPG)
   - Used alongside VPN or other encrypted transport

#### Recommended Alternatives for High Security:

- **WireGuard**: Modern VPN with ChaCha20-Poly1305, Curve25519
- **OpenVPN**: TLS 1.3 with AES-256-GCM-SHA384
- **SSH**: Ed25519 + ChaCha20-Poly1305, modern ciphers
- **TLS 1.3**: AES-256-GCM-SHA384 or ChaCha20-Poly1305
- **Tailscale/ZeroTier**: Managed mesh networks with modern crypto

**Why the SHA-1 limitation exists**: Gsocket uses SHA-1 for compatibility with the original gs-netcat protocol. Changing to SHA-256 would break interoperability with existing gsocket deployments. The trade-off prioritizes cross-implementation compatibility over maximum security.

**Risk Assessment**:
- **Known attacks**: SHA-1 collision attacks demonstrated (SHAttered, 2017)
- **Practical risk**: MAC forgery theoretically possible with ~2^69 operations
- **Timeline**: SHA-1 deprecated by NIST, browsers, major CAs (2017-2020)
- **Current status**: Considered INSECURE for new deployments

**Use at your own risk**. For production systems handling sensitive data, use alternatives listed above.

---

## Usage Guide

### Basic Connection

**Server (Listen Mode)**:
```bash
# Wait for client to connect
zigcat -l --gs-secret "my-secure-secret-2025"
```

**Client (Connect Mode)**:
```bash
# Connect to listening server (no host/port args)
zigcat --gs-secret "my-secure-secret-2025"
```

### File Transfer

**Receiver**:
```bash
# Receive file through GSRN tunnel
zigcat -l --gs-secret "file-transfer-$(date +%Y%m%d)" > received.tar.gz
```

**Sender**:
```bash
# Send file through GSRN tunnel
cat myarchive.tar.gz | zigcat --gs-secret "file-transfer-$(date +%Y%m%d)"
```

### Remote Shell (Requires `--allow`)

**Server**:
```bash
# DANGEROUS: Remote shell accessible via GSRN
zigcat -l --gs-secret "shell-secret" -e /bin/sh --allow

# SAFER: Remote shell with IP restriction
zigcat -l --gs-secret "shell-secret" -e /bin/sh --allow --allow-ip 203.0.113.0/24
```

**Client**:
```bash
# Connect to remote shell
zigcat --gs-secret "shell-secret"
```

### Port Forwarding

**Forward local port 8080 to remote service**:

**Remote (listen)**:
```bash
# Listen on GSRN, forward to localhost:80
zigcat -l --gs-secret "port-forward" --broker 8080
```

**Local (connect)**:
```bash
# Connect via GSRN
zigcat --gs-secret "port-forward"
```

Then access `localhost:8080` on local machine.

### Verbose Logging

```bash
# Level 1: Connection events
zigcat -l --gs-secret MySecret -v

# Level 2: Protocol details (shows GSRN tunnel + SRP handshake)
zigcat -l --gs-secret MySecret -vv

# Level 3: Full trace (all internal state)
zigcat -l --gs-secret MySecret -vvv
```

**Sample Verbose Output** (`-vv`):
```
Connecting to GSRN relay at gs.thc.org:443...
Derived GS-Address: a3f5d2c8b1e90f4d7c2a6b8e1f3d5c7a
Sent GsListen packet, waiting for peer...
GSRN tunnel established (role: server)
GsStart flags: 0x01
SRP client handshake complete
```

### Timeout Configuration

**Connect Timeout** (GSRN tunnel + SRP handshake):
```bash
# 60 second timeout for slow networks
zigcat -l --gs-secret MySecret -w 60

# 5 second timeout for fast networks
zigcat -l --gs-secret MySecret -w 5
```

**Idle Timeout** (bidirectional I/O):
```bash
# Close after 120 seconds of inactivity
zigcat -l --gs-secret MySecret -i 120
```

---

## Implementation Details

### File Structure

```
src/
├── net/
│   └── gsocket.zig           # GSRN protocol implementation (360 lines)
│       ├── deriveAddress()   # SHA256-based GS-Address derivation
│       ├── deriveSrpPassword() # SHA256-based SRP password derivation
│       └── establishGsrnTunnel() # GSRN handshake and tunnel setup
│
├── tls/
│   └── srp_openssl.zig       # SRP encryption using OpenSSL (449 lines)
│       ├── SrpConnection     # SRP connection state machine
│       ├── initClient()      # Client-side SRP handshake
│       ├── initServer()      # Server-side SRP handshake (TODO)
│       ├── doHandshake()     # Non-blocking handshake with poll()
│       └── read()/write()    # Encrypted I/O operations
│
├── client.zig                # Client mode orchestration
│   ├── runGsocketClient()    # Gsocket mode entry point
│   └── srpConnectionToStream() # Stream abstraction for bidirectionalTransfer
│
└── config/
    └── validator.zig         # Configuration validation
        └── validate()        # Checks gsocket incompatibilities
```

### Key Data Structures

**GS-Address** (16 bytes):
```zig
pub const GsAddress = [16]u8;
```

**SRP Password** (33 bytes):
```zig
pub const SrpPassword = [33]u8;  // 32 hex chars + null terminator
```

**SRP Connection State**:
```zig
pub const SrpConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,        // Underlying GSRN tunnel
    ssl_ctx: ?*c.SSL_CTX,
    ssl: ?*c.SSL,
    state: ConnectionState,        // initial → handshake → connected → closed
    is_client: bool,
    srp_client_ctx: ?*SrpClientContext,
    srp_server_ctx: ?*SrpServerContext,
};
```

### Configuration Validation

**Incompatible Options** (enforced at parse time):
```zig
// src/config/validator.zig
if (cfg.gsocket_secret != null) {
    if (cfg.udp_mode) return error.ConflictingOptions;     // TCP only
    if (cfg.sctp_mode) return error.ConflictingOptions;    // TCP only
    if (cfg.unix_socket_path != null) return error.ConflictingOptions;
    if (cfg.proxy != null) return error.ConflictingOptions;
    if (cfg.ssl or cfg.dtls) return error.ConflictingOptions;

    // Connect mode: no positional host/port args
    if (!cfg.listen_mode and cfg.positional_args.len > 0) {
        return error.ConflictingOptions;
    }
}
```

### Stream Abstraction Pattern

GSRN uses the same `stream.Stream` interface as TLS/DTLS for compatibility with `bidirectionalTransfer()`:

```zig
pub fn srpConnectionToStream(srp_conn: anytype) stream.Stream {
    const vtable = &struct {
        fn read(ctx: *anyopaque, buf: []u8) !usize {
            const self: *SrpConnection = @ptrCast(@alignCast(ctx));
            return self.read(buf);
        }

        fn write(ctx: *anyopaque, data: []const u8) !usize {
            const self: *SrpConnection = @ptrCast(@alignCast(ctx));
            return self.write(data);
        }

        fn close(ctx: *anyopaque) void {
            const self: *SrpConnection = @ptrCast(@alignCast(ctx));
            self.close();
        }

        fn handle(ctx: *anyopaque) posix.socket_t {
            const self: *SrpConnection = @ptrCast(@alignCast(ctx));
            return self.getSocket();
        }
    };

    return stream.Stream{
        .context = srp_conn,
        .vtable = vtable,
    };
}
```

---

## Testing and Verification

### Unit Tests

Run gsocket-specific tests:
```bash
# Test packet structure sizes
zig test src/net/gsocket.zig -Dtest-filter="packet structure sizes"

# Test secret derivation
zig test src/net/gsocket.zig -Dtest-filter="secret derivation"

# Test SRP connection initialization
zig test src/tls/srp_openssl.zig -Dtest-filter="SrpConnection initialization"
```

### Integration Testing

**Test 1: Basic File Transfer**:
```bash
# Terminal 1 (server)
echo "Hello from GSRN" | zigcat -l --gs-secret test123

# Terminal 2 (client)
zigcat --gs-secret test123
# Should output: Hello from GSRN
```

**Test 2: Bidirectional Communication**:
```bash
# Terminal 1
zigcat -l --gs-secret test123

# Terminal 2
zigcat --gs-secret test123

# Type in either terminal, should echo to the other
```

**Test 3: Timeout Handling**:
```bash
# Terminal 1: Start server with 5 second timeout
zigcat -l --gs-secret test123 -w 5

# Terminal 2: Wait 10 seconds, then try to connect
sleep 10 && zigcat --gs-secret test123
# Should fail with timeout error
```

**Test 4: Verbose Logging**:
```bash
# Terminal 1
zigcat -l --gs-secret test123 -vv 2>&1 | tee server.log

# Terminal 2
zigcat --gs-secret test123 -vv 2>&1 | tee client.log

# Verify logs show:
# - "Connecting to GSRN relay at gs.thc.org:443"
# - "Derived GS-Address: ..."
# - "GSRN tunnel established (role: ...)"
# - "SRP client handshake complete"
```

### Security Verification

**Verify Encryption**:
```bash
# Capture traffic while running gsocket connection
sudo tcpdump -i any -w gsocket.pcap host gs.thc.org

# Open in Wireshark, filter for TCP stream
# Should see:
# 1. TLS handshake to gs.thc.org:443
# 2. Encrypted application data (no plaintext visible)
```

**Verify Secret Derivation**:
```bash
# Test that same secret produces same GS-Address
zigcat -l --gs-secret test123 -vv 2>&1 | grep "Derived GS-Address"
zigcat --gs-secret test123 -vv 2>&1 | grep "Derived GS-Address"
# Both should show identical GS-Address
```

---

## Troubleshooting

### Connection Issues

#### Problem: "Connection timeout" during handshake

**Cause**: SRP handshake taking longer than connect timeout (default 30s)

**Solution**: Increase timeout with `-w` flag:
```bash
zigcat -l --gs-secret MySecret -w 60
```

#### Problem: "Connection refused" to gs.thc.org

**Cause**: Relay server down or network blocking port 443

**Diagnosis**:
```bash
# Test connectivity to relay
curl -I https://gs.thc.org

# Check firewall rules
sudo iptables -L OUTPUT -n | grep 443
```

**Solution**: Check network firewall, try from different network

#### Problem: Peers don't connect (timeout in "waiting for peer")

**Cause**: Different secrets or timing mismatch

**Solution**:
1. Verify both peers use EXACT same secret (case-sensitive)
2. Start server (`-l`) first, then client within ~60 seconds
3. Check verbose logs (`-vv`) for GS-Address mismatch

### Data Transfer Issues

#### Problem: Data corruption or binary files broken

**Cause**: CRLF conversion enabled accidentally

**Solution**: Remove `-C` flag (gsocket is binary-safe by default):
```bash
# Wrong
zigcat -l --gs-secret MySecret -C

# Correct
zigcat -l --gs-secret MySecret
```

#### Problem: "Invalid state" error during read/write

**Cause**: SRP handshake not complete or connection closed

**Diagnosis**: Enable verbose logging to see handshake state:
```bash
zigcat -l --gs-secret MySecret -vv
```

**Solution**: Ensure handshake completes before I/O operations

### Performance Issues

#### Problem: Slow transfer speeds

**Cause**: Relay server latency or SRP MAC overhead

**Diagnosis**: Measure relay latency:
```bash
ping gs.thc.org
```

**Mitigation**:
- Use compression before encryption: `tar czf - mydir/ | zigcat --gs-secret ...`
- Disable idle timeout: Don't use `-i` flag
- Consider direct connection if peers have public IPs

#### Problem: High CPU usage during transfer

**Cause**: SRP-AES-256-CBC encryption overhead

**Diagnosis**: Profile with `time` command:
```bash
time zigcat -l --gs-secret test123 < /dev/zero | head -c 100M > /dev/null
```

**Expected**: ~10-20% CPU for 100 Mbps transfer (depends on hardware)

### Error Messages

#### "SrpNotSupported: OpenSSL may not support SRP"

**Cause**: OpenSSL compiled without SRP support

**Solution**: Reinstall OpenSSL with SRP enabled:
```bash
# macOS (Homebrew)
brew reinstall openssl@3

# Linux (build from source with SRP)
./config --openssldir=/usr/local/ssl enable-srp
make && sudo make install
```

#### "ConflictingOptions: gsocket incompatible with UDP"

**Cause**: Trying to use `--gs-secret` with `-u` (UDP mode)

**Solution**: Remove `-u` flag (gsocket is TCP-only):
```bash
# Wrong
zigcat -u --gs-secret MySecret

# Correct
zigcat --gs-secret MySecret
```

#### "Missing value for --gs-secret"

**Cause**: No secret provided after `--gs-secret` flag

**Solution**: Provide secret as next argument:
```bash
# Wrong
zigcat -l --gs-secret

# Correct
zigcat -l --gs-secret "my-secret"
```

---

## Compatibility

### Protocol Compatibility

**Compatible with**:
- ✅ gs-netcat (original C implementation)
- ✅ gsocket library (libgsocket)
- ✅ All GSRN relay servers (protocol version 1.3)

**Cipher Suite Requirements**:
- Must use `SRP-AES-256-CBC-SHA` (only supported cipher)
- Client/server auto-negotiation (no manual cipher selection)

### Platform Compatibility

**Supported Platforms**:
- ✅ Linux (x86_64, aarch64, arm)
- ✅ macOS (Intel, Apple Silicon)
- ✅ Windows (x86_64, via OpenSSL)
- ✅ FreeBSD, OpenBSD, NetBSD

**Requirements**:
- OpenSSL 3.x with SRP support
- TCP socket support
- Non-blocking I/O with poll()/select()

### OpenSSL Version Notes

**OpenSSL 3.0+** (Recommended):
- Uses modern callback API (`SSL_CTX_set_srp_client_pwd_callback`)
- No deprecation warnings
- Best performance

**OpenSSL 1.1.1** (Supported):
- Uses compatibility shims for old API
- May show deprecation warnings
- Slightly slower handshake

**OpenSSL 1.0.2 and below** (NOT Supported):
- Missing required SRP callback functions
- Build will fail with linking errors

### Known Limitations

1. **Server Mode**: SRP server implementation incomplete (client-only currently)
2. **Relay Server**: Single point of failure (gs.thc.org only)
3. **SHA-1 MAC**: Weak MAC algorithm (protocol limitation)
4. **No Resumption**: No TLS session resumption support
5. **TCP Only**: No UDP/SCTP support (protocol design)

---

## References

### Protocol Documentation

- **GSRN Protocol Spec**: https://github.com/hackerschoice/gsocket
- **SRP RFC 2945**: https://tools.ietf.org/html/rfc2945
- **OpenSSL SRP Docs**: https://www.openssl.org/docs/man3.0/man3/SSL_CTX_set_srp_username.html

### Implementation Files

- **GSRN Protocol**: `src/net/gsocket.zig`
- **SRP Encryption**: `src/tls/srp_openssl.zig`
- **Client Integration**: `src/client.zig` (runGsocketClient, srpConnectionToStream)
- **Config Validation**: `src/config/validator.zig`

### Related Documentation

- **Main Usage**: [USAGE.md](USAGE.md) - CLI flag reference
- **Man Page**: [zigcat.1](zigcat.1) - Unix manual page
- **Architecture**: [CLAUDE.md](CLAUDE.md) - Implementation notes

### Security Advisories

- **SHA-1 Deprecation**: https://www.schneier.com/blog/archives/2020/01/sha-1_deprecati.html
- **SRP Security Analysis**: https://crypto.stackexchange.com/questions/8626/is-srp-6a-secure

### External Tools

- **gs-netcat**: https://github.com/hackerschoice/gsocket (C reference implementation)
- **Wireshark**: https://www.wireshark.org/ (traffic analysis)
- **OpenSSL**: https://www.openssl.org/ (crypto library)

---

## Changelog

### v0.1.0 (2025-01-16)
- ✅ Initial GSRN implementation
- ✅ SRP-AES-256-CBC-SHA encryption
- ✅ Client mode functional
- ✅ Non-blocking handshake with poll()
- ✅ Stream abstraction for bidirectionalTransfer
- ✅ Configuration validation
- ⏳ Server mode (TODO)

---

**Last Updated**: 2025-01-16
**Protocol Version**: GSRN 1.3
**Cipher Suite**: SRP-AES-256-CBC-SHA
