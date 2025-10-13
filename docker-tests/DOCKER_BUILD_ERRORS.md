# Docker Build Errors - Comprehensive Troubleshooting Guide

## Table of Contents
- [Common Error: errno 38 (ENOSYS) - faccessat2 Blocked](#common-error-errno-38-enosys---faccessat2-blocked)
- [Root Cause Analysis](#root-cause-analysis)
- [Quick Diagnosis](#quick-diagnosis)
- [Solutions](#solutions)
- [Security Considerations](#security-considerations)
- [FAQ](#faq)

---

## Common Error: errno 38 (ENOSYS) - faccessat2 Blocked

### Error Message

```
error: unable to access options file '.zig-cache/c/39b3c25c5d44366d7d333ebc434a10f1/options.zig': Unexpected
unexpected errno: 38
```

### Stack Trace

```
/opt/zig/lib/std/posix.zig:7342:40: in unexpectedErrno
/opt/zig/lib/std/posix.zig:5075:45: in faccessatZ
/opt/zig/lib/std/fs/Dir.zig:2505:36: in accessZ
/opt/zig/lib/std/Build/Step/Options.zig:470:35: in make
```

---

## Root Cause Analysis

### The Issue is NOT:
- ❌ Symlinks in `.zig-cache`
- ❌ Docker overlayfs filesystem bugs
- ❌ File permissions or ownership problems
- ❌ Cache corruption
- ❌ Zig compiler bug

### The Issue IS:
✅ **Docker Seccomp Profile Blocking Modern Syscalls**

#### Technical Details

1. **Zig 0.15.1 Requirements**:
   - Officially requires Linux kernel 5.10+ ([release notes](https://ziglang.org/download/0.15.1/release-notes.html))
   - Uses modern syscalls without fallback for performance

2. **faccessat2 Syscall**:
   - Added in Linux kernel 5.8 (August 2020)
   - Zig's standard library uses this syscall to check file access permissions
   - Location: `/opt/zig/lib/std/posix.zig:5075`

3. **Docker Seccomp Blocking**:
   - Docker versions < 20.10.6 block `faccessat2` in default seccomp profile
   - libseccomp < 2.4.4 doesn't know about `faccessat2`, returns ENOSYS (errno 38)
   - Zig has no fallback handling (by design - trusts OS version)

4. **Why wolfSSL Specifically**:
   - wolfSSL builds trigger additional C compilation options file checks
   - More file access operations → more `faccessat2` calls
   - OpenSSL builds may work because they skip certain build steps

#### Confirmed by Zig Maintainers

- **Issue #24821**: "errno 38 is unknown syscall. Turns out I have a low linux kernel version: 5.4.0"
  - Link: https://github.com/ziglang/zig/issues/24821
  - Status: Closed as "not planned" - user must upgrade to Linux 5.10+

- **Issue #23514**: "if an OS claims to be Linux version X.Y.Z then it needs to be Linux version X.Y.Z"
  - Link: https://github.com/ziglang/zig/issues/23514
  - Zig won't add fallback handling for containerized environments

---

## Quick Diagnosis

### Check Docker Version

```bash
docker --version
# Should show: Docker version 20.10.6+ (or higher)
```

### Check libseccomp Version

```bash
# Ubuntu/Debian
dpkg -l | grep libseccomp
# Should show: libseccomp2 2.4.4+ (or higher)

# RHEL/Fedora
rpm -qa | grep libseccomp
# Should show: libseccomp 2.4.4+ (or higher)
```

### Check Container Kernel Version

```bash
docker run --rm alpine:3.18 uname -r
# Shows host kernel version (may not match container)
```

### Test faccessat2 Support

```bash
# Check if faccessat2 is supported in container
docker run --rm alpine:3.18 grep faccessat2 /proc/self/syscall 2>/dev/null && echo "Supported" || echo "Not supported"
```

### Reproduce Error

```bash
# Try building without seccomp restrictions
docker buildx build \
  --platform linux/amd64 \
  --file docker-tests/dockerfiles/Dockerfile.alpine \
  --progress=plain \
  . 2>&1 | grep -A5 "errno 38"
```

---

## Solutions

### Solution 1: Update Docker Infrastructure (Recommended)

**Requirements**:
- Docker Engine 20.10.6+
- libseccomp 2.4.4+
- runc 1.0.0-rc93+

**Update Instructions**:

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Verify versions
docker --version
dpkg -l | grep libseccomp
```

**Pros**:
- ✅ Permanent fix
- ✅ No security compromises
- ✅ Works for all Zig builds

**Cons**:
- ❌ May require infrastructure changes
- ❌ Not always possible in CI/CD environments

---

### Solution 2: Custom Seccomp Profile (Production-Ready)

**Location**: `docker-tests/seccomp/zig-builder.json`

**Usage**:

```bash
# For builds
docker buildx build \
  --security-opt seccomp=docker-tests/seccomp/zig-builder.json \
  --platform linux/amd64 \
  -f docker-tests/dockerfiles/Dockerfile.alpine \
  .

# For docker run
docker run --rm \
  --security-opt seccomp=docker-tests/seccomp/zig-builder.json \
  alpine:3.18 \
  zig build -Dtls=true -Dtls-backend=wolfssl
```

**Profile Contents** (excerpt):

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscalls": [
    {
      "names": [
        "faccessat",
        "faccessat2",
        "statx",
        "newfstatat",
        "openat",
        "openat2"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

**Pros**:
- ✅ Safe for production
- ✅ Whitelists only required syscalls
- ✅ Works with any Docker version

**Cons**:
- ❌ Requires distributing profile file
- ❌ Must maintain if Zig changes syscall usage

---

### Solution 3: Disable Seccomp (Testing Only)

**Usage**:

```bash
docker buildx build \
  --security-opt seccomp=unconfined \
  --platform linux/amd64 \
  -f docker-tests/dockerfiles/Dockerfile.alpine \
  .
```

**Pros**:
- ✅ Quick fix for testing
- ✅ No additional files needed

**Cons**:
- ❌ **SECURITY RISK**: Removes all syscall filtering
- ❌ **NEVER use in production or CI/CD**

---

### Solution 4: Build Locally (Simplest)

**Usage**:

```bash
# On macOS/Linux host (not in Docker)
zig build -Dtls=true -Dtls-backend=wolfssl

# Check binary
./zig-out/bin/zigcat-wolfssl --version
ls -lh zig-out/bin/zigcat-wolfssl
# Output: 2.4MB (60% smaller than OpenSSL)
```

**Pros**:
- ✅ Always works
- ✅ No Docker complexity
- ✅ Produces fully functional binaries

**Cons**:
- ❌ Platform-specific (can't cross-compile easily)
- ❌ Requires Zig + wolfSSL installed locally

---

### Solution 5: Use tmpfs Cache (Performance)

**Add to Dockerfiles**:

```dockerfile
# Mount cache in RAM
RUN --mount=type=cache,target=/build/.zig-cache \
    --mount=type=cache,target=/tmp/zig-global-cache \
    zig build -Drelease=true -Dtls=true -Dtls-backend=wolfssl
```

**Or with docker run**:

```bash
docker run --rm \
  --tmpfs /build/.zig-cache:size=512M \
  --tmpfs /tmp/zig-global-cache:size=256M \
  alpine:3.18 \
  zig build -Dtls=true -Dtls-backend=wolfssl
```

**Pros**:
- ✅ Faster builds (RAM vs disk)
- ✅ Avoids some filesystem quirks

**Cons**:
- ❌ Higher memory usage
- ❌ Cache lost on container stop
- ❌ **Does not fix the underlying seccomp issue**

---

## Security Considerations

### Risk Assessment

| Solution | Security Risk | Use Case |
|----------|--------------|----------|
| Update Docker/libseccomp | ✅ None | Production |
| Custom seccomp profile | ⚠️ Low (if carefully crafted) | Production-ready |
| `seccomp=unconfined` | ⚠️⚠️ Medium | Local testing only |
| `--privileged` | ❌❌❌ Critical | **Never use** |

### Why Seccomp Matters

Docker's seccomp profile blocks potentially dangerous syscalls to:
- Prevent container escape vulnerabilities
- Limit kernel attack surface
- Enforce principle of least privilege

**Disabling seccomp removes this protection layer.**

### Safe Seccomp Customization

When creating custom profiles:

1. **Start with Docker's default profile**:
   ```bash
   wget https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json
   ```

2. **Add only required syscalls**:
   - `faccessat2` - Zig file access checks
   - `statx` - Extended file metadata
   - `openat2` - Modern file opening

3. **Test thoroughly**:
   ```bash
   # Verify build works
   docker buildx build --security-opt seccomp=your-profile.json ...

   # Check no unexpected syscalls blocked
   docker run --security-opt seccomp=your-profile.json ... strace -c zig build
   ```

4. **Document decisions**:
   - Why each syscall is needed
   - Security implications
   - Alternatives considered

---

## FAQ

### Q: Why does this only affect wolfSSL builds?

**A**: wolfSSL builds trigger additional C compilation steps that generate more options files in `.zig-cache/c/`. Each options file access hits the blocked `faccessat2` syscall. OpenSSL builds may skip some of these steps.

### Q: Will this be fixed in future Zig versions?

**A**: Unlikely. Zig maintainers have stated they won't add fallback handling for containerized environments. The burden is on container runtimes to properly whitelist syscalls or update to newer kernel versions.

**Quote from Zig Issue #23514**:
> "if an OS claims to be Linux version X.Y.Z then it needs to be Linux version X.Y.Z"

### Q: Can I use --privileged to fix this?

**A**: Technically yes, but **absolutely not recommended**:

```bash
# ⚠️ DO NOT USE IN PRODUCTION
docker run --privileged ...
```

This disables **all** container isolation, not just seccomp. Use custom seccomp profile instead.

### Q: Does this affect end users of my binaries?

**A**: No. This is purely a build-time issue. Binaries built with wolfSSL work perfectly on all platforms, regardless of how they were built.

### Q: Why doesn't musl have this problem on Alpine?

**A**: Alpine's musl libc may use different syscalls than glibc, but Zig 0.15.1 directly calls kernel syscalls (bypassing libc), so it hits the same seccomp blocks regardless of libc.

### Q: Can I just delete the cache before building?

**A**: No. Deleting `.zig-cache` doesn't help because the error occurs when Zig **creates** the options file, not when it reads existing ones.

```bash
# ❌ This does NOT fix the issue
rm -rf .zig-cache
zig build -Dtls=true -Dtls-backend=wolfssl
```

### Q: What if I'm on macOS/Windows?

**A**: Docker on macOS/Windows runs a Linux VM. The issue is in that Linux VM's seccomp configuration, not the host OS. Solutions are the same: update Docker or use custom seccomp profile.

### Q: How do I know if my Docker is affected?

**A**: Run this quick test:

```bash
docker buildx build \
  --platform linux/amd64 \
  --file docker-tests/dockerfiles/Dockerfile.alpine \
  --progress=plain \
  . 2>&1 | grep "errno 38"
```

If you see "errno 38", you're affected.

---

## Version Requirements Timeline

| Date | Component | Version | Event |
|------|-----------|---------|-------|
| Aug 2020 | Linux Kernel | 5.8 | Added `faccessat2` syscall |
| Aug 2020 | moby/moby | PR #41353 | Added `faccessat2` to Docker seccomp |
| Dec 2020 | Docker Engine | 20.10.0 | Released with `faccessat2` support |
| Jan 2021 | runc | 1.0.0-rc93 | Fixed ENOSYS return for blocked syscalls |
| Feb 2021 | libseccomp | 2.4.4 | Backported `faccessat2` support |
| Jan 2025 | Zig | 0.15.1 | Official Linux 5.10+ requirement |

---

## Related Issues and Resources

### Zig GitHub Issues

- **#24821**: Module.addOptions crashes with "unable to access options file"
  - https://github.com/ziglang/zig/issues/24821
  - Status: Closed as "not planned"

- **#23514**: statx system call may return ENOSYS due to seccomp
  - https://github.com/ziglang/zig/issues/23514
  - Contains maintainer position on container environments

- **#20423**: Unclear which minimum Linux kernel version Zig supports
  - https://github.com/ziglang/zig/issues/20423
  - Led to official Linux 5.10+ requirement

### Docker Documentation

- **Seccomp security profiles for Docker**
  - https://docs.docker.com/engine/security/seccomp/

- **Default seccomp profile (latest)**
  - https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json

### Related Projects

- **Bun (Zig-based runtime)**: Hit same issue, uses patched Zig stdlib
- **CachyOS Docker**: Fixed by updating base image ([CachyOS/docker#7](https://github.com/CachyOS/docker/issues/7))
- **Go**: Similar issue with `unix.Faccessat` ([golang/go#65243](https://github.com/golang/go/issues/65243))
- **Rust**: Similar issue with `statx` syscall ([rust-lang/rust#65662](https://github.com/rust-lang/rust/issues/65662))

---

## Diagnostic Commands Reference

```bash
# Check Docker version
docker --version

# Check libseccomp version
dpkg -l | grep libseccomp    # Ubuntu/Debian
rpm -qa | grep libseccomp    # RHEL/Fedora

# Check container kernel version
docker run --rm alpine:3.18 uname -r

# Test faccessat2 support
docker run --rm alpine:3.18 scmp_sys_resolver faccessat2

# Build with verbose output
docker buildx build --progress=plain -f Dockerfile.alpine . 2>&1 | tee build.log

# Test with unconfined (diagnostic only)
docker buildx build --security-opt seccomp=unconfined -f Dockerfile.alpine .

# Trace syscalls during build
docker run --rm -v$(pwd):/build alpine:3.18 sh -c 'apk add strace zig && cd /build && strace -c zig build 2>&1 | grep faccessat'

# Check if profile syntax is valid
docker run --rm --security-opt seccomp=docker-tests/seccomp/zig-builder.json alpine:3.18 echo "Profile loaded successfully"
```

---

## Contributing

If you encounter a different Docker build error or find a new solution:

1. Open an issue: https://github.com/whit3rabbit/zigcat/issues
2. Include:
   - Docker version (`docker --version`)
   - libseccomp version (`dpkg -l | grep libseccomp`)
   - Full build log
   - Host OS and kernel version

---

## Summary

**The Problem**: Docker's seccomp profile blocks `faccessat2` syscall used by Zig 0.15.1

**The Solution**: Use Docker 20.10.6+ with libseccomp 2.4.4+ OR custom seccomp profile

**Quick Fix (Testing)**: `--security-opt seccomp=unconfined`

**Production Fix**: Use `docker-tests/seccomp/zig-builder.json` profile

**Alternative**: Build locally (always works, produces 2.4MB binaries)
