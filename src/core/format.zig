//! Zig-BLE GATT Typing & Deserialization Engine
//!
//! Provides strict, zero-allocation serialization and parsing for:
//! 1. IEEE-11073-20601 Medical/Float types: SFLOAT (16-bit) and FLOAT (32-bit).
//! 2. GATT Characteristic Presentation Format Descriptors (Bluetooth SIG UUID 0x2904).
//! 3. Strongly-typed, endian-aware read/write primitives for GATT characteristics.

const std = @import("std");
const assigned_numbers = @import("assigned_numbers.zig");
const Units = assigned_numbers.Units;

/// IEEE-11073-20601 16-bit SFLOAT (Short Float).
/// Widely used across Bluetooth SIG medical and environmental profiles
/// (e.g. Health Thermometer, Pulse Oximeter, Weight Scale).
///
/// Layout:
/// - Bits 0..11: 12-bit signed mantissa (two's complement, range -2048 to +2047)
/// - Bits 12..15: 4-bit signed exponent (two's complement, range -8 to +7)
///
/// Mathematical value: `mantissa * 10^(exponent)`
pub const Sfloat = struct {
    raw: u16,

    pub const nan: Sfloat = .{ .raw = 0x07FF };
    pub const positive_infinity: Sfloat = .{ .raw = 0x07FE };
    pub const negative_infinity: Sfloat = .{ .raw = 0x0802 };
    pub const not_at_this_resolution: Sfloat = .{ .raw = 0x0800 };
    pub const reserved: Sfloat = .{ .raw = 0x0801 };

    /// Constructs an Sfloat from a raw 16-bit integer.
    pub inline fn fromRaw(raw_val: u16) Sfloat {
        return .{ .raw = raw_val };
    }

    /// Checks if this Sfloat represents Not-a-Number (NaN).
    pub inline fn isNan(self: Sfloat) bool {
        return (self.raw & 0x0FFF) == 0x07FF;
    }

    /// Checks if this Sfloat represents positive infinity (+INFINITY).
    pub inline fn isPositiveInfinity(self: Sfloat) bool {
        return (self.raw & 0x0FFF) == 0x07FE;
    }

    /// Checks if this Sfloat represents negative infinity (-INFINITY).
    pub inline fn isNegativeInfinity(self: Sfloat) bool {
        return (self.raw & 0x0FFF) == 0x0802;
    }

    /// Checks if this Sfloat represents Not at this Resolution (NRes).
    pub inline fn isNRes(self: Sfloat) bool {
        return (self.raw & 0x0FFF) == 0x0800;
    }

    /// Checks if this Sfloat represents a reserved value.
    pub inline fn isReserved(self: Sfloat) bool {
        return (self.raw & 0x0FFF) == 0x0801;
    }

    /// Returns true if this value is any special IEEE-11073 value (NaN, Inf, NRes, Reserved).
    pub inline fn isSpecial(self: Sfloat) bool {
        const m = self.raw & 0x0FFF;
        return (m >= 0x07FE and m <= 0x0802);
    }

    /// Extracts the 12-bit signed mantissa with proper two's complement sign extension.
    pub inline fn mantissa(self: Sfloat) i16 {
        const m_u12: u12 = @truncate(self.raw);
        return @as(i12, @bitCast(m_u12));
    }

    /// Extracts the 4-bit signed base-10 exponent with proper two's complement sign extension.
    pub inline fn exponent(self: Sfloat) i8 {
        const e_u4: u4 = @truncate(self.raw >> 12);
        return @as(i4, @bitCast(e_u4));
    }

    /// Constructs an Sfloat from an explicit 12-bit signed mantissa and 4-bit signed exponent.
    pub fn fromParts(mant: i12, exp: i4) Sfloat {
        const m_u12: u12 = @bitCast(mant);
        const e_u4: u4 = @bitCast(exp);
        const raw = (@as(u16, e_u4) << 12) | @as(u16, m_u12);
        return .{ .raw = raw };
    }

    /// Decodes the Sfloat into an IEEE-754 32-bit float (`f32`).
    /// Returns an error if the value is Not at this Resolution or Reserved.
    pub fn toF32(self: Sfloat) !f32 {
        if (self.isNan()) return std.math.nan(f32);
        if (self.isPositiveInfinity()) return std.math.inf(f32);
        if (self.isNegativeInfinity()) return -std.math.inf(f32);
        if (self.isNRes()) return error.NotAtThisResolution;
        if (self.isReserved()) return error.ReservedValue;

        const m = @as(f32, @floatFromInt(self.mantissa()));
        const e = @as(f32, @floatFromInt(self.exponent()));
        return m * std.math.pow(f32, 10.0, e);
    }

    /// Decodes the Sfloat into `f32`, returning NaN on NRes/Reserved instead of returning an error.
    pub fn toF32Unchecked(self: Sfloat) f32 {
        return self.toF32() catch std.math.nan(f32);
    }

    /// Decodes the Sfloat into an IEEE-754 64-bit float (`f64`).
    pub fn toF64(self: Sfloat) !f64 {
        const val = try self.toF32();
        return @floatCast(val);
    }

    /// Automatically encodes an `f32` value into an IEEE-11073 16-bit SFLOAT,
    /// searching for the optimal base-10 exponent in [-8, 7] that preserves maximum precision.
    pub fn fromF32(val: f32) Sfloat {
        if (std.math.isNan(val)) return nan;
        if (std.math.isPositiveInf(val)) return positive_infinity;
        if (std.math.isNegativeInf(val)) return negative_infinity;
        if (val == 0.0) return .{ .raw = 0 };

        var best_exp: i4 = 0;
        var best_mant: i12 = 0;
        var best_err: f32 = std.math.inf(f32);

        var exp: i4 = -8;
        while (true) : (exp += 1) {
            const factor = std.math.pow(f32, 10.0, -@as(f32, @floatFromInt(exp)));
            const scaled = val * factor;
            const rounded = @round(scaled);
            if (rounded >= -2045.0 and rounded <= 2045.0) {
                const mant: i12 = @intFromFloat(rounded);
                const reconstructed = @as(f32, @floatFromInt(mant)) * std.math.pow(f32, 10.0, @as(f32, @floatFromInt(exp)));
                const err = @abs(val - reconstructed);
                if (err < best_err) {
                    best_err = err;
                    best_exp = exp;
                    best_mant = mant;
                    if (err == 0.0) break;
                }
            }
            if (exp == 7) break;
        }

        return fromParts(best_mant, best_exp);
    }

    /// Convenience helper: converts `f32` to Sfloat.
    pub inline fn fromFloat(val: f32) Sfloat {
        return fromF32(val);
    }

    /// Convenience helper: decodes Sfloat to optional `f32` (returns null on NaN, NRes, or Reserved).
    pub inline fn toFloat(self: Sfloat) ?f32 {
        return self.toF32() catch null;
    }

    /// Encodes an `f32` with a specified fixed base-10 exponent.
    pub fn fromF32WithExponent(val: f32, exp: i4) !Sfloat {
        if (std.math.isNan(val)) return nan;
        if (std.math.isPositiveInf(val)) return positive_infinity;
        if (std.math.isNegativeInf(val)) return negative_infinity;

        const factor = std.math.pow(f32, 10.0, -@as(f32, @floatFromInt(exp)));
        const scaled = val * factor;
        const rounded = @round(scaled);
        if (rounded < -2045.0 or rounded > 2045.0) {
            return error.MantissaOverflow;
        }
        const mant: i12 = @intFromFloat(rounded);
        return fromParts(mant, exp);
    }

    /// Encodes an integer value into Sfloat with exponent 0.
    pub fn fromInt(val: anytype) !Sfloat {
        const i_val: i32 = switch (@typeInfo(@TypeOf(val))) {
            .int, .comptime_int => @intCast(val),
            else => @compileError("fromInt requires an integer"),
        };
        if (i_val < -2045 or i_val > 2045) return error.MantissaOverflow;
        return fromParts(@intCast(i_val), 0);
    }

    /// Formatter for std.fmt (e.g. "{f}").
    pub fn format(self: Sfloat, w: anytype) !void {
        if (self.isNan()) {
            try w.writeAll("NaN");
        } else if (self.isPositiveInfinity()) {
            try w.writeAll("+Infinity");
        } else if (self.isNegativeInfinity()) {
            try w.writeAll("-Infinity");
        } else if (self.isNRes()) {
            try w.writeAll("NRes");
        } else if (self.isReserved()) {
            try w.writeAll("Reserved");
        } else {
            const v = self.toF32() catch return;
            try w.print("{d}", .{v});
        }
    }
};

/// IEEE-11073-20601 32-bit FLOAT.
/// Used for higher precision physiological metrics and environmental sensors.
///
/// Layout:
/// - Bits 0..23: 24-bit signed mantissa (two's complement, range -8,388,608 to +8,388,607)
/// - Bits 24..31: 8-bit signed exponent (two's complement, range -128 to +127)
///
/// Mathematical value: `mantissa * 10^(exponent)`
pub const Float32 = struct {
    raw: u32,

    pub const nan: Float32 = .{ .raw = 0x007FFFFF };
    pub const positive_infinity: Float32 = .{ .raw = 0x007FFFFE };
    pub const negative_infinity: Float32 = .{ .raw = 0x00800002 };
    pub const not_at_this_resolution: Float32 = .{ .raw = 0x00800000 };
    pub const reserved: Float32 = .{ .raw = 0x00800001 };

    /// Constructs a Float32 from a raw 32-bit integer.
    pub inline fn fromRaw(raw_val: u32) Float32 {
        return .{ .raw = raw_val };
    }

    /// Checks if this Float32 represents Not-a-Number (NaN).
    pub inline fn isNan(self: Float32) bool {
        return (self.raw & 0x00FFFFFF) == 0x007FFFFF;
    }

    /// Checks if this Float32 represents positive infinity (+INFINITY).
    pub inline fn isPositiveInfinity(self: Float32) bool {
        return (self.raw & 0x00FFFFFF) == 0x007FFFFE;
    }

    /// Checks if this Float32 represents negative infinity (-INFINITY).
    pub inline fn isNegativeInfinity(self: Float32) bool {
        return (self.raw & 0x00FFFFFF) == 0x00800002;
    }

    /// Checks if this Float32 represents Not at this Resolution (NRes).
    pub inline fn isNRes(self: Float32) bool {
        return (self.raw & 0x00FFFFFF) == 0x00800000;
    }

    /// Checks if this Float32 represents a reserved value.
    pub inline fn isReserved(self: Float32) bool {
        return (self.raw & 0x00FFFFFF) == 0x00800001;
    }

    /// Returns true if this value is any special IEEE-11073 value.
    pub inline fn isSpecial(self: Float32) bool {
        const m = self.raw & 0x00FFFFFF;
        return (m >= 0x007FFFFE and m <= 0x007FFFFF) or (m >= 0x00800000 and m <= 0x00800002);
    }

    /// Extracts the 24-bit signed mantissa with proper sign extension.
    pub inline fn mantissa(self: Float32) i32 {
        const m_u24: u24 = @truncate(self.raw);
        return @as(i24, @bitCast(m_u24));
    }

    /// Extracts the 8-bit signed base-10 exponent.
    pub inline fn exponent(self: Float32) i8 {
        const e_u8: u8 = @truncate(self.raw >> 24);
        return @as(i8, @bitCast(e_u8));
    }

    /// Constructs a Float32 from a 24-bit signed mantissa and 8-bit signed exponent.
    pub fn fromParts(mant: i24, exp: i8) Float32 {
        const m_u24: u24 = @bitCast(mant);
        const e_u8: u8 = @bitCast(exp);
        const raw = (@as(u32, e_u8) << 24) | @as(u32, m_u24);
        return .{ .raw = raw };
    }

    /// Decodes the Float32 into an IEEE-754 64-bit float (`f64`).
    pub fn toF64(self: Float32) !f64 {
        if (self.isNan()) return std.math.nan(f64);
        if (self.isPositiveInfinity()) return std.math.inf(f64);
        if (self.isNegativeInfinity()) return -std.math.inf(f64);
        if (self.isNRes()) return error.NotAtThisResolution;
        if (self.isReserved()) return error.ReservedValue;

        const m = @as(f64, @floatFromInt(self.mantissa()));
        const e = @as(f64, @floatFromInt(self.exponent()));
        return m * std.math.pow(f64, 10.0, e);
    }

    /// Decodes the Float32 into `f64`, returning NaN on NRes/Reserved.
    pub fn toF64Unchecked(self: Float32) f64 {
        return self.toF64() catch std.math.nan(f64);
    }

    /// Decodes the Float32 into an IEEE-754 32-bit float (`f32`).
    pub fn toF32(self: Float32) !f32 {
        const val = try self.toF64();
        return @floatCast(val);
    }

    /// Automatically encodes an `f64` value into an IEEE-11073 32-bit FLOAT,
    /// selecting the optimal base-10 exponent that preserves up to 7 decimal digits of precision.
    pub fn fromF64(val: f64) Float32 {
        if (std.math.isNan(val)) return nan;
        if (std.math.isPositiveInf(val)) return positive_infinity;
        if (std.math.isNegativeInf(val)) return negative_infinity;
        if (val == 0.0) return .{ .raw = 0 };

        var best_exp: i8 = 0;
        var best_mant: i24 = 0;
        var best_err: f64 = std.math.inf(f64);

        // Scan candidate exponents in [-64, 64]
        var exp: i8 = -64;
        while (exp <= 64) : (exp += 1) {
            const factor = std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(exp)));
            const scaled = val * factor;
            const rounded = @round(scaled);
            if (rounded >= -8388605.0 and rounded <= 8388605.0) {
                const mant: i24 = @intFromFloat(rounded);
                const reconstructed = @as(f64, @floatFromInt(mant)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exp)));
                const err = @abs(val - reconstructed);
                if (err < best_err) {
                    best_err = err;
                    best_exp = exp;
                    best_mant = mant;
                    if (err == 0.0) break;
                }
            }
        }

        return fromParts(best_mant, best_exp);
    }

    /// Encodes an `f32` value into an IEEE-11073 32-bit FLOAT.
    pub fn fromF32(val: f32) Float32 {
        return fromF64(@floatCast(val));
    }

    /// Convenience helper: converts any float type to Float32.
    pub inline fn fromFloat(val: anytype) Float32 {
        return fromF64(@floatCast(val));
    }

    /// Convenience helper: decodes Float32 to optional `f32` (returns null on NaN, NRes, or Reserved).
    pub inline fn toFloat(self: Float32) ?f32 {
        return self.toF32() catch null;
    }

    /// Encodes an `f64` with a specified fixed base-10 exponent.
    pub fn fromF64WithExponent(val: f64, exp: i8) !Float32 {
        if (std.math.isNan(val)) return nan;
        if (std.math.isPositiveInf(val)) return positive_infinity;
        if (std.math.isNegativeInf(val)) return negative_infinity;

        const factor = std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(exp)));
        const scaled = val * factor;
        const rounded = @round(scaled);
        if (rounded < -8388605.0 or rounded > 8388605.0) {
            return error.MantissaOverflow;
        }
        const mant: i24 = @intFromFloat(rounded);
        return fromParts(mant, exp);
    }

    /// Formatter for std.fmt (e.g. "{f}").
    pub fn format(self: Float32, w: anytype) !void {
        if (self.isNan()) {
            try w.writeAll("NaN");
        } else if (self.isPositiveInfinity()) {
            try w.writeAll("+Infinity");
        } else if (self.isNegativeInfinity()) {
            try w.writeAll("-Infinity");
        } else if (self.isNRes()) {
            try w.writeAll("NRes");
        } else if (self.isReserved()) {
            try w.writeAll("Reserved");
        } else {
            const v = self.toF64() catch return;
            try w.print("{d}", .{v});
        }
    }
};

/// Bluetooth SIG Characteristic Presentation Format Types (GATT Spec Supplement Part 3).
pub const FormatType = enum(u8) {
    rfudev = 0x00, // Reserved for future use
    boolean = 0x01, // Unsigned 1-bit; 0=false, 1=true
    uint2 = 0x02, // Unsigned 2-bit integer
    uint4 = 0x03, // Unsigned 4-bit integer
    uint8 = 0x04, // Unsigned 8-bit integer
    uint12 = 0x05, // Unsigned 12-bit integer
    uint16 = 0x06, // Unsigned 16-bit integer
    uint24 = 0x07, // Unsigned 24-bit integer
    uint32 = 0x08, // Unsigned 32-bit integer
    uint48 = 0x09, // Unsigned 48-bit integer
    uint64 = 0x0A, // Unsigned 64-bit integer
    uint128 = 0x0B, // Unsigned 128-bit integer
    sint8 = 0x0C, // Signed 8-bit integer
    sint12 = 0x0D, // Signed 12-bit integer
    sint16 = 0x0E, // Signed 16-bit integer
    sint24 = 0x0F, // Signed 24-bit integer
    sint32 = 0x10, // Signed 32-bit integer
    sint48 = 0x11, // Signed 48-bit integer
    sint64 = 0x12, // Signed 64-bit integer
    sint128 = 0x13, // Signed 128-bit integer
    float32 = 0x14, // IEEE-754 32-bit floating point
    float64 = 0x15, // IEEE-754 64-bit floating point
    sfloat = 0x16, // IEEE-11073 16-bit SFLOAT
    float = 0x17, // IEEE-11073 32-bit FLOAT
    duint16 = 0x18, // IEEE-20601 format
    utf8s = 0x19, // UTF-8 string
    utf16s = 0x1A, // UTF-16 string
    opaque_struct = 0x1B, // Opaque structure
    _,

    pub fn isValid(self: FormatType) bool {
        return @intFromEnum(self) <= 0x1B;
    }

    pub fn getName(self: FormatType) []const u8 {
        return switch (self) {
            .rfudev => "Reserved",
            .boolean => "boolean",
            .uint2 => "uint2",
            .uint4 => "uint4",
            .uint8 => "uint8",
            .uint12 => "uint12",
            .uint16 => "uint16",
            .uint24 => "uint24",
            .uint32 => "uint32",
            .uint48 => "uint48",
            .uint64 => "uint64",
            .uint128 => "uint128",
            .sint8 => "sint8",
            .sint12 => "sint12",
            .sint16 => "sint16",
            .sint24 => "sint24",
            .sint32 => "sint32",
            .sint48 => "sint48",
            .sint64 => "sint64",
            .sint128 => "sint128",
            .float32 => "float32 (IEEE-754)",
            .float64 => "float64 (IEEE-754)",
            .sfloat => "SFLOAT (IEEE-11073)",
            .float => "FLOAT (IEEE-11073)",
            .duint16 => "duint16",
            .utf8s => "UTF-8 String",
            .utf16s => "UTF-16 String",
            .opaque_struct => "Opaque Struct",
            _ => "Unknown Format",
        };
    }
};

/// GATT Characteristic Presentation Format Descriptor (UUID 0x2904).
/// Standardized 7-byte binary descriptor defining how a characteristic value is formatted,
/// its exponent, physical unit, and human-readable context.
pub const CharacteristicPresentationFormat = extern struct {
    format: FormatType,
    exponent: i8,
    unit: u16,
    namespace: u8 = 0x01, // 0x01 = Bluetooth SIG Assigned Numbers
    description: u16 = 0x0000,

    /// Encodes this descriptor into the standard 7-byte wire format.
    pub fn encode(self: CharacteristicPresentationFormat) [7]u8 {
        var buf: [7]u8 = undefined;
        buf[0] = @intFromEnum(self.format);
        buf[1] = @bitCast(self.exponent);
        std.mem.writeInt(u16, buf[2..4], self.unit, .little);
        buf[4] = self.namespace;
        std.mem.writeInt(u16, buf[5..7], self.description, .little);
        return buf;
    }

    /// Decodes a 7-byte buffer into a CharacteristicPresentationFormat struct.
    pub fn decode(bytes: []const u8) !CharacteristicPresentationFormat {
        if (bytes.len < 7) return error.BufferTooSmall;
        const fmt: FormatType = @enumFromInt(bytes[0]);
        if (!fmt.isValid()) return error.InvalidFormat;
        const exp: i8 = @bitCast(bytes[1]);
        const unit = std.mem.readInt(u16, bytes[2..4], .little);
        const ns = bytes[4];
        const desc = std.mem.readInt(u16, bytes[5..7], .little);
        return .{
            .format = fmt,
            .exponent = exp,
            .unit = unit,
            .namespace = ns,
            .description = desc,
        };
    }

    /// Parses raw characteristic bytes according to this presentation format and formats
    /// the human-readable result (with units and exponent scaling) into `buf`.
    pub fn formatValue(self: CharacteristicPresentationFormat, raw_bytes: []const u8, buf: []u8) ![]const u8 {
        var off: usize = 0;
        const sym = Units.getSymbol(self.unit);

        switch (self.format) {
            .boolean => {
                if (raw_bytes.len < 1) return error.UnexpectedEndOfData;
                const b = raw_bytes[0] != 0;
                const str = try std.fmt.bufPrint(buf[off..], "{}", .{b});
                off += str.len;
            },
            .uint8 => {
                if (raw_bytes.len < 1) return error.UnexpectedEndOfData;
                const v = raw_bytes[0];
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .uint16 => {
                if (raw_bytes.len < 2) return error.UnexpectedEndOfData;
                const v = std.mem.readInt(u16, raw_bytes[0..2], .little);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .uint32 => {
                if (raw_bytes.len < 4) return error.UnexpectedEndOfData;
                const v = std.mem.readInt(u32, raw_bytes[0..4], .little);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .sint8 => {
                if (raw_bytes.len < 1) return error.UnexpectedEndOfData;
                const v = @as(i8, @bitCast(raw_bytes[0]));
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .sint16 => {
                if (raw_bytes.len < 2) return error.UnexpectedEndOfData;
                const v = std.mem.readInt(i16, raw_bytes[0..2], .little);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .sint32 => {
                if (raw_bytes.len < 4) return error.UnexpectedEndOfData;
                const v = std.mem.readInt(i32, raw_bytes[0..4], .little);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatFromInt(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .float32 => {
                if (raw_bytes.len < 4) return error.UnexpectedEndOfData;
                const bits = std.mem.readInt(u32, raw_bytes[0..4], .little);
                const v: f32 = @bitCast(bits);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = @as(f64, @floatCast(v)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .float64 => {
                if (raw_bytes.len < 8) return error.UnexpectedEndOfData;
                const bits = std.mem.readInt(u64, raw_bytes[0..8], .little);
                const v: f64 = @bitCast(bits);
                if (self.exponent == 0) {
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                    off += str.len;
                } else {
                    const scaled = v * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(self.exponent)));
                    const str = try std.fmt.bufPrint(buf[off..], "{d}", .{scaled});
                    off += str.len;
                }
            },
            .sfloat => {
                if (raw_bytes.len < 2) return error.UnexpectedEndOfData;
                const raw = std.mem.readInt(u16, raw_bytes[0..2], .little);
                const sf = Sfloat{ .raw = raw };
                const v = try sf.toF32();
                const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                off += str.len;
            },
            .float => {
                if (raw_bytes.len < 4) return error.UnexpectedEndOfData;
                const raw = std.mem.readInt(u32, raw_bytes[0..4], .little);
                const fl = Float32{ .raw = raw };
                const v = try fl.toF64();
                const str = try std.fmt.bufPrint(buf[off..], "{d}", .{v});
                off += str.len;
            },
            .utf8s => {
                if (buf[off..].len < raw_bytes.len) return error.BufferTooSmall;
                @memcpy(buf[off .. off + raw_bytes.len], raw_bytes);
                off += raw_bytes.len;
            },
            else => {
                const str = try std.fmt.bufPrint(buf[off..], "<format: 0x{X:0>2}, len: {d}>", .{ @intFromEnum(self.format), raw_bytes.len });
                off += str.len;
            },
        }

        if (sym) |s| {
            if (s.len > 0) {
                const str = try std.fmt.bufPrint(buf[off..], " {s}", .{s});
                off += str.len;
            }
        }

        return buf[0..off];
    }
};

// ============================================================================
// Strongly-Typed Serialization Engine
// ============================================================================

/// Serializes any supported Zig type (integer, float, bool, enum, packed/extern struct,
/// Sfloat, Float32, or custom encode() type) into little-endian bytes.
/// Returns the number of bytes written.
pub fn serialize(val: anytype, buf: []u8) !usize {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .bool => {
            if (buf.len < 1) return error.BufferTooSmall;
            buf[0] = if (val) 1 else 0;
            return 1;
        },
        .int => {
            const size = @sizeOf(T);
            if (buf.len < size) return error.BufferTooSmall;
            std.mem.writeInt(T, buf[0..size], val, .little);
            return size;
        },
        .float => {
            const size = @sizeOf(T);
            if (buf.len < size) return error.BufferTooSmall;
            const IntType = switch (size) {
                4 => u32,
                8 => u64,
                else => @compileError("Unsupported float size for GATT serialization: " ++ @typeName(T)),
            };
            const int_bits: IntType = @bitCast(val);
            std.mem.writeInt(IntType, buf[0..size], int_bits, .little);
            return size;
        },
        .@"enum" => {
            const Tag = @typeInfo(T).@"enum".tag_type;
            const size = @sizeOf(Tag);
            if (buf.len < size) return error.BufferTooSmall;
            std.mem.writeInt(Tag, buf[0..size], @intFromEnum(val), .little);
            return size;
        },
        .@"struct" => |s| {
            if (T == Sfloat) {
                if (buf.len < 2) return error.BufferTooSmall;
                std.mem.writeInt(u16, buf[0..2], val.raw, .little);
                return 2;
            } else if (T == Float32) {
                if (buf.len < 4) return error.BufferTooSmall;
                std.mem.writeInt(u32, buf[0..4], val.raw, .little);
                return 4;
            } else if (T == CharacteristicPresentationFormat) {
                if (buf.len < 7) return error.BufferTooSmall;
                const enc = val.encode();
                @memcpy(buf[0..7], &enc);
                return 7;
            } else if (s.layout == .@"packed") {
                const IntType = s.backing_integer orelse std.meta.Int(.unsigned, @bitSizeOf(T));
                const size = @sizeOf(IntType);
                if (buf.len < size) return error.BufferTooSmall;
                const int_val: IntType = @bitCast(val);
                std.mem.writeInt(IntType, buf[0..size], int_val, .little);
                return size;
            } else if (s.layout == .@"extern") {
                const size = @sizeOf(T);
                if (buf.len < size) return error.BufferTooSmall;
                @memcpy(buf[0..size], @as([*]const u8, @ptrCast(&val))[0..size]);
                return size;
            } else if (@hasDecl(T, "encode")) {
                return try val.encode(buf);
            } else {
                @compileError("Unsupported struct type for GATT serialization: " ++ @typeName(T));
            }
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (buf.len < val.len) return error.BufferTooSmall;
                @memcpy(buf[0..val.len], val);
                return val.len;
            } else {
                @compileError("Unsupported pointer type for GATT serialization: " ++ @typeName(T));
            }
        },
        else => @compileError("Unsupported type for GATT serialization: " ++ @typeName(T)),
    }
}

/// Deserializes a little-endian byte slice into the specified target type `T`.
/// Supports integers, floats, bool, enums, packed/extern structs, Sfloat, Float32,
/// slices (`[]const u8`), and custom types with a `decode([]const u8)` method.
pub fn deserialize(comptime T: type, buf: []const u8) !T {
    switch (@typeInfo(T)) {
        .bool => {
            if (buf.len < 1) return error.UnexpectedEndOfData;
            return buf[0] != 0;
        },
        .int => {
            const size = @sizeOf(T);
            if (buf.len < size) return error.UnexpectedEndOfData;
            return std.mem.readInt(T, buf[0..size], .little);
        },
        .float => {
            const size = @sizeOf(T);
            if (buf.len < size) return error.UnexpectedEndOfData;
            const IntType = switch (size) {
                4 => u32,
                8 => u64,
                else => @compileError("Unsupported float size for GATT deserialization: " ++ @typeName(T)),
            };
            const int_bits = std.mem.readInt(IntType, buf[0..size], .little);
            return @bitCast(int_bits);
        },
        .@"enum" => {
            const Tag = @typeInfo(T).@"enum".tag_type;
            const size = @sizeOf(Tag);
            if (buf.len < size) return error.UnexpectedEndOfData;
            const raw_val = std.mem.readInt(Tag, buf[0..size], .little);
            return @enumFromInt(raw_val);
        },
        .@"struct" => |s| {
            if (T == Sfloat) {
                if (buf.len < 2) return error.UnexpectedEndOfData;
                return Sfloat{ .raw = std.mem.readInt(u16, buf[0..2], .little) };
            } else if (T == Float32) {
                if (buf.len < 4) return error.UnexpectedEndOfData;
                return Float32{ .raw = std.mem.readInt(u32, buf[0..4], .little) };
            } else if (T == CharacteristicPresentationFormat) {
                return CharacteristicPresentationFormat.decode(buf);
            } else if (s.layout == .@"packed") {
                const IntType = s.backing_integer orelse std.meta.Int(.unsigned, @bitSizeOf(T));
                const size = @sizeOf(IntType);
                if (buf.len < size) return error.UnexpectedEndOfData;
                const int_val = std.mem.readInt(IntType, buf[0..size], .little);
                return @bitCast(int_val);
            } else if (s.layout == .@"extern") {
                const size = @sizeOf(T);
                if (buf.len < size) return error.UnexpectedEndOfData;
                var res: T = undefined;
                @memcpy(@as([*]u8, @ptrCast(&res))[0..size], buf[0..size]);
                return res;
            } else if (@hasDecl(T, "decode")) {
                return try T.decode(buf);
            } else {
                @compileError("Unsupported struct type for GATT deserialization: " ++ @typeName(T));
            }
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return buf;
            } else {
                @compileError("Unsupported pointer type for GATT deserialization: " ++ @typeName(T));
            }
        },
        else => @compileError("Unsupported type for GATT deserialization: " ++ @typeName(T)),
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Sfloat conversions and special values" {
    // 36.6 Celsius body temperature
    const s_temp = Sfloat.fromF32(36.6);
    const f_temp = try s_temp.toF32();
    try std.testing.expectApproxEqAbs(@as(f32, 36.6), f_temp, 0.01);

    // Negative temperature -15.5
    const s_neg = Sfloat.fromF32(-15.5);
    const f_neg = try s_neg.toF32();
    try std.testing.expectApproxEqAbs(@as(f32, -15.5), f_neg, 0.01);

    // Integer conversion
    const s_int = try Sfloat.fromInt(120);
    try std.testing.expectEqual(@as(i16, 120), s_int.mantissa());
    try std.testing.expectEqual(@as(i8, 0), s_int.exponent());

    // Special values
    try std.testing.expect(Sfloat.nan.isNan());
    try std.testing.expect(Sfloat.positive_infinity.isPositiveInfinity());
    try std.testing.expect(Sfloat.negative_infinity.isNegativeInfinity());
    try std.testing.expect(Sfloat.not_at_this_resolution.isNRes());
    try std.testing.expect(Sfloat.reserved.isReserved());
}

test "Float32 conversions and special values" {
    const fl_val = Float32.fromF64(101325.0); // 101325 Pa atmospheric pressure
    const dec = try fl_val.toF64();
    try std.testing.expectApproxEqAbs(@as(f64, 101325.0), dec, 0.1);

    try std.testing.expect(Float32.nan.isNan());
    try std.testing.expect(Float32.positive_infinity.isPositiveInfinity());
    try std.testing.expect(Float32.negative_infinity.isNegativeInfinity());
    try std.testing.expect(Float32.not_at_this_resolution.isNRes());
    try std.testing.expect(Float32.reserved.isReserved());
}

test "CharacteristicPresentationFormat encode decode and formatValue" {
    const cpf = CharacteristicPresentationFormat{
        .format = .sfloat,
        .exponent = 0,
        .unit = Units.celsius,
        .namespace = 0x01,
        .description = 0x0000,
    };
    const wire = cpf.encode();
    try std.testing.expectEqual(@as(usize, 7), wire.len);

    const decoded = try CharacteristicPresentationFormat.decode(&wire);
    try std.testing.expectEqual(FormatType.sfloat, decoded.format);
    try std.testing.expectEqual(Units.celsius, decoded.unit);

    // Format raw temperature bytes into formatted string with unit symbol
    const temp_sfloat = Sfloat.fromF32(37.2);
    var raw: [2]u8 = undefined;
    _ = try serialize(temp_sfloat, &raw);

    var text_buf: [64]u8 = undefined;
    const formatted = try decoded.formatValue(&raw, &text_buf);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "37.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "°C") != null);
}

test "Typed serialization engine primitives and structs" {
    var buf: [64]u8 = undefined;

    // Primitives
    const n_u16 = try serialize(@as(u16, 0xCAFE), &buf);
    try std.testing.expectEqual(@as(u16, 0xCAFE), try deserialize(u16, buf[0..n_u16]));

    const n_i32 = try serialize(@as(i32, -123456), &buf);
    try std.testing.expectEqual(@as(i32, -123456), try deserialize(i32, buf[0..n_i32]));

    const n_bool = try serialize(true, &buf);
    try std.testing.expectEqual(true, try deserialize(bool, buf[0..n_bool]));

    const n_f32 = try serialize(@as(f32, 3.1415), &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 3.1415), try deserialize(f32, buf[0..n_f32]), 0.0001);

    // Packed struct
    const PackedPkt = packed struct(u8) {
        mode: u2,
        active: bool,
        counter: u5,
    };
    const pkt = PackedPkt{ .mode = 3, .active = true, .counter = 17 };
    const n_pkt = try serialize(pkt, &buf);
    const pkt_dec = try deserialize(PackedPkt, buf[0..n_pkt]);
    try std.testing.expectEqual(pkt.mode, pkt_dec.mode);
    try std.testing.expectEqual(pkt.active, pkt_dec.active);
    try std.testing.expectEqual(pkt.counter, pkt_dec.counter);
}
