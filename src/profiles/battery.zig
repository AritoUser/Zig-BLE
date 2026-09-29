//! # Bluetooth SIG Battery Service (BAS)
//!
//! Service UUID: 0x180F (org.bluetooth.service.battery_service)
//! Characteristic:
//! - Battery Level: 0x2A19 (Read & Notify, uint8 0-100%)
//!
//! Specification: Bluetooth SIG Battery Service v1.0.

const std = @import("std");

pub const BatteryService = struct {
    pub const service_uuid16: u16 = 0x180F;
    pub const level_uuid16: u16 = 0x2A19;

    pub const ParseError = error{
        PayloadTooShort,
        InvalidValue,
    };

    /// Parses a raw Battery Level characteristic buffer (1 byte: 0-100%).
    ///
    /// ### Memory & Ownership
    /// - Zero-allocation, returns a plain `u8`.
    pub fn parseLevel(raw: []const u8) ParseError!u8 {
        if (raw.len < 1) return ParseError.PayloadTooShort;
        const level = raw[0];
        if (level > 100) return ParseError.InvalidValue;
        return level;
    }

    /// Encodes a percentage value (0-100%) into a 1-byte buffer for ATT read response or notification.
    pub fn encodeLevel(percentage: u8) ParseError![1]u8 {
        if (percentage > 100) return ParseError.InvalidValue;
        return [1]u8{percentage};
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "BatteryService: level parse and encode" {
    const raw = [_]u8{85};
    const level = try BatteryService.parseLevel(&raw);
    try std.testing.expectEqual(@as(u8, 85), level);

    const encoded = try BatteryService.encodeLevel(92);
    try std.testing.expectEqual(@as(u8, 92), encoded[0]);

    // Validation: > 100% is invalid
    try std.testing.expectError(BatteryService.ParseError.InvalidValue, BatteryService.parseLevel(&[_]u8{105}));
    try std.testing.expectError(BatteryService.ParseError.InvalidValue, BatteryService.encodeLevel(101));
    try std.testing.expectError(BatteryService.ParseError.PayloadTooShort, BatteryService.parseLevel(&[_]u8{}));
}
