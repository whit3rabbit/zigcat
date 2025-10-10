# ZigCat - Modern Netcat Implementation

A cross-platform, secure implementation of netcat/ncat written in Zig.

## Quick Start

```bash
# Build for current platform (stripped, ~1.8MB)
zig build

# Or use Makefile
make build              # Standard build
make build-static       # Static Linux binary

# Run with arguments
zig build run -- --help

# Run tests
zig build test
```

## Features

- Cross-Platform: Linux, macOS, Windows, BSD support
- Security-First: TLS encryption, access controls, memory safety
- Lightweight: Small binary size (1.8MB native, 6.3MB static)
- Modern: Built with Zig for performance and safety
- Portable: Static binaries with no external dependencies (Linux)

## Build Guide

### Using Makefile (Recommended)

```bash
# Show all available targets
make help

# Native builds
make build              # Current platform
make build-small        # Stripped symbols
make build-static       # Static Linux binary (musl)

# Cross-compilation
make linux-x64-static   # Linux x64 static (portable)
make linux-arm64-static # Linux ARM64 static
make macos-x64          # macOS Intel
make macos-arm64        # macOS Apple Silicon
make windows-x64        # Windows 64-bit

# Utilities
make check-size         # Compare binary sizes
make deb                # Build Debian package (dpkg-buildpackage)
make rpm                # Build RPM package (rpmbuild)
make clean              # Remove build artifacts
```

### Build Cheat Sheet

| Target Platform | Command | Binary Size | Notes |
|----------------|---------|-------------|-------|
| **macOS (native)** | `make build` | 1.8MB | Dynamic, stripped |
| **Linux x64 (static)** | `make linux-x64-static` | 6.5MB | No dependencies, portable |
| **Linux x64 (dynamic)** | `make linux-x64` | 6.2MB | Requires glibc |
| **Linux x86/32-bit (static)** | `make linux-x86-static` | 1.6MB | No dependencies, 32-bit |
| **Linux ARM64 (static)** | `make linux-arm64-static` | 1.7MB | No dependencies, portable |
| **Linux ARM/32-bit (static)** | `make linux-arm-static` | 1.6MB | No dependencies, 32-bit ARM |
| **macOS Intel** | `make macos-x64` | 1.8MB | Dynamic |
| **Windows x64** | `make windows-x64` | ~2MB | Dynamic |
| **Debian package** | `make deb` | n/a | Generates `.deb` via dpkg-buildpackage |
| **RPM package** | `make rpm` | n/a | Generates `.rpm` via rpmbuild |

### Using Zig Build Directly

```bash
# Feature flags
zig build -Dstrip=false        # Keep debug symbols
zig build -Dtls=false          # Disable TLS support
zig build -Dtls=true           # Enable TLS with OpenSSL
zig build -Dunixsock=false     # Disable Unix domain sockets
zig build -Dstatic=true        # Static linking (Linux only)

# Cross-compilation examples
zig build -Dtarget=x86_64-linux-musl -Dstatic=true    # Static Linux x64
zig build -Dtarget=aarch64-linux-musl -Dstatic=true   # Static Linux ARM64
zig build -Dtarget=x86_64-macos                       # macOS Intel
zig build -Dtarget=x86_64-windows                     # Windows x64
```

### Linux Packages

Both Debian and RPM package metadata live in the repository for reproducible distro builds.

```bash
# Debian package (requires dpkg-buildpackage, debhelper, zig >= 0.15.1)
make deb

# RPM package (requires rpmbuild, zig >= 0.15.1)
make rpm
```

See `docs/packaging/debian.md` and `docs/packaging/rpm.md` for dependency details and build outputs.

### TLS/SSL Support

ZigCat supports TLS encryption for secure connections:

```bash
# Build with TLS support (default, requires OpenSSL)
make build-with-tls             # Explicit TLS build
zig build -Dtls=true            # Using zig directly

# Build without TLS support
make build-no-tls               # Smaller binary, no TLS features
zig build -Dtls=false           # Using zig directly

# Prerequisites for TLS builds
# macOS: brew install openssl
# Linux: sudo apt install libssl-dev (Debian/Ubuntu)
#        sudo yum install openssl-devel (RHEL/Fedora)
# Windows: Download from https://slproweb.com/products/Win32OpenSSL.html
```

**TLS Features:**
- Client TLS: Connect to HTTPS/TLS servers (`--ssl` flag)
- Server TLS: Accept encrypted connections (`-l --ssl --ssl-cert cert.pem --ssl-key key.pem`)
- Certificate verification (enabled by default, `--ssl-verify=false` to disable)
- OpenSSL integration for production-grade encryption

**Build Size Impact:**
- With TLS: ~2.0-2.2MB (native), links OpenSSL dynamically
- Without TLS: ~1.8MB (native), no external dependencies

### Static vs Dynamic Linking

**Static builds (Linux only)**:
- Fully standalone binaries with no external dependencies
- Use musl libc (not glibc)
- Larger size (~6MB) but maximum portability
- Run on any Linux distribution without library requirements

**Dynamic builds**:
- Smaller size (~1.8MB on macOS, ~6MB on Linux cross-compiled)
- Require system libraries (libSystem on macOS, glibc on Linux)
- Optimal for native platform builds

## Documentation

- [Project Plan](docs/PLAN.md) - Requirements and feature roadmap
- [Testing Guide](docs/TESTS.md) - How to run the test suite
- [Static Linking Analysis](docs/STATIC_LINKING_ANALYSIS.md) - Build size analysis
- [Architecture](docs/architecture/) - Technical design documents
- [Task Tracking](docs/TODO.md) - Current development status

## License

See project documentation for licensing information.
