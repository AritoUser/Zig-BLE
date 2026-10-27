//! # Bluetooth SIG Pulse Oximeter Profile (PLXP)
//!
//! Service UUID: 0x1822 (org.bluetooth.service.pulse_oximeter)
//! Characteristics:
//! - PLX Spot-Check Measurement: 0x2A5E (Indicate)
//! - PLX Continuous Measurement: 0x2A5F (Notify)
//! - PLX Features:               0x2A60 (Read)
//!
//! Specification: Bluetooth SIG Pulse Oximeter Profile v1.0.1 / Core Spec v5.4.
//! Zero-allocation implementation with IEEE-11073 SFLOAT representations.

const std = @import("std");
const core = @import("../core/mod.zig");
const Sfloat = core.Sfloat;

pub const ParseError = error{
    PayloadTooShort,
    BufferOverflow,
    InvalidData,
};

pub const EncodeError = error{
    BufferTooSmall,
    InvalidData,
};

/// PLX Features bitfield (UUID 0x2A60).
pub const PlxFeatures = packed struct(u16) {
    measurement_status_supported: bool = false,
    device_and_sensor_status_supported: bool = false,
    measurement_storage_for_spot_check_supported: bool = false,
    timestamp_for_spot_check_supported: bool = false,
    spo2pr_fast_supported: bool = false,
    spo2pr_slow_supported: bool = false,
    pulse_amplitude_index_supported: bool = false,
    multiple_bonds_supported: bool = false,
    reserved: u8 = 0,

    pub fn parse(raw: []const u8) ParseError!PlxFeatures {
        if (raw.len < 2) return error.PayloadTooShort;
        const bits = std.mem.readInt(u16, raw[0..2], .little);
        return @bitCast(bits);
    }

    pub fn encode(self: PlxFeatures, out_buf: []u8) EncodeError![]u8 {
        if (out_buf.len < 2) return error.BufferTooSmall;
        const bits: u16 = @bitCast(self);
        std.mem.writeInt(u16, out_buf[0..2], bits, .little);
        return out_buf[0..2];
    }
};

/// Measurement Status Bitfield (16-bit).
pub const PlxMeasurementStatus = packed struct(u16) {
    reserved_0_4: u5 = 0,
    measurement_ongoing: bool = false, // Bit 5
    early_estimate: bool = false, // Bit 6
    validated_data: bool = false, // Bit 7
    fully_qualified_data: bool = false, // Bit 8
    data_from_measurement_storage: bool = false, // Bit 9
    data_for_demonstration: bool = false, // Bit 10
    data_for_testing: bool = false, // Bit 11
    calibration_ongoing: bool = false, // Bit 12
    measurement_unavailable: bool = false, // Bit 13
    questionable_measurement: bool = false, // Bit 14
    reserved_15: bool = false, // Bit 15
};

/// Device and Sensor Status Bitfield (24-bit).
///
/// NOTE: Because @sizeOf(packed struct(u24)) == 4 in Zig due to alignment,
/// serializing and deserializing MUST be performed through explicit 24-bit integer bitcasts.
pub const PlxDeviceAndSensorStatus = packed struct(u24) {
    extended_display_update_ongoing: bool = false, // Bit 0
    equipment_malfunction: bool = false, // Bit 1
    signal_processing_irregularity: bool = false, // Bit 2
    inadequate_signal: bool = false, // Bit 3
    poor_signal: bool = false, // Bit 4
    low_perfusion: bool = false, // Bit 5
    erratic_signal: bool = false, // Bit 6
    non_pulsatile: bool = false, // Bit 7
    questioning_pulse: bool = false, // Bit 8
    signal_analysis_ongoing: bool = false, // Bit 9
    sensor_interface_detected: bool = false, // Bit 10
    sensor_unconnected: bool = false, // Bit 11
    unknown_sensor_connected: bool = false, // Bit 12
    sensor_displaced: bool = false, // Bit 13
    sensor_malfunctioning: bool = false, // Bit 14
    sensor_disconnected: bool = false, // Bit 15
    reserved: u8 = 0, // Bits 16..23

    pub fn fromInt(val: u24) PlxDeviceAndSensorStatus {
        return @bitCast(val);
    }

    pub fn toInt(self: PlxDeviceAndSensorStatus) u24 {
        return @bitCast(self);
    }
};

/// PLX Spot-Check Measurement (0x2A5E).
pub const PlxSpotCheckMeasurement = struct {
    spo2: Sfloat,
    pulse_rate: Sfloat,
    timestamp: ?[7]u8 = null, // Year (u16), Month (u8), Day (u8), Hours (u8), Minutes (u8), Seconds (u8)
    measurement_status: ?PlxMeasurementStatus = null,
    device_and_sensor_status: ?PlxDeviceAndSensorStatus = null,
    pulse_amplitude_index: ?Sfloat = null,

    pub fn spo2Percent(self: PlxSpotCheckMeasurement) ?f32 {
        if (self.spo2.isSpecial()) return null;
        return self.spo2.toFloat();
    }

    pub fn pulseRateBpm(self: PlxSpotCheckMeasurement) ?f32 {
        if (self.pulse_rate.isSpecial()) return null;
        return self.pulse_rate.toFloat();
    }

    pub fn pulseAmplitudeIndexPercent(self: PlxSpotCheckMeasurement) ?f32 {
        if (self.pulse_amplitude_index) |pai| {
            if (pai.isSpecial()) return null;
            return pai.toFloat();
        }
        return null;
    }

    /// Parses raw bytes into a `PlxSpotCheckMeasurement`.
    /// Forward-compatible: accepts trailing bytes.
    pub fn parse(raw: []const u8) ParseError!PlxSpotCheckMeasurement {
        if (raw.len < 5) return error.PayloadTooShort; // flags (1) + spo2 (2) + pr (2)

        const flags = raw[0];
        const timestamp_present = (flags & 0x01) != 0;
        const measurement_status_present = (flags & 0x02) != 0;
        const dev_sensor_status_present = (flags & 0x04) != 0;
        const pai_present = (flags & 0x08) != 0;

        var offset: usize = 1;
        const spo2_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
        offset += 2;
        const pr_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
        offset += 2;

        var timestamp: ?[7]u8 = null;
        if (timestamp_present) {
            if (raw.len < offset + 7) return error.PayloadTooShort;
            var ts: [7]u8 = undefined;
            @memcpy(&ts, raw[offset .. offset + 7]);
            timestamp = ts;
            offset += 7;
        }

        var measurement_status: ?PlxMeasurementStatus = null;
        if (measurement_status_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            const ms_bits = std.mem.readInt(u16, raw[offset..][0..2], .little);
            measurement_status = @bitCast(ms_bits);
            offset += 2;
        }

        var dev_sensor_status: ?PlxDeviceAndSensorStatus = null;
        if (dev_sensor_status_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            const dss_bits = std.mem.readInt(u24, raw[offset..][0..3], .little);
            dev_sensor_status = @bitCast(dss_bits);
            offset += 3;
        }

        var pulse_amplitude_index: ?Sfloat = null;
        if (pai_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            const pai_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            pulse_amplitude_index = Sfloat.fromRaw(pai_raw);
            offset += 2;
        }

        return PlxSpotCheckMeasurement{
            .spo2 = Sfloat.fromRaw(spo2_raw),
            .pulse_rate = Sfloat.fromRaw(pr_raw),
            .timestamp = timestamp,
            .measurement_status = measurement_status,
            .device_and_sensor_status = dev_sensor_status,
            .pulse_amplitude_index = pulse_amplitude_index,
        };
    }

    /// Serializes into caller-provided buffer, returning sub-slice of written bytes.
    pub fn encode(self: PlxSpotCheckMeasurement, out_buf: []u8) EncodeError![]u8 {
        var flags: u8 = 0;
        var required_len: usize = 5;

        if (self.timestamp != null) {
            flags |= 0x01;
            required_len += 7;
        }
        if (self.measurement_status != null) {
            flags |= 0x02;
            required_len += 2;
        }
        if (self.device_and_sensor_status != null) {
            flags |= 0x04;
            required_len += 3;
        }
        if (self.pulse_amplitude_index != null) {
            flags |= 0x08;
            required_len += 2;
        }

        if (out_buf.len < required_len) return error.BufferTooSmall;

        out_buf[0] = flags;
        var offset: usize = 1;

        std.mem.writeInt(u16, out_buf[offset..][0..2], self.spo2.raw, .little);
        offset += 2;
        std.mem.writeInt(u16, out_buf[offset..][0..2], self.pulse_rate.raw, .little);
        offset += 2;

        if (self.timestamp) |ts| {
            @memcpy(out_buf[offset .. offset + 7], &ts);
            offset += 7;
        }

        if (self.measurement_status) |ms| {
            const bits: u16 = @bitCast(ms);
            std.mem.writeInt(u16, out_buf[offset..][0..2], bits, .little);
            offset += 2;
        }

        if (self.device_and_sensor_status) |dss| {
            const bits: u24 = @bitCast(dss);
            std.mem.writeInt(u24, out_buf[offset..][0..3], bits, .little);
            offset += 3;
        }

        if (self.pulse_amplitude_index) |pai| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], pai.raw, .little);
            offset += 2;
        }

        return out_buf[0..offset];
    }
};

/// PLX Continuous Measurement (0x2A5F).
pub const PlxContinuousMeasurement = struct {
    spo2_normal: Sfloat,
    pulse_rate_normal: Sfloat,
    spo2_fast: ?Sfloat = null,
    pulse_rate_fast: ?Sfloat = null,
    spo2_slow: ?Sfloat = null,
    pulse_rate_slow: ?Sfloat = null,
    measurement_status: ?PlxMeasurementStatus = null,
    device_and_sensor_status: ?PlxDeviceAndSensorStatus = null,
    pulse_amplitude_index: ?Sfloat = null,

    pub fn spo2Percent(self: PlxContinuousMeasurement) ?f32 {
        if (self.spo2_normal.isSpecial()) return null;
        return self.spo2_normal.toFloat();
    }

    pub fn pulseRateBpm(self: PlxContinuousMeasurement) ?f32 {
        if (self.pulse_rate_normal.isSpecial()) return null;
        return self.pulse_rate_normal.toFloat();
    }

    pub fn spo2FastPercent(self: PlxContinuousMeasurement) ?f32 {
        if (self.spo2_fast) |s| {
            if (s.isSpecial()) return null;
            return s.toFloat();
        }
        return null;
    }

    pub fn pulseRateFastBpm(self: PlxContinuousMeasurement) ?f32 {
        if (self.pulse_rate_fast) |p| {
            if (p.isSpecial()) return null;
            return p.toFloat();
        }
        return null;
    }

    pub fn spo2SlowPercent(self: PlxContinuousMeasurement) ?f32 {
        if (self.spo2_slow) |s| {
            if (s.isSpecial()) return null;
            return s.toFloat();
        }
        return null;
    }

    pub fn pulseRateSlowBpm(self: PlxContinuousMeasurement) ?f32 {
        if (self.pulse_rate_slow) |p| {
            if (p.isSpecial()) return null;
            return p.toFloat();
        }
        return null;
    }

    pub fn pulseAmplitudeIndexPercent(self: PlxContinuousMeasurement) ?f32 {
        if (self.pulse_amplitude_index) |pai| {
            if (pai.isSpecial()) return null;
            return pai.toFloat();
        }
        return null;
    }

    /// Parses raw bytes into a `PlxContinuousMeasurement`.
    /// Forward-compatible: accepts trailing bytes.
    pub fn parse(raw: []const u8) ParseError!PlxContinuousMeasurement {
        if (raw.len < 5) return error.PayloadTooShort;

        const flags = raw[0];
        const fast_present = (flags & 0x01) != 0;
        const slow_present = (flags & 0x02) != 0;
        const ms_present = (flags & 0x04) != 0;
        const dss_present = (flags & 0x08) != 0;
        const pai_present = (flags & 0x10) != 0;

        var offset: usize = 1;
        const spo2_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
        offset += 2;
        const pr_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
        offset += 2;

        var spo2_fast: ?Sfloat = null;
        var pr_fast: ?Sfloat = null;
        if (fast_present) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            spo2_fast = Sfloat.fromRaw(std.mem.readInt(u16, raw[offset..][0..2], .little));
            offset += 2;
            pr_fast = Sfloat.fromRaw(std.mem.readInt(u16, raw[offset..][0..2], .little));
            offset += 2;
        }

        var spo2_slow: ?Sfloat = null;
        var pr_slow: ?Sfloat = null;
        if (slow_present) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            spo2_slow = Sfloat.fromRaw(std.mem.readInt(u16, raw[offset..][0..2], .little));
            offset += 2;
            pr_slow = Sfloat.fromRaw(std.mem.readInt(u16, raw[offset..][0..2], .little));
            offset += 2;
        }

        var measurement_status: ?PlxMeasurementStatus = null;
        if (ms_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            const ms_bits = std.mem.readInt(u16, raw[offset..][0..2], .little);
            measurement_status = @bitCast(ms_bits);
            offset += 2;
        }

        var dev_sensor_status: ?PlxDeviceAndSensorStatus = null;
        if (dss_present) {
            if (raw.len < offset + 3) return error.PayloadTooShort;
            const dss_bits = std.mem.readInt(u24, raw[offset..][0..3], .little);
            dev_sensor_status = @bitCast(dss_bits);
            offset += 3;
        }

        var pulse_amplitude_index: ?Sfloat = null;
        if (pai_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            const pai_raw = std.mem.readInt(u16, raw[offset..][0..2], .little);
            pulse_amplitude_index = Sfloat.fromRaw(pai_raw);
            offset += 2;
        }

        return PlxContinuousMeasurement{
            .spo2_normal = Sfloat.fromRaw(spo2_raw),
            .pulse_rate_normal = Sfloat.fromRaw(pr_raw),
            .spo2_fast = spo2_fast,
            .pulse_rate_fast = pr_fast,
            .spo2_slow = spo2_slow,
            .pulse_rate_slow = pr_slow,
            .measurement_status = measurement_status,
            .device_and_sensor_status = dev_sensor_status,
            .pulse_amplitude_index = pulse_amplitude_index,
        };
    }

    /// Serializes into caller-provided buffer, returning sub-slice of written bytes.
    pub fn encode(self: PlxContinuousMeasurement, out_buf: []u8) EncodeError![]u8 {
        var flags: u8 = 0;
        var required_len: usize = 5;

        if (self.spo2_fast != null and self.pulse_rate_fast != null) {
            flags |= 0x01;
            required_len += 4;
        }
        if (self.spo2_slow != null and self.pulse_rate_slow != null) {
            flags |= 0x02;
            required_len += 4;
        }
        if (self.measurement_status != null) {
            flags |= 0x04;
            required_len += 2;
        }
        if (self.device_and_sensor_status != null) {
            flags |= 0x08;
            required_len += 3;
        }
        if (self.pulse_amplitude_index != null) {
            flags |= 0x10;
            required_len += 2;
        }

        if (out_buf.len < required_len) return error.BufferTooSmall;

        out_buf[0] = flags;
        var offset: usize = 1;

        std.mem.writeInt(u16, out_buf[offset..][0..2], self.spo2_normal.raw, .little);
        offset += 2;
        std.mem.writeInt(u16, out_buf[offset..][0..2], self.pulse_rate_normal.raw, .little);
        offset += 2;

        if (self.spo2_fast) |sf| {
            if (self.pulse_rate_fast) |prf| {
                std.mem.writeInt(u16, out_buf[offset..][0..2], sf.raw, .little);
                offset += 2;
                std.mem.writeInt(u16, out_buf[offset..][0..2], prf.raw, .little);
                offset += 2;
            }
        }

        if (self.spo2_slow) |ss| {
            if (self.pulse_rate_slow) |prs| {
                std.mem.writeInt(u16, out_buf[offset..][0..2], ss.raw, .little);
                offset += 2;
                std.mem.writeInt(u16, out_buf[offset..][0..2], prs.raw, .little);
                offset += 2;
            }
        }

        if (self.measurement_status) |ms| {
            const bits: u16 = @bitCast(ms);
            std.mem.writeInt(u16, out_buf[offset..][0..2], bits, .little);
            offset += 2;
        }

        if (self.device_and_sensor_status) |dss| {
            const bits: u24 = @bitCast(dss);
            std.mem.writeInt(u24, out_buf[offset..][0..3], bits, .little);
            offset += 3;
        }

        if (self.pulse_amplitude_index) |pai| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], pai.raw, .little);
            offset += 2;
        }

        return out_buf[0..offset];
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "PlxSpotCheckMeasurement: parse valid payload and verify Sfloat helper" {
    // Flags: 0x00 (no optional fields)
    // SpO2: 98.0% -> Sfloat(mantissa=98, exp=0) -> raw = 0x0062
    // PR: 72 bpm -> Sfloat(mantissa=72, exp=0) -> raw = 0x0048
    const spo2 = Sfloat.fromFloat(98.0);
    const pr = Sfloat.fromFloat(72.0);

    var raw: [5]u8 = undefined;
    raw[0] = 0x00;
    std.mem.writeInt(u16, raw[1..3], spo2.raw, .little);
    std.mem.writeInt(u16, raw[3..5], pr.raw, .little);

    const m = try PlxSpotCheckMeasurement.parse(&raw);
    try std.testing.expectEqual(@as(?f32, 98.0), m.spo2Percent());
    try std.testing.expectEqual(@as(?f32, 72.0), m.pulseRateBpm());
}

test "PlxSpotCheckMeasurement: round-trip encode and parse with all optional fields" {
    const spo2 = Sfloat.fromFloat(97.5);
    const pr = Sfloat.fromFloat(65.0);
    const pai = Sfloat.fromFloat(3.2);

    const original = PlxSpotCheckMeasurement{
        .spo2 = spo2,
        .pulse_rate = pr,
        .timestamp = [_]u8{ 0xE6, 0x07, 10, 27, 10, 30, 0 }, // Year 2022 (0x07E6), Oct 27, 10:30:00
        .measurement_status = .{ .validated_data = true, .fully_qualified_data = true },
        .device_and_sensor_status = .{ .sensor_interface_detected = true },
        .pulse_amplitude_index = pai,
    };

    var buf: [32]u8 = undefined;
    const written = try original.encode(&buf);
    try std.testing.expect(written.len == 1 + 4 + 7 + 2 + 3 + 2); // 19 bytes

    const parsed = try PlxSpotCheckMeasurement.parse(written);
    try std.testing.expectEqual(original.spo2.raw, parsed.spo2.raw);
    try std.testing.expectEqual(original.pulse_rate.raw, parsed.pulse_rate.raw);
    try std.testing.expectEqual(original.timestamp.?, parsed.timestamp.?);
    try std.testing.expectEqual(original.measurement_status.?.validated_data, parsed.measurement_status.?.validated_data);
    try std.testing.expectEqual(original.device_and_sensor_status.?.sensor_interface_detected, parsed.device_and_sensor_status.?.sensor_interface_detected);
    try std.testing.expectEqual(original.pulse_amplitude_index.?.raw, parsed.pulse_amplitude_index.?.raw);
}

test "PlxContinuousMeasurement: parse with fast/slow and status" {
    var raw = [_]u8{
        0x03, // fast + slow present
        0x61, 0x00, // SpO2 normal: 97
        0x46, 0x00, // PR normal: 70
        0x62, 0x00, // SpO2 fast: 98
        0x48, 0x00, // PR fast: 72
        0x60, 0x00, // SpO2 slow: 96
        0x44, 0x00, // PR slow: 68
    };

    const m = try PlxContinuousMeasurement.parse(&raw);
    try std.testing.expectEqual(@as(?f32, 97.0), m.spo2Percent());
    try std.testing.expectEqual(@as(?f32, 70.0), m.pulseRateBpm());
    try std.testing.expectEqual(@as(?f32, 98.0), m.spo2FastPercent());
    try std.testing.expectEqual(@as(?f32, 72.0), m.pulseRateFastBpm());
    try std.testing.expectEqual(@as(?f32, 96.0), m.spo2SlowPercent());
    try std.testing.expectEqual(@as(?f32, 68.0), m.pulseRateSlowBpm());
}

test "PlxFeatures: parse and encode roundtrip" {
    var raw = [_]u8{ 0b01000111, 0b00000000 };
    const feats = try PlxFeatures.parse(&raw);
    try std.testing.expect(feats.measurement_status_supported);
    try std.testing.expect(feats.device_and_sensor_status_supported);
    try std.testing.expect(feats.measurement_storage_for_spot_check_supported);
    try std.testing.expect(!feats.timestamp_for_spot_check_supported);
    try std.testing.expect(feats.pulse_amplitude_index_supported);

    var buf: [4]u8 = undefined;
    const encoded = try feats.encode(&buf);
    try std.testing.expectEqualSlices(u8, &raw, encoded);
}
