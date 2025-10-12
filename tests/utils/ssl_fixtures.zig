//! Shared SSL/TLS test fixtures used by multiple test suites.

const std = @import("std");
const artifacts = @import("test_artifacts.zig");

pub const CertArtifacts = struct {
    allocator: std.mem.Allocator,
    dir: artifacts.ArtifactDir,
    cert_path: []const u8,
    key_path: []const u8,

    pub fn deinit(self: *CertArtifacts) void {
        self.allocator.free(self.cert_path);
        self.allocator.free(self.key_path);
        self.dir.deinit();
    }
};

/// Generate a short-lived self-signed certificate for TLS tests.
pub fn generateSelfSignedCert(allocator: std.mem.Allocator, common_name: []const u8) !CertArtifacts {
    var dir = artifacts.ArtifactDir.init(allocator);
    errdefer dir.deinit();

    const cert_path = try dir.ensureEmptyFile("cert.pem");
    errdefer allocator.free(cert_path);

    const key_path = try dir.ensureEmptyFile("key.pem");
    errdefer allocator.free(key_path);

    const subject = try std.fmt.allocPrint(allocator, "/CN={s}", .{common_name});
    defer allocator.free(subject);

    var argv = [_][]const u8{
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-keyout",
        key_path,
        "-out",
        cert_path,
        "-days",
        "1",
        "-nodes",
        "-subj",
        subject,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        return error.CertGenerationFailed;
    }

    return CertArtifacts{
        .allocator = allocator,
        .dir = dir,
        .cert_path = cert_path,
        .key_path = key_path,
    };
}

pub const TestServer = struct {
    child: std.process.Child,
    port: u16,
    allocator: std.mem.Allocator,

    pub fn start(
        allocator: std.mem.Allocator,
        cert_path: []const u8,
        key_path: []const u8,
        port: u16,
    ) !TestServer {
        const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
        defer allocator.free(port_str);

        var argv = [_][]const u8{
            "openssl",
            "s_server",
            "-accept",
            port_str,
            "-cert",
            cert_path,
            "-key",
            key_path,
            "-quiet",
            "-no_dhe",
        };

        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        std.Thread.sleep(500 * std.time.ns_per_ms);

        return TestServer{
            .child = child,
            .port = port,
            .allocator = allocator,
        };
    }

    pub fn stop(self: *TestServer) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }
};
