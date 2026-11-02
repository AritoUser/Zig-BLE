//! Forces semantic analysis of every non-generic function reachable through the package's
//! public declarations (`zig build check-api`).
//!
//! Zig only compiles functions that are used, so a function nothing calls can stop compiling
//! without any test noticing, until the first user calls it. Modules for another platform
//! are skipped: they only compile on theirs.

const std = @import("std");
const builtin = @import("builtin");
const ble = @import("Zig_BLE");

const os = builtin.os.tag;

fn isForeignPlatform(name: []const u8) bool {
    const has = struct {
        fn f(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    }.f;
    if (os != .windows and has(name, "windows")) return true;
    if (os != .windows and has(name, "bond_store.platform")) return true; // Win32 externs
    if (os != .linux and (has(name, "dbus") or has(name, "bluez"))) return true;
    return false;
}

const Seen = struct {
    types: [4096]type = undefined,
    len: usize = 0,
};

fn collect(comptime T: type, comptime seen: *Seen) void {
    for (seen.types[0..seen.len]) |t| {
        if (t == T) return;
    }
    const name = @typeName(T);
    if (std.mem.startsWith(u8, name, "std.") or std.mem.eql(u8, name, "builtin") or isForeignPlatform(name)) return;
    seen.types[seen.len] = T;
    seen.len += 1;
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return,
    }
    for (std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl)) == type) collect(@field(T, decl), seen);
    }
}

const all_types = blk: {
    @setEvalBranchQuota(100_000_000);
    var seen: Seen = .{};
    collect(ble, &seen);
    const final = seen.types[0..seen.len].*;
    break :blk final;
};

test {
    @setEvalBranchQuota(100_000_000);
    inline for (all_types) |T| {
        switch (@typeInfo(T)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => {
                inline for (comptime std.meta.declarations(T)) |decl| {
                    _ = &@field(T, decl);
                }
            },
            else => {},
        }
    }
}
