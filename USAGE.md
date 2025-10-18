# Zigcat CLI Cheat Sheet

`zigcat` is a netcat-compatible tool written in Zig. This cheat sheet lists every supported command-line flag, its input type, and a concrete example. Unless noted otherwise, examples place the port argument last and avoid mutually exclusive combinations.

## Usage Patterns
- `zigcat [options] <host> <port>` - connect to a remote endpoint.
- `zigcat -l [options] <port>` - listen for inbound connections.
- `zigcat -U <path>` - connect to or listen on a Unix domain socket.

## Generating SSL Certificates

For testing purposes, you can generate a self-signed certificate using `openssl`.

```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 365 -nodes
```

This command will create two files:

*   `key.pem`: The private key.
*   `cert.pem`: The public certificate.

**Important:** For production use, you should obtain a certificate from a trusted Certificate Authority (CA).

## Positional Arguments
- `<host>` *(string)* - remote host or IP to connect to. Example: `zigcat example.com 80`
- `<port>` *(u16 or port range string for scans)* - TCP/UDP/SCTP port number or range string for zero-I/O scans. Example: `zigcat example.com 443`
- `--` *(end of options)* - treat all following tokens as positional or exec arguments. Example: `zigcat -l 9000 -e /usr/bin/grep -- -v error`

## General Controls
- `-h`, `--help` *(flag)* - show built-in help text. Example: `zigcat --help`
- `--version` *(flag)* - print program version and exit. Example: `zigcat --version`
- `--version-all` *(flag)* - show detailed build/platform info. Example: `zigcat --version-all`

## Verbosity & Output
- `-v`, `--verbose` *(flag)* - increase verbosity to verbose (level 1). Example: `zigcat -v example.com 80`
- `-vv` *(flag)* - enable debug verbosity (level 2). Example: `zigcat -vv example.com 80`
- `-vvv` *(flag)* - enable trace verbosity (level 3). Example: `zigcat -vvv example.com 80`
- `-vvvv` *(flag)* - maximize verbosity (level 4). Example: `zigcat -vvvv example.com 80`
- `--quiet` *(flag)* - errors only; suppress other logging. Example: `zigcat --quiet example.com 80`
- `-o`, `--output <file>` *(string path)* - write received data to a file. Example: `zigcat -o logs/session.txt example.com 80`
- `--append` *(flag)* - append to the `--output` file instead of truncating. Example: `zigcat -o logs/session.txt --append example.com 80`
- `-x`, `--hex-dump [file]` *(flag + optional string path)* - enable hex dump, optionally directing output to a file.  
  Example: `zigcat -x example.com 443`  
  Example with file: `zigcat -x dumps/handshake.hex example.com 443`
- `--append-output` *(flag)* - append to the hex dump file provided to `--hex-dump`. Example: `zigcat -x dumps/handshake.hex --append-output example.com 443`

## Connection Modes
- `-l`, `--listen` *(flag)* - listen for inbound connections. Example: `zigcat -l 8080`
- `-k`, `--keep-open` *(flag)* - continue listening after each client disconnects. Example: `zigcat -l -k 8080`
- `-m`, `--max-conns <count>` *(u32)* - cap concurrent listeners. Example: `zigcat -l --max-conns 4 8080`
- `--broker` *(flag)* - relay data between connected clients (mutually exclusive with `--chat`). Example: `zigcat -l --broker 9100`
- `--chat` *(flag)* - chatroom mode with nicknames (mutually exclusive with `--broker`). Example: `zigcat -l --chat 9100`
- `--max-clients <count>` *(u32)* - limit broker/chat participants. Example: `zigcat -l --broker --max-clients 150 9100`

## Transport & Address Selection
- `-u`, `--udp` *(flag)* - use UDP instead of TCP. Example: `zigcat --udp 198.51.100.5 53`
- `--sctp` *(flag)* - use SCTP transport. Example: `zigcat --sctp example.com 9899`
- `-U`, `--unixsock <path>` *(string path)* - use a Unix domain socket. Example: `zigcat -U /tmp/zigcat.sock`
- `-4` *(flag)* - force IPv4. In client mode, only attempts to connect to IPv4 addresses. In server mode, listens only on IPv4. Example: `zigcat -4 example.com 80`
- `-6` *(flag)* - force IPv6. In client mode, only attempts to connect to IPv6 addresses. In server mode, listens only on IPv6. Example: `zigcat -6 ipv6.example.com 80`
- **Dual-Stack Listening**: By default, if no bind address or IP version flag is specified in listen mode, `zigcat` will listen on both IPv4 (`0.0.0.0`) and IPv6 (`::`) simultaneously.
- `-s`, `--source <addr>` *(string)* - bind to a local source address. Example: `zigcat --source 192.0.2.10 example.com 80`
- `-p`, `--source-port <port>` *(u16)* - bind to a specific local port. Example: `zigcat --source-port 55000 example.com 80`
- `--keep-source-port` *(flag)* - retry connections without changing the bound source port. Example: `zigcat --keep-source-port --source-port 55000 example.com 80`
- `-n`, `--nodns` *(flag)* - skip DNS lookups; treat host as literal address. Example: `zigcat --nodns 93.184.216.34 80`

## Timing & Flow Control
- `-w`, `--wait <seconds>` *(u32 seconds)* - set connect timeout (converted to milliseconds). Example: `zigcat --wait 10 example.com 80`
- `-i`, `--idle-timeout <seconds>` *(u32 seconds)* - drop idle connections after the given timeout. Example: `zigcat -l --idle-timeout 60 9000`
- `-d`, `--delay <ms>` *(u32 milliseconds)* - pause between reads/writes for traffic shaping. Example: `zigcat --delay 250 example.com 80`
- `-q`, `--close-on-eof` *(flag)* - close the socket when stdin reaches EOF. Example: `zigcat -q example.com 80`
- `--no-shutdown` *(flag)* - keep the write side open after stdin EOF. Example: `zigcat --no-shutdown example.com 80`

## Transfer Behavior
- `--send-only` *(flag)* - disable reading from the socket. Example: `zigcat --send-only example.com 80`
- `--recv-only` *(flag)* - disable writing to the socket. Example: `zigcat --recv-only example.com 80`
- `-C`, `--crlf` *(flag)* - translate LF to CRLF on transmit. Example: `zigcat --crlf mail.example.com 25`
- `-t`, `--telnet` *(flag)* - process Telnet IAC sequences for connecting to BBSes, MUDs, and legacy systems. See [Telnet Protocol Support](#telnet-protocol-support) below for details. Example: `zigcat --telnet bbs.example.com 23`
- `--no-stdin` *(flag)* - do not pipe stdin into the exec child. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stdin`
- `--no-stdout` *(flag)* - discard exec stdout. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stdout`
- `--no-stderr` *(flag)* - discard exec stderr. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stderr`

## Telnet Protocol Support

The `--telnet` flag enables RFC 854 Telnet protocol processing, allowing zigcat to connect to legacy systems that require proper IAC (Interpret As Command) sequence handling and option negotiation.

### What Telnet Mode Does

- **Filters IAC Sequences**: Removes Telnet command bytes (0xFF IAC) from data stream
- **Option Negotiation**: Automatically responds to WILL/WONT/DO/DONT commands
- **Escapes Binary Data**: Properly handles 0xFF bytes in application data (IAC IAC → 0xFF)
- **Terminal Support**: Negotiates terminal type, window size (NAWS), and echo settings

### Supported Options (RFC Compliance)

- **ECHO (RFC 857)**: Server echo control
- **SUPPRESS-GO-AHEAD (RFC 858)**: Suppress go-ahead signal
- **TERMINAL-TYPE (RFC 1091)**: Terminal type negotiation
- **NAWS (RFC 1073)**: Window size negotiation
- **LINEMODE (RFC 1184)**: Line-oriented terminal mode

### Connecting to Legacy Systems

**Bulletin Board Systems (BBSes):**
```bash
# Connect to a BBS
zigcat --telnet bbs.example.com 23

# Connect with verbose logging to see negotiation
zigcat --telnet -v bbs.example.com 23
```

**MUD Servers (Multi-User Dungeons):**
```bash
# Connect to a MUD
zigcat --telnet mud.example.com 4000

# Connect with connection timeout
zigcat --telnet -w 10 mud.example.com 4000
```

**Network Equipment:**
```bash
# Connect to router/switch management
zigcat --telnet router.local 23

# Connect with specific source address
zigcat --telnet --source 192.168.1.10 router.local 23
```

### Telnet Server Mode

**Basic Telnet Server:**
```bash
# Listen for Telnet connections
zigcat -l --telnet 2323

# Keep listening after each client disconnects
zigcat -l --telnet -k 2323
```

**Telnet Server with Command Execution:**
```bash
# REQUIRES --allow flag in listen mode
zigcat -l --telnet 2323 -e /bin/bash --allow --allow-ip 127.0.0.1
```

### Combining Telnet with Other Features

**Telnet over TLS:**
```bash
# Secure Telnet connection
zigcat --telnet --ssl telnet-tls.example.com 992

# Telnet server with TLS
zigcat -l --telnet --ssl --ssl-cert cert.pem --ssl-key key.pem 992
```

**Telnet over Unix Domain Sockets:**
```bash
# Server on Unix socket
zigcat -l --telnet -U /tmp/telnet.sock

# Client via Unix socket
zigcat --telnet -U /tmp/telnet.sock
```

**Telnet through Proxy:**
```bash
# Connect through SOCKS5 proxy
zigcat --telnet --proxy socks5://localhost:1080 bbs.example.com 23

# Connect through HTTP CONNECT proxy
zigcat --telnet --proxy http://proxy.local:8080 telnet.example.com 23
```

### Debugging Telnet Protocol

**View Protocol Negotiation:**
```bash
# Use -v/-vv/-vvv for increasing verbosity
zigcat --telnet -vv server.example.com 23
```

**Capture Protocol Exchange:**
```bash
# Hex dump to file for analysis
zigcat --telnet -x telnet-debug.hex server.example.com 23

# View IAC sequences in hex dump
hexdump -C telnet-debug.hex | grep "ff"
```

**Common IAC Sequences:**
- `ff fb 01` = IAC WILL ECHO
- `ff fd 01` = IAC DO ECHO
- `ff fc 01` = IAC WONT ECHO
- `ff fe 01` = IAC DONT ECHO
- `ff fa 18 01 ff f0` = IAC SB TERMINAL-TYPE SEND IAC SE

### When NOT to Use Telnet Mode

**Plain TCP Services:**
If the server doesn't use Telnet protocol (most modern services), omit `--telnet`:
```bash
# HTTP - plain TCP
zigcat example.com 80

# SSH - NOT Telnet
zigcat example.com 22
```

**Binary Data Transfer:**
For binary data, avoid `--telnet` unless the protocol specifically requires it. Telnet escaping (IAC IAC) adds overhead:
```bash
# Binary file transfer - plain TCP
zigcat example.com 9000 < binary_file.dat
```

### Troubleshooting

**Problem:** Seeing `�WILL�ECHO` or garbled IAC sequences in output

**Solution:** Server is using Telnet protocol but you forgot `--telnet` flag
```bash
zigcat --telnet server.example.com 23
```

**Problem:** Connection closes immediately

**Solution:** Server may require specific option negotiation. Enable verbose logging:
```bash
zigcat --telnet -vv server.example.com 23
```

**Problem:** Terminal behaves oddly (no echo, strange line breaks)

**Solution:** Check which options were negotiated with verbose mode:
```bash
zigcat --telnet -v server.example.com 23
```

For comprehensive Telnet documentation including RFC references, architecture details, and advanced usage, see **[TELNET.md](TELNET.md)**.

## Execution Integration

**⚠️ Security Note**: zigcat requires explicit security acknowledgment for exec mode in listen mode to prevent accidental remote code execution vulnerabilities.

- `-e`, `--exec <cmd> [args...]` *(string command + optional args)* - run a program per connection; arguments continue until the next flag or end-of-options marker.
  **Required flags**: `--allow` when in listen mode (`-l`). Optionally add `--allow-ip` for IP restrictions.
  Example (ncat-compatible): `zigcat -l 9000 -e /usr/bin/cat --allow`
  Example (with IP restrictions): `zigcat -l 9000 -e /usr/bin/cat --allow --allow-ip 127.0.0.1`

- `-c`, `--sh-exec <command>` *(string)* - run command through the system shell.
  **Required flags**: `--allow` when in listen mode (`-l`). Optionally add `--allow-ip` for IP restrictions.
  Example (ncat-compatible): `zigcat -l 9000 -c "/usr/bin/logger -t zigcat" --allow`
  Example (with IP restrictions): `zigcat -l 9000 -c "/usr/bin/logger -t zigcat" --allow --allow-ip 192.168.1.0/24`

- `--allow` *(flag)* - acknowledge dangerous exec operations (REQUIRED for `-e`/`-c` in listen mode). When used alone, works like ncat (accepts all connections). Add `--allow-ip` for defense-in-depth IP restrictions.
  Example: `zigcat -l 9000 --allow -e /usr/bin/cat`

- `--allow-ip <list>` *(comma-separated strings)* - optional inline allowlist of CIDRs or addresses for defense-in-depth. When specified, only connections from these addresses can use exec mode.
  Example: `zigcat -l 9000 --allow --allow-ip 192.168.1.0/24,10.0.0.5 -e /usr/bin/cat`

- `--drop-user <name>` *(string)* - drop privileges to the named user after binding.
  Example: `zigcat -l 9000 --drop-user nobody --allow -e /usr/bin/cat`

**ncat Compatibility**:
- ncat: `ncat -l 9000 -e /bin/sh` ✅ works without flags (permissive by default)
- zigcat: `zigcat -l 9000 -e /bin/sh --allow` ✅ works with `--allow` flag (ncat-compatible)
- zigcat: `zigcat -l 9000 -e /bin/sh --allow --allow-ip 127.0.0.1` ✅ defense-in-depth with IP restrictions
- This behavior is consistent across ALL transports: TCP, UDP, Unix sockets, SCTP

## File Transfers

You can use `zigcat` to send files between two machines.

**Receiver:**
```bash
zigcat -l 1234 > received_file.txt
```

**Sender:**
```bash
zigcat localhost 1234 < original_file.txt
```

For encrypted transfers, use the `--ssl` flag.

**Receiver (with SSL):**
```bash
zigcat -l --ssl --ssl-cert cert.pem --ssl-key key.pem 1234 > received_file.txt
```

**Sender (with SSL):**
```bash
zigcat --ssl localhost 1234 < original_file.txt
```

## Remote Shell

You can get a remote shell using `zigcat`. Note that exec mode in listen mode requires the `--allow` flag.

**Listener (ncat-compatible):**
```bash
zigcat -l 1234 -e /bin/sh --allow
```

**Listener (with IP restrictions for defense-in-depth):**
```bash
zigcat -l 1234 -e /bin/sh --allow --allow-ip 127.0.0.1
```

**Connector:**
```bash
zigcat localhost 1234
```

For an encrypted remote shell, use the `--ssl` flag.

**Listener (with SSL, ncat-compatible):**
```bash
zigcat -l --ssl --ssl-cert cert.pem --ssl-key key.pem 1234 -e /bin/sh --allow
```

**Listener (with SSL and IP restrictions):**
```bash
zigcat -l --ssl --ssl-cert cert.pem --ssl-key key.pem 1234 -e /bin/sh --allow --allow-ip 127.0.0.1
```

**Connector (with SSL):**
```bash
zigcat --ssl localhost 1234
```

## Security & Access Control
- `--deny-file <path>` *(string path)* - load blocked host rules. Example: `zigcat -l 9000 --deny-file config/deny.list`
- `--allow-file <path>` *(string path)* - load allowed host rules. Example: `zigcat -l 9000 --allow-file config/allow.list`
- `--allow-ip <list>` *(comma-separated strings)* - inline allowlist of CIDRs or addresses. Example: `zigcat -l 9000 --allow-ip 192.168.1.0/24,10.0.0.5`
- `--deny-ip <list>` *(comma-separated strings)* - inline blocklist of CIDRs or addresses. Example: `zigcat -l 9000 --deny-ip 0.0.0.0/0`

## TLS/DTLS Options

**TLS Backend:** ZigCat supports two TLS backends selected at build time:
- **OpenSSL** (default): Full TLS 1.0-1.3 + DTLS 1.0-1.3 support
- **wolfSSL** (opt-in via `-Dtls-backend=wolfssl`): TLS 1.0-1.3 only, 60% smaller binary

All TLS flags work with both backends. DTLS flags only work with OpenSSL backend.

- `--ssl` *(flag)* - enable TLS (TCP) or DTLS (UDP). Example: `zigcat --ssl example.com 443`
- `--dtls` *(flag)* - enable DTLS (Datagram TLS over UDP, OpenSSL backend only). Example: `zigcat --dtls example.com 4433`
- `--dtls-mtu <bytes>` *(u16)* - set DTLS path MTU (default: 1200 bytes, OpenSSL backend only). Example: `zigcat --dtls --dtls-mtu 1400 example.com 4433`
- `--dtls-version <version>` *(enum: 1.0|1.2|1.3)* - set DTLS protocol version (default: 1.2, OpenSSL backend only). Example: `zigcat --dtls --dtls-version 1.3 example.com 4433`
- `--dtls-timeout <ms>` *(u32 milliseconds)* - set initial DTLS retransmission timeout (default: 1000ms, OpenSSL backend only). Example: `zigcat --dtls --dtls-timeout 2000 example.com 4433`
- `--ssl-verify` *(flag)* - force certificate verification (explicit opt-in). Example: `zigcat --ssl --ssl-verify example.com 443`
- `--no-ssl-verify` *(flag)* - disable certificate verification (insecure, requires `--insecure`). Example: `zigcat --ssl --insecure --no-ssl-verify example.com 443`
- `--ssl-verify=false` *(flag)* - alternate form to disable verification (requires `--insecure`). Example: `zigcat --ssl --insecure --ssl-verify=false example.com 443`
- `--insecure` *(flag)* - **REQUIRED** to allow insecure TLS connections when disabling certificate verification. This flag explicitly acknowledges the security risks of man-in-the-middle attacks and other threats. Example: `zigcat --ssl --insecure --no-ssl-verify example.com 443`
- `--ssl-cert <file>` *(string path)* - server certificate file. Example: `zigcat -l 8443 --ssl --ssl-cert certs/server.crt`
- `--ssl-key <file>` *(string path)* - server private key. Example: `zigcat -l 8443 --ssl --ssl-key certs/server.key`
- `--ssl-trustfile <file>` *(string path)* - CA bundle for client verification. Example: `zigcat --ssl --ssl-trustfile /etc/ssl/certs/ca-bundle.crt example.com 443`
- `--ssl-crl <file>` *(string path)* - certificate revocation list. Example: `zigcat --ssl --ssl-crl revocations.pem example.com 443`
- `--ssl-ciphers <list>` *(string)* - OpenSSL cipher list. Example: `zigcat --ssl --ssl-ciphers "TLS_AES_128_GCM_SHA256" example.com 443`
- `--ssl-servername <name>` *(string)* - override SNI hostname. Example: `zigcat --ssl --ssl-servername web.internal example.net 443`
- `--ssl-alpn <protocols>` *(string)* - comma-separated ALPN protocols. Example: `zigcat --ssl --ssl-alpn "h2,http/1.1" example.com 443`

### DTLS Usage Notes

**DTLS (Datagram Transport Layer Security)** extends TLS to UDP connections, preserving message boundaries while providing encryption.

**⚠️ Backend Compatibility:**
- **OpenSSL backend**: Full DTLS 1.0/1.2/1.3 support
- **wolfSSL backend**: DTLS not yet implemented (use `--ssl` for TLS over TCP only)

**Client Mode:**
```bash
# Basic DTLS client connection
zigcat --dtls example.com 4433

# DTLS with custom MTU and version
zigcat --dtls --dtls-mtu 1400 --dtls-version 1.2 example.com 4433

# DTLS with certificate verification
zigcat --dtls --ssl-verify --ssl-trustfile /etc/ssl/certs/ca-bundle.crt example.com 4433
```

**Server Mode:**
```bash
# DTLS server (requires certificate and key)
zigcat -l --dtls --ssl-cert cert.pem --ssl-key key.pem 4433

# DTLS server with client certificate verification
zigcat -l --dtls --ssl-cert cert.pem --ssl-key key.pem --ssl-verify --ssl-trustfile ca.pem 4433
```

**Requirements:**
- DTLS 1.0/1.2: OpenSSL 1.0.2 or later
- DTLS 1.3: OpenSSL 3.2.0 or later
- wolfSSL backend: DTLS not supported (returns `DtlsNotAvailableWithWolfSSL` error)

**Key Differences from TLS:**
- Operates over UDP instead of TCP
- Preserves message boundaries (each write = one datagram)
- Built-in retransmission for handshake packets
- MTU awareness to avoid IP fragmentation
- Cookie exchange for DoS protection (server mode)

## Global Socket (NAT Traversal)

**Global Socket Relay Network (GSRN)** enables two peers behind NAT/firewalls to establish a direct encrypted connection without port forwarding or VPN configuration. Uses gs.thc.org:443 relay server by default with end-to-end SRP-AES-256-CBC-SHA encryption.

- `--gs-secret <secret>` *(string)* - shared secret for GSRN connection. Both peers must use the exact same secret for connection establishment. The secret is hashed (SHA256) to derive a 128-bit GS-Address for relay server matching. Example: `zigcat --gs-secret MySecret`
- `-R, --relay <host:port>` *(string)* - specify a custom GSRN relay server (default: gs.thc.org:443). Enables private relay infrastructure for corporate/internal networks. Example: `zigcat -R private.relay.com:8443 --gs-secret MySecret`

### Protocol Overview

1. **Secret Derivation**: Both peers derive shared GS-Address from secret using SHA256
2. **Relay Connection**: Peers connect to gs.thc.org:443 (GSRN relay)
3. **Packet Exchange**: Server sends GsListen, client sends GsConnect packet
4. **Tunnel Establishment**: Relay matches addresses and creates raw TCP tunnel
5. **SRP Handshake**: Secure Remote Password (SRP) handshake provides end-to-end encryption
6. **Encrypted Stream**: SRP-AES-256-CBC-SHA cipher (compatible with gs-netcat)

### Security Characteristics

- ✅ **Mutual Authentication**: SRP provides password-based auth without X.509 certificates
- ✅ **End-to-End Encryption**: AES-256-CBC encryption independent of relay server
- ✅ **No Port Forwarding**: Both peers can be behind NAT/firewall
- ⚠️ **SHA-1 MAC**: Uses SHA-1 HMAC (weak, but required for gs-netcat compatibility)
- ⚠️ **Secret Strength**: Security depends on passphrase strength (use 32+ chars)

### Incompatibilities

GSRN mode cannot be combined with:
- ❌ UDP mode (`-u`) or SCTP (`--sctp`) - TCP only
- ❌ Unix sockets (`-U`) - network transport only
- ❌ Proxies (`--proxy`) - has its own NAT traversal
- ❌ SSL/TLS (`--ssl`) or DTLS (`--dtls`) - has its own encryption

### Basic Usage

**Automatic Role Assignment (Recommended):**
```bash
# Both peers run the same command - relay assigns roles automatically
# First peer to connect becomes server, second becomes client
Peer 1: zigcat --gs-secret MySecret
Peer 2: zigcat --gs-secret MySecret

# With verbose logging to see role assignment
zigcat --gs-secret MySecret -vv
# Output: "GSRN tunnel established (assigned role: Server)" or "...Client"
```

**Manual Mode Selection (Optional):**
```bash
# Explicitly register as listener (sends GsListen packet)
zigcat -l --gs-secret MySecret

# Explicitly register as connector (sends GsConnect packet)
zigcat --gs-secret MySecret

# Note: Actual SRP server/client role is still assigned by relay, not by -l flag
```

**Custom Relay Server:**
```bash
# Both peers must use the same custom relay
zigcat -R private.relay.com:8443 --gs-secret MySecret
zigcat -R private.relay.com:8443 --gs-secret MySecret
```

### File Transfer Examples

**Receiver (listen mode):**
```bash
# Receive file through GSRN tunnel
zigcat -l --gs-secret "file-transfer-secret" > received-file.tar.gz

# With progress output
zigcat -l --gs-secret "file-transfer-secret" -v > received-file.tar.gz
```

**Sender (connect mode):**
```bash
# Send file through GSRN tunnel
cat myfile.tar.gz | zigcat --gs-secret "file-transfer-secret"

# With hex dump for debugging
cat myfile.tar.gz | zigcat --gs-secret "file-transfer-secret" -x transfer.hex
```

### Remote Shell Examples

**Server (listen mode with exec):**
```bash
# REQUIRES --allow flag for remote shell
zigcat -l --gs-secret "shell-secret" -e /bin/sh --allow

# With IP restrictions (if connecting through known egress IP)
zigcat -l --gs-secret "shell-secret" -e /bin/sh --allow --allow-ip 203.0.113.0/24
```

**Client (connect mode):**
```bash
# Connect to remote shell through GSRN
zigcat --gs-secret "shell-secret"
```

### Timeout Configuration

**Custom Handshake Timeout:**
```bash
# Set 60 second timeout for slow networks (applies to SRP handshake)
zigcat -l --gs-secret MySecret -w 60

# Quick timeout for fast networks
zigcat -l --gs-secret MySecret -w 5
```

**Idle Timeout:**
```bash
# Close connection after 120 seconds of inactivity
zigcat -l --gs-secret MySecret -i 120
```

### Troubleshooting

**Problem:** Connection times out during handshake

**Solution:** Increase connect timeout with `-w` flag (default 30s):
```bash
zigcat -l --gs-secret MySecret -w 60
```

**Problem:** Can't see peer connection status

**Solution:** Enable verbose logging to see GSRN tunnel and SRP handshake:
```bash
zigcat -l --gs-secret MySecret -vv
```

**Problem:** Connection works but data corrupted

**Solution:** Ensure both peers use EXACT same secret (case-sensitive):
```bash
# Both must use identical secret
zigcat -l --gs-secret "Correct-Secret-2025"
zigcat --gs-secret "Correct-Secret-2025"
```

**Problem:** Error: ConflictingOptions with UDP/TLS/Proxy

**Solution:** GSRN is TCP-only with built-in encryption. Remove incompatible flags:
```bash
# ❌ Wrong: --gs-secret with --ssl
zigcat --gs-secret MySecret --ssl

# ✅ Correct: --gs-secret alone provides encryption
zigcat --gs-secret MySecret
```

**Problem:** Error: --relay can only be used with --gs-secret

**Solution:** The `-R` flag requires `--gs-secret` for GSRN mode:
```bash
# ❌ Wrong: --relay without --gs-secret
zigcat -R relay.com:443 example.com 80

# ✅ Correct: --relay with --gs-secret
zigcat -R relay.com:443 --gs-secret MySecret
```

**Problem:** Error: Custom gsocket relay must be in host:port format

**Solution:** Ensure relay address includes both hostname and port:
```bash
# ❌ Wrong: missing port
zigcat -R relay.example.com --gs-secret MySecret

# ✅ Correct: host:port format
zigcat -R relay.example.com:443 --gs-secret MySecret
```

For comprehensive GSRN documentation including protocol details, security analysis, custom relay setup, and advanced configuration, see **[GSOCKET_CUSTOM_RELAY.md](GSOCKET_CUSTOM_RELAY.md)** and **[GSOCKET_IMPLEMENTATION_SUMMARY.md](GSOCKET_IMPLEMENTATION_SUMMARY.md)**.

## Proxy Support
- `--proxy <target>` *(string)* - proxy address (e.g. `socks5://host:port` or `http://host:port`). Example: `zigcat --proxy socks5://127.0.0.1:1080 example.com 80`
- `--proxy-type <mode>` *(enum: http|socks4|socks5)* - override proxy protocol. Example: `zigcat --proxy proxy.local:8080 --proxy-type http example.com 80`
- `--proxy-auth <user:pass>` *(string)* - supply basic proxy credentials. Example: `zigcat --proxy http://proxy.local:8080 --proxy-auth alice:secret example.com 80`
- `--proxy-dns <mode>` *(enum: local|remote|both)* - control where DNS resolves. Example: `zigcat --proxy socks5://127.0.0.1:1080 --proxy-dns remote example.com 80`

## Zero-I/O & Scanning
- `-z`, `--zero-io` *(flag)* - perform connection checks without data transfer. Example: `zigcat -z example.com 443`
- `--scan-parallel` *(flag)* - parallelize zero-I/O scans. Example: `zigcat -z --scan-parallel example.com 1-1024`
- `--scan-randomize` *(flag)* - randomize scan order. Example: `zigcat -z --scan-parallel --scan-randomize example.com 1-1024`
- `--scan-workers <count>` *(usize)* - worker threads for parallel scans. Example: `zigcat -z --scan-parallel --scan-workers 20 example.com 1-1024`
- `--scan-delay <ms>` *(u32 milliseconds)* - delay between probes for stealth. Example: `zigcat -z --scan-parallel --scan-delay 100 example.com 1-1024`

All paths accept ASCII and must avoid traversal sequences (`..`) to pass internal validation. Numeric inputs are parsed in base 10 and must fit the listed Zig integer type. Combine options as needed, staying mindful of mutual exclusions such as `--send-only` vs. `--recv-only` and `--broker` vs. `--chat`.
