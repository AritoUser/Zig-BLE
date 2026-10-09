//! # Bluetooth SIG Heart Rate Profile (HRP)
//!
//! Service UUID: 0x180D (org.bluetooth.service.heart_rate)
//! Characteristics:
//! - Heart Rate Measurement: 0x2A37 (Notify mandatory)
//! - Body Sensor Location:   0x2A38 (Read optional)
//! - Heart Rate Control Pt:  0x2A39 (Write optional)
//!
//! Specification: Bluetooth SIG Heart Rate Profile v1.0 / Core Spec v5.4.

const std = @import("std");

/// Sensor Contact Status reported in Heart Rate Measurement flags (bits 1 & 2).
pub const SensorContactStatus = enum(u2) {
    not_supported = 0b00,
    not_supported_alt = 0b01,
    supported_no_contact = 0b10,
    supported_contact_detected = 0b11,

    pub fn isContactDetected(self: SensorContactStatus) bool {
        return self == .supported_contact_detected;
    }
};

/// Body Sensor Location according to Bluetooth SIG Assigned Numbers (0x2A38).
pub const BodySensorLocation = enum(u8) {
    other = 0,
    chest = 1,
    wrist = 2,
    finger = 3,
    hand = 4,
    ear_lobe = 5,
    foot = 6,
    _,

    pub fn toString(self: BodySensorLocation) []const u8 {
        return switch (self) {
            .other => "Other",
            .chest => "Chest",
            .wrist => "Wrist",
            .finger => "Finger",
            .hand => "Hand",
            .ear_lobe => "Ear Lobe",
            .foot => "Foot",
            _ => "Unknown",
        };
    }
};

/// Decoded Heart Rate Measurement characteristic value (0x2A37).
///
/// ### Memory & Ownership
/// - Bounded stack representation (`[8]u16` for RR-intervals).
/// - **Zero-Allocation**: No heap allocation is performed during parsing or encoding.
pub const HeartRateMeasurement = struct {
    /// Heart rate in beats per minute (BPM).
    bpm: u16,
    /// Skin contact detection status.
    sensor_contact: SensorContactStatus = .not_supported,
    /// Accumulated energy expended in kilo-Joules (kJ), if present.
    energy_expended_kj: ?u16 = null,
    /// RR-interval buffer (time between R-waves in 1/1024 seconds).
    rr_intervals: [8]u16 = @splat(0),
    /// Number of valid RR-intervals in the `rr_intervals` buffer.
    rr_count: usize = 0,

    pub const ParseError = error{
        PayloadTooShort,
        BufferOverflow,
    };

    /// Parses a raw ATT notification or read buffer into a `HeartRateMeasurement`.
    ///
    /// ### Endianness
    /// All multi-byte integers (16-bit BPM, Energy Expended, RR-intervals) are decoded in Little-Endian.
    pub fn parse(raw: []const u8) ParseError!HeartRateMeasurement {
        if (raw.len < 2) return ParseError.PayloadTooShort;

        const flags = raw[0];
        const is_16bit_bpm = (flags & 0x01) != 0;
        const contact_raw: u2 = @truncate((flags >> 1) & 0x03);
        const contact_status: SensorContactStatus = @enumFromInt(contact_raw);
        const has_energy = (flags & 0x08) != 0;
        const has_rr = (flags & 0x10) != 0;

        var offset: usize = 1;
        var bpm: u16 = 0;

        if (is_16bit_bpm) {
            if (raw.len < offset + 2) return ParseError.PayloadTooShort;
            bpm = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        } else {
            bpm = raw[offset];
            offset += 1;
        }

        var energy_kj: ?u16 = null;
        if (has_energy) {
            if (raw.len < offset + 2) return ParseError.PayloadTooShort;
            energy_kj = std.mem.readInt(u16, raw[offset..][0..2], .little);
            offset += 2;
        }

        var res = HeartRateMeasurement{
            .bpm = bpm,
            .sensor_contact = contact_status,
            .energy_expended_kj = energy_kj,
        };

        if (has_rr) {
            while (offset + 2 <= raw.len and res.rr_count < res.rr_intervals.len) {
                const interval = std.mem.readInt(u16, raw[offset..][0..2], .little);
                res.rr_intervals[res.rr_count] = interval;
                res.rr_count += 1;
                offset += 2;
            }
        }

        return res;
    }

    /// Serializes the measurement into raw ATT notification bytes.
    ///
    /// ### Arguments
    /// - `buf`: Output buffer. Must be large enough (min. 20 bytes recommended).
    ///
    /// ### Returns
    /// The number of bytes written into `buf`.
    pub fn encode(self: HeartRateMeasurement, buf: []u8) ParseError!usize {
        if (buf.len < 4) return ParseError.BufferOverflow;

        var flags: u8 = 0;
        const is_16bit = self.bpm > 255;
        if (is_16bit) flags |= 0x01;

        const contact_bits: u8 = @intFromEnum(self.sensor_contact);
        flags |= (contact_bits & 0x03) << 1;

        if (self.energy_expended_kj != null) flags |= 0x08;
        if (self.rr_count > 0) flags |= 0x10;

        buf[0] = flags;
        var offset: usize = 1;

        if (is_16bit) {
            if (offset + 2 > buf.len) return ParseError.BufferOverflow;
            std.mem.writeInt(u16, buf[offset..][0..2], self.bpm, .little);
            offset += 2;
        } else {
            if (offset + 1 > buf.len) return ParseError.BufferOverflow;
            buf[offset] = @truncate(self.bpm);
            offset += 1;
        }

        if (self.energy_expended_kj) |kj| {
            if (offset + 2 > buf.len) return ParseError.BufferOverflow;
            std.mem.writeInt(u16, buf[offset..][0..2], kj, .little);
            offset += 2;
        }

        for (0..self.rr_count) |i| {
            if (offset + 2 > buf.len) break;
            std.mem.writeInt(u16, buf[offset..][0..2], self.rr_intervals[i], .little);
            offset += 2;
        }

        return offset;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "HeartRateMeasurement: 8-bit BPM parsing" {
    // Flags: 8-bit BPM, contact detected (0b11 << 1 = 0x06), energy expended (0x08)
    // BPM: 72 (0x48), Energy: 250 kJ (0x00FA in LE: 0xFA, 0x00)
    const raw = [_]u8{ 0x0E, 0x48, 0xFA, 0x00 };
    const hrm = try HeartRateMeasurement.parse(&raw);

    try std.testing.expectEqual(@as(u16, 72), hrm.bpm);
    try std.testing.expectEqual(SensorContactStatus.supported_contact_detected, hrm.sensor_contact);
    try std.testing.expect(hrm.sensor_contact.isContactDetected());
    try std.testing.expectEqual(@as(?u16, 250), hrm.energy_expended_kj);
    try std.testing.expectEqual(@as(usize, 0), hrm.rr_count);
}

test "HeartRateMeasurement: 16-bit BPM with RR-intervals" {
    // Flags: 16-bit BPM (0x01) + RR present (0x10) = 0x11
    // BPM: 300 (0x012C in LE: 0x2C, 0x01)
    // RR1: 850 (0x0352 in LE: 0x52, 0x03), RR2: 860 (0x035C in LE: 0x5C, 0x03)
    const raw = [_]u8{ 0x11, 0x2C, 0x01, 0x52, 0x03, 0x5C, 0x03 };
    const hrm = try HeartRateMeasurement.parse(&raw);

    try std.testing.expectEqual(@as(u16, 300), hrm.bpm);
    try std.testing.expectEqual(@as(usize, 2), hrm.rr_count);
    try std.testing.expectEqual(@as(u16, 850), hrm.rr_intervals[0]);
    try std.testing.expectEqual(@as(u16, 860), hrm.rr_intervals[1]);
}

test "HeartRateMeasurement: roundtrip encoding and decoding" {
    var original = HeartRateMeasurement{
        .bpm = 145,
        .sensor_contact = .supported_contact_detected,
        .energy_expended_kj = 420,
    };
    original.rr_intervals[0] = 712;
    original.rr_intervals[1] = 708;
    original.rr_count = 2;

    var buf: [32]u8 = undefined;
    const len = try original.encode(&buf);

    const decoded = try HeartRateMeasurement.parse(buf[0..len]);
    try std.testing.expectEqual(original.bpm, decoded.bpm);
    try std.testing.expectEqual(original.sensor_contact, decoded.sensor_contact);
    try std.testing.expectEqual(original.energy_expended_kj, decoded.energy_expended_kj);
    try std.testing.expectEqual(original.rr_count, decoded.rr_count);
    try std.testing.expectEqual(original.rr_intervals[0], decoded.rr_intervals[0]);
    try std.testing.expectEqual(original.rr_intervals[1], decoded.rr_intervals[1]);
}
