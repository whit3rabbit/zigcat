# Building ZigCat Releases Locally

This guide explains how to build production-ready ZigCat release artifacts locally using the docker-tests release build system. You can build for multiple platforms, architectures, and configurations without relying on CI/CD.

## Quick Start

```bash
# Build all release artifacts (Linux, Alpine, FreeBSD)
make release-all

# Build specific variants
make release-linux    # Linux glibc + musl variants
make release-alpine   # Alpine musl + wolfSSL (smallest ~835KB)
make release-bsd      # FreeBSD cross-compiled

# Artifacts are created in:
# docker-tests/artifacts/releases/v{version}/
```

## Table of Contents

- [Prerequisites](#prerequisites)
- [Release Build Matrix](#release-build-matrix)
- [Build Commands](#build-commands)
- [Build Configurations](#build-configurations)
- [Artifact Structure](#artifact-structure)
- [Advanced Usage](#advanced-usage)
- [Platform-Specific Notes](#platform-specific-notes)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Tools

- **Docker**: For containerized cross-compilation builds
  - macOS: `brew install --cask docker`
  - Linux: Install Docker Engine (version 20.10.6+ recommended)
- **yq**: YAML processor for config parsing
  - macOS: `brew install yq`
  - Ubuntu: `apt install yq`
- **Make**: For convenient build targets (usually pre-installed)

### Optional Tools

- **GPG**: For signing release checksums (`--sign` flag)
- **Zig 0.15.1+**: For native builds (macOS only)

### System Requirements

- **Disk Space**: ~5GB for Docker images and build cache
- **RAM**: 4GB minimum, 8GB recommended for parallel builds
- **CPU**: Multi-core recommended for `--parallel` builds

## Release Build Matrix

The release build system supports the following platform/configuration matrix:

### Linux Variants

| **Variant** | **Arch** | **Libc** | **TLS** | **Linking** | **Size** | **Use Case** |
|-------------|----------|----------|---------|-------------|----------|--------------|
| Linux glibc | x64, arm64 | glibc | OpenSSL | Dynamic | ~2.0-2.2 MB | Modern Linux distros with TLS |
| Linux musl static | x64, arm64, x86, arm | musl | None | Static | ~1.6-1.8 MB | Maximum portability, no dependencies |
| Alpine wolfSSL | x64, arm64 | musl | wolfSSL | Static | **~835 KB** | Smallest with TLS (GPLv2 license) |

### BSD Variants

| **Variant** | **Arch** | **TLS** | **Notes** |
|-------------|----------|---------|-----------|
| FreeBSD | x64 | None | Cross-compiled from Linux |

### macOS Variants

| **Variant** | **Arch** | **TLS** | **Build Method** |
|-------------|----------|---------|------------------|
| macOS Intel | x64 | OpenSSL | **Native build required** |
| macOS Apple Silicon | arm64 | OpenSSL | **Native build required** |

**Note**: Windows builds are excluded (as per project requirements).

## Build Commands

### Using Makefile (Recommended)

```bash
# Build all release artifacts
make release-all

# Build specific platform variants
make release-linux      # All Linux variants (glibc, musl)
make release-alpine     # Alpine wolfSSL (smallest with TLS)
make release-bsd        # FreeBSD
make release-macos      # macOS (requires native macOS)

# Utility targets
make release-package    # Package artifacts into tarballs
make release-checksums  # Generate SHA256SUMS
make release-validate   # Smoke test all binaries
make release-clean      # Clean release artifacts
```

### Using Scripts Directly

```bash
# Build all variants
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-all.yml \
  --parallel \
  --verbose

# Build with specific version
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-linux.yml \
  --version v0.2.0 \
  --parallel

# Build Alpine wolfSSL variant
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-alpine.yml \
  --verbose

# Build on macOS (native)
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-macos.yml \
  --native \
  --verbose
```

## Build Configurations

Release configurations are defined in YAML files under `docker-tests/configs/releases/`:

### Available Configurations

1. **release-all.yml**: Complete build matrix (Linux glibc, musl, Alpine wolfSSL, FreeBSD)
2. **release-linux.yml**: Linux variants only (glibc dynamic+TLS, musl static)
3. **release-alpine.yml**: Alpine musl+wolfSSL (smallest build)
4. **release-bsd.yml**: FreeBSD cross-compiled
5. **release-macos.yml**: macOS native builds (requires macOS system)

### Configuration Structure

```yaml
platforms:
  - name: linux-glibc
    base_image: ubuntu:22.04
    dockerfile: Dockerfile.linux-glibc
    architectures: [amd64, arm64]
    zig_target_map:
      amd64: x86_64-linux-gnu
      arm64: aarch64-linux-gnu
    build_options:
      - "-Doptimize=ReleaseSmall"
      - "-Dstrip=true"
      - "-Dtls=true"
      - "-Dtls-backend=openssl"
    artifact_suffix: "glibc-openssl"
```

### Customizing Builds

To create a custom release configuration:

1. Copy an existing config: `cp docker-tests/configs/releases/release-linux.yml docker-tests/configs/releases/my-custom.yml`
2. Modify platforms, architectures, or build options
3. Run with custom config: `./docker-tests/scripts/build-release.sh --config docker-tests/configs/releases/my-custom.yml`

## Artifact Structure

Release artifacts are organized by version:

```
docker-tests/artifacts/releases/
└── v0.1.0/
    ├── zigcat-v0.1.0-linux-x64-glibc-openssl.tar.gz
    ├── zigcat-v0.1.0-linux-x64-musl-static.tar.gz
    ├── zigcat-v0.1.0-linux-arm64-glibc-openssl.tar.gz
    ├── zigcat-v0.1.0-linux-arm64-musl-static.tar.gz
    ├── zigcat-v0.1.0-linux-x86-musl-static.tar.gz
    ├── zigcat-v0.1.0-linux-arm-musl-static.tar.gz
    ├── zigcat-v0.1.0-alpine-x64-musl-wolfssl-static.tar.gz
    ├── zigcat-v0.1.0-alpine-arm64-musl-wolfssl-static.tar.gz
    ├── zigcat-v0.1.0-freebsd-x64.tar.gz
    ├── SHA256SUMS
    └── RELEASE_NOTES.md
```

### Artifact Naming Convention

```
zigcat-{version}-{platform}-{arch}-{variant}.tar.gz

Examples:
- zigcat-v0.1.0-linux-x64-glibc-openssl.tar.gz
- zigcat-v0.1.0-alpine-x64-musl-wolfssl-static.tar.gz
- zigcat-v0.1.0-freebsd-x64.tar.gz
```

### Tarball Contents

Each tarball contains:
- `zigcat` (or `zigcat-wolfssl` for wolfSSL builds): The binary
- `LICENSE`: Project license
- `README.md`: Project README
- `CHANGELOG.md`: (if available)

## Advanced Usage

### Parallel Builds

Enable parallel builds for faster compilation:

```bash
# Using Makefile (parallel enabled by default)
make release-all

# Using script directly
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-all.yml \
  --parallel
```

### Specifying Version

By default, version is auto-detected from `build.zig`. To override:

```bash
./docker-tests/scripts/build-release.sh \
  --version v0.2.0-beta \
  --config docker-tests/configs/releases/release-all.yml
```

### Skipping Phases

```bash
# Skip build, only package existing artifacts
./docker-tests/scripts/build-release.sh \
  --skip-build \
  --config docker-tests/configs/releases/release-all.yml

# Build only, skip packaging
./docker-tests/scripts/build-release.sh \
  --skip-package \
  --config docker-tests/configs/releases/release-all.yml
```

### GPG Signing Checksums

```bash
# Generate and sign checksums
./docker-tests/scripts/generate-checksums.sh \
  --release-dir docker-tests/artifacts/releases/v0.1.0 \
  --sign \
  --gpg-key YOUR_GPG_KEY_ID
```

### Validation

Validate all built binaries with smoke tests:

```bash
# Via Makefile
make release-validate

# Via script
./docker-tests/scripts/validate-releases.sh \
  --artifacts-dir docker-tests/artifacts \
  --verbose
```

## Platform-Specific Notes

### Linux Builds

**Linux glibc (dynamic with OpenSSL TLS)**:
- Built in Ubuntu 22.04 container
- Requires `libssl3` at runtime
- Best for modern Linux distributions (Ubuntu 22.04+, Debian 12+, Fedora 36+)

**Linux musl (static NO TLS)**:
- Built in Alpine 3.18 container
- Zero dependencies, runs anywhere
- Perfect for containers, embedded systems, old distros
- **Trade-off**: No TLS support for maximum portability

### Alpine Builds (Smallest with TLS)

**Alpine musl + wolfSSL**:
- Fully static binary with TLS support
- **Only ~835KB** on x64 (66% smaller than target!)
- Uses wolfSSL (licensed under GPLv2)
- Built in Alpine 3.18 with custom seccomp profile

**Important**: Binaries built with wolfSSL are subject to GPLv2 license terms.

**Docker Build Requirements**:
- Docker Engine 20.10.6+ OR custom seccomp profile
- Uses `--security-opt seccomp=docker-tests/seccomp/zig-builder.json`
- See `docker-tests/DOCKER_BUILD_ERRORS.md` for troubleshooting

### FreeBSD Builds

**FreeBSD (cross-compiled from Linux)**:
- Built in Ubuntu 22.04 container using Zig cross-compilation
- **NO TLS** support (cross-compile limitation)
- For TLS on FreeBSD, build natively:
  ```bash
  # On FreeBSD system
  pkg install zig openssl
  zig build -Doptimize=ReleaseSmall -Dtls=true -Dstrip=true
  ```

**OpenBSD / NetBSD**:
- Not supported in Docker builds (Zig cross-compilation limitations)
- Must build natively on those platforms

### macOS Builds

**macOS requires native builds** (not Docker):

```bash
# Prerequisites (on macOS)
brew install zig openssl

# Build via Makefile
make release-macos

# Or via script
./docker-tests/scripts/build-release.sh \
  --config docker-tests/configs/releases/release-macos.yml \
  --native
```

**Why native-only?**
- macOS SDK cannot be legally redistributed in Docker images
- osxcross setup is fragile and error-prone
- Apple Silicon requires native ARM64 macOS system

## Troubleshooting

### Docker Build Failures

**Error**: `errno 38 (ENOSYS)` or `unable to access options file`

**Cause**: Docker seccomp profile blocking `faccessat2` syscall (Zig 0.15.1 requirement)

**Solution**: Use custom seccomp profile:
```bash
docker build --security-opt seccomp=docker-tests/seccomp/zig-builder.json ...
```

See `docker-tests/DOCKER_BUILD_ERRORS.md` for detailed troubleshooting.

### Version Detection Issues

**Error**: `Could not auto-detect version from build.zig`

**Solution**: Specify version manually:
```bash
./docker-tests/scripts/build-release.sh --version v0.1.0 ...
```

### Missing Dependencies

**Error**: `Missing required tools: yq`

**Solution**: Install missing tools:
```bash
# macOS
brew install yq

# Ubuntu/Debian
apt install yq
```

### macOS Build Fails

**Error**: `ERROR: macOS builds must be run on native macOS system`

**Solution**: Run on a macOS machine, not in Docker/Linux.

### Checksum Generation Fails

**Error**: `No tarballs found in release directory`

**Solution**: Run packaging first:
```bash
make release-package
# Then
make release-checksums
```

## Best Practices

1. **Always validate builds**: Run `make release-validate` before distribution
2. **Generate checksums**: Always create SHA256SUMS for user verification
3. **Document variants**: Update RELEASE_NOTES.md with build details
4. **Test on target**: Verify binaries work on actual target systems
5. **Version consistently**: Use semantic versioning (vX.Y.Z)
6. **License compliance**: Note wolfSSL builds are GPLv2-licensed

## Complete Release Workflow

Here's a complete workflow for creating a release:

```bash
# 1. Ensure version is updated in build.zig
vim build.zig  # Update version constant

# 2. Build all release artifacts
make release-all

# 3. Validate all binaries
make release-validate

# 4. Generate checksums
make release-checksums

# 5. Review artifacts
ls -lh docker-tests/artifacts/releases/v*/

# 6. Test on target systems (manual)
# Copy artifacts to test systems and verify

# 7. Create GitHub release
# Upload artifacts from docker-tests/artifacts/releases/v*/
# Include SHA256SUMS and RELEASE_NOTES.md

# 8. Clean up (optional)
# make release-clean
```

## GitHub Release Upload

After building, upload artifacts to GitHub:

```bash
# Using GitHub CLI
cd docker-tests/artifacts/releases/v0.1.0
gh release create v0.1.0 \
  --title "ZigCat v0.1.0" \
  --notes-file RELEASE_NOTES.md \
  zigcat-*.tar.gz \
  SHA256SUMS
```

## Support

For issues or questions:
- Check `docker-tests/DOCKER_BUILD_ERRORS.md` for build errors
- See `BUILD.md` for general build information
- Report issues: https://github.com/anthropics/zigcat/issues

---

**Last Updated**: 2025-01-15
