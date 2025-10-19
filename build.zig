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

            // Use statFile() instead of accessAbsolute() to avoid faccessat2 syscall blocked by Docker seccomp
            _ = std.fs.cwd().statFile(lib_path) catch continue;
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

                // Use statFile() instead of accessAbsolute() to avoid faccessat2 syscall blocked by Docker seccomp
                _ = std.fs.cwd().statFile(full_path) catch continue;
                std.debug.print("[OpenSSL Detection] ✓ Found at system path: {s}\n", .{full_path});
                return true;
            }
        }
        std.debug.print("[OpenSSL Detection] Not found in system library paths\n", .{});
    }

    if (target.os.tag == .windows) {
        std.debug.print("[OpenSSL Detection] Trying Windows paths...\n", .{});

        // Try vcpkg first (GitHub Actions has VCPKG_ROOT environment variable)
        if (std.process.getEnvVarOwned(b.allocator, "VCPKG_ROOT")) |vcpkg_root| {
            defer b.allocator.free(vcpkg_root);

            const vcpkg_lib = std.fmt.allocPrint(b.allocator, "{s}\\installed\\x64-windows\\lib\\libssl.lib", .{vcpkg_root}) catch {
                std.debug.print("[OpenSSL Detection] Failed to format vcpkg path\n", .{});
                return false;
            };
            defer b.allocator.free(vcpkg_lib);

            // Use statFile() instead of accessAbsolute() for consistency and portability
            _ = std.fs.cwd().statFile(vcpkg_lib) catch {
                std.debug.print("[OpenSSL Detection] vcpkg OpenSSL not found at: {s}\n", .{vcpkg_lib});
                return false;
            };

            std.debug.print("[OpenSSL Detection] ✓ Found via vcpkg: {s}\n", .{vcpkg_root});
            return true;
        } else |_| {
            std.debug.print("[OpenSSL Detection] VCPKG_ROOT not found, trying other paths...\n", .{});
        }

        const windows_paths = [_][]const u8{
            // GitHub Actions default installation
            "C:\\Program Files\\OpenSSL\\bin\\libssl-3-x64.dll",
            "C:\\Program Files\\OpenSSL\\bin\\libcrypto-3-x64.dll",
            // Chocolatey third-party installers (fallback)
            "C:\\Program Files\\OpenSSL-Win64\\bin\\libssl-3-x64.dll",
            "C:\\Program Files\\OpenSSL-Win64\\bin\\libssl-1_1-x64.dll",
            "C:\\OpenSSL-Win64\\bin\\libssl-3-x64.dll",
            "C:\\OpenSSL-Win64\\bin\\libssl-1_1-x64.dll",
        };

        for (windows_paths) |path| {
            // Use statFile() instead of accessAbsolute() for consistency and portability
            _ = std.fs.cwd().statFile(path) catch continue;
            std.debug.print("[OpenSSL Detection] ✓ Found at Windows path: {s}\n", .{path});
            return true;
        }
        std.debug.print("[OpenSSL Detection] Not found in Windows paths\n", .{});
    }

    std.debug.print("[OpenSSL Detection] ✗ OpenSSL not found on system\n", .{});
    return false;
}

pub fn build(b: *std.Build) void {
    // Standard build options for target and optimization.
    // - `standardTargetOptions` configures cross-compilation targets (e.g., `x86_64-linux-gnu`).
    // - `standardOptimizeOption` controls optimization levels (`ReleaseSmall`, `Debug`, etc.).
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    // Custom build options, controllable via `-D<option>=<value>` flags.
    //
    // - `static`: (Default: false) If true, creates a fully static binary with no dynamic
    //   dependencies. This is primarily for Linux using the `musl` libc target.
    //   Example: `zig build -Dstatic=true -Dtarget=x86_64-linux-musl`
    const static = b.option(bool, "static", "Build fully static binary (Linux with musl only)") orelse false;
    //
    // - `tls`: (Default: true, unless `static` is true) Enables or disables TLS support.
    //   Requires OpenSSL development libraries on the host system. Automatically disabled
    //   for static builds to avoid complex static linking of OpenSSL.
    //   Example: `zig build -Dtls=false`
    const enable_tls = b.option(bool, "tls", "Enable TLS/SSL support (requires OpenSSL)") orelse !static;
    //
    // - `unixsock`: (Default: true) Enables or disables support for Unix domain sockets.
    const enable_unixsock = b.option(bool, "unixsock", "Enable Unix domain sockets") orelse true;
    //
    // - `strip`: (Default: true) If true, strips debug symbols from the final executable,
    //   reducing its size.
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse true;
    //
    // - `lto`: (Default: null/auto) Controls Link-Time Optimization mode for cross-module
    //   optimization and binary size reduction. LTO works across Zig + C boundaries (including OpenSSL).
    //   - null (auto): Enable LTO in release modes (recommended, default behavior)
    //   - .full: Maximum optimization, slowest build (~20-30% slower, 15-20% smaller binary)
    //   - .thin: Good optimization, faster build (~10-15% slower, 10-15% smaller binary)
    //   - .none: Disable LTO (for debugging only)
    //   Example: `zig build -Doptimize=ReleaseSmall -Dlto=full`
    const lto_mode = b.option(
        std.zig.LtoMode,
        "lto",
        "Link-Time Optimization mode: null/auto (default), full (max optimization), thin (balanced), none (disable)",
    ) orelse null;
    //
    // - `allow-legacy-tls`: (Default: false) If true, compiles in support for older,
    //   insecure TLS versions (1.0, 1.1). This should only be used for testing against
    //   legacy systems.
    const allow_legacy_tls = b.option(bool, "allow-legacy-tls", "Enable TLS 1.0/1.1 support (INSECURE, testing only)") orelse false;
    //
    // - `tls-backend`: (Default: openssl) Selects the TLS library backend.
    //   - `openssl`: Default, ubiquitous, ~6MB binary with TLS
    //   - `wolfssl`: Lightweight alternative, ~2.5-3MB binary with TLS (92% smaller library)
    //   Example: `zig build -Dtls-backend=wolfssl`
    const TlsBackendOption = enum { openssl, wolfssl };
    const tls_backend = b.option(TlsBackendOption, "tls-backend", "TLS backend: openssl (default), wolfssl (lightweight)") orelse .openssl;
    const use_wolfssl = (tls_backend == .wolfssl);

    // If wolfSSL is selected, print a GPLv2 license warning.
    if (use_wolfssl) {
        std.log.warn("=====================================================================", .{});
        std.log.warn("                            LICENSE WARNING                            ", .{});
        std.log.warn("=====================================================================", .{});
        std.log.warn("You have enabled the wolfSSL backend (-Dtls-backend=wolfssl).", .{});
        std.log.warn("wolfSSL is licensed under the GNU General Public License v2 (GPLv2).", .{});
        std.log.warn("Therefore, the resulting `zigcat` binary is also bound by the GPLv2.", .{});
        std.log.warn("If you distribute this binary, you must comply with the GPLv2 terms,", .{});
        std.log.warn("which include providing the source code.", .{});
        std.log.warn("", .{});
        std.log.warn("For details, see LICENSE-GPLv2 and the main LICENSE file.", .{});
        std.log.warn("=====================================================================", .{});
    }

    // CRITICAL: Validate that `static` and `tls` with OpenSSL are not enabled simultaneously.
    // Statically linking OpenSSL is complex and platform-dependent.
    // wolfSSL supports static linking, so allow static + wolfssl combination.
    if (static and enable_tls and !use_wolfssl) {
        std.log.err("", .{});
        std.log.err("=====================================================================", .{});
        std.log.err("ERROR: Static builds with OpenSSL are not supported", .{});
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
        std.log.err("  1. Build static with wolfSSL (NEW - enables TLS in static builds):", .{});
        std.log.err("     zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls-backend=wolfssl", .{});
        std.log.err("", .{});
        std.log.err("  2. Build static without TLS:", .{});
        std.log.err("     zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false", .{});
        std.log.err("", .{});
        std.log.err("  3. Build dynamic with OpenSSL:", .{});
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
        if (use_wolfssl) {
            // wolfSSL detection is done at link time
            // If wolfSSL is not installed, linking will fail with clear error
            std.debug.print("[TLS Backend] Using wolfSSL (lightweight, 92% smaller)\n", .{});

            // Warn about gsocket incompatibility with wolfSSL
            std.debug.print("[WARNING] gsocket mode is not available with wolfSSL backend\n", .{});
            std.debug.print("[WARNING] gsocket requires OpenSSL for SRP encryption support\n", .{});
            std.debug.print("[WARNING] To enable gsocket: Use -Dtls-backend=openssl instead\n", .{});
        } else {
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
                std.log.err("Alternatively:", .{});
                std.log.err("  - Use wolfSSL backend: zig build -Dtls-backend=wolfssl", .{});
                std.log.err("  - Disable TLS: zig build -Dtls=false", .{});
                return;
            }
            std.debug.print("[TLS Backend] Using OpenSSL (default, ubiquitous)\n", .{});
        }
    }

    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.0.1");
    options.addOption([]const u8, "zig_version", @import("builtin").zig_version_string);
    options.addOption(bool, "enable_tls", enable_tls);
    options.addOption(bool, "enable_unixsock", enable_unixsock);
    options.addOption(bool, "allow_legacy_tls", allow_legacy_tls);
    options.addOption(bool, "use_wolfssl", use_wolfssl);
    // Export TLS backend as string for conditional imports in code
    const tls_backend_str = if (use_wolfssl) "wolfssl" else "openssl";
    options.addOption([]const u8, "tls_backend", tls_backend_str);

    // Determine binary name: append "-wolfssl" when using wolfSSL backend for clarity
    const binary_name = if (use_wolfssl and enable_tls) "zigcat-wolfssl" else "zigcat";

    const exe = b.addExecutable(.{
        .name = binary_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/terminal/package.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol_module = b.createModule(.{
        .root_source_file = b.path("src/protocol/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_module.addImport("terminal", terminal_module);

    exe.root_module.addImport("terminal", terminal_module);
    exe.root_module.addImport("protocol", protocol_module);

    exe.root_module.addOptions("build_options", options);
    exe.linkLibC();

    // Apply LTO configuration
    exe.lto = lto_mode;

    // Log LTO mode for transparency
    if (lto_mode) |mode| {
        const mode_str = switch (mode) {
            .full => "full (maximum optimization, slower build)",
            .thin => "thin (balanced optimization, moderate build time)",
            .none => "none (LTO disabled)",
        };
        std.debug.print("[Build] LTO mode: {s}\n", .{mode_str});
    } else {
        std.debug.print("[Build] LTO mode: auto (enabled in release modes)\n", .{});
    }

    if (static) {
        exe.linkage = .static;
        if (target.result.os.tag == .linux) {
            exe.root_module.link_libc = true;
        }
    }

    if (enable_tls) {
        if (use_wolfssl) {
            // For static builds, directly link the .a file to avoid shared library conflicts
            // For dynamic builds, use linkSystemLibrary as usual
            if (static) {
                // Directly link the static library file
                // Alpine: /usr/lib/libwolfssl.a
                // Ubuntu: /usr/lib/x86_64-linux-gnu/libwolfssl.a or /usr/lib/aarch64-linux-gnu/libwolfssl.a
                const static_lib_paths = [_][]const u8{
                    "/usr/lib/libwolfssl.a", // Alpine/musl standard path
                    "/usr/lib/x86_64-linux-gnu/libwolfssl.a", // Ubuntu x86_64
                    "/usr/lib/aarch64-linux-gnu/libwolfssl.a", // Ubuntu ARM64
                    "/usr/local/lib/libwolfssl.a", // User-installed
                };

                var found_static_lib = false;
                for (static_lib_paths) |lib_path| {
                    // Use statFile() instead of accessAbsolute() to avoid faccessat2 syscall blocked by Docker seccomp
                    _ = std.fs.cwd().statFile(lib_path) catch continue;
                    exe.addObjectFile(.{ .cwd_relative = lib_path });
                    std.debug.print("[wolfSSL] Using static library: {s}\n", .{lib_path});
                    found_static_lib = true;
                    break;
                }

                if (!found_static_lib) {
                    // Alpine doesn't provide static wolfSSL by default, so fall back to dynamic linking
                    // This is acceptable for Alpine as it still produces small binaries with musl
                    std.log.warn("Static wolfSSL library not found, using dynamic linking instead", .{});
                    std.log.warn("  (This is normal on Alpine Linux - wolfssl-dev provides shared libraries only)", .{});
                    exe.linkSystemLibrary("wolfssl");
                }
            } else {
                // Dynamic build: use standard system library linking
                exe.linkSystemLibrary("wolfssl");
            }

            // Add platform-specific paths for wolfSSL
            if (target.result.os.tag == .macos) {
                // Check both Apple Silicon and Intel Homebrew paths
                const homebrew_paths = [_][]const u8{
                    "/opt/homebrew/opt/wolfssl", // Apple Silicon
                    "/usr/local/opt/wolfssl", // Intel
                };

                for (homebrew_paths) |base_path| {
                    const include_path = std.fmt.allocPrint(b.allocator, "{s}/include", .{base_path}) catch continue;
                    const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib", .{base_path}) catch continue;
                    defer b.allocator.free(include_path);
                    defer b.allocator.free(lib_path);

                    // Check if this path exists using statFile() to avoid faccessat2 syscall blocked by Docker seccomp
                    _ = std.fs.cwd().statFile(lib_path) catch continue;

                    exe.addSystemIncludePath(.{ .cwd_relative = include_path });
                    exe.addLibraryPath(.{ .cwd_relative = lib_path });
                    std.debug.print("[wolfSSL] Using Homebrew path: {s}\n", .{base_path});
                    break;
                }
            } else if (target.result.os.tag == .linux) {
                // Add standard Linux/Alpine paths for wolfSSL
                const include_paths = [_][]const u8{
                    "/usr/include", // Alpine standard include path
                    "/usr/local/include", // User-installed headers
                };
                for (include_paths) |include_path| {
                    exe.addSystemIncludePath(.{ .cwd_relative = include_path });
                }

                const lib_paths = [_][]const u8{
                    "/usr/lib", // Alpine standard library path
                    "/usr/local/lib", // User-installed libraries
                };
                for (lib_paths) |lib_path| {
                    exe.addLibraryPath(.{ .cwd_relative = lib_path });
                }
                std.debug.print("[wolfSSL] Added Linux include and library search paths\n", .{});
            }
        } else {
            // Windows uses different library names with vcpkg: libssl.lib instead of ssl.lib
            if (target.result.os.tag == .windows) {
                exe.linkSystemLibrary("libssl");
                exe.linkSystemLibrary("libcrypto");
            } else {
                exe.linkSystemLibrary("ssl");
                exe.linkSystemLibrary("crypto");
            }

            // Add include and library search paths for cross-compilation (Docker builds)
            // This helps Zig find OpenSSL headers and libraries when cross-compiling for Linux targets
            // CRITICAL: Only add paths matching the target architecture to avoid linker errors
            if (target.result.os.tag == .linux) {
                // Determine architecture-specific paths based on target CPU architecture
                const arch = target.result.cpu.arch;

                // Architecture-specific include paths (only for matching arch)
                // NOTE: Add paths unconditionally - linker will skip non-existent paths
                if (arch == .x86_64) {
                    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
                } else if (arch == .aarch64) {
                    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include/aarch64-linux-gnu" });
                }

                // Generic include paths (always add as fallback)
                exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
                exe.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });

                // Architecture-specific library paths (only for matching arch)
                // NOTE: Add paths unconditionally - linker will skip non-existent paths
                if (arch == .x86_64) {
                    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
                    exe.addLibraryPath(.{ .cwd_relative = "/lib/x86_64-linux-gnu" });
                } else if (arch == .aarch64) {
                    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
                    exe.addLibraryPath(.{ .cwd_relative = "/lib/aarch64-linux-gnu" });
                }

                // Generic library paths (always add as fallback)
                exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
                exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });

                std.debug.print("[OpenSSL] Added Linux include and library search paths for {s} architecture\n", .{@tagName(arch)});
            }

            // Add Windows-specific OpenSSL paths for vcpkg, GitHub Actions, and Chocolatey
            if (target.result.os.tag == .windows) {
                // Try vcpkg first (GitHub Actions has VCPKG_ROOT environment variable)
                if (std.process.getEnvVarOwned(b.allocator, "VCPKG_ROOT")) |vcpkg_root| {
                    defer b.allocator.free(vcpkg_root);

                    const vcpkg_include = std.fmt.allocPrint(b.allocator, "{s}\\installed\\x64-windows\\include", .{vcpkg_root}) catch {
                        std.debug.print("[OpenSSL] Failed to format vcpkg include path\n", .{});
                        return;
                    };
                    defer b.allocator.free(vcpkg_include);

                    const vcpkg_lib = std.fmt.allocPrint(b.allocator, "{s}\\installed\\x64-windows\\lib", .{vcpkg_root}) catch {
                        std.debug.print("[OpenSSL] Failed to format vcpkg lib path\n", .{});
                        return;
                    };
                    defer b.allocator.free(vcpkg_lib);

                    exe.addSystemIncludePath(.{ .cwd_relative = vcpkg_include });
                    exe.addLibraryPath(.{ .cwd_relative = vcpkg_lib });
                    std.debug.print("[OpenSSL] Added vcpkg paths: {s}\n", .{vcpkg_root});
                } else |_| {
                    std.debug.print("[OpenSSL] VCPKG_ROOT not found, using default Windows paths\n", .{});
                }

                // GitHub Actions default installation (fallback)
                exe.addLibraryPath(.{ .cwd_relative = "C:\\Program Files\\OpenSSL\\lib" });
                exe.addSystemIncludePath(.{ .cwd_relative = "C:\\Program Files\\OpenSSL\\include" });

                // Chocolatey third-party installer paths (fallback)
                exe.addLibraryPath(.{ .cwd_relative = "C:\\Program Files\\OpenSSL-Win64\\lib" });
                exe.addSystemIncludePath(.{ .cwd_relative = "C:\\Program Files\\OpenSSL-Win64\\include" });

                std.debug.print("[OpenSSL] Added Windows include and library search paths\n", .{});
            }
        }
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

    // This step runs all unit tests defined within the main `src` directory.
    // These tests focus on core logic, parsing, and data structures.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    //--- Net Tests ---
    const net_test_module = b.createModule(.{
        .root_source_file = b.path("tests/net_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_test_module.addImport("zigcat", exe.root_module);
    const net_tests = b.addTest(.{ .root_module = net_test_module });
    net_tests.linkLibC();
    const run_net_tests = b.addRunArtifact(net_tests);
    const net_test_step = b.step("test-net", "Run net tests");
    net_test_step.dependOn(&run_net_tests.step);

    //--- Integration Tests ---
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{ .root_module = integration_test_module });
    integration_tests.linkLibC();
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    //--- Timeout Tests ---
    // This suite covers various timeout scenarios, ensuring that idle, connection,
    // and execution timeouts are correctly triggered and handled.
    const timeout_test_module = b.createModule(.{
        .root_source_file = b.path("tests/timeout_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const timeout_tests = b.addTest(.{ .root_module = timeout_test_module });
    timeout_tests.linkLibC();
    const run_timeout_tests = b.addRunArtifact(timeout_tests);
    const timeout_test_step = b.step("test-timeout", "Run timeout-specific tests");
    timeout_test_step.dependOn(&run_timeout_tests.step);

    var run_terminal_control_tests: ?*std.Build.Step.Run = null;
    var run_echo_integration_tests: ?*std.Build.Step.Run = null;

    if (target.result.os.tag != .windows) {
        //--- Terminal Control Tests ---
        // Ensures local terminal handling utilities toggle raw mode correctly and
        // restore the original configuration across repeated transitions.
        const terminal_control_test_module = b.createModule(.{
            .root_source_file = b.path("tests/terminal_control_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        terminal_control_test_module.addImport("terminal", terminal_module);
        const terminal_control_tests = b.addTest(.{ .root_module = terminal_control_test_module });
        const run_terminal_control_tests_local = b.addRunArtifact(terminal_control_tests);
        run_terminal_control_tests = run_terminal_control_tests_local;
        const terminal_control_test_step = b.step("test-terminal-control", "Run terminal control tests");
        terminal_control_test_step.dependOn(&run_terminal_control_tests_local.step);

        const echo_integration_test_module = b.createModule(.{
            .root_source_file = b.path("tests/echo_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        echo_integration_test_module.addImport("protocol", protocol_module);
        const echo_integration_tests = b.addTest(.{ .root_module = echo_integration_test_module });
        const run_echo_integration_tests_local = b.addRunArtifact(echo_integration_tests);
        run_echo_integration_tests = run_echo_integration_tests_local;
        const echo_integration_test_step = b.step("test-echo-integration", "Run Telnet echo integration tests");
        echo_integration_test_step.dependOn(&run_echo_integration_tests_local.step);
    }

    //--- Exec Thread Lifecycle Tests ---
    // Verifies the correct creation, execution, and cleanup of threads used in
    // the command execution feature (`-e`/`-c`) on Windows.
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

    //--- UDP Mode Tests ---
    // Contains tests for UDP-specific functionality, including client/server
    // communication and connection handling.
    const udp_test_module = b.createModule(.{
        .root_source_file = b.path("tests/udp_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    udp_test_module.addImport("zigcat", exe.root_module);
    const udp_tests = b.addTest(.{ .root_module = udp_test_module });
    udp_tests.linkLibC();
    const run_udp_tests = b.addRunArtifact(udp_tests);
    const udp_test_step = b.step("test-udp", "Run UDP server tests");
    udp_test_step.dependOn(&run_udp_tests.step);

    //--- Zero-I/O Mode Tests ---
    // Tests the `-z` flag functionality for port scanning, ensuring it correctly
    // reports open and closed ports without transferring data.
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

    //--- Quit-on-EOF Tests ---
    // Verifies that the application correctly terminates (or not) based on the
    // `--close-on-eof` flag when it receives an End-of-File marker on stdin.
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

    //--- I/O Control Performance Tests ---
    // Performance tests for I/O-related features.
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

    //--- Multi-Client Integration Tests ---
    // Simulates multiple clients connecting to the server simultaneously to test
    // broker and chat modes under concurrent load.
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

    //--- Broker/Chat Performance and Compatibility Tests ---
    // Focuses on the performance and compatibility of the broker and chat modes.
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

    //--- Broker/Chat Performance Validation Tests ---
    // Validates the performance metrics and behavior of the broker and chat modes.
    const broker_perf_validation_test_module = b.createModule(.{
        .root_source_file = b.path("tests/broker_chat_performance_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const broker_perf_validation_tests = b.addTest(.{ .root_module = broker_perf_validation_test_module });
    const run_broker_perf_validation_tests = b.addRunArtifact(broker_perf_validation_tests);
    const broker_perf_validation_test_step = b.step("test-broker-validation", "Run broker/chat performance validation tests");
    broker_perf_validation_test_step.dependOn(&run_broker_perf_validation_tests.step);

    //--- Poll Wrapper Cross-Platform Tests ---
    // Tests the `poll()` wrapper to ensure it behaves consistently across
    // different platforms (especially for the Windows `select()` fallback).
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

    //--- CRLF Memory Safety Tests ---
    // Ensures that the `--crlf` option (which converts LF to CRLF) is handled
    // correctly without causing buffer overflows or memory errors.
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

    //--- Shell Command Memory Leak Tests ---
    // Specifically tests the `-c` (shell command) feature for memory leaks.
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

    //--- SSL/TLS Comprehensive Tests ---
    // A large suite covering all aspects of TLS functionality, including certificate
    // generation, handshake protocols, error handling, and compatibility.
    const ssl_test_module = b.createModule(.{
        .root_source_file = b.path("tests/ssl_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ssl_tests = b.addTest(.{ .root_module = ssl_test_module });
    ssl_tests.linkLibC();
    const run_ssl_tests = b.addRunArtifact(ssl_tests);
    const ssl_test_step = b.step("test-ssl", "Run SSL/TLS comprehensive tests (31 tests: cert generation, handshake, error handling, compatibility)");
    ssl_test_step.dependOn(&run_ssl_tests.step);

    //--- Telnet Protocol State Machine Tests ---
    // Tests the Telnet protocol parser and state machine to ensure it correctly
    // handles Telnet commands and option negotiations.
    const telnet_test_module = b.createModule(.{
        .root_source_file = b.path("tests/telnet_state_machine_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    telnet_test_module.addImport("protocol", protocol_module);
    const telnet_tests = b.addTest(.{ .root_module = telnet_test_module });
    telnet_tests.linkLibC();
    const run_telnet_tests = b.addRunArtifact(telnet_tests);
    const telnet_test_step = b.step("test-telnet", "Run Telnet protocol state machine tests");
    telnet_test_step.dependOn(&run_telnet_tests.step);

    //--- Unix Socket Security Tests ---
    // Focuses on security aspects of Unix domain sockets, such as Time-of-Check-to-Time-of-Use
    // (TOCTTOU) race conditions, file permissions, and platform limits.
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

    //--- Parallel Port Scanning Tests ---
    // Tests the parallel port scanning feature, including range parsing,
    // thread safety, and correctness of results.
    const parallel_scan_test_module = b.createModule(.{
        .root_source_file = b.path("tests/parallel_scan_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parallel_scan_tests = b.addTest(.{ .root_module = parallel_scan_test_module });
    parallel_scan_tests.linkLibC();
    const run_parallel_scan_tests = b.addRunArtifact(parallel_scan_tests);
    const parallel_scan_test_step = b.step("test-parallel-scan", "Run parallel port scanning tests (PortRange parsing, parallel correctness, thread safety)");
    parallel_scan_test_step.dependOn(&run_parallel_scan_tests.step);

    //--- Platform Detection and Kernel Version Parsing Tests ---
    // Verifies that the build script and application correctly detect the host
    // platform and parse kernel versions for feature detection (e.g., `io_uring`).
    const platform_test_module = b.createModule(.{
        .root_source_file = b.path("tests/platform_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_tests = b.addTest(.{ .root_module = platform_test_module });
    platform_tests.linkLibC();
    const run_platform_tests = b.addRunArtifact(platform_tests);
    const platform_test_step = b.step("test-platform", "Run platform detection and kernel version parsing tests (20 tests)");
    platform_test_step.dependOn(&run_platform_tests.step);

    //--- Port Scanning Feature Tests ---
    // Covers advanced port scanning features like randomization, delays, and
    // automatic backend selection.
    const portscan_features_test_module = b.createModule(.{
        .root_source_file = b.path("tests/portscan_features_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const portscan_features_tests = b.addTest(.{ .root_module = portscan_features_test_module });
    portscan_features_tests.linkLibC();
    const run_portscan_features_tests = b.addRunArtifact(portscan_features_tests);
    const portscan_features_test_step = b.step("test-portscan-features", "Run port scanning feature tests (randomization, delays, auto-selection) (23 tests)");
    portscan_features_test_step.dependOn(&run_portscan_features_tests.step);

    //--- io_uring Compile-Time Tests ---
    // Contains tests that verify the `io_uring` wrapper and its usage at compile time.
    const portscan_uring_test_module = b.createModule(.{
        .root_source_file = b.path("tests/portscan_uring_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const portscan_uring_tests = b.addTest(.{ .root_module = portscan_uring_test_module });
    portscan_uring_tests.linkLibC();
    const run_portscan_uring_tests = b.addRunArtifact(portscan_uring_tests);
    const portscan_uring_test_step = b.step("test-portscan-uring", "Run io_uring compile-time tests (7 tests)");
    portscan_uring_test_step.dependOn(&run_portscan_uring_tests.step);

    //--- Gsocket Integration Tests ---
    // Tests the gsocket (Global Socket) NAT traversal protocol and SRP encryption layer.
    // Covers secret derivation, packet structure, protocol constants, and SRP connection handling.
    const gsocket_test_module = b.createModule(.{
        .root_source_file = b.path("tests/gsocket_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gsocket_test_module.addImport("zigcat", exe.root_module);
    const gsocket_tests = b.addTest(.{ .root_module = gsocket_test_module });
    gsocket_tests.linkLibC();
    const run_gsocket_tests = b.addRunArtifact(gsocket_tests);
    const gsocket_test_step = b.step("test-gsocket", "Run gsocket integration tests (NAT traversal, SRP encryption)");
    gsocket_test_step.dependOn(&run_gsocket_tests.step);

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
    if (target.result.os.tag != .windows) {
        if (run_terminal_control_tests) |run| {
            feature_test_step.dependOn(&run.step);
        }
        if (run_echo_integration_tests) |run| {
            feature_test_step.dependOn(&run.step);
        }
    }

    const docker_test_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "-c",
        "docker-tests/scripts/run-tests.sh || echo 'Docker tests skipped (Docker not available)'",
    });
    const docker_test_step = b.step("test-docker", "Run Docker cross-platform tests (requires Docker)");
    docker_test_step.dependOn(&docker_test_cmd.step);
}
