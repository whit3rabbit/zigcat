// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Command-line argument parser for zigcat.
//!
//! This module handles parsing command-line arguments into a Config structure.
//! Features:
//! - Long and short flag support (e.g., -v / --verbose)
//! - Value flags with validation (e.g., -w 30, --port 8080)
//! - Comma-separated list parsing (--allow-ip 10.0.0.1,192.168.1.0/24)
//! - Positional argument handling (host port)
//! - Early validation of conflicting flags
//!
//! Timeout conversion:
//! - All timeout flags (-w, -i) accept seconds
//! - Internally converted to milliseconds (* 1000)
//! - Stored in Config as u32 milliseconds
//!
//! Exec mode argument parsing:
//! - -e flag collects all following args until next flag
//! - Arguments stored in cfg.exec_args ArrayList
//! - Must be freed by Config.deinit()

const std = @import("std");
const config = @import("../config.zig");
const logging = @import("../util/logging.zig");
const path_safety = @import("../util/path_safety.zig");

/// Errors that can occur during command-line argument parsing.
pub const CliError = error{
    /// Both --send-only and --recv-only specified
    ConflictingIOModes,
    /// Conflicting options specified
    ConflictingOptions,
    /// Output file path is invalid or empty
    InvalidOutputPath,
    /// Flag requires a value but none provided
    MissingValue,
    /// Unknown command-line flag
    UnknownOption,
    /// User requested help (-h/--help)
    ShowHelp,
    /// User requested version (--version)
    ShowVersion,
    /// Timeout flag value exceeds supported range
    TimeoutTooLarge,
};

/// Parse command-line arguments into a Config structure.
///
/// Parsing rules:
/// 1. Skip program name (args[0])
/// 2. Process flags in order, handling both short (-x) and long (--xxx) forms
/// 3. Flags with values consume the next argument
/// 4. Non-flag arguments are collected as positional args
/// 5. Validate for conflicts (e.g., --send-only + --recv-only)
///
/// Special behaviors:
/// - Help/version requests return specific errors for early exit
/// - Timeout values converted from seconds to milliseconds
/// - Comma-separated lists (--allow-ip) split and stored individually
/// - Exec args (-e) consume all following non-flag arguments
///
/// Parameters:
///   allocator: For dynamic allocations (lists, strings)
///   args: Command-line arguments including program name
///
/// Returns: Populated Config structure or CliError
pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !config.Config {
    var cfg = config.Config.init(allocator);
    var positional = std.ArrayList([]const u8){};
    defer positional.deinit(allocator);

    const is_test = @import("builtin").is_test;

    var i: usize = 1; // Skip program name
    var end_of_options = false; // Track if we've seen --
    var verbose_count: u8 = 0; // Track number of -v flags

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Detect -- separator (end of options)
        if (std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }

        // After --, treat everything as positional args (no flag processing)
        if (end_of_options or !std.mem.startsWith(u8, arg, "-")) {
            // Positional argument
            try positional.append(allocator, arg);
            continue;
        }

        // Handle flags
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return CliError.ShowHelp;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return CliError.ShowVersion;
        } else if (std.mem.eql(u8, arg, "--version-all")) {
            cfg.version_info = "all";
            return CliError.ShowVersion;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--listen")) {
            cfg.listen_mode = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--udp")) {
            cfg.udp_mode = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "-vv") or std.mem.eql(u8, arg, "-vvv") or
            std.mem.eql(u8, arg, "-vvvv"))
        {
            // Count number of 'v' characters in the flag
            if (std.mem.startsWith(u8, arg, "-v")) {
                const v_count = arg.len - 1; // Subtract the leading '-'
                verbose_count += @as(u8, @intCast(v_count));
            } else {
                // --verbose counts as 1
                verbose_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            cfg.verbosity = .quiet;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--keep-open")) {
            cfg.keep_listening = true;
        } else if (std.mem.eql(u8, arg, "-4")) {
            cfg.ipv4_only = true;
        } else if (std.mem.eql(u8, arg, "-6")) {
            cfg.ipv6_only = true;
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--crlf")) {
            cfg.crlf = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nodns")) {
            cfg.no_dns = true;
        } else if (std.mem.eql(u8, arg, "--send-only")) {
            cfg.send_only = true;
        } else if (std.mem.eql(u8, arg, "--recv-only")) {
            cfg.recv_only = true;
        } else if (std.mem.eql(u8, arg, "--broker")) {
            cfg.broker_mode = true;
        } else if (std.mem.eql(u8, arg, "--chat")) {
            cfg.chat_mode = true;
        } else if (std.mem.eql(u8, arg, "--ssl")) {
            cfg.ssl = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--telnet")) {
            cfg.telnet = true;
        } else if (std.mem.eql(u8, arg, "--append")) {
            cfg.append_output = true;
        } else if (std.mem.eql(u8, arg, "--append-output")) {
            cfg.hex_dump_append = true;
        } else if (std.mem.eql(u8, arg, "--no-shutdown")) {
            cfg.no_shutdown = true;
        } else if (std.mem.eql(u8, arg, "--keep-source-port")) {
            cfg.keep_source_port = true;
        } else if (std.mem.eql(u8, arg, "--allow")) {
            cfg.allow_dangerous = true;
            cfg.require_allow_with_exec = false; // ncat compatibility: --allow alone is sufficient
        } else if (std.mem.eql(u8, arg, "--sctp")) {
            cfg.sctp_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-stdin")) {
            cfg.exec_redirect_stdin = false;
        } else if (std.mem.eql(u8, arg, "--no-stdout")) {
            cfg.exec_redirect_stdout = false;
        } else if (std.mem.eql(u8, arg, "--no-stderr")) {
            cfg.exec_redirect_stderr = false;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--close-on-eof")) {
            cfg.close_on_eof = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero-io")) {
            cfg.zero_io = true;
        } else if (std.mem.eql(u8, arg, "--scan-parallel")) {
            cfg.scan_parallel = true;
        } else if (std.mem.eql(u8, arg, "--scan-randomize")) {
            cfg.scan_randomize = true;
        }
        // Flags with values
        else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.source_addr = args[i];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--source-port")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.source_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wait")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            const seconds = try std.fmt.parseInt(u64, args[i], 10);
            if (seconds > std.math.maxInt(u32) / 1000) {
                return CliError.TimeoutTooLarge;
            }
            cfg.wait_time = @intCast(seconds * 1000);
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--idle-timeout")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            const seconds = try std.fmt.parseInt(u64, args[i], 10);
            if (seconds > std.math.maxInt(u32) / 1000) {
                return CliError.TimeoutTooLarge;
            }
            cfg.idle_timeout = @intCast(seconds * 1000);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.exec_command = args[i];
            // Collect all remaining args until next flag or end
            i += 1;
            while (i < args.len) : (i += 1) {
                const current_arg = args[i];

                // If we see --, enable end_of_options and continue collecting
                if (std.mem.eql(u8, current_arg, "--")) {
                    end_of_options = true;
                    continue;
                }

                // Stop at next flag ONLY if we haven't seen --
                if (!end_of_options and std.mem.startsWith(u8, current_arg, "-")) {
                    break;
                }

                // Collect this argument for exec
                const arg_copy = try allocator.dupe(u8, current_arg);
                try cfg.exec_args.append(allocator, arg_copy);
            }
            i -= 1; // Back up one since the main loop will increment
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--sh-exec")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.shell_command = args[i];
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-conns")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.max_conns = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-clients")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.max_clients = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--ssl-cert")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_cert = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-key")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_key = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-trustfile")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_trustfile = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-ciphers")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_ciphers = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-servername")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_servername = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-alpn")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_alpn = args[i];
        } else if (std.mem.eql(u8, arg, "--ssl-verify")) {
            cfg.ssl_verify = true;
        } else if (std.mem.eql(u8, arg, "--no-ssl-verify") or std.mem.eql(u8, arg, "--ssl-verify=false")) {
            cfg.ssl_verify = false;
        } else if (std.mem.eql(u8, arg, "--ssl-crl")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.ssl_crl = args[i];
        } else if (std.mem.eql(u8, arg, "--gs-secret")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.gsocket_secret = args[i];
        } else if (std.mem.eql(u8, arg, "--proxy")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.proxy = args[i];
        } else if (std.mem.eql(u8, arg, "--proxy-type")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.proxy_type = try parseProxyType(args[i]);
        } else if (std.mem.eql(u8, arg, "--proxy-auth")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.proxy_auth = args[i];
        } else if (std.mem.eql(u8, arg, "--proxy-dns")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.proxy_dns = try parseProxyDns(args[i]);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delay")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.delay_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--deny-file")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.deny_file = args[i];
        } else if (std.mem.eql(u8, arg, "--allow-file")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.allow_file = args[i];
        } else if (std.mem.eql(u8, arg, "--allow-ip")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            // Support comma-separated values: --allow-ip 192.168.1.0/24,10.0.0.1
            try parseCommaSeparatedList(allocator, args[i], &cfg.allow_list);
        } else if (std.mem.eql(u8, arg, "--deny-ip")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            // Support comma-separated values: --deny-ip 0.0.0.0/0
            try parseCommaSeparatedList(allocator, args[i], &cfg.deny_list);
        } else if (std.mem.eql(u8, arg, "--drop-user")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.drop_privileges_user = args[i];
        } else if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--unixsock")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.unix_socket_path = args[i];
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--hex-dump")) {
            cfg.hex_dump = true;
            // Check if next argument is a file path (not a flag)
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cfg.hex_dump_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--scan-workers")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.scan_workers = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--scan-delay")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            cfg.scan_delay_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            logging.logError(error.UnknownOption, "Unknown option");
            logging.logWarning("  Option: {s}\n", .{arg});
            return CliError.UnknownOption;
        }
    }

    cfg.positional_args = try positional.toOwnedSlice(allocator);
    errdefer allocator.free(cfg.positional_args);

    // Map verbose count to verbosity level (only if not explicitly set to quiet)
    if (cfg.verbosity != .quiet and verbose_count > 0) {
        cfg.verbosity = switch (verbose_count) {
            1 => .verbose,
            2 => .debug,
            else => .trace, // 3 or more -> trace
        };
        // verbosity enum is now the only source of truth
    }

    // Validate I/O control flags
    if (cfg.send_only and cfg.recv_only) {
        if (!is_test) logging.logError(error.ConflictingIOModes, "--send-only and --recv-only are mutually exclusive");
        return CliError.ConflictingIOModes;
    }

    // Validate broker/chat mode flags
    if (cfg.broker_mode and cfg.chat_mode) {
        if (!is_test) logging.logError(error.ConflictingIOModes, "--broker and --chat are mutually exclusive");
        return CliError.ConflictingIOModes; // Reuse existing error for simplicity
    }

    // Validate output file path if specified
    if (cfg.output_file) |path| {
        try ensureCliPathSafe(path, "Output file", is_test);
    }

    // Validate hex dump file path if specified
    if (cfg.hex_dump_file) |path| {
        try ensureCliPathSafe(path, "Hex dump file", is_test);
    }

    if (cfg.ssl_cert) |path| {
        try ensureCliPathSafe(path, "TLS certificate", is_test);
    }

    if (cfg.ssl_key) |path| {
        try ensureCliPathSafe(path, "TLS key", is_test);
    }

    if (cfg.ssl_trustfile) |path| {
        try ensureCliPathSafe(path, "TLS trust store", is_test);
    }

    if (cfg.ssl_crl) |path| {
        try ensureCliPathSafe(path, "TLS CRL", is_test);
    }

    if (cfg.allow_file) |path| {
        try ensureCliPathSafe(path, "Allow rule file", is_test);
    }

    if (cfg.deny_file) |path| {
        try ensureCliPathSafe(path, "Deny rule file", is_test);
    }

    // Validate Unix socket configuration if specified
    if (cfg.unix_socket_path != null) {
        config.validateUnixSocket(&cfg) catch |err| switch (err) {
            config.UnixSocketError.UnixSocketsNotSupported, config.UnixSocketError.PlatformNotSupported => {
                if (!is_test) logging.logError(err, "Unix domain sockets not supported on this platform");
                return CliError.UnknownOption; // Reuse existing error for simplicity
            },
            config.UnixSocketError.InvalidUnixSocketPath => {
                if (!is_test) logging.logError(err, "Unix socket path cannot be empty");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.UnixSocketPathTooLong => {
                if (!is_test) logging.logError(err, "Unix socket path is too long (max 107 characters)");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.UnixSocketPathContainsNull => {
                if (!is_test) logging.logError(err, "Unix socket path contains null bytes");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.InvalidUnixSocketPathCharacters => {
                if (!is_test) logging.logError(err, "Unix socket path contains invalid characters");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.UnixSocketDirectoryNotFound => {
                if (!is_test) logging.logError(err, "Parent directory for Unix socket does not exist");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.UnixSocketPermissionDenied => {
                if (!is_test) logging.logError(err, "Permission denied for Unix socket path");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.FeatureNotAvailable => {
                if (!is_test) logging.logError(err, "Unix socket feature not available");
                return CliError.UnknownOption;
            },
            config.UnixSocketError.ConflictingUnixSocketAndProxy => {
                if (!is_test) logging.logError(err, "Unix sockets cannot be used with proxy settings");
                return CliError.ConflictingOptions;
            },
            config.UnixSocketError.ConflictingUnixSocketAndBroker => {
                if (!is_test) logging.logError(err, "Unix sockets cannot be used with broker/chat mode");
                return CliError.ConflictingOptions;
            },
            config.UnixSocketError.ConflictingUnixSocketAndExec => {
                if (!is_test) logging.logError(err, "Unix sockets with exec mode require special configuration");
                return CliError.ConflictingOptions;
            },
            config.UnixSocketError.UnixSocketResourceExhausted => {
                if (!is_test) logging.logError(err, "System resources exhausted for Unix socket");
                return CliError.UnknownOption;
            },
            config.UnixSocketError.UnixSocketSystemError => {
                if (!is_test) logging.logError(err, "System error with Unix socket configuration");
                return CliError.UnknownOption;
            },
            config.UnixSocketError.UnixSocketConfigurationError => {
                if (!is_test) logging.logError(err, "Invalid Unix socket configuration");
                return CliError.InvalidOutputPath;
            },
            config.UnixSocketError.ConflictingUnixSocketAndTCP => {
                if (!is_test) logging.logError(err, "Unix socket (-U) cannot be used with host/port arguments");
                return CliError.ConflictingIOModes;
            },
            config.UnixSocketError.ConflictingUnixSocketAndUDP => {
                if (!is_test) logging.logError(err, "Unix socket (-U) cannot be used with UDP mode (-u)");
                return CliError.ConflictingIOModes;
            },
            config.UnixSocketError.ConflictingUnixSocketAndTLS => {
                if (!is_test) logging.logError(err, "Unix socket (-U) cannot be used with TLS mode (--ssl)");
                return CliError.ConflictingIOModes;
            },
        };
    }

    return cfg;
}

/// Parse proxy type string into ProxyType enum.
///
/// Supported values:
/// - "http": HTTP CONNECT proxy
/// - "socks4": SOCKS4 proxy
/// - "socks5": SOCKS5 proxy
///
/// Returns: ProxyType enum or InvalidProxyType error
fn parseProxyType(s: []const u8) !config.ProxyType {
    if (std.mem.eql(u8, s, "http")) return .http;
    if (std.mem.eql(u8, s, "socks4")) return .socks4;
    if (std.mem.eql(u8, s, "socks5")) return .socks5;
    return error.InvalidProxyType;
}

/// Parse proxy DNS string into ProxyDns enum.
///
/// Supported values:
/// - "local": Resolve DNS locally before sending to proxy
/// - "remote": Send hostname to proxy for remote resolution
/// - "both": Support both local and remote resolution
///
/// Returns: ProxyDns enum or InvalidProxyDns error
fn parseProxyDns(s: []const u8) !config.ProxyDns {
    if (std.mem.eql(u8, s, "local")) return .local;
    if (std.mem.eql(u8, s, "remote")) return .remote;
    if (std.mem.eql(u8, s, "both")) return .both;
    return error.InvalidProxyDns;
}

/// Parse comma-separated list and add to ArrayList.
///
/// Splits input string on commas and trims whitespace from each item.
/// Empty items after trimming are skipped.
///
/// Example input: "192.168.1.0/24, 10.0.0.1, 2001:db8::/32"
/// Results in 3 list items (whitespace trimmed).
///
/// Parameters:
///   allocator: For duplicating strings (caller must free)
///   input: Comma-separated string
///   list: ArrayList to append items to
fn parseCommaSeparatedList(
    allocator: std.mem.Allocator,
    input: []const u8,
    list: *std.ArrayList([]const u8),
) !void {
    var it = std.mem.splitScalar(u8, input, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len > 0) {
            const owned = try allocator.dupe(u8, trimmed);
            try list.append(allocator, owned);
        }
    }
}

fn ensureCliPathSafe(path: []const u8, context: []const u8, is_test: bool) CliError!void {
    if (path.len == 0) {
        if (!is_test) {
            logging.logError(error.InvalidOutputPath, context);
            logging.logWarning("{s} path cannot be empty\n", .{context});
        }
        return CliError.InvalidOutputPath;
    }

    if (std.mem.indexOf(u8, path, "\x00") != null) {
        if (!is_test) {
            logging.logError(error.InvalidOutputPath, context);
            logging.logWarning("{s} path contains null bytes\n", .{context});
        }
        return CliError.InvalidOutputPath;
    }

    if (!path_safety.isSafePath(path)) {
        if (!is_test) {
            logging.logError(error.InvalidOutputPath, context);
            logging.logWarning("{s} path contains invalid traversal sequences\n", .{context});
        }
        return CliError.InvalidOutputPath;
    }
}
