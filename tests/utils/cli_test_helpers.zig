//! Shared helpers for CLI argument tests.

pub const MockConfig = struct {
    mode: Mode = .connect,
    host: ?[]const u8 = null,
    port: u16 = 0,
    udp: bool = false,
    ipv4: bool = false,
    ipv6: bool = false,
    listen: bool = false,
    keep_open: bool = false,
    zero_io: bool = false,
    verbose: u8 = 0,
    connect_timeout: ?u32 = null,
    idle_timeout: ?u32 = null,
    quit_after_eof: ?u32 = null,
    source_port: ?u16 = null,
    source_addr: ?[]const u8 = null,

    // TLS options
    ssl: bool = false,
    ssl_cert: ?[]const u8 = null,
    ssl_key: ?[]const u8 = null,
    ssl_trustfile: ?[]const u8 = null,
    ssl_verify: bool = false,
    ssl_servername: ?[]const u8 = null,
    ssl_ciphers: ?[]const u8 = null,

    // Proxy options
    proxy: ?[]const u8 = null,
    proxy_type: ProxyType = .http,
    proxy_auth: ?[]const u8 = null,

    // Access control
    allow: ?[]const u8 = null,
    deny: ?[]const u8 = null,

    // Execution
    exec: ?[]const u8 = null,
    sh_exec: ?[]const u8 = null,

    // I/O options
    send_only: bool = false,
    recv_only: bool = false,
    crlf: bool = false,
    hex_dump: ?[]const u8 = null,
    output: ?[]const u8 = null,
    append: bool = false,

    // Misc
    nodns: bool = false,
    telnet: bool = false,
    unixsock: ?[]const u8 = null,
    broker: bool = false,
    chat: bool = false,
    max_conns: u32 = 16,

    pub const Mode = enum { connect, listen };
    pub const ProxyType = enum { http, socks4, socks5 };
};
