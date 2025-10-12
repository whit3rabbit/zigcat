# Release Guide for Zigcat

This document describes the release process for Zigcat, including version management, testing, and creating GitHub releases.

## Overview

Zigcat uses semantic versioning (SemVer) and automated GitHub Actions workflows to build and publish releases for multiple platforms and architectures.

## Release Artifacts

Each release includes binaries for:

### Linux
- **x86_64 (dynamic)** - `zigcat-linux-x64` - With TLS support
- **x86_64 (static musl)** - `zigcat-linux-x64-static` - Portable, no dependencies, NO TLS
- **aarch64 (dynamic)** - `zigcat-linux-arm64` - With TLS support
- **aarch64 (static musl)** - `zigcat-linux-arm64-static` - Portable, no dependencies, NO TLS
- **x86 32-bit (dynamic)** - `zigcat-linux-x86` - With TLS support
- **x86 32-bit (static musl)** - `zigcat-linux-x86-static` - Portable, no dependencies, NO TLS
- **ARM 32-bit (dynamic)** - `zigcat-linux-arm` - With TLS support
- **ARM 32-bit (static musl)** - `zigcat-linux-arm-static` - Portable, no dependencies, NO TLS

### macOS
- **x86_64 (Intel)** - `zigcat-macos-x64` - With TLS support
- **aarch64 (Apple Silicon)** - `zigcat-macos-arm64` - With TLS support

### Windows
- **x86_64** - `zigcat-windows-x64.exe` - With TLS support
- **x86 32-bit** - `zigcat-windows-x86.exe` - With TLS support

### BSD
- **FreeBSD x86_64** - `zigcat-freebsd-x64` - With TLS support
- **OpenBSD x86_64** - `zigcat-openbsd-x64` - With TLS support
- **NetBSD x86_64** - `zigcat-netbsd-x64` - With TLS support

### Checksums
- **SHA256SUMS** - All checksums in one file
- Individual `.sha256` files for each binary

## Prerequisites

Before creating a release, ensure you have:

1. **Git** configured with commit access to the repository
2. **Zig 0.15.1** installed locally
3. **OpenSSL** development libraries (for local testing)
   - Ubuntu/Debian: `sudo apt-get install libssl-dev pkg-config`
   - macOS: `brew install openssl@3 pkg-config`
4. **GitHub CLI** (optional, for manual workflow dispatch): `gh` command

## Release Process

### 1. Update Version

Edit `build.zig` (around line 231) and update the version:

```zig
options.addOption([]const u8, "version", "X.Y.Z");
```

**Version format:** `X.Y.Z` (without 'v' prefix)

Example:
```zig
options.addOption([]const u8, "version", "0.1.0");
```

### 2. Run Tests Locally

Before creating a release, run the full test suite:

```bash
# Core tests
zig build test

# Feature tests
zig build test-timeout
zig build test-udp
zig build test-zero-io
zig build test-quit-eof
zig build test-platform
zig build test-portscan-features
zig build test-validation
zig build test-ssl

# Or use the prepare-release script (see step 4)
```

### 3. Commit Version Change

Commit the version update to `build.zig`:

```bash
git add build.zig
git commit -m "chore: bump version to X.Y.Z"
git push origin main
```

### 4. Create Release Tag

Use the automated release preparation script:

```bash
./scripts/prepare-release.sh vX.Y.Z
```

This script will:
1. ✅ Validate the version in `build.zig`
2. ✅ Verify git working directory is clean
3. ✅ Run the full test suite
4. ✅ Create a git tag
5. ✅ Push the tag to trigger the release workflow

**Example:**
```bash
./scripts/prepare-release.sh v0.1.0
```

### 5. Monitor Release Build

Once the tag is pushed, GitHub Actions will automatically:

1. Build binaries for all platforms (15 total artifacts)
2. Generate SHA256 checksums for each binary
3. Create a GitHub Release with all artifacts
4. Auto-generate changelog from git commits

**Monitor progress:**
- GitHub Actions: `https://github.com/YOUR_REPO/actions`
- Releases: `https://github.com/YOUR_REPO/releases`

Build time: ~10-15 minutes for all platforms

### 6. Verify Release

After the release is created:

1. **Check artifacts:**
   ```bash
   # Download and verify
   curl -LO https://github.com/YOUR_REPO/releases/download/vX.Y.Z/zigcat-linux-x64
   curl -LO https://github.com/YOUR_REPO/releases/download/vX.Y.Z/SHA256SUMS

   # Verify checksum
   grep zigcat-linux-x64 SHA256SUMS | sha256sum -c
   ```

2. **Test binary:**
   ```bash
   chmod +x zigcat-linux-x64
   ./zigcat-linux-x64 --version
   ./zigcat-linux-x64 --help
   ```

3. **Verify TLS support** (dynamic builds only):
   ```bash
   # Should show TLS support
   ./zigcat-linux-x64 --version-all | grep -i tls
   ```

4. **Verify static builds** (Linux musl):
   ```bash
   # Should show "not a dynamic executable"
   ldd zigcat-linux-x64-static

   # Should be portable (no system dependencies except kernel)
   file zigcat-linux-x64-static
   ```

## Manual Release Workflow

If you need to trigger the release manually (without creating a tag):

### Using GitHub CLI:

```bash
gh workflow run release.yml -f tag=vX.Y.Z
```

### Using GitHub Web UI:

1. Go to: `https://github.com/YOUR_REPO/actions/workflows/release.yml`
2. Click "Run workflow"
3. Enter tag (e.g., `v0.1.0`)
4. Click "Run workflow"

## Versioning Guidelines

Zigcat follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** version (X.0.0): Incompatible API changes
- **MINOR** version (0.X.0): New features, backward compatible
- **PATCH** version (0.0.X): Bug fixes, backward compatible

### Examples:

- **v0.1.0** → **v0.2.0**: Added new `-X` flag for proxy chaining
- **v0.2.0** → **v0.2.1**: Fixed timeout handling bug
- **v0.2.1** → **v1.0.0**: Removed deprecated `-L` flag (breaking change)

## Release Checklist

Before releasing:

- [ ] Version updated in `build.zig`
- [ ] All tests pass locally (`zig build test`)
- [ ] Feature tests pass (`test-timeout`, `test-udp`, etc.)
- [ ] SSL tests pass (`zig build test-ssl`)
- [ ] Platform tests pass (`zig build test-platform`)
- [ ] Git working directory is clean
- [ ] Changelog reviewed (via `git log`)
- [ ] Version follows SemVer guidelines

After releasing:

- [ ] GitHub Release created successfully
- [ ] All 15 platform artifacts present
- [ ] SHA256SUMS file generated
- [ ] Changelog auto-generated
- [ ] Binaries verified (at least one platform)
- [ ] Static builds verified (no dynamic dependencies)
- [ ] TLS support verified (dynamic builds)

## Troubleshooting

### Version Mismatch Error

**Error:** `Version mismatch! build.zig: 0.1.0, Requested: 0.2.0`

**Solution:** Update the version in `build.zig` (line ~231):
```zig
options.addOption([]const u8, "version", "0.2.0");
```

### Tag Already Exists

**Error:** `Tag v0.1.0 already exists!`

**Solution:** Delete the tag locally and remotely:
```bash
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0
```

### Test Failures

**Error:** `Test suite failed: test-ssl`

**Solution:** Run the failing test manually to see details:
```bash
zig build test-ssl
```

Fix the issue, commit, and re-run `prepare-release.sh`.

### Build Artifact Missing

**Issue:** Release created but missing some artifacts

**Solution:** Check GitHub Actions logs for build failures. Re-run failed jobs from the Actions tab.

### Static Build Has Dynamic Dependencies

**Issue:** `ldd zigcat-linux-x64-static` shows shared libraries

**Solution:** Verify musl target and static flag:
```bash
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false -Dstrip=true
```

## Artifact Naming Convention

All release artifacts follow this pattern:

```
zigcat-{os}-{arch}[-static][.exe]
```

**Examples:**
- `zigcat-linux-x64` - Linux x86_64 dynamic
- `zigcat-linux-x64-static` - Linux x86_64 static musl
- `zigcat-windows-x64.exe` - Windows x86_64
- `zigcat-macos-arm64` - macOS Apple Silicon

**Checksum files:**
- `{artifact}.sha256` - Individual checksum
- `SHA256SUMS` - All checksums in one file

## Binary Size Expectations

Approximate binary sizes (with `-Dstrip=true`):

| Platform | Size | Notes |
|----------|------|-------|
| Linux x64 (dynamic) | ~1.8 MB | With TLS |
| Linux x64 (static musl) | ~1.5 MB | NO TLS, portable |
| macOS x64 | ~1.9 MB | With TLS |
| Windows x64 | ~2.1 MB | With TLS |
| FreeBSD x64 | ~1.8 MB | With TLS |

Static builds are smaller due to no TLS dependencies.

## Support and Feedback

For issues with releases:

1. Check GitHub Actions logs: `https://github.com/YOUR_REPO/actions`
2. Review TESTS.md for test suite documentation
3. File an issue with:
   - Release version
   - Platform/architecture
   - Error message or unexpected behavior
   - Steps to reproduce

## Related Documentation

- **TESTS.md** - Test suite documentation (~161+ tests)
- **CLAUDE.md** - Project architecture and build commands
- **README.md** - Usage and feature documentation
- **Makefile** - Manual cross-compilation targets
