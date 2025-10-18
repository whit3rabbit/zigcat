// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


//! Core configuration structure for zigcat.
//!
//! This module owns the central `Config` type that aggregates
//! runtime options parsed from the CLI. Behaviour-specific
//! validation lives in sibling modules (`cli.zig`, `network.zig`,
//! `tls.zig`, `security.zig`).

const std = @import("std");
const exec = @import("../server/exec.zig");
const types = @import("types.zig");

/// Central configuration structure for all zigcat runtime options.
///
/// Memory management: ArrayLists must be freed via `deinit()` before deallocation.
pub const Config = struct {
    // Connection mode flags
    /// Listen for inbound connections. Controlled by `-l`, `--listen`. Default: `false`.
    listen_mode: bool = false,
    /// Use UDP instead of TCP. Controlled by `-u`, `--udp`. Default: `false`.
    udp_mode: bool = false,
    /// Use SCTP instead of TCP. Controlled by `--sctp`. Default: `false`.
    sctp_mode: bool = false,

    // Network options
    /// Source address to bind to. Controlled by `-s`, `--source-addr`. Default: `null`.
    source_addr: ?[]const u8 = null,
    /// Source port to bind to. Controlled by `-p`, `--source-port`. Default: `null`.
    source_port: ?u16 = null,
    /// Network interface to use. Controlled by `--interface`. Default: `null`.
    interface: ?[]const u8 = null,
    /// Use IPv4 only. Controlled by `-4`. Default: `false`.
    ipv4_only: bool = false,
    /// Use IPv6 only. Controlled by `-6`. Default: `false`.
    ipv6_only: bool = false,

    // Timing (all values in milliseconds)
    /// Timeout for connections in milliseconds. Controlled by `-w`, `--connect-timeout`. Default: `30000`.
    connect_timeout: u32 = 30000,
    /// Timeout for accepting connections in listen mode. Controlled by `--accept-timeout`. 0 means unlimited. Default: `0`.
    accept_timeout: u32 = 0,
    /// Idle timeout for the connection in milliseconds. Controlled by `-i`, `--idle-timeout`. 0 means unlimited. Default: `0`.
    idle_timeout: u32 = 0,
    /// Wait time between read/write operations. Not a standard nc feature. Default: `0`.
    wait_time: u32 = 0,

    // Transfer options
    /// Only send data, ignore received data. Controlled by `--send-only`. Default: `false`.
    send_only: bool = false,
    /// Only receive data, do not send anything. Controlled by `--recv-only`. Default: `false`.
    recv_only: bool = false,
    /// Close the connection on EOF from stdin. Controlled by `--close-on-eof`. Default: `false`.
    close_on_eof: bool = false,
    /// Convert LF to CRLF for output. Controlled by `--crlf`. Default: `false`.
    crlf: bool = false,
    /// Interpret Telnet commands. Controlled by `--telnet`. Default: `false`.
    telnet: bool = false,

    // Server options
    /// Keep listening for new connections after the current one finishes. Controlled by `-k`, `--keep-listening`. Default: `false`.
    keep_listening: bool = false,
    /// Maximum number of simultaneous connections to accept. Controlled by `--max-conns`. 0 means unlimited. Default: `0`.
    max_conns: u32 = 0,
    /// Execute a command after connection. Controlled by `-e`, `--exec`. Default: `null`.
    exec_command: ?[]const u8 = null,
    /// Arguments for the command specified with `--exec`.
    exec_args: std.ArrayList([]const u8),
    /// Execute a command via the system shell. Controlled by `-c`, `--shell`. Default: `null`.
    shell_command: ?[]const u8 = null,
    /// Redirect connection input to the executed command's stdin. Controlled by `--exec-redirect-stdin`. Default: `true`.
    exec_redirect_stdin: bool = true,
    /// Redirect the executed command's stdout to the connection. Controlled by `--exec-redirect-stdout`. Default: `true`.
    exec_redirect_stdout: bool = true,
    /// Redirect the executed command's stderr to the connection. Controlled by `--exec-redirect-stderr`. Default: `true`.
    exec_redirect_stderr: bool = true,
    /// Execution mode for commands (`direct`, `pty`, `fork`). Controlled by `--exec-mode`. Default: `.direct`.
    exec_mode: exec.ExecMode = .direct,
    /// Buffer size for client input forwarded to child stdin. Controlled by `--exec-stdin-buffer-size`. Default: `32 * 1024`.
    exec_stdin_buffer_size: usize = 32 * 1024,
    /// Buffer size for child stdout forwarded to client. Controlled by `--exec-stdout-buffer-size`. Default: `64 * 1024`.
    exec_stdout_buffer_size: usize = 64 * 1024,
    /// Buffer size for child stderr forwarded to client. Controlled by `--exec-stderr-buffer-size`. Default: `32 * 1024`.
    exec_stderr_buffer_size: usize = 32 * 1024,
    /// Maximum aggregate buffered bytes across exec I/O channels. Controlled by `--exec-max-buffer-bytes`. 0 means auto. Default: `256 * 1024`.
    exec_max_buffer_bytes: usize = 256 * 1024,
    /// Flow control pause threshold as a percentage of max buffer usage. Controlled by `--exec-flow-pause-percent`. Default: `0.85`.
    exec_flow_pause_percent: f32 = 0.85,
    /// Flow control resume threshold as a percentage of max buffer usage. Controlled by `--exec-flow-resume-percent`. Default: `0.60`.
    exec_flow_resume_percent: f32 = 0.60,
    /// Maximum total execution time in milliseconds. Controlled by `--exec-execution-timeout-ms`. 0 means unlimited. Default: `0`.
    exec_execution_timeout_ms: u32 = 0,
    /// Idle timeout in milliseconds for exec sessions. Controlled by `--exec-idle-timeout-ms`. 0 means unlimited. Default: `0`.
    exec_idle_timeout_ms: u32 = 0,
    /// Connection timeout in milliseconds for initial exec activity. Controlled by `--exec-connection-timeout-ms`. 0 means unlimited. Default: `0`.
    exec_connection_timeout_ms: u32 = 0,
    /// Address to bind for listening, overrides positional args. Controlled by `--bind`. Default: `null`.
    bind_addr: ?[]const u8 = null,

    // Broker/Chat Mode
    /// Enable message broker mode. Controlled by `--broker`. Default: `false`.
    broker_mode: bool = false,
    /// Enable multi-user chat mode. Controlled by `--chat`. Default: `false`.
    chat_mode: bool = false,
    /// Maximum number of clients in broker or chat mode. Controlled by `--max-clients`. Default: `50`.
    max_clients: u32 = 50,
    /// Maximum nickname length in chat mode. Controlled by `--chat-max-nickname-len`. Default: `32`.
    chat_max_nickname_len: usize = 32,
    /// Maximum message length in chat mode. Controlled by `--chat-max-message-len`. Default: `1024`.
    chat_max_message_len: usize = 1024,

    // SSL/TLS
    /// Enable SSL/TLS. Controlled by `--ssl`. Default: `false`.
    ssl: bool = false,
    /// Path to SSL certificate file. Controlled by `--ssl-cert`. Default: `null`.
    ssl_cert: ?[]const u8 = null,
    /// Path to SSL private key file. Controlled by `--ssl-key`. Default: `null`.
    ssl_key: ?[]const u8 = null,
    /// Verify the peer's SSL certificate. Controlled by `--ssl-verify`. Default: `true`.
    ssl_verify: bool = true,
    /// Allow insecure TLS connections (disables certificate verification). Controlled by `--insecure`. Default: `false`.
    /// SECURITY: This flag must be explicitly set to disable certificate verification.
    insecure: bool = false,
    /// Path to a file of trusted CA certificates. Controlled by `--ssl-trustfile`. Default: `null`.
    ssl_trustfile: ?[]const u8 = null,
    /// Path to a certificate revocation list file. Controlled by `--ssl-crl`. Default: `null`.
    ssl_crl: ?[]const u8 = null,
    /// Colon-separated list of SSL ciphers to use. Controlled by `--ssl-ciphers`. Default: `null`.
    ssl_ciphers: ?[]const u8 = null,
    /// Server Name Indication for TLS. Controlled by `--ssl-servername`. Default: `null`.
    ssl_servername: ?[]const u8 = null,
    /// Application-Layer Protocol Negotiation string. Controlled by `--ssl-alpn`. Default: `null`.
    ssl_alpn: ?[]const u8 = null,

    // DTLS (SSL over UDP)
    /// Enable DTLS (implies --ssl and --udp). Controlled by `--dtls`. Default: `false`.
    dtls: bool = false,
    /// Path MTU for DTLS datagrams. Controlled by `--dtls-mtu`. Default: `1200`.
    dtls_mtu: u16 = 1200,
    /// Initial DTLS handshake retransmission timeout in ms. Controlled by `--dtls-timeout`. Default: `1000`.
    dtls_timeout: u32 = 1000,
    /// Server cookie secret for DTLS. Auto-generated if null. Controlled by `--dtls-cookie-secret`. Default: `null`.
    dtls_cookie_secret: ?[]const u8 = null,
    /// Anti-replay window size (number of packets). Controlled by `--dtls-replay-window`. Default: `64`.
    dtls_replay_window: u32 = 64,

    // Global Socket (gsocket)
    /// Shared secret for gsocket NAT-traversal mode. Controlled by `--gs-secret`. Default: `null`.
    gsocket_secret: ?[]const u8 = null,
    /// Custom gsocket relay server (host:port). Controlled by `-R`, `--relay`. Default: `null`.
    gsocket_relay: ?[]const u8 = null,

    // Proxy
    /// Proxy address (`host:port`). Controlled by `-x`, `--proxy`. Default: `null`.
    proxy: ?[]const u8 = null,
    /// Proxy type (`http`, `socks4`, `socks5`). Controlled by `--proxy-type`. Default: `.http`.
    proxy_type: types.ProxyType = .http,
    /// Proxy authentication (`user:pass`). Controlled by `--proxy-auth`. Default: `null`.
    proxy_auth: ?[]const u8 = null,
    /// DNS resolution mode for proxy. Controlled by `--proxy-dns`. Default: `.none`.
    proxy_dns: types.ProxyDns = .none,

    // Connection control
    /// Do not call shutdown on the socket after EOF on stdin. Controlled by `--no-shutdown`. Default: `false`.
    no_shutdown: bool = false,
    /// Re-use the source port on reconnects. Controlled by `--keep-source-port`. Default: `false`.
    keep_source_port: bool = false,

    // Traffic shaping
    /// Delay between sending data packets in milliseconds. Controlled by `-d`. Default: `0`.
    delay_ms: u32 = 0,

    // Output options
    /// DEPRECATED: Use `verbosity` instead. Controlled by `-v`. Default: `false`.
    verbose: bool = false,
    /// DEPRECATED: Use `verbosity` instead. Controlled by `-v` (repeated). Default: `0`.
    verbose_level: u8 = 0,
    /// Set verbosity level (`quiet`, `normal`, `verbose`, `debug`). Controlled by `--verbosity`. Default: `.normal`.
    verbosity: types.VerbosityLevel = .normal,
    /// Hex dump traffic to stderr. Controlled by `--hex-dump`. Default: `false`.
    hex_dump: bool = false,
    /// File to write hex dump to instead of stderr. Controlled by `--hex-dump-file`. Default: `null`.
    hex_dump_file: ?[]const u8 = null,
    /// Append to the hex dump file instead of overwriting. Controlled by `--hex-dump-append`. Default: `false`.
    hex_dump_append: bool = false,
    /// Append to the output file instead of overwriting. Controlled by `-a`, `--append-output`. Default: `false`.
    append_output: bool = false,
    /// Write outgoing data to a file. Controlled by `-o`, `--output-file`. Default: `null`.
    output_file: ?[]const u8 = null,

    // Zero-I/O mode
    /// Zero-I/O mode for port scanning. Controlled by `-z`, `--zero-io`. Default: `false`.
    zero_io: bool = false,
    /// Enable parallel port scanning. Controlled by `--scan-parallel`. Default: `false`.
    scan_parallel: bool = false,
    /// Number of worker threads for parallel scanning. Controlled by `--scan-workers`. Default: `10`.
    scan_workers: usize = 10,
    /// Randomize port scanning order. Controlled by `--scan-randomize`. Default: `false`.
    scan_randomize: bool = false,
    /// Delay between port scans in milliseconds. Controlled by `--scan-delay-ms`. Default: `0`.
    scan_delay_ms: u32 = 0,

    // Security options
    /// Allow dangerous options like command execution without allowlisting. Controlled by `--allow-dangerous`. Default: `false`.
    allow_dangerous: bool = false,
    /// Require `--allow` or `--allow-file` when using `--exec`. Controlled by `--require-allow-with-exec`. Default: `true`.
    require_allow_with_exec: bool = true,
    /// User to drop privileges to after binding to a privileged port. Controlled by `--drop-privileges-user`. Default: `null`.
    drop_privileges_user: ?[]const u8 = null,
    /// Path to a file containing rules to deny connections. Controlled by `--deny-file`. Default: `null`.
    deny_file: ?[]const u8 = null,
    /// Path to a file containing rules to allow connections. Controlled by `--allow-file`. Default: `null`.
    allow_file: ?[]const u8 = null,
    /// Comma-separated list of hosts to allow. Controlled by `--allow`.
    allow_list: std.ArrayList([]const u8),
    /// Comma-separated list of hosts to deny. Controlled by `--deny`.
    deny_list: std.ArrayList([]const u8),

    // Unix Domain Sockets
    /// Path to a Unix domain socket to connect or listen on. Controlled by `-U`, `--unix-socket`. Default: `null`.
    unix_socket_path: ?[]const u8 = null,

    // Misc
    /// Do not perform DNS resolution. Controlled by `-n`, `--no-dns`. Default: `false`.
    no_dns: bool = false,
    /// Enable telemetry reporting. Controlled by `--telemetry`. Default: `false`.
    telemetry: bool = false,
    /// Holds version information if `--version` is passed.
    version_info: ?[]const u8 = null,

    // Positional arguments
    /// Positional arguments, typically `[host, port]`.
    positional_args: [][]const u8 = &[_][]const u8{},

    /// Initialize a default configuration with empty ArrayLists.
    pub fn init(_: std.mem.Allocator) Config {
        return .{
            .allow_list = std.ArrayList([]const u8){},
            .deny_list = std.ArrayList([]const u8){},
            .exec_args = std.ArrayList([]const u8){},
            .positional_args = &[_][]const u8{},
        };
    }

    /// Free all dynamically allocated memory in the configuration.
    /// Must be called before Config is freed to prevent memory leaks.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.allow_list.items) |item| {
            allocator.free(item);
        }
        for (self.deny_list.items) |item| {
            allocator.free(item);
        }
        for (self.exec_args.items) |item| {
            allocator.free(item);
        }
        self.allow_list.deinit(allocator);
        self.deny_list.deinit(allocator);
        self.exec_args.deinit(allocator);
        allocator.free(self.positional_args);
    }
};

/// Build exec session runtime configuration from Config.
pub fn buildExecSessionConfig(cfg: *const Config) exec.ExecSessionConfig {
    return .{
        .buffers = .{
            .stdin_capacity = cfg.exec_stdin_buffer_size,
            .stdout_capacity = cfg.exec_stdout_buffer_size,
            .stderr_capacity = cfg.exec_stderr_buffer_size,
        },
        .timeouts = .{
            .execution_ms = cfg.exec_execution_timeout_ms,
            .idle_ms = cfg.exec_idle_timeout_ms,
            .connection_ms = cfg.exec_connection_timeout_ms,
        },
        .flow = .{
            .max_total_buffer_bytes = cfg.exec_max_buffer_bytes,
            .pause_threshold_percent = cfg.exec_flow_pause_percent,
            .resume_threshold_percent = cfg.exec_flow_resume_percent,
        },
    };
}
