// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! Help and version display functions for zigcat CLI.
//!
//! This module provides user-facing output for:
//! - Usage information (printHelp)
//! - Basic version info (printVersion)
//! - Detailed version info (printVersionAll)

const std = @import("std");

/// Print usage information and exit.
///
/// Displays comprehensive help text including:
/// - Basic usage patterns
/// - All supported flags organized by category
/// - Example commands for common use cases
pub fn printHelp() void {
    std.debug.print(
        \\zigcat - Zig implementation of netcat
        \\
        \\USAGE:
        \\  zigcat [options] [host] [port]
        \\  zigcat -l [options] [port]
        \\
        \\CONNECT MODE (default):
        \\  zigcat <host> <port>          Connect to host:port
        \\
        \\LISTEN MODE:
        \\  -l, --listen                  Listen mode
        \\  -k, --keep-open               Keep listening after disconnect
        \\  -m, --max-conns <n>           Maximum concurrent connections
        \\
        \\BROKER/CHAT MODE:
        \\  --broker                      Broker mode (relay data between clients)
        \\  --chat                        Chat mode (line-oriented with nicknames)
        \\  --max-clients <n>             Maximum clients for broker/chat mode (default: 50)
        \\
        \\PROTOCOL OPTIONS:
        \\  -u, --udp                     UDP mode
        \\  --sctp                        SCTP mode
        \\  -U, --unixsock <path>         Unix domain socket (local IPC)
        \\  -4                            IPv4 only
        \\  -6                            IPv6 only
        \\
        \\TIMING OPTIONS:
        \\  -w, --wait <secs>             Connect timeout
        \\  -i, --idle-timeout <secs>     Idle timeout
        \\  -q, --close-on-eof            Close connection on EOF from stdin
        \\
        \\TRANSFER OPTIONS:
        \\  --send-only                   Only send data (close read)
        \\  --recv-only                   Only receive data (close write)
        \\  -C, --crlf                    Convert LF to CRLF
        \\  -t, --telnet                  Telnet protocol mode (process IAC sequences)
        \\  --telnet-signal-mode <mode>    Telnet signal behavior (local|remote)
        \\  --telnet-edit-mode <mode>      Telnet editing (remote|local)
        \\  --telnet-ansi-mode <mode>      ANSI escape handling (disabled|passthrough|active)
        \\  --no-shutdown                 Keep socket write-half open after stdin EOF
        \\  -d, --delay <ms>              Traffic shaping delay in milliseconds
        \\
        \\SSL/TLS OPTIONS:
        \\  --ssl                         Enable SSL/TLS
        \\  --ssl-verify                  Enable certificate verification (default)
        \\  --insecure                    Disable certificate verification (explicit acknowledgment)
        \\  --ssl-cert <file>             SSL certificate file (server mode)
        \\  --ssl-key <file>              SSL private key file (server mode)
        \\  --ssl-trustfile <file>        SSL CA certificate bundle
        \\  --ssl-crl <file>              Certificate Revocation List (CRL) file
        \\  --ssl-ciphers <ciphers>       SSL cipher suite list
        \\  --ssl-servername <name>       SNI server name (for virtual hosting)
        \\  --ssl-alpn <protocols>        ALPN protocol list (e.g., "h2,http/1.1")
        \\
        \\GSOCKET OPTIONS:
        \\  --gs-secret <secret>          Connect via Global Socket Relay Network (GSRN)
        \\                                Uses secret for NAT traversal through relay server
        \\                                Both peers must use the same secret for connection
        \\                                Provides SRP-AES-256-CBC-SHA end-to-end encryption
        \\                                (NOTE: Uses SHA-1 MAC for gsocket compatibility)
        \\                                No port forwarding or firewall configuration needed
        \\  -R, --relay <host:port>       Specify a custom GSRN relay server
        \\                                (Default: gs.thc.org:443)
        \\
        \\PROXY OPTIONS:
        \\  --proxy <url>                 Proxy URL (http://host:port, socks5://host:port)
        \\  --proxy-type <type>           Proxy type (http, socks4, socks5)
        \\  --proxy-auth <user:pass>      Proxy authentication credentials
        \\                                WARNING: Credentials sent in Base64 (NOT encrypted).
        \\                                EXTREMELY INSECURE: http:// proxy URLs leak your password
        \\                                exactly like plain text. Assume compromise if intercepted.
        \\                                Only use with HTTPS proxy URLs you fully trust.
        \\  --proxy-dns <mode>            DNS resolution mode (local, remote, both)
        \\
        \\EXECUTION OPTIONS:
        \\  -e, --exec <cmd> [args...]    Execute command with arguments
        \\                                Use -- to pass args with hyphens:
        \\                                  zigcat -l -e -- grep -v 'pattern'
        \\  -c, --sh-exec <cmd>           Execute command via shell
        \\  --allow                       Allow dangerous operations
        \\
        \\OUTPUT OPTIONS:
        \\  -v, --verbose                 Verbose mode (connection details and stats)
        \\  -vv                           Debug mode (protocol details and hex dumps)
        \\  -vvv                          Trace mode (all internal state tracing)
        \\  --quiet                       Quiet mode (errors only, suppresses all logging)
        \\  -o, --output <file>           Write received data to file
        \\  --append                      Append to output file instead of truncating
        \\  -x, --hex-dump [file]         Display data in hex format (optionally to file)
        \\  --append-output               Append to hex dump file instead of truncating
        \\
        \\VERBOSITY LEVELS:
        \\  quiet  (0): Silent except for errors
        \\  normal (1): Connection events and warnings (default)
        \\  verbose (2): -v enables detailed connection info and transfer stats
        \\  debug  (3): -vv enables protocol-level details and hex dumps
        \\  trace  (4): -vvv enables all internal state and function tracing
        \\
        \\ACCESS CONTROL:
        \\  --allow-ip <ips>              Allow specific IPs/CIDRs/hostnames (comma-separated)
        \\                                Examples: 192.168.1.0/24,10.0.0.1,example.com
        \\  --deny-ip <ips>               Deny specific IPs/CIDRs/hostnames (comma-separated)
        \\  --allow-file <file>           Read allow rules from file (one per line)
        \\  --deny-file <file>            Read deny rules from file (one per line)
        \\  --drop-user <user>            Drop privileges to user after bind (Unix only)
        \\
        \\  WARNING: Hostname rules use DNS which can be manipulated by attackers.
        \\           Prefer IP-based rules for production security. Hostnames add
        \\           10-100ms latency per connection due to DNS lookups.
        \\
        \\PORT SCANNING OPTIONS:
        \\  -z, --zero-io                 Zero-I/O mode (port scanning)
        \\  --scan-parallel               Enable parallel port scanning (10-100x faster)
        \\  --scan-workers <n>            Number of worker threads for parallel scanning (default: 10)
        \\                                Recommended: 10-50 workers depending on network bandwidth
        \\                                Higher values = faster scans but more aggressive
        \\  --scan-randomize              Randomize port scanning order (stealth mode)
        \\                                Evades IDS/IPS signature detection of sequential scans
        \\                                Use only for authorized security testing
        \\  --scan-delay <ms>             Delay between port scans in milliseconds (stealth mode)
        \\                                Reduces network spike detection and rate limiting
        \\                                Example: --scan-delay 100 (100ms between scans)
        \\
        \\OTHER OPTIONS:
        \\  --keep-source-port            Bind to specific source port before connect
        \\  --                            End of options (all following args are positional)
        \\  -h, --help                    Show this help
        \\  --version                     Show version
        \\  --version-all                 Show detailed version info (platform, features)
        \\
        \\EXAMPLES:
        \\  Basic usage:
        \\    zigcat google.com 80          Connect to Google on port 80
        \\    zigcat -l 8080                Listen on port 8080
        \\    zigcat -l -k 8080             Listen on port 8080, keep open
        \\    zigcat -u 192.168.1.1 53      UDP connection to DNS server
        \\
        \\  Verbosity control:
        \\    zigcat -v host 80             Verbose: show connection details
        \\    zigcat -vv host 80            Debug: show protocol details
        \\    zigcat -vvv host 80           Trace: show all internal state
        \\    zigcat --quiet host 80        Quiet: suppress all output except errors
        \\
        \\  I/O control:
        \\    zigcat --send-only host 80    Only send data to host:80
        \\    zigcat --recv-only host 80    Only receive data from host:80
        \\    zigcat -o output.txt host 80  Save received data to file
        \\    zigcat -x host 80             Display data in hex format
        \\    zigcat -x dump.hex host 80    Save hex dump to file
        \\
        \\  Advanced modes:
        \\    zigcat -l --broker 8080       Broker mode on port 8080
        \\    zigcat -l --chat 8080         Chat mode on port 8080
        \\    zigcat -l --broker --max-clients 100 8080  Broker with 100 max clients
        \\    zigcat -U /tmp/socket         Connect to Unix socket
        \\    zigcat -l -U /tmp/socket      Listen on Unix socket
        \\
        \\  Global Socket (NAT traversal):
        \\    zigcat -l --gs-secret MySecret  Listen via GSRN (wait for peer)
        \\    zigcat --gs-secret MySecret     Connect via GSRN (to listening peer)
        \\                                    Both peers auto-connect through gs.thc.org relay
        \\                                    End-to-end SRP-AES-256 encryption, no port forwarding
        \\
        \\  Command execution:
        \\    zigcat -l -e grep foo         Execute grep (args without hyphens)
        \\    zigcat -l -e -- grep -v foo   Execute grep with -v flag (using --)
        \\
        \\  Port scanning:
        \\    zigcat -z localhost 80         Test if port 80 is open (sequential)
        \\    zigcat -z --scan-parallel localhost 80  Test port 80 (parallel mode)
        \\    zigcat -z --scan-parallel --scan-workers 20 example.com 1-1024
        \\                                  Scan ports 1-1024 with 20 workers (fast!)
        \\    zigcat -z -w 0.5 --scan-parallel --scan-workers 50 192.168.1.1 1-65535
        \\                                  Scan all ports with 50 workers and 500ms timeout
        \\
        \\  Stealth port scanning:
        \\    zigcat -z --scan-parallel --scan-randomize target.com 1-1024
        \\                                  Randomize scan order (evade IDS signatures)
        \\    zigcat -z --scan-randomize --scan-delay 100 example.com 1-1024
        \\                                  Randomized + 100ms delay (very stealthy)
        \\    zigcat -z -w 0.5 --scan-parallel --scan-randomize --scan-delay 50 --scan-workers 10 192.168.1.1 1-65535
        \\                                  Full stealth scan: parallel, randomized, delayed
        \\
    , .{});
}

/// Print version information and exit.
pub fn printVersion() void {
    const build_options = @import("build_options");
    std.debug.print("zigcat {s}\nZig implementation of netcat\n", .{build_options.version});
}

/// Print detailed version information including dependencies.
pub fn printVersionAll() void {
    const build_options = @import("build_options");
    const builtin = @import("builtin");
    std.debug.print("zigcat {s}\n", .{build_options.version});
    std.debug.print("Zig {s}\n", .{builtin.zig_version_string});
    std.debug.print("Platform: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    std.debug.print("Build mode: {s}\n", .{@tagName(builtin.mode)});

    // Detect TLS availability at compile time
    const tls_available = @hasDecl(@import("../tls/tls.zig"), "TlsConnection");
    std.debug.print("Features: TLS={s}, UnixSock={s}\n", .{
        if (tls_available) "enabled" else "disabled",
        if (@import("../config.zig").UnixSocketSupport.available) "available" else "unavailable",
    });
}
