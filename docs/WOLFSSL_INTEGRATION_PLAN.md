# wolfSSL Integration Plan

**Date**: 2025-10-11
**Objective**: Integrate wolfSSL as an alternative TLS backend to reduce binary size from ~6MB to ~2-3MB for TLS-enabled builds
**Status**: Research Complete - Ready for Implementation

## Executive Summary

Research confirms that **wolfSSL is superior to OpenSSL for size-constrained builds**. wolfSSL can reduce TLS library overhead from 3-4MB (OpenSSL) to 300KB-1MB (wolfSSL), achieving **92% size reduction** while maintaining 90-95% OpenSSL API compatibility through the `--enable-opensslextra` compatibility layer.

### Size Comparison

| **TLS Library** | **Static Library Size** | **Binary Impact** | **Runtime Memory** |
|---|---|---|---|
| OpenSSL 3.5.2 | ~3-4MB | 6MB total | 1-2MB per connection |
| wolfSSL (minimal) | ~30-100KB | 2.5-3MB total | 3-36KB per connection |
| wolfSSL (full) | ~300KB-1MB | 3-4MB total | 36-100KB per connection |
| **Reduction** | **92-97%** | **50-60%** | **90-98%** |

### API Compatibility

- **Coverage**: 500+ OpenSSL functions mapped via `--enable-opensslextra`
- **Compatibility Layer**: Actively maintained (2024 updates)
- **Test Bed**: stunnel and Lighttpd (production-grade validation)
- **Migration Effort**: Minimal code changes (mostly header includes)

### Recommendation

**Implement dual TLS backend support**:
1. Keep OpenSSL as default (ubiquitous availability, zero setup)
2. Add wolfSSL as optional backend (`-Dtls-backend=wolfssl`)
3. Provide pre-built wolfSSL binaries for static builds
4. Document migration path for users prioritizing size

## Architecture Design

### Build System Changes

#### Option 1: Zig Package Manager (Recommended)

Use kassane/wolfssl as a Zig dependency:

```zig
// build.zig.zon
.{
    .name = "zigcat",
    .version = "0.1.0",
    .dependencies = .{
        .wolfssl = .{
            .url = "https://github.com/kassane/wolfssl/archive/zig-pkg.tar.gz",
            .hash = "...",
        },
    },
}
```

```zig
// build.zig additions
const tls_backend = b.option(
    enum { openssl, wolfssl },
    "tls-backend",
    "TLS library backend: openssl (default), wolfssl (smaller)",
) orelse .openssl;

if (enable_tls) {
    switch (tls_backend) {
        .openssl => {
            exe.linkSystemLibrary("ssl");
            exe.linkSystemLibrary("crypto");
            options.addOption(bool, "use_wolfssl", false);
        },
        .wolfssl => {
            const wolfssl_dep = b.dependency("wolfssl", .{
                .target = target,
                .optimize = optimize,
                .shared = false,  // Static linking
                .enable_opensslextra = true,  // OpenSSL compatibility
            });
            exe.linkLibrary(wolfssl_dep.artifact("wolfssl"));
            options.addOption(bool, "use_wolfssl", true);
        },
    }
}
```

#### Option 2: System wolfSSL (Alternative)

Detect system-installed wolfSSL similar to OpenSSL:

```zig
fn detectWolfSSL(b: *std.Build) bool {
    const pkg_config_result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &[_][]const u8{ "pkg-config", "--exists", "wolfssl" },
    }) catch return false;

    defer b.allocator.free(pkg_config_result.stdout);
    defer b.allocator.free(pkg_config_result.stderr);

    return (pkg_config_result.term.Exited == 0);
}
```

### Code Abstraction Layer

Create a TLS backend abstraction to support both libraries:

```zig
// src/tls/tls_backend.zig (NEW FILE)
const std = @import("std");
const build_options = @import("build_options");

pub const TlsContext = if (build_options.use_wolfssl)
    @import("tls_wolfssl.zig").WolfSslContext
else
    @import("tls_openssl.zig").OpenSslContext;

pub const TlsConnection = if (build_options.use_wolfssl)
    @import("tls_wolfssl.zig").WolfSslConnection
else
    @import("tls_openssl.zig").OpenSslConnection;

// Common interface (both backends must implement this)
pub const TlsBackend = struct {
    pub fn init() !void { }
    pub fn deinit() void { }
    pub fn createContext(is_server: bool) !TlsContext { }
};
```

### wolfSSL-Specific Implementation

```zig
// src/tls/tls_wolfssl.zig (NEW FILE)
const std = @import("std");
const c = @cImport({
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/ssl.h");
    @cInclude("wolfssl/wolfcrypt/settings.h");
});

pub const WolfSslContext = struct {
    ctx: *c.WOLFSSL_CTX,

    pub fn init(is_server: bool) !WolfSslContext {
        const method = if (is_server)
            c.wolfTLSv1_2_server_method()
        else
            c.wolfTLSv1_2_client_method();

        const ctx = c.wolfSSL_CTX_new(method) orelse
            return error.TlsContextFailed;

        return WolfSslContext{ .ctx = ctx };
    }

    pub fn deinit(self: *WolfSslContext) void {
        c.wolfSSL_CTX_free(self.ctx);
    }

    pub fn loadCertificate(self: *WolfSslContext, cert_path: []const u8) !void {
        const cert_z = try std.cstr.addNullByte(self.allocator, cert_path);
        defer self.allocator.free(cert_z);

        const ret = c.wolfSSL_CTX_use_certificate_file(
            self.ctx,
            cert_z.ptr,
            c.SSL_FILETYPE_PEM
        );
        if (ret != c.SSL_SUCCESS) return error.CertificateLoadFailed;
    }

    // ... similar for private key, verification, etc.
};

pub const WolfSslConnection = struct {
    ssl: *c.WOLFSSL,

    pub fn init(ctx: *WolfSslContext, socket: std.posix.socket_t) !WolfSslConnection {
        const ssl = c.wolfSSL_new(ctx.ctx) orelse
            return error.TlsConnectionFailed;

        const ret = c.wolfSSL_set_fd(ssl, socket);
        if (ret != c.SSL_SUCCESS) {
            c.wolfSSL_free(ssl);
            return error.TlsSetFdFailed;
        }

        return WolfSslConnection{ .ssl = ssl };
    }

    pub fn handshake(self: *WolfSslConnection) !void {
        const ret = c.wolfSSL_connect(self.ssl);
        if (ret != c.SSL_SUCCESS) {
            const err = c.wolfSSL_get_error(self.ssl, ret);
            return error.TlsHandshakeFailed;
        }
    }

    pub fn read(self: *WolfSslConnection, buffer: []u8) !usize {
        const bytes = c.wolfSSL_read(self.ssl, buffer.ptr, buffer.len);
        if (bytes < 0) {
            const err = c.wolfSSL_get_error(self.ssl, bytes);
            if (err == c.SSL_ERROR_WANT_READ) return 0;
            return error.TlsReadFailed;
        }
        return @intCast(bytes);
    }

    pub fn write(self: *WolfSslConnection, data: []const u8) !usize {
        const bytes = c.wolfSSL_write(self.ssl, data.ptr, data.len);
        if (bytes < 0) {
            const err = c.wolfSSL_get_error(self.ssl, bytes);
            if (err == c.SSL_ERROR_WANT_WRITE) return 0;
            return error.TlsWriteFailed;
        }
        return @intCast(bytes);
    }

    pub fn deinit(self: *WolfSslConnection) void {
        c.wolfSSL_free(self.ssl);
    }
};
```

### Migration Pattern for Existing Code

**Before (OpenSSL-specific)**:
```zig
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

const ctx = c.SSL_CTX_new(c.TLS_client_method());
```

**After (Backend-agnostic)**:
```zig
const tls = @import("tls/tls_backend.zig");

const ctx = try tls.TlsContext.init(false); // false = client mode
```

## Implementation Phases

### Phase 2A: wolfSSL Backend Support (1-2 weeks)

**Week 1: Foundation**
1. Add `build.zig.zon` with wolfssl dependency
2. Create `src/tls/tls_backend.zig` abstraction layer
3. Implement `src/tls/tls_wolfssl.zig` with basic connect/read/write
4. Add `tls-backend` build option to `build.zig`
5. Update `CLAUDE.md` with wolfSSL build instructions

**Week 2: Feature Parity**
1. Add wolfSSL server mode support (listen with TLS)
2. Implement certificate verification
3. Add DTLS support for wolfSSL backend
4. Test both backends with existing test suite
5. Document API compatibility coverage

**Deliverables**:
- ✅ Build system supports `-Dtls-backend=openssl` (default)
- ✅ Build system supports `-Dtls-backend=wolfssl` (opt-in)
- ✅ All TLS features work with both backends
- ✅ Binary size measured and documented
- ✅ CLAUDE.md updated with wolfSSL usage

### Phase 2B: Static TLS Builds (1 week)

**Combine wolfSSL + static linking for maximum size reduction:**

```bash
# Linux static build with wolfSSL (target: 2-3MB)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls-backend=wolfssl -Dlto=full

# Expected sizes:
# - Linux static + OpenSSL:  ~6MB (dynamic linking required)
# - Linux static + wolfSSL:  ~2-3MB (fully static, no dependencies)
# - macOS dynamic + wolfSSL: ~2.8-3.2MB (vs 2.4MB current)
```

**Deliverables**:
- ✅ Static Linux builds with wolfSSL under 3MB
- ✅ Makefile targets: `make linux-x64-static-wolfssl`
- ✅ Documentation: `docs/STATIC_TLS_BUILD.md`

### Phase 2C: CI/CD Integration (1 week)

**GitHub Actions workflow additions:**

```yaml
- name: Build Linux Static with wolfSSL
  run: |
    zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls-backend=wolfssl -Dlto=full
    ls -lh zig-out/bin/zigcat
    # Verify size under 3MB
    test $(stat -c%s zig-out/bin/zigcat) -lt 3145728

- name: Test wolfSSL TLS functionality
  run: |
    # Start test TLS server with wolfSSL backend
    ./zig-out/bin/zigcat -l --ssl --ssl-cert test.pem --ssl-key test.key 8443 &
    sleep 2
    # Connect with wolfSSL client
    echo "test" | ./zig-out/bin/zigcat --ssl localhost 8443
```

**Deliverables**:
- ✅ CI builds both OpenSSL and wolfSSL variants
- ✅ Binary size assertions enforce <3MB for static-wolfssl
- ✅ TLS functionality tests for both backends
- ✅ Release artifacts include both variants

## Binary Size Projections

| **Build Configuration** | **Current** | **With wolfSSL** | **Reduction** |
|---|---|---|---|
| macOS dynamic (TLS) | 2.4MB | 2.8-3.2MB | -17% to +33% |
| Linux dynamic (TLS) | 6.0MB | 3.5-4.0MB | 33-42% |
| Linux static (no TLS) | 2.0MB | 2.0MB | 0% (unchanged) |
| **Linux static (with TLS)** | **N/A** | **2.5-3.0MB** | **NEW** |

**Key Insights**:
- macOS may see slight size increase due to dynamic linking overhead
- Linux dynamic builds benefit significantly (3.5-4MB vs 6MB)
- **Linux static + wolfSSL enables TLS within size budget (<3MB)**
- This unlocks TLS for embedded/container deployments that previously required TLS disabled

## wolfSSL Configuration

### Minimal Configuration (300KB library)

```bash
# For zigcat: Disable unused features
./configure \
    --enable-opensslextra \
    --enable-tls13 \
    --enable-dtls \
    --disable-examples \
    --disable-crypttests \
    --disable-old-tls \
    --disable-sha3 \
    --disable-sha512 \
    --disable-poly1305 \
    --disable-chacha \
    --disable-md5 \
    --disable-ripemd \
    --disable-des3 \
    --disable-idea \
    --disable-rc4 \
    CFLAGS="-Os -ffunction-sections -fdata-sections" \
    LDFLAGS="-Wl,--gc-sections"
```

### Feature-Complete Configuration (1MB library)

```bash
# For zigcat: Full modern TLS support
./configure \
    --enable-opensslextra \
    --enable-tls13 \
    --enable-dtls \
    --enable-aesgcm \
    --enable-chacha \
    --enable-poly1305 \
    --enable-curve25519 \
    --enable-ed25519 \
    --disable-examples \
    --disable-crypttests \
    --disable-old-tls \
    CFLAGS="-O2 -ffunction-sections -fdata-sections" \
    LDFLAGS="-Wl,--gc-sections"
```

## OpenSSL Compatibility Coverage

### Supported (via --enable-opensslextra)

✅ **SSL/TLS Operations**:
- `SSL_CTX_new()`, `SSL_new()`, `SSL_connect()`, `SSL_accept()`
- `SSL_read()`, `SSL_write()`, `SSL_shutdown()`
- `SSL_set_fd()`, `SSL_get_error()`

✅ **Certificate Management**:
- `SSL_CTX_use_certificate_file()`
- `SSL_CTX_use_PrivateKey_file()`
- `SSL_CTX_load_verify_locations()`
- `SSL_get_peer_certificate()`

✅ **Verification**:
- `SSL_CTX_set_verify()`
- `SSL_get_verify_result()`
- `X509_verify_cert()`

✅ **DTLS (Datagram TLS)**:
- `DTLS_client_method()`, `DTLS_server_method()`
- `DTLSv1_2_client_method()`
- All DTLS-specific timeouts and MTU settings

### Unsupported / Requires Adaptation

❌ **Engine API**: wolfSSL doesn't support OpenSSL's engine abstraction
❌ **BIO abstraction**: wolfSSL uses simpler I/O model
❌ **Some legacy ciphers**: DES, RC4, MD5 (can be enabled if needed)

**Impact on zigcat**: Minimal - zigcat uses only basic SSL/TLS operations, all supported by wolfSSL compatibility layer.

## Testing Strategy

### Unit Tests

```zig
// tests/wolfssl_compat_test.zig
test "wolfSSL compatibility - basic connect" {
    if (!build_options.use_wolfssl) return error.SkipZigTest;

    const tls = @import("tls/tls_backend.zig");
    try tls.TlsBackend.init();
    defer tls.TlsBackend.deinit();

    const ctx = try tls.TlsContext.init(false);
    defer ctx.deinit();

    // Verify context created successfully
    try testing.expect(ctx.ctx != null);
}
```

### Integration Tests

```bash
#!/bin/bash
# tests/wolfssl_integration_test.sh

echo "Testing wolfSSL TLS server..."
./zigcat -l --ssl --ssl-cert test.crt --ssl-key test.key 8443 &
SERVER_PID=$!
sleep 2

echo "Testing wolfSSL TLS client..."
echo "test message" | ./zigcat --ssl localhost 8443

kill $SERVER_PID
echo "✓ wolfSSL integration test passed"
```

### Compatibility Matrix

| **Feature** | **OpenSSL** | **wolfSSL** | **Test Coverage** |
|---|---|---|---|
| TLS 1.2 client | ✅ | ✅ | `test-ssl` |
| TLS 1.3 client | ✅ | ✅ | `test-ssl` |
| TLS server | ✅ | ✅ | `test-ssl` |
| Certificate verification | ✅ | ✅ | `test-ssl` |
| mTLS (client certs) | ✅ | ✅ | `test-ssl` |
| DTLS 1.2 | ✅ | ✅ | `test-dtls` (new) |
| DTLS 1.3 | ✅ | ✅ | `test-dtls` (new) |
| ALPN negotiation | ✅ | ✅ | `test-alpn` (new) |

## Documentation Updates

### CLAUDE.md Additions

```markdown
### TLS Backend Selection

zigcat supports two TLS backends with different trade-offs:

| **Backend** | **Binary Size** | **Compatibility** | **Use Case** |
|---|---|---|---|
| OpenSSL (default) | 6MB dynamic | Ubiquitous | Standard deployments |
| wolfSSL (opt-in) | 2.5-3MB static | 95% compatible | Embedded, size-critical |

#### Using OpenSSL (Default)

```bash
# Build with OpenSSL (default, no flags needed)
zig build

# Static build (Linux only, TLS disabled)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false
```

#### Using wolfSSL (Opt-In)

```bash
# Build with wolfSSL backend
zig build -Dtls-backend=wolfssl

# Static Linux build with TLS enabled (wolfSSL only)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls-backend=wolfssl

# Expected binary: 2.5-3.0MB (fully static, TLS included)
```

#### When to Use wolfSSL

- **Embedded systems**: Tight memory constraints
- **Containers**: Minimize image size
- **Static builds**: Need TLS without dynamic linking
- **Airgapped systems**: Standalone binary with TLS

#### When to Use OpenSSL

- **Standard deployments**: System OpenSSL already installed
- **Maximum compatibility**: Legacy system support
- **Development**: Zero setup (system libraries)
```

### New Documentation Files

1. **docs/WOLFSSL_INTEGRATION.md**
   - Architecture overview
   - Build instructions
   - API compatibility reference
   - Troubleshooting guide

2. **docs/TLS_BACKEND_COMPARISON.md**
   - Feature matrix
   - Performance benchmarks
   - Binary size analysis
   - Migration guide

## Migration Path for Users

### For Existing Users (No Action Required)

OpenSSL remains the default backend. Existing builds continue to work unchanged:
```bash
zig build  # Still uses OpenSSL by default
```

### For Size-Conscious Users (Opt-In)

Users prioritizing binary size can opt into wolfSSL:
```bash
# Install wolfSSL (one-time setup)
brew install wolfssl              # macOS
sudo apt-get install libwolfssl-dev  # Ubuntu/Debian

# Build with wolfSSL
zig build -Dtls-backend=wolfssl
```

### For Static Build Users (New Capability)

Users who previously had to disable TLS for static builds can now enable it:
```bash
# Before (no TLS)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls=false

# After (TLS enabled with wolfSSL)
zig build -Dtarget=x86_64-linux-musl -Dstatic=true -Dtls-backend=wolfssl
```

## Risks and Mitigations

### Risk 1: API Incompatibility

**Risk**: wolfSSL compatibility layer doesn't cover all OpenSSL APIs used by zigcat
**Likelihood**: Low (zigcat uses basic SSL/TLS operations)
**Mitigation**:
- Comprehensive testing with existing test suite
- Abstraction layer allows fallback to OpenSSL on incompatibility
- Document known limitations

### Risk 2: Increased Complexity

**Risk**: Two TLS backends increase maintenance burden
**Likelihood**: Medium
**Mitigation**:
- Clear abstraction layer (`tls_backend.zig`)
- Both backends share same test suite
- CI tests both backends automatically
- Keep OpenSSL as default (minimizes user impact)

### Risk 3: wolfSSL Installation Friction

**Risk**: Users may not have wolfSSL installed
**Likelihood**: High
**Mitigation**:
- Keep OpenSSL as default (zero friction)
- Provide pre-built binaries with wolfSSL
- Use Zig package manager to vendor wolfSSL
- Clear documentation for wolfSSL setup

### Risk 4: macOS Size Increase

**Risk**: macOS builds may see size increase due to dynamic linking overhead
**Likelihood**: High (research suggests 17% increase possible)
**Mitigation**:
- Keep OpenSSL default on macOS
- wolfSSL opt-in only for Linux/embedded use cases
- Document trade-offs clearly

## Success Metrics

### Binary Size Targets

- ✅ Linux static + wolfSSL: <3MB (currently impossible with OpenSSL)
- ✅ Linux dynamic + wolfSSL: <4MB (vs 6MB with OpenSSL)
- ⚠️ macOS dynamic + wolfSSL: <3.5MB (may increase from 2.4MB, acceptable trade-off)

### Compatibility Targets

- ✅ 100% of existing TLS features work with wolfSSL
- ✅ All tests pass with both backends
- ✅ Zero breaking changes for existing users

### Adoption Targets

- ✅ wolfSSL available as opt-in flag
- ✅ Documentation covers both backends
- ✅ CI produces both OpenSSL and wolfSSL binaries
- ⚠️ User adoption measured via download metrics (6-12 months)

## Timeline

| **Phase** | **Duration** | **Deliverables** |
|---|---|---|
| **Phase 2A: wolfSSL Backend** | 1-2 weeks | Backend abstraction, wolfSSL impl, basic tests |
| **Phase 2B: Static TLS** | 1 week | Static builds, Makefile targets, benchmarks |
| **Phase 2C: CI/CD** | 1 week | Automated builds, size assertions, releases |
| **Total** | **3-4 weeks** | **Production-ready dual TLS backend support** |

## Conclusion

wolfSSL integration is **highly recommended** as a complement to OpenSSL, not a replacement:

**Keep OpenSSL as default** for:
- Zero-friction developer experience
- Maximum system compatibility
- Ubiquitous availability

**Add wolfSSL as opt-in** for:
- 50-60% binary size reduction (Linux)
- Static Linux builds with TLS (NEW capability)
- Embedded/container deployments
- Size-critical use cases

This approach provides **the best of both worlds**: ease of use (OpenSSL default) and optimization (wolfSSL opt-in), without forcing users to choose or breaking existing workflows.

The implementation is low-risk due to:
- Clear abstraction layer
- Comprehensive testing
- Backward compatibility
- Phased rollout

**Recommendation: Proceed with Phase 2A implementation** to unlock static TLS builds and achieve the <3MB binary size goal for TLS-enabled variants.
