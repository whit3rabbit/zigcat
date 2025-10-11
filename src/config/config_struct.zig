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
    listen_mode: bool = false,
    udp_mode: bool = false,
    sctp_mode: bool = false,

    // Network options
    source_addr: ?[]const u8 = null,
    source_port: ?u16 = null,
    interface: ?[]const u8 = null,
    ipv4_only: bool = false,
    ipv6_only: bool = false,

    // Timing (all values in milliseconds)
    connect_timeout: u32 = 30000,
    accept_timeout: u32 = 0,
    idle_timeout: u32 = 0,
    wait_time: u32 = 0,

    // Transfer options
    send_only: bool = false,
    recv_only: bool = false,
    close_on_eof: bool = false,
    crlf: bool = false,
    telnet: bool = false,

    // Server options
    keep_listening: bool = false,
    max_conns: u32 = 0,
    exec_command: ?[]const u8 = null,
    exec_args: std.ArrayList([]const u8),
    shell_command: ?[]const u8 = null,
    exec_redirect_stdin: bool = true,
    exec_redirect_stdout: bool = true,
    exec_redirect_stderr: bool = true,
    exec_mode: exec.ExecMode = .direct,
    /// Buffer size for client input forwarded to child stdin
    exec_stdin_buffer_size: usize = 32 * 1024,
    /// Buffer size for child stdout forwarded to client
    exec_stdout_buffer_size: usize = 64 * 1024,
    /// Buffer size for child stderr forwarded to client
    exec_stderr_buffer_size: usize = 32 * 1024,
    /// Maximum aggregate buffered bytes across exec I/O channels (0 = auto)
    exec_max_buffer_bytes: usize = 256 * 1024,
    /// Flow control pause threshold as percentage of max buffer usage
    exec_flow_pause_percent: f32 = 0.85,
    /// Flow control resume threshold as percentage of max buffer usage
    exec_flow_resume_percent: f32 = 0.60,
    /// Maximum execution duration in milliseconds (0 = unlimited)
    exec_execution_timeout_ms: u32 = 0,
    /// Idle timeout in milliseconds for exec sessions (0 = unlimited)
    exec_idle_timeout_ms: u32 = 0,
    /// Connection timeout in milliseconds for initial exec activity (0 = unlimited)
    exec_connection_timeout_ms: u32 = 0,
    bind_addr: ?[]const u8 = null,

    // Broker/Chat Mode
    broker_mode: bool = false,
    chat_mode: bool = false,
    max_clients: u32 = 50,
    chat_max_nickname_len: usize = 32,
    chat_max_message_len: usize = 1024,

    // SSL/TLS
    ssl: bool = false,
    ssl_cert: ?[]const u8 = null,
    ssl_key: ?[]const u8 = null,
    ssl_verify: bool = true,
    ssl_trustfile: ?[]const u8 = null,
    ssl_crl: ?[]const u8 = null,
    ssl_ciphers: ?[]const u8 = null,
    ssl_servername: ?[]const u8 = null,
    ssl_alpn: ?[]const u8 = null,

    // Proxy
    proxy: ?[]const u8 = null,
    proxy_type: types.ProxyType = .http,
    proxy_auth: ?[]const u8 = null,
    proxy_dns: types.ProxyDns = .none,

    // Connection control
    no_shutdown: bool = false,
    keep_source_port: bool = false,

    // Traffic shaping
    delay_ms: u32 = 0,

    // Output options
    verbose: bool = false, // Deprecated: use verbosity instead
    verbose_level: u8 = 0, // Deprecated: use verbosity instead
    verbosity: types.VerbosityLevel = .normal,
    hex_dump: bool = false,
    hex_dump_file: ?[]const u8 = null,
    hex_dump_append: bool = false,
    append_output: bool = false,
    output_file: ?[]const u8 = null,

    // Zero-I/O mode
    zero_io: bool = false,
    scan_parallel: bool = false, // Enable parallel port scanning
    scan_workers: usize = 10,    // Number of worker threads for parallel scanning

    // Security options
    allow_dangerous: bool = false,
    require_allow_with_exec: bool = true,
    drop_privileges_user: ?[]const u8 = null,
    deny_file: ?[]const u8 = null,
    allow_file: ?[]const u8 = null,
    allow_list: std.ArrayList([]const u8),
    deny_list: std.ArrayList([]const u8),

    // Unix Domain Sockets
    unix_socket_path: ?[]const u8 = null,

    // Misc
    no_dns: bool = false,
    telemetry: bool = false,
    version_info: ?[]const u8 = null,

    // Positional arguments
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
