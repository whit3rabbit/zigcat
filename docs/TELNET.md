# Telnet Protocol Support in zigcat

zigcat implements the Telnet protocol (RFC 854) with comprehensive option negotiation support, enabling connections to legacy systems, BBSes, MUD servers, and other Telnet-based services.

## Table of Contents

- [Overview](#overview)
- [Supported RFCs and Options](#supported-rfcs-and-options)
- [ANSI/VT100 Escape Sequence Parser](#ansivt100-escape-sequence-parser)
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
| NEW-ENVIRON (39) | [RFC 1572](https://www.rfc-editor.org/rfc/rfc1572.html) | Client environment variables | ✅ Full Support (safe allowlist) |

### Unsupported Options

Unsupported options are automatically refused with appropriate WONT/DONT responses per RFC 1143, ensuring proper negotiation behavior.

**Future Enhancements:**
- **RFC 2066 (CHARSET)**: Character set negotiation for international support
- **RFC 885 (End of Record)**: Record-oriented data transmission
- **RFC 1408 (ENVIRON)**: Environment variable passing

## ANSI/VT100 Escape Sequence Parser

### Overview

zigcat includes a production-quality ANSI/VT100 escape sequence parser that handles color codes, cursor movement, and xterm extensions commonly used by BBSes, MUD servers, and legacy terminal applications.

**Supported Features:**
- ✅ **VT100 Core**: CSI (Control Sequence Introducer), SGR (Select Graphic Rendition), cursor movement
- ✅ **Color Support**: 8-color ANSI, 16-color bright variants, 256-color palette, 24-bit true-color RGB
- ✅ **xterm Extensions**: 256-color mode (ESC[38;5;Nm), true-color (ESC[38;2;R;G;Bm), SGR 1006 mouse tracking
- ✅ **State Machine**: Paul Williams' canonical 14-state parser design from vt100.net
- ✅ **Streaming Parser**: Handles sequences split across buffer boundaries, zero-copy callbacks
- ✅ **Robust Error Handling**: Invalid sequences pass through unchanged (no strict errors)

**Architecture:**
- **Parser**: `src/protocol/ansi_parser.zig` (~700 lines) - Core state machine
- **Commands**: `src/protocol/ansi_commands.zig` (~400 lines) - Command dispatchers (SGR, cursor, mouse)
- **State**: `src/protocol/ansi_state.zig` (~200 lines) - Terminal state tracking for active mode
- **Tests**: `tests/ansi_parser_test.zig` (~600 lines) - 30+ comprehensive tests

### Three Modes of Operation

zigcat provides three ANSI parsing modes controlled by the `--telnet-ansi-mode` flag:

#### 1. Disabled Mode (`--telnet-ansi-mode disabled`)

**Behavior:** No ANSI parsing. All escape sequences pass through unchanged.

**Use Cases:**
- Raw protocol debugging
- Binary data transfer where ANSI sequences should not be interpreted
- Non-TTY automation scripts

**Example:**
```bash
# Connect with ANSI parsing disabled (raw mode)
zigcat --telnet --telnet-ansi-mode disabled server.example.com 23
```

**Output:** All escape sequences visible as raw bytes (e.g., `^[[31mRed Text^[[0m`)

#### 2. Passthrough Mode (`--telnet-ansi-mode passthrough`) - **Default for TTY**

**Behavior:** Parse and validate ANSI sequences, forward valid sequences to terminal unchanged. Invalid sequences pass through unmodified.

**Use Cases:**
- BBS connections with color support (most common use case)
- MUD servers with ANSI art and colors
- Terminal applications where you want the local terminal to handle rendering

**Example:**
```bash
# Connect to BBS with color support (default for TTY)
zigcat --telnet --telnet-ansi-mode passthrough bbs.example.com 23

# Or omit flag (auto-detects TTY and uses passthrough)
zigcat --telnet bbs.example.com 23
```

**Output:** Colors, cursor movements, and formatting rendered by your local terminal.

**What it does:**
- Validates escape sequences (detects malformed sequences)
- Forwards valid sequences to terminal for rendering
- Passes through invalid sequences unchanged (graceful degradation)
- No internal state tracking (lightweight, fast)

#### 3. Active Mode (`--telnet-ansi-mode active`)

**Behavior:** Parse, interpret, and maintain terminal state (cursor position, text attributes). Useful for terminal emulation or applications that need to track terminal state.

**Use Cases:**
- Terminal emulators that need cursor position tracking
- Screen scrapers that need to understand terminal state
- Applications coordinating ANSI parser with line editor
- Advanced debugging of terminal state changes

**Example:**
```bash
# Connect with full state tracking (terminal emulation)
zigcat --telnet --telnet-ansi-mode active server.example.com 23
```

**Output:** Same visual rendering as passthrough, but internal state maintained.

**What it does:**
- All features of passthrough mode
- Tracks cursor position (line, column)
- Maintains text attributes (bold, italic, underline, colors)
- Tracks screen dimensions
- Applies bounds checking on cursor movements
- Integrates with line editor for cursor coordination

**State Tracking Example:**
```zig
// After parsing: ESC[31m (set foreground to red)
terminal_state.current_attributes.foreground_color = Color{ .ansi = 1 };

// After parsing: ESC[2;10H (move cursor to line 2, column 10)
terminal_state.cursor_line = 2;
terminal_state.cursor_column = 10;
```

### Auto-Detection Behavior

When `--telnet-ansi-mode` is **not** specified, zigcat automatically chooses:

- **TTY stdin** (interactive terminal): Uses `passthrough` mode
- **Non-TTY stdin** (pipe, file redirect): Uses `disabled` mode

**Detection Logic:**
```zig
const default_mode = if (posix.isatty(posix.STDIN_FILENO))
    .passthrough  // TTY: Enable ANSI passthrough
else
    .disabled;    // Non-TTY: Disable ANSI parsing
```

**Example:**
```bash
# Interactive TTY → passthrough mode (colors enabled)
zigcat --telnet bbs.example.com 23

# Piped stdin → disabled mode (no ANSI parsing)
echo "test" | zigcat --telnet bbs.example.com 23
```

### Supported ANSI Sequences

#### SGR (Select Graphic Rendition) - Text Formatting

**8-Color ANSI:**
```
ESC[30m - ESC[37m  Foreground colors (black, red, green, yellow, blue, magenta, cyan, white)
ESC[40m - ESC[47m  Background colors
ESC[0m             Reset all attributes
ESC[1m             Bold
ESC[3m             Italic
ESC[4m             Underline
```

**Bright Colors (16-color):**
```
ESC[90m - ESC[97m  Bright foreground colors
ESC[100m - ESC[107m Bright background colors
```

**256-Color Palette:**
```
ESC[38;5;Nm        Foreground (N = 0-255)
ESC[48;5;Nm        Background (N = 0-255)
```

**True-Color RGB (24-bit):**
```
ESC[38;2;R;G;Bm    Foreground RGB (R, G, B = 0-255)
ESC[48;2;R;G;Bm    Background RGB
```

**Example:**
```bash
# Server sends: ESC[38;2;255;0;0mRed TextESC[0m
# Passthrough: Forwards to terminal → displays red text
# Active: Sets terminal_state.foreground_color = Color{ .rgb = .{ r=255, g=0, b=0 } }
```

#### Cursor Movement

```
ESC[A              Cursor up 1 line (CUU)
ESC[B              Cursor down 1 line (CUD)
ESC[C              Cursor forward 1 column (CUF)
ESC[D              Cursor back 1 column (CUB)
ESC[H              Cursor to home (1,1) (CUP)
ESC[<line>;<col>H  Cursor to position (CUP)
ESC[J              Erase display (ED)
ESC[K              Erase line (EL)
```

**Example:**
```bash
# Server sends: ESC[2;10H (move cursor to line 2, column 10)
# Active mode updates: terminal_state.cursor_line = 2, cursor_column = 10
```

#### Mouse Tracking (xterm SGR 1006)

```
ESC[<Cb;Cx;Cy;M    Mouse button press
ESC[<Cb;Cx;Cy;m    Mouse button release
```

**Parameters:**
- `Cb`: Button code (0=left, 1=middle, 2=right, 64=scroll up, 65=scroll down)
- `Cx`, `Cy`: Cursor coordinates (1-based)

**Example:**
```bash
# Server enables mouse tracking: ESC[?1006h
# User clicks at (10, 5) → Parser detects: MouseEvent{ .button_press, .button = 0, .x = 10, .y = 5 }
```

### Integration with Line Editor

When using local line editing (`--telnet-edit-mode local`), the ANSI parser coordinates cursor position with the line editor:

**Coordination Pattern:**
```zig
// Line editor maintains editing cursor
var line_editor = LineEditor.init(...);

// ANSI parser maintains terminal state
var terminal_state = TerminalState.init(80, 24);

// On cursor movement from server:
terminal_state.applyCursorMove(move);  // Update terminal state
line_editor.syncCursor(terminal_state.cursor_column);  // Sync editor
```

**Use Case Example:**
```bash
# Connect with local editing + active ANSI mode
zigcat --telnet --telnet-edit-mode local --telnet-ansi-mode active bbs.example.com 23

# Benefits:
# - Line editor knows current cursor position
# - Backspace/delete work correctly with ANSI-colored prompts
# - Arrow keys navigate correctly in multi-line prompts
```

### Performance Characteristics

| **Mode** | **CPU Usage** | **Latency** | **State Memory** |
|----------|--------------|-------------|------------------|
| `disabled` | 0% (passthrough) | ~0ns | 0 bytes |
| `passthrough` | <1% (parse only) | ~50ns/byte | 128 bytes (parser state) |
| `active` | ~2% (parse + state) | ~100ns/byte | 512 bytes (parser + terminal state) |

**Streaming Performance:**
- Zero-copy design (callbacks, no buffering except OSC sequences)
- Handles sequences split across buffer boundaries (e.g., `IAC` at end of one read, `WILL` at start of next)
- No backtracking or buffering (linear state machine)

### Parameter Limits (DoS Prevention)

To prevent denial-of-service attacks via malformed sequences:

- **Maximum parameters per sequence**: 16
- **Maximum parameter value**: 9999
- **OSC string buffer**: 256 bytes (DCS/OSC sequences)
- **Intermediates**: 2 bytes maximum

**Behavior on limit exceeded:**
- Sequence ignored, state reset to `ground`
- Invalid bytes pass through unchanged
- No errors raised (graceful degradation)

### Examples

#### BBS with ANSI Art (Default Passthrough)

```bash
# Auto-detects TTY, uses passthrough mode
zigcat --telnet bbs.example.com 23

# Server sends ANSI art with colors
# Output: Rendered with colors in your terminal
```

#### Debug ANSI Sequences (Disabled Mode)

```bash
# Disable ANSI parsing to see raw escape codes
zigcat --telnet --telnet-ansi-mode disabled -vv bbs.example.com 23

# Output: ^[[31mRed Text^[[0m (escape sequences visible)
```

#### Terminal Emulator (Active Mode with State Tracking)

```bash
# Full state tracking for terminal emulation
zigcat --telnet --telnet-ansi-mode active server.example.com 23

# Internal state maintained:
# - Cursor position (line 5, column 20)
# - Text attributes (bold, red foreground)
# - Screen dimensions (80x24)
```

#### Non-TTY Automation (Auto-Disabled)

```bash
# Piped input → ANSI parsing disabled automatically
echo "GET / HTTP/1.0\r\n\r\n" | zigcat --telnet server.example.com 80

# No ANSI parsing overhead for automation scripts
```

### Testing

The ANSI parser includes comprehensive test coverage:

**Test Categories:**
1. **State Machine Tests** (~150 lines): All 14 state transitions, ANYWHERE transitions
2. **SGR Tests** (~200 lines): 8-color, 256-color, true-color RGB, attribute combinations
3. **Cursor Movement Tests** (~100 lines): CUU, CUD, CUF, CUB, CUP with bounds checking
4. **Mouse Tests** (~50 lines): SGR 1006 button press/release, scroll events
5. **Streaming Tests** (~100 lines): Split sequences across buffers, partial IAC handling

**Run Tests:**
```bash
zig build test  # Run all tests including ANSI parser
```

### Troubleshooting

#### Problem: Colors not displaying

**Cause:** ANSI parsing disabled (non-TTY stdin or explicit `--telnet-ansi-mode disabled`)

**Solution:**
```bash
# Explicitly enable passthrough mode
zigcat --telnet --telnet-ansi-mode passthrough bbs.example.com 23
```

#### Problem: Seeing raw escape codes (e.g., `^[[31m`)

**Cause:** ANSI parsing disabled

**Solution:**
```bash
# Enable ANSI parsing (passthrough or active)
zigcat --telnet --telnet-ansi-mode passthrough bbs.example.com 23
```

#### Problem: Cursor position desynchronized

**Cause:** Using local line editor without active ANSI mode

**Solution:**
```bash
# Enable active mode for cursor coordination
zigcat --telnet --telnet-edit-mode local --telnet-ansi-mode active server.example.com 23
```

#### Problem: Invalid sequences causing issues

**Behavior:** zigcat's ANSI parser passes invalid sequences through unchanged (no errors)

**Debug:**
```bash
# Use disabled mode to see raw sequences
zigcat --telnet --telnet-ansi-mode disabled -x debug.hex server.example.com 23

# Analyze hex dump to identify malformed sequences
hexdump -C debug.hex | grep "1b"  # Look for ESC (0x1b)
```

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

### Signal Behavior

By default, zigcat mirrors traditional netcat semantics: `Ctrl+C` and `Ctrl+Z` control the **local** client. If you prefer to translate these keystrokes into Telnet commands instead of terminating zigcat, use:

```bash
zigcat --telnet --telnet-signal-mode remote bbs.example.com 23
```

In `remote` mode (POSIX terminals only):

- `Ctrl+C` → sends `IAC IP` (Interrupt Process) to the server and keeps zigcat running.
- `Ctrl+Z` → sends `IAC SUSP` (Suspend Process) to the server.
- zigcat automatically restores your terminal and the original signal handlers when the session ends.

If signal translation is unavailable on the current platform or stdin is not a TTY, zigcat falls back to the default `local` behavior and prints a warning.

### Editing Behavior

By default, zigcat leaves line editing to the remote host (traditional Telnet behaviour). Enable local editing with:

```bash
zigcat --telnet --telnet-edit-mode local bbs.example.com 23
```

When `local` editing is active on a TTY:

- Characters are buffered locally and only transmitted when you press Enter.
- Common editing keys are handled client-side:
  - **Basic editing**: Backspace, Delete, `Ctrl+U` (kill line), `Ctrl+W` (erase word)
  - **Cursor navigation**: Arrow keys (left/right), Home/End, `Ctrl+A/E` (start/end of line)
  - **Word navigation**: `Ctrl+Left/Right` (jump by word), `Alt+B/F` (word left/right)
  - **History navigation**: Up/Down arrows (browse command history, readline-style)
  - **History buffer**: 100-entry ring buffer (most recent commands first)
  - **Smart history**: Empty lines ignored, current line preserved during browsing
- zigcat negotiates the full SLC table so the server knows which control characters are intercepted locally.

**History Features:**
- Up arrow: Navigate to older commands (most recent → oldest)
- Down arrow: Navigate to newer commands (oldest → most recent, then back to current line)
- Editing: Modify history entries before submitting (creates new entry)
- Persistence: History preserved for duration of session (not saved to disk)

If stdin is not a TTY or the editor cannot be initialised, zigcat reverts to remote editing and emits a verbose warning.

### Environment Variable Negotiation

zigcat advertises `NEW-ENVIRON` by default and answers `SEND` subnegotiations with a curated set of safe variables (e.g., `TERM`, `USER`, `LANG`, `DISPLAY`, `SYSTEMTYPE`). Secrets such as tokens or passwords are never transmitted. If the server requests a variable outside the allowlist, zigcat silently ignores it for safety.

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
├── telnet_connection.zig   # High-level wrapper (250 lines)
├── ansi_parser.zig         # ANSI/VT100 state machine (700 lines)
├── ansi_commands.zig       # SGR, cursor, mouse dispatchers (400 lines)
└── ansi_state.zig          # Terminal state tracking (200 lines)
```

**Telnet Protocol**: ~1,417 lines
**ANSI Parser**: ~1,300 lines
**Total**: ~2,717 lines of implementation code

### Test Coverage

```
tests/
├── telnet_protocol_test.zig          # RFC 854/855 protocol tests (404 lines)
├── telnet_state_machine_test.zig     # State transitions (145 lines)
├── telnet_options_test.zig           # Option handlers (402 lines)
├── telnet_data_processing_test.zig   # Data processing, buffers (275 lines)
└── ansi_parser_test.zig              # ANSI parser comprehensive tests (600 lines)
```

**Telnet Tests**: ~1,226 lines
**ANSI Tests**: ~600 lines
**Total**: ~1,826 lines of test code

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

**Client Mode** (modular structure in `src/client/`):
- **Entry point**: `src/client/mod.zig` - Dispatches to telnet_client module
- **Setup**: `src/client/telnet_setup.zig` - TTY configuration, signal translation, window size detection
- **Orchestration**: `src/client/telnet_client.zig` - High-level Telnet client flow

```zig
// src/client/telnet_client.zig
pub fn runTelnetClient(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    raw_socket: posix.socket_t,
    tls_conn: ?*tls.TlsConnection,
    transfer_ctx: *TransferContext,
) !void {
    // 1. Setup TTY, signals, window size
    var setup = try telnet_setup.TelnetSetup.init(allocator, cfg);
    defer setup.deinit();

    // 2. Create TelnetConnection with 7 parameters (Zig 0.15.1+)
    var telnet_conn = try TelnetConnection.init(
        connection,
        allocator,
        cfg.terminal_type,
        setup.window_width,
        setup.window_height,
        setup.local_tty_state,
        setup.signal_translation_active, // New in modular refactor
    );
    defer telnet_conn.deinit();

    // 3. Perform initial negotiation
    try telnet_conn.performInitialNegotiation();

    // 4. Bidirectional transfer with Telnet stream adapter
    const stream = stream_adapters.telnetConnectionToStream(&telnet_conn);
    try transfer.bidirectionalTransfer(allocator, stream, cfg, ...);
}
```

**Server Mode** (`src/main/modes/server.zig`):
```zig
if (cfg.telnet) {
    var telnet_conn = try TelnetConnection.init(
        connection,
        allocator,
        null, // terminal_type (server doesn't send TERMINAL-TYPE)
        null, // window_width
        null, // window_height
        null, // local_tty_state
        false, // enable_signal_translation (server mode)
    );
    defer telnet_conn.deinit();
    try telnet_conn.performServerNegotiation();
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
