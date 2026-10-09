const std = @import("std");

/// Bluetooth LE address types according to Bluetooth Core Specification (Vol 6, Part B, Section 1.3).
pub const AddressType = enum {
    /// Public, IEEE-registered MAC address (fixed hardware address).
    public,
    /// Random device address (umbrella term for static and private addresses).
    random,
    /// Random Static: Remains constant across power cycles.
    random_static,
    /// Resolvable Private Address (RPA): Changes periodically, resolvable using an IRK (Identity Resolving Key).
    random_private_resolvable,
    /// Non-resolvable Private Address (NRPA): Random address for privacy protection (e.g. beacons).
    random_private_non_resolvable,

    /// Parses common address type strings (e.g. from BlueZ or configurations) into an AddressType.
    pub fn parse(str: []const u8) ?AddressType {
        if (std.ascii.eqlIgnoreCase(str, "public")) return .public;
        if (std.ascii.eqlIgnoreCase(str, "random")) return .random;
        if (std.ascii.eqlIgnoreCase(str, "static") or std.ascii.eqlIgnoreCase(str, "random-static")) return .random_static;
        if (std.ascii.eqlIgnoreCase(str, "rpa") or std.ascii.eqlIgnoreCase(str, "resolvable")) return .random_private_resolvable;
        if (std.ascii.eqlIgnoreCase(str, "nrpa") or std.ascii.eqlIgnoreCase(str, "non-resolvable")) return .random_private_non_resolvable;
        return null;
    }

    pub fn toString(self: AddressType) []const u8 {
        return switch (self) {
            .public => "public",
            .random => "random",
            .random_static => "random_static",
            .random_private_resolvable => "random_private_resolvable",
            .random_private_non_resolvable => "random_private_non_resolvable",
        };
    }
};

/// Bluetooth Device Address (BD_ADDR, 48-bit / 6 bytes).
/// Stored in big-endian in memory (MSB = bytes[0]), matching standard string representation "XX:XX:XX:XX:XX:XX".
pub const Address = struct {
    bytes: [6]u8,

    pub const any = Address{ .bytes = @splat(0) };

    pub const ParseError = error{
        InvalidLength,
        InvalidFormat,
        InvalidCharacter,
    };

    /// Parses a MAC address from strings formatted as "XX:XX:XX:XX:XX:XX" or "XX-XX-XX-XX-XX-XX".
    /// 100% zero heap allocations.
    pub fn parse(str: []const u8) ParseError!Address {
        if (str.len != 17) {
            return ParseError.InvalidLength;
        }

        var result: [6]u8 = undefined;
        var byte_idx: usize = 0;
        var i: usize = 0;

        while (i < str.len) : (i += 3) {
            const hi = try parseHexNibble(str[i]);
            const lo = try parseHexNibble(str[i + 1]);
            result[byte_idx] = (@as(u8, hi) << 4) | lo;
            byte_idx += 1;

            if (byte_idx < 6) {
                const sep = str[i + 2];
                if (sep != ':' and sep != '-') {
                    return ParseError.InvalidFormat;
                }
            }
        }

        return Address{ .bytes = result };
    }

    /// Helper function to parse a single hex nibble.
    pub fn parseHexNibble(c: u8) ParseError!u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => ParseError.InvalidCharacter,
        };
    }

    /// Classifies a random address according to the Bluetooth Core Specification
    /// based on the two most significant bits (MSB, bytes[0] in big-endian):
    /// - 0b11 -> Static Device Address
    /// - 0b00 -> Non-resolvable Private Address (NRPA)
    /// - 0b01 -> Resolvable Private Address (RPA)
    pub fn classifyRandom(self: Address) AddressType {
        const msb_two_bits = self.bytes[0] >> 6;
        return switch (msb_two_bits) {
            0b11 => .random_static,
            0b01 => .random_private_resolvable,
            0b00 => .random_private_non_resolvable,
            else => .random,
        };
    }

    /// Formats the address into a provided 17-byte buffer as "XX:XX:XX:XX:XX:XX".
    /// Zero heap allocations.
    pub fn formatBuf(self: Address, buf: *[17]u8) []const u8 {
        const hex = "0123456789ABCDEF";
        for (self.bytes, 0..) |b, i| {
            buf[i * 3] = hex[(b >> 4) & 0x0F];
            buf[i * 3 + 1] = hex[b & 0x0F];
            if (i < 5) {
                buf[i * 3 + 2] = ':';
            }
        }
        return buf[0..17];
    }

    /// Generates the 17-byte string representation "XX:XX:XX:XX:XX:XX" directly on the stack.
    pub fn toString(self: Address) [17]u8 {
        var buf: [17]u8 = undefined;
        _ = self.formatBuf(&buf);
        return buf;
    }

    /// Standard Zig std.fmt formatter (callable via "{f}").
    pub fn format(self: Address, w: anytype) !void {
        var buf: [17]u8 = undefined;
        _ = self.formatBuf(&buf);
        try w.writeAll(&buf);
    }

    /// Compares two addresses for equality.
    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Returns the bytes in little-endian order (e.g. for BLE over-the-air packets).
    pub fn toLittleEndian(self: Address) [6]u8 {
        return .{
            self.bytes[5],
            self.bytes[4],
            self.bytes[3],
            self.bytes[2],
            self.bytes[1],
            self.bytes[0],
        };
    }

    /// Creates an Address from little-endian bytes (e.g. from received BLE packets).
    pub fn fromLittleEndian(le_bytes: [6]u8) Address {
        return Address{
            .bytes = .{
                le_bytes[5],
                le_bytes[4],
                le_bytes[3],
                le_bytes[2],
                le_bytes[1],
                le_bytes[0],
            },
        };
    }
};

/// Complete device address (combination of 48-bit BD_ADDR and AddressType).
pub const DeviceAddress = struct {
    address: Address,
    address_type: AddressType = .public,

    pub fn eql(self: DeviceAddress, other: DeviceAddress) bool {
        return self.address.eql(other.address) and self.address_type == other.address_type;
    }

    /// Standard Zig std.fmt formatter (callable via "{f}").
    pub fn format(self: DeviceAddress, w: anytype) !void {
        try w.print("{f} ({s})", .{ self.address, @tagName(self.address_type) });
    }
};

/// Bluetooth UUID (Universally Unique Identifier).
/// Supports 16-bit, 32-bit, and 128-bit UUIDs.
/// Standardized internally as a 16-byte big-endian array.
pub const UUID = struct {
    bytes: [16]u8,

    /// Bluetooth SIG Base UUID: 00000000-0000-1000-8000-00805F9B34FB
    pub const BASE_UUID: [16]u8 = .{
        0x00, 0x00, 0x00, 0x00, // 0..3: 32-bit / 16-bit field
        0x00, 0x00, // 4..5
        0x10, 0x00, // 6..7
        0x80, 0x00, // 8..9
        0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB, // 10..15
    };

    pub const ParseError = error{
        InvalidLength,
        InvalidFormat,
        InvalidCharacter,
    };

    /// Creates a 128-bit UUID from a 16-byte big-endian array.
    pub fn fromBytes(bytes: [16]u8) UUID {
        return UUID{ .bytes = bytes };
    }

    /// Creates a 128-bit UUID from a `u128` (big-endian).
    pub fn fromU128(val: u128) UUID {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, val, .big);
        return UUID{ .bytes = bytes };
    }

    /// Creates a 128-bit UUID from a 16-bit Bluetooth SIG short UUID (e.g. 0x180D).
    pub fn from16(short_uuid: u16) UUID {
        var result = BASE_UUID;
        result[2] = @intCast((short_uuid >> 8) & 0xFF);
        result[3] = @intCast(short_uuid & 0xFF);
        return UUID{ .bytes = result };
    }

    /// Creates a 128-bit UUID from a 32-bit Bluetooth SIG UUID.
    pub fn from32(uuid32: u32) UUID {
        var result = BASE_UUID;
        result[0] = @intCast((uuid32 >> 24) & 0xFF);
        result[1] = @intCast((uuid32 >> 16) & 0xFF);
        result[2] = @intCast((uuid32 >> 8) & 0xFF);
        result[3] = @intCast(uuid32 & 0xFF);
        return UUID{ .bytes = result };
    }

    inline fn parseHexNibblesSimd(comptime N: usize, v: @Vector(N, u8)) ParseError!@Vector(N, u8) {
        const zero: @Vector(N, u8) = @splat('0');
        const nine: @Vector(N, u8) = @splat('9');
        const lower_a: @Vector(N, u8) = @splat('a');
        const lower_f: @Vector(N, u8) = @splat('f');
        const upper_a: @Vector(N, u8) = @splat('A');
        const upper_f: @Vector(N, u8) = @splat('F');

        const is_digit = (v >= zero) & (v <= nine);
        const is_lower = (v >= lower_a) & (v <= lower_f);
        const is_upper = (v >= upper_a) & (v <= upper_f);

        const valid = is_digit | is_lower | is_upper;
        if (!@reduce(.And, valid)) return ParseError.InvalidCharacter;

        const digit_val = v -% zero;
        const lower_val = v -% @as(@Vector(N, u8), @splat(87)); // 'a' - 10
        const upper_val = v -% @as(@Vector(N, u8), @splat(55)); // 'A' - 10

        return @select(u8, is_digit, digit_val, @select(u8, is_lower, lower_val, upper_val));
    }

    inline fn packNibblesSimd32(nibbles: @Vector(32, u8)) [16]u8 {
        const hi = @shuffle(u8, nibbles, undefined, [16]i32{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30 });
        const lo = @shuffle(u8, nibbles, undefined, [16]i32{ 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31 });
        const packed_vec: @Vector(16, u8) = (hi << @as(@Vector(16, u8), @splat(4))) | lo;
        return @bitCast(packed_vec);
    }

    /// Universal UUID parser supporting multiple formats (SIMD-accelerated for 128-bit):
    /// - 16-bit hex: "180D" or "0x180D"
    /// - 32-bit hex: "0000180D" or "0x0000180D"
    /// - 128-bit hyphenated: "0000180d-0000-1000-8000-00805f9b34fb"
    /// - 128-bit flat: "0000180d00001000800000805f9b34fb"
    pub fn parse(str: []const u8) ParseError!UUID {
        var s = str;
        if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
            s = s[2..];
        }

        if (s.len == 4) {
            // 16-Bit UUID
            var val: u16 = 0;
            for (s) |c| {
                const nibble = try Address.parseHexNibble(c);
                val = (val << 4) | nibble;
            }
            return from16(val);
        } else if (s.len == 8) {
            // 32-Bit UUID
            var val: u32 = 0;
            for (s) |c| {
                const nibble = try Address.parseHexNibble(c);
                val = (val << 4) | nibble;
            }
            return from32(val);
        } else if (s.len == 32) {
            // 128-Bit UUID ohne Bindestriche (Single-Pass 32-Byte AVX2/NEON SIMD)
            const v: @Vector(32, u8) = s[0..32].*;
            const nibbles = try parseHexNibblesSimd(32, v);
            return UUID{ .bytes = packNibblesSimd32(nibbles) };
        } else if (s.len == 36) {
            // Standard 128-Bit UUID mit Bindestrichen: 8-4-4-4-12
            if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') {
                return ParseError.InvalidFormat;
            }

            const v: @Vector(36, u8) = s[0..36].*;
            const hex_chars: @Vector(32, u8) = @shuffle(u8, v, undefined, [32]i32{
                0,  1,  2,  3,  4,  5,  6,  7,
                9,  10, 11, 12, 14, 15, 16, 17,
                19, 20, 21, 22, 24, 25, 26, 27,
                28, 29, 30, 31, 32, 33, 34, 35,
            });

            const nibbles = try parseHexNibblesSimd(32, hex_chars);
            return UUID{ .bytes = packNibblesSimd32(nibbles) };
        }

        return ParseError.InvalidLength;
    }

    /// Converts the 128-bit UUID into little-endian byte order (for BLE over-the-air ATT/GATT packets).
    pub fn toLittleEndian(self: UUID) [16]u8 {
        var res: [16]u8 = undefined;
        for (0..16) |i| {
            res[i] = self.bytes[15 - i];
        }
        return res;
    }

    /// Creates a 128-bit UUID from received little-endian bytes (e.g. from ATT Read/Notify payloads).
    pub fn fromLittleEndian(le_bytes: [16]u8) UUID {
        var res: [16]u8 = undefined;
        for (0..16) |i| {
            res[i] = le_bytes[15 - i];
        }
        return UUID{ .bytes = res };
    }

    /// Returns the internal 16-byte big-endian representation.
    pub inline fn toBytes(self: UUID) [16]u8 {
        return self.bytes;
    }

    /// Checks if this is a custom 128-bit vendor UUID (not a standard 16-bit SIG alias).
    pub inline fn is128Bit(self: UUID) bool {
        return !self.is16Bit();
    }

    /// Checks if this UUID represents a 16-bit Bluetooth SIG standard UUID.
    /// Uses two native register comparisons (32-bit and 64-bit) instead of byte loops.
    pub inline fn is16Bit(self: UUID) bool {
        if (self.bytes[0] != 0 or self.bytes[1] != 0) return false;
        const mid = std.mem.readInt(u32, self.bytes[4..8], .big);
        if (mid != 0x00001000) return false;
        const tail = std.mem.readInt(u64, self.bytes[8..16], .big);
        return tail == 0x8000_0080_5F9B_34FB;
    }

    /// Returns the 16-bit short value if this is a Bluetooth SIG 16-bit UUID.
    pub inline fn to16(self: UUID) ?u16 {
        if (!self.is16Bit()) return null;
        return (@as(u16, self.bytes[2]) << 8) | self.bytes[3];
    }

    /// Checks if this UUID represents a 32-bit Bluetooth SIG standard UUID.
    pub inline fn is32Bit(self: UUID) bool {
        const mid = std.mem.readInt(u32, self.bytes[4..8], .big);
        if (mid != 0x00001000) return false;
        const tail = std.mem.readInt(u64, self.bytes[8..16], .big);
        return tail == 0x8000_0080_5F9B_34FB;
    }

    /// Returns the 32-bit value if this is a Bluetooth SIG 32-bit UUID.
    pub inline fn to32(self: UUID) ?u32 {
        if (!self.is32Bit()) return null;
        return std.mem.readInt(u32, self.bytes[0..4], .big);
    }

    /// Compares two UUIDs for equality.
    pub fn eql(self: UUID, other: UUID) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Formats the UUID into a buffer (36 bytes) in canonical format:
    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (lowercase).
    pub fn formatBuf(self: UUID, buf: *[36]u8) []const u8 {
        const hex = "0123456789abcdef";
        var out_idx: usize = 0;

        for (self.bytes, 0..) |b, i| {
            buf[out_idx] = hex[(b >> 4) & 0x0F];
            buf[out_idx + 1] = hex[b & 0x0F];
            out_idx += 2;

            if (i == 3 or i == 5 or i == 7 or i == 9) {
                buf[out_idx] = '-';
                out_idx += 1;
            }
        }

        return buf[0..36];
    }

    /// Generates the 36-byte string representation directly on the stack.
    pub fn toString(self: UUID) [36]u8 {
        var buf: [36]u8 = undefined;
        _ = self.formatBuf(&buf);
        return buf;
    }

    /// Standard Zig std.fmt formatter (callable via "{f}").
    pub fn format(self: UUID, w: anytype) !void {
        var buf: [36]u8 = undefined;
        _ = self.formatBuf(&buf);
        try w.writeAll(&buf);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "AddressType parsing and classification" {
    try std.testing.expectEqual(AddressType.public, AddressType.parse("public").?);
    try std.testing.expectEqual(AddressType.random, AddressType.parse("random").?);
    try std.testing.expectEqual(AddressType.random_static, AddressType.parse("static").?);
    try std.testing.expectEqual(AddressType.random_private_resolvable, AddressType.parse("rpa").?);
    try std.testing.expectEqual(AddressType.random_private_non_resolvable, AddressType.parse("nrpa").?);
    try std.testing.expect(AddressType.parse("invalid") == null);

    // Random Address Classification
    // Static: MSB bits 11 -> z. B. 0xC0...
    const static_addr = try Address.parse("C0:11:22:33:44:55");
    try std.testing.expectEqual(AddressType.random_static, static_addr.classifyRandom());

    // RPA: MSB bits 01 -> z. B. 0x40...
    const rpa_addr = try Address.parse("40:11:22:33:44:55");
    try std.testing.expectEqual(AddressType.random_private_resolvable, rpa_addr.classifyRandom());

    // NRPA: MSB bits 00 -> z. B. 0x00...
    const nrpa_addr = try Address.parse("00:11:22:33:44:55");
    try std.testing.expectEqual(AddressType.random_private_non_resolvable, nrpa_addr.classifyRandom());
}

test "Address: parsing standard MAC format" {
    const addr = try Address.parse("00:1A:7D:DA:71:13");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x1A, 0x7D, 0xDA, 0x71, 0x13 }, &addr.bytes);

    const addr_lower = try Address.parse("00:1a:7d:da:71:13");
    try std.testing.expect(addr.eql(addr_lower));

    const addr_dash = try Address.parse("00-1A-7D-DA-71-13");
    try std.testing.expect(addr.eql(addr_dash));
}

test "Address: formatBuf and printing" {
    const addr = try Address.parse("F0:B5:D1:89:C2:54");
    var buf: [17]u8 = undefined;
    const formatted = addr.formatBuf(&buf);
    try std.testing.expectEqualStrings("F0:B5:D1:89:C2:54", formatted);

    const str = addr.toString();
    try std.testing.expectEqualStrings("F0:B5:D1:89:C2:54", &str);
}

test "Address: little endian conversion" {
    const addr = try Address.parse("11:22:33:44:55:66");
    const le = addr.toLittleEndian();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, &le);

    const from_le = Address.fromLittleEndian(le);
    try std.testing.expect(addr.eql(from_le));
}

test "UUID: 16-bit expansion to Base UUID" {
    const uuid16 = UUID.from16(0x180D);
    try std.testing.expect(uuid16.is16Bit());
    try std.testing.expectEqual(@as(?u16, 0x180D), uuid16.to16());

    var buf: [36]u8 = undefined;
    const formatted = uuid16.formatBuf(&buf);
    try std.testing.expectEqualStrings("0000180d-0000-1000-8000-00805f9b34fb", formatted);
}

test "UUID: parse 16-bit, 32-bit, and 128-bit strings" {
    const uuid1 = try UUID.parse("180D");
    try std.testing.expectEqual(@as(?u16, 0x180D), uuid1.to16());

    const uuid2 = try UUID.parse("0000180D");
    try std.testing.expect(uuid1.eql(uuid2));

    const uuid3 = try UUID.parse("0000180d-0000-1000-8000-00805f9b34fb");
    try std.testing.expect(uuid1.eql(uuid3));

    const vendor_str = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
    const vendor = try UUID.parse(vendor_str);
    var buf: [36]u8 = undefined;
    try std.testing.expectEqualStrings(vendor_str, vendor.formatBuf(&buf));
}

test "std.fmt compatibility: Address, DeviceAddress, and UUID" {
    const addr = try Address.parse("C0:1A:7D:DA:71:13");
    var buf_addr: [32]u8 = undefined;
    const formatted_addr = try std.fmt.bufPrint(&buf_addr, "{f}", .{addr});
    try std.testing.expectEqualStrings("C0:1A:7D:DA:71:13", formatted_addr);

    const dev_addr = DeviceAddress{ .address = addr, .address_type = .random_static };
    var buf_dev: [64]u8 = undefined;
    const formatted_dev = try std.fmt.bufPrint(&buf_dev, "{f}", .{dev_addr});
    try std.testing.expectEqualStrings("C0:1A:7D:DA:71:13 (random_static)", formatted_dev);

    const uuid = try UUID.parse("0000180d-0000-1000-8000-00805f9b34fb");
    var buf_uuid: [48]u8 = undefined;
    const formatted_uuid = try std.fmt.bufPrint(&buf_uuid, "{f}", .{uuid});
    try std.testing.expectEqualStrings("0000180d-0000-1000-8000-00805f9b34fb", formatted_uuid);
}

test "UUID: little endian conversion and roundtrip" {
    const original = try UUID.parse("0000180d-0000-1000-8000-00805f9b34fb");
    const le_bytes = original.toLittleEndian();

    // Verify first and last bytes are reversed
    try std.testing.expectEqual(original.bytes[0], le_bytes[15]);
    try std.testing.expectEqual(original.bytes[15], le_bytes[0]);

    const reconstructed = UUID.fromLittleEndian(le_bytes);
    try std.testing.expect(original.eql(reconstructed));
}

test "UUID: SIMD parsing of flat 32-char and uppercase strings" {
    // Canonical hyphenated lowercase
    const canonical = try UUID.parse("6e400001-b5a3-f393-e0a9-e50e24dcca9e");

    // Canonical hyphenated uppercase
    const upper = try UUID.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
    try std.testing.expect(canonical.eql(upper));

    // Flat 32-char lowercase (SIMD 32-char branch)
    const flat_lower = try UUID.parse("6e400001b5a3f393e0a9e50e24dcca9e");
    try std.testing.expect(canonical.eql(flat_lower));

    // Flat 32-char uppercase
    const flat_upper = try UUID.parse("6E400001B5A3F393E0A9E50E24DCCA9E");
    try std.testing.expect(canonical.eql(flat_upper));

    // With 0x prefix
    const prefixed = try UUID.parse("0x6e400001b5a3f393e0a9e50e24dcca9e");
    try std.testing.expect(canonical.eql(prefixed));

    // Error handling
    try std.testing.expectError(error.InvalidCharacter, UUID.parse("6e400001-b5a3-f393-e0a9-e50e24dcca9g")); // 'g' invalid
    try std.testing.expectError(error.InvalidFormat, UUID.parse("6e400001_b5a3_f393_e0a9_e50e24dcca9e")); // wrong separator
    try std.testing.expectError(error.InvalidLength, UUID.parse("6e400001-b5a3-f393")); // truncated
}
