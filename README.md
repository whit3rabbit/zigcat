<p align="center">
  <a href="https://github.com/whit3rabbit/zigcat-github">
    <img src="assets/logo.png" alt="ZigCat logo" width="500">
  </a>
</p>

# ZigCat

ZigCat is a modern, secure alternative to netcat/ncat built in Zig. It keeps the classic "Swiss army knife for TCP/UDP" feel while adding TLS, access control, and broker/chat collaboration modes.

## Getting started
- Download the latest release binary for your platform from the [Releases](https://github.com/whit3rabbit/zigcat/releases) page.
- Make it executable (`chmod +x zigcat` on Unix-like systems).
- Run `zigcat --help` or open [`USAGE.md`](USAGE.md) for the full CLI cheat sheet.

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

## Building from source
Prebuilt downloads live on the Releases page. If you prefer to compile locally, follow the detailed instructions in `BUILD.md`.

## Documentation
- [`USAGE.md`](USAGE.md) - complete CLI cheat sheet with flag types and examples.
- [`BUILD.md`](BUILD.md) - platform-specific build commands and packaging tips.
- `docs/` - additional architecture notes, testing guides, and plans.

## License
See `LICENSE` or the documentation bundle for full licensing terms.
