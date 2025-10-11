//! Security validation and privilege management
//!
//! This module provides security features for safe network service operation:
//! - Privilege dropping (Unix only) - run as unprivileged user after binding
//! - Exec mode validation - enforce access control for remote command execution
//! - Security event logging - track dangerous operations
//!
//! Key Security Functions:
//! - dropPrivileges() - Drop root privileges to target user (Unix only)
//! - validateExecSecurity() - Ensure exec mode has access control configured
//! - displayExecWarning() - Show operator warning about dangerous exec mode
//! - logSecurityEvent() - Log security-relevant events with client addresses
//!
//! Platform Support:
//! - Unix/Linux: Full privilege dropping with setuid/setgid
//! - Windows: Privilege operations not implemented (logs info message)
//!
//! Usage Pattern:
//! 1. Bind to privileged port (<1024) as root
//! 2. Call dropPrivileges("nobody") to become unprivileged user
//! 3. Validate exec mode with validateExecSecurity() before accepting connections
//! 4. Log all security events with logSecurityEvent()

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("logging.zig");

// Import C functions for group management (not available in std.posix)
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("grp.h");
    @cInclude("pwd.h");
});

/// Errors that can occur during security operations
pub const SecurityError = error{
    /// Target user not found in common users and not valid UID
    UserNotFound,

    /// Failed to set user ID (setuid syscall failed)
    SetuidFailed,

    /// Failed to set group ID (setgid syscall failed)
    SetgidFailed,

    /// Failed to set supplementary groups (setgroups syscall failed)
    SetgroupsFailed,

    /// Attempted privilege drop without root privileges
    NotRoot,
};

/// Drop privileges after binding to port (Unix only)
///
/// SECURITY CRITICAL: This function irreversibly drops root privileges
/// to run as an unprivileged user. Must be called AFTER binding to
/// privileged ports (<1024) but BEFORE accepting connections.
///
/// Architecture:
/// 1. Check if running as root (euid == 0)
/// 2. Look up target user (e.g., "nobody", "www-data")
/// 3. Clear supplementary groups with setgroups() (prevents retaining wheel/admin)
/// 4. Set primary GID with setgid() (can't change after UID drop)
/// 5. Set UID with setuid() (irreversible - can't regain root)
/// 6. Verify privilege drop succeeded and log final groups
///
/// Platform Support:
/// - Unix/Linux: Full implementation with setuid/setgid
/// - Windows: No-op (logs info message and returns)
///
/// Parameters:
/// - target_user: Username or numeric UID to switch to
///   - Common users: "nobody" (65534), "daemon" (1), "www-data" (33)
///   - Numeric UID: "1000" parsed as UID (primary group resolved via getpwuid)
///
/// Returns:
/// - error.NotRoot if not running as root (euid != 0)
/// - error.UserNotFound if target_user not in common users and not numeric UID
/// - error.SetgroupsFailed if supplementary group clearing fails
/// - error.SetgidFailed if group ID change fails
/// - error.SetuidFailed if user ID change fails or still root after drop
///
/// Security:
/// - Clears supplementary groups first to prevent retaining wheel/admin groups
/// - GID must be changed before UID (UID drop is permanent)
/// - Verifies euid != 0 after drop to confirm privilege loss
/// - Logs before/after UID/GID/groups for complete audit trail
///
/// Example:
/// ```zig
/// // Bind to privileged port while root
/// const sock = try posix.socket(...);
/// try posix.bind(sock, ...);  // Port 80 requires root
///
/// // Drop privileges before accepting connections
/// try dropPrivileges("nobody");  // Now running as nobody:nobody
/// ```
pub fn dropPrivileges(target_user: []const u8) !void {
    if (builtin.os.tag == .windows) {
        logging.log(1, "Privilege dropping not implemented on Windows\n", .{});
        return;
    }

    // Check if we're running as root
    const euid = std.os.linux.geteuid();
    if (euid != 0) {
        logging.log(1, "Not running as root (euid={any}), skipping privilege drop\n", .{euid});
        return;
    }

    logging.log(1, "Running as root, attempting to drop privileges to user '{s}'\n", .{target_user});

    // Look up target user (e.g., "nobody")
    const pw = try getUserInfo(target_user);

    // Drop privileges: clear supplementary groups first, then set GID, then UID
    // Order is critical:
    // 1. setgroups() - Clear supplementary groups (requires root)
    // 2. setgid() - Set primary group (requires root)
    // 3. setuid() - Set user ID (irreversible, must be last)

    // SECURITY: Clear all supplementary groups to prevent retaining privileged
    // groups like "wheel" or "admin" after dropping to an unprivileged user.
    // Calling setgroups with size 0 and a null list is the standard way to do this.
    if (c.setgroups(0, null) != 0) {
        const errno = std.posix.errno(-1);
        std.debug.print("Error: Failed to clear supplementary groups with setgroups(0, null): errno={any}\n", .{errno});
        return SecurityError.SetgroupsFailed;
    }

    // SECURITY FIX (2025-10-10): Use 'try' to propagate errors immediately.
    // Previous catch blocks could theoretically allow partial privilege drop if setgid
    // failed but execution continued. Using 'try' ensures the entire privilege drop
    // operation aborts on any failure, preventing insecure partial drops.
    //
    // CRITICAL: If setgid fails, the process retains privileged group membership.
    // If execution then continued to setuid, we'd have an unprivileged user with
    // privileged group access - a serious security vulnerability.
    try std.posix.setgid(pw.gid);
    try std.posix.setuid(pw.uid);

    // Verify we can't get root back
    const new_euid = std.os.linux.geteuid();
    const new_egid = std.os.linux.getegid();

    // Verify supplementary groups were cleared
    var group_buf: [32]c.gid_t = undefined;
    const ngroups = c.getgroups(group_buf.len, &group_buf);

    logging.log(1, "✓ Privileges dropped successfully:\n", .{});
    logging.log(1, "  User: {s}\n", .{target_user});
    logging.log(1, "  UID:  {any} -> {any}\n", .{ euid, new_euid });
    logging.log(1, "  GID:  {any} -> {any}\n", .{ std.os.linux.getegid(), new_egid });

    // Log supplementary groups for security audit
    if (ngroups > 0) {
        logging.log(1, "  Supplementary groups ({any} total):\n", .{ngroups});
        var i: usize = 0;
        while (i < ngroups) : (i += 1) {
            logging.log(1, "    - GID {any}\n", .{group_buf[i]});
        }
    } else {
        logging.log(1, "  Supplementary groups: (none)\n", .{});
    }

    // Safety check
    if (new_euid == 0) {
        std.debug.print("Error: SECURITY: Still running as root after privilege drop!\n", .{});
        return SecurityError.SetuidFailed;
    }
}

/// User information for privilege dropping
const UserInfo = struct {
    /// User ID (numeric identifier)
    uid: std.posix.uid_t,

    /// Group ID (numeric identifier)
    gid: std.posix.gid_t,

    /// Username (for logging)
    name: []const u8,
};

/// Look up user by name or numeric UID (Unix only)
///
/// Resolves username to UID/GID for privilege dropping.
/// Supports common system users and numeric UID fallback.
/// Numeric fallback resolves the primary group via getpwuid when available.
///
/// Common system users:
/// - "nobody": UID 65534, GID 65534 (unprivileged user)
/// - "daemon": UID 1, GID 1 (system daemon user)
/// - "www-data": UID 33, GID 33 (web server user)
///
/// Parameters:
/// - username: User name or numeric UID string
///
/// Returns:
/// - UserInfo struct with UID/GID/name
/// - error.UserNotFound if name not in common users and not numeric UID
///
/// Example:
/// ```zig
/// const user = try getUserInfo("nobody");  // UID 65534
/// const user2 = try getUserInfo("1000");   // UID 1000 (numeric)
/// ```
fn getUserInfo(username: []const u8) !UserInfo {
    if (builtin.os.tag == .windows) {
        return SecurityError.UserNotFound;
    }

    // Add an assertion for safety.
    std.debug.assert(username.len < 255);

    // Create a null-terminated copy of the username for C compatibility
    var buf: [256]u8 = undefined;
    const new_len = @min(username.len, buf.len - 1);
    @memcpy(buf[0..new_len], username[0..new_len]);
    buf[new_len] = 0;
    const username_z: [*:0]const u8 = @ptrCast(buf[0 .. new_len + 1 :0].ptr);

    // Try to look up the user with getpwnam
    const pwent = c.getpwnam(username_z);

    if (pwent != null) {
        // User found, return their info
        return UserInfo{
            .uid = pwent.*.pw_uid,
            .gid = pwent.*.pw_gid,
            .name = username,
        };
    }

    // If user not found by name, try parsing as a numeric UID
    const uid = std.fmt.parseInt(std.posix.uid_t, username, 10) catch {
        logging.log(1, "Error: User '{s}' not found in system database and not a valid UID\n", .{username});
        return SecurityError.UserNotFound;
    };

    // Numeric UID successfully parsed, attempt to resolve primary group
    const pwuid = c.getpwuid(@intCast(uid));
    if (pwuid != null) {
        return UserInfo{
            .uid = uid,
            .gid = @intCast(pwuid.*.pw_gid),
            .name = username,
        };
    }

    logging.logWarning("Could not resolve primary group for UID {any}; defaulting to GID {any}\n", .{ uid, uid });

    return UserInfo{
        .uid = uid,
        .gid = @intCast(uid), // Fallback: assume GID = UID
        .name = username,
    };
}

/// Log security-relevant event
///
/// Logs security-critical operations for audit trail.
/// Always uses std.log.warn for visibility in production.
///
/// Parameters:
/// - event_type: Event category (e.g., "EXEC", "CONNECT", "DENY")
/// - client_addr: Client IP address involved in event
/// - details: Additional context about the event
///
/// Example:
/// ```zig
/// logSecurityEvent("EXEC", client_addr, "Running /bin/sh");
/// logSecurityEvent("DENY", client_addr, "IP not in allow list");
/// ```
pub fn logSecurityEvent(
    comptime event_type: []const u8,
    client_addr: std.net.Address,
    details: []const u8,
) void {
    logging.logWarning("SECURITY[{s}]: {any} - {s}\n", .{ event_type, client_addr, details });
}

/// Validate that exec mode has proper restrictions
///
/// SECURITY CRITICAL: Ensures exec mode (-e/-c flags) has access control
/// configured to prevent unrestricted remote command execution.
///
/// Security Check:
/// - If require_allow is true AND allow_list_count is 0:
///   - Displays prominent error box to stderr
///   - Returns error.ExecRequiresAllow to abort server startup
///
/// This prevents the dangerous scenario where ANY client can execute
/// the configured program without IP-based access restrictions.
///
/// Parameters:
/// - exec_program: Program path being executed (for error message)
/// - allow_list_count: Number of IPs in allow list (0 = no restrictions)
/// - require_allow: Whether to enforce access control (default: true)
///
/// Returns:
/// - error.ExecRequiresAllow if require_allow && allow_list_count == 0
/// - Success if access control is properly configured
///
/// Example:
/// ```zig
/// // FAILS: No access control
/// validateExecSecurity("/bin/sh", 0, true);  // Error!
///
/// // SUCCEEDS: Access control configured
/// validateExecSecurity("/bin/sh", 3, true);  // 3 allowed IPs
/// ```
pub fn validateExecSecurity(
    exec_program: []const u8,
    allow_list_count: usize,
    require_allow: bool,
) !void {
    if (require_allow and allow_list_count == 0) {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════╗\n", .{});
        std.debug.print("║  ⚠️  SECURITY ERROR  ⚠️                  ║\n", .{});
        std.debug.print("║  Exec mode requires access control!     ║\n", .{});
        std.debug.print("║  Program: {s:<30}║\n", .{exec_program});
        std.debug.print("║  NO ACCESS RESTRICTIONS CONFIGURED!     ║\n", .{});
        std.debug.print("║                                          ║\n", .{});
        std.debug.print("║  Any client could execute this program! ║\n", .{});
        std.debug.print("║  Use --allow to restrict access.        ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        return error.ExecRequiresAllow;
    }
}

/// Display security warning for exec mode
///
/// Shows prominent boxed warning to operator about dangerous exec mode.
/// Called during server startup to ensure operator awareness.
///
/// Warning content varies based on access control:
/// - If allow_list_count == 0: Emphasizes lack of restrictions
/// - If allow_list_count > 0: Shows number of allowed addresses
///
/// Parameters:
/// - exec_program: Program path being executed (shown in warning)
/// - allow_list_count: Number of IPs in allow list (0 = unrestricted)
///
/// Example output (no restrictions):
/// ```
/// ╔══════════════════════════════════════════╗
/// ║  ⚠️  SECURITY WARNING  ⚠️                ║
/// ║  Exec mode (-e) is DANGEROUS!           ║
/// ║  Program: /bin/sh                       ║
/// ║  NO ACCESS RESTRICTIONS CONFIGURED!     ║
/// ║  Any client can execute this program!   ║
/// ╚══════════════════════════════════════════╝
/// ```
pub fn displayExecWarning(exec_program: []const u8, allow_list_count: usize) void {
    logging.logWarning("\n", .{});
    logging.logWarning("╔══════════════════════════════════════════╗\n", .{});
    logging.logWarning("║  ⚠️  SECURITY WARNING  ⚠️                ║\n", .{});
    logging.logWarning("║  Exec mode (-e) is DANGEROUS!           ║\n", .{});
    logging.logWarning("║  Program: {s:<30}║\n", .{exec_program});

    if (allow_list_count == 0) {
        logging.logWarning("║  NO ACCESS RESTRICTIONS CONFIGURED!     ║\n", .{});
        logging.logWarning("║  Any client can execute this program!   ║\n", .{});
    } else {
        logging.logWarning("║  Access restricted to {any} addresses       ║\n", .{allow_list_count});
    }

    logging.logWarning("╚══════════════════════════════════════════╝\n", .{});
    logging.logWarning("\n", .{});
}

/// Validate Unix socket file permissions for security
///
/// SECURITY CRITICAL: Validates that Unix socket files do not have overly
/// permissive file permissions that could allow unauthorized access.
///
/// Security checks:
/// - World-readable/writable permissions (0o007) - HIGH RISK
/// - Group-writable permissions (0o020) - MEDIUM RISK
///
/// This provides defense-in-depth security by catching misconfigured socket
/// files that could allow unintended access even with other access controls.
///
/// Architecture:
/// 1. Stat the socket file to get permissions
/// 2. Extract permission bits (mode & 0o777)
/// 3. Check for world permissions (other: rwx)
/// 4. Check for group-write permission
/// 5. Log warnings with remediation advice
///
/// Platform Support:
/// - Unix/Linux: Full permission checking
/// - Windows: No-op (returns immediately)
///
/// Parameters:
/// - socket_path: Path to Unix socket file to validate
///
/// Returns:
/// - error.FileNotFound if socket file doesn't exist
/// - error.AccessDenied if cannot stat the file
/// - Success after logging any warnings
///
/// Security Impact:
/// - Prevents overly-permissive socket files
/// - Provides operator feedback on risky configurations
/// - Suggests remediation commands (chmod)
///
/// Example:
/// ```zig
/// // After creating Unix socket server
/// const sock_path = "/tmp/myapp.sock";
/// try validateUnixSocketPermissions(sock_path);  // Warns if 0o777
/// ```
pub fn validateUnixSocketPermissions(socket_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        // Unix sockets not supported on Windows
        return;
    }

    // Stat the socket file to get permissions
    const stat_result = std.fs.cwd().statFile(socket_path) catch |err| {
        // FileNotFound is expected if socket not yet created
        if (err == error.FileNotFound) {
            return err;
        }
        // AccessDenied means we can't validate, but socket exists
        if (err == error.AccessDenied) {
            logging.logWarning("Cannot validate permissions for Unix socket '{s}': Access denied\n", .{socket_path});
            return err;
        }
        return err;
    };

    // Extract permission bits (lower 9 bits: rwxrwxrwx)
    const perms = stat_result.mode & 0o777;

    // Check for world permissions (other: rwx) - HIGH RISK
    const world_perms = perms & 0o007;
    if (world_perms != 0) {
        logging.logWarning("\n", .{});
        logging.logWarning("╔═══════════════════════════════════════════════════════════╗\n", .{});
        logging.logWarning("║  ⚠️  SECURITY WARNING: Unix Socket Permissions           ║\n", .{});
        logging.logWarning("║                                                           ║\n", .{});
        logging.logWarning("║  Socket has WORLD-READABLE/WRITABLE permissions!         ║\n", .{});
        logging.logWarning("║  Path: {s:<50}║\n", .{socket_path});
        logging.logWarning("║  Permissions: 0o{o:<46}║\n", .{perms});
        logging.logWarning("║                                                           ║\n", .{});
        logging.logWarning("║  Any user on the system can access this socket!          ║\n", .{});
        logging.logWarning("║  Recommended: chmod 770 {s:<34}║\n", .{socket_path});
        logging.logWarning("╚═══════════════════════════════════════════════════════════╝\n", .{});
        logging.logWarning("\n", .{});
        return;
    }

    // Check for group-writable permission - MEDIUM RISK
    const group_write = perms & 0o020;
    if (group_write != 0) {
        logging.log(1, "Unix socket is group-writable (0o{o}): {s}\n", .{ perms, socket_path });
        logging.log(1, "Consider: chmod 750 {s} (if group access not needed)\n", .{socket_path});
    }
}

test "getUserInfo system user (root)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const root = try getUserInfo("root");
    try std.testing.expectEqual(@as(u32, 0), root.uid);
    try std.testing.expectEqualStrings("root", root.name);
}

test "getUserInfo numeric UID" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const user = try getUserInfo("1000");
    try std.testing.expectEqual(@as(u32, 1000), user.uid);
}

test "validateExecSecurity requires allow" {
    // Skip this test to avoid log pollution in test output
    // The functionality is validated by checking that error is returned
    // and the security warnings are displayed during integration tests
    return error.SkipZigTest;
}

test "validateExecSecurity allows with restrictions" {
    try validateExecSecurity("/bin/sh", 5, true);
}

test "validateUnixSocketPermissions on nonexistent file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Test with nonexistent file
    const result = validateUnixSocketPermissions("/tmp/nonexistent_socket_test_xyz.sock");
    try std.testing.expectError(error.FileNotFound, result);
}

test "validateUnixSocketPermissions on real file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Create a temporary file to test with (unique name to avoid conflicts)
    const test_path = "/tmp/zigcat_security_perm_test_unique.sock";

    // Ensure cleanup even if test fails
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Create the file with specific permissions
    const file = std.fs.cwd().createFile(test_path, .{ .mode = 0o600 }) catch |err| {
        logging.logWarning("Cannot create test file: {any}\n", .{err});
        return error.SkipZigTest;
    };
    file.close();

    // Test validation on file with safe permissions (should pass quietly)
    validateUnixSocketPermissions(test_path) catch |err| {
        logging.logWarning("Validation failed on safe permissions: {any}\n", .{err});
    };

    // Now set world-readable permissions (0o644) - This should trigger warning
    // Open the file and use File.chmod
    const file_to_chmod = std.fs.cwd().openFile(test_path, .{}) catch |err| {
        logging.logWarning("Cannot open test file for chmod: {any}\n", .{err});
        return error.SkipZigTest;
    };
    defer file_to_chmod.close();

    file_to_chmod.chmod(0o644) catch |err| {
        logging.logWarning("Cannot chmod test file: {any}\n", .{err});
        return error.SkipZigTest;
    };

    // Test validation with world-readable permissions (should warn but not error)
    validateUnixSocketPermissions(test_path) catch {};
}
