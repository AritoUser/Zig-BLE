//! # Bluetooth SIG Environmental Sensing Service (ESS)
//!
//! Service UUID: 0x181A (org.bluetooth.service.environmental_sensing)
//! Characteristics:
//! - Temperature: 0x2A6E (sint16 in 0.01 °C, -273.15 °C to +327.67 °C)
//! - Humidity:    0x2A6F (uint16 in 0.01 %, 0.00 % to 100.00 %)
//! - Pressure:    0x2A6D (uint32 in 0.1 Pa, e.g. 1,013,250 = 1013.25 hPa)
//!
//! Specification: Bluetooth SIG Environmental Sensing Service v1.0.

const std = @import("std");

pub const EnvironmentalSensing = struct {
    pub const service_uuid16: u16 = 0x181A;
    pub const temperature_uuid16: u16 = 0x2A6E;
    pub const humidity_uuid16: u16 = 0x2A6F;
    pub const pressure_uuid16: u16 = 0x2A6D;

    pub const ParseError = error{
        PayloadTooShort,
    };

    // ------------------------------------------------------------------------
    // Temperature (sint16 in 0.01 °C)
    // ------------------------------------------------------------------------

    /// Parses raw Temperature bytes (2 bytes Little-Endian sint16).
    /// Returns the raw integer value (e.g. 2345 = 23.45 °C).
    pub fn parseTemperatureRaw(raw: []const u8) ParseError!i16 {
        if (raw.len < 2) return ParseError.PayloadTooShort;
        return @as(i16, @bitCast(std.mem.readInt(u16, raw[0..2], .little)));
    }

    /// Parses raw Temperature bytes and converts to float Celsius.
    pub fn parseTemperatureCelsius(raw: []const u8) ParseError!f32 {
        const raw_val = try parseTemperatureRaw(raw);
        return @as(f32, @floatFromInt(raw_val)) / 100.0;
    }

    /// Encodes a Celsius temperature (as float) into 2-byte Little-Endian wire format.
    pub fn encodeTemperatureCelsius(celsius: f32) [2]u8 {
        const raw_val: i16 = @intFromFloat(std.math.clamp(celsius * 100.0, -32768.0, 32767.0));
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @as(u16, @bitCast(raw_val)), .little);
        return buf;
    }

    // ------------------------------------------------------------------------
    // Humidity (uint16 in 0.01 %)
    // ------------------------------------------------------------------------

    /// Parses raw Humidity bytes (2 bytes Little-Endian uint16).
    /// Returns the raw integer value (e.g. 4850 = 48.50 %).
    pub fn parseHumidityRaw(raw: []const u8) ParseError!u16 {
        if (raw.len < 2) return ParseError.PayloadTooShort;
        return std.mem.readInt(u16, raw[0..2], .little);
    }

    /// Parses raw Humidity bytes and converts to float percentage (0.0% to 100.0%).
    pub fn parseHumidityPercent(raw: []const u8) ParseError!f32 {
        const raw_val = try parseHumidityRaw(raw);
        return @as(f32, @floatFromInt(raw_val)) / 100.0;
    }

    /// Encodes a humidity percentage (0.0 to 100.0) into 2-byte Little-Endian wire format.
    pub fn encodeHumidityPercent(percent: f32) [2]u8 {
        const clamped = std.math.clamp(percent, 0.0, 100.0);
        const raw_val: u16 = @intFromFloat(clamped * 100.0);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, raw_val, .little);
        return buf;
    }

    // ------------------------------------------------------------------------
    // Pressure (uint32 in 0.1 Pa)
    // ------------------------------------------------------------------------

    /// Parses raw Pressure bytes (4 bytes Little-Endian uint32).
    /// Value is in 0.1 Pa (e.g. 1013250 = 1013.25 hPa).
    pub fn parsePressureRaw(raw: []const u8) ParseError!u32 {
        if (raw.len < 4) return ParseError.PayloadTooShort;
        return std.mem.readInt(u32, raw[0..4], .little);
    }

    /// Parses raw Pressure bytes and converts to hectopascals (hPa / mbar).
    pub fn parsePressureHpa(raw: []const u8) ParseError!f64 {
        const raw_val = try parsePressureRaw(raw);
        // 1 Pa = 10 units of 0.1 Pa. 1 hPa = 100 Pa = 1000 units of 0.1 Pa.
        return @as(f64, @floatFromInt(raw_val)) / 1000.0;
    }

    /// Encodes a pressure in hPa into 4-byte Little-Endian wire format.
    pub fn encodePressureHpa(hpa: f64) [4]u8 {
        const raw_val: u32 = @intFromFloat(hpa * 1000.0);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, raw_val, .little);
        return buf;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "EnvironmentalSensing: temperature encoding and decoding" {
    // 21.50 °C -> 2150 (0x0866 in LE: 0x66, 0x08)
    const enc = EnvironmentalSensing.encodeTemperatureCelsius(21.50);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x66, 0x08 }, &enc);

    const deg = try EnvironmentalSensing.parseTemperatureCelsius(&enc);
    try std.testing.expectApproxEqAbs(@as(f32, 21.50), deg, 0.01);

    // Negative temperature: -10.25 °C -> -1025 (0xFC00 - 1 = 0xFBFF in signed)
    const neg_enc = EnvironmentalSensing.encodeTemperatureCelsius(-10.25);
    const neg_deg = try EnvironmentalSensing.parseTemperatureCelsius(&neg_enc);
    try std.testing.expectApproxEqAbs(@as(f32, -10.25), neg_deg, 0.01);
}

test "EnvironmentalSensing: humidity and pressure" {
    // Humidity 65.40% -> 6540 (0x198C in LE: 0x8C, 0x19)
    const hum_enc = EnvironmentalSensing.encodeHumidityPercent(65.40);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x8C, 0x19 }, &hum_enc);
    const hum = try EnvironmentalSensing.parseHumidityPercent(&hum_enc);
    try std.testing.expectApproxEqAbs(@as(f32, 65.40), hum, 0.01);

    // Pressure: 1013.25 hPa -> 1,013,250 (0x000F7602 in LE: 0x02, 0x76, 0x0F, 0x00)
    const p_enc = EnvironmentalSensing.encodePressureHpa(1013.25);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x76, 0x0F, 0x00 }, &p_enc);
    const p = try EnvironmentalSensing.parsePressureHpa(&p_enc);
    try std.testing.expectApproxEqAbs(@as(f64, 1013.25), p, 0.001);
}
