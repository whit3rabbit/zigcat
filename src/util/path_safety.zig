//! Path safety helpers used to reject directory traversal sequences.
//!
//! These helpers are intentionally lightweight and perform purely lexical
//! validation so they can be used during argument parsing before any file
//! system interaction occurs.

const std = @import("std");

/// Return true when `path` contains a `..` component that would traverse
/// upwards in the directory tree. Both POSIX (`/`) and Windows (`\`) path
/// separators are treated as delimiters and empty components are ignored.
pub fn hasParentDirectoryTraversal(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            return true;
        }
    }
    return false;
}

/// Basic guard that checks for traversal segments and rejects empty inputs.
/// Returns false if the path is empty or contains parent-directory references.
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0) return false;
    return !hasParentDirectoryTraversal(path);
}
