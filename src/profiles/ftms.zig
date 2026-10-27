//! # Bluetooth SIG Fitness Machine Profile (FTMS)
//!
//! Service UUID: 0x1826 (org.bluetooth.service.fitness_machine)
//! Characteristics:
//! - Fitness Machine Feature:         0x2ACC (Read)
//! - Treadmill Data:                  0x2ACD (Notify)
//! - Cross Trainer Data:              0x2ACE (Notify)
//! - Step Climber Data:               0x2ACF (Notify)
//! - Stair Climber Data:              0x2AD0 (Notify)
//! - Rower Data:                      0x2AD1 (Notify)
//! - Indoor Bike Data:                0x2AD2 (Notify)
//! - Training Status:                 0x2AD3 (Notify, Read)
//! - Supported Speed Range:           0x2AD4 (Read)
//! - Supported Inclination Range:     0x2AD5 (Read)
//! - Supported Resistance Range:      0x2AD6 (Read)
//! - Supported Heart Rate Range:      0x2AD7 (Read)
//! - Supported Power Range:           0x2AD8 (Read)
//! - Fitness Machine Control Point:   0x2AD9 (Write, Indicate)
//! - Fitness Machine Status:          0x2ADA (Notify)
//!
//! Specification: Bluetooth SIG Fitness Machine Service v1.0.
//! Zero-allocation implementation with native u24 distance and exact SI unit conversions.

const std = @import("std");

pub const ParseError = error{
    PayloadTooShort,
    BufferOverflow,
    InvalidData,
};

pub const EncodeError = error{
    BufferTooSmall,
    InvalidData,
};

/// Expended Energy structure used across FTMS data streams.
pub const ExpendedEnergy = struct {
    total_kcal: u16,
    energy_per_hour_kcal: u16,
    energy_per_minute_kcal: u8,
};

/// Fitness Machine Feature (UUID 0x2ACC) - 8 Bytes total.
pub const FitnessMachineFeature = struct {
    fitness_machine_features: u32 = 0,
    target_setting_features: u32 = 0,

    pub fn parse(raw: []const u8) ParseError!FitnessMachineFeature {
        if (raw.len < 8) return error.PayloadTooShort;
        return .{
            .fitness_machine_features = std.mem.readInt(u32, raw[0..4], .little),
            .target_setting_features = std.mem.readInt(u32, raw[4..8], .little),
        };
    }

    pub fn encode(self: FitnessMachineFeature, out_buf: []u8) EncodeError![]u8 {
        if (out_buf.len < 8) return error.BufferTooSmall;
        std.mem.writeInt(u32, out_buf[0..4], self.fitness_machine_features, .little);
        std.mem.writeInt(u32, out_buf[4..8], self.target_setting_features, .little);
        return out_buf[0..8];
    }
};

/// Decoded Indoor Bike Data characteristic value (0x2AD2).
///
/// NOTE on Bit 0 (`More Data`):
/// In FTMS v1.0, Bit 0 behaves inversely to all other bits:
/// - Bit 0 = 0: `instantaneous_speed` is PRESENT.
/// - Bit 0 = 1: `instantaneous_speed` is NOT PRESENT (data fragment).
pub const IndoorBikeData = struct {
    instantaneous_speed_raw: ?u16 = null, // 0.01 km/h
    average_speed_raw: ?u16 = null, // 0.01 km/h
    instantaneous_cadence_raw: ?u16 = null, // 0.5 RPM
    average_cadence_raw: ?u16 = null, // 0.5 RPM
    total_distance_meters: ?u24 = null, // 1 meter
    resistance_level: ?i16 = null, // unitless level
    instantaneous_power_watts: ?i16 = null, // 1 Watt
    average_power_watts: ?i16 = null, // 1 Watt
    expended_energy: ?ExpendedEnergy = null,
    heart_rate_bpm: ?u8 = null,
    metabolic_equivalent_raw: ?u8 = null, // 0.1 MET
    elapsed_time_seconds: ?u16 = null,
    remaining_time_seconds: ?u16 = null,

    // Ergonomic Physical Value Getters
    pub fn speedKmh(self: IndoorBikeData) ?f32 {
        return if (self.instantaneous_speed_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.01 else null;
    }

    pub fn averageSpeedKmh(self: IndoorBikeData) ?f32 {
        return if (self.average_speed_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.01 else null;
    }

    pub fn cadenceRpm(self: IndoorBikeData) ?f32 {
        return if (self.instantaneous_cadence_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.5 else null;
    }

    pub fn averageCadenceRpm(self: IndoorBikeData) ?f32 {
        return if (self.average_cadence_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.5 else null;
    }

    pub fn powerWatts(self: IndoorBikeData) ?i16 {
        return self.instantaneous_power_watts;
    }

    pub fn averagePowerWatts(self: IndoorBikeData) ?i16 {
        return self.average_power_watts;
    }

    pub fn metabolicEquivalent(self: IndoorBikeData) ?f32 {
        return if (self.metabolic_equivalent_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.1 else null;
    }

    /// Parses raw notification bytes into an `IndoorBikeData` struct.
    /// Forward-compatible: accepts trailing bytes.
    pub fn parse(raw: []const u8) ParseError!IndoorBikeData {
        if (raw.len < 2) return error.PayloadTooShort;

        const flags = std.mem.readInt(u16, raw[0..2], .little);
        // Bit 0 = 0 -> Speed present! Bit 0 = 1 -> Speed omitted!
        const speed_present = (flags & 0x0001) == 0;
        const avg_speed_present = (flags & 0x0002) != 0;
        const cadence_present = (flags & 0x0004) != 0;
        const avg_cadence_present = (flags & 0x0008) != 0;
        const distance_present = (flags & 0x0010) != 0;
        const resistance_present = (flags & 0x0020) != 0;
        const power_present = (flags & 0x0040) != 0;
        const avg_power_present = (flags & 0x0080) != 0;
        const energy_present = (flags & 0x0100) != 0;
        const hr_present = (flags & 0x0200) != 0;
        const met_present = (flags & 0x0400) != 0;
        const elapsed_present = (flags & 0x0800) != 0;
        const remaining_present = (flags & 0x1000) != 0;

        var offset: usize = 2;
        var res = IndoorBikeData{};

        if (speed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_speed_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (avg_speed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_speed_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (cadence_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_cadence_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (avg_cadence_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_cadence_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (distance_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            res.total_distance_meters = std.mem.readInt(u24, raw[offset..][0..3], .little);
            offset += 3;
        }

        if (resistance_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.resistance_level = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (power_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_power_watts = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (avg_power_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_power_watts = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (energy_present) {
            if (raw.len < offset + 5) return error.PayloadTooShort;
            res.expended_energy = ExpendedEnergy{
                .total_kcal = std.mem.readInt(u16, raw[offset..][0..2], .little),
                .energy_per_hour_kcal = std.mem.readInt(u16, raw[offset + 2 ..][0..2], .little),
                .energy_per_minute_kcal = raw[offset + 4],
            };
            offset += 5;
        }

        if (hr_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.heart_rate_bpm = raw[offset];
            offset += 1;
        }

        if (met_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.metabolic_equivalent_raw = raw[offset];
            offset += 1;
        }

        if (elapsed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.elapsed_time_seconds = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        if (remaining_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.remaining_time_seconds = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        return res;
    }

    /// Serializes into caller-provided buffer, returning sub-slice of written bytes.
    pub fn encode(self: IndoorBikeData, out_buf: []u8) EncodeError![]u8 {
        var flags: u16 = 0;
        var required_len: usize = 2;

        if (self.instantaneous_speed_raw == null) {
            // Inverted: Bit 0 = 1 means speed NOT present!
            flags |= 0x0001;
        } else {
            required_len += 2;
        }

        if (self.average_speed_raw != null) {
            flags |= 0x0002;
            required_len += 2;
        }
        if (self.instantaneous_cadence_raw != null) {
            flags |= 0x0004;
            required_len += 2;
        }
        if (self.average_cadence_raw != null) {
            flags |= 0x0008;
            required_len += 2;
        }
        if (self.total_distance_meters != null) {
            flags |= 0x0010;
            required_len += 3;
        }
        if (self.resistance_level != null) {
            flags |= 0x0020;
            required_len += 2;
        }
        if (self.instantaneous_power_watts != null) {
            flags |= 0x0040;
            required_len += 2;
        }
        if (self.average_power_watts != null) {
            flags |= 0x0080;
            required_len += 2;
        }
        if (self.expended_energy != null) {
            flags |= 0x0100;
            required_len += 5;
        }
        if (self.heart_rate_bpm != null) {
            flags |= 0x0200;
            required_len += 1;
        }
        if (self.metabolic_equivalent_raw != null) {
            flags |= 0x0400;
            required_len += 1;
        }
        if (self.elapsed_time_seconds != null) {
            flags |= 0x0800;
            required_len += 2;
        }
        if (self.remaining_time_seconds != null) {
            flags |= 0x1000;
            required_len += 2;
        }

        if (out_buf.len < required_len) return error.BufferTooSmall;

        std.mem.writeInt(u16, out_buf[0..2], flags, .little);
        var offset: usize = 2;

        if (self.instantaneous_speed_raw) |spd| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], spd, .little);
            offset += 2;
        }
        if (self.average_speed_raw) |aspd| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], aspd, .little);
            offset += 2;
        }
        if (self.instantaneous_cadence_raw) |cad| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], cad, .little);
            offset += 2;
        }
        if (self.average_cadence_raw) |acad| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], acad, .little);
            offset += 2;
        }
        if (self.total_distance_meters) |dist| {
            std.mem.writeInt(u24, out_buf[offset..][0..3], dist, .little);
            offset += 3;
        }
        if (self.resistance_level) |res_lvl| {
            std.mem.writeInt(i16, out_buf[offset..][0..2], res_lvl, .little);
            offset += 2;
        }
        if (self.instantaneous_power_watts) |pwr| {
            std.mem.writeInt(i16, out_buf[offset..][0..2], pwr, .little);
            offset += 2;
        }
        if (self.average_power_watts) |apwr| {
            std.mem.writeInt(i16, out_buf[offset..][0..2], apwr, .little);
            offset += 2;
        }
        if (self.expended_energy) |ee| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], ee.total_kcal, .little);
            std.mem.writeInt(u16, out_buf[offset + 2 ..][0..2], ee.energy_per_hour_kcal, .little);
            out_buf[offset + 4] = ee.energy_per_minute_kcal;
            offset += 5;
        }
        if (self.heart_rate_bpm) |hr| {
            out_buf[offset] = hr;
            offset += 1;
        }
        if (self.metabolic_equivalent_raw) |met| {
            out_buf[offset] = met;
            offset += 1;
        }
        if (self.elapsed_time_seconds) |el| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], el, .little);
            offset += 2;
        }
        if (self.remaining_time_seconds) |rem| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], rem, .little);
            offset += 2;
        }

        return out_buf[0..offset];
    }
};

/// Accumulator for multi-packet FTMS telemetry when `more_data` (Bit 0) is set.
pub const IndoorBikeAccumulator = struct {
    current: IndoorBikeData = .{},

    pub fn update(self: *IndoorBikeAccumulator, data: IndoorBikeData) void {
        if (data.instantaneous_speed_raw) |v| self.current.instantaneous_speed_raw = v;
        if (data.average_speed_raw) |v| self.current.average_speed_raw = v;
        if (data.instantaneous_cadence_raw) |v| self.current.instantaneous_cadence_raw = v;
        if (data.average_cadence_raw) |v| self.current.average_cadence_raw = v;
        if (data.total_distance_meters) |v| self.current.total_distance_meters = v;
        if (data.resistance_level) |v| self.current.resistance_level = v;
        if (data.instantaneous_power_watts) |v| self.current.instantaneous_power_watts = v;
        if (data.average_power_watts) |v| self.current.average_power_watts = v;
        if (data.expended_energy) |v| self.current.expended_energy = v;
        if (data.heart_rate_bpm) |v| self.current.heart_rate_bpm = v;
        if (data.metabolic_equivalent_raw) |v| self.current.metabolic_equivalent_raw = v;
        if (data.elapsed_time_seconds) |v| self.current.elapsed_time_seconds = v;
        if (data.remaining_time_seconds) |v| self.current.remaining_time_seconds = v;
    }

    pub fn get(self: *const IndoorBikeAccumulator) IndoorBikeData {
        return self.current;
    }

    pub fn reset(self: *IndoorBikeAccumulator) void {
        self.current = .{};
    }
};

/// Decoded Treadmill Data characteristic value (0x2ACD).
pub const TreadmillData = struct {
    instantaneous_speed_raw: ?u16 = null, // 0.01 km/h (Bit 0 = 0 -> present)
    average_speed_raw: ?u16 = null, // 0.01 km/h
    total_distance_meters: ?u24 = null, // 1 m
    inclination_raw: ?i16 = null, // 0.1 %
    ramp_angle_raw: ?i16 = null, // 0.1 degree
    instantaneous_pace_raw: ?u8 = null, // 0.1 km/min or min/km
    average_pace_raw: ?u8 = null,
    expended_energy: ?ExpendedEnergy = null,
    heart_rate_bpm: ?u8 = null,
    metabolic_equivalent_raw: ?u8 = null,
    elapsed_time_seconds: ?u16 = null,
    remaining_time_seconds: ?u16 = null,

    pub fn speedKmh(self: TreadmillData) ?f32 {
        return if (self.instantaneous_speed_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.01 else null;
    }

    pub fn inclinationPercent(self: TreadmillData) ?f32 {
        return if (self.inclination_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.1 else null;
    }

    pub fn parse(raw: []const u8) ParseError!TreadmillData {
        if (raw.len < 2) return error.PayloadTooShort;

        const flags = std.mem.readInt(u16, raw[0..2], .little);
        const speed_present = (flags & 0x0001) == 0;
        const avg_speed_present = (flags & 0x0002) != 0;
        const dist_present = (flags & 0x0004) != 0;
        const incl_present = (flags & 0x0008) != 0;
        // Bit 4: elevation gain (2x u16) - skipped if not requested
        const elev_present = (flags & 0x0010) != 0;
        const pace_present = (flags & 0x0020) != 0;
        const avg_pace_present = (flags & 0x0040) != 0;
        const energy_present = (flags & 0x0080) != 0;
        const hr_present = (flags & 0x0100) != 0;
        const met_present = (flags & 0x0200) != 0;
        const elapsed_present = (flags & 0x0400) != 0;
        const remaining_present = (flags & 0x0800) != 0;

        var offset: usize = 2;
        var res = TreadmillData{};

        if (speed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_speed_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (avg_speed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_speed_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (dist_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            res.total_distance_meters = std.mem.readInt(u24, raw[offset..][0..3], .little);
            offset += 3;
        }
        if (incl_present) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            res.inclination_raw = std.mem.readInt(i16, raw[offset..][0..2], .little);
            res.ramp_angle_raw = std.mem.readInt(i16, raw[offset + 2 ..][0..2], .little);
            offset += 4;
        }
        if (elev_present) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            offset += 4; // positive (u16) + negative (u16)
        }
        if (pace_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.instantaneous_pace_raw = raw[offset];
            offset += 1;
        }
        if (avg_pace_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.average_pace_raw = raw[offset];
            offset += 1;
        }
        if (energy_present) {
            if (raw.len < offset + 5) return error.PayloadTooShort;
            res.expended_energy = ExpendedEnergy{
                .total_kcal = std.mem.readInt(u16, raw[offset..][0..2], .little),
                .energy_per_hour_kcal = std.mem.readInt(u16, raw[offset + 2 ..][0..2], .little),
                .energy_per_minute_kcal = raw[offset + 4],
            };
            offset += 5;
        }
        if (hr_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.heart_rate_bpm = raw[offset];
            offset += 1;
        }
        if (met_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.metabolic_equivalent_raw = raw[offset];
            offset += 1;
        }
        if (elapsed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.elapsed_time_seconds = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (remaining_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.remaining_time_seconds = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        return res;
    }
};

/// Decoded Rower Data characteristic value (0x2AD1).
pub const RowerData = struct {
    stroke_rate_raw: ?u8 = null, // 0.5 SPM (Bit 0 = 0 -> present)
    stroke_count: ?u16 = null, // (Bit 0 = 0 -> present)
    average_stroke_rate_raw: ?u8 = null, // 0.5 SPM
    total_distance_meters: ?u24 = null, // 1 m
    instantaneous_pace_seconds_500m: ?u16 = null,
    average_pace_seconds_500m: ?u16 = null,
    instantaneous_power_watts: ?i16 = null,
    average_power_watts: ?i16 = null,
    resistance_level: ?i16 = null,
    expended_energy: ?ExpendedEnergy = null,
    heart_rate_bpm: ?u8 = null,
    elapsed_time_seconds: ?u16 = null,

    pub fn strokeRateSpm(self: RowerData) ?f32 {
        return if (self.stroke_rate_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.5 else null;
    }

    pub fn parse(raw: []const u8) ParseError!RowerData {
        if (raw.len < 2) return error.PayloadTooShort;

        const flags = std.mem.readInt(u16, raw[0..2], .little);
        const stroke_present = (flags & 0x0001) == 0;
        const avg_stroke_present = (flags & 0x0002) != 0;
        const dist_present = (flags & 0x0004) != 0;
        const pace_present = (flags & 0x0008) != 0;
        const avg_pace_present = (flags & 0x0010) != 0;
        const pwr_present = (flags & 0x0020) != 0;
        const avg_pwr_present = (flags & 0x0040) != 0;
        const res_present = (flags & 0x0080) != 0;
        const energy_present = (flags & 0x0100) != 0;
        const hr_present = (flags & 0x0200) != 0;
        // Met is bit 10 (0x0400)
        const elapsed_present = (flags & 0x0800) != 0;

        var offset: usize = 2;
        var res = RowerData{};

        if (stroke_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            res.stroke_rate_raw = raw[offset];
            res.stroke_count = std.mem.readInt(u16, raw[offset + 1 ..][0..2], .little);
            offset += 3;
        }
        if (avg_stroke_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.average_stroke_rate_raw = raw[offset];
            offset += 1;
        }
        if (dist_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            res.total_distance_meters = std.mem.readInt(u24, raw[offset..][0..3], .little);
            offset += 3;
        }
        if (pace_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_pace_seconds_500m = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (avg_pace_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_pace_seconds_500m = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (pwr_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.instantaneous_power_watts = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (avg_pwr_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.average_power_watts = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (res_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.resistance_level = std.mem.readInt(i16, raw[offset..][0..2], .little);
            offset += 2;
        }
        if (energy_present) {
            if (raw.len < offset + 5) return error.PayloadTooShort;
            res.expended_energy = ExpendedEnergy{
                .total_kcal = std.mem.readInt(u16, raw[offset..][0..2], .little),
                .energy_per_hour_kcal = std.mem.readInt(u16, raw[offset + 2 ..][0..2], .little),
                .energy_per_minute_kcal = raw[offset + 4],
            };
            offset += 5;
        }
        if (hr_present) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            res.heart_rate_bpm = raw[offset];
            offset += 1;
        }
        if (elapsed_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            res.elapsed_time_seconds = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        return res;
    }
};

// ============================================================================
// Fitness Machine Control Point (0x2AD9)
// ============================================================================

pub const FitnessMachineControlPoint = struct {
    pub const OpCode = enum(u8) {
        request_control = 0x00,
        reset = 0x01,
        set_target_speed = 0x02,
        set_target_inclination = 0x03,
        set_target_resistance_level = 0x04,
        set_target_power = 0x05,
        start_or_resume = 0x07,
        stop_or_pause = 0x08,
        set_indoor_bike_simulation_parameters = 0x11,
        response_code = 0x80,
        _,
    };

    pub const ResultCode = enum(u8) {
        success = 0x01,
        op_code_not_supported = 0x02,
        invalid_parameter = 0x03,
        operation_failed = 0x04,
        control_not_permitted = 0x05,
        _,
    };

    pub const IndoorBikeSimulationParams = struct {
        wind_speed_raw: i16, // 0.001 m/s (-32.768 to +32.767 m/s)
        grade_raw: i16, // 0.01 % (-40.00 to +40.00 %)
        crr_raw: u8, // 0.0001 (e.g. 40 = 0.0040)
        cw_raw: u8, // 0.01 kg/m (e.g. 51 = 0.51 kg/m)

        pub fn fromValues(wind_mps: f32, grade_percent: f32, crr: f32, cw: f32) IndoorBikeSimulationParams {
            return .{
                .wind_speed_raw = @intFromFloat(wind_mps * 1000.0),
                .grade_raw = @intFromFloat(grade_percent * 100.0),
                .crr_raw = @intFromFloat(crr * 10000.0),
                .cw_raw = @intFromFloat(cw * 100.0),
            };
        }
    };

    pub const Request = union(OpCode) {
        request_control: void,
        reset: void,
        set_target_speed: u16, // 0.01 km/h
        set_target_inclination: i16, // 0.1 %
        set_target_resistance_level: u8, // level index
        set_target_power: i16, // Watts (ERG Mode)
        start_or_resume: void,
        stop_or_pause: bool, // true = stop (0x01), false = pause (0x02)
        set_indoor_bike_simulation_parameters: IndoorBikeSimulationParams,
        response_code: void,

        /// Serializes the control point command into caller-provided buffer.
        pub fn encode(self: Request, out_buf: []u8) EncodeError![]u8 {
            switch (self) {
                .request_control => {
                    if (out_buf.len < 1) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.request_control);
                    return out_buf[0..1];
                },
                .reset => {
                    if (out_buf.len < 1) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.reset);
                    return out_buf[0..1];
                },
                .set_target_speed => |spd| {
                    if (out_buf.len < 3) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.set_target_speed);
                    std.mem.writeInt(u16, out_buf[1..3], spd, .little);
                    return out_buf[0..3];
                },
                .set_target_inclination => |incl| {
                    if (out_buf.len < 3) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.set_target_inclination);
                    std.mem.writeInt(i16, out_buf[1..3], incl, .little);
                    return out_buf[0..3];
                },
                .set_target_resistance_level => |lvl| {
                    if (out_buf.len < 2) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.set_target_resistance_level);
                    out_buf[1] = lvl;
                    return out_buf[0..2];
                },
                .set_target_power => |watts| {
                    if (out_buf.len < 3) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.set_target_power);
                    std.mem.writeInt(i16, out_buf[1..3], watts, .little);
                    return out_buf[0..3];
                },
                .start_or_resume => {
                    if (out_buf.len < 1) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.start_or_resume);
                    return out_buf[0..1];
                },
                .stop_or_pause => |is_stop| {
                    if (out_buf.len < 2) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.stop_or_pause);
                    out_buf[1] = if (is_stop) 0x01 else 0x02;
                    return out_buf[0..2];
                },
                .set_indoor_bike_simulation_parameters => |sim| {
                    if (out_buf.len < 7) return error.BufferTooSmall;
                    out_buf[0] = @intFromEnum(OpCode.set_indoor_bike_simulation_parameters);
                    std.mem.writeInt(i16, out_buf[1..3], sim.wind_speed_raw, .little);
                    std.mem.writeInt(i16, out_buf[3..5], sim.grade_raw, .little);
                    out_buf[5] = sim.crr_raw;
                    out_buf[6] = sim.cw_raw;
                    return out_buf[0..7];
                },
                .response_code => return error.InvalidData,
            }
        }
    };

    pub const Response = struct {
        request_op_code: OpCode,
        result_code: ResultCode,

        pub fn isSuccess(self: Response) bool {
            return self.result_code == .success;
        }

        pub fn parse(raw: []const u8) ParseError!Response {
            if (raw.len < 3) return error.PayloadTooShort;
            if (raw[0] != @intFromEnum(OpCode.response_code)) return error.InvalidData;

            return Response{
                .request_op_code = @enumFromInt(raw[1]),
                .result_code = @enumFromInt(raw[2]),
            };
        }

        pub fn encode(self: Response, out_buf: []u8) EncodeError![]u8 {
            if (out_buf.len < 3) return error.BufferTooSmall;
            out_buf[0] = @intFromEnum(OpCode.response_code);
            out_buf[1] = @intFromEnum(self.request_op_code);
            out_buf[2] = @intFromEnum(self.result_code);
            return out_buf[0..3];
        }
    };
};

// ============================================================================
// Unit Tests
// ============================================================================

test "IndoorBikeData: Bit 0 inverted More Data handling" {
    // Packet A: more_data = 0 -> Speed IS PRESENT (25.50 km/h = 2550 = 0x09F6)
    var raw_with_speed = [_]u8{
        0x00, 0x00, // flags: bit 0 = 0 -> speed present
        0xF6, 0x09, // instantaneous speed: 25.50 km/h
    };
    const data_a = try IndoorBikeData.parse(&raw_with_speed);
    try std.testing.expectEqual(@as(?u16, 2550), data_a.instantaneous_speed_raw);
    try std.testing.expectEqual(@as(?f32, 25.50), data_a.speedKmh());

    // Packet B: more_data = 1 -> Speed IS OMITTED, cadence present (85.0 RPM = 170 = 0x00AA)
    // Flags: 0x0001 (more data) | 0x0004 (cadence) = 0x0005
    var raw_omitted_speed = [_]u8{
        0x05, 0x00, // flags: bit 0 = 1, bit 2 = 1
        0xAA, 0x00, // instantaneous cadence: 170 * 0.5 = 85 RPM
    };
    const data_b = try IndoorBikeData.parse(&raw_omitted_speed);
    try std.testing.expect(data_b.instantaneous_speed_raw == null);
    try std.testing.expectEqual(@as(?u16, 170), data_b.instantaneous_cadence_raw);
    try std.testing.expectEqual(@as(?f32, 85.0), data_b.cadenceRpm());
}

test "IndoorBikeData: u24 Total Distance and Power parsing" {
    // Flags: speed (bit 0 = 0), distance (bit 4 = 1), power (bit 6 = 1) -> flags = 0x0050
    // Speed: 32.00 km/h (3200 = 0x0C80)
    // Distance: 15,234 meters (0x003B82 -> little endian: 0x82, 0x3B, 0x00)
    // Power: 250 Watts (0x00FA)
    const raw = [_]u8{
        0x50, 0x00, // flags
        0x80, 0x0C, // speed 3200
        0x82, 0x3B, 0x00, // distance 15234 m (u24)
        0xFA, 0x00, // power 250 W
    };

    const data = try IndoorBikeData.parse(&raw);
    try std.testing.expectEqual(@as(?u16, 3200), data.instantaneous_speed_raw);
    try std.testing.expectEqual(@as(?u24, 15234), data.total_distance_meters);
    try std.testing.expectEqual(@as(?i16, 250), data.instantaneous_power_watts);
}

test "IndoorBikeAccumulator: merges multi-packet fragment telemetry" {
    var acc = IndoorBikeAccumulator{};

    // Fragment 1: Speed (30.00 km/h) + Cadence (90 RPM)
    const frag1 = IndoorBikeData{
        .instantaneous_speed_raw = 3000,
        .instantaneous_cadence_raw = 180,
    };
    acc.update(frag1);

    // Fragment 2: Power (280 W) + Distance (5000 m) with speed omitted
    const frag2 = IndoorBikeData{
        .instantaneous_power_watts = 280,
        .total_distance_meters = 5000,
    };
    acc.update(frag2);

    const merged = acc.get();
    try std.testing.expectEqual(@as(?f32, 30.0), merged.speedKmh());
    try std.testing.expectEqual(@as(?f32, 90.0), merged.cadenceRpm());
    try std.testing.expectEqual(@as(?i16, 280), merged.powerWatts());
    try std.testing.expectEqual(@as(?u24, 5000), merged.total_distance_meters);
}

test "FitnessMachineControlPoint: ERG Mode 0x05 and SIM Mode 0x11 encoding" {
    var buf: [16]u8 = undefined;

    // 1. Set Target Power 250 Watts
    const erg_req = FitnessMachineControlPoint.Request{ .set_target_power = 250 };
    const erg_bytes = try erg_req.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0xFA, 0x00 }, erg_bytes);

    // 2. Set Indoor Bike Simulation: Wind +2.0 m/s, Grade +7.5%, Crr 0.0040, Cw 0.51 kg/m
    const sim_params = FitnessMachineControlPoint.IndoorBikeSimulationParams.fromValues(2.0, 7.5, 0.0040, 0.51);
    const sim_req = FitnessMachineControlPoint.Request{ .set_indoor_bike_simulation_parameters = sim_params };
    const sim_bytes = try sim_req.encode(&buf);
    try std.testing.expectEqual(@as(usize, 7), sim_bytes.len);
    try std.testing.expectEqual(@as(u8, 0x11), sim_bytes[0]);
    try std.testing.expectEqual(@as(i16, 2000), std.mem.readInt(i16, sim_bytes[1..3], .little)); // 2.0 * 1000
    try std.testing.expectEqual(@as(i16, 750), std.mem.readInt(i16, sim_bytes[3..5], .little)); // 7.5 * 100
    try std.testing.expectEqual(@as(u8, 40), sim_bytes[5]); // 0.0040 * 10000
    try std.testing.expectEqual(@as(u8, 51), sim_bytes[6]); // 0.51 * 100
}

test "FitnessMachineControlPoint: response parsing" {
    const raw_resp = [_]u8{ 0x80, 0x11, 0x01 }; // Response to 0x11 (Simulation), Result: Success (0x01)
    const resp = try FitnessMachineControlPoint.Response.parse(&raw_resp);
    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqual(FitnessMachineControlPoint.OpCode.set_indoor_bike_simulation_parameters, resp.request_op_code);
    try std.testing.expectEqual(FitnessMachineControlPoint.ResultCode.success, resp.result_code);
}
