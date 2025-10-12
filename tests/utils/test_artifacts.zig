//! Shared helpers for creating and cleaning up filesystem artifacts during tests.
//! Provides a thin wrapper around `temp_dir.zig` with convenience methods for
//! generating relative paths that can be passed to commands or `std.fs.cwd()`
//! operations.

const std = @import("std");
const temp_dir = @import("temp_dir.zig");

/// Manages a scoped temporary directory for tests that need to create files.
/// Generates paths relative to the repository root so existing code that uses
/// `std.fs.cwd()` continues to work unchanged.
pub const ArtifactDir = struct {
    allocator: std.mem.Allocator,
    temp: temp_dir.TempDir,

    /// Create a new artifact directory rooted under `.zig-cache/tmp`.
    pub fn init(allocator: std.mem.Allocator) ArtifactDir {
        return .{
            .allocator = allocator,
            .temp = temp_dir.createTempDir(allocator),
        };
    }

    /// Clean up the directory and release all temporary files.
    pub fn deinit(self: *ArtifactDir) void {
        self.temp.cleanup();
    }

    /// Ensure a file exists (creating parent directories as needed) and return
    /// the relative path that can be fed to existing file APIs.
    pub fn ensureEmptyFile(self: *ArtifactDir, relative_path: []const u8) ![]const u8 {
        try self.temp.writeFile(relative_path, "");
        return self.relativePath(relative_path);
    }

    /// Write data into a file within the artifact directory and return the
    /// relative path.
    pub fn writeFile(self: *ArtifactDir, relative_path: []const u8, data: []const u8) ![]const u8 {
        try self.temp.writeFile(relative_path, data);
        return self.relativePath(relative_path);
    }

    /// Convenience helper that formats a relative path before returning the
    /// fully qualified test path.
    pub fn makePath(self: *ArtifactDir, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const relative = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(relative);
        return self.relativePath(relative);
    }

    /// Read a file that was created in the artifact directory. Caller must free
    /// the returned slice.
    pub fn readFile(self: *ArtifactDir, relative_path: []const u8) ![]u8 {
        return self.temp.readFile(relative_path);
    }

    /// Delete a file inside the artifact directory if it exists.
    pub fn deleteFile(self: *ArtifactDir, relative_path: []const u8) void {
        self.temp.dir().deleteFile(relative_path) catch {};
    }

    /// Compute a path relative to the repository root for the given file in the
    /// artifact directory. Caller must free the returned slice.
    pub fn relativePath(self: *ArtifactDir, relative_path: []const u8) ![]const u8 {
        const buffer = try self.allocator.alloc(u8, std.posix.PATH_MAX);
        defer self.allocator.free(buffer);

        const base = try self.temp.getRelPath(buffer);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, relative_path });
    }
};
