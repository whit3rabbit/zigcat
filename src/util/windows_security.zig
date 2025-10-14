//! Windows security descriptor and ACL management for Unix domain sockets
//!
//! This module provides Windows-specific security functions for setting and validating
//! file permissions on Unix domain socket files using Windows ACLs (Access Control Lists)
//! instead of POSIX mode bits.
//!
//! Key concepts:
//! - SDDL: Security Descriptor Definition Language (string-based ACL representation)
//! - DACL: Discretionary Access Control List (who can access the resource)
//! - ACE: Access Control Entry (individual permission rule in DACL)
//! - SID: Security Identifier (unique ID for user/group)

const std = @import("std");
const builtin = @import("builtin");

// This module is Windows-only
comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_security.zig is Windows-only. Use POSIX permissions on other platforms.");
    }
}

const windows = std.os.windows;
const posix = std.posix;

// ============================================================================
// Windows API Type Definitions
// ============================================================================

pub const SECURITY_DESCRIPTOR = extern struct {
    Revision: windows.BYTE,
    Sbz1: windows.BYTE,
    Control: windows.WORD,
    Owner: ?*anyopaque,
    Group: ?*anyopaque,
    Sacl: ?*ACL,
    Dacl: ?*ACL,
};

pub const ACL = extern struct {
    AclRevision: windows.BYTE,
    Sbz1: windows.BYTE,
    AclSize: windows.WORD,
    AceCount: windows.WORD,
    Sbz2: windows.WORD,
};

pub const ACE_HEADER = extern struct {
    AceType: windows.BYTE,
    AceFlags: windows.BYTE,
    AceSize: windows.WORD,
};

pub const ACCESS_ALLOWED_ACE = extern struct {
    Header: ACE_HEADER,
    Mask: windows.DWORD,
    SidStart: windows.DWORD, // First DWORD of SID
};

// Security descriptor control flags
pub const SE_DACL_PRESENT: windows.WORD = 0x0004;
pub const SE_SELF_RELATIVE: windows.WORD = 0x8000;

// SDDL revision
pub const SDDL_REVISION_1: windows.DWORD = 1;

// Security information flags
pub const DACL_SECURITY_INFORMATION: windows.DWORD = 0x00000004;
pub const OWNER_SECURITY_INFORMATION: windows.DWORD = 0x00000001;
pub const GROUP_SECURITY_INFORMATION: windows.DWORD = 0x00000002;

// Object type for SetSecurityInfo
pub const SE_OBJECT_TYPE = enum(c_int) {
    SE_UNKNOWN_OBJECT_TYPE = 0,
    SE_FILE_OBJECT = 1,
    SE_SERVICE = 2,
    SE_PRINTER = 3,
    SE_REGISTRY_KEY = 4,
    SE_LMSHARE = 5,
    SE_KERNEL_OBJECT = 6,
    SE_WINDOW_OBJECT = 7,
    SE_DS_OBJECT = 8,
    SE_DS_OBJECT_ALL = 9,
    SE_PROVIDER_DEFINED_OBJECT = 10,
    SE_WMIGUID_OBJECT = 11,
    SE_REGISTRY_WOW64_32KEY = 12,
    SE_REGISTRY_WOW64_64KEY = 13,
};

// ACE types
pub const ACCESS_ALLOWED_ACE_TYPE: windows.BYTE = 0x00;
pub const ACCESS_DENIED_ACE_TYPE: windows.BYTE = 0x01;

// Well-known SIDs
pub const WELL_KNOWN_SID_TYPE = enum(c_int) {
    WinNullSid = 0,
    WinWorldSid = 1, // Everyone (S-1-1-0)
    WinLocalSid = 2,
    WinCreatorOwnerSid = 3,
    WinCreatorGroupSid = 4,
    WinNetworkSid = 5, // Network (S-1-5-2)
    WinBatchSid = 6,
    WinInteractiveSid = 7,
    WinAuthenticatedUserSid = 11, // Authenticated Users (S-1-5-11)
    WinBuiltinAdministratorsSid = 26, // Administrators (S-1-5-32-544)
    WinBuiltinUsersSid = 27, // Users (S-1-5-32-545)
    // ... many more
};

// ============================================================================
// Windows API Extern Declarations (advapi32.dll)
// ============================================================================

pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: [*:0]const u16,
    StringSDRevision: windows.DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn SetNamedSecurityInfoW(
    pObjectName: [*:0]const u16,
    ObjectType: SE_OBJECT_TYPE,
    SecurityInfo: windows.DWORD,
    psidOwner: ?*anyopaque,
    psidGroup: ?*anyopaque,
    pDacl: ?*ACL,
    pSacl: ?*ACL,
) callconv(windows.WINAPI) windows.DWORD;

pub extern "advapi32" fn GetNamedSecurityInfoW(
    pObjectName: [*:0]const u16,
    ObjectType: SE_OBJECT_TYPE,
    SecurityInfo: windows.DWORD,
    ppsidOwner: ?*?*anyopaque,
    ppsidGroup: ?*?*anyopaque,
    ppDacl: ?*?*ACL,
    ppSacl: ?*?*ACL,
    ppSecurityDescriptor: *?*anyopaque,
) callconv(windows.WINAPI) windows.DWORD;

pub extern "advapi32" fn GetSecurityDescriptorDacl(
    pSecurityDescriptor: *anyopaque,
    lpbDaclPresent: *windows.BOOL,
    pDacl: *?*ACL,
    lpbDaclDefaulted: *windows.BOOL,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn GetAce(
    pAcl: *ACL,
    dwAceIndex: windows.DWORD,
    pAce: *?*anyopaque,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn EqualSid(
    pSid1: *anyopaque,
    pSid2: *anyopaque,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn CreateWellKnownSid(
    WellKnownSidType: WELL_KNOWN_SID_TYPE,
    DomainSid: ?*anyopaque,
    pSid: *anyopaque,
    cbSid: *windows.DWORD,
) callconv(windows.WINAPI) windows.BOOL;

pub extern "advapi32" fn LocalFree(
    hMem: ?*anyopaque,
) callconv(windows.WINAPI) ?*anyopaque;

// ============================================================================
// SDDL (Security Descriptor Definition Language) Utilities
// ============================================================================

/// Common SDDL strings for Unix socket permissions
pub const SDDL = struct {
    /// Owner only (equivalent to chmod 700)
    /// System + Administrators get full access
    pub const OWNER_ONLY = "D:P(A;;GA;;;SY)(A;;GA;;;BA)";

    /// Owner + group (equivalent to chmod 770)
    /// System + Administrators get read/write/execute
    pub const OWNER_GROUP = "D:P(A;;GRGWGX;;;BA)(A;;GRGWGX;;;SY)";

    /// World readable (INSECURE - equivalent to chmod 777)
    /// Everyone gets full access
    pub const WORLD_ACCESS = "D:P(A;;GA;;;WD)";

    /// Default secure permissions for Unix sockets
    pub const DEFAULT = OWNER_ONLY;
};

/// Map Unix mode bits to Windows SDDL string
pub fn modeToSddl(mode: posix.mode_t) []const u8 {
    return switch (mode) {
        0o700 => SDDL.OWNER_ONLY,
        0o770 => SDDL.OWNER_GROUP,
        0o777 => SDDL.WORLD_ACCESS,
        else => SDDL.DEFAULT, // Default to secure permissions
    };
}

// ============================================================================
// Permission Setting Functions
// ============================================================================

/// Set Windows socket file permissions using SDDL string
///
/// This function applies a Windows ACL to a file using Security Descriptor
/// Definition Language (SDDL). SDDL is a string-based representation of
/// security descriptors.
///
/// Common SDDL strings:
/// - "D:P(A;;GA;;;WD)": Grant full access to Everyone (World)
/// - "D:P(A;;GA;;;BA)": Grant full access to Administrators only
/// - "D:P(A;;GRGWGX;;;WD)": Grant read/write/execute to Everyone
///
/// Arguments:
/// - socket_path: Path to the socket file (UTF-8)
/// - sddl_string: SDDL string defining permissions (UTF-8)
///
/// Returns: error on failure (ConvertSecurityDescriptorFailed, GetDaclFailed, SetSecurityInfoFailed)
pub fn setWindowsSocketPermissions(socket_path: []const u8, sddl_string: []const u8) !void {
    if (builtin.os.tag != .windows) return;

    const allocator = std.heap.page_allocator;

    // Convert UTF-8 path to UTF-16 (Windows wide string)
    const path_w = try std.unicode.utf8ToUtf16LeWithNull(allocator, socket_path);
    defer allocator.free(path_w);

    // Convert SDDL string to UTF-16
    const sddl_w = try std.unicode.utf8ToUtf16LeWithNull(allocator, sddl_string);
    defer allocator.free(sddl_w);

    // Convert SDDL string to security descriptor
    var sd: ?*anyopaque = null;
    const result = ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w.ptr,
        SDDL_REVISION_1,
        &sd,
        null,
    );

    if (result == 0) {
        return error.ConvertSecurityDescriptorFailed;
    }
    defer _ = LocalFree(sd);

    // Extract DACL from security descriptor
    var dacl_present: windows.BOOL = 0;
    var dacl: ?*ACL = null;
    var dacl_defaulted: windows.BOOL = 0;

    const dacl_result = GetSecurityDescriptorDacl(
        sd.?,
        &dacl_present,
        &dacl,
        &dacl_defaulted,
    );

    if (dacl_result == 0 or dacl_present == 0) {
        return error.GetDaclFailed;
    }

    // Apply DACL to socket file
    const set_result = SetNamedSecurityInfoW(
        path_w.ptr,
        .SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        null, // owner
        null, // group
        dacl,
        null, // SACL
    );

    if (set_result != 0) { // ERROR_SUCCESS = 0
        return error.SetSecurityInfoFailed;
    }
}

/// Set socket permissions using Unix mode (cross-platform wrapper)
///
/// On Unix: Uses chmod with mode bits
/// On Windows: Converts mode to SDDL and applies ACL
pub fn setSocketPermissions(socket_path: []const u8, mode: posix.mode_t) !void {
    if (builtin.os.tag == .windows) {
        const sddl = modeToSddl(mode);
        try setWindowsSocketPermissions(socket_path, sddl);
    } else {
        try posix.chmod(socket_path, mode);
    }
}

// ============================================================================
// Permission Validation Functions
// ============================================================================

/// Check if a SID represents a world-accessible group (Everyone, Network, Users)
fn isWorldAccessibleSid(sid: *anyopaque) bool {
    // Check against well-known insecure SIDs
    const insecure_sids = [_]WELL_KNOWN_SID_TYPE{
        .WinWorldSid, // Everyone (S-1-1-0)
        .WinNetworkSid, // Network (S-1-5-2)
        .WinAuthenticatedUserSid, // Authenticated Users (S-1-5-11)
        .WinBuiltinUsersSid, // Users (S-1-5-32-545)
    };

    for (insecure_sids) |sid_type| {
        var buffer: [128]u8 = undefined;
        var size: windows.DWORD = buffer.len;

        const result = CreateWellKnownSid(
            sid_type,
            null,
            &buffer,
            &size,
        );

        if (result != 0) {
            if (EqualSid(sid, &buffer) != 0) {
                return true;
            }
        }
    }

    return false;
}

/// Validate Windows socket file permissions
///
/// This function checks if a socket file has overly permissive ACL entries
/// that would allow unauthorized access (similar to checking for world-writable
/// permissions on Unix).
///
/// Returns:
/// - true if permissions are insecure (world-accessible)
/// - false if permissions are secure (owner-only or admin-only)
pub fn validateWindowsSocketPermissions(socket_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return false;

    const allocator = std.heap.page_allocator;

    // Convert UTF-8 path to UTF-16
    const path_w = try std.unicode.utf8ToUtf16LeWithNull(allocator, socket_path);
    defer allocator.free(path_w);

    // Get security descriptor with DACL
    var sd: ?*anyopaque = null;
    var dacl: ?*ACL = null;

    const result = GetNamedSecurityInfoW(
        path_w.ptr,
        .SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        null, // owner
        null, // group
        &dacl,
        null, // SACL
        &sd,
    );

    if (result != 0) { // ERROR_SUCCESS = 0
        return error.GetSecurityInfoFailed;
    }
    defer _ = LocalFree(sd);

    if (dacl == null) {
        // No DACL means everyone has full access (INSECURE!)
        return true;
    }

    // Enumerate ACEs in DACL
    const ace_count = dacl.?.AceCount;
    var i: windows.DWORD = 0;
    while (i < ace_count) : (i += 1) {
        var ace: ?*anyopaque = null;
        const ace_result = GetAce(dacl.?, i, &ace);

        if (ace_result == 0 or ace == null) continue;

        const header = @as(*ACE_HEADER, @ptrCast(@alignCast(ace.?)));

        // Check for ACCESS_ALLOWED_ACE (not ACCESS_DENIED)
        if (header.AceType == ACCESS_ALLOWED_ACE_TYPE) {
            const allowed_ace = @as(*ACCESS_ALLOWED_ACE, @ptrCast(@alignCast(ace.?)));
            const sid = @as(*anyopaque, @ptrCast(&allowed_ace.SidStart));

            // Check if this ACE grants access to world-accessible groups
            if (isWorldAccessibleSid(sid)) {
                return true; // INSECURE: World-accessible ACE found
            }
        }
    }

    return false; // SECURE: No world-accessible ACEs found
}

// ============================================================================
// ACL Diagnostic Functions
// ============================================================================

/// Add ConvertSidToStringSidW for SID-to-string conversion
pub extern "advapi32" fn ConvertSidToStringSidW(
    Sid: *anyopaque,
    StringSid: *[*:0]u16,
) callconv(windows.WINAPI) windows.BOOL;

/// ACE information for diagnostic output
pub const AceInfo = struct {
    ace_type: []const u8,
    sid_string: []const u8,
    access_mask: windows.DWORD,
    is_world_accessible: bool,
};

/// Get human-readable ACL diagnostic information
///
/// Returns detailed information about all ACEs in the file's DACL,
/// including SID strings, access masks, and security warnings.
///
/// Example:
/// ```zig
/// const info = try getAclDiagnostics(allocator, "\\\\.\\ pipe\\myapp");
/// defer {
///     for (info.aces) |ace| {
///         allocator.free(ace.sid_string);
///         allocator.free(ace.ace_type);
///     }
///     allocator.free(info.aces);
/// }
/// std.debug.print("File has {d} ACL entries\n", .{info.aces.len});
/// ```
pub const AclDiagnostics = struct {
    has_dacl: bool,
    ace_count: u32,
    aces: []AceInfo,
    is_insecure: bool,
};

pub fn getAclDiagnostics(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
) !AclDiagnostics {
    if (builtin.os.tag != .windows) {
        return AclDiagnostics{
            .has_dacl = false,
            .ace_count = 0,
            .aces = &[_]AceInfo{},
            .is_insecure = false,
        };
    }

    // Convert UTF-8 path to UTF-16
    const path_w = try std.unicode.utf8ToUtf16LeWithNull(allocator, socket_path);
    defer allocator.free(path_w);

    // Get security descriptor with DACL
    var sd: ?*anyopaque = null;
    var dacl: ?*ACL = null;

    const result = GetNamedSecurityInfoW(
        path_w.ptr,
        .SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION,
        null,
        null,
        &dacl,
        null,
        &sd,
    );

    if (result != 0) {
        return error.GetSecurityInfoFailed;
    }
    defer _ = LocalFree(sd);

    if (dacl == null) {
        // No DACL means everyone has full access (INSECURE!)
        return AclDiagnostics{
            .has_dacl = false,
            .ace_count = 0,
            .aces = &[_]AceInfo{},
            .is_insecure = true,
        };
    }

    // Enumerate ACEs
    const ace_count = dacl.?.AceCount;
    var ace_list = std.ArrayList(AceInfo){};
    errdefer {
        for (ace_list.items) |ace| {
            allocator.free(ace.sid_string);
            allocator.free(ace.ace_type);
        }
        ace_list.deinit(allocator);
    }

    var is_insecure = false;
    var i: windows.DWORD = 0;
    while (i < ace_count) : (i += 1) {
        var ace: ?*anyopaque = null;
        const ace_result = GetAce(dacl.?, i, &ace);

        if (ace_result == 0 or ace == null) continue;

        const header = @as(*ACE_HEADER, @ptrCast(@alignCast(ace.?)));

        // Get ACE type string
        const ace_type_str = switch (header.AceType) {
            ACCESS_ALLOWED_ACE_TYPE => "ALLOW",
            ACCESS_DENIED_ACE_TYPE => "DENY",
            else => "UNKNOWN",
        };

        if (header.AceType == ACCESS_ALLOWED_ACE_TYPE) {
            const allowed_ace = @as(*ACCESS_ALLOWED_ACE, @ptrCast(@alignCast(ace.?)));
            const sid = @as(*anyopaque, @ptrCast(&allowed_ace.SidStart));

            // Convert SID to string
            var sid_string_w: [*:0]u16 = undefined;
            const sid_result = ConvertSidToStringSidW(sid, &sid_string_w);

            var sid_string: []const u8 = "UNKNOWN";
            if (sid_result != 0) {
                // Convert UTF-16 to UTF-8
                const sid_len = std.mem.indexOfSentinel(u16, 0, sid_string_w);
                const sid_slice = sid_string_w[0..sid_len :0];
                sid_string = std.unicode.utf16LeToUtf8Alloc(allocator, sid_slice) catch "CONVERSION_FAILED";
                _ = LocalFree(sid_string_w);
            } else {
                sid_string = try allocator.dupe(u8, "UNKNOWN");
            }

            // Check if world-accessible
            const world_accessible = isWorldAccessibleSid(sid);
            if (world_accessible) {
                is_insecure = true;
            }

            try ace_list.append(AceInfo{
                .ace_type = try allocator.dupe(u8, ace_type_str),
                .sid_string = sid_string,
                .access_mask = allowed_ace.Mask,
                .is_world_accessible = world_accessible,
            });
        }
    }

    return AclDiagnostics{
        .has_dacl = true,
        .ace_count = ace_count,
        .aces = try ace_list.toOwnedSlice(),
        .is_insecure = is_insecure,
    };
}

/// Print human-readable ACL diagnostics to stderr
///
/// Displays detailed information about file ACLs including:
/// - Number of ACEs
/// - Each ACE's type, SID, and access mask
/// - Security warnings for world-accessible entries
///
/// Example:
/// ```zig
/// try printAclDiagnostics(allocator, "\\\\.\\ pipe\\myapp");
/// ```
pub fn printAclDiagnostics(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
) !void {
    const diagnostics = try getAclDiagnostics(allocator, socket_path);
    defer {
        for (diagnostics.aces) |ace| {
            allocator.free(ace.sid_string);
            allocator.free(ace.ace_type);
        }
        allocator.free(diagnostics.aces);
    }

    std.debug.print("\n=== ACL Diagnostics for: {s} ===\n", .{socket_path});

    if (!diagnostics.has_dacl) {
        std.debug.print("⚠️  WARNING: No DACL present (everyone has full access!)\n", .{});
        return;
    }

    std.debug.print("Total ACEs: {d}\n", .{diagnostics.ace_count});
    std.debug.print("Security Status: {s}\n", .{if (diagnostics.is_insecure) "⚠️  INSECURE" else "✅ SECURE"});
    std.debug.print("\nACL Entries:\n", .{});

    for (diagnostics.aces, 0..) |ace, idx| {
        std.debug.print("  [{d}] Type: {s:<6} | SID: {s:<40} | Mask: 0x{X:0>8}", .{
            idx + 1,
            ace.ace_type,
            ace.sid_string,
            ace.access_mask,
        });

        if (ace.is_world_accessible) {
            std.debug.print(" ⚠️  WORLD-ACCESSIBLE\n", .{});
        } else {
            std.debug.print("\n", .{});
        }
    }

    if (diagnostics.is_insecure) {
        std.debug.print("\n⚠️  SECURITY WARNING: This file has world-accessible permissions!\n", .{});
        std.debug.print("   Recommended action: Restrict access to owner/administrators only\n", .{});
        std.debug.print("   Use SDDL: {s}\n", .{SDDL.OWNER_ONLY});
    }

    std.debug.print("=====================================\n\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "modeToSddl conversions" {
    try std.testing.expectEqualStrings(SDDL.OWNER_ONLY, modeToSddl(0o700));
    try std.testing.expectEqualStrings(SDDL.OWNER_GROUP, modeToSddl(0o770));
    try std.testing.expectEqualStrings(SDDL.WORLD_ACCESS, modeToSddl(0o777));
    try std.testing.expectEqualStrings(SDDL.DEFAULT, modeToSddl(0o755)); // Unmapped modes use default
}
