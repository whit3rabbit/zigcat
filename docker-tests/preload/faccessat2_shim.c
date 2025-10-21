/*
 * LD_PRELOAD shim to intercept faccessat2 syscalls and redirect to faccessat
 *
 * This workaround is needed for Docker builds with old seccomp profiles that
 * block the faccessat2 syscall (errno 38 / ENOSYS).
 *
 * Zig 0.15.1 uses faccessat2 internally, which requires:
 * - Docker 20.10.6+ with libseccomp 2.4.4+
 * - OR this LD_PRELOAD shim as a temporary workaround
 *
 * Build:
 *   gcc -shared -fPIC -o faccessat2_shim.so faccessat2_shim.c
 *
 * Usage:
 *   LD_PRELOAD=./faccessat2_shim.so zig build
 */

#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <errno.h>

/* Syscall numbers for x86_64 and aarch64 */
#ifndef SYS_faccessat
#define SYS_faccessat 269   /* x86_64 and aarch64 */
#endif

#ifndef SYS_faccessat2
#define SYS_faccessat2 439  /* x86_64 and aarch64 */
#endif

/*
 * Intercept faccessat2 and redirect to faccessat
 *
 * Note: This ignores the flags parameter since faccessat doesn't support it.
 * This is acceptable for Zig's build system which primarily uses flags=0.
 */
int faccessat2(int dirfd, const char *pathname, int mode, int flags) {
    /*
     * Call faccessat (older syscall) instead of faccessat2
     * Ignore flags - faccessat doesn't support AT_EACCESS or AT_SYMLINK_NOFOLLOW
     */
    return syscall(SYS_faccessat, dirfd, pathname, mode);
}
