# Zig Version Compatibility

**Last Updated**: 2025-10-20
**Status**: ✅ Compatible with Zig 0.15.1 and 0.16.0-dev

## Supported Zig Versions

| Version | Status | Notes |
|---------|--------|-------|
| **0.15.1** | ✅ **Officially Supported** | Target version for releases |
| **0.16.0-dev** | ✅ **Compatible** | Early adopter support (dev builds) |
| 0.14.x | ❌ Not Supported | ArrayList API breaking changes |

## Cross-Version Compatibility Fixes

### 1. File Reading API (src/server/listen.zig:421)

**Issue**: Initially thought `readToEndAlloc()` was removed in 0.16.0-dev.

**Resolution**: Research confirmed `readToEndAlloc()` still exists in both versions.

```zig
// ✅ Works in 0.15.1 and 0.16.0-dev
const content = try file.readToEndAlloc(allocator, max_file_size);
```

**Status**: ✅ No special handling needed

### 2. getgroups() System Call (src/util/security.zig:152-157)

**Issue**: Zig 0.16.0-dev has C translation layer bugs with `__builtin_constant_p` in getgroups() inline macros.

**Error**:
```
error: expected type 'c_int', found 'bool'
    __builtin.object_size(..., @as(c_int, 2) > @as(c_int, 1))
                                 ~~~~~~~~~~~~~~^~~~~~~~~~~~~~~
```

**Root Cause**: [Issue #22804](https://github.com/ziglang/zig/issues/22804) - C translation doesn't cast comparison operators to `bool` in conditional contexts.

**Resolution**: Use direct Linux syscall on 0.16.0-dev to bypass broken C macros.

```zig
const ngroups = if (builtin.os.tag == .linux and @hasDecl(std.os.linux, "getgroups"))
    // Zig 0.16.0-dev on Linux: Bypass C translation layer
    @as(i32, @intCast(std.os.linux.getgroups(@intCast(group_buf.len), @ptrCast(&group_buf))))
else
    // Zig 0.15.1 or non-Linux: Use C library function
    c.getgroups(@intCast(group_buf.len), &group_buf);
```

**Status**: ✅ Compile-time selection based on platform and Zig version

## API Migration Notes

### From Zig 0.14.x → 0.15.1

If migrating from 0.14.x, be aware of these breaking changes:

1. **ArrayList API Change**:
   ```zig
   // ❌ OLD (0.14.x)
   var list = ArrayList.fromOwnedSlice(allocator, slice);
   list.deinit();

   // ✅ NEW (0.15.1+)
   var list = ArrayList.fromOwnedSlice(slice);  // No allocator
   list.deinit(allocator);  // Allocator required
   ```

2. **Build System Changes**:
   ```zig
   // ❌ OLD (0.14.x)
   exe.root_source_file = .{ .path = "src/main.zig" };

   // ✅ NEW (0.15.1+)
   exe.root_module.root_source_file = .{ .path = "src/main.zig" };
   ```

3. **Reader/Writer Overhaul**:
   - `file.reader()` → `file.deprecatedReader()` (still works, but marked deprecated)
   - New `std.Io.Reader`/`std.Io.Writer` interfaces (0.15.1+)
   - Explicit buffering now required

## Future-Proofing for Zig 0.16.0 Stable

### Expected Breaking Changes

From [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html):

> "Moving forward, Zig will rearrange all of its file system, networking, timers, synchronization, and pretty much everything that can block into a new `std.Io` interface."

**Impact**: When Zig 0.16.0 is officially released, expect major breaking changes in:
- `std.fs` - File system operations
- `std.net` - Networking
- `std.time` - Timers and sleep
- Synchronization primitives

**Recommendation**: Continue using `readToEndAlloc()` until 0.16.0 stable release, then review new `std.Io` migration guide.

### Known Upcoming Changes

1. **Async I/O Integration**: All blocking operations will migrate to `std.Io` interface
2. **POSIX Namespace Cleanup**: Ongoing migration from `std.os.*` to `std.posix.*`
3. **C Translation Improvements**: Fix for issue #22804 (__builtin macro handling)

## Testing Matrix

### macOS (Zig 0.15.1)
```bash
$ zig version
0.15.1

$ zig build
[OpenSSL Detection] ✓ Found via pkg-config: 3.5.2
[Build] LTO mode: auto (enabled in release modes)
✅ Build successful
```

### Linux (Zig 0.16.0-dev)
```bash
$ zig version
0.16.0-dev.747+493ad58ff

$ zig build
[OpenSSL Detection] ✓ Found via pkg-config: 3.0.13
[Build] LTO mode: auto (enabled in release modes)
✅ Build successful (with std.os.linux.getgroups() workaround)
```

## Troubleshooting

### Build Fails with "expected type 'c_int', found 'bool'"

**Symptom**:
```
src/util/security.zig:149: error: expected type 'c_int', found 'bool'
    const ngroups = c.getgroups(@intCast(group_buf.len), &group_buf);
```

**Cause**: Zig 0.16.0-dev C translation layer bug ([#22804](https://github.com/ziglang/zig/issues/22804))

**Solution**: Pull latest changes - the code now uses `std.os.linux.getgroups()` on 0.16.0-dev to bypass the broken C macro.

### Build Fails with "no member function named 'readToEndAlloc'"

**Symptom**:
```
src/server/listen.zig:421: error: no field or member function named 'readToEndAlloc'
```

**Cause**: This should NOT happen - `readToEndAlloc()` exists in both 0.15.1 and 0.16.0-dev.

**Solution**:
1. Verify your Zig version: `zig version`
2. If using a very old dev build, upgrade to latest 0.16.0-dev or use stable 0.15.1
3. Report issue with your exact Zig version/commit hash

## References

- **Zig 0.15.1 Release Notes**: https://ziglang.org/download/0.15.1/release-notes.html
- **Zig Master Documentation**: https://ziglang.org/documentation/master/
- **Issue #22804**: __builtin_constant_p type mismatch in C translation
- **PR #22286**: getgroups() nullable pointer update
- **PR #23096**: Removal of deprecated APIs from 0.14 cycle

## Contributing

When adding code that may interact with version-specific APIs:

1. **Test on both 0.15.1 and latest 0.16.0-dev** if possible
2. **Use `@hasDecl()` for compile-time detection** of version-specific APIs
3. **Document version-specific workarounds** with inline comments and issue references
4. **Prefer stable stdlib APIs** over platform-specific syscalls when available

Example pattern:
```zig
// Zig 0.16.0-dev workaround for issue #XXXXX
const result = if (@hasDecl(std.new_api, "function"))
    std.new_api.function(args)  // 0.16.0-dev path
else
    std.old_api.function(args);  // 0.15.1 path
```
