# ZigCat Release Build Guide

Complete guide for building v0.0.1 release packages with tarballs, .deb, and .rpm files.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Prerequisites](#prerequisites)
3. [Build System Overview](#build-system-overview)
4. [Step-by-Step Guide](#step-by-step-guide)
5. [Build Artifacts](#build-artifacts)
6. [Troubleshooting](#troubleshooting)
7. [Manual Build Process](#manual-build-process)

## Quick Start

**One-command complete build:**

```bash
make release-v0.0.1
```

This will:
1. Build all platform binaries (Linux x64/ARM64, Alpine, FreeBSD)
2. Create tarballs with gzip -9 compression
3. Generate .deb and .rpm packages
4. Create SHA256SUMS
5. Validate binaries

**Estimated time:** 25-45 minutes (depending on system)

## Prerequisites

### Required Software

```bash
# Docker (for cross-platform builds)
docker --version  # Should be 20.10+

# Make
make --version

# Optional: For package creation
dpkg-deb --version   # For .deb packages
rpmbuild --version   # For .rpm packages
```

### System Requirements

- **OS**: macOS (ARM64 recommended) or Linux
- **RAM**: 8GB minimum, 16GB recommended
- **Disk**: 10GB free space
- **Docker**: Running and accessible

### Platform-Specific Notes

**macOS (ARM64):**
- ✅ Can build: Linux ARM64 (native), Alpine ARM64, FreeBSD x64
- ⚠️ May fail: Linux x64 (Docker platform emulation)
- 💡 Tip: Use continue-on-error mode (default)

**macOS (Intel):**
- ✅ Can build: Linux x64, FreeBSD x64
- ⚠️ May fail: ARM64 builds (Docker platform emulation)

**Linux x64:**
- ✅ Can build all platforms (best compatibility)

## Build System Overview

### Architecture

```
make release-v0.0.1
    ↓
build-release-v2.sh (builds all binaries)
    ↓
package-release.sh (creates tarballs/deb/rpm)
    ├─ build-deb-packages.sh
    └─ build-rpm-packages.sh
    ↓
generate-checksums.sh (SHA256SUMS)
    ↓
validate-releases.sh (smoke tests)
```

### Build Matrix

| Platform | Arch | TLS Backend | Type | Size | Output Name |
|----------|------|-------------|------|------|-------------|
| Linux glibc | x64 | OpenSSL | Dynamic | ~6MB | `zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz` |
| Linux glibc | ARM64 | OpenSSL | Dynamic | ~6MB | `zigcat-v0.0.1-linux-arm64-glibc-openssl-dynamic.tar.gz` |
| Linux musl | x64 | None | Static | ~2MB | `zigcat-v0.0.1-linux-x64-musl-static.tar.gz` |
| Linux musl | ARM64 | None | Static | ~2MB | `zigcat-v0.0.1-linux-arm64-musl-static.tar.gz` |
| Alpine musl | x64 | wolfSSL | Static | ~835KB | `zigcat-v0.0.1-alpine-x64-musl-wolfssl-static.tar.gz` |
| Alpine musl | ARM64 | wolfSSL | Static | ~865KB | `zigcat-v0.0.1-alpine-arm64-musl-wolfssl-static.tar.gz` |
| FreeBSD | x64 | None | Dynamic | ~300KB | `zigcat-v0.0.1-freebsd-x64.tar.gz` |

### Continue-on-Error Mode

The build system uses **continue-on-error by default**:
- Each platform builds independently
- Failures don't stop the entire build
- Final report shows: ✅ successful, ❌ failed
- Exit code 0 if at least one build succeeds

## Step-by-Step Guide

### Step 1: Clean Previous Builds (Optional)

```bash
make release-clean
```

### Step 2: Build All Binaries

```bash
# Option A: Use Makefile (recommended)
make release-build

# Option B: Direct script call
./docker-tests/scripts/build-release-v2.sh --version v0.0.1 --continue-on-error --verbose
```

**What happens:**
- Docker builds each platform sequentially
- Binaries extracted to `docker-tests/artifacts/{platform}-{arch}/zigcat`
- Logs saved to `docker-tests/logs/build-{platform}-{arch}.log`
- Build report generated at `docker-tests/artifacts/BUILD_REPORT.md`

**Duration:** 15-30 minutes

### Step 3: Package Artifacts

```bash
# Option A: Use Makefile (tarballs + deb + rpm)
make release-package

# Option B: Tarballs only
make release-tarballs

# Option C: Direct script call
./docker-tests/scripts/package-release.sh \
    --version v0.0.1 \
    --compression 9 \
    --create-deb \
    --create-rpm \
    --verbose
```

**What happens:**
- Tarballs created with gzip -9 (maximum compression)
- .deb packages created for all Linux variants
- .rpm packages created for all Linux variants
- Outputs to `docker-tests/artifacts/releases/v0.0.1/{tarballs,deb,rpm}/`

**Duration:** 5-10 minutes

### Step 4: Generate Checksums

```bash
make release-checksums
```

**What happens:**
- SHA256SUMS file created
- Includes all tarballs, .deb, and .rpm files
- Output: `docker-tests/artifacts/releases/v0.0.1/SHA256SUMS`

**Duration:** <1 minute

### Step 5: Validate Binaries

```bash
make release-validate
```

**What happens:**
- Basic smoke tests on binaries
- Verifies executable permissions
- Checks static/dynamic linking
- Reports any issues

**Duration:** 2-5 minutes

### Step 6: Review Build Summary

```bash
make release-summary
```

**Output example:**
```
Release Summary:
================

Tarballs:
  2.3M  zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz
  865K  zigcat-v0.0.1-alpine-arm64-musl-wolfssl-static.tar.gz
  300K  zigcat-v0.0.1-freebsd-x64.tar.gz

Debian Packages:
  2.5M  zigcat_0.0.1-1_amd64.deb
  900K  zigcat-static_0.0.1-1_amd64.deb

RPM Packages:
  2.4M  zigcat-0.0.1-1.x86_64.rpm
  890K  zigcat-static-0.0.1-1.x86_64.rpm
```

## Build Artifacts

### Directory Structure

```
docker-tests/artifacts/
├── linux-amd64/zigcat           # Build artifacts (one per platform)
├── linux-arm64/zigcat
├── alpine-amd64/zigcat
├── alpine-arm64/zigcat
├── freebsd-amd64/zigcat
├── releases/
│   └── v0.0.1/
│       ├── tarballs/
│       │   ├── zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz
│       │   ├── zigcat-v0.0.1-linux-arm64-glibc-openssl-dynamic.tar.gz
│       │   ├── zigcat-v0.0.1-linux-x64-musl-static.tar.gz
│       │   ├── zigcat-v0.0.1-linux-arm64-musl-static.tar.gz
│       │   ├── zigcat-v0.0.1-alpine-x64-musl-wolfssl-static.tar.gz
│       │   ├── zigcat-v0.0.1-alpine-arm64-musl-wolfssl-static.tar.gz
│       │   └── zigcat-v0.0.1-freebsd-x64.tar.gz
│       ├── deb/
│       │   ├── zigcat_0.0.1-1_amd64.deb
│       │   ├── zigcat_0.0.1-1_arm64.deb
│       │   ├── zigcat-static_0.0.1-1_amd64.deb
│       │   └── zigcat-wolfssl_0.0.1-1_amd64.deb
│       ├── rpm/
│       │   ├── zigcat-0.0.1-1.x86_64.rpm
│       │   ├── zigcat-0.0.1-1.aarch64.rpm
│       │   ├── zigcat-static-0.0.1-1.x86_64.rpm
│       │   └── zigcat-wolfssl-0.0.1-1.x86_64.rpm
│       ├── SHA256SUMS
│       ├── BUILD_REPORT.md
│       └── RELEASE_NOTES.md
└── logs/
    ├── build-linux-x64-openssl.log
    ├── build-linux-arm64-openssl.log
    ├── build-alpine-x64-wolfssl.log
    └── ...
```

### Tarball Contents

Each tarball includes:
```
zigcat-v0.0.1-{platform}-{arch}-{suffix}/
├── zigcat           # Binary
├── LICENSE          # MIT license
├── README.md        # Project README
└── RELEASE_NOTES_v0.0.1.md  # Release notes
```

### Package Variants

**zigcat (default):**
- OpenSSL-enabled dynamic binary
- TLS/DTLS support
- GSocket NAT traversal
- Requires: libssl3 (>= 3.0.0)

**zigcat-static:**
- Musl static binary
- No TLS support
- Zero dependencies
- Portable to any Linux

**zigcat-wolfssl:**
- wolfSSL static binary
- TLS support (no DTLS)
- GPLv2 license
- Zero dependencies

## Troubleshooting

### ARM64 Builds Failing on macOS

**Symptom:** Linux x64 or Alpine x64 builds fail on ARM64 Mac

**Cause:** Docker platform emulation limitations

**Solution:** This is expected. The build will continue and skip failed platforms.

```bash
# Check build report
cat docker-tests/artifacts/BUILD_REPORT.md
```

### Docker Daemon Not Running

**Symptom:**
```
[ERROR] Docker daemon is not running
```

**Solution:**
```bash
# macOS: Open Docker Desktop
open -a Docker

# Linux: Start Docker service
sudo systemctl start docker
```

### Permission Denied on Docker

**Symptom:**
```
permission denied while trying to connect to the Docker daemon socket
```

**Solution:**
```bash
# Add user to docker group (Linux)
sudo usermod -aG docker $USER
newgrp docker

# Or use sudo (not recommended for builds)
sudo make release-v0.0.1
```

### Build Timeout

**Symptom:** Build exceeds 600 seconds (10 minutes)

**Solution:** Increase timeout:
```bash
./docker-tests/scripts/build-release-v2.sh --version v0.0.1 --timeout 1200
```

### No .deb/.rpm Packages Created

**Symptom:** Tarballs exist but no packages

**Cause:** `dpkg-deb` or `rpmbuild` not installed

**Solution:**
```bash
# Debian/Ubuntu
sudo apt install dpkg-dev rpm

# macOS
brew install rpm
# Note: .deb creation requires Linux or Docker
```

### Compression Too Slow

**Symptom:** Packaging takes >10 minutes

**Solution:** Use parallel gzip (pigz):
```bash
# macOS
brew install pigz

# Linux
sudo apt install pigz
```

## Manual Build Process

### Building Single Platform

```bash
# Example: Linux x64 with OpenSSL
docker build \
    --platform linux/amd64 \
    --build-arg ZIG_TARGET=x86_64-linux-gnu \
    --build-arg BUILD_OPTIONS="-Dtls=true -Dtls-backend=openssl" \
    -f docker-tests/dockerfiles/Dockerfile.linux \
    -t zigcat-linux-x64:v0.0.1 \
    .

# Extract binary
container_id=$(docker create zigcat-linux-x64:v0.0.1)
docker cp $container_id:/app/zig-out/bin/zigcat ./zigcat-linux-x64
docker rm $container_id
```

### Creating Tarball Manually

```bash
# Create package directory
mkdir -p zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic
cp zigcat-linux-x64 zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic/zigcat
cp LICENSE README.md RELEASE_NOTES_v0.0.1.md zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic/

# Create tarball with max compression
GZIP=-9 tar -czf zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz \
    zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic
```

### Creating .deb Package Manually

```bash
./docker-tests/scripts/build-deb-packages.sh \
    --version v0.0.1 \
    --artifacts-dir docker-tests/artifacts \
    --output-dir docker-tests/artifacts/releases/v0.0.1/deb \
    --verbose
```

### Creating .rpm Package Manually

```bash
./docker-tests/scripts/build-rpm-packages.sh \
    --version v0.0.1 \
    --artifacts-dir docker-tests/artifacts \
    --output-dir docker-tests/artifacts/releases/v0.0.1/rpm \
    --verbose
```

## Uploading to GitHub Releases

After successful build:

```bash
# 1. Create GitHub release
gh release create v0.0.1 \
    --title "ZigCat v0.0.1 - Initial Release" \
    --notes-file RELEASE_NOTES_v0.0.1.md

# 2. Upload all tarballs
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/tarballs/*.tar.gz

# 3. Upload packages (optional)
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/deb/*.deb
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/rpm/*.rpm

# 4. Upload checksums
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/SHA256SUMS
```

## Best Practices

1. **Always run on clean state:**
   ```bash
   make release-clean
   make release-v0.0.1
   ```

2. **Use verbose mode for debugging:**
   ```bash
   ./docker-tests/scripts/build-release-v2.sh --version v0.0.1 --verbose
   ```

3. **Check logs for failed builds:**
   ```bash
   cat docker-tests/logs/build-{failed-platform}.log
   ```

4. **Verify checksums before upload:**
   ```bash
   cd docker-tests/artifacts/releases/v0.0.1
   sha256sum -c SHA256SUMS
   ```

5. **Test binaries on target platforms:**
   - Extract tarball on target system
   - Run `./zigcat --version-all`
   - Test basic connectivity: `./zigcat example.com 80`

## Support

- **Issues:** https://github.com/whit3rabbit/zigcat-github/issues
- **Documentation:** See `docs/` directory
- **Build Logs:** Check `docker-tests/logs/`
- **Build Report:** `docker-tests/artifacts/BUILD_REPORT.md`

---

**Last Updated:** October 19, 2025
**Version:** v0.0.1
**Maintainer:** Whit3Rabbit <whiterabbit@protonmail.com>
