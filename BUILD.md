# Building ZigCat

These instructions cover all supported build workflows. Downloadable release binaries are published on the project's Releases page; follow the steps below only if you want to build from source.

## Using the Makefile (recommended)

```bash
# Show available targets
make help

# Native builds
make build              # Current platform
make build-small        # Stripped symbols
make build-static       # Static Linux binary (musl)

# Cross compilation
make linux-x64-static   # Linux x64, fully static
make linux-arm64-static # Linux ARM64, fully static
make macos-x64          # macOS Intel
make macos-arm64        # macOS Apple Silicon
make windows-x64        # Windows 64-bit

# Utilities
make check-size         # Compare binary sizes
make deb                # Build Debian package
make rpm                # Build RPM package
make clean              # Remove build artifacts
```

### Build cheat sheet

| Target | Command | Binary size | Notes |
|--------|---------|-------------|-------|
| macOS (native) | `make build` | ~1.8 MB | Dynamic, stripped |
| Linux x64 (static) | `make linux-x64-static` | ~6.5 MB | No dependencies |
| Linux x64 (dynamic) | `make linux-x64` | ~6.2 MB | Requires glibc |
| Linux x86 (static) | `make linux-x86-static` | ~1.6 MB | Portable 32-bit |
| Linux ARM64 (static) | `make linux-arm64-static` | ~1.7 MB | Portable 64-bit |
| Linux ARM (static) | `make linux-arm-static` | ~1.6 MB | Portable 32-bit ARM |
| macOS Intel | `make macos-x64` | ~1.8 MB | Dynamic |
| Windows x64 | `make windows-x64` | ~2 MB | Dynamic |
| Debian package | `make deb` | n/a | Produces `.deb` |
| RPM package | `make rpm` | n/a | Produces `.rpm` |

## Using Zig build directly

```bash
# Standard build
zig build

# Adjust features
zig build -Dstrip=false        # Keep debug symbols
zig build -Dtls=false          # Disable TLS support
zig build -Dtls=true           # Build with OpenSSL-based TLS
zig build -Dunixsock=false     # Disable Unix domain sockets
zig build -Dstatic=true        # Static linking (Linux only)

# Cross compilation examples
zig build -Dtarget=x86_64-linux-musl -Dstatic=true
zig build -Dtarget=aarch64-linux-musl -Dstatic=true
zig build -Dtarget=x86_64-macos
zig build -Dtarget=x86_64-windows
```

## Distribution packages

```bash
# Debian package (requires dpkg-buildpackage, debhelper, zig >= 0.15.1)
make deb

# RPM package (requires rpmbuild, zig >= 0.15.1)
make rpm
```

Package metadata lives under `docs/packaging/`.

## TLS/SSL builds

ZigCat supports TLS via two backends: **OpenSSL** (default, ubiquitous) and **wolfSSL** (lightweight, 60% smaller).

### OpenSSL Backend (default)

```bash
# Enable TLS support with OpenSSL (default)
make build-with-tls
zig build -Dtls=true

# Explicitly select OpenSSL backend
zig build -Dtls=true -Dtls-backend=openssl
```

**Prerequisites:**
- macOS: `brew install openssl`
- Debian/Ubuntu: `sudo apt install libssl-dev`
- RHEL/Fedora: `sudo yum install openssl-devel`
- Windows: use a prebuilt OpenSSL package (e.g., from slproweb.com)

**Features:**
- Full TLS 1.0-1.3 support
- DTLS 1.0-1.3 support (Datagram TLS over UDP)
- Ubiquitous, battle-tested library
- Binary size: ~2.0-2.2 MB (native dynamic build)

### wolfSSL Backend (opt-in)

```bash
# Enable TLS support with wolfSSL backend
zig build -Dtls=true -Dtls-backend=wolfssl
```

**Prerequisites:**
- macOS: `brew install wolfssl`
- Debian/Ubuntu: `sudo apt install libwolfssl-dev`
- RHEL/Fedora: `sudo yum install wolfssl-devel`
- Build from source: https://www.wolfssl.com/download/

**Features:**
- Full TLS 1.0-1.3 support
- **60% smaller binary** (2.4 MB vs 6 MB on macOS)
- Lightweight, optimized for embedded systems
- FIPS 140-2/140-3 certified versions available
- **Note:** DTLS not yet implemented for wolfSSL backend

**Size Comparison:**

| Configuration | Backend | Binary Size | Notes |
|--------------|---------|-------------|-------|
| Native build | OpenSSL | ~2.0-2.2 MB | Default, includes DTLS |
| Native build | wolfSSL | ~2.4 MB | 60% smaller, no DTLS |
| No TLS | N/A | ~1.8 MB | Smallest |

### Disable TLS support

```bash
# Disable TLS completely
make build-no-tls
zig build -Dtls=false
```

## Static vs. dynamic linking

- **Static builds (Linux only)** use musl and embed dependencies; binaries are ~6 MB but run on any modern distribution without extra libraries.
- **Dynamic builds** are smaller but depend on the platform libc (`libSystem`, `glibc`, etc.). Use these for native deployments where dependencies are available.
