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

## Docker cross-platform testing

The Docker test system validates zigcat builds across multiple platforms and architectures with automated cross-compilation.

### Quick start

```bash
# Run all enabled platforms and tests (Linux, Alpine, FreeBSD)
./docker-tests/scripts/run-tests.sh --verbose

# Test TLS builds across all platforms
./docker-tests/scripts/run-tests.sh \
  --config docker-tests/configs/examples/tls-cross-build-test.yml \
  --verbose

# Test specific platform only
./docker-tests/scripts/run-tests.sh \
  --platforms alpine \
  --verbose
```

### Test configurations

The test system uses YAML configuration files to define platforms, architectures, and test suites:

```bash
# Default configuration (all platforms, all tests)
docker-tests/configs/test-config.yml

# TLS-specific testing (Linux, Alpine, FreeBSD with TLS enabled)
docker-tests/configs/examples/tls-cross-build-test.yml

# Platform-specific configs
docker-tests/configs/platforms/linux-only.yml
docker-tests/configs/platforms/alpine-only.yml
docker-tests/configs/platforms/freebsd-only.yml
```

### Available platforms

| Platform | Base Image | Architectures | Libc | TLS Support |
|----------|-----------|---------------|------|-------------|
| Linux | Ubuntu 22.04 | x86_64, aarch64 | glibc | OpenSSL |
| Alpine | Alpine 3.18 | x86_64, aarch64 | musl | OpenSSL |
| FreeBSD | Ubuntu 22.04 (cross) | x86_64 | libc | OpenSSL |

### Test suites

The system includes multiple test suites covering different functionality:

- **basic**: Core connectivity and functionality
- **protocols**: TLS, proxy, HTTP CONNECT, SOCKS4/5
- **features**: File transfer, exec mode, bidirectional I/O
- **timeout_tests**: Timeout handling and enforcement
- **ssl_tests**: Comprehensive TLS/SSL validation (31 tests)
- **portscan_tests**: Port scanning features (23 tests)
- **validation_tests**: Memory safety validation (13 tests)

### Advanced usage

```bash
# Custom configuration with verbose output
./docker-tests/scripts/run-tests.sh \
  --config /path/to/custom-config.yml \
  --verbose

# Parallel execution (faster, more CPU)
./docker-tests/scripts/run-tests.sh \
  --parallel \
  --verbose

# Test specific platforms and suites
./docker-tests/scripts/run-tests.sh \
  --platforms linux,alpine \
  --test-suites basic,protocols \
  --verbose

# Skip build phase (use existing artifacts)
./docker-tests/scripts/run-tests.sh \
  --skip-build \
  --test-suites smoke

# Dry run (see what would be executed)
./docker-tests/scripts/run-tests.sh \
  --config docker-tests/configs/examples/tls-cross-build-test.yml \
  --dry-run
```

### Configuration validation

```bash
# Validate configuration file
./docker-tests/scripts/config-validator.sh \
  --config-file docker-tests/configs/examples/tls-cross-build-test.yml \
  validate

# Show configuration summary
./docker-tests/scripts/config-validator.sh \
  --config-file docker-tests/configs/examples/tls-cross-build-test.yml \
  summary

# List enabled platforms
./docker-tests/scripts/config-validator.sh \
  --config-file docker-tests/configs/examples/tls-cross-build-test.yml \
  platforms
```

### Requirements

- Docker
- Docker Compose
- `yq` (YAML processor): `brew install yq` (macOS) or `apt install yq` (Ubuntu)
- Zig 0.15.1+ (only if not skipping build phase)

### Test results

Results are stored in:
- `docker-tests/results/` - Test reports (JSON)
- `docker-tests/logs/` - Detailed test logs
- `docker-tests/artifacts/` - Built binaries

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

## Building on BSD Systems

Zigcat supports FreeBSD, OpenBSD, and NetBSD, but **requires native builds** due to Zig 0.15.2 cross-compilation limitations.

Pre-built BSD binaries are **not available** in releases because:
- Zig lacks cross-compilation libc support for modern BSD versions (FreeBSD 14.x, OpenBSD 7.x, NetBSD 10.x)
- Cross-compiled binaries would fail with ABI mismatches

### FreeBSD

```bash
# Install Zig 0.15.2 or later
pkg install zig

# Build zigcat
zig build -Dtls=false -Dstrip=true

# Binary location
./zig-out/bin/zigcat
```

### OpenBSD

```bash
# Install Zig 0.15.2 or later
pkg_add zig

# Build zigcat
zig build -Dtls=false -Dstrip=true

# Binary location
./zig-out/bin/zigcat
```

### NetBSD

```bash
# Install Zig 0.15.2 or later
pkgin install zig

# Build zigcat
zig build -Dtls=false -Dstrip=true

# Binary location
./zig-out/bin/zigcat
```

**Notes:**
- TLS is disabled (`-Dtls=false`) because BSD cross-compilation doesn't support OpenSSL linking
- Native builds produce ~1.8-2.0 MB stripped binaries
- All core features (TCP, UDP, Unix sockets, port scanning, exec mode) work normally
- For TLS support on BSD, you'll need to wait for v0.1.0 which will include wolfSSL static linking
