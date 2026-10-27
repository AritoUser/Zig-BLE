//! # Bluetooth SIG Running Speed and Cadence Profile (RSCP)
//!
//! Service UUID: 0x1814 (org.bluetooth.service.running_speed_and_cadence)
//! Characteristics:
//! - RSC Measurement:   0x2A53 (Notify)
//! - RSC Feature:       0x2A54 (Read)
//! - SC Control Point:  0x2A55 (Write, Indicate)
//! - Sensor Location:   0x2A5D (Read)
//!
//! Specification: Bluetooth SIG Running Speed and Cadence Profile v1.0.
//! Zero-allocation implementation with exact 1/256 m/s speed and stride conversions.

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

/// RSC Feature bitfield (UUID 0x2A54).
pub const RscFeature = packed struct(u16) {
    instantaneous_stride_length_measurement_supported: bool = false, // Bit 0
    total_distance_measurement_supported: bool = false, // Bit 1
    walking_or_running_status_supported: bool = false, // Bit 2
    calibration_procedure_supported: bool = false, // Bit 3
    multiple_sensor_locations_supported: bool = false, // Bit 4
    reserved: u11 = 0,

    pub fn parse(raw: []const u8) ParseError!RscFeature {
        if (raw.len < 2) return error.PayloadTooShort;
        const bits = std.mem.readInt(u16, raw[0..2], .little);
        return @bitCast(bits);
    }

    pub fn encode(self: RscFeature, out_buf: []u8) EncodeError![]u8 {
        if (out_buf.len < 2) return error.BufferTooSmall;
        const bits: u16 = @bitCast(self);
        std.mem.writeInt(u16, out_buf[0..2], bits, .little);
        return out_buf[0..2];
    }
};

/// Decoded RSC Measurement characteristic value (0x2A53).
pub const RscMeasurement = struct {
    instantaneous_speed_raw: u16, // 1/256 m/s
    instantaneous_cadence_rpm: u8, // 1 RPM (stride rate)
    instantaneous_stride_length_raw: ?u16 = null, // 1/100 m (centimeters)
    total_distance_raw: ?u32 = null, // 1/10 m (decimeters)
    is_running: bool = false, // Bit 2: false = walking, true = running

    // Ergonomic Physical Value Getters
    pub fn speedMetersPerSecond(self: RscMeasurement) f32 {
        return @as(f32, @floatFromInt(self.instantaneous_speed_raw)) / 256.0;
    }

    pub fn speedKilometersPerHour(self: RscMeasurement) f32 {
        return self.speedMetersPerSecond() * 3.6;
    }

    pub fn cadenceRpm(self: RscMeasurement) u8 {
        return self.instantaneous_cadence_rpm;
    }

    pub fn strideLengthMeters(self: RscMeasurement) ?f32 {
        return if (self.instantaneous_stride_length_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.01 else null;
    }

    pub fn totalDistanceMeters(self: RscMeasurement) ?f32 {
        return if (self.total_distance_raw) |raw| @as(f32, @floatFromInt(raw)) * 0.1 else null;
    }

    /// Parses raw notification bytes into an `RscMeasurement`.
    /// Forward-compatible: accepts trailing bytes.
    pub fn parse(raw: []const u8) ParseError!RscMeasurement {
        if (raw.len < 4) return error.PayloadTooShort; // flags (1) + speed (2) + cadence (1)

        const flags = raw[0];
        const stride_present = (flags & 0x01) != 0;
        const dist_present = (flags & 0x02) != 0;
        const is_running = (flags & 0x04) != 0;

        const speed_raw = std.mem.readInt(u16, raw[1..3], .little);
        const cadence = raw[3];
        var offset: usize = 4;

        var stride: ?u16 = null;
        if (stride_present) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            stride = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        var total_dist: ?u32 = null;
        if (dist_present) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            total_dist = std.mem.readInt(u32, raw[offset..][0..4], .little);
            offset += 4;
        }

        return RscMeasurement{
            .instantaneous_speed_raw = speed_raw,
            .instantaneous_cadence_rpm = cadence,
            .instantaneous_stride_length_raw = stride,
            .total_distance_raw = total_dist,
            .is_running = is_running,
        };
    }

    /// Serializes into caller-provided buffer, returning sub-slice of written bytes.
    pub fn encode(self: RscMeasurement, out_buf: []u8) EncodeError![]u8 {
        var flags: u8 = 0;
        var required_len: usize = 4;

        if (self.instantaneous_stride_length_raw != null) {
            flags |= 0x01;
            required_len += 2;
        }
        if (self.total_distance_raw != null) {
            flags |= 0x02;
            required_len += 4;
        }
        if (self.is_running) {
            flags |= 0x04;
        }

        if (out_buf.len < required_len) return error.BufferTooSmall;

        out_buf[0] = flags;
        std.mem.writeInt(u16, out_buf[1..3], self.instantaneous_speed_raw, .little);
        out_buf[3] = self.instantaneous_cadence_rpm;
        var offset: usize = 4;

        if (self.instantaneous_stride_length_raw) |stride| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], stride, .little);
            offset += 2;
        }
        if (self.total_distance_raw) |dist| {
            std.mem.writeInt(u32, out_buf[offset..][0..4], dist, .little);
            offset += 4;
        }

        return out_buf[0..offset];
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "RscMeasurement: parse speed, cadence, and running status" {
    // Flags: stride present (0x01) | total distance present (0x02) | running (0x04) = 0x07
    // Speed: 3.5 m/s -> 3.5 * 256 = 896 = 0x0380
    // Cadence: 180 RPM = 0xB4
    // Stride: 1.15 m -> 115 cm = 0x0073
    // Distance: 5432.1 m -> 54321 dm = 0x0000D431
    const raw = [_]u8{
        0x07, // flags
        0x80, 0x03, // speed 896 (3.5 m/s)
        0xB4, // cadence 180 RPM
        0x73, 0x00, // stride 115 cm
        0x31, 0xD4, 0x00, 0x00, // total dist 54321 dm
    };

    const m = try RscMeasurement.parse(&raw);
    try std.testing.expect(m.is_running);
    try std.testing.expectEqual(@as(f32, 3.5), m.speedMetersPerSecond());
    try std.testing.expectApproxEqAbs(@as(f32, 12.6), m.speedKilometersPerHour(), 0.001); // 3.5 * 3.6 = 12.6
    try std.testing.expectEqual(@as(u8, 180), m.cadenceRpm());
    try std.testing.expectEqual(@as(?f32, 1.15), m.strideLengthMeters());
    try std.testing.expectEqual(@as(?f32, 5432.1), m.totalDistanceMeters());
}

test "RscMeasurement: round-trip encode and parse" {
    const original = RscMeasurement{
        .instantaneous_speed_raw = 512, // 2.0 m/s
        .instantaneous_cadence_rpm = 160,
        .instantaneous_stride_length_raw = 100, // 1.0 m
        .total_distance_raw = 12340, // 1234.0 m
        .is_running = false, // walking
    };

    var buf: [16]u8 = undefined;
    const written = try original.encode(&buf);
    const parsed = try RscMeasurement.parse(written);

    try std.testing.expectEqual(original.instantaneous_speed_raw, parsed.instantaneous_speed_raw);
    try std.testing.expectEqual(original.instantaneous_cadence_rpm, parsed.instantaneous_cadence_rpm);
    try std.testing.expectEqual(original.instantaneous_stride_length_raw.?, parsed.instantaneous_stride_length_raw.?);
    try std.testing.expectEqual(original.total_distance_raw.?, parsed.total_distance_raw.?);
    try std.testing.expectEqual(original.is_running, parsed.is_running);
}

test "RscFeature: parse and encode roundtrip" {
    var raw = [_]u8{ 0b00000111, 0x00 };
    const feat = try RscFeature.parse(&raw);
    try std.testing.expect(feat.instantaneous_stride_length_measurement_supported);
    try std.testing.expect(feat.total_distance_measurement_supported);
    try std.testing.expect(feat.walking_or_running_status_supported);
    try std.testing.expect(!feat.calibration_procedure_supported);

    var buf: [4]u8 = undefined;
    const written = try feat.encode(&buf);
    try std.testing.expectEqualSlices(u8, &raw, written);
}
