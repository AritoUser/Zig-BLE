//! Self-contained growable byte buffer for D-Bus wire protocol
//! Completely independent of standard library ArrayList breaking changes across compiler versions.

const std = @import("std");

pub const ByteBuffer = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    len: usize,

    pub fn init(allocator: std.mem.Allocator) ByteBuffer {
        return .{
            .allocator = allocator,
            .data = &[_]u8{},
            .len = 0,
        };
    }

    pub fn initCapacity(allocator: std.mem.Allocator, cap: usize) !ByteBuffer {
        const d = try allocator.alloc(u8, cap);
        return .{
            .allocator = allocator,
            .data = d,
            .len = 0,
        };
    }

    pub fn deinit(self: ByteBuffer) void {
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
    }

    pub fn ensureTotalCapacity(self: *ByteBuffer, new_cap: usize) !void {
        if (new_cap <= self.data.len) return;
        var next_cap = if (self.data.len == 0) @as(usize, 64) else self.data.len * 2;
        while (next_cap < new_cap) next_cap *= 2;
        self.data = try self.allocator.realloc(self.data, next_cap);
    }

    pub fn append(self: *ByteBuffer, byte: u8) !void {
        try self.ensureTotalCapacity(self.len + 1);
        self.data[self.len] = byte;
        self.len += 1;
    }

    pub fn appendSlice(self: *ByteBuffer, slice: []const u8) !void {
        try self.ensureTotalCapacity(self.len + slice.len);
        @memcpy(self.data[self.len .. self.len + slice.len], slice);
        self.len += slice.len;
    }

    pub fn appendNTimes(self: *ByteBuffer, byte: u8, count: usize) !void {
        try self.ensureTotalCapacity(self.len + count);
        @memset(self.data[self.len .. self.len + count], byte);
        self.len += count;
    }

    pub fn clearRetainingCapacity(self: *ByteBuffer) void {
        self.len = 0;
    }

    pub fn getSlice(self: *const ByteBuffer) []u8 {
        return self.data[0..self.len];
    }
};

/// Version-independent generic dynamic list (immune to std.ArrayList differences between Zig versions)
pub fn List(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: []T,
        len: usize,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .items = &[_]T{},
                .len = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.items.len > 0) {
                self.allocator.free(self.items);
                self.items = &[_]T{};
                self.len = 0;
            }
        }

        pub fn append(self: *@This(), item: T) !void {
            if (self.len >= self.items.len) {
                const next_cap = if (self.items.len == 0) 8 else self.items.len * 2;
                self.items = try self.allocator.realloc(self.items, next_cap);
            }
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.len = 0;
        }

        pub fn getSlice(self: *const @This()) []T {
            return self.items[0..self.len];
        }
    };
}

test "ByteBuffer basic operations" {
    var buf = ByteBuffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.append('a');
    try buf.appendSlice("bcde");
    try buf.appendNTimes(0, 3);

    try std.testing.expectEqual(@as(usize, 8), buf.len);
    try std.testing.expectEqualStrings("abcde\x00\x00\x00", buf.getSlice());
}
