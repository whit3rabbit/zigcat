# Zigcat Quick Start Cheat Sheet

`zigcat` is a versatile, netcat-compatible Swiss army knife for TCP/UDP/TLS. This guide walks from the fastest ways to get moving into the advanced tricks you are likely to need next.

## 1. Core Connections
- **Connect to a service**  
  ```bash
  zigcat example.com 443
  ```
- **Listen for inbound clients**  
  ```bash
  zigcat -l 9000
  ```
- **Share a secret, let zigcat decide roles automatically (GSRN)**  
  ```bash
  zigcat --gs-secret "MySharedSecret"
  ```
  Run the same command on both peers; the relay assigns roles (no more `-l` vs client confusion).
- **Keep a listener alive for multiple clients**  
  ```bash
  zigcat -l -k 9000
  ```

## 2. Fast File Transfers
- **Send a file over direct TCP**  
  ```bash
  # Receiver
  zigcat -l 9000 > received.tar.gz

  # Sender
  cat archive.tar.gz | zigcat 198.51.100.10 9000
  ```
- **Send a file end-to-end encrypted via GSRN**  
  ```bash
  # Receiver
  zigcat --gs-secret "file-secret" > received.tar.gz

  # Sender
  cat archive.tar.gz | zigcat --gs-secret "file-secret"
  ```

## 3. TLS / SSL Basics
- **TLS client with verification**  
  ```bash
  zigcat --ssl mail.example.com 993
  ```
- **Mutual TLS with custom CA**  
  ```bash
  zigcat --ssl --cafile ca.pem --cert cert.pem --key key.pem secure.example 8443
  ```
- **DTLS (TLS over UDP)**  
  ```bash
  zigcat --dtls --udp example.com 4433
  ```

## 4. GSocket Relay Essentials
- **Dynamic role assignment** – both peers run `zigcat --gs-secret "Secret"`.
- **Custom GSRN relay**  
  ```bash
  zigcat -R relay.company.net:8443 --gs-secret "CorpSecret"
  ```
- **Troubleshooting the relay**
  - `--relay can only be used with --gs-secret` → add `--gs-secret`.
  - `Custom gsocket relay must be in host:port format` → include the port (`relay:443`).
  - Encryption is built-in; do **not** combine `--gs-secret` with `--ssl`.

## 5. Remote Shell & Exec (Handle With Care)
- **Trusted network shell**  
  ```bash
  zigcat -l 2222 -e /bin/sh --allow
  zigcat 203.0.113.5 2222
  ```
- **Secure shell over GSRN with allow list**  
  ```bash
  zigcat -l --gs-secret "shell-secret" -e /bin/sh --allow --allow-ip 203.0.113.0/24
  zigcat --gs-secret "shell-secret"
  ```
- Always gate `-e` with `--allow`, `--allow-ip`, or `--deny-ip` so you do not expose an unauthenticated shell.

## 6. Observability & Flow Control
- **Verbosity ladder** – `-v` (info), `-vv` (debug), `-vvv` (trace), `-vvvv` (max).
- **Hex dump a session**  
  ```bash
  zigcat -x dumps/handshake.hex example.com 443
  ```
- **Timeout tuning**  
  ```bash
  zigcat --wait 10 example.com 80      # connect timeout (seconds)
  zigcat -l --idle-timeout 120 9000    # drop idle clients
  ```
- **Persist output to file**  
  ```bash
  zigcat -o logs/session.txt example.com 80
  ```

## 7. Proxies, Ports, and Scans
- **Socks5 proxy**  
  ```bash
  zigcat --proxy socks5://127.0.0.1:1080 example.com 80
  ```
- **Force IPv4 / IPv6** – add `-4` or `-6`.
- **Zero-I/O port scan**  
  ```bash
  zigcat -z --scan-parallel --scan-randomize target.example 1-1024
  ```
- **Tune scan workers** – combine `--scan-workers <n>` and `--scan-delay <ms>` for stealth vs speed.

## 8. Quick Flag Reference
- `-u`, `--udp` – switch to UDP.
- `--sctp` – SCTP transport.
- `-U <path>` – Unix domain sockets.
- `--broker` / `--chat` – multi-client relays (mutually exclusive).
- `--max-clients <n>` – cap broker/chat peers.
- `--proxy-auth user:pass` – credentials for HTTP/SOCKS proxies.

## 9. Troubleshooting Cheats
- **Need more visibility?** → add `-vv` to watch the relay and handshake.
- **Handshake slow or failing?** → raise `--wait` (connect timeout).
- **Data corruption?** → confirm both sides use the exact same `--gs-secret`.
- **Want dual-stack listening?** – default listen mode already binds to `0.0.0.0` and `::`.

## 10. Generate Test Certificates Quickly
```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -sha256 -days 365 -nodes
```
Use the generated files with `--cert` and `--key`. For production, obtain certificates from a trusted CA.

## 11. Read More
- `zigcat --help` – builtin usage summary.
- `zigcat.1` – full man page (`man zigcat`).
- `GSOCKET_CUSTOM_RELAY.md` – build or operate a private relay.
- `GSOCKET_IMPLEMENTATION_SUMMARY.md` – protocol internals.
- `BUILD.md` – compiling from source.

Stay safe: test locally, lock down listeners, and rotate secrets when in doubt.
