const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const supports_posix_signals = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

pub const SignalMode = enum(u8) {
    local,
    remote,
};

pub const SignalEvent = struct {
    ctrl_c: bool = false,
    ctrl_z: bool = false,

    pub fn any(self: SignalEvent) bool {
        return self.ctrl_c or self.ctrl_z;
    }
};

var installed = std.atomic.Value(bool).init(false);
var current_mode = std.atomic.Value(SignalMode).init(.local);
var ctrl_c_flag = std.atomic.Value(bool).init(false);
var ctrl_z_flag = std.atomic.Value(bool).init(false);

const has_sigint = @hasField(posix.SIG, "INT");
const has_sigtstp = @hasField(posix.SIG, "TSTP");

var previous_sigint: posix.Sigaction = undefined;
var previous_sigtstp: posix.Sigaction = undefined;
var have_previous_sigint = std.atomic.Value(bool).init(false);
var have_previous_sigtstp = std.atomic.Value(bool).init(false);

fn sigintHandler(_: c_int) callconv(std.builtin.CallingConvention.c) void {
    ctrl_c_flag.store(true, .release);
}

fn sigtstpHandler(_: c_int) callconv(std.builtin.CallingConvention.c) void {
    ctrl_z_flag.store(true, .release);
}

pub fn supportsSignalTranslation() bool {
    return supports_posix_signals and has_sigint;
}

pub fn currentMode() SignalMode {
    return current_mode.load(.acquire);
}

pub fn install(mode: SignalMode) !void {
    current_mode.store(mode, .release);

    if (!supportsSignalTranslation() or mode == .local) {
        // No translation required; ensure handlers are removed.
        try teardown();
        return;
    }

    if (installed.load(.acquire)) {
        return;
    }

    ctrl_c_flag.store(false, .release);
    ctrl_z_flag.store(false, .release);

    if (has_sigint) {
        const handler = posix.Sigaction{
            .handler = .{ .handler = sigintHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(posix.SIG.INT, &handler, &previous_sigint);
        have_previous_sigint.store(true, .release);
    }

    if (has_sigtstp) {
        const handler = posix.Sigaction{
            .handler = .{ .handler = sigtstpHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(posix.SIG.TSTP, &handler, &previous_sigtstp);
        have_previous_sigtstp.store(true, .release);
    }

    installed.store(true, .release);
}

pub fn teardown() !void {
    if (!supportsSignalTranslation()) return;
    if (!installed.load(.acquire)) return;

    if (has_sigint) {
        var restore = if (have_previous_sigint.swap(false, .acq_rel)) previous_sigint else posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &restore, null);
    }

    if (has_sigtstp) {
        var restore = if (have_previous_sigtstp.swap(false, .acq_rel)) previous_sigtstp else posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.TSTP, &restore, null);
    }

    installed.store(false, .release);
    current_mode.store(.local, .release);
    ctrl_c_flag.store(false, .release);
    ctrl_z_flag.store(false, .release);
}

pub fn pollEvents() SignalEvent {
    if (!supportsSignalTranslation()) {
        return .{};
    }

    return .{
        .ctrl_c = ctrl_c_flag.swap(false, .acquire),
        .ctrl_z = ctrl_z_flag.swap(false, .acquire),
    };
}

/// Test helper to simulate signal delivery.
pub fn injectForTest(event: SignalEvent) void {
    if (event.ctrl_c) ctrl_c_flag.store(true, .release);
    if (event.ctrl_z) ctrl_z_flag.store(true, .release);
}
