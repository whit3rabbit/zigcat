# Telnet RFC Compliance Documentation

**Last Updated:** 2025-01-17
**Status:** Active Development
**Related:** TELNET_TODO.md

---

## Executive Summary

Zigcat's Telnet implementation provides **excellent RFC compliance** for core protocol (RFC 854/855) with strong support for common options. This document serves as a single source of truth for RFC compliance status, eliminating the need for repeated RFC lookups.

**Current Compliance Level:** ~85% (Core protocol + 6 major options)

---

## Compliance Matrix

### Core Protocol Specifications

| RFC | Title | Status | Completion | Notes |
|-----|-------|--------|------------|-------|
| **854** | Telnet Protocol Specification | ✅ Complete | 100% | All command codes, IAC escaping, state machine |
| **855** | Telnet Option Specification | ✅ Complete | 100% | WILL/WONT/DO/DONT negotiation |
| **1143** | Q Method of Option Negotiation | ⚠️ Partial | 60% | Basic states implemented, queue bits missing |

### Implemented Telnet Options

| RFC | Option | Code | Status | Completion | Implementation |
|-----|--------|------|--------|------------|----------------|
| **857** | ECHO | 1 | ✅ Complete | 100% | Full TTY integration, local echo sync |
| **858** | SUPPRESS-GO-AHEAD | 3 | ✅ Complete | 100% | Disables half-duplex mode |
| **859** | STATUS | 5 | ⚠️ Defined | 10% | Option code exists, no handler |
| **860** | TIMING-MARK | 6 | ⚠️ Defined | 10% | Option code exists, no handler |
| **1091** | TERMINAL-TYPE | 24 | ✅ Complete | 100% | Full subnegotiation support |
| **1073** | NAWS | 31 | ✅ Complete | 100% | Dynamic window size updates via SIGWINCH |
| **1079** | TERMINAL-SPEED | 32 | ⚠️ Defined | 10% | Option code exists, no handler |
| **1372** | REMOTE-FLOW-CONTROL | 33 | ⚠️ Defined | 10% | Option code exists, no handler |
| **1184** | LINEMODE | 34 | ⚠️ Partial | 40% | MODE/FORWARDMASK handlers, SLC constants defined |
| **1408** | ENVIRON (Old) | 36 | ⚠️ Defined | 10% | Option code exists, deprecated in favor of NEW-ENVIRON |
| **1572** | NEW-ENVIRON | 39 | ✅ Complete | 100% | Full subnegotiation, security allowlist |

### Missing Common Options

| RFC | Option | Code | Priority | Notes |
|-----|--------|------|----------|-------|
| **856** | BINARY | 0 | Medium | Enables 8-bit clean transmission |
| **2946** | ENCRYPT | 38 | Low | Encryption support (less relevant with TLS) |
| **2941** | AUTHENTICATION | 37 | Low | Authentication mechanisms |
| **2066** | CHARSET | 42 | Low | Character set negotiation |

---

## Detailed Implementation Status

### RFC 854: Telnet Protocol Specification ✅

**Implementation:** `src/protocol/telnet.zig`

#### Command Codes (All Implemented)
- **EOF (236)**: End of file ✅
- **SUSP (237)**: Suspend process ✅
- **ABORT (238)**: Abort process ✅
- **EOR (239)**: End of record ✅
- **SE (240)**: Subnegotiation end ✅
- **NOP (241)**: No operation ✅
- **DM (242)**: Data mark ✅
- **BRK (243)**: Break ✅
- **IP (244)**: Interrupt process ✅
- **AO (245)**: Abort output ✅
- **AYT (246)**: Are you there ✅
- **EC (247)**: Erase character ✅
- **EL (248)**: Erase line ✅
- **GA (249)**: Go ahead ✅
- **SB (250)**: Subnegotiation begin ✅
- **WILL (251)**: Sender wants to enable option ✅
- **WONT (252)**: Sender wants to disable option ✅
- **DO (253)**: Sender wants receiver to enable option ✅
- **DONT (254)**: Sender wants receiver to disable option ✅
- **IAC (255)**: Interpret as command ✅

#### IAC Byte Escaping ✅
- **Implementation:** `processOutput()` in telnet_processor.zig:211-215
- **Rule:** Data byte 255 → IAC IAC (255, 255)
- **Applies to:** Normal data and subnegotiation data
- **Tests:** Covered in processor tests

#### State Machine ✅
- **Implementation:** `validateStateTransition()` in telnet.zig:102-134
- **States:** DATA, IAC, WILL, WONT, DO, DONT, SB, SB_DATA, SB_IAC
- **Validation:** Every state transition checked before processing
- **Error handling:** Returns `TelnetError.InvalidStateTransition` on violation

#### Gaps
- **TCP Urgent Data (Synch Signal)**: ⚠️ Partial
  - DM command defined but no platform-specific urgent data handling
  - Estimated effort: 50-75 lines (platform-dependent)

---

### RFC 855: Telnet Option Specification ✅

**Implementation:** `src/protocol/telnet_processor.zig`

#### Negotiation Commands
- **WILL/WONT/DO/DONT**: Fully implemented ✅
- **Response generation**: Automatic via OptionHandlerRegistry ✅
- **Loop prevention**: Negotiation count tracking (MAX_NEGOTIATION_ATTEMPTS = 10) ✅

#### Negotiation Rules
- **Asymmetric options**: Supported ✅
- **Default state**: All options start as NO ✅
- **Response required**: Every request generates response ✅

---

### RFC 1143: Q Method ⚠️ Partial (60%)

**Implementation:** `src/protocol/telnet_processor.zig:25-59`

#### Implemented
- ✅ Four basic states: NO, YES, WANTNO, WANTYES
- ✅ Loop prevention via negotiation counting
- ✅ State transitions on WILL/WONT/DO/DONT

#### Missing
- ❌ Queue bits (EMPTY/OPPOSITE)
  - Cannot queue contradictory option requests
  - Simpler negotiation count approach used instead
- ❌ Full state machine with 8 states (NO, YES, WANTNO-EMPTY, WANTNO-OPPOSITE, WANTYES-EMPTY, WANTYES-OPPOSITE)

#### Rationale for Partial Implementation
For zigcat's use case (controlled client/server scenarios), negotiation counting is sufficient. Full Q-Method is complex and overkill for most Telnet implementations. Can be added later if needed.

**Estimated effort to complete:** 100-150 lines

---

### RFC 857: ECHO Option ✅ Complete

**Implementation:** `src/protocol/telnet_options.zig:25-80`

#### Features
- ✅ Client/server echo negotiation
- ✅ TTY integration (`termios` ECHO flag control)
- ✅ Automatic local echo toggling based on remote WILL/WONT
- ✅ No double-echo issues

#### Typical Flow
1. Server sends `IAC WILL ECHO` → client disables local echo
2. Client sends `IAC DO ECHO` → acknowledges server echo
3. Server sends `IAC WONT ECHO` → client enables local echo

---

### RFC 858: SUPPRESS-GO-AHEAD ✅ Complete

**Implementation:** `src/protocol/telnet_options.zig:453-490`

#### Features
- ✅ Disables half-duplex mode (go-ahead signals)
- ✅ Standard negotiation handlers
- ✅ Typically enabled in both directions for full-duplex

---

### RFC 1091: TERMINAL-TYPE ✅ Complete

**Implementation:** `src/protocol/telnet_options.zig:82-162`

#### Features
- ✅ Subnegotiation support (SEND/IS commands)
- ✅ Configurable terminal type (default: "UNKNOWN")
- ✅ Standard negotiation handlers

#### Subnegotiation Format
```
Client ← Server: IAC SB TERMINAL-TYPE SEND IAC SE
Client → Server: IAC SB TERMINAL-TYPE IS "xterm" IAC SE
```

---

### RFC 1073: NAWS (Negotiate About Window Size) ✅ Complete

**Implementation:** `src/protocol/telnet_options.zig:164-255`

#### Features
- ✅ Dynamic window size updates via SIGWINCH (POSIX only)
- ✅ 16-bit big-endian width/height encoding
- ✅ IAC byte escaping in size values (if 255 appears)
- ✅ Automatic updates on terminal resize

#### Subnegotiation Format
```
Client → Server: IAC SB NAWS <width_hi> <width_lo> <height_hi> <height_lo> IAC SE
```

**Example:** 80x24 terminal
```
IAC SB NAWS 0x00 0x50 0x00 0x18 IAC SE
```

#### Platform Support
- ✅ Linux/macOS/BSD: Full support via SIGWINCH handler
- ⚠️ Windows: Not yet implemented (TODO: use `GetConsoleScreenBufferInfo`)

---

### RFC 1572: NEW-ENVIRON ✅ Complete

**Implementation:**
- Constants: `src/protocol/telnet_environ.zig:3-12`
- Handler: `src/protocol/telnet_options.zig:257-451`

#### Features
- ✅ Environment variable subnegotiation (IS/SEND/INFO)
- ✅ Security allowlist (TERM, USER, LANG, LC_ALL, COLORTERM, DISPLAY, SYSTEMTYPE)
- ✅ Variable escaping (IAC, ESC, control codes)
- ✅ USERVAR support for custom variables

#### Command Codes
- **IS (0)**: Send environment variables to peer
- **SEND (1)**: Request environment variables from peer
- **INFO (2)**: Informational update

#### Type Codes
- **VAR (0)**: Well-known variable
- **VALUE (1)**: Value follows
- **ESC (2)**: Escape character
- **USERVAR (3)**: User-defined variable

#### Subnegotiation Format
```
IAC SB NEW-ENVIRON IS VAR "USER" VALUE "joe" VAR "TERM" VALUE "xterm" IAC SE
```

#### Security Allowlist
Only these variables are sent (never credentials, tokens, or paths):
- `TERM` (terminal type)
- `USER` (username)
- `LANG` (locale)
- `LC_ALL` (locale override)
- `COLORTERM` (color support)
- `DISPLAY` (X11 display)
- `SYSTEMTYPE` (OS type)

**Location:** `ALLOWED_VARS` in `src/protocol/telnet_options.zig:263-271`

---

### RFC 1184: LINEMODE ⚠️ Partial (40%)

**Implementation:** `src/protocol/telnet_options.zig:492-694`

#### Implemented
- ✅ MODE subnegotiation (EDIT, TRAPSIG, MODE_ACK, SOFT_TAB, LIT_ECHO flags)
- ✅ FORWARDMASK subnegotiation (echo back acknowledgment)
- ✅ All 30 SLC (Special Line Character) function codes defined
- ✅ All SLC modifier flags defined (NOSUPPORT, CANTCHANGE, VALUE, DEFAULT, ACK, FLUSH)

#### Missing
- ❌ SLC handler implementation (currently stub at line 593-595)
- ❌ Mapping termios special characters to SLC codes
- ❌ Local line editing buffer
- ❌ Character forwarding logic

#### SLC Function Codes (30 total)
**Control Functions (1-9):**
- SLC_SYNCH, SLC_BRK, SLC_IP, SLC_AO, SLC_AYT, SLC_EOR, SLC_ABORT, SLC_EOF, SLC_SUSP

**Editing Functions (10-18):**
- SLC_EC, SLC_EL, SLC_EW, SLC_RP, SLC_LNEXT, SLC_XON, SLC_XOFF, SLC_FORW1, SLC_FORW2

**Cursor Movement (19-30):**
- SLC_MCL, SLC_MCR, SLC_MCWL, SLC_MCWR, SLC_MCBOL, SLC_MCEOL, SLC_INSRT, SLC_OVER, SLC_ECR, SLC_EWR, SLC_EBOL, SLC_EEOL

#### SLC Triplet Structure
Each SLC is 3 bytes:
1. **Function code** (1-30)
2. **Modifier byte**: Level bits + flags
   - Level: NOSUPPORT(0), CANTCHANGE(1), VALUE(2), DEFAULT(3)
   - Flags: SLC_ACK(0x80), SLC_FLUSHIN(0x40), SLC_FLUSHOUT(0x20)
3. **ASCII character value**

**Estimated effort to complete SLC:** 300-400 lines

---

## Code Organization

### File Structure
```
src/protocol/
├── telnet.zig              # Core enums, validation, RFC 854/855 definitions
├── telnet_processor.zig    # State machine, option negotiation (RFC 1143)
├── telnet_connection.zig   # High-level connection wrapper
├── telnet_options.zig      # Option-specific handlers (RFC 857/858/1091/1073/1184/1572)
└── telnet_environ.zig      # NEW-ENVIRON helpers (RFC 1572)
```

### Key Constants
- **MAX_SUBNEGOTIATION_LENGTH**: 1024 bytes (telnet_processor.zig:73)
- **MAX_NEGOTIATION_ATTEMPTS**: 10 (telnet_processor.zig:74)
- **MAX_PARTIAL_BUFFER_SIZE**: 16 bytes (telnet_processor.zig:75)
- **BUFFER_SIZE**: 4096 bytes (telnet_connection.zig:39)

### Testing
- **Unit tests:** Coverage in `tests/` directory
- **Integration tests:** Manual testing with `bbs.fozztexx.com`, `telehack.com`
- **Fuzzing:** Window resize stress testing (TELNET_TODO.md:373-380)

---

## Security Considerations

### IAC Byte Escaping
- **Prevents:** Command injection in data streams
- **Implementation:** Automatic in `processOutput()` (telnet_processor.zig:210-218)
- **Rule:** Every 0xFF in application data → 0xFF 0xFF on wire

### NEW-ENVIRON Allowlist
- **Prevents:** Credential leakage (passwords, tokens, API keys)
- **Implementation:** `ALLOWED_VARS` filter (telnet_options.zig:263-271)
- **Sent BEFORE authentication:** Variables are transmitted before credentials

### Negotiation Loop Prevention
- **Prevents:** Infinite negotiation cycles (denial of service)
- **Implementation:** `negotiation_count` tracking (telnet_processor.zig:360-364)
- **Limit:** 10 attempts per option (MAX_NEGOTIATION_ATTEMPTS)

### Subnegotiation Length Limit
- **Prevents:** Buffer overflow attacks
- **Implementation:** Check before appending (telnet_processor.zig:304-307)
- **Limit:** 1024 bytes (MAX_SUBNEGOTIATION_LENGTH)

---

## Platform Compatibility

| Feature | Linux | macOS | FreeBSD | Windows | Notes |
|---------|-------|-------|---------|---------|-------|
| Core Protocol (RFC 854) | ✅ | ✅ | ✅ | ✅ | Full support |
| ECHO (termios) | ✅ | ✅ | ✅ | ⚠️ | Windows has limited termios |
| NAWS (SIGWINCH) | ✅ | ✅ | ✅ | ❌ | Windows needs `GetConsoleScreenBufferInfo` |
| NEW-ENVIRON | ✅ | ✅ | ✅ | ✅ | Platform-independent |
| LINEMODE | ⚠️ | ⚠️ | ⚠️ | ⚠️ | Partial on all platforms |

---

## Future Work & Roadmap

### Phase 1: Complete LINEMODE SLC (Priority: LOW)
**Estimated effort:** 300-400 lines, 2-3 weeks

- Implement SLC subnegotiation handler
- Map termios special characters to SLC codes
- Add local line editing buffer
- Implement character forwarding

**Blocker:** Low priority, most modern terminals handle editing locally

### Phase 2: Full RFC 1143 Q-Method (Priority: MEDIUM)
**Estimated effort:** 100-150 lines, 1 week

- Add queue bits (EMPTY/OPPOSITE) to OptionState
- Implement 8-state machine
- More precise loop handling

**Blocker:** Current negotiation counting works well for zigcat's use case

### Phase 3: Additional Options (Priority: LOW)
**Estimated effort:** 50-100 lines per option

- BINARY (RFC 856): 8-bit clean transmission
- CHARSET (RFC 2066): Character set negotiation
- ENCRYPT (RFC 2946): Encryption (less relevant with TLS)

**Blocker:** Low demand, TLS provides encryption

### Phase 4: Windows NAWS Support (Priority: MEDIUM)
**Estimated effort:** 50-75 lines

- Implement `GetConsoleScreenBufferInfo` polling or event handling
- Mirror POSIX SIGWINCH approach

---

## Testing Strategy

### Unit Tests
- ✅ State machine transitions (`telnet.zig` validation)
- ✅ IAC byte escaping (processor tests)
- ✅ Option negotiation state updates
- ✅ NEW-ENVIRON escaping and parsing
- ✅ NAWS encoding/decoding

### Integration Tests
- ✅ Manual: `bbs.fozztexx.com` (public BBS)
- ✅ Manual: `telehack.com` (interactive Telnet server)
- ✅ Manual: `towel.blinkenlights.nl` (Star Wars ANSI test)
- ⚠️ Automated: PTY-based testing (TODO in TELNET_TODO.md:348-362)

### Fuzzing
- ⚠️ Window resize stress test (TELNET_TODO.md:373-380)
- ⚠️ Malformed subnegotiation sequences
- ⚠️ Negotiation loop edge cases

---

## References

### RFCs (Hyperlinked)
- [RFC 854: Telnet Protocol Specification](https://www.rfc-editor.org/rfc/rfc854)
- [RFC 855: Telnet Option Specification](https://www.rfc-editor.org/rfc/rfc855)
- [RFC 857: Telnet ECHO Option](https://www.rfc-editor.org/rfc/rfc857)
- [RFC 858: Telnet SUPPRESS-GO-AHEAD Option](https://www.rfc-editor.org/rfc/rfc858)
- [RFC 859: Telnet STATUS Option](https://www.rfc-editor.org/rfc/rfc859)
- [RFC 860: Telnet TIMING-MARK Option](https://www.rfc-editor.org/rfc/rfc860)
- [RFC 1073: Telnet Window Size Option (NAWS)](https://www.rfc-editor.org/rfc/rfc1073)
- [RFC 1079: Telnet Terminal Speed Option](https://www.rfc-editor.org/rfc/rfc1079)
- [RFC 1091: Telnet Terminal-Type Option](https://www.rfc-editor.org/rfc/rfc1091)
- [RFC 1143: The Q Method of Implementing Telnet Option Negotiation](https://www.rfc-editor.org/rfc/rfc1143)
- [RFC 1184: Telnet Linemode Option](https://www.rfc-editor.org/rfc/rfc1184)
- [RFC 1372: Telnet Remote Flow Control Option](https://www.rfc-editor.org/rfc/rfc1372)
- [RFC 1408: Telnet Environment Option (Old ENVIRON)](https://www.rfc-editor.org/rfc/rfc1408)
- [RFC 1572: Telnet Environment Option (NEW-ENVIRON)](https://www.rfc-editor.org/rfc/rfc1572)

### Related Documentation
- **TELNET_TODO.md**: Implementation roadmap and task tracking
- **src/protocol/telnet.zig**: Core RFC 854/855 documentation
- **src/protocol/telnet_processor.zig**: Q-Method implementation notes

### External Resources
- [IANA Telnet Options Registry](https://www.iana.org/assignments/telnet-options/telnet-options.xhtml)
- [Build Your Own Text Editor (termios guide)](https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html)
- [Playing with SIGWINCH](https://www.rkoucha.fr/tech_corner/sigwinch.html)
- [vt100.net (Parser design)](https://vt100.net/)

---

## Changelog

### 2025-01-17
- Initial RFC compliance documentation created
- Documented all implemented RFCs (854, 855, 857, 858, 1091, 1073, 1572)
- Documented partial RFC 1143 Q-Method implementation
- Added SLC constants documentation for RFC 1184
- Added security considerations and platform compatibility matrix

---

**Document Version:** 1.0
**Maintained by:** Zigcat Telnet Implementation Team
**Last Reviewed:** 2025-01-17
