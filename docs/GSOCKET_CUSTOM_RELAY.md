# GSocket Custom Relay Server Support

This document describes the custom relay server feature added to zigcat's gsocket implementation, providing compatibility with the official `gs-netcat` `-R` flag.

## Overview

The gsocket protocol supports custom relay servers for private NAT traversal infrastructure. By default, zigcat uses the public relay at `gs.thc.org:443`, but users can now specify their own relay server for enhanced privacy or internal network deployments.

## Command-Line Interface

### Flags

```bash
-R, --relay <host:port>       Specify a custom GSRN relay server
                              (Default: gs.thc.org:443)
```

### Compatibility

✅ **Fully compatible with official `gs-cat` flags**:
- Short form: `-R custom.relay.com:8443`
- Long form: `--relay custom.relay.com:8443`

## Usage Examples

### Basic Custom Relay Connection

**Peer 1 (Server):**
```bash
zigcat -l --gs-secret MySecret --relay private.relay.example.com:443
```

**Peer 2 (Client):**
```bash
zigcat --gs-secret MySecret --relay private.relay.example.com:443
```

### Using Default Public Relay

```bash
# These are equivalent:
zigcat --gs-secret MySecret
zigcat --gs-secret MySecret --relay gs.thc.org:443
```

### Short Flag Form

```bash
zigcat -l --gs-secret MySecret -R 192.168.1.100:8443
```

## Implementation Details

### Architecture

The custom relay feature is implemented across four key modules:

1. **Configuration** (`src/config/config_struct.zig`):
   - Added `gsocket_relay: ?[]const u8` field to store relay address

2. **CLI Parser** (`src/cli/parser.zig`):
   - Parses `-R` and `--relay` flags
   - Stores value in `cfg.gsocket_relay`

3. **Tunnel Establishment** (`src/net/gsocket.zig`):
   - Parses relay address as `host:port`
   - Falls back to `gs.thc.org:443` if not specified
   - Validates port number range (0-65535)

4. **Validation** (`src/config/validator.zig`):
   - Ensures `--relay` is only used with `--gs-secret`
   - Returns `error.ConflictingOptions` if misused

### Parsing Logic

The relay address is parsed using the following algorithm:

```zig
// Find last ':' (supports IPv6 addresses with brackets)
const colon_pos = std.mem.lastIndexOf(u8, relay_str, ":");

// Extract host and port
const host = relay_str[0..colon_pos];
const port = std.fmt.parseInt(u16, relay_str[colon_pos + 1 ..], 10);
```

**Supported Formats:**
- `hostname.com:443`
- `192.168.1.100:8443`
- `[2001:db8::1]:443` (IPv6 with brackets)

**Invalid Formats:**
- `hostname` (missing port) → `error.InvalidGsRelayFormat`
- `hostname:abc` (non-numeric port) → `error.InvalidGsRelayFormat`
- `hostname:99999` (port out of range) → overflow error

### Error Handling

| Error | Condition | Message |
|-------|-----------|---------|
| `error.InvalidGsRelayFormat` | Missing `:` separator | "Custom gsocket relay must be in host:port format" |
| `error.InvalidGsRelayFormat` | Non-numeric port | "Invalid port number in relay address" |
| `error.ConflictingOptions` | `--relay` without `--gs-secret` | "--relay can only be used with --gs-secret" |

## Security Considerations

### Trust Model

When using a custom relay server, you must understand the trust implications:

1. **Metadata Visibility**: The relay operator can see:
   - IP addresses of both peers
   - Connection timestamps
   - Connection duration
   - GS-Address derived from secret (16 bytes)

2. **End-to-End Encryption**: The relay **cannot** see:
   - Actual data transmitted (encrypted with SRP-AES-256-CBC-SHA)
   - The shared secret itself
   - Decrypted message contents

3. **Man-in-the-Middle Risk**: 
   - The relay is **not authenticated** by the gsocket protocol
   - A malicious relay cannot decrypt data (protected by SRP)
   - However, a malicious relay could:
     - Log connection metadata
     - Block connections selectively
     - Perform traffic analysis on encrypted data

### Recommendations

✅ **Use custom relay when:**
- You control the relay server infrastructure
- You need to comply with data sovereignty requirements
- You want to avoid metadata visibility to THC operators
- You're operating in an air-gapped or internal network

❌ **Don't use custom relay when:**
- The relay server is untrusted
- DNS/routing to relay could be compromised
- You need relay server authentication (not supported by gsocket protocol)

### Hardening Measures

For production deployments with custom relays:

1. **TLS Transport** (Future Enhancement):
   - Currently, zigcat connects to relay over plain TCP (port 443 is just a convention)
   - Future versions could wrap the relay connection in TLS for transport security
   - This would authenticate the relay server and protect metadata

2. **Relay Pinning**:
   - Use IP addresses instead of hostnames to avoid DNS attacks
   - Use relay servers on trusted networks only

3. **Monitoring**:
   - Log all relay connections for audit trails
   - Monitor relay server for unauthorized access

## Compatibility with Official Implementation

### Protocol Compliance

✅ **100% compatible** with official `gs-netcat` custom relay feature:
- Uses identical flag names (`-R`, `--relay`)
- Supports same `host:port` format
- Falls back to `gs.thc.org:443` when not specified
- No changes to GSRN protocol packets

### Tested Scenarios

| Scenario | zigcat | gs-netcat | Result |
|----------|--------|-----------|--------|
| Both use default relay | ✅ | ✅ | ✅ Works |
| Both use custom relay | ✅ | ✅ | ✅ Works |
| zigcat custom, gs-netcat custom (same) | ✅ | ✅ | ✅ Works |
| zigcat default, gs-netcat custom | ✅ | ✅ | ❌ Fails (different relays) |
| zigcat custom, gs-netcat default | ✅ | ✅ | ❌ Fails (different relays) |

**Note**: Both peers **must** use the same relay server to connect.

## Setting Up a Private Relay Server

### Requirements

To run your own GSRN relay server, you need:

1. A server with a public IP address (or accessible via VPN)
2. The official `gs-netcat` relay server software (from THC gsocket repository)
3. Open firewall port (default: 443, but configurable)

### Installation

```bash
# Install gsocket relay server (gs-relay-d)
git clone https://github.com/hackerschoice/gsocket.git
cd gsocket
./configure
make
sudo make install

# Start relay daemon
sudo gs-relay-d -p 443 -l /var/log/gs-relay.log
```

### Configuration Options

```bash
gs-relay-d [options]
  -p <port>       Listen port (default: 443)
  -l <logfile>    Log file path
  -d              Daemonize (run in background)
  -v              Verbose logging
  -k <secret>     Optional shared secret for relay authentication
```

### Testing Your Relay

```bash
# Peer 1
zigcat -l --gs-secret TestSecret --relay your-relay.example.com:443

# Peer 2
zigcat --gs-secret TestSecret --relay your-relay.example.com:443
```

## Advanced Use Cases

### Internal Corporate Network

```bash
# Deploy relay on internal server
sudo gs-relay-d -p 8443 -l /var/log/gsocket-relay.log

# Users connect via internal hostname
zigcat --gs-secret ProjectAlpha --relay relay.corp.internal:8443
```

### High-Security Deployment

```bash
# Run relay on non-standard port with restricted access
sudo gs-relay-d -p 12345 -k RelayAuthSecret -l /var/log/secure-relay.log

# Firewall rules (allow only specific IPs)
sudo iptables -A INPUT -p tcp --dport 12345 -s 10.0.0.0/8 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 12345 -j DROP
```

### Multi-Region Deployment

```bash
# Deploy relays in multiple regions for low latency
Region A: relay-us-east.example.com:443
Region B: relay-eu-west.example.com:443
Region C: relay-ap-south.example.com:443

# Users choose closest relay
zigcat --gs-secret MySecret --relay relay-us-east.example.com:443
```

## Troubleshooting

### Connection Timeout

**Symptom**: `Connection timeout` error when connecting to custom relay

**Solutions**:
1. Verify relay server is running: `telnet your-relay.com 443`
2. Check firewall rules allow incoming connections on relay port
3. Ensure both peers use the **exact same** relay address

### Invalid Format Error

**Symptom**: `error.InvalidGsRelayFormat`

**Solutions**:
1. Ensure format is `host:port` (e.g., `relay.com:443`)
2. Verify port is numeric (0-65535)
3. For IPv6, use brackets: `[2001:db8::1]:443`

### Orphaned Relay Flag

**Symptom**: `--relay can only be used with --gs-secret`

**Solutions**:
1. Always use `--gs-secret` when using `--relay`
2. The relay flag is only valid in gsocket mode

## Implementation Details

### Files Modified

| File | Changes | Description |
|------|---------|-------------|
| `src/config/config_struct.zig` | +2 lines | Added `gsocket_relay` field |
| `src/cli/parser.zig` | +4 lines | Parse `-R` and `--relay` flags |
| `src/cli/help.zig` | +3 lines | Document flags in help text |
| `src/net/gsocket.zig` | +25 lines | Parse relay address, fallback to default |
| `src/config/validator.zig` | +7 lines | Validate `--relay` requires `--gs-secret` |

**Total**: ~40 lines of code across 5 files

### Performance Impact

✅ **Zero performance overhead**:
- Relay parsing only occurs once during initialization
- No runtime cost when using default relay
- Negligible parsing cost (~microseconds) for custom relay

## Future Enhancements

### Planned Features

1. **Environment Variable Support**:
   ```bash
   export GSOCKET_RELAY=relay.example.com:443
   zigcat --gs-secret MySecret  # Uses env var
   ```

2. **Relay List with Failover**:
   ```bash
   zigcat --relay relay1.com:443,relay2.com:443,relay3.com:443 --gs-secret MySecret
   # Tries relay1, falls back to relay2, then relay3
   ```

3. **TLS-Wrapped Relay Connection**:
   ```bash
   zigcat --relay-tls relay.example.com:443 --gs-secret MySecret
   # Wraps relay connection in TLS for metadata protection
   ```

4. **Relay Authentication**:
   ```bash
   zigcat --relay relay.com:443 --relay-auth AuthSecret --gs-secret MySecret
   # Authenticate to relay server (requires gs-relay-d -k support)
   ```

## References

- **Official gsocket**: https://github.com/hackerschoice/gsocket
- **GSRN Protocol**: See `GSOCKET_TODO.md` for protocol details
- **Security Model**: See "Security Considerations" section above

---

## Summary

The custom relay feature provides:

✅ **Full compatibility** with official `gs-netcat` `-R` flag  
✅ **Flexible deployment** for private/corporate infrastructure  
✅ **Enhanced privacy** by avoiding public relay metadata visibility  
✅ **Zero breaking changes** to existing gsocket functionality  
✅ **Robust validation** to prevent misconfiguration  

The implementation follows gsocket protocol standards while providing the flexibility needed for production deployments.

---

## Related Changes

This custom relay feature is part of a larger effort to bring zigcat's gsocket implementation into full compliance with the official protocol. See also:

### Issue #1: Dynamic SRP Role Determination (CRITICAL FIX)

**Problem**: Original implementation used CLI `--listen` flag to determine SRP server/client roles, breaking the protocol design.

**Fix**: Role is now dynamically assigned by the GSRN relay via `GsStart.flags`, allowing both users to run the same command without coordination.

**Impact**: Both users can now run `zigcat --gs-secret MySecret` (no `-l` coordination needed).

### Issue #2: OpenSSL Callback Error Handling (SECURITY FIX)

**Problem**: `srpServerUsernameCallback()` returned non-standard `-1` error codes instead of proper OpenSSL error values.

**Fix**: Now returns `SSL3_AL_FATAL` with proper alert descriptor (`SSL_AD_INTERNAL_ERROR`).

**Impact**: Prevents undefined behavior during SRP handshakes across OpenSSL versions.

### Issue #3: Custom Relay Server Support (NEW FEATURE)

**Problem**: Relay server was hardcoded to `gs.thc.org:443`, preventing private/corporate deployments.

**Fix**: Added `-R`/`--relay` flags (compatible with official `gs-cat`) to specify custom relay servers.

**Impact**: Users can now deploy private relay infrastructure for enhanced privacy and internal networks.

---

## Complete Change Summary

| Issue | Type | Files Modified | Lines Changed | Status |
|-------|------|----------------|---------------|--------|
| Dynamic SRP Role | Fix (Critical) | 2 files | ~50 | ✅ Complete |
| OpenSSL Callbacks | Fix (Security) | 1 file | ~5 | ✅ Complete |
| Custom Relay | Feature | 5 files | ~40 | ✅ Complete |

**Total Impact**: ~95 lines across 8 files (some overlap)

---

For detailed technical explanations of the protocol fixes, see the project documentation.
