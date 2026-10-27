//! # Bluetooth SIG Cycling Power Profile (CPP)
//!
//! Service UUID: 0x1818 (org.bluetooth.service.cycling_power)
//! Characteristics:
//! - Cycling Power Measurement:     0x2A63 (Notify)
//! - Cycling Power Vector:          0x2A64 (Notify)
//! - Cycling Power Feature:         0x2A65 (Read)
//! - Cycling Power Control Point:   0x2A66 (Write, Indicate)
//! - Sensor Location:               0x2A5D (Read)
//!
//! Specification: Bluetooth SIG Cycling Power Service v1.1.
//! Zero-allocation implementation with 64-second 1/1024s timestamp wrapping calculations.

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

/// Cycling Power Feature bitfield (UUID 0x2A65).
pub const CyclingPowerFeature = packed struct(u32) {
    pedal_power_balance_supported: bool = false, // Bit 0
    accumulated_torque_supported: bool = false, // Bit 1
    wheel_revolution_data_supported: bool = false, // Bit 2
    crank_revolution_data_supported: bool = false, // Bit 3
    extreme_magnitudes_supported: bool = false, // Bit 4
    extreme_angles_supported: bool = false, // Bit 5
    top_and_bottom_dead_spot_angles_supported: bool = false, // Bit 6
    accumulated_energy_supported: bool = false, // Bit 7
    offset_compensation_indicator_supported: bool = false, // Bit 8
    offset_compensation_supported: bool = false, // Bit 9
    cycling_power_measurement_characteristic_content_masking_supported: bool = false, // Bit 10
    multiple_sensor_locations_supported: bool = false, // Bit 11
    crank_length_adjustment_supported: bool = false, // Bit 12
    chain_length_adjustment_supported: bool = false, // Bit 13
    chain_weight_adjustment_supported: bool = false, // Bit 14
    span_length_adjustment_supported: bool = false, // Bit 15
    sensor_measurement_context: bool = false, // Bit 16: 0 = Force, 1 = Torque
    instantaneous_measurement_direction_supported: bool = false, // Bit 17
    factory_calibration_date_supported: bool = false, // Bit 18
    enhanced_offset_compensation_supported: bool = false, // Bit 19
    reserved: u12 = 0,

    pub fn parse(raw: []const u8) ParseError!CyclingPowerFeature {
        if (raw.len < 4) return error.PayloadTooShort;
        const bits = std.mem.readInt(u32, raw[0..4], .little);
        return @bitCast(bits);
    }

    pub fn encode(self: CyclingPowerFeature, out_buf: []u8) EncodeError![]u8 {
        if (out_buf.len < 4) return error.BufferTooSmall;
        const bits: u32 = @bitCast(self);
        std.mem.writeInt(u32, out_buf[0..4], bits, .little);
        return out_buf[0..4];
    }
};

/// Decoded Cycling Power Measurement characteristic value (0x2A63).
pub const CyclingPowerMeasurement = struct {
    instantaneous_power: i16, // Watts (-32768 to +32767 W)
    pedal_power_balance_raw: ?u8 = null, // Bit 0..6: 0.5 %, Bit 7: 0 = Right, 1 = Left
    accumulated_torque_raw: ?u16 = null, // 1/32 Nm
    cumulative_wheel_revs: ?u32 = null,
    last_wheel_event_time: ?u16 = null, // 1/1024 s (wraps every 64s)
    cumulative_crank_revs: ?u16 = null,
    last_crank_event_time: ?u16 = null, // 1/1024 s (wraps every 64s)
    maximum_force_magnitude: ?i16 = null, // Newtons
    minimum_force_magnitude: ?i16 = null,
    maximum_torque_magnitude: ?i16 = null, // 1/32 Nm
    minimum_torque_magnitude: ?i16 = null,
    accumulated_energy_kj: ?u16 = null, // kJ

    pub fn powerWatts(self: CyclingPowerMeasurement) i16 {
        return self.instantaneous_power;
    }

    pub fn pedalPowerBalancePercent(self: CyclingPowerMeasurement) ?f32 {
        if (self.pedal_power_balance_raw) |raw| {
            const val = raw & 0x7F;
            return @as(f32, @floatFromInt(val)) * 0.5;
        }
        return null;
    }

    pub fn isPedalBalanceReferenceLeft(self: CyclingPowerMeasurement) bool {
        if (self.pedal_power_balance_raw) |raw| {
            return (raw & 0x80) != 0;
        }
        return false;
    }

    pub fn accumulatedTorqueNm(self: CyclingPowerMeasurement) ?f32 {
        if (self.accumulated_torque_raw) |raw| {
            return @as(f32, @floatFromInt(raw)) / 32.0;
        }
        return null;
    }

    /// Parses raw notification bytes into a `CyclingPowerMeasurement`.
    /// Forward-compatible: accepts trailing bytes.
    pub fn parse(raw: []const u8) ParseError!CyclingPowerMeasurement {
        if (raw.len < 4) return error.PayloadTooShort; // flags (2) + power (2)

        const flags = std.mem.readInt(u16, raw[0..2], .little);
        const has_balance = (flags & 0x0001) != 0;
        const has_torque = (flags & 0x0004) != 0;
        const has_wheel = (flags & 0x0010) != 0;
        const has_crank = (flags & 0x0020) != 0;
        const has_force = (flags & 0x0040) != 0;
        const has_torque_mag = (flags & 0x0080) != 0;
        const has_energy = (flags & 0x0800) != 0;

        var offset: usize = 2;
        const pwr = std.mem.readInt(i16, raw[offset..][0..2], .little);
        offset += 2;

        var balance: ?u8 = null;
        if (has_balance) {
            if (raw.len < offset + 1) return error.PayloadTooShort;
            balance = raw[offset];
            offset += 1;
        }

        var torque: ?u16 = null;
        if (has_torque) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            torque = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        var wheel_revs: ?u32 = null;
        var wheel_time: ?u16 = null;
        if (has_wheel) {
            if (raw.len < offset + 6) return error.PayloadTooShort;
            wheel_revs = std.mem.readInt(u32, raw[offset..][0..4], .little);
            wheel_time = std.mem.readInt(u16, raw[offset + 4 ..][0..2], .little);
            offset += 6;
        }

        var crank_revs: ?u16 = null;
        var crank_time: ?u16 = null;
        if (has_crank) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            crank_revs = std.mem.readInt(u16, raw[offset..][0..2], .little);
            crank_time = std.mem.readInt(u16, raw[offset + 2 ..][0..2], .little);
            offset += 4;
        }

        var max_force: ?i16 = null;
        var min_force: ?i16 = null;
        if (has_force) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            max_force = std.mem.readInt(i16, raw[offset..][0..2], .little);
            min_force = std.mem.readInt(i16, raw[offset + 2 ..][0..2], .little);
            offset += 4;
        }

        var max_torque: ?i16 = null;
        var min_torque: ?i16 = null;
        if (has_torque_mag) {
            if (raw.len < offset + 4) return error.PayloadTooShort;
            max_torque = std.mem.readInt(i16, raw[offset..][0..2], .little);
            min_torque = std.mem.readInt(i16, raw[offset + 2 ..][0..2], .little);
            offset += 4;
        }

        var energy_kj: ?u16 = null;
        if (has_energy) {
            if (raw.len < offset + 2) return error.PayloadTooShort;
            energy_kj = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        return CyclingPowerMeasurement{
            .instantaneous_power = pwr,
            .pedal_power_balance_raw = balance,
            .accumulated_torque_raw = torque,
            .cumulative_wheel_revs = wheel_revs,
            .last_wheel_event_time = wheel_time,
            .cumulative_crank_revs = crank_revs,
            .last_crank_event_time = crank_time,
            .maximum_force_magnitude = max_force,
            .minimum_force_magnitude = min_force,
            .maximum_torque_magnitude = max_torque,
            .minimum_torque_magnitude = min_torque,
            .accumulated_energy_kj = energy_kj,
        };
    }

    /// Serializes into caller-provided buffer, returning sub-slice of written bytes.
    pub fn encode(self: CyclingPowerMeasurement, out_buf: []u8) EncodeError![]u8 {
        var flags: u16 = 0;
        var required_len: usize = 4;

        if (self.pedal_power_balance_raw != null) {
            flags |= 0x0001;
            if (self.isPedalBalanceReferenceLeft()) flags |= 0x0002;
            required_len += 1;
        }
        if (self.accumulated_torque_raw != null) {
            flags |= 0x0004;
            required_len += 2;
        }
        if (self.cumulative_wheel_revs != null and self.last_wheel_event_time != null) {
            flags |= 0x0010;
            required_len += 6;
        }
        if (self.cumulative_crank_revs != null and self.last_crank_event_time != null) {
            flags |= 0x0020;
            required_len += 4;
        }
        if (self.maximum_force_magnitude != null and self.minimum_force_magnitude != null) {
            flags |= 0x0040;
            required_len += 4;
        }
        if (self.maximum_torque_magnitude != null and self.minimum_torque_magnitude != null) {
            flags |= 0x0080;
            required_len += 4;
        }
        if (self.accumulated_energy_kj != null) {
            flags |= 0x0800;
            required_len += 2;
        }

        if (out_buf.len < required_len) return error.BufferTooSmall;

        std.mem.writeInt(u16, out_buf[0..2], flags, .little);
        std.mem.writeInt(i16, out_buf[2..4], self.instantaneous_power, .little);
        var offset: usize = 4;

        if (self.pedal_power_balance_raw) |bal| {
            out_buf[offset] = bal;
            offset += 1;
        }
        if (self.accumulated_torque_raw) |trq| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], trq, .little);
            offset += 2;
        }
        if (self.cumulative_wheel_revs) |w_revs| {
            if (self.last_wheel_event_time) |w_time| {
                std.mem.writeInt(u32, out_buf[offset..][0..4], w_revs, .little);
                std.mem.writeInt(u16, out_buf[offset + 4 ..][0..2], w_time, .little);
                offset += 6;
            }
        }
        if (self.cumulative_crank_revs) |c_revs| {
            if (self.last_crank_event_time) |c_time| {
                std.mem.writeInt(u16, out_buf[offset..][0..2], c_revs, .little);
                std.mem.writeInt(u16, out_buf[offset + 2 ..][0..2], c_time, .little);
                offset += 4;
            }
        }
        if (self.maximum_force_magnitude) |max_f| {
            if (self.minimum_force_magnitude) |min_f| {
                std.mem.writeInt(i16, out_buf[offset..][0..2], max_f, .little);
                std.mem.writeInt(i16, out_buf[offset + 2 ..][0..2], min_f, .little);
                offset += 4;
            }
        }
        if (self.maximum_torque_magnitude) |max_t| {
            if (self.minimum_torque_magnitude) |min_t| {
                std.mem.writeInt(i16, out_buf[offset..][0..2], max_t, .little);
                std.mem.writeInt(i16, out_buf[offset + 2 ..][0..2], min_t, .little);
                offset += 4;
            }
        }
        if (self.accumulated_energy_kj) |kj| {
            std.mem.writeInt(u16, out_buf[offset..][0..2], kj, .little);
            offset += 2;
        }

        return out_buf[0..offset];
    }
};

// ============================================================================
// Cadence & Speed Calculation Helpers (with 1/1024s 64s timestamp wrapping)
// ============================================================================

/// Calculates instantaneous cadence in RPM between two consecutive crank revolution events.
/// Handles the 16-bit 1/1024s timer rollover (every ~64 seconds) using wrapping subtraction `-%`.
pub fn calculateCadenceRpm(prev_revs: u16, prev_time: u16, curr_revs: u16, curr_time: u16) ?f32 {
    const time_diff = curr_time -% prev_time;
    if (time_diff == 0) return null; // No new event time reported
    const revs_diff = curr_revs -% prev_revs;
    if (revs_diff == 0) return 0.0; // Freewheeling / coasting

    // revs / (time_diff / 1024 s) * 60 s/min = (revs * 1024 * 60) / time_diff
    const num = @as(f32, @floatFromInt(revs_diff)) * 1024.0 * 60.0;
    const den = @as(f32, @floatFromInt(time_diff));
    return num / den;
}

/// State helper for tracking crank cadence across incoming BLE notifications.
pub const CadenceCalculator = struct {
    last_revs: ?u16 = null,
    last_time: ?u16 = null,

    pub fn update(self: *CadenceCalculator, m: CyclingPowerMeasurement) ?f32 {
        if (m.cumulative_crank_revs == null or m.last_crank_event_time == null) return null;
        const curr_revs = m.cumulative_crank_revs.?;
        const curr_time = m.last_crank_event_time.?;

        defer {
            self.last_revs = curr_revs;
            self.last_time = curr_time;
        }

        if (self.last_revs == null or self.last_time == null) return null;
        return calculateCadenceRpm(self.last_revs.?, self.last_time.?, curr_revs, curr_time);
    }

    pub fn reset(self: *CadenceCalculator) void {
        self.last_revs = null;
        self.last_time = null;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "CyclingPowerMeasurement: parse and verify balance and power" {
    // Flags: balance present (0x0001) | reference left (0x0002) = 0x0003
    // Power: 315 Watts (0x013B)
    // Balance: 48.0% Left (96 = 0x60 | 0x80 = 0xE0)
    const raw = [_]u8{
        0x03, 0x00, // flags
        0x3B, 0x01, // 315 Watts
        0xE0, // balance: 48% Left
    };

    const m = try CyclingPowerMeasurement.parse(&raw);
    try std.testing.expectEqual(@as(i16, 315), m.powerWatts());
    try std.testing.expect(m.isPedalBalanceReferenceLeft());
    try std.testing.expectEqual(@as(?f32, 48.0), m.pedalPowerBalancePercent());
}

test "CyclingPowerMeasurement: round-trip encode and parse" {
    const original = CyclingPowerMeasurement{
        .instantaneous_power = 275,
        .pedal_power_balance_raw = 0x64, // 50.0% Right (0x64 = 100 * 0.5%)
        .accumulated_torque_raw = 3200, // 100 Nm (3200 / 32)
        .cumulative_crank_revs = 4500,
        .last_crank_event_time = 12345,
    };

    var buf: [32]u8 = undefined;
    const written = try original.encode(&buf);
    const parsed = try CyclingPowerMeasurement.parse(written);

    try std.testing.expectEqual(original.instantaneous_power, parsed.instantaneous_power);
    try std.testing.expectEqual(original.pedal_power_balance_raw.?, parsed.pedal_power_balance_raw.?);
    try std.testing.expectEqual(original.accumulated_torque_raw.?, parsed.accumulated_torque_raw.?);
    try std.testing.expectEqual(original.cumulative_crank_revs.?, parsed.cumulative_crank_revs.?);
    try std.testing.expectEqual(original.last_crank_event_time.?, parsed.last_crank_event_time.?);
}

test "calculateCadenceRpm: 64-second timestamp rollover with wrapping subtraction" {
    // Normal case: 90 RPM
    // 1 revolution in 60/90 s = 0.6666 s = 683 ticks of 1/1024s
    const rpm1 = calculateCadenceRpm(100, 1000, 101, 1683).?;
    try std.testing.expect(rpm1 > 89.8 and rpm1 < 90.2);

    // Rollover case: last_time was 65000, curr_time wrapped around 65535 to 147
    // time_diff = 147 -% 65000 = 147 + (65536 - 65000) = 147 + 536 = 683 ticks!
    const rpm_wrap = calculateCadenceRpm(100, 65000, 101, 147).?;
    try std.testing.expect(rpm_wrap > 89.8 and rpm_wrap < 90.2);
}

test "CadenceCalculator: state tracker" {
    var calc = CadenceCalculator{};

    // First sample establishes baseline, returns null
    const m1 = CyclingPowerMeasurement{
        .instantaneous_power = 200,
        .cumulative_crank_revs = 10,
        .last_crank_event_time = 1000,
    };
    try std.testing.expect(calc.update(m1) == null);

    // Second sample calculates cadence
    const m2 = CyclingPowerMeasurement{
        .instantaneous_power = 200,
        .cumulative_crank_revs = 11,
        .last_crank_event_time = 1683,
    };
    const rpm = calc.update(m2).?;
    try std.testing.expect(rpm > 89.8 and rpm < 90.2);
}
