//! # Beacon Profiles: Apple iBeacon & Google Eddystone
//!
//! Provides zero-allocation encoders and parsers for industry-standard BLE beacons:
//! - Apple iBeacon (Manufacturer Data 0x004C)
//! - Google Eddystone (Service Data 0xFEAA: UID, URL, TLM)

const std = @import("std");
const types = @import("../core/types.zig");
const UUID = types.UUID;

// ============================================================================
// Apple iBeacon
// ============================================================================

pub const IBeacon = struct {
    /// Apple Bluetooth SIG Company Identifier (0x004C).
    pub const company_id: u16 = 0x004C;

    /// 16-byte proximity UUID.
    uuid: UUID,
    /// 16-bit group identifier (Major). Big-Endian in iBeacon specification.
    major: u16,
    /// 16-bit sub-group identifier (Minor). Big-Endian in iBeacon specification.
    minor: u16,
    /// Calibrated RSSI at 1 meter distance (measured in dBm, typically -59 dBm).
    measured_power: i8,

    pub const ParseError = error{
        InvalidLength,
        InvalidPrefix,
    };

    /// Encodes iBeacon fields into a standard 23-byte Apple manufacturer payload.
    /// Format: [0x02, 0x15, UUID (16B), Major (2B BE), Minor (2B BE), MeasuredPower (1B)].
    pub fn encode(self: IBeacon) [23]u8 {
        var buf: [23]u8 = undefined;
        buf[0] = 0x02; // iBeacon Type
        buf[1] = 0x15; // Remaining Length: 21 bytes

        // Copy 16-byte UUID in Big-Endian order
        const uuid_bytes = self.uuid.toBytes();
        @memcpy(buf[2..18], &uuid_bytes);

        // Major & Minor (Big-Endian per Apple spec!)
        std.mem.writeInt(u16, buf[18..20], self.major, .big);
        std.mem.writeInt(u16, buf[20..22], self.minor, .big);
        buf[22] = @as(u8, @bitCast(self.measured_power));

        return buf;
    }

    /// Parses an Apple iBeacon manufacturer payload.
    pub fn parse(payload: []const u8) ParseError!IBeacon {
        if (payload.len < 23) return ParseError.InvalidLength;
        if (payload[0] != 0x02 or payload[1] != 0x15) return ParseError.InvalidPrefix;

        var uuid_bytes: [16]u8 = undefined;
        @memcpy(&uuid_bytes, payload[2..18]);
        const uuid = UUID.fromBytes(uuid_bytes);

        const major = std.mem.readInt(u16, payload[18..20], .big);
        const minor = std.mem.readInt(u16, payload[20..22], .big);
        const power: i8 = @bitCast(payload[22]);

        return IBeacon{
            .uuid = uuid,
            .major = major,
            .minor = minor,
            .measured_power = power,
        };
    }

    /// Directly constructs and encodes a standard 23-byte Apple iBeacon payload from parameters.
    pub fn build(uuid_str: []const u8, major: u16, minor: u16, measured_power: i8) ![23]u8 {
        const u = try UUID.parse(uuid_str);
        const beacon = IBeacon{
            .uuid = u,
            .major = major,
            .minor = minor,
            .measured_power = measured_power,
        };
        return beacon.encode();
    }
};

// ============================================================================
// Google Eddystone
// ============================================================================

pub const Eddystone = struct {
    pub const service_uuid16: u16 = 0xFEAA;

    pub const FrameType = enum(u8) {
        uid = 0x00,
        url = 0x10,
        tlm = 0x20,
        eid = 0x30,
        _,
    };

    pub const UrlScheme = enum(u8) {
        http_www = 0x00,  // "http://www."
        https_www = 0x01, // "https://www."
        http = 0x02,      // "http://"
        https = 0x03,     // "https://"
    };

    /// Eddystone-UID Frame (16 bytes ID + Tx power).
    pub const UidFrame = struct {
        tx_power_at_0m: i8,
        namespace_id: [10]u8,
        instance_id: [6]u8,

        pub fn encode(self: UidFrame) [20]u8 {
            var buf: [20]u8 = undefined;
            buf[0] = @intFromEnum(FrameType.uid);
            buf[1] = @as(u8, @bitCast(self.tx_power_at_0m));
            @memcpy(buf[2..12], &self.namespace_id);
            @memcpy(buf[12..18], &self.instance_id);
            buf[18] = 0x00; // Reserved
            buf[19] = 0x00; // Reserved
            return buf;
        }
    };

    pub const EncodedUrl = struct {
        bytes: [32]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    /// Eddystone-URL Frame.
    pub const UrlFrame = struct {
        tx_power_at_0m: i8,
        scheme: UrlScheme,
        encoded_url: []const u8,

        pub fn encode(self: UrlFrame, out: []u8) !usize {
            const total = 3 + self.encoded_url.len;
            if (out.len < total) return error.BufferTooSmall;
            out[0] = @intFromEnum(FrameType.url);
            out[1] = @as(u8, @bitCast(self.tx_power_at_0m));
            out[2] = @intFromEnum(self.scheme);
            @memcpy(out[3..total], self.encoded_url);
            return total;
        }

        pub fn encodeUrl(url: []const u8, tx_power_at_0m: i8) !EncodedUrl {
            var res = EncodedUrl{};
            var scheme: UrlScheme = .https;
            var path = url;
            if (std.mem.startsWith(u8, url, "https://www.")) {
                scheme = .https_www;
                path = url["https://www.".len..];
            } else if (std.mem.startsWith(u8, url, "http://www.")) {
                scheme = .http_www;
                path = url["http://www.".len..];
            } else if (std.mem.startsWith(u8, url, "https://")) {
                scheme = .https;
                path = url["https://".len..];
            } else if (std.mem.startsWith(u8, url, "http://")) {
                scheme = .http;
                path = url["http://".len..];
            }

            const frame = UrlFrame{
                .tx_power_at_0m = tx_power_at_0m,
                .scheme = scheme,
                .encoded_url = path,
            };
            res.len = try frame.encode(&res.bytes);
            return res;
        }
    };

    /// Eddystone-TLM (Telemetry) Frame.
    pub const TlmFrame = struct {
        battery_mv: u16,
        temperature_celsius: f32,
        adv_pdu_count: u32,
        time_since_boot_seconds: u32,

        pub fn encode(self: TlmFrame) [14]u8 {
            var buf: [14]u8 = undefined;
            buf[0] = @intFromEnum(FrameType.tlm);
            buf[1] = 0x00; // TLM version

            std.mem.writeInt(u16, buf[2..4], self.battery_mv, .big);

            // 8.8 fixed-point temperature
            const temp_raw: i16 = @intFromFloat(self.temperature_celsius * 256.0);
            std.mem.writeInt(u16, buf[4..6], @as(u16, @bitCast(temp_raw)), .big);

            std.mem.writeInt(u32, buf[6..10], self.adv_pdu_count, .big);

            // Deciseconds (0.1s increments)
            const deciseconds = self.time_since_boot_seconds * 10;
            std.mem.writeInt(u32, buf[10..14], deciseconds, .big);

            return buf;
        }

        pub fn encodeTlm(battery_mv: u16, temperature_celsius: f32, adv_pdu_count: u32, time_since_boot_seconds: u32) [14]u8 {
            const frame = TlmFrame{
                .battery_mv = battery_mv,
                .temperature_celsius = temperature_celsius,
                .adv_pdu_count = adv_pdu_count,
                .time_since_boot_seconds = time_since_boot_seconds,
            };
            return frame.encode();
        }
    };
};

pub const AppleIBeacon = struct {
    pub const build = IBeacon.build;
    pub const parse = IBeacon.parse;
    pub const encode = IBeacon.encode;
};

pub const EddystoneUrl = struct {
    pub const encode = Eddystone.UrlFrame.encodeUrl;
    pub const UrlScheme = Eddystone.UrlScheme;
};

pub const EddystoneUid = Eddystone.UidFrame;

pub const EddystoneTlm = struct {
    pub const encode = Eddystone.TlmFrame.encodeTlm;
};

// ============================================================================
// Unit Tests
// ============================================================================

test "IBeacon: roundtrip encoding and decoding" {
    const original_uuid = try UUID.parse("e2c56db5-dffb-48d2-b060-d0f5a71096e0");
    const beacon = IBeacon{
        .uuid = original_uuid,
        .major = 100,
        .minor = 1,
        .measured_power = -59,
    };

    const payload = beacon.encode();
    try std.testing.expectEqual(@as(usize, 23), payload.len);
    try std.testing.expectEqual(@as(u8, 0x02), payload[0]);
    try std.testing.expectEqual(@as(u8, 0x15), payload[1]);

    const decoded = try IBeacon.parse(&payload);
    try std.testing.expectEqual(beacon.uuid, decoded.uuid);
    try std.testing.expectEqual(beacon.major, decoded.major);
    try std.testing.expectEqual(beacon.minor, decoded.minor);
    try std.testing.expectEqual(beacon.measured_power, decoded.measured_power);
}

test "Eddystone: UID and TLM frame encoding" {
    const uid = Eddystone.UidFrame{
        .tx_power_at_0m = -20,
        .namespace_id = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A },
        .instance_id = [_]u8{ 'Z', 'I', 'G', 'B', 'L', 'E' },
    };

    const enc_uid = uid.encode();
    try std.testing.expectEqual(@as(u8, 0x00), enc_uid[0]);
    try std.testing.expectEqual(@as(u8, 0xEC), enc_uid[1]); // -20 in u8 bitcast is 0xEC
    try std.testing.expectEqualSlices(u8, &uid.namespace_id, enc_uid[2..12]);

    const tlm = Eddystone.TlmFrame{
        .battery_mv = 3300,
        .temperature_celsius = 24.5,
        .adv_pdu_count = 10000,
        .time_since_boot_seconds = 3600,
    };

    const enc_tlm = tlm.encode();
    try std.testing.expectEqual(@as(u8, 0x20), enc_tlm[0]);
    const batt = std.mem.readInt(u16, enc_tlm[2..4], .big);
    try std.testing.expectEqual(@as(u16, 3300), batt);
}
