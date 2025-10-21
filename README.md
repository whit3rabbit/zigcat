<p align="center">
  <a href="https://github.com/whit3rabbit/zigcat-github">
    <img src="assets/logo.png" alt="ZigCat logo" width="500">
  </a>
</p>

# ZigCat

ZigCat is a modern, secure alternative to netcat/ncat built in Zig. It keeps the classic "Swiss army knife for TCP/UDP" feel while adding TLS, access control, and broker/chat collaboration modes.

* This should not be used in any production environments. This is just a hobby project to test zig. *

## Getting started
- Download the latest release binary for your platform from the [Releases](https://github.com/whit3rabbit/zigcat/releases) page.
- Make it executable (`chmod +x zigcat` on Unix-like systems).
- Run `zigcat --help` or open [`USAGE.md`](USAGE.md) for the quick-start cheat sheet.
- Zigcat is built against Zig `0.15.1`; Zig `0.16` introduces breaking changes, so stick with `0.15.1` until support lands.

### Quick examples
- Connect to a service: `zigcat example.com 443`
- Listen for inbound connections: `zigcat -l 9000`
- Secure TLS client: `zigcat --ssl mail.example.com 993`
- Secure DTLS client (UDP): `zigcat --dtls example.com 4433`
- Broker chat relay: `zigcat -l --broker --max-clients 100 9100`
- Stealth port scan: `zigcat -z --scan-parallel --scan-randomize target.example 1-1024`

## What it can do
- **Flexible transports**: TCP, UDP, SCTP, Unix sockets, IPv4/IPv6.
- **Secure by default**: TLS/DTLS with verification, access allow/deny lists, privilege dropping.
- **Powerful modes**: Broker/chat relays, exec pipelines, zero-I/O port scanning.
- **Observability**: Verbosity levels up to trace, hex dump logging, structured output files.
- **Portable**: Runs on Linux, macOS, BSD, and Windows with small binaries.
- **Platform-native I/O**: Leverages Linux `io_uring` when available (with epoll/poll fallbacks), and on Windows pairs IOCP with named pipe/Unix socket shims so the same CLI works everywhere.
- **TLS backends**: Supports OpenSSL and wolfSSL (TLS only—wolfSSL builds currently disable DTLS/UDP) so you can match licensing and footprint needs.

## Building from source
Prebuilt downloads live on the Releases page. If you prefer to compile locally, follow the detailed instructions in `BUILD.md`.

## Documentation
- [`USAGE.md`](USAGE.md) - quick-start cheat sheet covering core to advanced usage.
- [`BUILD.md`](BUILD.md) - platform-specific build commands and packaging tips.
- `docs/` - additional architecture notes, testing guides, and plans.

## Licensing

The core source code of zigcat is licensed under the **MIT License**.

However, the license of the final compiled binary depends on the build options you choose:

-   **Default (OpenSSL build):** The binary is licensed under the **MIT License**.
-   **wolfSSL build (`-Dtls-backend=wolfssl`):** Due to the GPLv2 license of wolfSSL, any binary built with this option is subject to the **GNU GPLv2**.

Please see the `LICENSE` file for full details. The texts for the MIT and GPLv2 licenses are available in `LICENSE-MIT` and `LICENSE-GPLv2`, respectively.
