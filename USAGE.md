# Zigcat CLI Cheat Sheet

`zigcat` is a netcat-compatible tool written in Zig. This cheat sheet lists every supported command-line flag, its input type, and a concrete example. Unless noted otherwise, examples place the port argument last and avoid mutually exclusive combinations.

## Usage Patterns
- `zigcat [options] <host> <port>` - connect to a remote endpoint.
- `zigcat -l [options] <port>` - listen for inbound connections.
- `zigcat -U <path>` - connect to or listen on a Unix domain socket.

## Generating SSL Certificates

For testing purposes, you can generate a self-signed certificate using `openssl`.

```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 365 -nodes
```

This command will create two files:

*   `key.pem`: The private key.
*   `cert.pem`: The public certificate.

**Important:** For production use, you should obtain a certificate from a trusted Certificate Authority (CA).

## Positional Arguments
- `<host>` *(string)* - remote host or IP to connect to. Example: `zigcat example.com 80`
- `<port>` *(u16 or port range string for scans)* - TCP/UDP/SCTP port number or range string for zero-I/O scans. Example: `zigcat example.com 443`
- `--` *(end of options)* - treat all following tokens as positional or exec arguments. Example: `zigcat -l 9000 -e /usr/bin/grep -- -v error`

## General Controls
- `-h`, `--help` *(flag)* - show built-in help text. Example: `zigcat --help`
- `--version` *(flag)* - print program version and exit. Example: `zigcat --version`
- `--version-all` *(flag)* - show detailed build/platform info. Example: `zigcat --version-all`

## Verbosity & Output
- `-v`, `--verbose` *(flag)* - increase verbosity to verbose (level 1). Example: `zigcat -v example.com 80`
- `-vv` *(flag)* - enable debug verbosity (level 2). Example: `zigcat -vv example.com 80`
- `-vvv` *(flag)* - enable trace verbosity (level 3). Example: `zigcat -vvv example.com 80`
- `-vvvv` *(flag)* - maximize verbosity (level 4). Example: `zigcat -vvvv example.com 80`
- `-q`, `--quiet` *(flag)* - errors only; suppress other logging. Example: `zigcat -q example.com 80`
- `-o`, `--output <file>` *(string path)* - write received data to a file. Example: `zigcat -o logs/session.txt example.com 80`
- `--append` *(flag)* - append to the `--output` file instead of truncating. Example: `zigcat -o logs/session.txt --append example.com 80`
- `-x`, `--hex-dump [file]` *(flag + optional string path)* - enable hex dump, optionally directing output to a file.  
  Example: `zigcat -x example.com 443`  
  Example with file: `zigcat -x dumps/handshake.hex example.com 443`
- `--append-output` *(flag)* - append to the hex dump file provided to `--hex-dump`. Example: `zigcat -x dumps/handshake.hex --append-output example.com 443`

## Connection Modes
- `-l`, `--listen` *(flag)* - listen for inbound connections. Example: `zigcat -l 8080`
- `-k`, `--keep-open` *(flag)* - continue listening after each client disconnects. Example: `zigcat -l -k 8080`
- `-m`, `--max-conns <count>` *(u32)* - cap concurrent listeners. Example: `zigcat -l --max-conns 4 8080`
- `--broker` *(flag)* - relay data between connected clients (mutually exclusive with `--chat`). Example: `zigcat -l --broker 9100`
- `--chat` *(flag)* - chatroom mode with nicknames (mutually exclusive with `--broker`). Example: `zigcat -l --chat 9100`
- `--max-clients <count>` *(u32)* - limit broker/chat participants. Example: `zigcat -l --broker --max-clients 150 9100`

## Transport & Address Selection
- `-u`, `--udp` *(flag)* - use UDP instead of TCP. Example: `zigcat --udp 198.51.100.5 53`
- `--sctp` *(flag)* - use SCTP transport. Example: `zigcat --sctp example.com 9899`
- `-U`, `--unixsock <path>` *(string path)* - use a Unix domain socket. Example: `zigcat -U /tmp/zigcat.sock`
- `-4` *(flag)* - force IPv4. Example: `zigcat -4 example.com 80`
- `-6` *(flag)* - force IPv6. Example: `zigcat -6 ipv6.example.com 80`
- `-s`, `--source <addr>` *(string)* - bind to a local source address. Example: `zigcat --source 192.0.2.10 example.com 80`
- `-p`, `--source-port <port>` *(u16)* - bind to a specific local port. Example: `zigcat --source-port 55000 example.com 80`
- `--keep-source-port` *(flag)* - retry connections without changing the bound source port. Example: `zigcat --keep-source-port --source-port 55000 example.com 80`
- `-n`, `--nodns` *(flag)* - skip DNS lookups; treat host as literal address. Example: `zigcat --nodns 93.184.216.34 80`

## Timing & Flow Control
- `-w`, `--wait <seconds>` *(u32 seconds)* - set connect timeout (converted to milliseconds). Example: `zigcat --wait 10 example.com 80`
- `-i`, `--idle-timeout <seconds>` *(u32 seconds)* - drop idle connections after the given timeout. Example: `zigcat -l --idle-timeout 60 9000`
- `-d`, `--delay <ms>` *(u32 milliseconds)* - pause between reads/writes for traffic shaping. Example: `zigcat --delay 250 example.com 80`
- `--close-on-eof` *(flag)* - close the socket when stdin reaches EOF. Example: `zigcat --close-on-eof example.com 80`
- `--no-shutdown` *(flag)* - keep the write side open after stdin EOF. Example: `zigcat --no-shutdown example.com 80`

## Transfer Behavior
- `--send-only` *(flag)* - disable reading from the socket. Example: `zigcat --send-only example.com 80`
- `--recv-only` *(flag)* - disable writing to the socket. Example: `zigcat --recv-only example.com 80`
- `-C`, `--crlf` *(flag)* - translate LF to CRLF on transmit. Example: `zigcat --crlf mail.example.com 25`
- `-t`, `--telnet` *(flag)* - process Telnet IAC sequences. Example: `zigcat --telnet bbs.example.com 23`
- `--no-stdin` *(flag)* - do not pipe stdin into the exec child. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stdin`
- `--no-stdout` *(flag)* - discard exec stdout. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stdout`
- `--no-stderr` *(flag)* - discard exec stderr. Example: `zigcat -l 9000 -e /usr/bin/logger --no-stderr`

## Execution Integration
- `-e`, `--exec <cmd> [args...]` *(string command + optional args)* - run a program per connection; arguments continue until the next flag or end-of-options marker. Example: `zigcat -l 9000 -e /usr/bin/cat`
- `-c`, `--sh-exec <command>` *(string)* - run command through the system shell. Example: `zigcat -l 9000 -c "/usr/bin/logger -t zigcat"`
- `--allow` *(flag)* - acknowledge dangerous exec operations (required for some hardened setups). Example: `zigcat -l 9000 --allow -e /usr/bin/cat`
- `--drop-user <name>` *(string)* - drop privileges to the named user after binding. Example: `zigcat -l 9000 --drop-user nobody`

## File Transfers

You can use `zigcat` to send files between two machines.

**Receiver:**
```bash
zigcat -l 1234 > received_file.txt
```

**Sender:**
```bash
zigcat localhost 1234 < original_file.txt
```

For encrypted transfers, use the `--ssl` flag.

**Receiver (with SSL):**
```bash
zigcat -l --ssl --ssl-cert cert.pem --ssl-key key.pem 1234 > received_file.txt
```

**Sender (with SSL):**
```bash
zigcat --ssl localhost 1234 < original_file.txt
```

## Remote Shell

You can get a remote shell using `zigcat`.

**Listener:**
```bash
zigcat -l 1234 -e /bin/sh
```

**Connector:**
```bash
zigcat localhost 1234
```

For an encrypted remote shell, use the `--ssl` flag.

**Listener (with SSL):**
```bash
zigcat -l --ssl --ssl-cert cert.pem --ssl-key key.pem 1234 -e /bin/sh
```

**Connector (with SSL):**
```bash
zigcat --ssl localhost 1234
```

## Security & Access Control
- `--deny-file <path>` *(string path)* - load blocked host rules. Example: `zigcat -l 9000 --deny-file config/deny.list`
- `--allow-file <path>` *(string path)* - load allowed host rules. Example: `zigcat -l 9000 --allow-file config/allow.list`
- `--allow-ip <list>` *(comma-separated strings)* - inline allowlist of CIDRs or addresses. Example: `zigcat -l 9000 --allow-ip 192.168.1.0/24,10.0.0.5`
- `--deny-ip <list>` *(comma-separated strings)* - inline blocklist of CIDRs or addresses. Example: `zigcat -l 9000 --deny-ip 0.0.0.0/0`

## TLS Options
- `--ssl` *(flag)* - enable TLS. Example: `zigcat --ssl example.com 443`
- `--ssl-verify` *(flag)* - force certificate verification (explicit opt-in). Example: `zigcat --ssl --ssl-verify example.com 443`
- `--no-ssl-verify` *(flag)* - disable certificate verification (insecure). Example: `zigcat --ssl --no-ssl-verify example.com 443`
- `--ssl-verify=false` *(flag)* - alternate form to disable verification. Example: `zigcat --ssl --ssl-verify=false example.com 443`
- `--ssl-cert <file>` *(string path)* - server certificate file. Example: `zigcat -l 8443 --ssl --ssl-cert certs/server.crt`
- `--ssl-key <file>` *(string path)* - server private key. Example: `zigcat -l 8443 --ssl --ssl-key certs/server.key`
- `--ssl-trustfile <file>` *(string path)* - CA bundle for client verification. Example: `zigcat --ssl --ssl-trustfile /etc/ssl/certs/ca-bundle.crt example.com 443`
- `--ssl-crl <file>` *(string path)* - certificate revocation list. Example: `zigcat --ssl --ssl-crl revocations.pem example.com 443`
- `--ssl-ciphers <list>` *(string)* - OpenSSL cipher list. Example: `zigcat --ssl --ssl-ciphers "TLS_AES_128_GCM_SHA256" example.com 443`
- `--ssl-servername <name>` *(string)* - override SNI hostname. Example: `zigcat --ssl --ssl-servername web.internal example.net 443`
- `--ssl-alpn <protocols>` *(string)* - comma-separated ALPN protocols. Example: `zigcat --ssl --ssl-alpn "h2,http/1.1" example.com 443`

## Proxy Support
- `--proxy <target>` *(string)* - proxy address (e.g. `socks5://host:port` or `http://host:port`). Example: `zigcat --proxy socks5://127.0.0.1:1080 example.com 80`
- `--proxy-type <mode>` *(enum: http|socks4|socks5)* - override proxy protocol. Example: `zigcat --proxy proxy.local:8080 --proxy-type http example.com 80`
- `--proxy-auth <user:pass>` *(string)* - supply basic proxy credentials. Example: `zigcat --proxy http://proxy.local:8080 --proxy-auth alice:secret example.com 80`
- `--proxy-dns <mode>` *(enum: local|remote|both)* - control where DNS resolves. Example: `zigcat --proxy socks5://127.0.0.1:1080 --proxy-dns remote example.com 80`

## Zero-I/O & Scanning
- `-z`, `--zero-io` *(flag)* - perform connection checks without data transfer. Example: `zigcat -z example.com 443`
- `--scan-parallel` *(flag)* - parallelize zero-I/O scans. Example: `zigcat -z --scan-parallel example.com 1-1024`
- `--scan-randomize` *(flag)* - randomize scan order. Example: `zigcat -z --scan-parallel --scan-randomize example.com 1-1024`
- `--scan-workers <count>` *(usize)* - worker threads for parallel scans. Example: `zigcat -z --scan-parallel --scan-workers 20 example.com 1-1024`
- `--scan-delay <ms>` *(u32 milliseconds)* - delay between probes for stealth. Example: `zigcat -z --scan-parallel --scan-delay 100 example.com 1-1024`

All paths accept ASCII and must avoid traversal sequences (`..`) to pass internal validation. Numeric inputs are parsed in base 10 and must fit the listed Zig integer type. Combine options as needed, staying mindful of mutual exclusions such as `--send-only` vs. `--recv-only` and `--broker` vs. `--chat`.
