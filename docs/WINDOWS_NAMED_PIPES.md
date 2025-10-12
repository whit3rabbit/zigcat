# Windows Named Pipes Implementation Guide for Zig

This document provides a comprehensive reference for implementing Windows Named Pipes as a fallback for Unix domain sockets on older Windows systems (pre-Windows 10 RS4).

**Target Zig Version:** 0.15.1

## Overview

Windows Named Pipes provide inter-process communication (IPC) similar to Unix domain sockets. They are essential for compatibility with older Windows versions that lack AF_UNIX support.

**Key Differences from Unix Sockets:**
- Named pipes are **not** filesystem objects (cannot use regular file APIs)
- Pipes live in a special `\\.\pipe\` namespace
- Use dedicated Named Pipe APIs instead of standard socket APIs
- Server must explicitly call `ConnectNamedPipe()` after creation
- Security configured via `SECURITY_ATTRIBUTES` instead of file permissions

---

## 1. Zig Standard Library APIs

### 1.1 Available in std.os.windows (Zig 0.15.1)

#### CreateNamedPipeW

```zig
pub extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;
```

**Returns:** `HANDLE` to pipe instance on success, `INVALID_HANDLE_VALUE` on failure

**Parameters:**
- `lpName`: Pipe name in format `\\.\pipe\<name>` (UTF-16 encoded)
- `dwOpenMode`: Access mode (`PIPE_ACCESS_DUPLEX`, `PIPE_ACCESS_INBOUND`, `PIPE_ACCESS_OUTBOUND`)
- `dwPipeMode`: Pipe type, read mode, wait mode (OR'd together)
- `nMaxInstances`: Max pipe instances (1-255, or `PIPE_UNLIMITED_INSTANCES`)
- `nOutBufferSize`: Output buffer size in bytes
- `nInBufferSize`: Input buffer size in bytes
- `nDefaultTimeOut`: Default timeout in milliseconds (0 = 50ms default)
- `lpSecurityAttributes`: Optional security descriptor (use null for default)

**Common Errors:**
- `ERROR_ACCESS_DENIED`: Insufficient permissions
- `ERROR_INVALID_PARAMETER`: Invalid flag combination or parameters

#### CreateFileW (for Named Pipe Clients)

```zig
pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
```

**Client Connection Parameters:**
- `lpFileName`: Pipe name `\\.\pipe\<name>`
- `dwDesiredAccess`: `GENERIC_READ | GENERIC_WRITE`
- `dwShareMode`: `FILE_SHARE_READ | FILE_SHARE_WRITE`
- `dwCreationDisposition`: `OPEN_EXISTING` (must already exist)
- `dwFlagsAndAttributes`: Usually 0 or `FILE_FLAG_OVERLAPPED`

**Returns:** `INVALID_HANDLE_VALUE` on error, use `GetLastError()`

#### ReadFile / WriteFile

```zig
pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
```

**Note:** For synchronous I/O, pass `null` for `lpOverlapped`.

### 1.2 Missing APIs (Need Manual Declaration)

**CRITICAL:** These APIs are **not** in Zig 0.15.1 stdlib. You must declare them yourself:

#### ConnectNamedPipe

```zig
pub extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(windows.WINAPI) windows.BOOL;
```

**Behavior:**
- Waits for a client to connect to the pipe instance
- **Must be called after `CreateNamedPipeW`** before I/O can occur
- Returns `TRUE` on success, `FALSE` on error
- **Special case:** If client already connected, returns `FALSE` with `ERROR_PIPE_CONNECTED` (this is success!)

**Error Handling:**
```zig
if (ConnectNamedPipe(pipe_handle, null) == 0) {
    const err = windows.kernel32.GetLastError();
    switch (err) {
        .PIPE_CONNECTED => {}, // Client already connected, OK!
        .NO_DATA => return error.PreviousClientNotDisconnected,
        else => return error.ConnectFailed,
    }
}
```

#### DisconnectNamedPipe

```zig
pub extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(windows.WINAPI) windows.BOOL;
```

**Behavior:**
- Disconnects the server end from the client
- **Required before reusing a pipe handle** with `ConnectNamedPipe()`
- Does **not** close the handle (use `CloseHandle` for that)
- Returns `TRUE` on success, `FALSE` on error

**Usage Pattern:**
```zig
// Accept first client
try ConnectNamedPipe(pipe, null);
// ... handle client ...

// Reuse pipe for next client
if (DisconnectNamedPipe(pipe) == 0) return error.DisconnectFailed;
try ConnectNamedPipe(pipe, null); // Ready for next client
```

#### PeekNamedPipe

```zig
pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: windows.DWORD,
    lpBytesRead: ?*windows.DWORD,
    lpTotalBytesAvail: ?*windows.DWORD,
    lpBytesLeftThisMessage: ?*windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;
```

**Behavior:**
- Copies data from pipe **without removing it**
- Returns immediately (non-blocking)
- Useful for checking if data is available before blocking on `ReadFile()`

**Example:**
```zig
var bytes_avail: windows.DWORD = 0;
if (PeekNamedPipe(pipe, null, 0, null, &bytes_avail, null) == 0) {
    return error.PeekFailed;
}
if (bytes_avail > 0) {
    // Data available, safe to read
}
```

#### GetNamedPipeInfo

```zig
pub extern "kernel32" fn GetNamedPipeInfo(
    hNamedPipe: windows.HANDLE,
    lpFlags: ?*windows.DWORD,
    lpOutBufferSize: ?*windows.DWORD,
    lpInBufferSize: ?*windows.DWORD,
    lpMaxInstances: ?*windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;
```

**Behavior:**
- Retrieves pipe configuration (type, buffer sizes, max instances)
- Pass `null` for any parameter you don't need

---

## 2. Named Pipe Configuration Structures

### 2.1 SECURITY_ATTRIBUTES

```zig
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: windows.DWORD,
    lpSecurityDescriptor: ?windows.LPVOID,
    bInheritHandle: windows.BOOL,
};
```

**Usage:**
```zig
var sa = windows.SECURITY_ATTRIBUTES{
    .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = null, // Use default (calling process's access token)
    .bInheritHandle = windows.FALSE, // Don't inherit handle
};
```

**For Restrictive Security (see Section 4):**
```zig
var sa = windows.SECURITY_ATTRIBUTES{
    .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = &custom_security_descriptor, // Owner-only access
    .bInheritHandle = windows.FALSE,
};
```

### 2.2 Pipe Mode Flags (dwOpenMode)

**Available in Zig std.os.windows:**

```zig
// Access modes (mutually exclusive, OR with flags below)
pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;    // Bidirectional
pub const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;   // Server reads, client writes
pub const PIPE_ACCESS_OUTBOUND: DWORD = 0x00000002;  // Server writes, client reads

// Flags (OR with access mode above)
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000; // Fail if pipe already exists
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;          // Async I/O
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;    // Local connections only
```

**Recommended for Zigcat:**
```zig
const open_mode = windows.PIPE_ACCESS_DUPLEX |
                  windows.PIPE_REJECT_REMOTE_CLIENTS |
                  windows.FILE_FLAG_FIRST_PIPE_INSTANCE;
```

### 2.3 Pipe Type Flags (dwPipeMode)

**Available in Zig std.os.windows:**

```zig
// Pipe type (mutually exclusive)
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;    // Byte stream (like TCP)
pub const PIPE_TYPE_MESSAGE: DWORD = 0x00000004; // Message boundaries

// Read mode (mutually exclusive)
pub const PIPE_READMODE_BYTE: DWORD = 0x00000000;    // Byte-oriented reads
pub const PIPE_READMODE_MESSAGE: DWORD = 0x00000002; // Message-oriented reads

// Wait mode (mutually exclusive)
pub const PIPE_WAIT: DWORD = 0x00000000;   // Blocking mode (recommended)
pub const PIPE_NOWAIT: DWORD = 0x00000001; // Legacy non-blocking (don't use)
```

**CRITICAL:** Cannot combine `PIPE_TYPE_BYTE` with `PIPE_READMODE_MESSAGE` → `ERROR_INVALID_PARAMETER`

**Recommended for Zigcat:**
```zig
const pipe_mode = windows.PIPE_TYPE_BYTE |
                  windows.PIPE_READMODE_BYTE |
                  windows.PIPE_WAIT;
```

### 2.4 Buffer Sizes and Limits

```zig
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 0xFF; // 255 decimal
```

**Recommended Values:**
- `nMaxInstances`: `1` (for server socket equivalent) or `PIPE_UNLIMITED_INSTANCES`
- `nOutBufferSize`: `4096` to `65536` bytes (must not exceed nonpaged pool)
- `nInBufferSize`: `4096` to `65536` bytes
- `nDefaultTimeOut`: `0` (uses 50ms default) or custom value in milliseconds

**Example:**
```zig
const buffer_size = 8192; // 8KB buffers
const timeout_ms = 50;    // 50ms default timeout
```

---

## 3. Named Pipe Naming Convention

### 3.1 Windows Format

**Format:** `\\.\pipe\<pipename>` (local server) or `\\<ServerName>\pipe\<pipename>` (remote)

**Rules:**
- Use `.` for local server (most common)
- Pipe name can contain any character **except backslash**
- Names are **case-insensitive**
- Maximum length: **256 characters total** (including `\\.\pipe\`)
- No directory hierarchy (flat namespace)

### 3.2 Translating Unix Socket Paths

**Unix:** `/tmp/zigcat.sock`  
**Windows:** `\\.\pipe\zigcat`

**Translation Function:**
```zig
fn unixPathToNamedPipe(allocator: std.mem.Allocator, unix_path: []const u8) ![]u16 {
    // Extract filename without directory
    const basename = std.fs.path.basename(unix_path);
    
    // Remove .sock extension if present
    const name = if (std.mem.endsWith(u8, basename, ".sock"))
        basename[0 .. basename.len - 5]
    else
        basename;
    
    // Convert to Windows pipe path: \\.\pipe\<name>
    const pipe_path = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\{s}", .{name});
    defer allocator.free(pipe_path);
    
    // Convert to UTF-16 (Windows requires wide chars)
    return try std.unicode.utf8ToUtf16LeAlloc(allocator, pipe_path);
}
```

**Example:**
```zig
const unix_path = "/tmp/zigcat.sock";
const pipe_name = try unixPathToNamedPipe(allocator, unix_path);
defer allocator.free(pipe_name);
// Result: L"\\.\pipe\zigcat" (UTF-16)
```

### 3.3 Naming Best Practices

1. **Use simple names:** Avoid special characters besides `-` and `_`
2. **Prefix for namespacing:** `zigcat-<feature>` to avoid collisions
3. **No path separators:** Named pipes are flat, no `/` or `\`
4. **Case-insensitive:** `ZigCat` and `zigcat` are the same pipe
5. **Check for collisions:** Use `FILE_FLAG_FIRST_PIPE_INSTANCE` to detect conflicts

---

## 4. Security Configuration (Owner-Only Access)

**Goal:** Create Named Pipe with Unix `0o700` equivalent (owner-only read/write/execute)

### 4.1 Default Security (Insecure!)

**Default behavior when `lpSecurityAttributes = null`:**
- Full control: LocalSystem, Administrators, Creator Owner
- **Read access: Everyone group and Anonymous account** ← **Security risk!**

### 4.2 Restrictive DACL (Recommended)

**Windows APIs needed (NOT in Zig stdlib):**
```zig
pub extern "advapi32" fn InitializeSecurityDescriptor(
    pSecurityDescriptor: windows.PVOID,
    dwRevision: windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn SetSecurityDescriptorDacl(
    pSecurityDescriptor: windows.PVOID,
    bDaclPresent: windows.BOOL,
    pDacl: ?windows.PVOID, // NULL = deny all
    bDaclDefaulted: windows.BOOL,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: windows.HANDLE,
    TokenInformationClass: windows.DWORD,
    TokenInformation: ?windows.PVOID,
    TokenInformationLength: windows.DWORD,
    ReturnLength: *windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;
```

**Constants:**
```zig
pub const SECURITY_DESCRIPTOR_REVISION: DWORD = 1;
pub const TokenUser: DWORD = 1; // For GetTokenInformation
```

### 4.3 Creating Owner-Only DACL

**Steps:**
1. Get current user's SID from process token
2. Initialize security descriptor
3. Create DACL granting full control to owner SID only
4. Pass to `CreateNamedPipeW()`

**Full Example (requires more Win32 APIs):**
```zig
fn createOwnerOnlySecurityAttributes(allocator: std.mem.Allocator) !windows.SECURITY_ATTRIBUTES {
    // 1. Get current process token
    var token: windows.HANDLE = undefined;
    if (windows.kernel32.OpenProcessToken(
        windows.kernel32.GetCurrentProcess(),
        windows.TOKEN_QUERY,
        &token,
    ) == 0) return error.OpenProcessTokenFailed;
    defer _ = windows.kernel32.CloseHandle(token);
    
    // 2. Get user SID from token (requires TOKEN_USER structure and GetTokenInformation)
    // ... (complex Win32 code omitted for brevity) ...
    
    // 3. Build DACL with single ACE granting GENERIC_ALL to owner SID
    // ... (requires InitializeAcl, AddAccessAllowedAce) ...
    
    // 4. Initialize security descriptor
    var sd = try allocator.alloc(u8, @sizeOf(windows.SECURITY_DESCRIPTOR));
    if (InitializeSecurityDescriptor(sd.ptr, SECURITY_DESCRIPTOR_REVISION) == 0) {
        return error.InitSecurityDescriptorFailed;
    }
    
    // 5. Set DACL
    if (SetSecurityDescriptorDacl(sd.ptr, windows.TRUE, dacl.ptr, windows.FALSE) == 0) {
        return error.SetDaclFailed;
    }
    
    return windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = sd.ptr,
        .bInheritHandle = windows.FALSE,
    };
}
```

### 4.4 Simplified Approach (Medium Security)

**If full DACL creation is too complex, use:**
```zig
// Use FILE_FLAG_FIRST_PIPE_INSTANCE to prevent hijacking
const open_mode = windows.PIPE_ACCESS_DUPLEX |
                  windows.PIPE_REJECT_REMOTE_CLIENTS |
                  windows.FILE_FLAG_FIRST_PIPE_INSTANCE;

// Create with default security (less secure but functional)
var sa = windows.SECURITY_ATTRIBUTES{
    .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
    .lpSecurityDescriptor = null,
    .bInheritHandle = windows.FALSE,
};
```

**Mitigations:**
- `PIPE_REJECT_REMOTE_CLIENTS`: Prevents remote access
- `FILE_FLAG_FIRST_PIPE_INSTANCE`: Fails if pipe name already exists (prevents hijacking)
- **Document security limitation:** Warn users that pipe has broader permissions than Unix socket

---

## 5. Server-Client Flow

### 5.1 Server: Accept Loop

```zig
const std = @import("std");
const windows = std.os.windows;

// 1. Create named pipe
const pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zigcat");

const pipe_handle = windows.kernel32.CreateNamedPipeW(
    pipe_name,
    windows.PIPE_ACCESS_DUPLEX | windows.PIPE_REJECT_REMOTE_CLIENTS,
    windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE | windows.PIPE_WAIT,
    windows.PIPE_UNLIMITED_INSTANCES, // Allow multiple clients
    8192, // Out buffer
    8192, // In buffer
    0,    // Default timeout (50ms)
    null, // Default security (use custom SECURITY_ATTRIBUTES for production!)
);

if (pipe_handle == windows.INVALID_HANDLE_VALUE) {
    return error.CreatePipeFailed;
}
defer _ = windows.kernel32.CloseHandle(pipe_handle);

// 2. Wait for client connection
if (ConnectNamedPipe(pipe_handle, null) == 0) {
    const err = windows.kernel32.GetLastError();
    if (err != .PIPE_CONNECTED) { // ERROR_PIPE_CONNECTED means client already connected (OK)
        return error.ConnectFailed;
    }
}

// 3. Perform I/O
var buffer: [1024]u8 = undefined;
var bytes_read: windows.DWORD = 0;

if (windows.kernel32.ReadFile(
    pipe_handle,
    &buffer,
    buffer.len,
    &bytes_read,
    null,
) == 0) {
    return error.ReadFailed;
}

std.debug.print("Read {d} bytes: {s}\n", .{ bytes_read, buffer[0..bytes_read] });

// 4. Disconnect (if keep-alive mode)
if (DisconnectNamedPipe(pipe_handle) == 0) {
    return error.DisconnectFailed;
}

// 5. Loop: Go back to step 2 to accept next client
```

### 5.2 Client: Connect and Send

```zig
const std = @import("std");
const windows = std.os.windows;

// 1. Connect to named pipe
const pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\zigcat");

const pipe_handle = windows.kernel32.CreateFileW(
    pipe_name,
    windows.GENERIC_READ | windows.GENERIC_WRITE,
    0, // No sharing
    null, // Default security
    windows.OPEN_EXISTING,
    0, // Synchronous I/O
    null,
);

if (pipe_handle == windows.INVALID_HANDLE_VALUE) {
    const err = windows.kernel32.GetLastError();
    if (err == .PIPE_BUSY) {
        // All instances busy, wait for one
        if (WaitNamedPipeW(pipe_name, 5000) == 0) { // 5 second timeout
            return error.PipeTimeout;
        }
        // Retry CreateFileW after wait...
    }
    return error.ConnectFailed;
}
defer _ = windows.kernel32.CloseHandle(pipe_handle);

// 2. Write data
const message = "Hello from client!";
var bytes_written: windows.DWORD = 0;

if (windows.kernel32.WriteFile(
    pipe_handle,
    message.ptr,
    @intCast(message.len),
    &bytes_written,
    null,
) == 0) {
    return error.WriteFailed;
}
```

### 5.3 Handling ERROR_PIPE_BUSY

**Client-side retry logic:**
```zig
pub extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: windows.LPCWSTR,
    nTimeOut: windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

const NMPWAIT_USE_DEFAULT_WAIT: windows.DWORD = 0x00000000;
const NMPWAIT_WAIT_FOREVER: windows.DWORD = 0xFFFFFFFF;

fn connectWithRetry(pipe_name: [*:0]const u16, timeout_ms: u32) !windows.HANDLE {
    var retries: u32 = 0;
    const max_retries: u32 = 3;
    
    while (retries < max_retries) : (retries += 1) {
        const handle = windows.kernel32.CreateFileW(
            pipe_name,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            0,
            null,
        );
        
        if (handle != windows.INVALID_HANDLE_VALUE) {
            return handle;
        }
        
        const err = windows.kernel32.GetLastError();
        if (err == .PIPE_BUSY) {
            // Wait for pipe to become available
            if (WaitNamedPipeW(pipe_name, timeout_ms) == 0) {
                return error.PipeTimeout;
            }
            // Retry CreateFileW
            continue;
        }
        
        return error.ConnectFailed;
    }
    
    return error.MaxRetriesExceeded;
}
```

---

## 6. Error Handling

### 6.1 Common Error Codes

```zig
// Add these to your error enum or handle directly via GetLastError()

pub const ERROR_PIPE_BUSY: windows.Win32Error = .PIPE_BUSY;         // 231 (0xE7)
pub const ERROR_PIPE_CONNECTED: windows.Win32Error = .PIPE_CONNECTED; // 535 (0x217)
pub const ERROR_NO_DATA: windows.Win32Error = .NO_DATA;             // 232 (0xE8)
pub const ERROR_BROKEN_PIPE: windows.Win32Error = .BROKEN_PIPE;     // 109 (0x6D)
pub const ERROR_PIPE_NOT_CONNECTED: windows.Win32Error = .PIPE_NOT_CONNECTED; // 233 (0xE9)
```

### 6.2 Error Scenarios

| **Error** | **Cause** | **Solution** |
|-----------|-----------|--------------|
| `ERROR_PIPE_BUSY` | All pipe instances in use | Call `WaitNamedPipeW()`, then retry |
| `ERROR_PIPE_CONNECTED` | Client already connected when calling `ConnectNamedPipe()` | **Not an error!** Continue with I/O |
| `ERROR_NO_DATA` | Pipe closing or previous client didn't disconnect | Call `DisconnectNamedPipe()` before reconnecting |
| `ERROR_BROKEN_PIPE` | Other end closed connection | Close handle, treat as EOF |
| `ERROR_PIPE_NOT_CONNECTED` | I/O attempted before `ConnectNamedPipe()` | Call `ConnectNamedPipe()` first |

### 6.3 Example Error Handling

```zig
fn handlePipeError(err: windows.Win32Error) error{PipeBusy, PipeClosing, Disconnected}!void {
    switch (err) {
        .PIPE_BUSY => return error.PipeBusy,
        .NO_DATA, .BROKEN_PIPE => return error.Disconnected,
        .PIPE_NOT_CONNECTED => return error.PipeClosing,
        else => {
            std.log.err("Unexpected pipe error: {}", .{err});
            return error.Disconnected;
        },
    }
}
```

---

## 7. Integration with Zigcat

### 7.1 Platform Detection

```zig
const builtin = @import("builtin");

pub fn supportsUnixSockets() bool {
    if (builtin.os.tag != .windows) return true;
    
    // Windows 10 RS4 (Build 17134) and later support AF_UNIX
    const version = std.os.windows.GetVersion();
    const build = (version >> 16) & 0xFFFF;
    return build >= 17134;
}

pub fn shouldUseNamedPipes() bool {
    return builtin.os.tag == .windows and !supportsUnixSockets();
}
```

### 7.2 Unified Socket Abstraction

```zig
pub const UnixSocketHandle = union(enum) {
    unix_socket: std.posix.socket_t,
    named_pipe: std.os.windows.HANDLE,
    
    pub fn init(path: []const u8, is_server: bool) !UnixSocketHandle {
        if (shouldUseNamedPipes()) {
            // Windows Named Pipe path
            const pipe_name = try unixPathToNamedPipe(allocator, path);
            defer allocator.free(pipe_name);
            
            if (is_server) {
                const handle = windows.kernel32.CreateNamedPipeW(
                    pipe_name.ptr,
                    windows.PIPE_ACCESS_DUPLEX | windows.PIPE_REJECT_REMOTE_CLIENTS,
                    windows.PIPE_TYPE_BYTE | windows.PIPE_WAIT,
                    windows.PIPE_UNLIMITED_INSTANCES,
                    8192, 8192, 0, null,
                );
                if (handle == windows.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
                return .{ .named_pipe = handle };
            } else {
                // Client connection logic
                // ...
            }
        } else {
            // Unix socket path
            const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
            // ... bind/connect logic ...
            return .{ .unix_socket = sock };
        }
    }
    
    pub fn read(self: UnixSocketHandle, buffer: []u8) !usize {
        return switch (self) {
            .unix_socket => |sock| try std.posix.read(sock, buffer),
            .named_pipe => |pipe| blk: {
                var bytes_read: windows.DWORD = 0;
                if (windows.kernel32.ReadFile(pipe, buffer.ptr, @intCast(buffer.len), &bytes_read, null) == 0) {
                    return error.ReadFailed;
                }
                break :blk @intCast(bytes_read);
            },
        };
    }
    
    pub fn write(self: UnixSocketHandle, data: []const u8) !usize {
        return switch (self) {
            .unix_socket => |sock| try std.posix.write(sock, data),
            .named_pipe => |pipe| blk: {
                var bytes_written: windows.DWORD = 0;
                if (windows.kernel32.WriteFile(pipe, data.ptr, @intCast(data.len), &bytes_written, null) == 0) {
                    return error.WriteFailed;
                }
                break :blk @intCast(bytes_written);
            },
        };
    }
    
    pub fn close(self: UnixSocketHandle) void {
        switch (self) {
            .unix_socket => |sock| std.posix.close(sock),
            .named_pipe => |pipe| _ = windows.kernel32.CloseHandle(pipe),
        }
    }
};
```

### 7.3 Server Accept with Named Pipes

```zig
pub fn acceptConnection(server_handle: UnixSocketHandle) !UnixSocketHandle {
    return switch (server_handle) {
        .unix_socket => |sock| blk: {
            const client = try std.posix.accept(sock, null, null, 0);
            break :blk .{ .unix_socket = client };
        },
        .named_pipe => |pipe| blk: {
            // ConnectNamedPipe blocks until client connects
            if (ConnectNamedPipe(pipe, null) == 0) {
                const err = windows.kernel32.GetLastError();
                if (err != .PIPE_CONNECTED) {
                    return error.AcceptFailed;
                }
            }
            // Return same handle (Named Pipes reuse handle for I/O)
            break :blk .{ .named_pipe = pipe };
        },
    };
}
```

---

## 8. Important Caveats

### 8.1 Named Pipes vs Unix Sockets

| **Feature** | **Unix Sockets** | **Windows Named Pipes** |
|-------------|-----------------|------------------------|
| **Filesystem object** | Yes (can `ls`, `rm`) | No (virtual namespace) |
| **Permissions** | File mode bits (0o700) | SECURITY_ATTRIBUTES + DACL |
| **Accept semantics** | New FD per client | Reuse same HANDLE (after `DisconnectNamedPipe`) |
| **Listen queue** | Kernel-managed backlog | `nMaxInstances` limit |
| **Blocking connect** | `connect()` blocks | `CreateFileW()` fails with `ERROR_PIPE_BUSY`, use `WaitNamedPipeW()` |
| **Half-close** | Supported (`shutdown()`) | Not directly supported |
| **Poll/select** | Yes | Requires overlapped I/O + `WaitForMultipleObjects` |

### 8.2 Security Considerations

1. **Default permissions are too permissive:** Everyone can connect by default
2. **No filesystem visibility:** Can't use `ls` to see active pipes
3. **Use `PIPE_REJECT_REMOTE_CLIENTS`:** Prevents network access
4. **Use `FILE_FLAG_FIRST_PIPE_INSTANCE`:** Prevents name hijacking
5. **Document security differences:** Users should know Windows pipes are less secure than Unix 0o700 sockets

### 8.3 Performance Notes

- Named Pipes are **not zero-copy** like Unix sockets
- Overlapped I/O (async) recommended for high-throughput scenarios
- Buffer sizes matter: Too small = context switches, too large = wasted memory

### 8.4 Testing on Non-Windows Systems

**You cannot test Named Pipes on macOS/Linux!**  
- Consider using Wine (limited support)
- Set up Windows VM or use GitHub Actions Windows runners
- Mock the Named Pipe API for unit tests

---

## 9. Additional Resources

### Official Microsoft Documentation
- [Named Pipes Overview](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipes)
- [Named Pipe Security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [CreateNamedPipeW Reference](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createnamedpipew)

### Zig Resources
- [Zig Standard Library (windows.zig)](https://github.com/ziglang/zig/blob/master/lib/std/os/windows.zig)
- [zigwin32 (comprehensive Win32 bindings)](https://github.com/marlersoft/zigwin32)
- [Zig GitHub Issue #19047: Missing Named Pipe APIs](https://github.com/ziglang/zig/issues/19047)

### Implementation Examples
- [Windows Named Pipe Test (C)](https://gist.github.com/rprichard/8dd8ca134b39534b7da2733994aa07ba)
- [Zig Windows examples](https://ziglang.org/learn/samples/)

---

## 10. Summary Checklist

**Before implementing Named Pipes in Zigcat:**

- [ ] Declare missing APIs: `ConnectNamedPipe`, `DisconnectNamedPipe`, `WaitNamedPipeW`
- [ ] Implement `unixPathToNamedPipe()` translation function
- [ ] Create `UnixSocketHandle` union for abstraction
- [ ] Add platform detection (`supportsUnixSockets()`)
- [ ] Use `PIPE_REJECT_REMOTE_CLIENTS` for security
- [ ] Handle `ERROR_PIPE_BUSY` with `WaitNamedPipeW()` retry
- [ ] Treat `ERROR_PIPE_CONNECTED` as success (not error)
- [ ] Call `DisconnectNamedPipe()` before reusing handle
- [ ] Document security limitations (no 0o700 equivalent by default)
- [ ] Test on actual Windows system (VM or CI)

**Recommended flag combination:**
```zig
const open_mode = windows.PIPE_ACCESS_DUPLEX |
                  windows.PIPE_REJECT_REMOTE_CLIENTS |
                  windows.FILE_FLAG_FIRST_PIPE_INSTANCE;

const pipe_mode = windows.PIPE_TYPE_BYTE |
                  windows.PIPE_READMODE_BYTE |
                  windows.PIPE_WAIT;
```

---

**Document Version:** 1.0  
**Last Updated:** 2025-10-11  
**Target Zig Version:** 0.15.1
