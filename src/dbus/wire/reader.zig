//! Zero-Copy D-Bus Wire Message Reader & MessageIter
//! Parses D-Bus payloads directly from the socket buffer with zero heap allocations.

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;

/// Parses the signature of exactly one complete D-Bus type (including nested containers).
pub fn parseSingleType(sig: []const u8) []const u8 {
    if (sig.len == 0) return "";
    var i: usize = 0;
    while (i < sig.len and sig[i] == Type.array) : (i += 1) {}
    if (i >= sig.len) return sig;

    if (sig[i] == Type.struct_begin) {
        var depth: usize = 1;
        i += 1;
        while (i < sig.len and depth > 0) : (i += 1) {
            if (sig[i] == Type.struct_begin) depth += 1;
            if (sig[i] == Type.struct_end) depth -= 1;
        }
        return sig[0..i];
    } else if (sig[i] == Type.dict_entry_begin) {
        var depth: usize = 1;
        i += 1;
        while (i < sig.len and depth > 0) : (i += 1) {
            if (sig[i] == Type.dict_entry_begin) depth += 1;
            if (sig[i] == Type.dict_entry_end) depth -= 1;
        }
        return sig[0..i];
    } else {
        return sig[0 .. i + 1];
    }
}

/// Zero-copy iterator over D-Bus message arguments.
pub const MessageIter = struct {
    buf: []const u8,
    offset: usize,
    end_offset: usize,
    sig: []const u8,
    sig_idx: usize = 0,
    is_array: bool = false,
    endian: std.builtin.Endian = .little,

    pub fn init(buf: []const u8, start_offset: usize, end_offset: usize, sig: []const u8) MessageIter {
        return initEndian(buf, start_offset, end_offset, sig, .little);
    }

    pub fn initEndian(buf: []const u8, start_offset: usize, end_offset: usize, sig: []const u8, endian: std.builtin.Endian) MessageIter {
        return MessageIter{
            .buf = buf,
            .offset = start_offset,
            .end_offset = end_offset,
            .sig = sig,
            .sig_idx = 0,
            .is_array = false,
            .endian = endian,
        };
    }

    /// Returns the current argument type code (e.g. 's', 'u', 'v', 'a', '{').
    pub fn getArgType(self: *const MessageIter) u8 {
        if (self.offset >= self.end_offset) return Type.invalid;
        if (self.is_array) {
            // In an array, argument type matches the element type of the array signature
            if (self.sig.len > 0) return self.sig[0];
            return Type.invalid;
        }
        if (self.sig_idx >= self.sig.len) return Type.invalid;
        return self.sig[self.sig_idx];
    }

    pub fn hasMore(self: *const MessageIter) bool {
        return self.getArgType() != Type.invalid;
    }

    /// Advances to the next element or argument.
    pub fn next(self: *MessageIter) bool {
        if (!self.hasMore()) return false;

        // If the current element was not read yet, skip it:
        self.skipCurrent();

        if (self.is_array) {
            return self.offset < self.end_offset;
        } else {
            const current_type_sig = parseSingleType(self.sig[self.sig_idx..]);
            self.sig_idx += current_type_sig.len;
            return self.sig_idx < self.sig.len and self.offset < self.end_offset;
        }
    }

    /// Skips the current element if it was not consumed.
    fn skipCurrent(self: *MessageIter) void {
        const t = self.getArgType();
        switch (t) {
            Type.byte => {
                if (self.offset < self.end_offset) self.offset += 1;
            },
            Type.boolean, Type.int32, Type.uint32, Type.unix_fd => {
                self.offset = types.alignOffset(self.offset, 4);
                if (self.offset + 4 <= self.end_offset) self.offset += 4;
            },
            Type.int16, Type.uint16 => {
                self.offset = types.alignOffset(self.offset, 2);
                if (self.offset + 2 <= self.end_offset) self.offset += 2;
            },
            Type.int64, Type.uint64, Type.double => {
                self.offset = types.alignOffset(self.offset, 8);
                if (self.offset + 8 <= self.end_offset) self.offset += 8;
            },
            Type.string, Type.object_path => {
                self.offset = types.alignOffset(self.offset, 4);
                if (self.offset + 4 <= self.end_offset) {
                    const len = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
                    self.offset += 4 + len + 1; // +1 for null terminator
                }
            },
            Type.signature => {
                if (self.offset < self.end_offset) {
                    const len = self.buf[self.offset];
                    self.offset += 1 + len + 1;
                }
            },
            Type.array => {
                self.offset = types.alignOffset(self.offset, 4);
                if (self.offset + 4 <= self.end_offset) {
                    const len = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
                    self.offset += 4;
                    // Take alignment of first element into account
                    const elem_sig = parseSingleType(self.sig[self.sig_idx + 1 ..]);
                    if (elem_sig.len > 0) {
                        self.offset = types.alignOffset(self.offset, types.getAlignment(elem_sig[0]));
                    }
                    self.offset += len;
                }
            },
            Type.variant => {
                if (self.offset < self.end_offset) {
                    const sig_len = self.buf[self.offset];
                    self.offset += 1;
                    const val_sig = self.buf[self.offset .. self.offset + sig_len];
                    self.offset += sig_len + 1; // + null terminator
                    if (val_sig.len > 0) {
                        self.offset = types.alignOffset(self.offset, types.getAlignment(val_sig[0]));
                        var sub = MessageIter.initEndian(self.buf, self.offset, self.end_offset, val_sig, self.endian);
                        sub.skipCurrent();
                        self.offset = sub.offset;
                    }
                }
            },
            Type.dict_entry_begin, Type.struct_begin => {
                self.offset = types.alignOffset(self.offset, 8);
                // Open child iterator and traverse
                if (self.recurse()) |sub_val| {
                    var sub = sub_val;
                    while (sub.hasMore()) {
                        _ = sub.next();
                    }
                    self.offset = sub.offset;
                }
            },
            else => {},
        }
    }

    /// Opens nested containers (array, variant, dict entry, struct).
    pub fn recurse(self: *MessageIter) ?MessageIter {
        const t = self.getArgType();
        switch (t) {
            Type.variant => {
                if (self.offset >= self.end_offset) return null;
                const sig_len = self.buf[self.offset];
                self.offset += 1;
                if (self.offset + sig_len >= self.end_offset) return null;
                const inner_sig = self.buf[self.offset .. self.offset + sig_len];
                self.offset += sig_len;
                if (self.offset >= self.end_offset or self.buf[self.offset] != 0) return null;
                self.offset += 1; // null terminator

                if (inner_sig.len == 0) return null;
                const align_val = types.getAlignment(inner_sig[0]);
                self.offset = types.alignOffset(self.offset, align_val);

                return MessageIter.initEndian(self.buf, self.offset, self.end_offset, inner_sig, self.endian);
            },
            Type.array => {
                self.offset = types.alignOffset(self.offset, 4);
                if (self.offset + 4 > self.end_offset) return null;
                const array_byte_len = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
                self.offset += 4;

                const elem_sig = parseSingleType(self.sig[self.sig_idx + 1 ..]);
                if (elem_sig.len == 0) return null;

                const elem_align = types.getAlignment(elem_sig[0]);
                const content_start = types.alignOffset(self.offset, elem_align);
                const content_end = content_start + array_byte_len;

                self.offset = content_end;

                var it = MessageIter.initEndian(self.buf, content_start, content_end, elem_sig, self.endian);
                it.is_array = true;
                return it;
            },
            Type.dict_entry_begin => {
                self.offset = types.alignOffset(self.offset, 8);
                // Signature within { ... }
                const entry_sig = parseSingleType(self.sig[self.sig_idx..]);
                if (entry_sig.len < 3) return null;
                const inner_sig = entry_sig[1 .. entry_sig.len - 1]; // without '{' and '}'

                return MessageIter.initEndian(self.buf, self.offset, self.end_offset, inner_sig, self.endian);
            },
            Type.struct_begin => {
                self.offset = types.alignOffset(self.offset, 8);
                const struct_sig = parseSingleType(self.sig[self.sig_idx..]);
                if (struct_sig.len < 2) return null;
                const inner_sig = struct_sig[1 .. struct_sig.len - 1];

                return MessageIter.initEndian(self.buf, self.offset, self.end_offset, inner_sig, self.endian);
            },
            else => return null,
        }
    }

    /// Reads a string ('s').
    pub fn getString(self: *MessageIter) ?[:0]const u8 {
        if (self.getArgType() != Type.string and self.getArgType() != Type.object_path) return null;
        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const len = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
        self.offset += 4;

        if (self.offset + len >= self.end_offset) return null;
        if (self.buf[self.offset + len] != 0) return null;
        const str = self.buf[self.offset .. self.offset + len :0];
        self.offset += len + 1;

        if (!self.is_array) {
            self.sig_idx += 1;
        }

        return str;
    }

    pub fn getObjectPath(self: *MessageIter) ?[:0]const u8 {
        return self.getString();
    }

    /// Reads a single byte ('y').
    pub fn getByte(self: *MessageIter) ?u8 {
        if (self.getArgType() != Type.byte) return null;
        if (self.offset >= self.end_offset) return null;
        const val = self.buf[self.offset];
        self.offset += 1;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads a boolean ('b').
    pub fn getBool(self: *MessageIter) ?bool {
        if (self.getArgType() != Type.boolean) return null;
        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const val = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
        self.offset += 4;
        if (!self.is_array) self.sig_idx += 1;
        return val != 0;
    }

    /// Reads a uint16 ('q').
    pub fn getUInt16(self: *MessageIter) ?u16 {
        if (self.getArgType() != Type.uint16) return null;
        self.offset = types.alignOffset(self.offset, 2);
        if (self.offset + 2 > self.end_offset) return null;
        const val = std.mem.readInt(u16, self.buf[self.offset..][0..2], self.endian);
        self.offset += 2;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads an int16 ('n').
    pub fn getInt16(self: *MessageIter) ?i16 {
        if (self.getArgType() != Type.int16) return null;
        self.offset = types.alignOffset(self.offset, 2);
        if (self.offset + 2 > self.end_offset) return null;
        const val = @as(i16, @bitCast(std.mem.readInt(u16, self.buf[self.offset..][0..2], self.endian)));
        self.offset += 2;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads a uint32 ('u').
    pub fn getUInt32(self: *MessageIter) ?u32 {
        if (self.getArgType() != Type.uint32) return null;
        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const val = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
        self.offset += 4;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads an int32 ('i').
    pub fn getInt32(self: *MessageIter) ?i32 {
        if (self.getArgType() != Type.int32) return null;
        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const val = @as(i32, @bitCast(std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian)));
        self.offset += 4;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads a uint64 ('t').
    pub fn getUInt64(self: *MessageIter) ?u64 {
        if (self.getArgType() != Type.uint64) return null;
        self.offset = types.alignOffset(self.offset, 8);
        if (self.offset + 8 > self.end_offset) return null;
        const val = std.mem.readInt(u64, self.buf[self.offset..][0..8], self.endian);
        self.offset += 8;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads an int64 ('x').
    pub fn getInt64(self: *MessageIter) ?i64 {
        if (self.getArgType() != Type.int64) return null;
        self.offset = types.alignOffset(self.offset, 8);
        if (self.offset + 8 > self.end_offset) return null;
        const val = @as(i64, @bitCast(std.mem.readInt(u64, self.buf[self.offset..][0..8], self.endian)));
        self.offset += 8;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads a double ('d') with 8-byte alignment.
    pub fn getDouble(self: *MessageIter) ?f64 {
        if (self.getArgType() != Type.double) return null;
        self.offset = types.alignOffset(self.offset, 8);
        if (self.offset + 8 > self.end_offset) return null;
        const bits = std.mem.readInt(u64, self.buf[self.offset..][0..8], self.endian);
        const val: f64 = @bitCast(bits);
        self.offset += 8;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads the 32-bit index of a Unix file descriptor ('h').
    pub fn getUnixFdIndex(self: *MessageIter) ?u32 {
        if (self.getArgType() != Type.unix_fd) return null;
        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const val = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
        self.offset += 4;
        if (!self.is_array) self.sig_idx += 1;
        return val;
    }

    /// Reads a Unix file descriptor ('h') as an index (compatibility alias).
    pub fn getUnixFd(self: *MessageIter) ?i32 {
        if (self.getUnixFdIndex()) |idx| {
            return @intCast(idx);
        }
        return null;
    }

    /// Returns the element type of an array.
    pub fn getElementType(self: *MessageIter) u8 {
        if (self.getArgType() != Type.array) return Type.invalid;
        const elem_sig = parseSingleType(self.sig[self.sig_idx + 1 ..]);
        if (elem_sig.len > 0) return elem_sig[0];
        return Type.invalid;
    }

    /// Reads a contiguous byte array (type 'ay') directly as a zero-copy slice.
    pub fn getFixedBytes(self: *MessageIter) ?[]const u8 {
        if (self.getArgType() != Type.array) return null;
        if (self.getElementType() != Type.byte) return null;

        self.offset = types.alignOffset(self.offset, 4);
        if (self.offset + 4 > self.end_offset) return null;
        const len = std.mem.readInt(u32, self.buf[self.offset..][0..4], self.endian);
        self.offset += 4;

        if (self.offset + len > self.end_offset) return null;
        const slice = self.buf[self.offset .. self.offset + len];
        self.offset += len;

        if (!self.is_array) {
            const arr_sig = parseSingleType(self.sig[self.sig_idx..]);
            self.sig_idx += arr_sig.len;
        }

        return slice;
    }

    /// Unpacks a variant container and yields an iterator over its content.
    pub fn getVariant(self: *MessageIter) ?MessageIter {
        return self.recurse();
    }

    /// Opens a struct container ('(...)') and yields an iterator over its fields.
    pub fn openStruct(self: *MessageIter) ?MessageIter {
        return self.recurse();
    }

    /// Opens a dict-entry container ('{...}') and yields an iterator.
    pub fn openDictEntry(self: *MessageIter) ?MessageIter {
        return self.recurse();
    }

    /// Opens an array container ('a...') and yields an iterator over the elements.
    pub fn openArray(self: *MessageIter) ?MessageIter {
        return self.recurse();
    }
};

test "parseSingleType signature splitting" {
    try std.testing.expectEqualStrings("s", parseSingleType("s"));
    try std.testing.expectEqualStrings("u", parseSingleType("u"));
    try std.testing.expectEqualStrings("as", parseSingleType("as"));
    try std.testing.expectEqualStrings("a{sv}", parseSingleType("a{sv}"));
    try std.testing.expectEqualStrings("a{sa{sv}}", parseSingleType("a{sa{sv}}"));
    try std.testing.expectEqualStrings("a(oa{sa{sv}})", parseSingleType("a(oa{sa{sv}})"));
}

test "MessageIter: Big-Endian decoding & safe sentinel string slicing" {
    // uint32 (0x12345678 in BE) + int16 (-1234 in BE) + string "BlueZ"
    const buf = [_]u8{
        0x12, 0x34, 0x56, 0x78, // uint32
        0xFB, 0x2E,             // int16: -1234 (0xFB2E)
        0x00, 0x00,             // 2 bytes padding to align offset to 4 for string
        0x00, 0x00, 0x00, 0x05, // string length = 5 (BE)
        'B',  'l',  'u',  'e',  'Z', 0x00, // "BlueZ\0"
    };

    var it = MessageIter.initEndian(&buf, 0, buf.len, "uns", .big);
    try std.testing.expectEqual(@as(u32, 0x12345678), it.getUInt32().?);
    try std.testing.expectEqual(@as(i16, -1234), it.getInt16().?);
    const s = it.getString().?;
    try std.testing.expectEqualStrings("BlueZ", s);
    try std.testing.expectEqual(@as(u8, 0), s[5]); // verified sentinel!
}
