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

## Building Releases Locally (via Docker)

ZigCat includes a comprehensive release build system that uses Docker to build production-ready artifacts for multiple platforms and configurations locally, without relying on CI/CD.

### Quick Start

```bash
# Build all release artifacts (Linux, Alpine, FreeBSD)
make release-all

# Build specific variants
make release-linux      # All Linux variants (glibc+TLS, musl static)
make release-alpine     # Alpine musl+wolfSSL (~835KB smallest)
make release-bsd        # FreeBSD cross-compiled
make release-macos      # macOS (requires native macOS)
```

### Release Build Matrix

| **Variant** | **Arch** | **Libc** | **TLS** | **Linking** | **Size** |
|-------------|----------|----------|---------|-------------|----------|
| Linux glibc | x64, arm64 | glibc | OpenSSL | Dynamic | ~2.0-2.2 MB |
| Linux musl | x64, arm64, x86, arm | musl | None | Static | ~1.6-1.8 MB |
| **Alpine wolfSSL** | x64, arm64 | musl | wolfSSL | Static | **~835 KB** ✨ |
| FreeBSD | x64 | N/A | None | Cross-compiled | ~1.8 MB |
| macOS | x64, arm64 | N/A | OpenSSL | Native only | ~2.0 MB |

### Features

- ✅ **Complete platform coverage**: Linux (glibc, musl), Alpine (wolfSSL), FreeBSD, macOS
- ✅ **Multiple TLS options**: OpenSSL (default), wolfSSL (smallest), or no TLS (maximum portability)
- ✅ **Automatic packaging**: Creates properly named tarballs with LICENSE, README
- ✅ **Checksums**: Generates SHA256SUMS for artifact verification
- ✅ **Validation**: Smoke tests all binaries before release
- ✅ **Version management**: Auto-detects version from build.zig

### Artifact Structure

Release artifacts are organized by version:

```
docker-tests/artifacts/releases/
└── v0.1.0/
    ├── zigcat-v0.1.0-linux-x64-glibc-openssl.tar.gz
    ├── zigcat-v0.1.0-linux-x64-musl-static.tar.gz
    ├── zigcat-v0.1.0-alpine-x64-musl-wolfssl-static.tar.gz (smallest!)
    ├── zigcat-v0.1.0-freebsd-x64.tar.gz
    ├── SHA256SUMS
    └── RELEASE_NOTES.md
```

### Prerequisites

- Docker (version 20.10.6+ recommended)
- yq (YAML processor): `brew install yq` (macOS) or `apt install yq` (Ubuntu)
- Make (usually pre-installed)

### Complete Documentation

For detailed release build documentation, see **[RELEASE_BUILDS.md](RELEASE_BUILDS.md)**, which covers:
- Complete build matrix and platform details
- Advanced configuration options
- Platform-specific notes (Alpine, FreeBSD, macOS)
- Troubleshooting guide
- Complete release workflow

### Example Workflow

```bash
# 1. Build all release artifacts
make release-all

# 2. Validate binaries
make release-validate

# 3. Generate checksums
make release-checksums

# 4. Review artifacts
ls -lh docker-tests/artifacts/releases/v*/

# 5. Upload to GitHub releases
```

### Makefile Targets

```bash
make release-all        # Build all variants (Linux, Alpine, BSD)
make release-linux      # Linux glibc + musl only
make release-alpine     # Alpine wolfSSL (smallest ~835KB)
make release-bsd        # FreeBSD cross-compiled
make release-macos      # macOS native builds (requires macOS)
make release-package    # Package artifacts into tarballs
make release-checksums  # Generate SHA256SUMS
make release-validate   # Smoke test all binaries
make release-clean      # Clean release artifacts
```

### Why Docker-based Builds?

- **Reproducible**: Same environment every time
- **Cross-compilation**: Build for any platform from macOS/Linux
- **No local dependencies**: All TLS libraries in containers
- **CI/CD parity**: Same builds locally and in CI

### Platform Notes

**Alpine wolfSSL (Smallest Build)**:
- Only ~835KB with full TLS support
- Uses wolfSSL (GPLv2 license)
- Requires custom seccomp profile for Docker builds
- See `docker-tests/DOCKER_BUILD_ERRORS.md` for troubleshooting

**FreeBSD**:
- Cross-compiled from Linux (NO TLS)
- For TLS support, build natively on FreeBSD

**macOS**:
- Requires native macOS system (not Docker)
- Cannot be cross-compiled due to Apple licensing

For complete details, troubleshooting, and advanced usage, see **[RELEASE_BUILDS.md](RELEASE_BUILDS.md)**.

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
- Windows: See [Building on Windows](#building-on-windows) for vcpkg, Chocolatey, and manual installation instructions

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
| Static musl + wolfSSL (Alpine) | wolfSSL | **835 KB** | ✅ Fully static with TLS, no dependencies! |
| No TLS | N/A | ~1.8 MB | Smallest without TLS |

**Static Linking with wolfSSL:**

wolfSSL supports static linking, enabling TLS in fully static musl binaries:

```bash
# Build static musl binary with TLS (wolfSSL backend)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=true -Dtls-backend=wolfssl

# Binary will be named zigcat-wolfssl for clarity
./zig-out/bin/zigcat-wolfssl --version
```

**Licensing:**
- OpenSSL backend: MIT license
- wolfSSL backend: **GPLv2 license** (binary becomes GPL if distributed)

**Known Issues - Docker Build Failures:**

**Error**: `error: unable to access options file '.zig-cache/.../options.zig': Unexpected` (errno 38: ENOSYS)

**Root Cause**: Docker's seccomp security profile blocks the `faccessat2` syscall (introduced in Linux 5.8), which Zig 0.15.1 uses for file access checks during the build process. This is **NOT** a symlink, filesystem, or cache corruption issue—it's pure syscall blocking at the container security layer.

**Technical Details**:
- Zig 0.15.1 officially requires Linux kernel 5.10+ ([release notes](https://ziglang.org/download/0.15.1/release-notes.html))
- The `faccessat2` syscall is used by Zig's standard library without fallback handling
- Docker versions < 20.10.6 or libseccomp < 2.4.4 block this syscall, returning ENOSYS
- wolfSSL builds trigger additional options file checks, hitting the blocked syscall
- Confirmed by Zig maintainers in issues [#24821](https://github.com/ziglang/zig/issues/24821) and [#23514](https://github.com/ziglang/zig/issues/23514)

**Affected Environments**: Docker only (Alpine 3.18, Ubuntu 22.04); native macOS/Linux builds succeed

**Solutions** (ranked by preference):

1. **Update Docker Infrastructure** (Best long-term)
   - Requires: Docker Engine 20.10.6+, libseccomp 2.4.4+, runc 1.0.0-rc93+
   - Check versions: `docker --version` and `dpkg -l | grep libseccomp`

2. **Use Custom Seccomp Profile** (Production-ready)
   ```bash
   docker buildx build \
     --security-opt seccomp=docker-tests/seccomp/zig-builder.json \
     -f docker-tests/dockerfiles/Dockerfile.alpine .
   ```
   - Safe for production: whitelists only required syscalls (`faccessat`, `faccessat2`, `statx`)
   - Profile location: `docker-tests/seccomp/zig-builder.json`

3. **Disable Seccomp** (Testing only, NOT production)
   ```bash
   docker buildx build \
     --security-opt seccomp=unconfined \
     -f docker-tests/dockerfiles/Dockerfile.alpine .
   ```
   - ⚠️ **Security risk**: Removes all syscall filtering

4. **Build Locally** (Simplest workaround)
   ```bash
   zig build -Dtls=true -Dtls-backend=wolfssl
   # Produces working 2.4MB binary
   ```

**Status**: ✅ **RESOLVED** - Docker builds now work with custom seccomp profile! Alpine produces **835KB** fully static musl binaries with TLS (66% smaller than target). Use `docker build --security-opt seccomp=docker-tests/seccomp/zig-builder.json` for all builds. Local builds also work perfectly.

**For detailed troubleshooting**, see: `docker-tests/DOCKER_BUILD_ERRORS.md`

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

## Building on Windows

ZigCat builds natively on Windows with support for both OpenSSL and wolfSSL TLS backends. The build system automatically detects libraries installed via vcpkg, Chocolatey, or manual installation.

### Prerequisites: Install Zig

**Option 1: Chocolatey (Recommended)**
```powershell
choco install zig
```

**Option 2: Direct Download**
- Download Zig 0.15.1 or later from: https://ziglang.org/download/
- Extract to `C:\zig` (or your preferred location)
- Add to PATH: `setx PATH "%PATH%;C:\zig"`

### OpenSSL Installation (3 methods)

The build system supports three OpenSSL installation methods, automatically detecting libraries in the following order:

#### 1. vcpkg (Recommended for CI/CD)

vcpkg is Microsoft's C/C++ package manager, ideal for reproducible builds and CI/CD pipelines.

```powershell
# Install vcpkg
git clone https://github.com/Microsoft/vcpkg.git C:\vcpkg
cd C:\vcpkg
.\bootstrap-vcpkg.bat

# Install OpenSSL for x64-windows
.\vcpkg install openssl:x64-windows

# Set environment variable (required for build detection)
setx VCPKG_ROOT "C:\vcpkg"
```

**Note**: After setting `VCPKG_ROOT`, restart your terminal or IDE for the environment variable to take effect.

#### 2. Chocolatey

```powershell
choco install openssl
```

This installs OpenSSL to `C:\Program Files\OpenSSL-Win64\`, which the build system auto-detects.

#### 3. Manual Download (Win64 OpenSSL)

- Download from: https://slproweb.com/products/Win32OpenSSL.html
- Choose "Win64 OpenSSL v3.x.x" (not the "Light" version)
- Install to default location: `C:\Program Files\OpenSSL-Win64\`
- Add to PATH (for runtime DLLs): `setx PATH "%PATH%;C:\Program Files\OpenSSL-Win64\bin"`

**Supported Paths** (auto-detected by build system):
- vcpkg: `%VCPKG_ROOT%\installed\x64-windows\`
- GitHub Actions: `C:\Program Files\OpenSSL\`
- Chocolatey: `C:\Program Files\OpenSSL-Win64\` or `C:\OpenSSL-Win64\`

### wolfSSL Installation (2 methods)

wolfSSL provides a lightweight TLS alternative (60% smaller binaries, GPLv2 license).

#### 1. vcpkg

```powershell
# Install wolfSSL for x64-windows
cd C:\vcpkg
.\vcpkg install wolfssl:x64-windows
```

#### 2. Build from Source

- Download from: https://www.wolfssl.com/download/
- Extract and open `wolfssl64.sln` in Visual Studio
- Build the Release configuration
- Copy headers to `C:\Program Files\wolfSSL\include\`
- Copy `wolfssl.lib` to `C:\Program Files\wolfSSL\lib\`

**License Warning**: wolfSSL is licensed under GPLv2. Binaries built with wolfSSL must comply with GPLv2 terms if distributed.

### Build Commands

```powershell
# Standard build (no TLS)
zig build

# Build with OpenSSL TLS support (default backend)
zig build -Dtls=true

# Build with wolfSSL TLS support (lightweight alternative)
zig build -Dtls=true -Dtls-backend=wolfssl

# Build with optimizations
zig build -Doptimize=ReleaseSmall -Dstrip=true

# Cross-compile for Windows from Linux/macOS
zig build -Dtarget=x86_64-windows -Dtls=true
```

**Binary Location**: `.\zig-out\bin\zigcat.exe` (or `zigcat-wolfssl.exe` for wolfSSL builds)

### Binary Size Comparison

| Configuration | Binary Size | Dependencies | Notes |
|--------------|-------------|--------------|-------|
| No TLS | ~1.8 MB | None | Smallest, no SSL/TLS |
| OpenSSL TLS | ~2.0-2.2 MB | `libssl-3-x64.dll`, `libcrypto-3-x64.dll` | Default, ubiquitous |
| wolfSSL TLS | ~2.4 MB | `wolfssl.dll` | Lightweight, GPLv2 license |

**Note**: Windows builds use dynamic linking by default. Ensure OpenSSL/wolfSSL DLLs are in your PATH or in the same directory as `zigcat.exe`.

### Troubleshooting

#### Error: "OpenSSL not found"

**Symptoms**: Build fails with `TLS support requested but OpenSSL not found`

**Solutions**:
1. **vcpkg users**: Verify `VCPKG_ROOT` environment variable is set:
   ```powershell
   echo %VCPKG_ROOT%  # Should output: C:\vcpkg
   ```
   If not set, run: `setx VCPKG_ROOT "C:\vcpkg"` and restart your terminal.

2. **Chocolatey/Manual users**: Verify installation path exists:
   ```powershell
   dir "C:\Program Files\OpenSSL-Win64\bin\libssl-3-x64.dll"
   ```
   If not found, reinstall OpenSSL or use vcpkg.

3. **Check library detection** (verbose output):
   ```powershell
   zig build -Dtls=true 2>&1 | findstr "OpenSSL Detection"
   ```
   This shows which paths the build system checked.

#### Error: "library not found for -llibssl"

**Symptoms**: Linker fails to find `libssl.lib`

**Solutions**:
1. **vcpkg users**: Ensure you installed for the correct triplet:
   ```powershell
   .\vcpkg list openssl  # Should show: openssl:x64-windows
   ```
   If not, run: `.\vcpkg install openssl:x64-windows`

2. **Manual users**: Verify `.lib` files exist:
   ```powershell
   dir "C:\Program Files\OpenSSL-Win64\lib\libssl.lib"
   dir "C:\Program Files\OpenSSL-Win64\lib\libcrypto.lib"
   ```
   If not found, download the full installer (not "Light" version) from slproweb.com.

#### Runtime Error: "libssl-3-x64.dll not found"

**Symptoms**: `zigcat.exe` runs but crashes with DLL not found error

**Solutions**:
1. **Add OpenSSL to PATH**:
   ```powershell
   setx PATH "%PATH%;C:\Program Files\OpenSSL-Win64\bin"
   ```
   Restart your terminal after setting PATH.

2. **Copy DLLs to executable directory** (alternative):
   ```powershell
   copy "C:\Program Files\OpenSSL-Win64\bin\*.dll" .\zig-out\bin\
   ```

3. **vcpkg users**: Copy DLLs from vcpkg installation:
   ```powershell
   copy "%VCPKG_ROOT%\installed\x64-windows\bin\*.dll" .\zig-out\bin\
   ```

#### Performance Issues

**Symptoms**: Slow build times or large binaries

**Solutions**:
- **Enable Link-Time Optimization** (15-20% smaller binaries):
  ```powershell
  zig build -Doptimize=ReleaseSmall -Dlto=thin
  ```

- **Use wolfSSL backend** (60% smaller TLS binary):
  ```powershell
  zig build -Dtls=true -Dtls-backend=wolfssl
  ```

### Development Tools

**Recommended IDE Setup**:
- Visual Studio Code with Zig Language extension
- ZLS (Zig Language Server): https://github.com/zigtools/zls

**Testing**:
```powershell
# Run all tests
zig build test

# Run specific test suites
zig build test-net        # Network tests
zig build test-ssl        # TLS/SSL tests (requires OpenSSL/wolfSSL)
zig build test-timeout    # Timeout handling tests
```

### Cross-Compilation from Windows

You can cross-compile for other platforms from Windows:

```powershell
# Linux x64 (musl static binary)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos

# macOS Intel
zig build -Dtarget=x86_64-macos
```

**Note**: Cross-compiled TLS builds require the target platform's SSL libraries to be available on the Windows build machine.