//! # Blood Pressure Service (BLS) - Bluetooth SIG Specification
//!
//! Assigned Service UUID: `0x1810` (GATT Service: Blood Pressure)
//!
//! Provides blood pressure measurements (Systolic, Diastolic, Mean Arterial Pressure,
//! Pulse Rate, and Measurement Status) using IEEE-11073-20601 16-bit SFLOAT types.
//!
//! 100% Pure Zig, zero dynamic allocations.

const std = @import("std");
const core = @import("../core/mod.zig");
const Sfloat = core.Sfloat;
const Services = core.Services;
const Characteristics = core.Characteristics;

pub const BloodPressureService = struct {
    pub const SERVICE_UUID = Services.blood_pressure; // 0x1810

    pub const BloodPressureUnits = enum(u1) {
        mm_hg = 0,
        k_pa = 1,

        pub fn symbol(self: BloodPressureUnits) []const u8 {
            return switch (self) {
                .mm_hg => "mmHg",
                .k_pa => "kPa",
            };
        }
    };

    pub const MeasurementStatus = packed struct(u16) {
        body_movement: bool = false,
        cuff_too_loose: bool = false,
        irregular_pulse: bool = false,
        pulse_rate_range: u2 = 0, // 0 = in range, 1 = exceeds upper, 2 = less than lower
        improper_position: bool = false,
        _reserved: u10 = 0,

        pub fn fromInt(raw: u16) MeasurementStatus {
            return @bitCast(raw);
        }

        pub fn toInt(self: MeasurementStatus) u16 {
            return @bitCast(self);
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

    /// Blood Pressure Measurement Characteristic (UUID 0x2A35).
    pub const Measurement = struct {
        units: BloodPressureUnits,
        systolic: f32,
        diastolic: f32,
        mean_arterial_pressure: f32,
        timestamp: ?DateTime = null,
        pulse_rate: ?f32 = null,
        user_id: ?u8 = null,
        status: ?MeasurementStatus = null,

        pub fn parse(raw: []const u8) ?Measurement {
            if (raw.len < 7) return null; // Flags (1) + 3 Sfloats (6)

            const flags = raw[0];
            const units: BloodPressureUnits = @enumFromInt(@as(u1, @truncate(flags & 0x01)));
            const has_timestamp = (flags & 0x02) != 0;
            const has_pulse_rate = (flags & 0x04) != 0;
            const has_user_id = (flags & 0x08) != 0;
            const has_status = (flags & 0x10) != 0;

            const sys_sf = Sfloat.fromRaw(std.mem.readInt(u16, raw[1..3], .little));
            const dia_sf = Sfloat.fromRaw(std.mem.readInt(u16, raw[3..5], .little));
            const map_sf = Sfloat.fromRaw(std.mem.readInt(u16, raw[5..7], .little));

            var offset: usize = 7;
            var ts: ?DateTime = null;
            if (has_timestamp) {
                if (raw.len < offset + DateTime.RAW_LEN) return null;
                ts = DateTime.parse(raw[offset..][0..DateTime.RAW_LEN]);
                offset += DateTime.RAW_LEN;
            }

            var pulse: ?f32 = null;
            if (has_pulse_rate) {
                if (raw.len < offset + 2) return null;
                const pr_sf = Sfloat.fromRaw(std.mem.readInt(u16, raw[offset..][0..2], .little));
                pulse = pr_sf.toFloat();
                offset += 2;
            }

            var uid: ?u8 = null;
            if (has_user_id) {
                if (raw.len < offset + 1) return null;
                uid = raw[offset];
                offset += 1;
            }

            var ms: ?MeasurementStatus = null;
            if (has_status) {
                if (raw.len < offset + 2) return null;
                ms = MeasurementStatus.fromInt(std.mem.readInt(u16, raw[offset..][0..2], .little));
                offset += 2;
            }

            return Measurement{
                .units = units,
                .systolic = sys_sf.toFloat() orelse 0.0,
                .diastolic = dia_sf.toFloat() orelse 0.0,
                .mean_arterial_pressure = map_sf.toFloat() orelse 0.0,
                .timestamp = ts,
                .pulse_rate = pulse,
                .user_id = uid,
                .status = ms,
            };
        }

        pub fn serialize(self: Measurement, dest: []u8) !usize {
            var flags: u8 = @intFromEnum(self.units);
            if (self.timestamp != null) flags |= 0x02;
            if (self.pulse_rate != null) flags |= 0x04;
            if (self.user_id != null) flags |= 0x08;
            if (self.status != null) flags |= 0x10;

            if (dest.len < 7) return error.BufferTooSmall;
            dest[0] = flags;

            const sys_sf = Sfloat.fromFloat(self.systolic);
            const dia_sf = Sfloat.fromFloat(self.diastolic);
            const map_sf = Sfloat.fromFloat(self.mean_arterial_pressure);

            std.mem.writeInt(u16, dest[1..3], sys_sf.raw, .little);
            std.mem.writeInt(u16, dest[3..5], dia_sf.raw, .little);
            std.mem.writeInt(u16, dest[5..7], map_sf.raw, .little);

            var offset: usize = 7;
            if (self.timestamp) |ts| {
                if (dest.len < offset + DateTime.RAW_LEN) return error.BufferTooSmall;
                _ = try ts.serialize(dest[offset..]);
                offset += DateTime.RAW_LEN;
            }

            if (self.pulse_rate) |pr| {
                if (dest.len < offset + 2) return error.BufferTooSmall;
                const pr_sf = Sfloat.fromFloat(pr);
                std.mem.writeInt(u16, dest[offset..][0..2], pr_sf.raw, .little);
                offset += 2;
            }

            if (self.user_id) |uid| {
                if (dest.len < offset + 1) return error.BufferTooSmall;
                dest[offset] = uid;
                offset += 1;
            }

            if (self.status) |st| {
                if (dest.len < offset + 2) return error.BufferTooSmall;
                std.mem.writeInt(u16, dest[offset..][0..2], st.toInt(), .little);
                offset += 2;
            }

            return offset;
        }

        /// Formats into standard readable blood pressure string (e.g. "120/80 mmHg (Pulse: 72 bpm)").
        pub fn formatString(self: Measurement, dest: []u8) ![]const u8 {
            if (self.pulse_rate) |pr| {
                return std.fmt.bufPrint(
                    dest,
                    "{d:.0}/{d:.0} {s} (MAP: {d:.0}, Pulse: {d:.0} bpm)",
                    .{ self.systolic, self.diastolic, self.units.symbol(), self.mean_arterial_pressure, pr },
                );
            } else {
                return std.fmt.bufPrint(
                    dest,
                    "{d:.0}/{d:.0} {s} (MAP: {d:.0})",
                    .{ self.systolic, self.diastolic, self.units.symbol(), self.mean_arterial_pressure },
                );
            }
        }
    };
};

test "blood pressure service - parse and serialize roundtrip" {
    const meas = BloodPressureService.Measurement{
        .units = .mm_hg,
        .systolic = 120.0,
        .diastolic = 80.0,
        .mean_arterial_pressure = 93.0,
        .pulse_rate = 72.0,
        .user_id = 1,
        .status = .{ .irregular_pulse = false },
    };

    var buf: [32]u8 = undefined;
    const len = try meas.serialize(&buf);
    try std.testing.expectEqual(12, len); // 1 flags + 6 pressure + 2 pulse + 1 uid + 2 status

    const parsed = BloodPressureService.Measurement.parse(buf[0..len]).?;
    try std.testing.expectEqual(BloodPressureService.BloodPressureUnits.mm_hg, parsed.units);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), parsed.systolic, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), parsed.diastolic, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 93.0), parsed.mean_arterial_pressure, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 72.0), parsed.pulse_rate.?, 0.5);
    try std.testing.expectEqual(@as(u8, 1), parsed.user_id.?);

    var str_buf: [64]u8 = undefined;
    const str = try parsed.formatString(&str_buf);
    try std.testing.expectEqualStrings("120/80 mmHg (MAP: 93, Pulse: 72 bpm)", str);
}
