//! # Vendor advertisement decoders
//!
//! Recognizes documented vendor formats in raw advertising data:
//! - Apple iBeacon (manufacturer data, company 0x004C) via `beacon.IBeacon`
//! - Microsoft Swift Pair (manufacturer data, company 0x0006), per Microsoft's
//!   "Swift Pair" component guidelines
//! - Google Fast Pair (service data 0xFE2C), per the Fast Pair Provider specification
//!
//! Undocumented formats (e.g. Apple Continuity) are intentionally not decoded.

const std = @import("std");
const core = @import("../core/mod.zig");
const beacon = @import("beacon.zig");

const Address = core.Address;
const AdIterator = core.advertising.AdIterator;

/// Microsoft Swift Pair pairing advertisement.
pub const SwiftPair = struct {
    pub const company_id: u16 = 0x0006;
    pub const beacon_id: u8 = 0x03;

    pub const Scenario = enum(u8) {
        /// Pairing over Bluetooth LE only.
        le_only = 0x00,
        /// Pairing over BR/EDR only, using LE for discovery.
        bredr_only = 0x01,
        /// Pairing over LE and BR/EDR with Secure Connections.
        le_and_bredr = 0x02,
    };

    scenario: Scenario,
    /// BR/EDR address of a `.bredr_only` peripheral.
    bredr_address: ?Address = null,
    /// 24-bit Class of Device of dual-mode peripherals (`.bredr_only`, `.le_and_bredr`).
    class_of_device: ?u24 = null,
    /// Optional display name (UTF-8, may be empty).
    display_name: []const u8 = "",

    /// Parses the manufacturer data payload that follows company ID 0x0006.
    pub fn parse(payload: []const u8) ?SwiftPair {
        // Beacon ID, sub scenario, reserved RSSI byte (0x80)
        if (payload.len < 3 or payload[0] != beacon_id) return null;
        const scenario = std.enums.fromInt(Scenario, payload[1]) orelse return null;
        var rest = payload[3..];
        var sp = SwiftPair{ .scenario = scenario };

        if (scenario == .bredr_only) {
            if (rest.len < 6) return null;
            // Little endian on air; `Address.bytes` is most significant byte first.
            var bytes: [6]u8 = undefined;
            for (0..6) |i| bytes[i] = rest[5 - i];
            sp.bredr_address = .{ .bytes = bytes };
            rest = rest[6..];
        }
        if (scenario != .le_only) {
            if (rest.len < 3) return null;
            sp.class_of_device = std.mem.readInt(u24, rest[0..3], .little);
            rest = rest[3..];
        }
        sp.display_name = rest;
        return sp;
    }
};

/// Google Fast Pair provider advertisement (service data UUID 0xFE2C).
pub const FastPair = union(enum) {
    pub const service_uuid16: u16 = 0xFE2C;

    /// The provider is in pairing mode.
    discoverable: struct {
        /// 24-bit model ID as transmitted (octets 0-2).
        model_id: [3]u8,
        /// LE Audio Sharing payload only: FP LE Audio Sharing supported.
        le_audio_sharing: bool = false,
        /// LE Audio Sharing payload only: factory new, no account keys yet.
        out_of_box: bool = false,
    },
    /// The provider is not in pairing mode and advertises its account key filter.
    not_discoverable: struct {
        /// Show the "device nearby" UI on matching seekers (filter type 0000) or not (0010).
        show_ui: bool,
        /// Bloom filter over the account keys and `salt`.
        account_key_filter: []const u8,
        salt: ?u16 = null,
    },

    /// Model ID as one number, most significant octet first (the form shown in Google's
    /// device console).
    pub fn modelIdValue(model_id: [3]u8) u24 {
        return std.mem.readInt(u24, &model_id, .big);
    }

    /// Parses the service data that follows UUID 0xFE2C.
    pub fn parse(data: []const u8) ?FastPair {
        if (data.len == 3) return .{ .discoverable = .{ .model_id = data[0..3].* } };
        if (data.len < 2 or data[0] != 0x00) return null; // version 0, no flags

        const field_len: usize = data[1] >> 4;
        const field_type: u4 = @truncate(data[1]);
        switch (field_type) {
            // LE Audio Sharing: model ID field, then a capability map field
            0b0111 => {
                if (field_len != 3 or data.len < 2 + field_len) return null;
                var out = FastPair{ .discoverable = .{ .model_id = data[2..5].* } };
                const rest = data[2 + field_len ..];
                if (rest.len >= 2 and (rest[0] & 0x0F) == 0b1000) {
                    out.discoverable.le_audio_sharing = rest[1] & 0b10 != 0;
                    out.discoverable.out_of_box = rest[1] & 0b01 != 0;
                }
                return out;
            },
            // Account Key Filter (show / hide UI), optionally followed by the salt field
            0b0000, 0b0010 => {
                if (data.len < 2 + field_len) return null;
                var out = FastPair{ .not_discoverable = .{
                    .show_ui = field_type == 0b0000,
                    .account_key_filter = data[2 .. 2 + field_len],
                } };
                const rest = data[2 + field_len ..];
                if (rest.len >= 3 and rest[0] == 0x21) {
                    out.not_discoverable.salt = std.mem.readInt(u16, rest[1..3], .big);
                }
                return out;
            },
            else => return null,
        }
    }
};

pub const VendorAdvertisement = union(enum) {
    ibeacon: beacon.IBeacon,
    swift_pair: SwiftPair,
    fast_pair: FastPair,
};

/// Returns the first recognized vendor format in raw advertising data (AD structures).
/// Slices in the result point into `raw`.
pub fn decode(raw: []const u8) ?VendorAdvertisement {
    var it = AdIterator.init(raw);
    while (it.next()) |ad| {
        if (ad.asManufacturerData()) |mfg| {
            switch (mfg.company_id) {
                beacon.IBeacon.company_id => if (beacon.IBeacon.parse(mfg.payload)) |ib| return .{ .ibeacon = ib } else |_| {},
                SwiftPair.company_id => if (SwiftPair.parse(mfg.payload)) |sp| return .{ .swift_pair = sp },
                else => {},
            }
        } else if (ad.asServiceData16()) |sd| {
            if (sd.uuid16 == FastPair.service_uuid16) {
                if (FastPair.parse(sd.data)) |fp| return .{ .fast_pair = fp };
            }
        }
    }
    return null;
}

test "SwiftPair parses LE-only, dual-mode and BR/EDR-only payloads" {
    const le = SwiftPair.parse(&.{ 0x03, 0x00, 0x80, 'M', 'o', 'u', 's', 'e' }).?;
    try std.testing.expectEqual(SwiftPair.Scenario.le_only, le.scenario);
    try std.testing.expectEqualStrings("Mouse", le.display_name);
    try std.testing.expect(le.class_of_device == null);

    const dual = SwiftPair.parse(&.{ 0x03, 0x02, 0x80, 0x04, 0x04, 0x24 }).?;
    try std.testing.expectEqual(@as(?u24, 0x240404), dual.class_of_device);
    try std.testing.expectEqualStrings("", dual.display_name);

    const bredr = SwiftPair.parse(&.{ 0x03, 0x01, 0x80, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x04, 0x04, 0x24, 'H' }).?;
    try std.testing.expect(bredr.bredr_address.?.eql(try Address.parse("11:22:33:44:55:66")));
    try std.testing.expectEqualStrings("H", bredr.display_name);

    try std.testing.expect(SwiftPair.parse(&.{ 0x02, 0x00, 0x80 }) == null);
    try std.testing.expect(SwiftPair.parse(&.{ 0x03, 0x01, 0x80, 0x01 }) == null);
}

test "FastPair parses discoverable, LE Audio and account key payloads" {
    const disc = FastPair.parse(&.{ 0x2C, 0x6E, 0x85 }).?;
    try std.testing.expectEqual(@as(u24, 0x2C6E85), FastPair.modelIdValue(disc.discoverable.model_id));

    const audio = FastPair.parse(&.{ 0x00, 0x37, 0x01, 0x02, 0x03, 0x18, 0b11 }).?;
    try std.testing.expect(audio.discoverable.le_audio_sharing);
    try std.testing.expect(audio.discoverable.out_of_box);

    const hidden = FastPair.parse(&.{ 0x00, 0x42, 0xDE, 0xAD, 0xBE, 0xEF, 0x21, 0x12, 0x34 }).?;
    try std.testing.expect(!hidden.not_discoverable.show_ui);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, hidden.not_discoverable.account_key_filter);
    try std.testing.expectEqual(@as(?u16, 0x1234), hidden.not_discoverable.salt);

    try std.testing.expect(FastPair.parse(&.{ 0x10, 0x40 }) == null);
    // Filter length 4 but only 2 bytes follow (3-byte payloads are always a model ID)
    try std.testing.expect(FastPair.parse(&.{ 0x00, 0x40, 0x01, 0x02 }) == null);
}

test "decode finds the vendor format among other AD structures" {
    // Flags, then Swift Pair manufacturer data
    const swift = [_]u8{ 0x02, 0x01, 0x06, 0x08, 0xFF, 0x06, 0x00, 0x03, 0x00, 0x80, 'K', 'B' };
    try std.testing.expectEqualStrings("KB", decode(&swift).?.swift_pair.display_name);

    // Fast Pair service data
    const fast = [_]u8{ 0x06, 0x16, 0x2C, 0xFE, 0xAA, 0xBB, 0xCC };
    try std.testing.expectEqual(@as(u8, 0xAA), decode(&fast).?.fast_pair.discoverable.model_id[0]);

    const plain = [_]u8{ 0x02, 0x01, 0x06 };
    try std.testing.expect(decode(&plain) == null);
}
