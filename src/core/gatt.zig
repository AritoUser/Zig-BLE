const std = @import("std");
const types = @import("types.zig");
const UUID = types.UUID;
const assigned_numbers = @import("assigned_numbers.zig");

/// GATT Service Type (Primary vs. Secondary).
pub const ServiceType = enum {
    primary,
    secondary,

    pub fn toString(self: ServiceType) []const u8 {
        return switch (self) {
            .primary => "primary",
            .secondary => "secondary",
        };
    }
};

/// GATT Write Type (with or without response).
pub const WriteType = enum {
    /// ATT Write Request: The peripheral acknowledges the write with a Write Response.
    with_response,
    /// ATT Write Command: Fast write without acknowledgement (high throughput).
    without_response,
};

/// Characteristic Properties according to Bluetooth Core Specification (Vol 3, Part G, Section 3.3.1.1).
/// Exactly 1 byte (bitfield).
pub const CharacteristicProperties = packed struct(u8) {
    /// Bit 0 (0x01): Value permitted in server advertising / broadcast.
    broadcast: bool = false,
    /// Bit 1 (0x02): Value may be read via ATT Read Request.
    read: bool = false,
    /// Bit 2 (0x04): Value may be written via ATT Write Command (without response).
    write_without_response: bool = false,
    /// Bit 3 (0x08): Value may be written via ATT Write Request (with response).
    write: bool = false,
    /// Bit 4 (0x10): Server may send notifications (unacknowledged).
    notify: bool = false,
    /// Bit 5 (0x20): Server may send indications (acknowledged with ATT confirmation).
    indicate: bool = false,
    /// Bit 6 (0x40): Authenticated signed writes allowed.
    authenticated_signed_writes: bool = false,
    /// Bit 7 (0x80): Additional properties in the Characteristic Extended Properties Descriptor.
    extended_properties: bool = false,

    /// Converts the flags into a raw byte.
    pub fn toByte(self: CharacteristicProperties) u8 {
        return @bitCast(self);
    }

    /// Constructs properties from a raw byte.
    pub fn fromByte(byte: u8) CharacteristicProperties {
        return @bitCast(byte);
    }

    /// Parses a single BlueZ flag string and updates the properties.
    /// Uses O(1) length dispatching: Each BlueZ flag has a unique string length.
    pub fn parseBluezFlag(self: *CharacteristicProperties, flag: []const u8) void {
        switch (flag.len) {
            4 => if (std.mem.eql(u8, flag, "read")) {
                self.read = true;
            },
            5 => if (std.mem.eql(u8, flag, "write")) {
                self.write = true;
            },
            6 => if (std.mem.eql(u8, flag, "notify")) {
                self.notify = true;
            },
            8 => if (std.mem.eql(u8, flag, "indicate")) {
                self.indicate = true;
            },
            9 => if (std.mem.eql(u8, flag, "broadcast")) {
                self.broadcast = true;
            },
            19 => if (std.mem.eql(u8, flag, "extended-properties")) {
                self.extended_properties = true;
            },
            22 => if (std.mem.eql(u8, flag, "write-without-response")) {
                self.write_without_response = true;
            },
            27 => if (std.mem.eql(u8, flag, "authenticated-signed-writes")) {
                self.authenticated_signed_writes = true;
            },
            else => {},
        }
    }

    /// Converts BlueZ D-Bus string flags (e.g. ["read", "write", "notify"]) into a type-safe bitset.
    pub fn fromBluezFlags(flags: []const []const u8) CharacteristicProperties {
        var props = CharacteristicProperties{};
        for (flags) |flag| {
            props.parseBluezFlag(flag);
        }
        return props;
    }

    /// Checks if any form of writing is supported.
    pub fn canWrite(self: CharacteristicProperties) bool {
        return self.write or self.write_without_response or self.authenticated_signed_writes;
    }

    /// Checks if live subscription updates are supported (Notify or Indicate).
    pub fn canSubscribe(self: CharacteristicProperties) bool {
        return self.notify or self.indicate;
    }
};

/// Client Characteristic Configuration Descriptor (CCCD, UUID 0x2902).
/// Standardized 16-bit bitfield per Bluetooth Core Spec (Vol 3, Part G, Section 3.3.3.3).
pub const Cccd = packed struct(u16) {
    /// Bit 0 (0x0001): Notifications enabled.
    notifications: bool = false,
    /// Bit 1 (0x0002): Indications enabled.
    indications: bool = false,
    /// Bits 2..15: Reserved (must be 0).
    _reserved: u14 = 0,

    pub const NONE = Cccd{};
    pub const NOTIFY = Cccd{ .notifications = true };
    pub const INDICATE = Cccd{ .indications = true };
    pub const BOTH = Cccd{ .notifications = true, .indications = true };

    /// Encodes the CCCD value for transmission over the ATT protocol (2 bytes little-endian).
    pub fn encode(self: Cccd) [2]u8 {
        const val: u16 = @bitCast(self);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, val, .little);
        return bytes;
    }

    /// Decodes the CCCD value from received ATT bytes (2 bytes little-endian).
    pub fn decode(bytes: [2]u8) Cccd {
        const val = std.mem.readInt(u16, &bytes, .little);
        return @bitCast(val);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "CharacteristicProperties bitcast and methods" {
    var props = CharacteristicProperties{
        .read = true,
        .write = true,
        .notify = true,
    };

    const byte = props.toByte();
    // read (0x02) | write (0x08) | notify (0x10) = 0x1A
    try std.testing.expectEqual(@as(u8, 0x1A), byte);

    const from_byte = CharacteristicProperties.fromByte(byte);
    try std.testing.expect(from_byte.read);
    try std.testing.expect(from_byte.write);
    try std.testing.expect(from_byte.notify);
    try std.testing.expect(!from_byte.indicate);
    try std.testing.expect(!from_byte.broadcast);

    try std.testing.expect(props.canWrite());
    try std.testing.expect(props.canSubscribe());
}

test "CharacteristicProperties from BlueZ flags" {
    const bluez_flags = [_][]const u8{ "read", "write-without-response", "notify" };
    const props = CharacteristicProperties.fromBluezFlags(&bluez_flags);

    try std.testing.expect(props.read);
    try std.testing.expect(props.write_without_response);
    try std.testing.expect(!props.write);
    try std.testing.expect(props.notify);
    try std.testing.expect(!props.indicate);
    try std.testing.expect(props.canWrite());
}

test "Cccd encoding and decoding" {
    const cccd = Cccd.NOTIFY;
    const encoded = cccd.encode();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00 }, &encoded);

    const decoded = Cccd.decode(encoded);
    try std.testing.expect(decoded.notifications);
    try std.testing.expect(!decoded.indications);

    const both = Cccd.BOTH;
    const both_enc = both.encode();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, &both_enc);
    const both_dec = Cccd.decode(both_enc);
    try std.testing.expect(both_dec.notifications and both_dec.indications);
}
