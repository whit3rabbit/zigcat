# Telnet Protocol Support in zigcat

zigcat implements the Telnet protocol (RFC 854) with comprehensive option negotiation support, enabling connections to legacy systems, BBSes, MUD servers, and other Telnet-based services.

## Table of Contents

- [Overview](#overview)
- [Supported RFCs and Options](#supported-rfcs-and-options)
- [Usage](#usage)
- [Technical Details](#technical-details)
- [Troubleshooting](#troubleshooting)
- [Architecture](#architecture)

## Overview

The Telnet protocol is a text-oriented protocol that operates over TCP/IP and provides bidirectional interactive text communication. Originally designed for remote terminal access, it's still widely used for:

- **Bulletin Board Systems (BBSes)**: Text-based online communities
- **MUD Servers**: Multi-User Dungeons and text-based games
- **Network Equipment**: Router/switch management interfaces
- **Legacy Systems**: Mainframe and minicomputer access
- **Testing**: Protocol debugging and manual testing

### What Telnet Mode Does

When you enable Telnet mode with `-t` or `--telnet`, zigcat:

1. **Filters IAC Sequences**: Interprets and removes Telnet command sequences (starting with 0xFF IAC byte) from the data stream
2. **Handles Option Negotiation**: Automatically responds to WILL/WONT/DO/DONT commands for supported options
3. **Escapes Binary Data**: Properly escapes 0xFF bytes in application data (IAC IAC → 0xFF)
4. **Maintains State**: Tracks negotiation state for each option across the connection lifecycle
5. **Preserves Data Integrity**: Ensures application data remains 8-bit clean and data-agnostic

### 8-Bit Clean Design

zigcat's Telnet implementation is **8-bit clean**, meaning:
- Application data can contain any byte values (0x00-0xFF)
- Only IAC sequences (0xFF prefix) are interpreted as commands
- Binary protocols can be tunneled through Telnet with proper escaping
- UTF-8 and other multi-byte encodings pass through unchanged

## Supported RFCs and Options

### Core Protocol

| RFC | Title | Status |
|-----|-------|--------|
| [RFC 854](https://www.rfc-editor.org/rfc/rfc854.html) | Telnet Protocol Specification | ✅ Full Support |
| [RFC 855](https://www.rfc-editor.org/rfc/rfc855.html) | Telnet Option Specifications | ✅ Full Support |
| [RFC 1143](https://www.rfc-editor.org/rfc/rfc1143.html) | The Q Method of Implementing TELNET Option Negotiation | ✅ Partial Support |

### Supported Options

| Option | RFC | Description | Status |
|--------|-----|-------------|--------|
| ECHO (1) | [RFC 857](https://www.rfc-editor.org/rfc/rfc857.html) | Server echoes client input | ✅ Full Support |
| SUPPRESS-GO-AHEAD (3) | [RFC 858](https://www.rfc-editor.org/rfc/rfc858.html) | Suppress go-ahead signal | ✅ Full Support |
| TERMINAL-TYPE (24) | [RFC 1091](https://www.rfc-editor.org/rfc/rfc1091.html) | Terminal type negotiation | ✅ Full Support |
| NAWS (31) | [RFC 1073](https://www.rfc-editor.org/rfc/rfc1073.html) | Negotiate About Window Size | ✅ Full Support |
| LINEMODE (34) | [RFC 1184](https://www.rfc-editor.org/rfc/rfc1184.html) | Line-oriented terminal mode | ✅ Full Support |

### Unsupported Options

Unsupported options are automatically refused with appropriate WONT/DONT responses per RFC 1143, ensuring proper negotiation behavior.

**Future Enhancements:**
- **RFC 2066 (CHARSET)**: Character set negotiation for international support
- **RFC 885 (End of Record)**: Record-oriented data transmission
- **RFC 1408 (ENVIRON)**: Environment variable passing

## Usage

### How to Exit a Telnet Session

**⚠️ IMPORTANT**: Unlike traditional telnet clients, zigcat does not use escape sequences like `Ctrl+]`. Here are your exit options:

#### Default Behavior (Recommended for Most Sessions)

**Most Telnet sessions should exit naturally when you log out on the server side:**

```bash
# Connect to a BBS or interactive system
zigcat --telnet bbs.example.com 23

# When done, use the server's logout command (e.g., 'logout', 'exit', 'quit', 'bye')
# The server closes the connection, zigcat exits automatically
```

**What happens with `Ctrl+D` (EOF on stdin):**
- zigcat performs a **half-close**: sends `shutdown(SHUT_WR)` to close the write side
- Connection stays open to receive any final data from the server
- This is **correct netcat behavior** matching ncat and allows request-response patterns

**Example of half-close pattern:**
```bash
# Send HTTP request, wait for response
echo -e "GET / HTTP/1.0\r\n\r\n" | zigcat --telnet example.com 80
# Half-close allows server to send response after request completes
```

#### Method 1: Server-Initiated Close (Most Common)
Wait for the server to close the connection using its logout/exit command. This is the natural exit for interactive sessions.

#### Method 2: Immediate Close with `-q` Flag
Use the `-q` / `--close-on-eof` flag when you want `Ctrl+D` to close immediately:

```bash
# Close immediately on Ctrl+D (skip half-close, exit right away)
zigcat --telnet -q telnet.example.com 23

# Then press Ctrl+D to close connection immediately
```

**When to use `-q`:**
- ✅ Port scanning / banner grabbing (fire-and-forget)
- ✅ Automated scripts that don't wait for server response
- ✅ Testing connections where you want immediate exit
- ❌ Interactive BBS/MUD sessions (use server logout instead)
- ❌ Request-response protocols (half-close is needed)

**Note:** The `-q` flag is for **close-on-EOF** behavior. For quiet logging mode, use the long form `--quiet` flag.

#### Method 3: Idle Timeout
```bash
# Connection closes after 60 seconds of inactivity
zigcat --telnet -i 60 bbs.example.com 23
```

#### Method 4: Force Quit
Press `Ctrl+C` to terminate zigcat immediately (sends SIGINT).

**Comparison with Traditional Tools:**

| Feature | Traditional telnet | ncat (default) | zigcat (default) | zigcat with `-q` |
|---------|-------------------|----------------|------------------|------------------|
| Escape sequence | `Ctrl+]` then `quit` | Not supported | Not supported | Not supported |
| `Ctrl+D` behavior | Varies | Half-close (keep reading) | Half-close (keep reading) | Close immediately |
| Server logout | Exits | Exits | Exits | Exits |
| Idle timeout | Not built-in | `-i` flag | `-i` flag | `-i` flag |
| Force quit | `Ctrl+C` | `Ctrl+C` | `Ctrl+C` | `Ctrl+C` |

**Flag Clarification:**
- `-q` / `--close-on-eof` → Close connection when stdin reaches EOF
- `--quiet` (long form only) → Quiet logging mode (errors only)

### Basic Telnet Client

Connect to a Telnet server with protocol handling:

```bash
# Connect to a BBS (exit naturally with server's logout command)
zigcat --telnet bbs.example.com 23

# Connect to a MUD server (type 'quit' or server's exit command when done)
zigcat --telnet mud.example.com 4000

# Connect to network equipment (use 'exit' or 'logout' at router prompt)
zigcat --telnet router.local 23

# Port scan / banner grab (use -q to close immediately after Ctrl+D)
echo "" | zigcat --telnet -q telnet.example.com 23
```

### Telnet Server Mode

Run a Telnet server that handles protocol negotiation:

```bash
# Basic Telnet server (listen mode)
zigcat -l --telnet 2323

# Telnet server with command execution (requires --allow in listen mode)
zigcat -l --telnet 2323 -e /bin/bash --allow --allow-ip 127.0.0.1
```

**Security Note**: When using `-e` or `-c` in listen mode, you MUST specify `--allow` to acknowledge the security implications. Add `--allow-ip` for IP-based access control.

### Combining with Other Features

#### Telnet over TLS

Secure your Telnet connection with TLS encryption:

```bash
# Client with TLS
zigcat --telnet --ssl telnet.example.com 992

# Server with TLS (requires certificate and key)
zigcat -l --telnet --ssl --ssl-cert cert.pem --ssl-key key.pem 992
```

#### Telnet over Unix Domain Sockets

Use Unix domain sockets for local IPC with Telnet protocol:

```bash
# Server listening on Unix socket
zigcat -l --telnet -U /tmp/telnet.sock

# Client connecting to Unix socket
zigcat --telnet -U /tmp/telnet.sock
```

#### Telnet with Proxy

Route Telnet connections through SOCKS or HTTP proxies:

```bash
# Connect through SOCKS5 proxy
zigcat --telnet --proxy socks5://localhost:1080 bbs.example.com 23

# Connect through HTTP CONNECT proxy
zigcat --telnet --proxy http://proxy.local:8080 telnet.example.com 23
```

#### Advanced Options

```bash
# Telnet with connect timeout
zigcat --telnet -w 10 slow-server.example.com 23

# Telnet with idle timeout
zigcat --telnet -i 300 idle-server.example.com 23

# Telnet with verbose output (see negotiation)
zigcat --telnet -v bbs.example.com 23

# Telnet with hex dump (debug protocol)
zigcat --telnet -x debug.hex telnet.example.com 23
```

## Technical Details

### Protocol State Machine

zigcat implements a byte-by-byte state machine that parses the Telnet protocol according to RFC 854:

**States:**
- `data`: Normal data processing
- `iac`: Received IAC (0xFF) byte
- `will/wont/do/dont`: Option negotiation states
- `sb`: Subnegotiation begin
- `sb_data`: Subnegotiation data processing
- `sb_iac`: IAC within subnegotiation

**Transitions:**
```
data → (0xFF) → iac
iac → (WILL) → will → (option) → data
iac → (SB) → sb → sb_data → (IAC) → sb_iac → (SE) → data
iac → (IAC) → data  [escaped 0xFF in application data]
```

### Option Negotiation

zigcat follows RFC 1143's Q-method for option negotiation to prevent loops:

**Negotiation Flow:**
1. Remote sends: `IAC WILL <option>`
2. Local responds: `IAC DO <option>` (if supported) or `IAC DONT <option>` (if not)
3. Option state updated: `no → yes`

**Loop Prevention:**
- Maximum 10 negotiation attempts per option
- State tracking with `no`, `yes`, `wantno`, `wantyes` states
- Automatic refusal of unsupported options

### Subnegotiation Support

For complex options that require exchanging additional data:

**Format:**
```
IAC SB <option> <data...> IAC SE
```

**Examples:**

**Terminal Type (SEND request):**
```
Server → Client: IAC SB TERMINAL-TYPE 1 IAC SE
Client → Server: IAC SB TERMINAL-TYPE 0 "xterm-256color" IAC SE
```

**NAWS (Window Size notification):**
```
Client → Server: IAC SB NAWS <width-high> <width-low> <height-high> <height-low> IAC SE
```

### Buffer Management

**Buffer Limits:**
- **Subnegotiation Buffer**: 1024 bytes (MAX_SUBNEGOTIATION_LENGTH)
- **Partial Sequence Buffer**: 16 bytes (MAX_PARTIAL_BUFFER_SIZE)
- **Negotiation Attempts**: 10 per option (MAX_NEGOTIATION_ATTEMPTS)

These limits match legacy ncat behavior and prevent DoS attacks via oversized subnegotiations.

### Partial Sequence Handling

zigcat correctly handles IAC sequences split across multiple reads:

**Example:**
```
Read 1: "Hello" + 0xFF (IAC)
Read 2: 0xFB (WILL) + 0x01 (ECHO) + "World"
Result: "HelloWorld" + negotiation response
```

The partial buffer stores incomplete sequences until the next read completes them.

### IAC Escaping

The 0xFF byte has special meaning in Telnet (IAC - Interpret As Command). To send a literal 0xFF byte:

**Application Data:**
```
Input:  "Test\xFFData"
Output: "Test\xFF\xFFData"  (IAC escaped as IAC IAC)
```

**Reading:**
```
Input:  "Test\xFF\xFFData"
Output: "Test\xFFData"      (IAC IAC decoded as 0xFF)
```

This escaping is automatic and transparent when using Telnet mode.

## Troubleshooting

### Connection Issues

**Problem:** Server closes connection immediately

**Possible Causes:**
1. Server requires specific option negotiation
2. Terminal type not acceptable
3. Protocol mismatch (server expects plain TCP, not Telnet)

**Solutions:**
```bash
# Try without Telnet mode first
zigcat server.example.com 23

# Enable verbose logging to see negotiation
zigcat --telnet -vv server.example.com 23

# Capture hex dump to analyze protocol
zigcat --telnet -x debug.hex server.example.com 23
```

### Garbled Output

**Problem:** Seeing `�WILL�ECHO` or similar IAC sequences in output

**Cause:** Server is sending Telnet protocol but you're not using `--telnet` flag

**Solution:**
```bash
# Add --telnet flag
zigcat --telnet server.example.com 23
```

**Problem:** Terminal behaves strangely (no echo, weird line breaks)

**Cause:** ECHO or LINEMODE negotiation failed

**Solution:**
```bash
# Force verbose mode to see negotiation
zigcat --telnet -v server.example.com 23

# Check which options were accepted
# Look for "IAC DO ECHO" in output
```

### Performance Issues

**Problem:** Slow connection or high CPU usage

**Cause:** Excessive option negotiation or large subnegotiations

**Solution:**
```bash
# Enable verbose logging to identify problematic negotiation
zigcat --telnet -vv server.example.com 23

# Check for negotiation loops (should be prevented)
# Maximum 10 attempts per option
```

### Binary Data Transfer

**Problem:** Binary data corrupted when using Telnet mode

**Cause:** Telnet mode is designed for text protocols. Binary 0xFF bytes are escaped.

**Solution:**
```bash
# For binary data, do NOT use --telnet flag
zigcat server.example.com 23 < binary_file.dat

# If server requires Telnet negotiation but you're sending binary:
# This is a protocol design issue - Telnet is not ideal for binary data
# Consider using raw TCP mode or base64 encoding
```

### Debugging Negotiation

**View negotiation in real-time:**
```bash
# Use -vv or -vvv for debug/trace output
zigcat --telnet -vv server.example.com 23
```

**Capture and analyze protocol:**
```bash
# Hex dump to file
zigcat --telnet -x capture.hex server.example.com 23

# Analyze hex dump to see IAC sequences
hexdump -C capture.hex | grep "ff"
```

**Common IAC sequences:**
- `ff fb 01` = IAC WILL ECHO
- `ff fd 01` = IAC DO ECHO
- `ff fc 01` = IAC WONT ECHO
- `ff fe 01` = IAC DONT ECHO
- `ff fa 18 01 ff f0` = IAC SB TERMINAL-TYPE SEND IAC SE

## Architecture

### Module Organization

```
src/protocol/
├── telnet.zig              # Core enums, validation utilities (150 lines)
├── telnet_processor.zig    # State machine, option negotiation (522 lines)
├── telnet_options.zig      # Option handlers (ECHO, NAWS, etc.) (495 lines)
└── telnet_connection.zig   # High-level wrapper (250 lines)
```

**Total**: ~1,417 lines of implementation code

### Test Coverage

```
tests/
├── telnet_protocol_test.zig          # RFC 854/855 protocol tests (404 lines)
├── telnet_state_machine_test.zig     # State transitions (145 lines)
├── telnet_options_test.zig           # Option handlers (402 lines)
└── telnet_data_processing_test.zig   # Data processing, buffers (275 lines)
```

**Total**: ~1,226 lines of test code

**Test Strategy:**
- Unit tests for each option handler
- Integration tests with socketpair
- State transition validation
- Buffer overflow protection
- Partial sequence handling
- IAC escaping correctness

### Design Principles

1. **Separation of Concerns**: Protocol logic separated from I/O handling
2. **Modularity**: Each option has its own handler
3. **Testability**: Pure functions with dependency injection
4. **Robustness**: Buffer overflow protection, negotiation loop prevention
5. **RFC Compliance**: Strict adherence to RFC specifications
6. **Data Agnostic**: Application data remains untouched (8-bit clean)

### Integration Points

**Client Mode** (`src/client.zig`):
```zig
if (cfg.telnet) {
    var telnet_conn = try TelnetConnection.init(connection, allocator, ...);
    defer telnet_conn.deinit();
    try telnet_conn.performInitialNegotiation(); // Client-side negotiation
    // Use telnet_conn.read() / telnet_conn.write()
}
```

**Server Mode** (`src/main/modes/server.zig`):
```zig
if (cfg.telnet) {
    var telnet_conn = try TelnetConnection.init(connection, allocator, ...);
    defer telnet_conn.deinit();
    try telnet_conn.performServerNegotiation(); // Server-side negotiation
    // Use telnet_conn.read() / telnet_conn.write()
}
```

**Transfer Loop** (`src/io/transfer.zig`):
The Telnet connection wraps the underlying socket, transparently handling protocol processing during `read()` and `write()` calls.

## Examples

### Connecting to a Public BBS

```bash
# Example: Synchronet BBS
zigcat --telnet bbs.synchro.net 23

# Example: DoorMUD
zigcat --telnet doormud.com 9999
```

### Setting Up a Simple Telnet Server

```bash
# Terminal 1: Start Telnet server
zigcat -l --telnet 2323

# Terminal 2: Connect with Telnet client
zigcat --telnet localhost 2323

# Or use system telnet client
telnet localhost 2323
```

### Testing Terminal Negotiation

```bash
# Set custom terminal type
export TERM=vt100
zigcat --telnet bbs.example.com 23

# Resize terminal and observe NAWS updates (if server supports it)
# Terminal size changes are automatically sent via NAWS subnegotiation
```

### Debugging Telnet Protocol

```bash
# Capture full protocol exchange
zigcat --telnet -vvv -x telnet-debug.hex server.example.com 23

# View negotiation in real-time
zigcat --telnet -vv server.example.com 23 2>&1 | grep IAC

# Compare with system telnet
telnet -d server.example.com 23
```

## See Also

- **USAGE.md**: Complete CLI reference
- **RFC 854**: Telnet Protocol Specification
- **RFC 855**: Telnet Option Specifications
- **src/protocol/**: Implementation source code
- **tests/**: Comprehensive test suite

## Contributing

When adding support for new Telnet options:

1. Add option enum to `src/protocol/telnet.zig`
2. Create handler struct in `src/protocol/telnet_options.zig`
3. Register handler in `OptionHandlerRegistry`
4. Add comprehensive tests in `tests/telnet_options_test.zig`
5. Update this documentation with RFC reference and usage examples

For bug reports or feature requests related to Telnet support, please open an issue at https://github.com/anthropics/zigcat/issues
