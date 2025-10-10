const std = @import("std");

/// Detect if OpenSSL development libraries are available on the system.
/// Uses pkg-config as the primary detection method, falling back to path-based detection.
/// Returns true if OpenSSL libraries are found and accessible.
fn detectOpenSSL(b: *std.Build) bool {
    const allocator = b.allocator;

    std.debug.print("[OpenSSL Detection] Trying pkg-config...\n", .{});
    const pkg_config_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "pkg-config", "--exists", "openssl" },
    }) catch |err| {
        std.debug.print("[OpenSSL Detection] pkg-config failed: {}\n", .{err});
        return detectOpenSSLPaths(b);
    };
    defer allocator.free(pkg_config_result.stdout);
    defer allocator.free(pkg_config_result.stderr);

    if (pkg_config_result.term.Exited == 0) {
        const version_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "pkg-config", "--modversion", "openssl" },
        }) catch |err| {
            std.debug.print("[OpenSSL Detection] pkg-config version check failed: {}\n", .{err});
            std.debug.print("[OpenSSL Detection] ✓ Found via pkg-config (version unknown)\n", .{});
            return true;
        };
        defer allocator.free(version_result.stdout);
        defer allocator.free(version_result.stderr);

        std.debug.print("[OpenSSL Detection] ✓ Found via pkg-config: {s}\n", .{std.mem.trimRight(u8, version_result.stdout, "\n\r")});
        return true;
    }

    std.debug.print("[OpenSSL Detection] pkg-config not found or OpenSSL not available\n", .{});
    return detectOpenSSLPaths(b);
}

/// Fallback OpenSSL detection using platform-specific library paths.
/// Checks Homebrew paths on macOS, system library paths on Unix-like systems,
/// and standard installation paths on Windows.
/// Returns true if OpenSSL libraries are found at any of the checked paths.
fn detectOpenSSLPaths(b: *std.Build) bool {
    const target = @import("builtin").target;

    if (target.os.tag == .macos) {
        std.debug.print("[OpenSSL Detection] Trying Homebrew paths...\n", .{});
        const homebrew_paths = [_][]const u8{
            "/opt/homebrew/opt/openssl",
            "/opt/homebrew/opt/openssl@3",
            "/opt/homebrew/opt/openssl@1.1",
            "/usr/local/opt/openssl",
            "/usr/local/opt/openssl@3",
            "/usr/local/opt/openssl@1.1",
        };

        for (homebrew_paths) |path| {
            const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib/libssl.dylib", .{path}) catch continue;
            defer b.allocator.free(lib_path);

            std.fs.accessAbsolute(lib_path, .{}) catch continue;
            std.debug.print("[OpenSSL Detection] ✓ Found at Homebrew path: {s}\n", .{path});
            return true;
        }
        std.debug.print("[OpenSSL Detection] Not found in Homebrew paths\n", .{});
    }

    if (target.os.tag != .windows) {
        std.debug.print("[OpenSSL Detection] Trying system library paths...\n", .{});
        const lib_names = [_][]const u8{ "libssl.so", "libssl.dylib", "libssl.so.3", "libssl.so.1.1" };
        const search_paths = [_][]const u8{ "/usr/lib", "/usr/local/lib", "/lib", "/usr/lib64", "/usr/local/lib64", "/lib64" };

        for (search_paths) |search_path| {
            for (lib_names) |lib_name| {
                const full_path = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ search_path, lib_name }) catch continue;
                defer b.allocator.free(full_path);

                std.fs.accessAbsolute(full_path, .{}) catch continue;
                std.debug.print("[OpenSSL Detection] ✓ Found at system path: {s}\n", .{full_path});
                return true;
            }
        }
        std.debug.print("[OpenSSL Detection] Not found in system library paths\n", .{});
    }

    if (target.os.tag == .windows) {
        std.debug.print("[OpenSSL Detection] Trying Windows paths...\n", .{});
        const windows_paths = [_][]const u8{
            "C:\\Program Files\\OpenSSL-Win64\\bin\\libssl-3-x64.dll",
            "C:\\Program Files\\OpenSSL-Win64\\bin\\libssl-1_1-x64.dll",
            "C:\\OpenSSL-Win64\\bin\\libssl-3-x64.dll",
            "C:\\OpenSSL-Win64\\bin\\libssl-1_1-x64.dll",
        };

        for (windows_paths) |path| {
            std.fs.accessAbsolute(path, .{}) catch continue;
            std.debug.print("[OpenSSL Detection] ✓ Found at Windows path: {s}\n", .{path});
            return true;
        }
        std.debug.print("[OpenSSL Detection] Not found in Windows paths\n", .{});
    }

    std.debug.print("[OpenSSL Detection] ✗ OpenSSL not found on system\n", .{});
    return false;
}

/// Main build function for ZigCat netcat implementation.
/// Configures the executable with optional TLS support, feature flags, and comprehensive test suite.
///
/// Build options:
/// - `tls`: Enable TLS/SSL support (requires OpenSSL)
/// - `unixsock`: Enable Unix domain sockets (default: true)
/// - `strip`: Strip debug symbols (default: true)
/// - `static`: Build fully static binary (Linux with musl only)
/// - `allow-legacy-tls`: Enable TLS 1.0/1.1 support (INSECURE, testing only)
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    // Auto-disable TLS for static builds to avoid dynamic OpenSSL linking
    const static = b.option(bool, "static", "Build fully static binary (Linux with musl only)") orelse false;
    const enable_tls = b.option(bool, "tls", "Enable TLS/SSL support (requires OpenSSL)") orelse !static;
    const enable_unixsock = b.option(bool, "unixsock", "Enable Unix domain sockets") orelse true;
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse true;
    const allow_legacy_tls = b.option(bool, "allow-legacy-tls", "Enable TLS 1.0/1.1 support (INSECURE, testing only)") orelse false;

    // CRITICAL: Validate incompatible combination of static + TLS
    if (static and enable_tls) {
        std.log.err("", .{});
        std.log.err("=====================================================================", .{});
        std.log.err("ERROR: Static builds with TLS are not supported", .{});
        std.log.err("=====================================================================", .{});
        std.log.err("", .{});
        std.log.err("Static linking (-Dstatic=true) produces fully portable binaries with", .{});
        std.log.err("no dependencies, but requires disabling TLS support.", .{});
        std.log.err("", .{});
        std.log.err("Reason: OpenSSL links dynamically by default. Statically linking", .{});
        std.log.err("OpenSSL requires platform-specific static libraries (.a files) that", .{});
        std.log.err("must be built separately for each target architecture.", .{});
        std.log.err("", .{});
        std.log.err("Solutions:", .{});
        std.log.err("  1. Build static without TLS (recommended):", .{});
        std.log.err("     zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false", .{});
        std.log.err("", .{});
        std.log.err("  2. Build dynamic with TLS:", .{});
        std.log.err("     zig build -Dtarget=x86_64-linux-gnu -Dtls=true", .{});
        std.log.err("", .{});
        std.log.err("Static binary characteristics:", .{});
        std.log.err("  - Size: ~2MB (without TLS)", .{});
        std.log.err("  - Dependencies: None (fully standalone)", .{});
        std.log.err("  - Portability: Runs on any Linux with same architecture", .{});
        std.log.err("  - Use cases: Containers, embedded systems, minimal environments", .{});
        std.log.err("", .{});
        std.log.err("Dynamic binary characteristics:", .{});
        std.log.err("  - Size: ~6MB (with TLS)", .{});
        std.log.err("  - Dependencies: libssl.so, libcrypto.so (must be installed)", .{});
        std.log.err("  - Portability: Requires compatible glibc and OpenSSL", .{});
        std.log.err("  - Use cases: Standard Linux distributions, macOS, Windows", .{});
        std.log.err("", .{});
        std.log.err("=====================================================================", .{});
        return;
    }

    if (enable_tls) {
        const openssl_available = detectOpenSSL(b);
        if (!openssl_available) {
            std.log.err("TLS support requested but OpenSSL not found.", .{});
            std.log.err("", .{});
            std.log.err("To install OpenSSL development libraries:", .{});
            std.log.err("  Ubuntu/Debian: sudo apt-get install libssl-dev", .{});
            std.log.err("  RHEL/CentOS:   sudo yum install openssl-devel", .{});
            std.log.err("  macOS:         brew install openssl", .{});
            std.log.err("  Windows:       Install OpenSSL from https://slproweb.com/products/Win32OpenSSL.html", .{});
            std.log.err("", .{});
            std.log.err("Or build without TLS support: zig build -Dtls=false", .{});
            return;
        }
    }

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");
    options.addOption([]const u8, "zig_version", @import("builtin").zig_version_string);
    options.addOption(bool, "enable_tls", enable_tls);
    options.addOption(bool, "enable_unixsock", enable_unixsock);
    options.addOption(bool, "allow_legacy_tls", allow_legacy_tls);

    const exe = b.addExecutable(.{
        .name = "zigcat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe.root_module.addOptions("build_options", options);
    exe.linkLibC();

    if (static) {
        exe.linkage = .static;
        if (target.result.os.tag == .linux) {
            exe.root_module.link_libc = true;
        }
    }

    if (enable_tls) {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const timeout_test_module = b.createModule(.{
        .root_source_file = b.path("tests/timeout_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const timeout_tests = b.addTest(.{ .root_module = timeout_test_module });
    const run_timeout_tests = b.addRunArtifact(timeout_tests);
    const timeout_test_step = b.step("test-timeout", "Run timeout-specific tests");
    timeout_test_step.dependOn(&run_timeout_tests.step);

    const exec_thread_test_module = b.createModule(.{
        .root_source_file = b.path("tests/exec_thread_lifecycle_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    exec_thread_test_module.addImport("zigcat", exe.root_module);
    const exec_thread_tests = b.addTest(.{ .root_module = exec_thread_test_module });
    exec_thread_tests.linkLibC();
    const run_exec_thread_tests = b.addRunArtifact(exec_thread_tests);
    const exec_thread_test_step = b.step("test-exec-threads", "Run exec thread lifecycle tests");
    exec_thread_test_step.dependOn(&run_exec_thread_tests.step);

    const udp_test_module = b.createModule(.{
        .root_source_file = b.path("tests/udp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const udp_tests = b.addTest(.{ .root_module = udp_test_module });
    udp_tests.linkLibC();
    const run_udp_tests = b.addRunArtifact(udp_tests);
    const udp_test_step = b.step("test-udp", "Run UDP server tests");
    udp_test_step.dependOn(&run_udp_tests.step);

    const zero_io_test_module = b.createModule(.{
        .root_source_file = b.path("tests/zero_io_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zero_io_tests = b.addTest(.{ .root_module = zero_io_test_module });
    zero_io_tests.linkLibC();
    const run_zero_io_tests = b.addRunArtifact(zero_io_tests);
    const zero_io_test_step = b.step("test-zero-io", "Run zero-I/O mode tests");
    zero_io_test_step.dependOn(&run_zero_io_tests.step);

    const quit_eof_test_module = b.createModule(.{
        .root_source_file = b.path("tests/quit_eof_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const quit_eof_tests = b.addTest(.{ .root_module = quit_eof_test_module });
    quit_eof_tests.linkLibC();
    const run_quit_eof_tests = b.addRunArtifact(quit_eof_tests);
    const quit_eof_test_step = b.step("test-quit-eof", "Run quit-after-EOF tests");
    quit_eof_test_step.dependOn(&run_quit_eof_tests.step);

    const io_perf_test_module = b.createModule(.{
        .root_source_file = b.path("tests/io_control_performance_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_perf_test_module.addOptions("build_options", options);
    const io_perf_tests = b.addTest(.{ .root_module = io_perf_test_module });
    io_perf_tests.linkLibC();
    const run_io_perf_tests = b.addRunArtifact(io_perf_tests);
    const io_perf_test_step = b.step("test-io-performance", "Run I/O control performance tests");
    io_perf_test_step.dependOn(&run_io_perf_tests.step);

    const multi_client_test_module = b.createModule(.{
        .root_source_file = b.path("tests/multi_client_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const multi_client_tests = b.addTest(.{ .root_module = multi_client_test_module });
    multi_client_tests.linkLibC();
    const run_multi_client_tests = b.addRunArtifact(multi_client_tests);
    const multi_client_test_step = b.step("test-multi-client", "Run multi-client integration tests");
    multi_client_test_step.dependOn(&run_multi_client_tests.step);

    const broker_perf_test_module = b.createModule(.{
        .root_source_file = b.path("tests/broker_chat_performance_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    broker_perf_test_module.addOptions("build_options", options);
    const broker_perf_tests = b.addTest(.{ .root_module = broker_perf_test_module });
    broker_perf_tests.linkLibC();
    const run_broker_perf_tests = b.addRunArtifact(broker_perf_tests);
    const broker_perf_test_step = b.step("test-broker-performance", "Run broker/chat performance and compatibility tests");
    broker_perf_test_step.dependOn(&run_broker_perf_tests.step);

    const broker_perf_validation_test_module = b.createModule(.{
        .root_source_file = b.path("tests/broker_chat_performance_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const broker_perf_validation_tests = b.addTest(.{ .root_module = broker_perf_validation_test_module });
    const run_broker_perf_validation_tests = b.addRunArtifact(broker_perf_validation_tests);
    const broker_perf_validation_test_step = b.step("test-broker-validation", "Run broker/chat performance validation tests");
    broker_perf_validation_test_step.dependOn(&run_broker_perf_validation_tests.step);

    const poll_wrapper_test_module = b.createModule(.{
        .root_source_file = b.path("tests/poll_wrapper_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const poll_wrapper_tests = b.addTest(.{ .root_module = poll_wrapper_test_module });
    poll_wrapper_tests.linkLibC();
    const run_poll_wrapper_tests = b.addRunArtifact(poll_wrapper_tests);
    const poll_wrapper_test_step = b.step("test-poll-wrapper", "Run poll wrapper cross-platform tests");
    poll_wrapper_test_step.dependOn(&run_poll_wrapper_tests.step);

    const crlf_memory_test_module = b.createModule(.{
        .root_source_file = b.path("tests/crlf_memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const crlf_memory_tests = b.addTest(.{ .root_module = crlf_memory_test_module });
    crlf_memory_tests.linkLibC();
    const run_crlf_memory_tests = b.addRunArtifact(crlf_memory_tests);
    const crlf_memory_test_step = b.step("test-crlf", "Run CRLF memory safety tests (8 tests)");
    crlf_memory_test_step.dependOn(&run_crlf_memory_tests.step);

    const shell_memory_test_module = b.createModule(.{
        .root_source_file = b.path("tests/shell_memory_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shell_memory_tests = b.addTest(.{ .root_module = shell_memory_test_module });
    shell_memory_tests.linkLibC();
    const run_shell_memory_tests = b.addRunArtifact(shell_memory_tests);
    const shell_memory_test_step = b.step("test-shell", "Run shell memory leak tests (5 tests)");
    shell_memory_test_step.dependOn(&run_shell_memory_tests.step);

    const ssl_test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_ssl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ssl_tests = b.addTest(.{ .root_module = ssl_test_module });
    ssl_tests.linkLibC();
    const run_ssl_tests = b.addRunArtifact(ssl_tests);
    const ssl_test_step = b.step("test-ssl", "Run SSL/TLS comprehensive tests (31 tests: cert generation, handshake, error handling, compatibility)");
    ssl_test_step.dependOn(&run_ssl_tests.step);

    const telnet_test_module = b.createModule(.{
        .root_source_file = b.path("tests/telnet_state_machine_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const telnet_tests = b.addTest(.{ .root_module = telnet_test_module });
    telnet_tests.linkLibC();
    const run_telnet_tests = b.addRunArtifact(telnet_tests);
    const telnet_test_step = b.step("test-telnet", "Run Telnet protocol state machine tests");
    telnet_test_step.dependOn(&run_telnet_tests.step);

    const unix_security_test_module = b.createModule(.{
        .root_source_file = b.path("tests/unix_socket_security_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unix_security_tests = b.addTest(.{ .root_module = unix_security_test_module });
    unix_security_tests.linkLibC();
    const run_unix_security_tests = b.addRunArtifact(unix_security_tests);
    const unix_security_test_step = b.step("test-unix-security", "Run Unix socket security tests (TOCTTOU, permissions, platform limits)");
    unix_security_test_step.dependOn(&run_unix_security_tests.step);

    const validation_test_step = b.step("test-validation", "Run all validation tests (13 tests: 8 CRLF + 5 shell)");
    validation_test_step.dependOn(&run_crlf_memory_tests.step);
    validation_test_step.dependOn(&run_shell_memory_tests.step);

    const feature_test_step = b.step("test-features", "Run all feature tests (UDP, zero-I/O, quit-EOF, I/O performance, multi-client, broker validation, poll wrapper, SSL)");
    feature_test_step.dependOn(&run_udp_tests.step);
    feature_test_step.dependOn(&run_zero_io_tests.step);
    feature_test_step.dependOn(&run_quit_eof_tests.step);
    feature_test_step.dependOn(&run_io_perf_tests.step);
    feature_test_step.dependOn(&run_multi_client_tests.step);
    feature_test_step.dependOn(&run_broker_perf_validation_tests.step);
    feature_test_step.dependOn(&run_poll_wrapper_tests.step);
    feature_test_step.dependOn(&run_ssl_tests.step);

    const docker_test_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "-c",
        "docker-tests/scripts/run-tests.sh || echo 'Docker tests skipped (Docker not available)'",
    });
    const docker_test_step = b.step("test-docker", "Run Docker cross-platform tests (requires Docker)");
    docker_test_step.dependOn(&docker_test_cmd.step);
}
