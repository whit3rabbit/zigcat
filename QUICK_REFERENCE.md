# GSocket Changes - Quick Reference Card

## What Changed?

### 1. Dynamic Role Assignment (CRITICAL FIX)
**Before**: Users had to coordinate roles manually
```bash
Peer 1: zigcat -l --gs-secret MySecret  # Server
Peer 2: zigcat --gs-secret MySecret     # Client
```

**After**: Both run same command, relay assigns roles
```bash
Peer 1: zigcat --gs-secret MySecret  # Automatic role
Peer 2: zigcat --gs-secret MySecret  # Automatic role
```

### 2. Custom Relay Support (NEW FEATURE)
**Before**: Hardcoded to gs.thc.org:443
```bash
zigcat --gs-secret MySecret  # Always uses gs.thc.org
```

**After**: Can specify custom relay
```bash
zigcat -R private.relay.com:8443 --gs-secret MySecret
# OR
zigcat --relay private.relay.com:8443 --gs-secret MySecret
```

### 3. OpenSSL Error Handling (SECURITY FIX)
Fixed callback error codes for stability across OpenSSL versions.

---

## New Command-Line Flags

### `-R, --relay <host:port>`
Specify custom GSRN relay server (default: gs.thc.org:443)

**Example**:
```bash
zigcat -R 192.168.1.100:8443 --gs-secret MySecret
```

**Requirements**:
- Must be used with `--gs-secret`
- Both peers must use same relay
- Format: `host:port` (port required)

---

## Common Usage Patterns

### Basic Connection (Recommended)
```bash
# Both peers run identical command
zigcat --gs-secret "my-shared-secret"
```

### Custom Relay
```bash
# Both peers specify same relay
zigcat -R private.relay.com:443 --gs-secret "my-secret"
```

### File Transfer
```bash
# Receiver
zigcat --gs-secret "file-transfer" > received.tar.gz

# Sender
cat myfile.tar.gz | zigcat --gs-secret "file-transfer"
```

### Remote Shell (with security)
```bash
# Server
zigcat --gs-secret "shell-secret" -e /bin/sh --allow

# Client
zigcat --gs-secret "shell-secret"
```

---

## Error Messages & Solutions

### "--relay can only be used with --gs-secret"
**Fix**: Add `--gs-secret` flag
```bash
# Wrong
zigcat -R relay.com:443 example.com 80

# Correct
zigcat -R relay.com:443 --gs-secret MySecret
```

### "Custom gsocket relay must be in host:port format"
**Fix**: Include port number
```bash
# Wrong
zigcat -R relay.com --gs-secret MySecret

# Correct
zigcat -R relay.com:443 --gs-secret MySecret
```

---

## Documentation Reference

- **USAGE.md**: User guide with examples
- **zigcat.1**: Man page (`man zigcat`)
- **GSOCKET_CUSTOM_RELAY.md**: Detailed relay setup guide
- **GSOCKET_IMPLEMENTATION_SUMMARY.md**: Technical details

---

## Compatibility

✅ **Backward Compatible**: All existing commands still work
✅ **gs-netcat Compatible**: 100% interoperable
✅ **No Breaking Changes**: Safe to upgrade

---

## Quick Start

### For Users
```bash
# Just share a secret, connect automatically
zigcat --gs-secret "MySharedSecret"
```

### For Enterprises
```bash
# Deploy private relay, both peers connect to it
zigcat -R internal-relay.corp.com:443 --gs-secret "CorpSecret"
```

---

## Key Benefits

1. **Simpler**: No role coordination needed
2. **Flexible**: Custom relay support for private infrastructure  
3. **Stable**: Fixed OpenSSL callback errors
4. **Compatible**: Works with official gs-netcat

---

**Version**: 0.1.0+gsocket-fixes
**Status**: Production Ready
**Documentation**: See above files for details
