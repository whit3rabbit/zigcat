const std = @import("std");

pub const NewEnviron = struct {
    pub const IS: u8 = 0;
    pub const SEND: u8 = 1;
    pub const INFO: u8 = 2;

    pub const VAR: u8 = 0;
    pub const VALUE: u8 = 1;
    pub const ESC: u8 = 2;
    pub const USERVAR: u8 = 3;
};

pub const Kind = enum(u8) {
    variable = NewEnviron.VAR,
    user = NewEnviron.USERVAR,
};

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
    kind: Kind = .variable,
};

pub const OwnedEntry = struct {
    name: []const u8,
    value: []u8,
    kind: Kind = .variable,
};

pub const Collection = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OwnedEntry),

    pub fn init(allocator: std.mem.Allocator) Collection {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(OwnedEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Collection) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn items(self: *const Collection) []const OwnedEntry {
        return self.entries.items;
    }
};

pub fn collectEnvironmentVariables(
    allocator: std.mem.Allocator,
    names: []const []const u8,
) (std.mem.Allocator.Error || std.process.GetEnvVarOwnedError)!Collection {
    var collection = Collection.init(allocator);
    errdefer collection.deinit();

    for (names) |name| {
        const value_owned = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };
        try collection.entries.append(allocator, .{
            .name = name,
            .value = value_owned,
            .kind = .variable,
        });
    }

    return collection;
}

pub fn buildIsResponse(
    allocator: std.mem.Allocator,
    entries: []const OwnedEntry,
) std.mem.Allocator.Error![]u8 {
    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit(allocator);

    try response.append(allocator, NewEnviron.IS);

    for (entries) |entry| {
        try response.append(allocator, @intFromEnum(entry.kind));
        try appendEscaped(allocator, &response, entry.name);

        try response.append(allocator, NewEnviron.VALUE);
        try appendEscaped(allocator, &response, entry.value);
    }

    return response.toOwnedSlice(allocator);
}

fn appendEscaped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    data: []const u8,
) std.mem.Allocator.Error!void {
    for (data) |byte| {
        switch (byte) {
            0xFF => try out.appendSlice(allocator, &[_]u8{ 0xFF, 0xFF }),
            NewEnviron.ESC => try out.appendSlice(allocator, &[_]u8{ NewEnviron.ESC, NewEnviron.ESC }),
            0x00, 0x01, 0x03 => try out.appendSlice(allocator, &[_]u8{ NewEnviron.ESC, byte }),
            else => try out.append(allocator, byte),
        }
    }
}
