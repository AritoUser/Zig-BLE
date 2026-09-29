//! # Health Thermometer Service (HTS) - Bluetooth SIG Specification
//!
//! Assigned Service UUID: `0x1809` (GATT Service: Health Thermometer)
//!
//! Provides medical and clinical temperature measurements utilizing IEEE-11073-20601
//! 32-bit FLOAT-Type representations with optional timestamps and body location types.
//!
//! 100% Pure Zig, zero dynamic allocations.

const std = @import("std");
const core = @import("../core/mod.zig");
const Float32 = core.Float32;
const Services = core.Services;
const Characteristics = core.Characteristics;

pub const HealthThermometerService = struct {
    pub const SERVICE_UUID = Services.health_thermometer; // 0x1809

    pub const TemperatureType = enum(u8) {
        armpit = 1,
        body = 2,
        ear = 3,
        finger = 4,
        gastro_intestinal_tract = 5,
        mouth = 6,
        rectum = 7,
        toe = 8,
        tympanum = 9,
        _,

        pub fn toString(self: TemperatureType) []const u8 {
            return switch (self) {
                .armpit => "Armpit",
                .body => "Body (general)",
                .ear => "Ear",
                .finger => "Finger",
                .gastro_intestinal_tract => "Gastro-intestinal Tract",
                .mouth => "Mouth",
                .rectum => "Rectum",
                .toe => "Toe",
                .tympanum => "Tympanum",
                else => "Unknown Location",
            };
        }
    };

    pub const TemperatureUnits = enum(u1) {
        celsius = 0,
        fahrenheit = 1,

        pub fn symbol(self: TemperatureUnits) []const u8 {
            return switch (self) {
                .celsius => "°C",
                .fahrenheit => "°F",
            };
        }
    };

    pub const DateTime = struct {
        year: u16,
        month: u8,
        day: u8,
        hours: u8,
        minutes: u8,
        seconds: u8,

        pub const RAW_LEN = 7;

        pub fn parse(raw: []const u8) ?DateTime {
            if (raw.len < RAW_LEN) return null;
            return DateTime{
                .year = std.mem.readInt(u16, raw[0..2], .little),
                .month = raw[2],
                .day = raw[3],
                .hours = raw[4],
                .minutes = raw[5],
                .seconds = raw[6],
            };
        }

        pub fn serialize(self: DateTime, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            std.mem.writeInt(u16, dest[0..2], self.year, .little);
            dest[2] = self.month;
            dest[3] = self.day;
            dest[4] = self.hours;
            dest[5] = self.minutes;
            dest[6] = self.seconds;
            return RAW_LEN;
        }
    };

    /// Temperature Measurement Characteristic (UUID 0x2A1C).
    pub const Measurement = struct {
        units: TemperatureUnits,
        temperature: f32, // Converted to IEEE-11073 32-bit Float
        raw_float: Float32,
        timestamp: ?DateTime = null,
        temperature_type: ?TemperatureType = null,

        pub fn parse(raw: []const u8) ?Measurement {
            if (raw.len < 5) return null; // Flags (1) + Float32 (4)

            const flags = raw[0];
            const units: TemperatureUnits = @enumFromInt(@as(u1, @truncate(flags & 0x01)));
            const has_timestamp = (flags & 0x02) != 0;
            const has_type = (flags & 0x04) != 0;

            const float_raw = std.mem.readInt(u32, raw[1..5], .little);
            const float_val = Float32.fromRaw(float_raw);

            var offset: usize = 5;
            var ts: ?DateTime = null;
            if (has_timestamp) {
                if (raw.len < offset + DateTime.RAW_LEN) return null;
                ts = DateTime.parse(raw[offset..][0..DateTime.RAW_LEN]);
                offset += DateTime.RAW_LEN;
            }

            var t_type: ?TemperatureType = null;
            if (has_type) {
                if (raw.len < offset + 1) return null;
                t_type = @enumFromInt(raw[offset]);
                offset += 1;
            }

            return Measurement{
                .units = units,
                .temperature = float_val.toFloat() orelse 0.0,
                .raw_float = float_val,
                .timestamp = ts,
                .temperature_type = t_type,
            };
        }

        pub fn serialize(self: Measurement, dest: []u8) !usize {
            var flags: u8 = @intFromEnum(self.units);
            if (self.timestamp != null) flags |= 0x02;
            if (self.temperature_type != null) flags |= 0x04;

            if (dest.len < 5) return error.BufferTooSmall;
            dest[0] = flags;

            // IEEE-11073 32-bit float encoding (e.g. 37.0°C -> mantissa 370, exponent -1)
            const fl = if (self.raw_float.raw != 0) self.raw_float else Float32.fromFloat(self.temperature);
            std.mem.writeInt(u32, dest[1..5], fl.raw, .little);

            var offset: usize = 5;
            if (self.timestamp) |ts| {
                if (dest.len < offset + DateTime.RAW_LEN) return error.BufferTooSmall;
                _ = try ts.serialize(dest[offset..]);
                offset += DateTime.RAW_LEN;
            }

            if (self.temperature_type) |tt| {
                if (dest.len < offset + 1) return error.BufferTooSmall;
                dest[offset] = @intFromEnum(tt);
                offset += 1;
            }

            return offset;
        }

        /// Formats into human-readable string (e.g. "36.8 °C (Ear)").
        pub fn formatString(self: Measurement, dest: []u8) ![]const u8 {
            if (self.temperature_type) |tt| {
                return std.fmt.bufPrint(
                    dest,
                    "{d:.1} {s} ({s})",
                    .{ self.temperature, self.units.symbol(), tt.toString() },
                );
            } else {
                return std.fmt.bufPrint(
                    dest,
                    "{d:.1} {s}",
                    .{ self.temperature, self.units.symbol() },
                );
            }
        }
    };
};

test "health thermometer service - parse and serialize roundtrip" {
    const meas = HealthThermometerService.Measurement{
        .units = .celsius,
        .temperature = 37.2,
        .raw_float = Float32.fromFloat(37.2),
        .timestamp = HealthThermometerService.DateTime{
            .year = 2026,
            .month = 9,
            .day = 29,
            .hours = 20,
            .minutes = 0,
            .seconds = 0,
        },
        .temperature_type = .ear,
    };

    var buf: [32]u8 = undefined;
    const len = try meas.serialize(&buf);
    try std.testing.expectEqual(13, len); // 1 flags + 4 float + 7 timestamp + 1 type

    const parsed = HealthThermometerService.Measurement.parse(buf[0..len]).?;
    try std.testing.expectEqual(HealthThermometerService.TemperatureUnits.celsius, parsed.units);
    try std.testing.expectApproxEqAbs(@as(f32, 37.2), parsed.temperature, 0.05);
    try std.testing.expectEqual(HealthThermometerService.TemperatureType.ear, parsed.temperature_type.?);
    try std.testing.expectEqual(@as(u16, 2026), parsed.timestamp.?.year);

    var str_buf: [32]u8 = undefined;
    const str = try parsed.formatString(&str_buf);
    try std.testing.expectEqualStrings("37.2 °C (Ear)", str);
}
