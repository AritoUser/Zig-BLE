//! D-Bus Binary Protocol Type System & Constants
//! Specification conforming to freedesktop.org D-Bus Specification v0.30+

const std = @import("std");

/// D-Bus Type Codes
pub const Type = struct {
    pub const invalid: u8 = 0;
    pub const byte: u8 = 'y';
    pub const boolean: u8 = 'b';
    pub const int16: u8 = 'n';
    pub const uint16: u8 = 'q';
    pub const int32: u8 = 'i';
    pub const uint32: u8 = 'u';
    pub const int64: u8 = 'x';
    pub const uint64: u8 = 't';
    pub const double: u8 = 'd';
    pub const string: u8 = 's';
    pub const object_path: u8 = 'o';
    pub const signature: u8 = 'g';
    pub const array: u8 = 'a';
    pub const variant: u8 = 'v';
    pub const struct_begin: u8 = '(';
    pub const struct_end: u8 = ')';
    pub const dict_entry_begin: u8 = '{';
    pub const dict_entry_end: u8 = '}';
    pub const unix_fd: u8 = 'h';
};

/// Returns the required byte alignment for a D-Bus type code.
pub inline fn getAlignment(type_code: u8) usize {
    return switch (type_code) {
        Type.byte, Type.signature, Type.variant => 1,
        Type.int16, Type.uint16 => 2,
        Type.boolean, Type.int32, Type.uint32, Type.unix_fd, Type.string, Type.object_path, Type.array => 4,
        Type.int64, Type.uint64, Type.double, Type.struct_begin, Type.dict_entry_begin => 8,
        else => 1,
    };
}

/// Computes the next aligned offset.
pub inline fn alignOffset(offset: usize, alignment: usize) usize {
    const mask = alignment - 1;
    return (offset + mask) & ~mask;
}

/// Calculates the number of padding bytes required to reach the specified alignment.
pub inline fn paddingRequired(offset: usize, alignment: usize) usize {
    return alignOffset(offset, alignment) - offset;
}

/// D-Bus Message Types (Header Byte 1)
pub const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

/// D-Bus Header Flags (Header Byte 2)
pub const HeaderFlags = struct {
    pub const no_reply_expected: u8 = 0x01;
    pub const no_auto_start: u8 = 0x02;
    pub const allow_interactive_authorization: u8 = 0x04;
};

/// D-Bus Header Field Codes (standard header fields in the a(yv) array)
pub const HeaderField = struct {
    pub const invalid: u8 = 0;
    pub const path: u8 = 1; // Type 'o'
    pub const interface: u8 = 2; // Type 's'
    pub const member: u8 = 3; // Type 's'
    pub const error_name: u8 = 4; // Type 's'
    pub const reply_serial: u8 = 5; // Type 'u'
    pub const destination: u8 = 6; // Type 's'
    pub const sender: u8 = 7; // Type 's'
    pub const signature: u8 = 8; // Type 'g'
    pub const unix_fds: u8 = 9; // Type 'u'
};

test "D-Bus alignment helpers" {
    try std.testing.expectEqual(@as(usize, 0), paddingRequired(0, 8));
    try std.testing.expectEqual(@as(usize, 7), paddingRequired(1, 8));
    try std.testing.expectEqual(@as(usize, 0), paddingRequired(16, 8));
    try std.testing.expectEqual(@as(usize, 1), paddingRequired(3, 4));
    try std.testing.expectEqual(@as(usize, 8), alignOffset(5, 8));
}
