//! D-Bus Wire Protocol Header Parsing & Calculations
//! Strictly conforms to D-Bus Specification v0.30+ (8-byte body alignment guarantees)

const std = @import("std");
const types = @import("types.zig");
const Type = types.Type;
const MessageType = types.MessageType;
const HeaderField = types.HeaderField;

/// Fixed 16-byte header of every D-Bus message
pub const FixedHeader = extern struct {
    endianness: u8 = 'l', // 'l' = Little-Endian, 'B' = Big-Endian
    msg_type: MessageType,
    flags: u8 = 0,
    proto_version: u8 = 1,
    body_len: u32,
    serial: u32,
    fields_len: u32,

    pub const encoded_size: usize = 16;

    pub fn decode(bytes: *const [16]u8) !FixedHeader {
        const endianness = bytes[0];
        if (endianness != 'l' and endianness != 'B') {
            return error.InvalidEndianness;
        }

        const endian: std.builtin.Endian = if (endianness == 'l') .little else .big;

        const raw_type = bytes[1];
        if (raw_type < 1 or raw_type > 4) {
            return error.InvalidMessageType;
        }

        const proto_version = bytes[3];
        if (proto_version != 1) {
            return error.UnsupportedProtocolVersion;
        }

        return FixedHeader{
            .endianness = endianness,
            .msg_type = @enumFromInt(raw_type),
            .flags = bytes[2],
            .proto_version = proto_version,
            .body_len = std.mem.readInt(u32, bytes[4..8], endian),
            .serial = std.mem.readInt(u32, bytes[8..12], endian),
            .fields_len = std.mem.readInt(u32, bytes[12..16], endian),
        };
    }

    pub fn encode(self: FixedHeader, dest: *[16]u8) void {
        dest[0] = self.endianness;
        dest[1] = @intFromEnum(self.msg_type);
        dest[2] = self.flags;
        dest[3] = self.proto_version;
        // Always natively encode in Little-Endian ('l')
        std.mem.writeInt(u32, dest[4..8], self.body_len, .little);
        std.mem.writeInt(u32, dest[8..12], self.serial, .little);
        std.mem.writeInt(u32, dest[12..16], self.fields_len, .little);
    }
};

/// Computes the number of padding bytes between header fields and the message body.
/// The body MUST begin at an 8-byte aligned offset relative to byte 0 of the message!
pub inline fn calcHeaderPadding(fields_len: u32) usize {
    return (8 - (fields_len % 8)) % 8;
}

/// Computes the absolute byte offset where the body begins (always 8-byte aligned).
pub inline fn calcBodyOffset(fields_len: u32) usize {
    return FixedHeader.encoded_size + fields_len + calcHeaderPadding(fields_len);
}

/// Computes total message size in wire format (header + fields + padding + body).
pub inline fn calcTotalMessageSize(fields_len: u32, body_len: u32) usize {
    return calcBodyOffset(fields_len) + body_len;
}

/// Extracted standard header fields for fast zero-copy access
pub const HeaderFields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    unix_fds: ?u32 = null,

    /// Parses variable header fields a(yv) from buffer [16 .. 16 + fields_len].
    pub fn parse(msg_bytes: []const u8, fields_len: u32) !HeaderFields {
        var hf = HeaderFields{};
        if (msg_bytes.len < FixedHeader.encoded_size + fields_len) {
            return error.BufferTooSmall;
        }

        var offset: usize = FixedHeader.encoded_size;
        const end_offset = offset + fields_len;

        while (offset < end_offset) {
            // Each struct (yv) in the array must be aligned to 8 bytes (relative to message start)
            offset = types.alignOffset(offset, 8);
            if (offset >= end_offset) break;

            const field_code = msg_bytes[offset];
            offset += 1;
            if (offset >= end_offset) return error.MalformedHeaderField;

            // Variant signature length
            const sig_len = msg_bytes[offset];
            offset += 1;
            if (offset + sig_len >= end_offset) return error.MalformedHeaderField;

            const sig = msg_bytes[offset .. offset + sig_len];
            offset += sig_len;

            // Skip signature null terminator
            if (offset >= end_offset or msg_bytes[offset] != 0) return error.MalformedHeaderField;
            offset += 1;

            if (sig.len == 0) return error.MalformedHeaderField;
            const val_type = sig[0];

            // Alignment for variant value
            const val_align = types.getAlignment(val_type);
            offset = types.alignOffset(offset, val_align);

            switch (field_code) {
                HeaderField.path => {
                    if (val_type != Type.object_path) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.path = val;
                },
                HeaderField.interface => {
                    if (val_type != Type.string) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.interface = val;
                },
                HeaderField.member => {
                    if (val_type != Type.string) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.member = val;
                },
                HeaderField.error_name => {
                    if (val_type != Type.string) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.error_name = val;
                },
                HeaderField.reply_serial => {
                    if (val_type != Type.uint32) return error.InvalidHeaderFieldType;
                    if (offset + 4 > end_offset) return error.MalformedHeaderField;
                    hf.reply_serial = std.mem.readInt(u32, msg_bytes[offset..][0..4], .little);
                    offset += 4;
                },
                HeaderField.destination => {
                    if (val_type != Type.string) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.destination = val;
                },
                HeaderField.sender => {
                    if (val_type != Type.string) return error.InvalidHeaderFieldType;
                    const val = try readStringSlice(msg_bytes, &offset, end_offset);
                    hf.sender = val;
                },
                HeaderField.signature => {
                    if (val_type != Type.signature) return error.InvalidHeaderFieldType;
                    if (offset >= end_offset) return error.MalformedHeaderField;
                    const slen = msg_bytes[offset];
                    offset += 1;
                    if (offset + slen >= end_offset) return error.MalformedHeaderField;
                    hf.signature = msg_bytes[offset .. offset + slen];
                    offset += slen;
                    if (offset >= end_offset or msg_bytes[offset] != 0) return error.MalformedHeaderField;
                    offset += 1;
                },
                HeaderField.unix_fds => {
                    if (val_type != Type.uint32) return error.InvalidHeaderFieldType;
                    if (offset + 4 > end_offset) return error.MalformedHeaderField;
                    hf.unix_fds = std.mem.readInt(u32, msg_bytes[offset..][0..4], .little);
                    offset += 4;
                },
                else => {
                    // Skip unknown header field:
                    // If string or object path:
                    if (val_type == Type.string or val_type == Type.object_path) {
                        _ = try readStringSlice(msg_bytes, &offset, end_offset);
                    } else if (val_type == Type.uint32 or val_type == Type.boolean) {
                        offset += 4;
                    } else if (val_type == Type.uint64) {
                        offset += 8;
                    } else {
                        // Unknown type: return parsed fields so far
                        return hf;
                    }
                },
            }
        }

        return hf;
    }

    fn readStringSlice(bytes: []const u8, offset_ptr: *usize, max_offset: usize) ![]const u8 {
        var off = offset_ptr.*;
        if (off + 4 > max_offset) return error.MalformedHeaderField;
        const str_len = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;

        if (off + str_len >= max_offset) return error.MalformedHeaderField;
        const slice = bytes[off .. off + str_len];
        off += str_len;

        // Verify null terminator
        if (off >= max_offset or bytes[off] != 0) return error.MalformedHeaderField;
        off += 1;

        offset_ptr.* = off;
        return slice;
    }
};

test "D-Bus Header Body Alignment & Padding" {
    // When fields_len = 80: 16 + 80 = 96 (divisible by 8) -> padding = 0
    try std.testing.expectEqual(@as(usize, 0), calcHeaderPadding(80));
    try std.testing.expectEqual(@as(usize, 96), calcBodyOffset(80));

    // When fields_len = 83: 16 + 83 = 99 -> padding = 5, body at 104 (divisible by 8)
    try std.testing.expectEqual(@as(usize, 5), calcHeaderPadding(83));
    try std.testing.expectEqual(@as(usize, 104), calcBodyOffset(83));

    // When fields_len = 0: 16 + 0 = 16 -> padding = 0, body at 16
    try std.testing.expectEqual(@as(usize, 0), calcHeaderPadding(0));
    try std.testing.expectEqual(@as(usize, 16), calcBodyOffset(0));
}
