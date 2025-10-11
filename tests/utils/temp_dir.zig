//! Utility module for managing temporary directories in tests.
//!
//! This module provides helpers for creating isolated, secure temporary
//! directories for test cases. All functions use std.testing.tmpDir()
//! internally for cross-platform compatibility.
//!
//! Usage:
//!   const temp_utils = @import("utils/temp_dir.zig");
//!   var tmp = try temp_utils.createTempDir(.{});
//!   defer tmp.cleanup();

const std = @import("std");
const testing = std.testing;
const fs = std.fs;

/// A temporary directory with additional utility methods.
pub const TempDir = struct {
    inner: testing.TmpDir,
    allocator: std.mem.Allocator,

    /// Create a new temporary directory.
    /// Always call cleanup() when done (use defer).
    pub fn init(allocator: std.mem.Allocator) TempDir {
        return .{
            .inner = testing.tmpDir(.{}),
            .allocator = allocator,
        };
    }

    /// Create a temporary directory with custom options.
    pub fn initWithOptions(allocator: std.mem.Allocator, opts: fs.Dir.OpenOptions) TempDir {
        return .{
            .inner = testing.tmpDir(opts),
            .allocator = allocator,
        };
    }

    /// Clean up the temporary directory and all its contents.
    pub fn cleanup(self: *TempDir) void {
        self.inner.cleanup();
    }

    /// Get the underlying directory handle.
    pub fn dir(self: *TempDir) fs.Dir {
        return self.inner.dir;
    }

    /// Get the relative path to the temporary directory.
    /// Returns ".zig-cache/tmp/{random_hash}"
    pub fn getRelPath(self: *const TempDir, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{self.inner.sub_path});
    }

    /// Get the absolute path to the temporary directory.
    /// Caller must free the returned slice.
    pub fn getAbsPath(self: *const TempDir) ![]const u8 {
        const cwd = fs.cwd();
        const cache_path = try cwd.realpathAlloc(self.allocator, ".zig-cache/tmp");
        defer self.allocator.free(cache_path);

        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ cache_path, self.inner.sub_path });
    }

    /// Get the full path to a file within the temporary directory.
    /// Useful for passing to external commands or system calls.
    /// Caller must free the returned slice.
    pub fn getFilePath(self: *const TempDir, relative_path: []const u8) ![]const u8 {
        const abs_path = try self.getAbsPath();
        defer self.allocator.free(abs_path);

        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ abs_path, relative_path });
    }

    /// Create a file in the temporary directory and return its absolute path.
    /// Useful for generating paths for TLS certificates, socket files, etc.
    /// Caller must free the returned slice.
    pub fn createFileWithPath(self: *TempDir, relative_path: []const u8, data: []const u8) ![]const u8 {
        // Create any parent directories
        if (fs.path.dirname(relative_path)) |parent| {
            try self.inner.dir.makePath(parent);
        }

        // Write file
        try self.inner.dir.writeFile(.{
            .sub_path = relative_path,
            .data = data,
        });

        // Return absolute path
        return self.getFilePath(relative_path);
    }

    /// Create multiple nested directories at once.
    pub fn makePath(self: *TempDir, relative_path: []const u8) !void {
        try self.inner.dir.makePath(relative_path);
    }

    /// Write a file to the temporary directory.
    pub fn writeFile(self: *TempDir, relative_path: []const u8, data: []const u8) !void {
        // Create parent directories if needed
        if (fs.path.dirname(relative_path)) |parent| {
            try self.inner.dir.makePath(parent);
        }

        try self.inner.dir.writeFile(.{
            .sub_path = relative_path,
            .data = data,
        });
    }

    /// Read a file from the temporary directory.
    /// Caller must free the returned slice.
    pub fn readFile(self: *TempDir, relative_path: []const u8) ![]u8 {
        return self.inner.dir.readFileAlloc(self.allocator, relative_path, 1024 * 1024);
    }

    /// Check if a file exists in the temporary directory.
    pub fn fileExists(self: *TempDir, relative_path: []const u8) bool {
        self.inner.dir.access(relative_path, .{}) catch return false;
        return true;
    }
};

/// Convenience function to create a temporary directory.
/// Returns a TempDir that must be cleaned up with defer.
pub fn createTempDir(allocator: std.mem.Allocator) TempDir {
    return TempDir.init(allocator);
}

/// Convenience function to create a temporary directory with custom options.
pub fn createTempDirWithOptions(allocator: std.mem.Allocator, opts: fs.Dir.OpenOptions) TempDir {
    return TempDir.initWithOptions(allocator, opts);
}

// =============================================================================
// Tests
// =============================================================================

test "TempDir: basic creation and cleanup" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    // Directory should exist
    var dir = tmp.dir();
    var file = try dir.createFile("test.txt", .{});
    defer file.close();
    try file.writeAll("test data");
}

test "TempDir: write and read file" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    try tmp.writeFile("test.txt", "Hello, World!");

    const content = try tmp.readFile("test.txt");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("Hello, World!", content);
}

test "TempDir: nested directories" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    try tmp.makePath("a/b/c");
    try tmp.writeFile("a/b/c/test.txt", "nested file");

    try testing.expect(tmp.fileExists("a/b/c/test.txt"));
}

test "TempDir: get absolute path" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    const abs_path = try tmp.getAbsPath();
    defer testing.allocator.free(abs_path);

    // Path should contain .zig-cache/tmp/
    try testing.expect(std.mem.indexOf(u8, abs_path, ".zig-cache") != null);
    try testing.expect(std.mem.indexOf(u8, abs_path, "tmp") != null);
}

test "TempDir: get file path" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    try tmp.writeFile("test.txt", "data");

    const file_path = try tmp.getFilePath("test.txt");
    defer testing.allocator.free(file_path);

    // Verify file is accessible via returned path
    const cwd = fs.cwd();
    const file = try cwd.openFile(file_path, .{});
    defer file.close();
}

test "TempDir: createFileWithPath" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    const file_path = try tmp.createFileWithPath("certs/cert.pem", "CERT DATA");
    defer testing.allocator.free(file_path);

    // Verify file exists and contains correct data
    const content = try tmp.readFile("certs/cert.pem");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("CERT DATA", content);
}

test "TempDir: multiple instances are isolated" {
    var tmp1 = createTempDir(testing.allocator);
    defer tmp1.cleanup();

    var tmp2 = createTempDir(testing.allocator);
    defer tmp2.cleanup();

    try tmp1.writeFile("test.txt", "tmp1 data");
    try tmp2.writeFile("test.txt", "tmp2 data");

    const content1 = try tmp1.readFile("test.txt");
    defer testing.allocator.free(content1);

    const content2 = try tmp2.readFile("test.txt");
    defer testing.allocator.free(content2);

    try testing.expectEqualStrings("tmp1 data", content1);
    try testing.expectEqualStrings("tmp2 data", content2);
}

test "TempDir: file exists check" {
    var tmp = createTempDir(testing.allocator);
    defer tmp.cleanup();

    try testing.expect(!tmp.fileExists("nonexistent.txt"));

    try tmp.writeFile("exists.txt", "data");
    try testing.expect(tmp.fileExists("exists.txt"));
}

test "TempDir: with iterate option" {
    var tmp = createTempDirWithOptions(testing.allocator, .{ .iterate = true });
    defer tmp.cleanup();

    try tmp.writeFile("file1.txt", "data1");
    try tmp.writeFile("file2.txt", "data2");
    try tmp.makePath("subdir");

    var walker = try tmp.dir().walk(testing.allocator);
    defer walker.deinit();

    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            file_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), file_count);
}
