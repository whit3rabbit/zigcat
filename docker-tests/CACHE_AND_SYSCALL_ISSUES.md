# Docker Build Cache and Syscall Issues

This document details the Zig cache corruption and syscall compatibility issues encountered during Docker builds for zigcat release binaries.

**Date**: 2025-10-20
**Zig Version**: 0.15.1
**Docker BuildKit**: 1.5+

---

## Issue 1: Zig Cache Corruption (RESOLVED)

###Description
Builds fail with `error: unable to access options file '.zig-cache/c/.../options.zig': Unexpected`

### Root Cause
Docker BuildKit cache mounts (`--mount=type=cache`) persist across builds. When source files change or different build options are used, the cached state becomes invalid.

### Solution Applied
**Removed cache mounts and added cache cleanup after each build:**

```dockerfile
# Before (BROKEN):
RUN --mount=type=cache,target=/build/.zig-cache \
    --mount=type=cache,target=/tmp/zig-global-cache \
    zig build -Dtarget="$ZIG_TARGET" $BUILD_OPTIONS

# After (FIXED):
ARG BUILD_ID=default
ENV ZIG_LOCAL_CACHE_DIR=/build/.zig-cache-${BUILD_ID}
ENV ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global-cache-${BUILD_ID}

RUN zig build -Dtarget="$ZIG_TARGET" $BUILD_OPTIONS && \
    rm -rf "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
```

### Files Modified
- `docker-tests/dockerfiles/release/Dockerfile.linux-musl`
- `docker-tests/dockerfiles/release/Dockerfile.linux-glibc`
- `docker-tests/dockerfiles/release/Dockerfile.alpine-wolfssl`
- `docker-tests/scripts/build-release.sh` (generates unique BUILD_ID)

**Status**: ✅ **RESOLVED** (cache approach fixed, but blocked by Issue 2)

---

## Issue 2: faccessat2 Syscall Blocked (ACTIVE BL OCKER)

### Error Message
```
unexpected errno: 38
faccessatZ: else => |err| return unexpectedErrno(err)
error: unable to access options file '.zig-cache/c/242be99a2e1bb39e6b880c7b5722b91e/options.zig': Unexpected
```

### Root Cause
Zig 0.15.1 uses the `faccessat2` syscall which was introduced in Linux kernel 5.8. Older Docker versions or libseccomp versions block this syscall, returning errno 38 (ENOSYS).

**System Requirements**:
- Docker 20.10.6+ with libseccomp 2.4.4+
- **OR** custom seccomp profile that allows `faccessat2`

### Attempted Fixes
1. ❌ **Custom seccomp profile**: `--security-opt seccomp=docker-tests/seccomp/zig-builder.json`
   - Did not work with `docker buildx build` (seccomp option may not be supported by buildx)

2. ❌ **Removing cache mounts**: Did not address the underlying syscall issue

### Current Status
**BLOCKED** - Cannot proceed with Docker builds until one of the following is resolved:

1. **Upgrade host system**:
   - Docker 20.10.6+ (currently unknown version)
   - libseccomp 2.4.4+

2. **Use alternative build approach**:
   - Build locally without Docker
   - Use GitHub Actions with newer Docker version
   - Use native builds on target platforms

### Verification Commands
```bash
# Check Docker version
docker --version

# Check if buildx supports seccomp
docker buildx build --help | grep seccomp

# Check libseccomp version (on Linux)
ldconfig -p | grep libseccomp
```

**Status**: ⚠️ **ACTIVE BLOCKER** - Requires system upgrade or alternative build approach

---

## Issue 3: Alpine WolfSSL Package Name (RESOLVED)

### Error Message
```
ERROR: unable to select packages:
  wolfssl-dev (no such package)
```

### Root Cause
Alpine Linux uses `wolfssl` package (not `wolfssl-dev`) in the community repository.

### Solution Applied
```dockerfile
# Before:
RUN apk add --no-cache wolfssl-dev

# After:
# NOTE: Use 'wolfssl' package from community repo (not 'wolfssl-dev')
RUN apk add --no-cache wolfssl
```

### Files Modified
- `docker-tests/dockerfiles/release/Dockerfile.alpine-wolfssl`
- `docker-tests/dockerfiles/Dockerfile.alpine`

**Status**: ✅ **RESOLVED**

---

## Issue 4: ARM64 GLIBC Linking (KNOWN LIMITATION)

### Error Message
```
error: ld.lld: undefined reference: dlerror@GLIBC_2.34
error: ld.lld: undefined reference: pthread_rwlock_destroy@GLIBC_2.34
(... 17 errors total)
```

### Root Cause
Zig 0.15.1's ld.lld linker cannot resolve versioned GLIBC symbols on ARM64 architecture.

### Attempted Fixes
1. ❌ Explicit pthread/dl linking
2. ❌ `--allow-shlib-undefined` linker flag (API doesn't exist in Zig 0.15.1)

### Recommendation
- Use ARM64 **musl** builds instead (static, no GLIBC dependency)
- Wait for Zig linker improvements in future versions
- Consider using traditional `ld` instead of `ld.lld` for ARM64 glibc targets

**Status**: ❌ **KNOWN LIMITATION** - Cannot be fixed with current Zig version

---

## Summary Table

| Issue | Status | Impact | Solution |
|-------|--------|--------|----------|
| Zig cache corruption | ✅ Resolved | Low | Cache cleanup after build |
| faccessat2 syscall blocked | ⚠️ **BLOCKER** | **High** | **Requires system upgrade** |
| Alpine WolfSSL package | ✅ Resolved | Low | Use `wolfssl` package |
| ARM64 GLIBC linking | ❌ Known limitation | Medium | Use ARM64 musl instead |

---

## Next Steps

### Immediate Priority
**Resolve faccessat2 syscall issue**:

1. Check current Docker and libseccomp versions
2. Upgrade Docker to 20.10.6+ if needed
3. Upgrade libseccomp to 2.4.4+ if needed
4. **OR** use GitHub Actions with modern Docker version
5. **OR** build natively on macOS/Linux without Docker

### Testing After Upgrade
```bash
# Test alpine-wolfssl build
timeout 240 docker buildx build \
  --platform linux/amd64 \
  --build-arg BUILD_ID="test-$(date +%s)" \
  --build-arg ZIG_VERSION=0.15.1 \
  --build-arg DEFAULT_ZIG_VERSION=0.15.1 \
  -f docker-tests/dockerfiles/release/Dockerfile.alpine-wolfssl \
  -t zigcat-test:latest --load .
```

### Alternative: GitHub Actions Build
If local Docker upgrade is not feasible, use GitHub Actions workflow:
- ubuntu-latest provides Docker 20.10+ by default
- No seccomp issues
- Can build all platform variants

---

## References
- Zig faccessat2 issue: https://github.com/ziglang/zig/issues/13050
- Docker seccomp profile: `docker-tests/seccomp/zig-builder.json`
- Previous fixes: `docker-tests/FIXES_APPLIED.md`, `docker-tests/BUILD_FIXES_SUMMARY.md`
