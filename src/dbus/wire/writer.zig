//! D-Bus Wire Message Serializer & MessageBuilder
//! Constructs D-Bus messages and containers with correct byte alignment.

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;
const ByteBuffer = @import("buffer.zig").ByteBuffer;

pub const ContainerType = enum {
    none,
    array,
    variant,
    dict_entry,
    structure,
};

pub const MessageBuilder = struct {
    buffer: *ByteBuffer,
    sig_buffer: ?*ByteBuffer = null,
    container_type: ContainerType = .none,
    array_len_pos: usize = 0,
    array_content_start: usize = 0,

    pub fn init(buffer: *ByteBuffer, sig_buffer: ?*ByteBuffer) MessageBuilder {
        return MessageBuilder{
            .buffer = buffer,
            .sig_buffer = sig_buffer,
            .container_type = .none,
        };
    }

    /// Inserts padding bytes to achieve the requested alignment.
    pub fn padTo(self: *MessageBuilder, alignment: usize) !void {
        const pad = types.paddingRequired(self.buffer.len, alignment);
        if (pad > 0) {
            try self.buffer.appendNTimes(0, pad);
        }
    }

    /// Appends a string ('s').
    pub fn appendString(self: *MessageBuilder, str: [:0]const u8) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.string);
        }
        try self.padTo(4);
        const len: u32 = @intCast(str.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);
        try self.buffer.appendSlice(&len_bytes);
        try self.buffer.appendSlice(str);
        try self.buffer.append(0); // null terminator
    }

    /// Appends an object path ('o').
    pub fn appendObjectPath(self: *MessageBuilder, path: [:0]const u8) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.object_path);
        }
        try self.padTo(4);
        const len: u32 = @intCast(path.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);
        try self.buffer.appendSlice(&len_bytes);
        try self.buffer.appendSlice(path);
        try self.buffer.append(0); // null terminator
    }

    /// Appends a boolean ('b') (4 bytes in D-Bus wire protocol).
    pub fn appendBool(self: *MessageBuilder, val: bool) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.boolean);
        }
        try self.padTo(4);
        const int_val: u32 = if (val) 1 else 0;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, int_val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a byte ('y').
    pub fn appendByte(self: *MessageBuilder, val: u8) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.byte);
        }
        try self.buffer.append(val);
    }

    /// Appends a uint16 ('q').
    pub fn appendUInt16(self: *MessageBuilder, val: u16) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.uint16);
        }
        try self.padTo(2);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends an int16 ('n').
    pub fn appendInt16(self: *MessageBuilder, val: i16) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.int16);
        }
        try self.padTo(2);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a uint32 ('u').
    pub fn appendUInt32(self: *MessageBuilder, val: u32) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.uint32);
        }
        try self.padTo(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends an int32 ('i').
    pub fn appendInt32(self: *MessageBuilder, val: i32) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.int32);
        }
        try self.padTo(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a uint64 ('t').
    pub fn appendUInt64(self: *MessageBuilder, val: u64) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.uint64);
        }
        try self.padTo(8);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends an int64 ('x').
    pub fn appendInt64(self: *MessageBuilder, val: i64) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.int64);
        }
        try self.padTo(8);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, val, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a double ('d').
    pub fn appendDouble(self: *MessageBuilder, val: f64) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.double);
        }
        try self.padTo(8);
        const bits: u64 = @bitCast(val);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, bits, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a Unix file descriptor ('h') as an index.
    pub fn appendUnixFd(self: *MessageBuilder, fd_index: u32) !void {
        if (self.sig_buffer) |sig| {
            try sig.append(Type.unix_fd);
        }
        try self.padTo(4);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, fd_index, .little);
        try self.buffer.appendSlice(&bytes);
    }

    /// Appends a byte array ('ay').
    pub fn appendBytes(self: *MessageBuilder, bytes: []const u8) !void {
        if (self.sig_buffer) |sig| {
            try sig.appendSlice("ay");
        }
        try self.padTo(4);
        const len: u32 = @intCast(bytes.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);
        try self.buffer.appendSlice(&len_bytes);
        try self.buffer.appendSlice(bytes);
    }

    /// Opens a struct container ('(...)').
    pub fn openStruct(self: *MessageBuilder, struct_sig: [:0]const u8) !MessageBuilder {
        if (self.sig_buffer) |sb| {
            try sb.appendSlice(struct_sig);
        }
        try self.padTo(8);
        return MessageBuilder{
            .buffer = self.buffer,
            .sig_buffer = null,
            .container_type = .structure,
        };
    }

    /// Opens a variant container ('v').
    pub fn openVariant(self: *MessageBuilder, sig: [:0]const u8) !MessageBuilder {
        if (self.sig_buffer) |sb| {
            try sb.append(Type.variant);
        }
        // Signature length (1 byte) + signature + null terminator
        try self.buffer.append(@intCast(sig.len));
        try self.buffer.appendSlice(sig);
        try self.buffer.append(0);

        // Prepare alignment for variant payload
        if (sig.len > 0) {
            const align_val = types.getAlignment(sig[0]);
            const pad = types.paddingRequired(self.buffer.len, align_val);
            if (pad > 0) {
                try self.buffer.appendNTimes(0, pad);
            }
        }

        return MessageBuilder{
            .buffer = self.buffer,
            .sig_buffer = null, // Within a container, do not capture top-level signature
            .container_type = .variant,
        };
    }

    /// Opens an array container ('a').
    pub fn openArray(self: *MessageBuilder, elem_sig: [:0]const u8) !MessageBuilder {
        if (self.sig_buffer) |sb| {
            try sb.append(Type.array);
            try sb.appendSlice(elem_sig);
        }
        // Array length requires 4-byte alignment
        try self.padTo(4);
        const len_pos = self.buffer.len;
        // 4 dummy bytes for backpatched array length
        try self.buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 });

        // Elements must be aligned to their own type alignment
        if (elem_sig.len > 0) {
            const elem_align = types.getAlignment(elem_sig[0]);
            const pad = types.paddingRequired(self.buffer.len, elem_align);
            if (pad > 0) {
                try self.buffer.appendNTimes(0, pad);
            }
        }
        const content_start = self.buffer.len;

        return MessageBuilder{
            .buffer = self.buffer,
            .sig_buffer = null,
            .container_type = .array,
            .array_len_pos = len_pos,
            .array_content_start = content_start,
        };
    }

    /// Opens a dictionary entry ('{...}').
    pub fn openDictEntry(self: *MessageBuilder) !MessageBuilder {
        // Dict entry requires 8-byte alignment
        try self.padTo(8);
        return MessageBuilder{
            .buffer = self.buffer,
            .sig_buffer = null,
            .container_type = .dict_entry,
        };
    }

    /// Closes an open container and writes length fixups.
    pub fn closeContainer(self: *MessageBuilder, sub: *MessageBuilder) !void {
        _ = self;
        if (sub.container_type == .array) {
            const content_len: u32 = @intCast(sub.buffer.len - sub.array_content_start);
            std.mem.writeInt(u32, sub.buffer.data[sub.array_len_pos..][0..4], content_len, .little);
        }
    }

    // ========================================================================
    // Ergonomic BlueZ helpers (dictionary entries)
    // ========================================================================

    /// Appends a string {s, s} as a variant into an {sv} dictionary.
    pub fn appendDictString(self: *MessageBuilder, key: [:0]const u8, val: [:0]const u8) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("s");
        try v.appendString(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends an object path {s, o} as a variant into an {sv} dictionary.
    pub fn appendDictObjectPath(self: *MessageBuilder, key: [:0]const u8, path: [:0]const u8) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("o");
        try v.appendObjectPath(path);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a boolean {s, b} as a variant into an {sv} dictionary.
    pub fn appendDictBool(self: *MessageBuilder, key: [:0]const u8, val: bool) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("b");
        try v.appendBool(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a byte {s, y} as a variant into an {sv} dictionary.
    pub fn appendDictByte(self: *MessageBuilder, key: [:0]const u8, val: u8) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("y");
        try v.appendByte(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a uint16 {s, q} as a variant into an {sv} dictionary.
    pub fn appendDictUInt16(self: *MessageBuilder, key: [:0]const u8, val: u16) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("q");
        try v.appendUInt16(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends an int16 {s, n} as a variant into an {sv} dictionary.
    pub fn appendDictInt16(self: *MessageBuilder, key: [:0]const u8, val: i16) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("n");
        try v.appendInt16(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a uint32 {s, u} as a variant into an {sv} dictionary.
    pub fn appendDictUInt32(self: *MessageBuilder, key: [:0]const u8, val: u32) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("u");
        try v.appendUInt32(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a uint64 {s, t} as a variant into an {sv} dictionary.
    pub fn appendDictUInt64(self: *MessageBuilder, key: [:0]const u8, val: u64) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("t");
        try v.appendUInt64(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends an int64 {s, x} as a variant into an {sv} dictionary.
    pub fn appendDictInt64(self: *MessageBuilder, key: [:0]const u8, val: i64) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("x");
        try v.appendInt64(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a double {s, d} as a variant into an {sv} dictionary.
    pub fn appendDictDouble(self: *MessageBuilder, key: [:0]const u8, val: f64) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("d");
        try v.appendDouble(val);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a Unix FD {s, h} as a variant into an {sv} dictionary.
    pub fn appendDictUnixFd(self: *MessageBuilder, key: [:0]const u8, fd_index: u32) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("h");
        try v.appendUnixFd(fd_index);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a byte array {s, ay} as a variant into an {sv} dictionary.
    pub fn appendDictBytes(self: *MessageBuilder, key: [:0]const u8, bytes: []const u8) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("ay");
        try v.appendBytes(bytes);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }

    /// Appends a string array {s, as} as a variant into an {sv} dictionary.
    pub fn appendDictStringArray(self: *MessageBuilder, key: [:0]const u8, strings: []const [:0]const u8) !void {
        var entry = try self.openDictEntry();
        try entry.appendString(key);
        var v = try entry.openVariant("as");
        var arr = try v.openArray("s");
        for (strings) |s| {
            try arr.appendString(s);
        }
        try v.closeContainer(&arr);
        try entry.closeContainer(&v);
        try self.closeContainer(&entry);
    }
};

test "MessageBuilder serialize primitives" {
    var buf = ByteBuffer.init(std.testing.allocator);
    defer buf.deinit();

    var builder = MessageBuilder.init(&buf, null);
    try builder.appendString("Hello");
    try builder.appendUInt32(42);

    try std.testing.expect(buf.len > 0);
}

test "MessageBuilder and MessageIter all wire types roundtrip" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    try builder.appendByte(0xAB);
    try builder.appendBool(true);
    try builder.appendInt16(-1234);
    try builder.appendUInt16(5678);
    try builder.appendInt32(-100_000);
    try builder.appendUInt32(200_000);
    try builder.appendInt64(-9876543210123);
    try builder.appendUInt64(12345678901234);
    try builder.appendDouble(3.141592653589793);
    try builder.appendUnixFd(3);
    try builder.appendString("test_wire");
    try builder.appendObjectPath("/org/bluez/test");

    try std.testing.expectEqualStrings("ybnqiuxtdhso", sig_buf.getSlice());

    var iter = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    try std.testing.expectEqual(@as(?u8, 0xAB), iter.getByte());
    try std.testing.expectEqual(@as(?bool, true), iter.getBool());
    try std.testing.expectEqual(@as(?i16, -1234), iter.getInt16());
    try std.testing.expectEqual(@as(?u16, 5678), iter.getUInt16());
    try std.testing.expectEqual(@as(?i32, -100_000), iter.getInt32());
    try std.testing.expectEqual(@as(?u32, 200_000), iter.getUInt32());
    try std.testing.expectEqual(@as(?i64, -9876543210123), iter.getInt64());
    try std.testing.expectEqual(@as(?u64, 12345678901234), iter.getUInt64());
    try std.testing.expectApproxEqAbs(@as(f64, 3.141592653589793), iter.getDouble().?, 0.000000000001);
    try std.testing.expectEqual(@as(?u32, 3), iter.getUnixFdIndex());
    try std.testing.expectEqualStrings("test_wire", iter.getString().?);
    try std.testing.expectEqualStrings("/org/bluez/test", iter.getObjectPath().?);
}

test "MessageBuilder and MessageIter struct and dict roundtrip" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    var dict = try builder.openArray("{sv}");
    try dict.appendDictInt64("LargeNegative", -5000000000);
    try dict.appendDictUInt64("LargePositive", 9000000000);
    try dict.appendDictDouble("Ratio", 42.5);
    try dict.appendDictUnixFd("Handle", 7);
    try builder.closeContainer(&dict);

    try std.testing.expectEqualStrings("a{sv}", sig_buf.getSlice());

    var iter = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    var array_it = iter.openArray().?;

    // Entry 1
    var e1 = array_it.openDictEntry().?;
    try std.testing.expectEqualStrings("LargeNegative", e1.getString().?);
    var v1 = e1.getVariant().?;
    try std.testing.expectEqual(@as(?i64, -5000000000), v1.getInt64());
    _ = array_it.next();

    // Entry 2
    var e2 = array_it.openDictEntry().?;
    try std.testing.expectEqualStrings("LargePositive", e2.getString().?);
    var v2 = e2.getVariant().?;
    try std.testing.expectEqual(@as(?u64, 9000000000), v2.getUInt64());
    _ = array_it.next();

    // Entry 3
    var e3 = array_it.openDictEntry().?;
    try std.testing.expectEqualStrings("Ratio", e3.getString().?);
    var v3 = e3.getVariant().?;
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), v3.getDouble().?, 0.0001);
    _ = array_it.next();

    // Entry 4
    var e4 = array_it.openDictEntry().?;
    try std.testing.expectEqualStrings("Handle", e4.getString().?);
    var v4 = e4.getVariant().?;
    try std.testing.expectEqual(@as(?u32, 7), v4.getUnixFdIndex());
}

test "MessageBuilder and MessageIter struct container roundtrip" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    var st = try builder.openStruct("(su)");
    try st.appendString("device");
    try st.appendUInt32(100);
    try builder.closeContainer(&st);

    try std.testing.expectEqualStrings("(su)", sig_buf.getSlice());

    var iter = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    var st_it = iter.openStruct().?;
    try std.testing.expectEqualStrings("device", st_it.getString().?);
    try std.testing.expectEqual(@as(?u32, 100), st_it.getUInt32());
}

test "MessageBuilder: Empty array preserves element alignment padding per D-Bus spec" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    // Write empty options dictionary a{sv} (each element {sv} requires 8-byte alignment)
    var opts = try builder.openArray("{sv}");
    try builder.closeContainer(&opts);

    // D-Bus spec: "The alignment padding for the first element is required even if the array is empty (where n is zero)."
    // Array length is a 4-byte integer = 0, followed by 4 bytes of padding to align the first element to 8 bytes.
    try std.testing.expectEqual(@as(usize, 8), body_buf.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body_buf.getSlice()[0..4], .little));

    // Append subsequent string "BlueZ"
    try builder.appendString("BlueZ");
    try std.testing.expectEqualStrings("a{sv}s", sig_buf.getSlice());
    // 4 bytes (array len = 0) + 4 bytes (alignment pad) + 4 bytes (str len = 5) + 5 bytes ("BlueZ") + 1 null byte = 18 bytes total
    try std.testing.expectEqual(@as(usize, 18), body_buf.len);

    // Read back with openArray and getString
    var it1 = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    var arr1 = it1.openArray().?;
    try std.testing.expect(!arr1.hasMore());
    const str1 = it1.getString().?;
    try std.testing.expectEqualStrings("BlueZ", str1);

    // Read back with skipCurrent (via next()) and getString
    var it2 = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    try std.testing.expect(it2.next());
    const str2 = it2.getString().?;
    try std.testing.expectEqualStrings("BlueZ", str2);
}

test "MessageBuilder: Empty array between arguments roundtrip (sa{sv}u)" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    try builder.appendString("path");
    var opts = try builder.openArray("{sv}");
    try builder.closeContainer(&opts);
    try builder.appendUInt32(0xCAFEBABE);

    try std.testing.expectEqualStrings("sa{sv}u", sig_buf.getSlice());

    var it = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    try std.testing.expectEqualStrings("path", it.getString().?);
    var arr = it.openArray().?;
    try std.testing.expect(!arr.hasMore());
    try std.testing.expectEqual(@as(?u32, 0xCAFEBABE), it.getUInt32());
}

test "MessageBuilder: Non-empty array preserves alignment and roundtrips" {
    var body_buf = ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    const reader_mod = @import("reader.zig");

    var builder = MessageBuilder.init(&body_buf, &sig_buf);
    var opts = try builder.openArray("{sv}");
    try opts.appendDictString("key", "val");
    try builder.closeContainer(&opts);
    try builder.appendUInt32(12345);

    try std.testing.expectEqualStrings("a{sv}u", sig_buf.getSlice());

    var it = reader_mod.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    var arr = it.openArray().?;
    try std.testing.expect(arr.hasMore());
    var entry = arr.openDictEntry().?;
    try std.testing.expectEqualStrings("key", entry.getString().?);
    var v = entry.getVariant().?;
    try std.testing.expectEqualStrings("val", v.getString().?);
    _ = arr.next();
    try std.testing.expect(!arr.hasMore());

    try std.testing.expectEqual(@as(?u32, 12345), it.getUInt32());
}



