# Telnet Full Client Implementation TODO

**Last Updated:** 2025-10-13
**Status:** Research Complete, Implementation Planned

---

## Executive Summary

### Current Status: Excellent Protocol Handler ✅

Zigcat's Telnet implementation is **highly RFC-compliant** and functions excellently as a protocol-aware data pipe:

- ✅ **RFC 854/855** (Core Protocol) - Full compliance with IAC escaping, state machine, subnegotiation
- ✅ **RFC 857** (ECHO) - Complete negotiation support
- ✅ **RFC 858** (SUPPRESS-GO-AHEAD) - Full support
- ✅ **RFC 1091** (TERMINAL-TYPE) - Complete subnegotiation
- ✅ **RFC 1073** (NAWS) - Full subnegotiation, **but static** (no dynamic updates)
- ⚠️ **RFC 1143** (Q-Method) - Partial (missing queue bits, effective loop prevention via attempt counter)
- ⚠️ **RFC 1184** (LINEMODE) - Basic MODE subnegotiation, minimal SLC support

**Lines of Code:** 1,417 implementation + 1,226 tests = **2,643 total**

### Gap: Protocol Handler vs Full Client Application

To transform zigcat into a **full-featured interactive Telnet client** (like `telnet`, PuTTY, SecureCRT), the primary gaps are:

1. **Local Terminal (TTY) Management** - Raw mode, signal handling, echo control
2. **Data Rendering** - ANSI escape code parsing and display
3. **Dynamic Window Tracking** - SIGWINCH signal handler for NAWS updates
4. **Environment Variables** - NEW-ENVIRON option support
5. **Local Line Editing** - Complete LINEMODE with SLC implementation

**Critical Insight:** The shift is from **protocol handling** (bytes in, bytes out) to **terminal management** (controlling the user's TTY and rendering data).

---

## Phase 1: Local Terminal (TTY) Management 🎯 **HIGH PRIORITY**

**Estimated Effort:** 400-600 lines of code
**Impact:** Foundation for all interactive features
**Complexity:** Medium

### 1.1 TTY Raw Mode Implementation

**Goal:** Put local terminal into raw mode for immediate keystroke transmission.

#### Tasks

- [x] **Create `src/terminal/tty_control.zig`** (200 lines)
  - [x] `enableRawMode()` function
    - Disable `ICANON` (canonical mode - line buffering)
    - Disable `ECHO` (local echo)
    - Disable `ISIG` (signal generation)
    - Set `VMIN = 1, VTIME = 0` (byte-at-a-time input)
  - [x] `disableRawMode()` function
  - [x] `saveOriginalTermios()` function
  - [x] `restoreOriginalTermios()` function
  - [x] Platform detection (Unix vs Windows)

- [x] **Create `src/terminal/tty_state.zig`** (50 lines)
  - [x] `TtyState` struct for storing original termios
  - [x] `isatty()` wrapper for checking if stdin/stdout are TTYs

- [x] **Modify `src/client.zig`**
  - [x] Call `saveOriginalTermios()` at startup
  - [x] Call `enableRawMode()` when entering Telnet mode
  - [x] Add `defer restoreOriginalTermios()` for cleanup
  - [x] Add error handling for non-TTY stdin

- [x] **Create `tests/terminal_control_test.zig`** (150 lines)
  - [x] Test flag manipulation (ICANON, ECHO, ISIG)
  - [x] Test save/restore state
  - [x] Test non-TTY graceful handling
  - [x] Test repeated enable/disable cycles

#### Implementation Notes

**Zig Pattern:**
```zig
const std = @import("std");
const posix = std.posix;

pub const TtyState = struct {
    original_termios: posix.termios,
    is_raw: bool = false,
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) !TtyState {
        if (!posix.isatty(fd)) return error.NotATty;

        var state = TtyState{ .fd = fd, .original_termios = undefined };
        try posix.tcgetattr(fd, &state.original_termios);
        return state;
    }

    pub fn enableRawMode(self: *TtyState) !void {
        if (self.is_raw) return;

        var raw = self.original_termios;

        // Input flags: disable CR-to-NL translation, break, parity, strip, flow control
        raw.iflag &= ~@as(posix.tcflag_t, posix.BRKINT | posix.ICRNL | posix.INPCK | posix.ISTRIP | posix.IXON);

        // Output flags: disable output processing
        raw.oflag &= ~@as(posix.tcflag_t, posix.OPOST);

        // Control flags: set 8-bit characters
        raw.cflag |= posix.CS8;

        // Local flags: disable canonical mode, echo, signals, extended processing
        raw.lflag &= ~@as(posix.tcflag_t, posix.ECHO | posix.ICANON | posix.IEXTEN | posix.ISIG);

        // Byte-at-a-time read
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.fd, .FLUSH, &raw);
        self.is_raw = true;
    }

    pub fn restore(self: *TtyState) !void {
        if (!self.is_raw) return;
        try posix.tcsetattr(self.fd, .FLUSH, &self.original_termios);
        self.is_raw = false;
    }
};
```

**Critical Pitfall:** Always use `defer` to restore terminal state, even on error paths. Otherwise, a crash leaves the user's terminal in raw mode (requires typing `reset` blindly).

---

### 1.2 Enhanced Echo Control

**Goal:** Integrate existing ECHO option handler with termios to control local echo.

#### Tasks

- [x] **Modify `src/protocol/telnet_options.zig`** (existing file)
  - [x] Import `tty_control.zig`
  - [x] Enhance `EchoHandler.handleWill()`:
    - When server sends `IAC WILL ECHO`, call `tty_control.setLocalEcho(false)`
  - [x] Enhance `EchoHandler.handleWont()`:
    - When server sends `IAC WONT ECHO`, call `tty_control.setLocalEcho(true)`

- [x] **Add to `src/terminal/tty_control.zig`**
  - [x] `setLocalEcho(enabled: bool)` function
    - Toggle `ECHO` flag in termios
    - Use `TCSANOW` for immediate effect

- [x] **Create `tests/echo_integration_test.zig`** (100 lines)
  - [x] Test IAC WILL ECHO → local echo disabled
  - [x] Test IAC WONT ECHO → local echo enabled
  - [x] Test echo state persistence across reads
  - [x] Test no double-echo (type "hello", see it once)

#### Implementation Notes

**Echo Control Pattern:**
```zig
pub fn setLocalEcho(self: *TtyState, enabled: bool) !void {
    var termios_current: posix.termios = undefined;
    try posix.tcgetattr(self.fd, &termios_current);

    if (enabled) {
        termios_current.lflag |= posix.ECHO;
    } else {
        termios_current.lflag &= ~@as(posix.tcflag_t, posix.ECHO);
    }

    try posix.tcsetattr(self.fd, .NOW, &termios_current);
}
```

**Testing Strategy:**
- Use PTY pair to simulate terminal
- Send IAC negotiation sequences
- Verify termios ECHO flag state

---

### 1.3 Dynamic NAWS (Window Size Updates)

**Goal:** Detect terminal window resizes and send updated NAWS subnegotiation to server.

#### Tasks

- [ ] **Create `src/terminal/signal_handler.zig`** (150 lines)
  - [ ] `setupSigwinchHandler()` function
    - Register SIGWINCH signal handler
    - Use `SA_RESTART` flag to avoid interrupting syscalls
  - [ ] `handleSigwinch()` callback
    - Query new window size with `ioctl(TIOCGWINSZ)`
    - Set flag for main loop to process
  - [ ] Global state for window change flag (atomic if needed)

- [ ] **Modify `src/protocol/telnet_connection.zig`**
  - [ ] Add `checkAndSendWindowSizeUpdate()` method
    - Check window change flag
    - Generate NAWS subnegotiation packet
    - Send to server
  - [ ] Call `setupSigwinchHandler()` after initial NAWS negotiation

- [ ] **Modify `src/client.zig`**
  - [ ] In main I/O loop, periodically check window change flag
  - [ ] Call `telnet_conn.checkAndSendWindowSizeUpdate()`

- [ ] **Create `tests/naws_dynamic_test.zig`** (100 lines)
  - [ ] Test window size query (TIOCGWINSZ)
  - [ ] Test NAWS packet generation (big-endian encoding)
  - [ ] Test signal handler registration
  - [ ] Test byte 255 escaping (if dimension == 0xFF → 0xFF 0xFF)

#### Implementation Notes

**SIGWINCH Handler Pattern:**
```zig
const std = @import("std");
const posix = std.posix;

var window_size_changed = std.atomic.Value(bool).init(false);

fn sigwinchHandler(_: c_int) callconv(.C) void {
    window_size_changed.store(true, .release);
}

pub fn setupSigwinchHandler() !void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.empty_sigset,
        .flags = posix.SA.RESTART,
    };
    try posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn getWindowSize() !posix.winsize {
    var ws: posix.winsize = undefined;
    const result = std.os.linux.ioctl(posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result != 0) return error.IoctlFailed;
    return ws;
}
```

**NAWS Subnegotiation Format (RFC 1073):**
```
IAC SB NAWS <width-high> <width-low> <height-high> <height-low> IAC SE
0xFF 0xFA 0x1F <W-hi> <W-lo> <H-hi> <H-lo> 0xFF 0xF0
```

**Critical:** Must escape byte 255 (if dimension == 0xFF, send 0xFF 0xFF)

---

### 1.4 Signal Translation (Ctrl-C, Ctrl-Z)

**Goal:** Handle signal-generating keystrokes appropriately in raw mode.

#### Tasks

- [ ] **Design Decision:** Determine desired behavior for zigcat
  - **Option A:** Ctrl-C kills local zigcat client (current behavior)
  - **Option B:** Ctrl-C sends Telnet IP command to remote server
  - **Recommendation:** Option A (matches ncat, simpler UX)

- [ ] **If Option B chosen:**
  - [ ] Add signal handlers for SIGINT, SIGTSTP
  - [ ] In handlers, send Telnet commands:
    - Ctrl-C → `IAC IP` (0xFF 0xF4)
    - Ctrl-Z → `IAC SUSP` (0xFF 0xED)
  - [ ] Add configuration flag: `--trap-signals`

- [ ] **Document behavior in `TELNET.md`:**
  - Explain that Ctrl-C terminates local client
  - Recommend using server's logout command for graceful exit

#### Implementation Notes

**Current zigcat behavior (per TELNET.md):** No escape sequences like traditional telnet's `Ctrl-]`. Ctrl-C kills local client.

**Rationale:** Simpler UX, matches ncat behavior, avoids complexity.

**If signal trapping desired:**
```zig
fn sigintHandler(_: c_int) callconv(.C) void {
    // Send IAC IP to server
    const ip_cmd = [_]u8{ 0xFF, 0xF4 };
    _ = posix.write(global_socket_fd, &ip_cmd, ip_cmd.len) catch {};
}
```

---

## Phase 2: NEW-ENVIRON Support 🎯 **HIGH PRIORITY**

**Estimated Effort:** 300-400 lines of code
**Impact:** Better server compatibility, X11 forwarding, proper locale
**Complexity:** Medium

### Goal

Implement RFC 1572 (Telnet Environment Option) to send environment variables like `TERM`, `USER`, `DISPLAY`, `LANG` to the server during connection setup.

### Tasks

- [ ] **Add to `src/protocol/telnet.zig`** (existing file)
  - [ ] Add `TelnetOption.new_environ = 39` to enum

- [ ] **Create `src/protocol/telnet_environ.zig`** (250 lines)
  - [ ] `NewEnvironHandler` struct
  - [ ] Command constants: SEND (1), IS (0), INFO (2)
  - [ ] Type constants: VAR (0), VALUE (1), ESC (2), USERVAR (3)
  - [ ] `handleSendRequest()` method
    - Parse SEND command (which variables requested)
    - Build IS response with values
  - [ ] `buildIsResponse()` helper
    - Collect environment variables (USER, TERM, DISPLAY, LANG)
    - Escape special bytes (IAC, ESC, VAR, VALUE, USERVAR)
    - Format: `IAC SB NEW-ENVIRON IS VAR "USER" VALUE "alice" ... IAC SE`
  - [ ] `escapeValue()` helper
    - Escape 0xFF → 0xFF 0xFF
    - Escape 0x02 → 0x02 0x02
    - Escape 0x00 → 0x02 0x00
    - Escape 0x01 → 0x02 0x01
    - Escape 0x03 → 0x02 0x03

- [ ] **Modify `src/protocol/telnet_options.zig`** (existing file)
  - [ ] Register `NewEnvironHandler` in `OptionHandlerRegistry`

- [ ] **Create `tests/environ_test.zig`** (150 lines)
  - [ ] Test SEND command parsing
  - [ ] Test IS response generation
  - [ ] Test escaping (IAC, ESC, special bytes)
  - [ ] Test with real environment variables
  - [ ] Test empty variable handling

### Implementation Notes

**Environment Variables to Send (Priority Order):**
1. `TERM` - Terminal type (e.g., "xterm-256color")
2. `USER` - Login username
3. `DISPLAY` - X11 display (e.g., "localhost:10.0")
4. `LANG` - Locale (e.g., "en_US.UTF-8")
5. `SYSTEMTYPE` - OS type (e.g., "UNIX")

**Subnegotiation Format:**
```
IAC SB NEW-ENVIRON IS VAR "TERM" VALUE "xterm-256color" VAR "USER" VALUE "alice" IAC SE
```

**Escaping Example:**
- Raw value: `"val\xFFue"` (contains IAC byte)
- Escaped: `"val\xFF\xFFue"`

**Security Note:** Environment variables are sent BEFORE authentication. Only send safe variables (no passwords, tokens).

**Reference:** RFC 1572 Section 2 (Subnegotiation Format)

---

## Phase 3: Enhanced LINEMODE 🎯 **MEDIUM PRIORITY**

**Estimated Effort:** 500-700 lines of code
**Impact:** Reduced network traffic, better editing UX
**Complexity:** High

### Goal

Complete RFC 1184 (Linemode Option) implementation with full SLC (Set Local Characters) support and local line editing.

### 3.1 Complete SLC Implementation

#### Tasks

- [ ] **Modify `src/protocol/telnet_linemode.zig`** (create if needed, 300 lines)
  - [ ] SLC function code constants (18+ codes):
    - SLC_SYNCH (1), SLC_BRK (2), SLC_IP (3), SLC_AO (4), SLC_AYT (5)
    - SLC_EOR (6), SLC_ABORT (7), SLC_EOF (8), SLC_SUSP (9)
    - SLC_EC (10), SLC_EL (11), SLC_EW (12), SLC_RP (13)
    - SLC_LNEXT (14), SLC_XON (15), SLC_XOFF (16)
    - SLC_FORW1 (17), SLC_FORW2 (18)
  - [ ] SLC level/modifier flags:
    - Levels: NOSUPPORT (0), CANTCHANGE (1), VALUE (2), DEFAULT (3)
    - Modifiers: ACK (0x80), FLUSHIN (0x40), FLUSHOUT (0x20)
  - [ ] `parseSLC()` method (parse triplets from server)
  - [ ] `buildSLC()` method (generate triplets from local termios)
  - [ ] `getLocalSLC()` helper
    - Read special characters from termios.c_cc array
    - Map to SLC function codes

- [ ] **Create `tests/slc_test.zig`** (150 lines)
  - [ ] Test triplet parsing
  - [ ] Test triplet generation
  - [ ] Test level/flag handling
  - [ ] Test termios → SLC mapping

#### Implementation Notes

**SLC Triplet Format:** `[Function, Flags, Value]` (3 bytes per character)

**Example:**
- Ctrl-C (Interrupt Process): `[SLC_IP, VALUE | FLUSHIN | FLUSHOUT, 0x03]`
- Backspace (Erase Character): `[SLC_EC, VALUE, 0x7F]`

**Termios Mapping:**
```zig
const slc_map = [_]struct { slc: u8, cc_index: usize }{
    .{ .slc = SLC_IP, .cc_index = @intFromEnum(posix.V.INTR) },   // Ctrl-C
    .{ .slc = SLC_EOF, .cc_index = @intFromEnum(posix.V.EOF) },   // Ctrl-D
    .{ .slc = SLC_SUSP, .cc_index = @intFromEnum(posix.V.SUSP) }, // Ctrl-Z
    .{ .slc = SLC_EC, .cc_index = @intFromEnum(posix.V.ERASE) },  // Backspace
    .{ .slc = SLC_EL, .cc_index = @intFromEnum(posix.V.KILL) },   // Ctrl-U
    // ... more mappings
};
```

---

### 3.2 Local Line Editing

#### Tasks

- [ ] **Create `src/terminal/line_editor.zig`** (350 lines)
  - [ ] `LineEditor` struct
    - Line buffer (e.g., 4096 bytes)
    - Cursor position
    - Escape sequence state machine
  - [ ] `processKey()` method
    - Handle printable characters (append to buffer)
    - Handle backspace (0x7F or 0x08)
    - Handle delete (ESC [ 3 ~)
    - Handle arrow keys (cursor movement)
    - Handle Ctrl-A, Ctrl-E, Ctrl-U, Ctrl-K, Ctrl-W
    - Handle enter (submit line)
  - [ ] `eraseCharacter()` helper (visual: backspace-space-backspace)
  - [ ] `eraseLine()` helper (visual: CR + clear-to-end-of-line)
  - [ ] `submitLine()` method (return buffered line)

- [ ] **Create `tests/line_editor_test.zig`** (150 lines)
  - [ ] Test character append
  - [ ] Test backspace (both 0x7F and 0x08)
  - [ ] Test line erase (Ctrl-U)
  - [ ] Test word erase (Ctrl-W)
  - [ ] Test line submit (enter)

#### Implementation Notes

**When to Use Local Editing:**
- Only if LINEMODE negotiated with EDIT flag set
- Otherwise, pass all characters through to server (raw mode)

**Visual Erasing:**
```zig
pub fn eraseCharacter(self: *LineEditor) !void {
    if (self.cursor_pos == 0) return;

    self.cursor_pos -= 1;
    self.buffer[self.cursor_pos] = 0;

    // Visual: backspace (move left), space (erase), backspace (move back)
    try self.output.writeAll(&[_]u8{ 0x08, ' ', 0x08 });
}
```

**Backspace Portability:**
- Linux/macOS: Usually 0x7F (DEL)
- Windows: Usually 0x08 (^H)
- **Solution:** Handle both

---

## Phase 4: ANSI Escape Code Parser 🎯 **LOW PRIORITY**

**Estimated Effort:** 600-800 lines of code
**Impact:** Proper color/cursor rendering (visual improvement)
**Complexity:** High

### Goal

Parse ANSI escape sequences from server and execute terminal control commands (cursor movement, colors, clearing).

### Tasks

- [ ] **Create `src/terminal/ansi_parser.zig`** (400 lines)
  - [ ] State machine (Ground, Escape, CSI Entry, CSI Parameter, CSI Final)
  - [ ] `processChar()` method (state transitions)
  - [ ] Parameter buffer (up to 16 parameters)
  - [ ] Intermediate byte buffer
  - [ ] `executeCommand()` method (dispatch to renderer)

- [ ] **Create `src/terminal/ansi_renderer.zig`** (300 lines)
  - [ ] `executeCSI()` method
    - Cursor movement (CUU, CUD, CUF, CUB, CUP)
    - Clearing (ED, EL)
    - SGR (colors, bold, underline, reset)
  - [ ] `moveCursor()` helper
  - [ ] `setColor()` helper
  - [ ] `clearScreen()` helper

- [ ] **Modify `src/io/transfer.zig`** (existing file)
  - [ ] Integrate ANSI parser into socket → stdout path
  - [ ] Pass received bytes through parser before writing to stdout

- [ ] **Create `tests/ansi_parser_test.zig`** (200 lines)
  - [ ] Test each sequence type (cursor, color, clear)
  - [ ] Test partial sequences across reads
  - [ ] Test malformed sequences (graceful ignore)
  - [ ] Test parameter parsing (0-16 params)

### Implementation Notes

**State Machine (based on Paul Williams' VT100 parser):**

**States:**
1. **Ground** - Normal text
2. **Escape** - After ESC (0x1B)
3. **CSI Entry** - After ESC [
4. **CSI Parameter** - Collecting numeric parameters
5. **CSI Intermediate** - After parameters, before final
6. **CSI Final** - Execute command

**Common Sequences:**
- `ESC[2J` - Clear entire screen
- `ESC[H` - Cursor to home (0,0)
- `ESC[1;31m` - Bold red foreground
- `ESC[10;20H` - Cursor to row 10, col 20

**Parser Pattern:**
```zig
pub const State = enum { ground, escape, csi_entry, csi_param, csi_final };

pub const AnsiParser = struct {
    state: State = .ground,
    params: [16]u32 = [_]u32{0} ** 16,
    param_count: usize = 0,

    pub fn processChar(self: *AnsiParser, ch: u8) ?Command {
        return switch (self.state) {
            .ground => if (ch == 0x1B) {
                self.state = .escape;
                return null;
            } else {
                return .{ .print = ch };
            },
            // ... handle other states
        };
    }
};
```

**Fallback Strategy:** If parser disabled or encounters unknown sequences, pass raw bytes through (current behavior).

**Reference:** vt100.net (Paul Williams' state machine), ECMA-48 standard

---

## What NOT to Implement ❌

### Security RFCs: Obsolete and Superseded

Based on comprehensive RFC research, **DO NOT implement** these security extensions:

#### RFC 2066 - CHARSET Option ❌

**Why Not:**
- No security benefit
- UTF-8 is universal in 2025
- Terminal handles encoding locally
- 200-400 lines of code with zero value

**Alternative:** Assume UTF-8, let users configure terminal encoding via environment variables.

---

#### RFC 2941 - Authentication Option ❌

**Why Not:**
- **Massive implementation effort:** 3,500+ lines of complex cryptographic code
- **Downgrade attack vulnerability:** Attacker can force weakest mutually acceptable method
- **Requires external dependencies:** Kerberos KDC, SRP crypto libraries
- **No real security benefit:** "Authenticated Telnet" is still weaker than SSH
- **False sense of security:** Users might think it's secure when it's not

**Critical RFC Quote:**
> "The negotiation of the authentication type pair is not protected, allowing an attacker to force selection of the weakest mutually acceptable method."

**Alternative:** Use **SSH** for secure remote access. zigcat is for legacy/testing use cases.

---

#### RFC 2946 - Data Encryption Option ❌

**Why Not:**
- **Deprecated ciphers:** DES (broken 1999), 3DES (deprecated 2023)
- **NO INTEGRITY PROTECTION:** Can be tampered without detection
- **NO AUTHENTICATION:** Man-in-the-middle vulnerable
- **2,000+ lines of crypto code:** Complex, error-prone
- **RFC itself recommends TLS instead**

**Critical RFC Quote:**
> "All of the encryption mechanisms provided under this option do not provide data integrity."

**Alternative:** Use **TLS** (already supported via `--ssl` flag).

---

### Security Recommendations

**Add to TELNET.md (Security Section):**

```markdown
## Security Considerations

**⚠️ IMPORTANT: Telnet is NOT secure for sensitive data.**

Telnet transmits all data (including passwords) in **plaintext** and provides:
- ❌ No encryption
- ❌ No authentication
- ❌ No integrity protection

**For secure remote access, use SSH instead:**
```bash
# Instead of:
zigcat --telnet server.example.com 23

# Use SSH:
ssh user@server.example.com
```

**Use zigcat's Telnet mode only for:**
- Legacy BBS/MUD connections (non-sensitive)
- Network equipment management on isolated networks
- Protocol debugging and testing
- Port scanning (with `-z` flag)

**For encryption, use TLS mode:**
```bash
# Telnet protocol over TLS (if server supports it)
zigcat --telnet --ssl server.example.com 992
```
```

---

## Testing Strategy

### Unit Tests

**Terminal Control:**
- [ ] Test termios flag manipulation (ICANON, ECHO, ISIG on/off)
- [ ] Test canonical ↔ raw mode transitions
- [ ] Test state save/restore
- [ ] Test signal handler registration
- [ ] Test non-TTY graceful handling

**ANSI Parser:**
- [ ] Test each sequence type (cursor, color, clear, SGR)
- [ ] Test partial sequence buffering across reads
- [ ] Test malformed sequence handling (ignore gracefully)
- [ ] Test parameter parsing (0-16 params, edge cases)
- [ ] Test state machine transitions

**Echo Control:**
- [ ] Test ECHO flag toggling
- [ ] Test Telnet WILL/WONT ECHO handling
- [ ] Test echo state consistency across operations

**Window Size:**
- [ ] Test winsize struct parsing
- [ ] Test NAWS packet generation (big-endian encoding)
- [ ] Test byte 255 escaping (0xFF → 0xFF 0xFF)

**NEW-ENVIRON:**
- [ ] Test SEND command parsing
- [ ] Test IS response generation
- [ ] Test escaping (IAC, ESC, VAR, VALUE, USERVAR)
- [ ] Test with real environment variables
- [ ] Test empty/missing variable handling

**LINEMODE:**
- [ ] Test MODE subnegotiation
- [ ] Test SLC triplet parsing/generation
- [ ] Test FORWARDMASK handling
- [ ] Test termios → SLC mapping

**Line Editor:**
- [ ] Test character append
- [ ] Test backspace (both 0x7F and 0x08)
- [ ] Test line erase (Ctrl-U)
- [ ] Test word erase (Ctrl-W)
- [ ] Test cursor movement (arrow keys)
- [ ] Test line submit (enter)

---

### Integration Tests

**PTY-Based Tests:**
```zig
// Spawn PTY pair, test terminal behavior
const pty = try std.posix.openpt(.{});
const pts_name = try std.posix.ptsname(pty);
const pts = try std.posix.open(pts_name, .{}, 0);

// Apply terminal settings to pts
var tty: linux.termios = undefined;
try linux.tcgetattr(pts, &tty);
tty.lflag &= ~@as(u32, linux.ICANON | linux.ECHO);
try linux.tcsetattr(pts, .FLUSH, &tty);

// Test: Send data to pty, verify pts receives it
// Test: Send ANSI codes, verify cursor/color changes
```

**Telnet Protocol Integration:**
- [ ] Test ECHO negotiation (IAC WILL ECHO → disable local echo)
- [ ] Test NAWS negotiation (IAC DO NAWS → send size)
- [ ] Test NEW-ENVIRON (IAC DO NEW-ENVIRON → send variables)
- [ ] Test SUPPRESS-GA + ECHO combination
- [ ] Test negotiation state machine

**Signal Integration:**
- [ ] Simulate SIGWINCH, verify size query and NAWS update
- [ ] Test signal handler registration
- [ ] Test EINTR handling during I/O operations

---

### Manual Testing

**Checklist:**
- [ ] Connect to public Telnet BBS (e.g., bbs.fozztexx.com), verify display
- [ ] Resize window during session, verify server adapts (vim redraws)
- [ ] Type with local echo on/off, verify no doubling
- [ ] Test backspace on both Linux (DEL) and macOS (DEL)
- [ ] Test Ctrl-C (kills local client per zigcat design)
- [ ] SSH to server with colors, verify ANSI codes display correctly
- [ ] Run vim over Telnet, verify cursor movements work
- [ ] Test on non-TTY stdin (e.g., `echo "test" | zigcat --telnet server 23`)
- [ ] Test terminal restoration on clean exit
- [ ] Test terminal restoration on Ctrl-C (interrupt)
- [ ] Use `stty -a` to inspect terminal state before/after

---

### Edge Case Testing

**Terminal State:**
- [ ] stdin not a TTY (redirected input) - should detect and skip raw mode
- [ ] Multiple rapid mode switches
- [ ] Interrupted `tcsetattr` (EINTR handling)
- [ ] Terminal crash/kill without cleanup (verify `reset` command fixes)

**ANSI Parser:**
- [ ] Incomplete sequences at buffer boundary
- [ ] Unknown/invalid sequences (should ignore gracefully)
- [ ] Extremely long parameter lists (>16 params)
- [ ] Nested/overlapping sequences
- [ ] Malicious sequences (fuzzing)

**Signal Handling:**
- [ ] SIGWINCH during read/write operations
- [ ] Rapid SIGWINCH storm (resize spam)
- [ ] Signal handler race conditions
- [ ] Signal during telnet negotiation

**Echo:**
- [ ] Echo change mid-line
- [ ] Double WILL ECHO (idempotent)
- [ ] Echo with non-TTY stdin
- [ ] Echo during password prompt

**Window Size:**
- [ ] Window size 0×0 (invalid, should handle gracefully)
- [ ] Very large sizes (>999 rows/cols)
- [ ] Signal during NAWS transmission
- [ ] Dimension == 255 (test byte escaping)

---

### Performance Testing

- [ ] Measure overhead of ANSI parsing (throughput degradation)
- [ ] Test latency of terminal mode switches
- [ ] Memory leak testing (long-running session, hours)
- [ ] CPU usage under high I/O (should remain reasonable)
- [ ] Test with large ANSI-heavy output (e.g., `cat large.log` with colors)

---

### Fuzzing

```bash
# Fuzz ANSI parser
radamsa -n 10000 < ansi_corpus.txt | zigcat --telnet localhost 23

# Fuzz Telnet protocol parser
echo -n -e '\xFF\xFB\x01' | zigcat --telnet localhost 23

# Fuzz terminal control
for i in {1..1000}; do
    zigcat --telnet localhost 23 < /dev/urandom &
    sleep 0.1
    killall zigcat
done
```

---

## Implementation Roadmap

### Milestone 1: Foundation (2-3 weeks)
- [ ] TTY state management (save/restore)
- [ ] Raw mode implementation
- [ ] Enhanced echo control
- [ ] Unit tests for terminal control
- [ ] Documentation update (TELNET.md)

**Deliverable:** zigcat can enter/exit raw mode cleanly with proper cleanup.

---

### Milestone 2: Dynamic Window Tracking (1 week)
- [ ] SIGWINCH signal handler
- [ ] Dynamic window size query
- [ ] NAWS update transmission
- [ ] Integration tests
- [ ] Manual testing (resize during vim session)

**Deliverable:** Window resizes propagate to server, full-screen apps work correctly.

---

### Milestone 3: Environment Variables (1-2 weeks)
- [ ] NEW-ENVIRON option implementation
- [ ] Subnegotiation with escaping
- [ ] Environment variable collection (TERM, USER, DISPLAY, LANG)
- [ ] Unit tests for escaping logic
- [ ] Integration tests with real servers

**Deliverable:** Server receives client environment variables during connection.

---

### Milestone 4: Enhanced LINEMODE (2-3 weeks)
- [ ] Complete SLC implementation (18+ function codes)
- [ ] Local line editing buffer
- [ ] Editing functions (backspace, erase line, etc.)
- [ ] Integration with LINEMODE negotiation
- [ ] Comprehensive testing

**Deliverable:** Local line editing reduces network traffic, better UX.

---

### Milestone 5: ANSI Parser (Optional, 2-3 weeks)
- [ ] State machine implementation
- [ ] CSI command execution
- [ ] Color and cursor control
- [ ] Integration into I/O path
- [ ] Performance testing

**Deliverable:** Colors and cursor movements render correctly.

---

### Milestone 6: Documentation & Polish (1 week)
- [ ] Update TELNET.md with new features
- [ ] Add TERMINAL.md (user guide)
- [ ] Update CLAUDE.md (architecture)
- [ ] Create examples directory
- [ ] Write migration guide
- [ ] Security warnings

**Deliverable:** Complete user documentation for new features.

---

## References

### RFCs Analyzed

**Core Protocol:**
- RFC 854: Telnet Protocol Specification
- RFC 855: Telnet Option Specification
- RFC 857: Telnet Echo Option
- RFC 858: Telnet Suppress Go Ahead Option
- RFC 1143: The Q Method of Implementing Telnet Option Negotiation

**Advanced Options:**
- RFC 1073: Telnet Window Size Option (NAWS)
- RFC 1091: Telnet Terminal-Type Option
- RFC 1184: Telnet Linemode Option (including MODE, SLC, FORWARDMASK)
- RFC 1572: Telnet Environment Option (NEW-ENVIRON)

**Security (NOT implementing):**
- RFC 2066: TELNET CHARSET Option (Experimental)
- RFC 2941: Telnet Authentication Option (Proposed Standard)
- RFC 2946: Telnet Data Encryption Option (Standards Track)
- RFC 8446: TLS 1.3 (Current Standard - **use this instead**)

**Terminal Control:**
- ECMA-48: Control Functions for Coded Character Sets
- ISO/IEC 6429: Control functions for coded character sets

---

### Implementation Guides

**ANSI Escape Codes:**
- vt100.net: Paul Williams' DEC VT100 state machine parser
- ANSI Escape Codes: https://www2.ccs.neu.edu/research/gpc/VonaUtils/vona/terminal/vtansi.htm
- Microsoft Console Virtual Terminal Sequences: https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences

**Terminal Programming:**
- Build Your Own Text Editor: https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
- POSIX termios API documentation

**Zig-Specific:**
- codeberg.org/gnarz/term: Zig terminal handling library
- blog.fabrb.com: Real-time input capture tutorial (Zig 0.14)
- zig.news/lhp: TUI application basics - uncooked terminal I/O

---

### Reference Implementations

**C Libraries:**
- libtelnet (github.com/seanmiddleditch/libtelnet): RFC-compliant Telnet implementation
- Josh Haberman's VT100 parser: Public domain ANSI parser

**Rust Implementations:**
- tokio-rs terminal emulator: Modern async terminal emulator

---

### Testing Resources

**Test Suites:**
- vttest: VT100/VT220 compatibility test suite
- xterm test files: Comprehensive terminal test cases

**Manual Testing:**
- bbs.fozztexx.com: Public Telnet BBS for testing
- telehack.com: Interactive Telnet server
- towel.blinkenlights.nl: Star Wars ASCII movie (ANSI test)

---

## Current zigcat Status (Baseline)

**Lines of Code:**
- Implementation: 1,417 lines
- Tests: 1,226 lines
- Total: 2,643 lines

**Fully Implemented:**
- RFC 854/855 (Core Protocol)
- RFC 857 (ECHO)
- RFC 858 (SUPPRESS-GO-AHEAD)
- RFC 1091 (TERMINAL-TYPE)
- RFC 1073 (NAWS) - **Static only**

**Partially Implemented:**
- RFC 1143 (Q-Method) - Missing queue bits
- RFC 1184 (LINEMODE) - Basic MODE, minimal SLC

**Not Implemented:**
- RFC 1572 (NEW-ENVIRON)
- Terminal TTY management
- ANSI escape code parsing
- Dynamic NAWS (SIGWINCH)
- Complete LINEMODE (full SLC)

**Implementation Quality:**
- ✅ Excellent protocol compliance
- ✅ Comprehensive test coverage
- ✅ IAC escaping and loop prevention
- ✅ Buffer overflow protection
- ✅ Security: TLS support via `--ssl`

---

## Success Metrics

### Phase 1 Success (TTY Management)
- [ ] Terminal always restores on exit (no `reset` needed)
- [ ] Window resize propagates within 100ms
- [ ] No echo doubling on standard Telnet servers
- [ ] Works on Linux, macOS, FreeBSD
- [ ] Graceful degradation on Windows (warn about limitations)

### Phase 2 Success (NEW-ENVIRON)
- [ ] Environment variables sent during connection
- [ ] Server receives TERM, USER, DISPLAY correctly
- [ ] Proper escaping (no IAC injection)
- [ ] Integration tests pass

### Phase 3 Success (LINEMODE)
- [ ] Local editing reduces network traffic (measurable)
- [ ] Backspace works correctly (both DEL and ^H)
- [ ] Line erase (Ctrl-U) functions properly
- [ ] No visual artifacts

### Phase 4 Success (ANSI Parser)
- [ ] Colors display correctly
- [ ] Cursor movements work (vim, htop, etc.)
- [ ] No performance degradation (< 5% overhead)
- [ ] Graceful handling of unknown sequences

---

## Conclusion

This roadmap transforms zigcat from an **excellent Telnet protocol handler** into a **full-featured interactive Telnet client**. The implementation is modular, allowing incremental progress while maintaining stability.

**Key Priorities:**
1. **TTY Management** (Foundation)
2. **Dynamic NAWS** (User-visible improvement)
3. **NEW-ENVIRON** (Server compatibility)
4. **Enhanced LINEMODE** (Performance)
5. **ANSI Parser** (Visual polish)

**What to Skip:**
- Security RFCs (use SSH/TLS instead)
- Complex line editing (server handles it)
- Non-essential options

**Estimated Total Effort:** 8-12 weeks (1 developer, part-time)

**Next Steps:**
1. Review and approve this plan
2. Begin Phase 1: TTY Management
3. Implement iteratively with testing
4. Document as you go

---

**Document Version:** 1.0
**Date:** 2025-10-13
**Status:** Ready for Implementation
