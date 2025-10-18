const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const has_sigaction = @hasDecl(posix, "Sigaction");
const has_sigwinch = has_sigaction and @hasDecl(posix.SIG, "WINCH");
const supports_posix_signals = has_sigwinch;

var handler_installed = std.atomic.Value(bool).init(false);
var window_size_changed = std.atomic.Value(bool).init(false);

fn sigwinchHandler(_: c_int) callconv(std.builtin.CallingConvention.c) void {
    window_size_changed.store(true, .release);
}

pub fn supportsSigwinch() bool {
    return supports_posix_signals;
}

pub fn isSigwinchEnabled() bool {
    if (!supports_posix_signals) {
        return false;
    }
    return handler_installed.load(.acquire);
}

pub fn setupSigwinchHandler() !void {
    if (!supports_posix_signals) {
        return error.UnsupportedPlatform;
    }

    if (handler_installed.load(.acquire)) {
        return;
    }

    const sigaction = posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };

    posix.sigaction(posix.SIG.WINCH, &sigaction, null);
    handler_installed.store(true, .release);
}

pub fn checkWindowSizeChanged() bool {
    if (!supports_posix_signals) {
        return false;
    }
    return window_size_changed.swap(false, .acquire);
}

pub fn getWindowSizeForFd(fd: posix.fd_t) !posix.winsize {
    if (!supports_posix_signals) {
        return error.UnsupportedPlatform;
    }

    var ws: posix.winsize = undefined;
    while (true) {
        const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        switch (posix.errno(rc)) {
            .SUCCESS => return ws,
            .INTR => continue,
            else => return error.IoctlFailed,
        }
    }
}

pub fn getWindowSize() !posix.winsize {
    return getWindowSizeForFd(posix.STDOUT_FILENO);
}
