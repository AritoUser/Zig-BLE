//! # Human Interface Device (HID) over GATT Profile (HOGP) - Bluetooth SIG Specification
//!
//! Assigned Service UUID: `0x1812` (GATT Service: Human Interface Device)
//!
//! Enables standard BLE wireless keyboards, mice, trackpads, presenters, and game controllers.
//!
//! 100% Pure Zig, zero dynamic allocations.

const std = @import("std");
const core = @import("../core/mod.zig");
const Services = core.Services;
const Characteristics = core.Characteristics;
const Descriptors = core.Descriptors;

pub const HidService = struct {
    pub const SERVICE_UUID = Services.human_interface_device; // 0x1812

    pub const ProtocolMode = enum(u8) {
        boot = 0x00,
        report = 0x01,
        _,

        pub fn toString(self: ProtocolMode) []const u8 {
            return switch (self) {
                .boot => "Boot Protocol Mode",
                .report => "Report Protocol Mode",
                else => "Unknown Protocol Mode",
            };
        }
    };

    pub const ControlPointCommand = enum(u8) {
        @"suspend" = 0x00,
        exit_suspend = 0x01,
        _,
    };

    pub const ReportType = enum(u8) {
        input = 0x01,
        output = 0x02,
        feature = 0x03,
        _,

        pub fn toString(self: ReportType) []const u8 {
            return switch (self) {
                .input => "Input Report",
                .output => "Output Report",
                .feature => "Feature Report",
                else => "Unknown Report Type",
            };
        }
    };

    /// HID Information Characteristic (UUID 0x2A4A, 4 bytes).
    pub const HidInfo = struct {
        bcd_hid: u16, // Version number of USB HID spec (e.g. 0x0111)
        country_code: u8,
        remote_wake: bool,
        normally_connectable: bool,

        pub const RAW_LEN = 4;

        pub fn parse(raw: []const u8) ?HidInfo {
            if (raw.len < RAW_LEN) return null;
            const flags = raw[3];
            return HidInfo{
                .bcd_hid = std.mem.readInt(u16, raw[0..2], .little),
                .country_code = raw[2],
                .remote_wake = (flags & 0x01) != 0,
                .normally_connectable = (flags & 0x02) != 0,
            };
        }

        pub fn serialize(self: HidInfo, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            std.mem.writeInt(u16, dest[0..2], self.bcd_hid, .little);
            dest[2] = self.country_code;
            var flags: u8 = 0;
            if (self.remote_wake) flags |= 0x01;
            if (self.normally_connectable) flags |= 0x02;
            dest[3] = flags;
            return RAW_LEN;
        }
    };

    /// Report Reference Descriptor (UUID 0x2908, 2 bytes).
    /// Placed on each Report characteristic to declare its Report ID and Report Type.
    pub const ReportReference = struct {
        report_id: u8,
        report_type: ReportType,

        pub const RAW_LEN = 2;

        pub fn parse(raw: []const u8) ?ReportReference {
            if (raw.len < RAW_LEN) return null;
            return ReportReference{
                .report_id = raw[0],
                .report_type = @enumFromInt(raw[1]),
            };
        }

        pub fn serialize(self: ReportReference, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            dest[0] = self.report_id;
            dest[1] = @intFromEnum(self.report_type);
            return RAW_LEN;
        }
    };

    /// Standard Boot Keyboard Input Report (UUID 0x2A22, 8 bytes).
    /// Compatible with BIOS boot mode.
    pub const BootKeyboardInput = struct {
        modifiers: KeyboardModifiers,
        reserved: u8 = 0,
        keys: [6]u8, // Up to 6 simultaneous standard HID keycodes (e.g. 0x04 = 'a')

        pub const RAW_LEN = 8;

        pub fn parse(raw: []const u8) ?BootKeyboardInput {
            if (raw.len < RAW_LEN) return null;
            return BootKeyboardInput{
                .modifiers = KeyboardModifiers.fromByte(raw[0]),
                .reserved = raw[1],
                .keys = raw[2..8].*,
            };
        }

        pub fn serialize(self: BootKeyboardInput, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            dest[0] = self.modifiers.toByte();
            dest[1] = self.reserved;
            @memcpy(dest[2..8], &self.keys);
            return RAW_LEN;
        }
    };

    pub const KeyboardModifiers = packed struct(u8) {
        left_ctrl: bool = false,
        left_shift: bool = false,
        left_alt: bool = false,
        left_gui: bool = false, // Windows / Command key
        right_ctrl: bool = false,
        right_shift: bool = false,
        right_alt: bool = false,
        right_gui: bool = false,

        pub fn fromByte(b: u8) KeyboardModifiers {
            return @bitCast(b);
        }

        pub fn toByte(self: KeyboardModifiers) u8 {
            return @bitCast(self);
        }
    };

    /// Standard Boot Mouse Input Report (UUID 0x2A33, 3 to 4 bytes).
    pub const BootMouseInput = struct {
        buttons: MouseButtons,
        x: i8, // Relative displacement X
        y: i8, // Relative displacement Y
        wheel: i8 = 0, // Optional vertical scroll wheel displacement

        pub fn parse(raw: []const u8) ?BootMouseInput {
            if (raw.len < 3) return null;
            return BootMouseInput{
                .buttons = MouseButtons.fromByte(raw[0]),
                .x = @as(i8, @bitCast(raw[1])),
                .y = @as(i8, @bitCast(raw[2])),
                .wheel = if (raw.len >= 4) @as(i8, @bitCast(raw[3])) else 0,
            };
        }

        pub fn serialize(self: BootMouseInput, dest: []u8) !usize {
            if (dest.len < 4) return error.BufferTooSmall;
            dest[0] = self.buttons.toByte();
            dest[1] = @as(u8, @bitCast(self.x));
            dest[2] = @as(u8, @bitCast(self.y));
            dest[3] = @as(u8, @bitCast(self.wheel));
            return 4;
        }
    };

    pub const MouseButtons = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        middle: bool = false,
        _reserved: u5 = 0,

        pub fn fromByte(b: u8) MouseButtons {
            return @bitCast(b);
        }

        pub fn toByte(self: MouseButtons) u8 {
            return @bitCast(self);
        }
    };
};

test "hid profile - hid info and report reference roundtrip" {
    const info = HidService.HidInfo{
        .bcd_hid = 0x0111, // HID v1.11
        .country_code = 0,
        .remote_wake = true,
        .normally_connectable = true,
    };

    var buf: [16]u8 = undefined;
    const len1 = try info.serialize(&buf);
    try std.testing.expectEqual(4, len1);

    const parsed_info = HidService.HidInfo.parse(buf[0..len1]).?;
    try std.testing.expectEqual(@as(u16, 0x0111), parsed_info.bcd_hid);
    try std.testing.expect(parsed_info.remote_wake);
    try std.testing.expect(parsed_info.normally_connectable);

    // Report Reference
    const ref = HidService.ReportReference{
        .report_id = 1,
        .report_type = .input,
    };
    const len2 = try ref.serialize(&buf);
    try std.testing.expectEqual(2, len2);

    const parsed_ref = HidService.ReportReference.parse(buf[0..len2]).?;
    try std.testing.expectEqual(@as(u8, 1), parsed_ref.report_id);
    try std.testing.expectEqual(HidService.ReportType.input, parsed_ref.report_type);
}

test "hid profile - boot keyboard and mouse report roundtrip" {
    // Keyboard with Left Shift + 'a' key (0x04)
    const kb = HidService.BootKeyboardInput{
        .modifiers = .{ .left_shift = true },
        .keys = [_]u8{ 0x04, 0, 0, 0, 0, 0 },
    };

    var buf: [16]u8 = undefined;
    const len1 = try kb.serialize(&buf);
    try std.testing.expectEqual(8, len1);

    const parsed_kb = HidService.BootKeyboardInput.parse(buf[0..len1]).?;
    try std.testing.expect(parsed_kb.modifiers.left_shift);
    try std.testing.expectEqual(@as(u8, 0x04), parsed_kb.keys[0]);

    // Mouse movement: +10 X, -5 Y, left click
    const mouse = HidService.BootMouseInput{
        .buttons = .{ .left = true },
        .x = 10,
        .y = -5,
        .wheel = 1,
    };
    const len2 = try mouse.serialize(&buf);
    try std.testing.expectEqual(4, len2);

    const parsed_mouse = HidService.BootMouseInput.parse(buf[0..len2]).?;
    try std.testing.expect(parsed_mouse.buttons.left);
    try std.testing.expectEqual(@as(i8, 10), parsed_mouse.x);
    try std.testing.expectEqual(@as(i8, -5), parsed_mouse.y);
    try std.testing.expectEqual(@as(i8, 1), parsed_mouse.wheel);
}
