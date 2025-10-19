# ZigCat Release Guide

Complete guide for creating and managing ZigCat releases, from development builds to production packages and GitHub releases.

## Quick Navigation

**Which workflow is right for you?**

- 🚀 **Creating a GitHub Release?** → [Automated Release Workflow](#automated-release-workflow)
- 🔧 **Building Release Locally?** → [Manual Local Release](#manual-local-release)
- 💻 **Just Developing?** → See [BUILD.md](../BUILD.md)
- 🤖 **CI/CD Integration?** → [GitHub Actions Reference](#github-actions-reference)

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Workflow Comparison](#workflow-comparison)
3. [Automated Release Workflow](#automated-release-workflow) (Recommended for maintainers)
4. [Manual Local Release](#manual-local-release) (v0.0.1+ system)
5. [Build Matrix & Artifacts](#build-matrix--artifacts)
6. [Versioning & Tagging](#versioning--tagging)
7. [Packaging](#packaging)
8. [Validation & Checksums](#validation--checksums)
9. [GitHub Release Upload](#github-release-upload)
10. [Troubleshooting](#troubleshooting)
11. [Appendix](#appendix)

## Prerequisites

### For All Workflows

- **Git** with commit access to repository
- **Zig 0.15.1** (exact version required for ArrayList API compatibility)

### For Automated Release (GitHub Actions)

- **GitHub CLI** (optional): `gh` command for manual workflow dispatch
- **prepare-release.sh** script (included in repo)

### For Manual Local Release

- **Docker** 20.10+ for cross-platform builds
- **Make** for convenient build targets
- **dpkg-deb** (optional): For .deb package creation
- **rpmbuild** (optional): For .rpm package creation
- **pigz** (optional): For faster gzip compression

### For TLS-Enabled Builds

- **OpenSSL 3.x** development libraries
  - macOS: `brew install openssl@3`
  - Ubuntu/Debian: `sudo apt install libssl-dev`
  - Fedora/RHEL: `sudo dnf install openssl-devel`

## Workflow Comparison

| Workflow | Best For | Prerequisites | Time | Output |
|----------|----------|---------------|------|--------|
| **Automated Release** | Maintainers creating GitHub releases | Git, prepare-release.sh | 15-20 min | GitHub Release with all platforms |
| **Manual Local** | Testing release builds, custom packages | Docker, build scripts | 30-45 min | Tarballs + .deb + .rpm locally |
| **Development** | Day-to-day coding | Zig only | 1-2 min | Local binary |

## Automated Release Workflow

**Best for:** Maintainers creating official GitHub releases via CI/CD

This workflow uses GitHub Actions to automatically build binaries for all platforms, create packages, and publish a GitHub Release.

### Step 1: Update Version

Edit `build.zig` (line ~273) and update the version:

```zig
options.addOption([]const u8, "version", "X.Y.Z");
```

**Version format:** `X.Y.Z` (without 'v' prefix)

Example:
```zig
options.addOption([]const u8, "version", "0.0.2");
```

**Also update:**
- `debian/changelog` - Add new entry for version
- `packaging/rpm/zigcat.spec` - Update version field

### Step 2: Commit Version Changes

```bash
git add build.zig debian/changelog packaging/rpm/zigcat.spec
git commit -m "chore: bump version to X.Y.Z"
git push origin main
```

### Step 3: Run Automated Release Script

```bash
./scripts/prepare-release.sh vX.Y.Z
```

This script will:
1. ✅ Validate version in `build.zig` matches tag
2. ✅ Verify git working directory is clean
3. ✅ Run full test suite
4. ✅ Create git tag
5. ✅ Push tag to trigger GitHub Actions

**Example:**
```bash
./scripts/prepare-release.sh v0.0.2
```

### Step 4: Monitor GitHub Actions

Once the tag is pushed, GitHub Actions automatically:
- Builds binaries for all platforms
- Generates SHA256 checksums
- Creates GitHub Release with artifacts
- Auto-generates changelog from commits

**Monitor progress:**
- Actions: `https://github.com/whit3rabbit/zigcat/actions`
- Releases: `https://github.com/whit3rabbit/zigcat/releases`

**Build time:** ~10-15 minutes for all platforms

### Step 5: Verify Release

After release is created, verify artifacts:

```bash
# Download and check
curl -LO https://github.com/whit3rabbit/zigcat/releases/download/vX.Y.Z/zigcat-linux-x64
curl -LO https://github.com/whit3rabbit/zigcat/releases/download/vX.Y.Z/SHA256SUMS

# Verify checksum
grep zigcat-linux-x64 SHA256SUMS | sha256sum -c

# Test binary
chmod +x zigcat-linux-x64
./zigcat-linux-x64 --version
```

## Manual Local Release

**Best for:** Building releases locally without CI/CD, creating custom packages, testing build process

This is the v0.0.1+ manual build system using `build-release-v2.sh` and packaging scripts.

### Quick Start

**One-command complete build:**

```bash
make release-v0.0.1
```

This runs all steps automatically: build → package → checksums → validate

### Step-by-Step Process

#### 1. Clean Previous Builds (Optional)

```bash
make release-clean
```

#### 2. Update Version

Same as automated workflow - update `build.zig`, `debian/changelog`, `packaging/rpm/zigcat.spec`

#### 3. Build All Binaries

```bash
# Option A: Makefile
make release-build

# Option B: Direct script call
./docker-tests/scripts/build-release-v2.sh --version v0.0.1 --continue-on-error --verbose
```

**What happens:**
- Docker builds each platform sequentially
- Binaries extracted to `docker-tests/artifacts/{platform}-{arch}/zigcat`
- Logs saved to `docker-tests/logs/build-{platform}-{arch}.log`
- Build report: `docker-tests/artifacts/BUILD_REPORT.md`

**Duration:** 15-30 minutes

**Platforms built:**
- Linux x64 glibc+OpenSSL (dynamic, ~6MB)
- Linux ARM64 glibc+OpenSSL (dynamic, ~6MB)
- Linux x64 musl static (no TLS, ~2MB)
- Linux ARM64 musl static (no TLS, ~2MB)
- Alpine x64 musl+wolfSSL (static, ~835KB)
- Alpine ARM64 musl+wolfSSL (static, ~865KB)
- FreeBSD x64 (~300KB)

#### 4. Package Artifacts

```bash
# Option A: Tarballs + deb + rpm
make release-package

# Option B: Tarballs only
make release-tarballs

# Option C: Direct script
./docker-tests/scripts/package-release.sh \
    --version v0.0.1 \
    --compression 9 \
    --create-deb \
    --create-rpm \
    --verbose
```

**What happens:**
- Tarballs created with gzip -9 (maximum compression)
- .deb packages for Linux variants (OpenSSL, static, wolfSSL)
- .rpm packages for Linux variants
- Output: `docker-tests/artifacts/releases/v0.0.1/{tarballs,deb,rpm}/`

**Duration:** 5-10 minutes

#### 5. Generate Checksums

```bash
make release-checksums
```

**Output:** `docker-tests/artifacts/releases/v0.0.1/SHA256SUMS`

#### 6. Validate Binaries

```bash
make release-validate
```

Runs smoke tests: executable permissions, static/dynamic linking checks

#### 7. Review Summary

```bash
make release-summary
```

Shows all created artifacts with sizes.

### Platform-Specific Notes

**macOS (ARM64):**
- ✅ Can build: Linux ARM64, Alpine ARM64, FreeBSD x64
- ⚠️ May fail: Linux x64 (Docker emulation)
- Uses continue-on-error mode by default

**macOS (Intel):**
- ✅ Can build: Linux x64, FreeBSD x64
- ⚠️ May fail: ARM64 builds (Docker emulation)

**Linux x64:**
- ✅ Can build all platforms (best compatibility)

## Build Matrix & Artifacts

### Platform Matrix

| Platform | Arch | TLS Backend | Type | Size | Use Case | Filename Pattern |
|----------|------|-------------|------|------|----------|------------------|
| Linux glibc | x64 | OpenSSL | Dynamic | ~6MB | Modern distros with TLS | `zigcat-v{ver}-linux-x64-glibc-openssl-dynamic.tar.gz` |
| Linux glibc | ARM64 | OpenSSL | Dynamic | ~6MB | ARM servers with TLS | `zigcat-v{ver}-linux-arm64-glibc-openssl-dynamic.tar.gz` |
| Linux musl | x64 | None | Static | ~2MB | Containers, portability | `zigcat-v{ver}-linux-x64-musl-static.tar.gz` |
| Linux musl | ARM64 | None | Static | ~2MB | ARM embedded, portable | `zigcat-v{ver}-linux-arm64-musl-static.tar.gz` |
| Alpine musl | x64 | wolfSSL | Static | ~835KB | **Smallest with TLS** (GPLv2) | `zigcat-v{ver}-alpine-x64-musl-wolfssl-static.tar.gz` |
| Alpine musl | ARM64 | wolfSSL | Static | ~865KB | **Smallest ARM+TLS** (GPLv2) | `zigcat-v{ver}-alpine-arm64-musl-wolfssl-static.tar.gz` |
| FreeBSD | x64 | None | Dynamic | ~300KB | FreeBSD systems | `zigcat-v{ver}-freebsd-x64.tar.gz` |

### Artifact Directory Structure

```
docker-tests/artifacts/releases/v0.0.1/
├── tarballs/
│   ├── zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz
│   ├── zigcat-v0.0.1-linux-arm64-glibc-openssl-dynamic.tar.gz
│   ├── zigcat-v0.0.1-linux-x64-musl-static.tar.gz
│   ├── zigcat-v0.0.1-linux-arm64-musl-static.tar.gz
│   ├── zigcat-v0.0.1-alpine-x64-musl-wolfssl-static.tar.gz
│   ├── zigcat-v0.0.1-alpine-arm64-musl-wolfssl-static.tar.gz
│   └── zigcat-v0.0.1-freebsd-x64.tar.gz
├── deb/
│   ├── zigcat_0.0.1-1_amd64.deb           # Default OpenSSL
│   ├── zigcat_0.0.1-1_arm64.deb
│   ├── zigcat-static_0.0.1-1_amd64.deb    # Musl static
│   └── zigcat-wolfssl_0.0.1-1_amd64.deb   # wolfSSL (GPLv2)
├── rpm/
│   ├── zigcat-0.0.1-1.x86_64.rpm
│   ├── zigcat-0.0.1-1.aarch64.rpm
│   ├── zigcat-static-0.0.1-1.x86_64.rpm
│   └── zigcat-wolfssl-0.0.1-1.x86_64.rpm
├── SHA256SUMS
├── BUILD_REPORT.md
└── RELEASE_NOTES.md
```

### Tarball Contents

Each tarball contains:
```
zigcat-v{version}-{platform}-{arch}-{suffix}/
├── zigcat                    # Binary
├── LICENSE                   # MIT license
├── README.md                 # Project README
└── RELEASE_NOTES_v{ver}.md   # Release notes
```

### Package Variants

**zigcat (default):**
- OpenSSL-enabled dynamic binary
- Full TLS/DTLS support
- GSocket NAT traversal
- **Requires:** libssl3 (>= 3.0.0)
- **License:** MIT

**zigcat-static:**
- Musl static binary
- **No TLS support** (for maximum portability)
- Zero runtime dependencies
- Portable to any Linux (same arch)
- **License:** MIT

**zigcat-wolfssl:**
- wolfSSL static binary
- TLS 1.2/1.3 support (no DTLS yet)
- Zero runtime dependencies
- **License:** GPLv2 (due to wolfSSL)

## Versioning & Tagging

ZigCat follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** (X.0.0): Incompatible API changes
- **MINOR** (0.X.0): New features, backward compatible
- **PATCH** (0.0.X): Bug fixes, backward compatible

### Examples

- **v0.1.0** → **v0.2.0**: Added new `-X` flag for proxy chaining
- **v0.2.0** → **v0.2.1**: Fixed timeout handling bug
- **v0.2.1** → **v1.0.0**: Removed deprecated `-L` flag (breaking change)

### Version Update Locations

When bumping version, update ALL of these:

1. **build.zig** (line ~273):
   ```zig
   options.addOption([]const u8, "version", "X.Y.Z");
   ```

2. **debian/changelog** (add new entry at top):
   ```
   zigcat (X.Y.Z-1) unstable; urgency=medium

     * Release vX.Y.Z
     * Feature descriptions here

    -- Whit3Rabbit <whiterabbit@protonmail.com>  DATE
   ```

3. **packaging/rpm/zigcat.spec** (lines 2 and changelog):
   ```spec
   Version:        X.Y.Z
   ...
   %changelog
   * DATE Whit3Rabbit <whiterabbit@protonmail.com> - X.Y.Z-1
   - Release vX.Y.Z
   ```

### Git Tag Format

- **Format:** `vX.Y.Z` (with 'v' prefix)
- **Type:** Annotated tags (not lightweight)
- **Message:** Include release summary

**Example:**
```bash
git tag -a v0.0.2 -m "Release v0.0.2

- Fix timeout handling bug
- Add support for SOCKS5 UDP
- Improve error messages
"
git push origin v0.0.2
```

## Packaging

### Tarball Creation

Tarballs use **gzip -9** (maximum compression) for smallest size.

**Manual creation:**
```bash
# Create package directory
mkdir -p zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic
cp binary zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic/zigcat
cp LICENSE README.md RELEASE_NOTES_v0.0.1.md zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic/

# Create tarball with max compression
GZIP=-9 tar -czf zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic.tar.gz \
    zigcat-v0.0.1-linux-x64-glibc-openssl-dynamic
```

**Faster with pigz (parallel gzip):**
```bash
tar -cf - directory | pigz -9 > output.tar.gz
```

### Debian Packages (.deb)

**Automated:**
```bash
./docker-tests/scripts/build-deb-packages.sh \
    --version v0.0.1 \
    --artifacts-dir docker-tests/artifacts \
    --output-dir docker-tests/artifacts/releases/v0.0.1/deb
```

**Package structure:**
- `zigcat` - Default OpenSSL variant (depends on libssl3)
- `zigcat-static` - Static variant (no dependencies)
- `zigcat-wolfssl` - wolfSSL variant (no dependencies, GPLv2)

**Install:**
```bash
sudo dpkg -i zigcat_0.0.1-1_amd64.deb
```

### RPM Packages (.rpm)

**Automated:**
```bash
./docker-tests/scripts/build-rpm-packages.sh \
    --version v0.0.1 \
    --artifacts-dir docker-tests/artifacts \
    --output-dir docker-tests/artifacts/releases/v0.0.1/rpm
```

**Install:**
```bash
sudo rpm -i zigcat-0.0.1-1.x86_64.rpm
```

## Validation & Checksums

### Generate Checksums

```bash
# Automated
make release-checksums

# Manual
cd docker-tests/artifacts/releases/v0.0.1
sha256sum tarballs/*.tar.gz deb/*.deb rpm/*.rpm > SHA256SUMS
```

### Verify Checksums

```bash
cd docker-tests/artifacts/releases/v0.0.1
sha256sum -c SHA256SUMS
```

### Binary Validation

**Automated:**
```bash
make release-validate
```

**Manual checks:**
```bash
# Check executable
chmod +x zigcat-linux-x64
./zigcat-linux-x64 --version

# Verify static linking
ldd zigcat-linux-x64-static
# Should show: "not a dynamic executable"

# Verify TLS support (dynamic builds)
./zigcat-linux-x64 --version-all | grep -i tls
# Should show: "TLS Support: Enabled"

# Check binary size
ls -lh zigcat-*
```

## GitHub Release Upload

### Using GitHub CLI (Recommended)

```bash
# 1. Create release
gh release create v0.0.1 \
    --title "ZigCat v0.0.1 - Initial Release" \
    --notes-file RELEASE_NOTES_v0.0.1.md

# 2. Upload tarballs
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/tarballs/*.tar.gz

# 3. Upload packages (optional)
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/deb/*.deb
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/rpm/*.rpm

# 4. Upload checksums
gh release upload v0.0.1 docker-tests/artifacts/releases/v0.0.1/SHA256SUMS
```

### Using GitHub Web UI

1. Go to: `https://github.com/whit3rabbit/zigcat/releases/new`
2. Choose tag: `v0.0.1`
3. Enter title and description
4. Drag and drop artifacts
5. Click "Publish release"

## Troubleshooting

### Version Mismatch Error

**Error:** `Version mismatch! build.zig: 0.1.0, Requested: 0.2.0`

**Solution:** Update version in `build.zig` (line ~273)

### Tag Already Exists

**Error:** `Tag v0.1.0 already exists!`

**Solution:**
```bash
# Delete locally and remotely
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0
```

### Docker Daemon Not Running

**Error:** `Docker daemon is not running`

**Solution:**
```bash
# macOS
open -a Docker

# Linux
sudo systemctl start docker
```

### ARM64 Builds Failing on macOS

**Symptom:** Linux x64 or Alpine x64 fail on ARM64 Mac

**Cause:** Docker platform emulation limitations

**Solution:** Expected behavior. Build continues with continue-on-error mode. Check `BUILD_REPORT.md`.

### Permission Denied on Docker

**Solution:**
```bash
# Add user to docker group (Linux)
sudo usermod -aG docker $USER
newgrp docker
```

### Build Timeout

**Solution:** Increase timeout:
```bash
./docker-tests/scripts/build-release-v2.sh --version v0.0.1 --timeout 1200
```

### No .deb/.rpm Created

**Cause:** `dpkg-deb` or `rpmbuild` not installed

**Solution:**
```bash
# Debian/Ubuntu
sudo apt install dpkg-dev rpm

# macOS
brew install rpm
# Note: .deb requires Linux
```

### Compression Too Slow

**Solution:** Install pigz for parallel compression:
```bash
# macOS
brew install pigz

# Linux
sudo apt install pigz
```

## Appendix

### A. Release Checklist

**Before releasing:**
- [ ] Version updated in build.zig
- [ ] debian/changelog updated
- [ ] packaging/rpm/zigcat.spec updated
- [ ] All tests pass: `zig build test`
- [ ] Feature tests pass: `zig build test-timeout`, `test-udp`, etc.
- [ ] Git working directory clean
- [ ] Changelog reviewed
- [ ] Version follows SemVer

**After releasing:**
- [ ] GitHub Release created
- [ ] All expected artifacts present
- [ ] SHA256SUMS generated
- [ ] Binaries verified on at least one platform
- [ ] Static builds verified (no dependencies)
- [ ] TLS support verified (dynamic builds)

### B. GitHub Actions Reference

**Workflow file:** `.github/workflows/release.yml`

**Trigger:**
- Automatically on git tag push: `git push origin v*`
- Manually via GitHub UI or `gh` CLI

**Manual trigger:**
```bash
gh workflow run release.yml -f tag=v0.0.2
```

**Build matrix:**
- 15+ platform/architecture combinations
- Parallel builds for speed
- Artifact upload to GitHub Releases

### C. Manual Single-Platform Build

**Example: Linux x64 with OpenSSL**

```bash
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

### D. Legacy Docker Build System (Deprecated)

**Old system** using `release-all.yml` configs and `build-release.sh`:

```bash
# DO NOT USE for new releases
./docker-tests/scripts/build-release.sh \
    --config docker-tests/configs/releases/release-all.yml
```

**Use instead:** `build-release-v2.sh` (v0.0.1+ system)

### E. Binary Size Expectations

| Build Type | x64 Size | ARM64 Size | Notes |
|------------|----------|------------|-------|
| Linux glibc+OpenSSL (dynamic) | ~6.0 MB | ~6.0 MB | Requires libssl |
| Linux musl static (no TLS) | ~2.0 MB | ~2.0 MB | Zero dependencies |
| Alpine musl+wolfSSL (static) | ~835 KB | ~865 KB | **Smallest with TLS** |
| FreeBSD (dynamic) | ~300 KB | N/A | Cross-compiled |

## Support

- **Issues:** https://github.com/whit3rabbit/zigcat/issues
- **Documentation:** See `docs/` directory
- **Build Guide:** [BUILD.md](../BUILD.md)
- **Build Logs:** `docker-tests/logs/`
- **Build Report:** `docker-tests/artifacts/BUILD_REPORT.md`

---

**Last Updated:** October 19, 2025
**Version:** v0.0.1
**Maintainer:** Whit3Rabbit <whiterabbit@protonmail.com>
