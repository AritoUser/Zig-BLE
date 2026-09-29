//! # Current Time Service (CTS) - Bluetooth SIG Specification
//!
//! Assigned Service UUID: `0x1805` (GATT Service: Current Time)
//!
//! Provides synchronized time, date, timezone, and DST information between
//! central clients (e.g. smartphones, gateways) and peripheral devices (smartwatches, sensors).
//!
//! 100% Pure Zig, zero dynamic allocations.

const std = @import("std");
const core = @import("../core/mod.zig");
const Services = core.Services;
const Characteristics = core.Characteristics;

pub const CurrentTimeService = struct {
    pub const SERVICE_UUID = Services.current_time; // 0x1805

    pub const DayOfWeek = enum(u8) {
        unknown = 0,
        monday = 1,
        tuesday = 2,
        wednesday = 3,
        thursday = 4,
        friday = 5,
        saturday = 6,
        sunday = 7,
        _,

        pub fn toString(self: DayOfWeek) []const u8 {
            return switch (self) {
                .monday => "Monday",
                .tuesday => "Tuesday",
                .wednesday => "Wednesday",
                .thursday => "Thursday",
                .friday => "Friday",
                .saturday => "Saturday",
                .sunday => "Sunday",
                else => "Unknown",
            };
        }
    };

    pub const AdjustReason = packed struct(u8) {
        manual_time_update: bool = false,
        external_reference_time_update: bool = false,
        change_of_time_zone: bool = false,
        change_of_dst: bool = false,
        _reserved: u4 = 0,

        pub fn toByte(self: AdjustReason) u8 {
            return @bitCast(self);
        }

        pub fn fromByte(b: u8) AdjustReason {
            return @bitCast(b);
        }
    };

    /// Current Time Characteristic (UUID 0x2A2B, 10 bytes).
    pub const CurrentTime = struct {
        year: u16,
        month: u8, // 1 - 12 (0 = unknown)
        day: u8, // 1 - 31 (0 = unknown)
        hours: u8, // 0 - 23
        minutes: u8, // 0 - 59
        seconds: u8, // 0 - 59
        day_of_week: DayOfWeek,
        fractions256: u8, // 1/256th of a second
        adjust_reason: AdjustReason,

        pub const RAW_LEN = 10;

        pub fn parse(raw: []const u8) ?CurrentTime {
            if (raw.len < RAW_LEN) return null;
            return CurrentTime{
                .year = std.mem.readInt(u16, raw[0..2], .little),
                .month = raw[2],
                .day = raw[3],
                .hours = raw[4],
                .minutes = raw[5],
                .seconds = raw[6],
                .day_of_week = @enumFromInt(raw[7]),
                .fractions256 = raw[8],
                .adjust_reason = AdjustReason.fromByte(raw[9]),
            };
        }

        pub fn serialize(self: CurrentTime, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            std.mem.writeInt(u16, dest[0..2], self.year, .little);
            dest[2] = self.month;
            dest[3] = self.day;
            dest[4] = self.hours;
            dest[5] = self.minutes;
            dest[6] = self.seconds;
            dest[7] = @intFromEnum(self.day_of_week);
            dest[8] = self.fractions256;
            dest[9] = self.adjust_reason.toByte();
            return RAW_LEN;
        }

        /// Formats into "YYYY-MM-DD HH:MM:SS" string buffer (at least 19 bytes).
        pub fn formatString(self: CurrentTime, dest: []u8) ![]const u8 {
            return std.fmt.bufPrint(
                dest,
                "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
                .{ self.year, self.month, self.day, self.hours, self.minutes, self.seconds },
            );
        }
    };

    pub const DstOffset = enum(u8) {
        standard = 0,
        half_hour = 2,
        daylight = 4,
        double_daylight = 8,
        unknown = 255,
        _,

        pub fn toString(self: DstOffset) []const u8 {
            return switch (self) {
                .standard => "Standard Time (+0h)",
                .half_hour => "Half Hour Daylight (+0.5h)",
                .daylight => "Daylight Time (+1h)",
                .double_daylight => "Double Daylight Time (+2h)",
                else => "Unknown DST Offset",
            };
        }
    };

    /// Local Time Information Characteristic (UUID 0x2A0F, 2 bytes).
    pub const LocalTimeInfo = struct {
        /// Offset from UTC in increments of 15 minutes (-48 to +56).
        /// Example: UTC+1 (CET) is +4. UTC+2 (CEST) is +8.
        time_zone_15min_offset: i8,
        dst_offset: DstOffset,

        pub const RAW_LEN = 2;

        pub fn parse(raw: []const u8) ?LocalTimeInfo {
            if (raw.len < RAW_LEN) return null;
            return LocalTimeInfo{
                .time_zone_15min_offset = @as(i8, @bitCast(raw[0])),
                .dst_offset = @enumFromInt(raw[1]),
            };
        }

        pub fn serialize(self: LocalTimeInfo, dest: []u8) !usize {
            if (dest.len < RAW_LEN) return error.BufferTooSmall;
            dest[0] = @as(u8, @bitCast(self.time_zone_15min_offset));
            dest[1] = @intFromEnum(self.dst_offset);
            return RAW_LEN;
        }

        /// Returns total UTC offset in minutes including DST.
        pub fn totalUtcOffsetMinutes(self: LocalTimeInfo) i32 {
            var minutes: i32 = @as(i32, self.time_zone_15min_offset) * 15;
            switch (self.dst_offset) {
                .half_hour => minutes += 30,
                .daylight => minutes += 60,
                .double_daylight => minutes += 120,
                else => {},
            }
            return minutes;
        }
    };
};

test "current time service - parse and serialize roundtrip" {
    const ct = CurrentTimeService.CurrentTime{
        .year = 2026,
        .month = 9,
        .day = 29,
        .hours = 19,
        .minutes = 45,
        .seconds = 30,
        .day_of_week = .tuesday,
        .fractions256 = 128,
        .adjust_reason = .{ .manual_time_update = true },
    };

    var buf: [16]u8 = undefined;
    const len = try ct.serialize(&buf);
    try std.testing.expectEqual(10, len);

    const parsed = CurrentTimeService.CurrentTime.parse(buf[0..len]).?;
    try std.testing.expectEqual(@as(u16, 2026), parsed.year);
    try std.testing.expectEqual(@as(u8, 9), parsed.month);
    try std.testing.expectEqual(@as(u8, 29), parsed.day);
    try std.testing.expectEqual(@as(u8, 19), parsed.hours);
    try std.testing.expectEqual(@as(u8, 45), parsed.minutes);
    try std.testing.expectEqual(@as(u8, 30), parsed.seconds);
    try std.testing.expectEqual(CurrentTimeService.DayOfWeek.tuesday, parsed.day_of_week);
    try std.testing.expectEqual(@as(u8, 128), parsed.fractions256);
    try std.testing.expect(parsed.adjust_reason.manual_time_update);

    var str_buf: [32]u8 = undefined;
    const str = try parsed.formatString(&str_buf);
    try std.testing.expectEqualStrings("2026-09-29 19:45:30", str);
}

test "current time service - local time info roundtrip" {
    // UTC+2 (CEST: +1h timezone offset +1h daylight saving)
    const lti = CurrentTimeService.LocalTimeInfo{
        .time_zone_15min_offset = 4, // 4 * 15 min = +60 min
        .dst_offset = .daylight, // +60 min
    };

    var buf: [4]u8 = undefined;
    const len = try lti.serialize(&buf);
    try std.testing.expectEqual(2, len);

    const parsed = CurrentTimeService.LocalTimeInfo.parse(buf[0..len]).?;
    try std.testing.expectEqual(@as(i8, 4), parsed.time_zone_15min_offset);
    try std.testing.expectEqual(CurrentTimeService.DstOffset.daylight, parsed.dst_offset);
    try std.testing.expectEqual(@as(i32, 120), parsed.totalUtcOffsetMinutes());
}
