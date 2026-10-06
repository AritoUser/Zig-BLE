//! # BLE Generic Attribute Profile (GATT) & Attribute Protocol (ATT) Engine
//!
//! Provides zero-copy abstractions and standardized data structures for BLE GATT
//! client and server operations strictly conforming to the Bluetooth Core Specification
//! (v5.4 / v6.0, Vol 3, Part F & Part G).
//!
//! ## Memory Safety & Concurrency Guarantees
//! - **Zero-Allocation**: Hot-path packet parsing, notification processing, and CCCD bit manipulation
//!   execute without heap allocations (`no-alloc`). All payloads borrow slices directly from network buffers.
//! - **Alignment & Endianness**: Multi-byte integers (Attribute Handles, CCCD values, UUIDs) are decoded
//!   using explicit Little-Endian semantics (`std.mem.readInt(..., .little)`) to prevent unaligned trap
//!   exceptions on ARM, RISC-V, and MIPS CPUs.

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

/// Alias for CharacteristicProperties conforming to Bluetooth Core Spec v5.4, Vol 3, Part G.
pub const CharacteristicProps = CharacteristicProperties;

/// Standard Attribute Protocol (ATT) Opcodes according to Bluetooth Core Spec v5.4, Vol 3, Part F, Section 3.4.
pub const AttOpcode = enum(u8) {
    error_rsp = 0x01,
    exchange_mtu_req = 0x02,
    exchange_mtu_rsp = 0x03,
    find_info_req = 0x04,
    find_info_rsp = 0x05,
    find_by_type_val_req = 0x06,
    find_by_type_val_rsp = 0x07,
    read_by_type_req = 0x08,
    read_by_type_rsp = 0x09,
    read_req = 0x0A,
    read_rsp = 0x0B,
    read_blob_req = 0x0C,
    read_blob_rsp = 0x0D,
    read_multiple_req = 0x0E,
    read_multiple_rsp = 0x0F,
    read_by_group_type_req = 0x10,
    read_by_group_type_rsp = 0x11,
    write_req = 0x12,
    write_rsp = 0x13,
    write_cmd = 0x52,
    prepare_write_req = 0x16,
    prepare_write_rsp = 0x17,
    execute_write_req = 0x18,
    execute_write_rsp = 0x19,
    handle_value_ntf = 0x1B,
    handle_value_ind = 0x1D,
    handle_value_cfm = 0x1E,
    signed_write_cmd = 0xD2,
    _,
};

/// Error set for ATT and GATT packet parsing.
pub const ParseError = error{
    PayloadTooShort,
    InvalidCrc,
    MalformedUuid,
    BufferOverflow,
    InvalidOpcode,
};

/// Represents an unpacked ATT Handle Value Notification (`ATT_HANDLE_VALUE_NTF`).
pub const NotificationData = struct {
    /// 16-bit Attribute Handle assigned to the characteristic value on the GATT server.
    handle: u16,
    /// Raw unparsed payload bytes. Borrows memory directly from the receive buffer.
    payload: []const u8,
};

/// Parses a raw ATT Handle Value Notification (`ATT_HANDLE_VALUE_NTF`, Opcode 0x1B) packet.
///
/// ### Memory & Ownership
/// - **Zero-Copy**: The returned `payload` slice references the provided `raw_packet` directly.
/// - **Zero-Allocation**: Performs no heap allocations (`no-alloc`).
///
/// ### Endianness & Hardware Representation
/// - `handle` is decoded from Little-Endian wire format according to Bluetooth Core Spec v5.4, Vol 3, Part F.
///
/// ### Preconditions
/// - If the raw packet includes the 1-byte opcode (`0x1B`), `raw_packet.len` must be >= 3 bytes.
/// - If the opcode was already stripped by lower L2CAP layers, 2-byte handle + value is accepted.
///
/// ### Arguments
/// - `raw_packet`: Raw bytes from the BLE HCI/L2CAP/socket stream.
///
/// ### Returns
/// Decoded `NotificationData` struct with handle and payload slice, or `ParseError.PayloadTooShort`.
pub fn parseNotification(raw_packet: []const u8) ParseError!NotificationData {
    if (raw_packet.len == 0) return ParseError.PayloadTooShort;

    // Check if opcode byte is present
    if (raw_packet[0] == @intFromEnum(AttOpcode.handle_value_ntf)) {
        if (raw_packet.len < 3) return ParseError.PayloadTooShort;
        const handle = std.mem.readInt(u16, raw_packet[1..3], .little);
        return NotificationData{
            .handle = handle,
            .payload = raw_packet[3..],
        };
    } else {
        // Opcode already stripped by L2CAP layer: Handle (2 bytes) + Payload
        if (raw_packet.len < 2) return ParseError.PayloadTooShort;
        const handle = std.mem.readInt(u16, raw_packet[0..2], .little);
        return NotificationData{
            .handle = handle,
            .payload = raw_packet[2..],
        };
    }
}

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

test "parseNotification: zero-copy and Little-Endian handle decoding" {
    // Opcode (0x1B) + Handle (0x002A in LE: 0x2A, 0x00) + Payload ("SensorData")
    const raw_packet = [_]u8{ 0x1B, 0x2A, 0x00, 'S', 'e', 'n', 's', 'o', 'r', 'D', 'a', 't', 'a' };
    const ntf = try parseNotification(&raw_packet);

    try std.testing.expectEqual(@as(u16, 0x002A), ntf.handle);
    try std.testing.expectEqualStrings("SensorData", ntf.payload);

    // Stripped L2CAP format: Handle (0x0014 in LE: 0x14, 0x00) + Payload (0xDE, 0xAD, 0xBE, 0xEF)
    const stripped = [_]u8{ 0x14, 0x00, 0xDE, 0xAD, 0xBE, 0xEF };
    const ntf_stripped = try parseNotification(&stripped);
    try std.testing.expectEqual(@as(u16, 0x0014), ntf_stripped.handle);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, ntf_stripped.payload);

    // Error case: too short
    const short_pkt = [_]u8{ 0x1B, 0x2A };
    try std.testing.expectError(ParseError.PayloadTooShort, parseNotification(&short_pkt));
}
