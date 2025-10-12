// CLI Argument Parser Tests
// Tests all 50+ command-line flags, bundling, validation, and help text

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const cli_helpers = @import("utils/cli_test_helpers.zig");

// Import modules under test (these will be created by coder)
// const cli = @import("../src/cli.zig");
// const Config = @import("../src/config.zig").Config;

const Config = cli_helpers.MockConfig;

// =============================================================================
// BASIC ARGUMENT PARSING TESTS
// =============================================================================

test "parse empty arguments - should show usage" {
    // Empty args should require at least host:port or -l
    // This test validates that the parser detects missing required arguments

    const allocator = testing.allocator;
    var args = [_][]const u8{"zig-nc"};

    // Expected: error.MissingArguments or similar
    // const config = cli.parseArgs(allocator, &args) catch |err| {
    //     try expectEqual(error.MissingArguments, err);
    //     return;
    // };
    // try expect(false); // Should not reach here
}

test "parse basic connect mode - host and port" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "example.com", "80" };

    // Expected behavior:
    // - mode = .connect
    // - host = "example.com"
    // - port = 80

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(Config.Mode.connect, config.mode);
    // try expectEqualStrings("example.com", config.host.?);
    // try expectEqual(@as(u16, 80), config.port);
}

test "parse listen mode - with port only" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "8080" };

    // Expected:
    // - mode = .listen
    // - port = 8080
    // - host = null (listen on all interfaces)

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.listen);
    // try expectEqual(@as(u16, 8080), config.port);
    // try expect(config.host == null);
}

test "parse listen mode - with specific bind address" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "127.0.0.1", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.listen);
    // try expectEqualStrings("127.0.0.1", config.host.?);
    // try expectEqual(@as(u16, 8080), config.port);
}

// =============================================================================
// FLAG BUNDLING TESTS
// =============================================================================

test "parse bundled short flags - lv" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-lv", "8080" };

    // -lv should expand to -l -v
    // Expected:
    // - listen = true
    // - verbose = 1

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.listen);
    // try expectEqual(@as(u8, 1), config.verbose);
}

test "parse bundled flags - lvk" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-lvk", "8080" };

    // -lvk should expand to -l -v -k
    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.listen);
    // try expect(config.keep_open);
    // try expectEqual(@as(u8, 1), config.verbose);
}

test "parse multiple verbose flags - vv" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-vv", "example.com", "80" };

    // -vv should set verbose = 2
    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u8, 2), config.verbose);
}

test "parse separate verbose flags - v v" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-v", "-v", "example.com", "80" };

    // Two separate -v flags should also set verbose = 2
    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u8, 2), config.verbose);
}

// =============================================================================
// PROTOCOL FLAGS TESTS
// =============================================================================

test "parse UDP flag - short form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-u", "example.com", "53" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.udp);
}

test "parse UDP flag - long form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--udp", "example.com", "53" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.udp);
}

test "parse IPv4 force flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-4", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.ipv4);
    // try expect(!config.ipv6);
}

test "parse IPv6 force flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-6", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.ipv6);
    // try expect(!config.ipv4);
}

test "parse IPv4 and IPv6 together - should error" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-4", "-6", "example.com", "80" };

    // Conflicting flags - should return error
    // try expectError(error.ConflictingFlags, cli.parseArgs(allocator, &args));
}

// =============================================================================
// TIMEOUT FLAGS TESTS
// =============================================================================

test "parse connect timeout - short form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-w", "30", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u32, 30), config.connect_timeout.?);
}

test "parse connect timeout - long form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--connect-timeout", "45", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u32, 45), config.connect_timeout.?);
}

test "parse idle timeout" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-i", "60", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u32, 60), config.idle_timeout.?);
}

test "parse quit-after-eof timeout" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-q", "5", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u32, 5), config.quit_after_eof.?);
}

test "parse invalid timeout - non-numeric" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-w", "abc", "example.com", "80" };

    // Should error on invalid number
    // try expectError(error.InvalidNumber, cli.parseArgs(allocator, &args));
}

test "parse invalid timeout - negative" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-w", "-5", "example.com", "80" };

    // Should error on negative timeout
    // try expectError(error.InvalidNumber, cli.parseArgs(allocator, &args));
}

// =============================================================================
// SOURCE ADDRESS/PORT TESTS
// =============================================================================

test "parse source port" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-p", "12345", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u16, 12345), config.source_port.?);
}

test "parse source address" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-s", "192.168.1.100", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("192.168.1.100", config.source_addr.?);
}

// =============================================================================
// TLS/SSL FLAGS TESTS
// =============================================================================

test "parse SSL flag - basic" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--ssl", "example.com", "443" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.ssl);
}

test "parse SSL with certificate - listen mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",           "-l",                "--ssl",
        "--ssl-cert",       "/path/to/cert.pem", "--ssl-key",
        "/path/to/key.pem", "8443",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.ssl);
    // try expectEqualStrings("/path/to/cert.pem", config.ssl_cert.?);
    // try expectEqualStrings("/path/to/key.pem", config.ssl_key.?);
}

test "parse SSL with verification" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",          "--ssl",                        "--ssl-verify",
        "--ssl-trustfile", "/etc/ssl/certs/ca-bundle.crt", "example.com",
        "443",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.ssl);
    // try expect(config.ssl_verify);
    // try expectEqualStrings("/etc/ssl/certs/ca-bundle.crt", config.ssl_trustfile.?);
}

test "parse SSL with SNI servername" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",           "--ssl",
        "--ssl-servername", "www.example.com",
        "192.168.1.1",      "443",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("www.example.com", config.ssl_servername.?);
}

test "parse SSL listen without cert - should error" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--ssl", "8443" };

    // SSL in listen mode requires cert and key
    // try expectError(error.MissingSSLCertificate, cli.parseArgs(allocator, &args));
}

// =============================================================================
// PROXY FLAGS TESTS
// =============================================================================

test "parse HTTP proxy" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",       "--proxy", "proxy.example.com:8080",
        "--proxy-type", "http",    "target.com",
        "80",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("proxy.example.com:8080", config.proxy.?);
    // try expectEqual(Config.ProxyType.http, config.proxy_type);
}

test "parse SOCKS5 proxy with auth" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",       "--proxy",    "socks.example.com:1080",
        "--proxy-type", "socks5",     "--proxy-auth",
        "user:pass",    "target.com", "80",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(Config.ProxyType.socks5, config.proxy_type);
    // try expectEqualStrings("user:pass", config.proxy_auth.?);
}

test "parse invalid proxy type" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",       "--proxy", "proxy.com:8080",
        "--proxy-type", "invalid", "target.com",
        "80",
    };

    // try expectError(error.InvalidProxyType, cli.parseArgs(allocator, &args));
}

// =============================================================================
// ACCESS CONTROL FLAGS TESTS
// =============================================================================

test "parse allow list - single IP" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--allow", "192.168.1.100", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("192.168.1.100", config.allow.?);
}

test "parse allow list - CIDR range" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--allow", "192.168.1.0/24", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("192.168.1.0/24", config.allow.?);
}

test "parse deny list" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--deny", "10.0.0.0/8", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("10.0.0.0/8", config.deny.?);
}

// =============================================================================
// EXEC FLAGS TESTS
// =============================================================================

test "parse exec flag - with program" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "-e", "/bin/sh", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("/bin/sh", config.exec.?);
}

test "parse sh-exec flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "-c", "echo 'Hello'", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("echo 'Hello'", config.sh_exec.?);
}

test "parse exec with allow - safe combination" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",  "-l",            "-e",   "/bin/sh",
        "--allow", "192.168.1.100", "8080",
    };

    // This should be the recommended safe way to use -e
    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("/bin/sh", config.exec.?);
    // try expectEqualStrings("192.168.1.100", config.allow.?);
}

// =============================================================================
// I/O FLAGS TESTS
// =============================================================================

const cli = @import("../src/cli.zig");
const config = @import("../src/config.zig");

test "parse send-only flag" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--send-only", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.send_only);
    try expect(!cfg.recv_only);
}

test "parse recv-only flag" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--recv-only", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.recv_only);
    try expect(!cfg.send_only);
}

test "parse send-only and recv-only together - should error" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{
        "zigcat",      "--send-only", "--recv-only",
        "example.com", "80",
    };

    // Should error due to conflicting flags
    try expectError(cli.CliError.ConflictingIOModes, cli.parseArgs(allocator, &args));
}

test "parse output file flag - short form" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/output.log", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "parse output file flag - long form" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--output", "/tmp/output.log", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "parse append flag" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{
        "zigcat",      "-o", "/tmp/output.log", "--append",
        "example.com", "80",
    };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.append_output);
    try expectEqualStrings("/tmp/output.log", cfg.output_file.?);
}

test "parse hex-dump flag - short form without file" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-x", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.hex_dump);
    try expect(cfg.hex_dump_file == null);
}

test "parse hex-dump flag - long form without file" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--hex-dump", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.hex_dump);
    try expect(cfg.hex_dump_file == null);
}

test "parse hex-dump flag - with file" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-x", "/tmp/dump.hex", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.hex_dump);
    try expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "parse hex-dump flag - long form with file" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--hex-dump", "/tmp/dump.hex", "example.com", "80" };

    const cfg = try cli.parseArgs(allocator, &args);
    defer cfg.deinit(allocator);

    try expect(cfg.hex_dump);
    try expectEqualStrings("/tmp/dump.hex", cfg.hex_dump_file.?);
}

test "parse empty output file path - should error" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-o", "", "example.com", "80" };

    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(allocator, &args));
}

test "parse empty hex dump file path - should error" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-x", "", "example.com", "80" };

    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(allocator, &args));
}

test "parse output file with null bytes - should error" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "-o", "/tmp/out\x00put.log", "example.com", "80" };

    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(allocator, &args));
}

test "parse TLS certificate path with traversal - should error" {
    const allocator = testing.allocator;
    var args = [_][:0]const u8{ "zigcat", "--ssl", "--ssl-cert", "../secrets/cert.pem", "--ssl-key", "/tmp/key.pem", "example.com", "443" };

    try expectError(cli.CliError.InvalidOutputPath, cli.parseArgs(allocator, &args));
}

test "parse CRLF flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-C", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.crlf);
}

test "parse hex-dump flag - to stdout" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-x", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.hex_dump != null);
}

test "parse hex-dump flag - to file" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-x", "/tmp/dump.hex", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("/tmp/dump.hex", config.hex_dump.?);
}

test "parse output file flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-o", "/tmp/output.log", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("/tmp/output.log", config.output.?);
}

test "parse output with append flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{
        "zig-nc",      "-o", "/tmp/output.log", "--append",
        "example.com", "80",
    };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.append);
}

// =============================================================================
// MISC FLAGS TESTS
// =============================================================================

test "parse zero-io flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-z", "example.com", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.zero_io);
}

test "parse nodns flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-n", "192.168.1.1", "80" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.nodns);
}

test "parse telnet flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-t", "example.com", "23" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.telnet);
}

test "parse keep-open flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "-k", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.keep_open);
}

test "parse broker mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--broker", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.broker);
}

test "parse chat mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "--chat", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.chat);
}

test "parse max-conns" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "-k", "--max-conns", "32", "8080" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqual(@as(u32, 32), config.max_conns);
}

// =============================================================================
// PLATFORM-SPECIFIC FLAGS TESTS
// =============================================================================

test "parse unix socket - client mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-U", "/tmp/socket" };

    // Should only work on Unix platforms
    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expectEqualStrings("/tmp/socket", config.unixsock.?);
}

test "parse unix socket - listen mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l", "-U", "/tmp/socket" };

    // const config = try cli.parseArgs(allocator, &args);
    // defer config.deinit(allocator);
    //
    // try expect(config.listen);
    // try expectEqualStrings("/tmp/socket", config.unixsock.?);
}

// =============================================================================
// HELP AND VERSION TESTS
// =============================================================================

test "parse help flag - short form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-h" };

    // Should print help and exit (not return config)
    // const result = cli.parseArgs(allocator, &args);
    // try expectError(error.ShowHelp, result);
}

test "parse help flag - long form" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--help" };

    // try expectError(error.ShowHelp, cli.parseArgs(allocator, &args));
}

test "parse version flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--version" };

    // try expectError(error.ShowVersion, cli.parseArgs(allocator, &args));
}

// =============================================================================
// INVALID ARGUMENT TESTS
// =============================================================================

test "parse unknown flag" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--unknown-flag", "example.com", "80" };

    // try expectError(error.UnknownFlag, cli.parseArgs(allocator, &args));
}

test "parse invalid port - too large" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "example.com", "99999" };

    // try expectError(error.InvalidPort, cli.parseArgs(allocator, &args));
}

test "parse invalid port - non-numeric" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "example.com", "http" };

    // try expectError(error.InvalidPort, cli.parseArgs(allocator, &args));
}

test "parse missing required value - timeout" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-w", "example.com", "80" };

    // -w requires a numeric value, "example.com" is not valid
    // try expectError(error.InvalidNumber, cli.parseArgs(allocator, &args));
}

test "parse missing required value - source port" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-p" };

    // -p requires a port number
    // try expectError(error.MissingValue, cli.parseArgs(allocator, &args));
}

// =============================================================================
// CONFIG VALIDATION TESTS
// =============================================================================

test "validate listen mode requires port" {
    // Listen mode must have a port specified
    // This is a validation test, not just parsing
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-l" };

    // try expectError(error.MissingPort, cli.parseArgs(allocator, &args));
}

test "validate connect mode requires host and port" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "example.com" };

    // Missing port in connect mode
    // try expectError(error.MissingPort, cli.parseArgs(allocator, &args));
}

test "validate UDP with Unix socket - should error" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-u", "-U", "/tmp/socket" };

    // UDP and Unix sockets are incompatible
    // try expectError(error.ConflictingFlags, cli.parseArgs(allocator, &args));
}

test "validate broker requires listen mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "--broker", "example.com", "80" };

    // Broker mode only makes sense with -l
    // try expectError(error.InvalidMode, cli.parseArgs(allocator, &args));
}

test "validate exec requires listen mode" {
    const allocator = testing.allocator;
    var args = [_][]const u8{ "zig-nc", "-e", "/bin/sh", "example.com", "80" };

    // -e only works in listen mode
    // try expectError(error.InvalidMode, cli.parseArgs(allocator, &args));
}

// =============================================================================
// HELP TEXT GENERATION TESTS
// =============================================================================

test "help text contains basic usage" {
    // const help = cli.getHelpText();
    //
    // // Should contain usage line
    // try expect(std.mem.indexOf(u8, help, "Usage:") != null);
    // try expect(std.mem.indexOf(u8, help, "zig-nc") != null);
}

test "help text contains all major flags" {
    // const help = cli.getHelpText();
    //
    // // Check for presence of major flag categories
    // try expect(std.mem.indexOf(u8, help, "-l") != null);
    // try expect(std.mem.indexOf(u8, help, "--listen") != null);
    // try expect(std.mem.indexOf(u8, help, "--ssl") != null);
    // try expect(std.mem.indexOf(u8, help, "--proxy") != null);
    // try expect(std.mem.indexOf(u8, help, "-e") != null);
    // try expect(std.mem.indexOf(u8, help, "--help") != null);
}

test "help text platform-specific - Unix sockets" {
    // On Unix platforms, help should include -U flag
    // On Windows, it should not

    // const help = cli.getHelpText();
    //
    // if (std.Target.current.os.tag == .windows) {
    //     try expect(std.mem.indexOf(u8, help, "-U") == null);
    // } else {
    //     try expect(std.mem.indexOf(u8, help, "-U") != null);
    // }
}
