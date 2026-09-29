//! # Device Information Service (DIS) - Bluetooth SIG Specification
//!
//! Assigned Service UUID: `0x180A` (GATT Service: Device Information)
//!
//! Provides manufacturers and peripherals a standardized way to expose model,
//! hardware, firmware, and regulatory identification information.
//!
//! 100% Pure Zig, zero dynamic allocations on hot-paths.

const std = @import("std");
const core = @import("../core/mod.zig");
const UUID = core.UUID;
const Services = core.Services;
const Characteristics = core.Characteristics;

pub const DeviceInformationService = struct {
    pub const SERVICE_UUID = Services.device_information; // 0x180A

    /// System ID Characteristic (UUID 0x2A23, 8 bytes).
    /// Structure: 40-bit manufacturer-defined identifier + 24-bit OUI (Organizationally Unique Identifier).
    pub const SystemId = struct {
        bytes: [8]u8,

        pub fn init(manufacturer_id: u40, oui_id: u24) SystemId {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u40, b[0..5], manufacturer_id, .little);
            std.mem.writeInt(u24, b[5..8], oui_id, .little);
            return SystemId{ .bytes = b };
        }

        pub fn parse(raw: []const u8) ?SystemId {
            if (raw.len < 8) return null;
            return SystemId{ .bytes = raw[0..8].* };
        }

        pub fn manufacturerId(self: SystemId) u40 {
            return std.mem.readInt(u40, self.bytes[0..5], .little);
        }

        pub fn oui(self: SystemId) u24 {
            return std.mem.readInt(u24, self.bytes[5..8], .little);
        }
    };

    pub const PnpVendorIdSource = enum(u8) {
        bluetooth_sig = 1,
        usb_implementers_forum = 2,
        _,

        pub fn toString(self: PnpVendorIdSource) []const u8 {
            return switch (self) {
                .bluetooth_sig => "Bluetooth SIG Assigned Company ID",
                .usb_implementers_forum => "USB Implementers Forum",
                _ => "Unknown Vendor ID Source",
            };
        }
    };

    /// PnP ID Characteristic (UUID 0x2A50, 7 bytes).
    /// Used by host operating systems to identify device drivers and vendor/product pairs.
    pub const PnpId = struct {
        vendor_id_source: PnpVendorIdSource,
        vendor_id: u16,
        product_id: u16,
        product_version: u16,

        pub const RAW_LEN = 7;

        pub fn parse(raw: []const u8) ?PnpId {
            if (raw.len < RAW_LEN) return null;
            return PnpId{
                .vendor_id_source = @enumFromInt(raw[0]),
                .vendor_id = std.mem.readInt(u16, raw[1..3], .little),
                .product_id = std.mem.readInt(u16, raw[3..5], .little),
                .product_version = std.mem.readInt(u16, raw[5..7], .little),
            };
        }

        pub fn serialize(self: PnpId, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            dest[0] = @intFromEnum(self.vendor_id_source);
            std.mem.writeInt(u16, dest[1..3], self.vendor_id, .little);
            std.mem.writeInt(u16, dest[3..5], self.product_id, .little);
            std.mem.writeInt(u16, dest[5..7], self.product_version, .little);
            return RAW_LEN;
        }
    };

    /// High-level struct representing all standard Device Information fields.
    pub const Info = struct {
        manufacturer_name: ?[]const u8 = null,
        model_number: ?[]const u8 = null,
        serial_number: ?[]const u8 = null,
        hardware_revision: ?[]const u8 = null,
        firmware_revision: ?[]const u8 = null,
        software_revision: ?[]const u8 = null,
        system_id: ?SystemId = null,
        pnp_id: ?PnpId = null,
    };
};

test "device information service - system id roundtrip" {
    const sys_id = DeviceInformationService.SystemId.init(0x1122334455, 0xAABBCC);
    try std.testing.expectEqual(@as(u40, 0x1122334455), sys_id.manufacturerId());
    try std.testing.expectEqual(@as(u24, 0xAABBCC), sys_id.oui());

    const parsed = DeviceInformationService.SystemId.parse(&sys_id.bytes).?;
    try std.testing.expectEqual(sys_id.manufacturerId(), parsed.manufacturerId());
    try std.testing.expectEqual(sys_id.oui(), parsed.oui());
}

test "device information service - pnp id roundtrip" {
    const pnp = DeviceInformationService.PnpId{
        .vendor_id_source = .bluetooth_sig,
        .vendor_id = 0x0059, // Nordic Semiconductor
        .product_id = 0x1234,
        .product_version = 0x0100,
    };

    var buf: [16]u8 = undefined;
    const len = try pnp.serialize(&buf);
    try std.testing.expectEqual(7, len);

    const parsed = DeviceInformationService.PnpId.parse(buf[0..len]).?;
    try std.testing.expectEqual(DeviceInformationService.PnpVendorIdSource.bluetooth_sig, parsed.vendor_id_source);
    try std.testing.expectEqual(@as(u16, 0x0059), parsed.vendor_id);
    try std.testing.expectEqual(@as(u16, 0x1234), parsed.product_id);
    try std.testing.expectEqual(@as(u16, 0x0100), parsed.product_version);
}
