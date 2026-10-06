const std = @import("std");
const types = @import("types.zig");
const UUID = types.UUID;
const CompanyId = @import("assigned_numbers.zig").CompanyId;

/// Standardized Advertising Data (AD) Types according to the Bluetooth Core Specification Supplement (CSS).
pub const AdType = enum(u8) {
    flags = 0x01,
    incomplete_16bit_service_uuids = 0x02,
    complete_16bit_service_uuids = 0x03,
    incomplete_32bit_service_uuids = 0x04,
    complete_32bit_service_uuids = 0x05,
    incomplete_128bit_service_uuids = 0x06,
    complete_128bit_service_uuids = 0x07,
    shortened_local_name = 0x08,
    complete_local_name = 0x09,
    tx_power_level = 0x0A,
    service_data_16bit = 0x16,
    appearance = 0x19,
    service_data_32bit = 0x20,
    service_data_128bit = 0x21,
    advertising_interval = 0x1A,
    periodic_advertising_interval = 0x2A,
    broadcast_code = 0x2D,
    resolvable_set_identifier = 0x2E,
    manufacturer_specific_data = 0xFF,
    _,
};

/// Bluetooth Radio Physical Layer (PHY) types (Bluetooth Core Spec v5.0+).
pub const PhyType = enum(u8) {
    /// 1 Mbps standard BLE PHY (Bluetooth 4.0 - 6.0 compatible).
    le_1m = 1,
    /// 2 Mbps high-throughput PHY (Bluetooth 5.0+).
    le_2m = 2,
    /// LE Coded PHY for long-range communication (S=2 500 kbps, S=8 125 kbps).
    le_coded = 3,

    pub fn toString(self: PhyType) []const u8 {
        return switch (self) {
            .le_1m => "1M",
            .le_2m => "2M",
            .le_coded => "Coded",
        };
    }
};

/// Secondary Advertising Channel selection for Extended Advertising (Bluetooth 5.0+).
pub const SecondaryChannel = enum {
    none,
    le_1m,
    le_2m,
    coded,

    pub fn toBluezString(self: SecondaryChannel) ?[:0]const u8 {
        return switch (self) {
            .none => null,
            .le_1m => "1M",
            .le_2m => "2M",
            .coded => "Coded",
        };
    }
};

/// BLE Advertising Flags (AD Type 0x01, 1 byte).
pub const AdvertisingFlags = packed struct(u8) {
    /// LE Limited Discoverable Mode (device is discoverable for a limited time).
    le_limited_discoverable: bool = false,
    /// LE General Discoverable Mode (device is continuously discoverable).
    le_general_discoverable: bool = false,
    /// BR/EDR Not Supported (pure Bluetooth Low Energy device, no Classic Bluetooth).
    br_edr_not_supported: bool = false,
    /// Simultaneous LE and BR/EDR to Same Device Capable (Controller).
    simultaneous_le_and_br_edr_controller: bool = false,
    /// Simultaneous LE and BR/EDR to Same Device Capable (Host).
    simultaneous_le_and_br_edr_host: bool = false,
    _reserved: u3 = 0,

    pub fn toByte(self: AdvertisingFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(b: u8) AdvertisingFlags {
        return @bitCast(b);
    }
};

/// Manufacturer Specific Data (AD Type 0xFF).
pub const ManufacturerData = struct {
    /// 16-bit Bluetooth SIG Company Identifier (little-endian in the payload).
    company_id: u16,
    /// Raw payload following the Company Identifier.
    payload: []const u8,

    pub fn getCompanyName(self: ManufacturerData) ?[]const u8 {
        return CompanyId.getName(self.company_id);
    }
};

/// Service Data with 16-bit UUID (AD Type 0x16).
/// Contains a 16-bit Service UUID followed by arbitrary service data payload.
pub const ServiceData16 = struct {
    uuid16: u16,
    data: []const u8,

    pub fn getUuid(self: ServiceData16) UUID {
        return UUID.from16(self.uuid16);
    }
};

/// Service Data with 32-bit UUID (AD Type 0x20).
pub const ServiceData32 = struct {
    uuid32: u32,
    data: []const u8,

    pub fn getUuid(self: ServiceData32) UUID {
        return UUID.from32(self.uuid32);
    }
};

/// Service Data with 128-bit UUID (AD Type 0x21).
/// Transmitted in little-endian over the air.
pub const ServiceData128 = struct {
    uuid: UUID,
    data: []const u8,
};

/// Zero-allocation iterator over a list of 16-bit Service UUIDs (AD Type 0x02 / 0x03).
pub const ServiceUuids16Iterator = struct {
    raw: []const u8,
    cursor: usize = 0,

    pub fn next(self: *ServiceUuids16Iterator) ?u16 {
        if (self.cursor + 2 > self.raw.len) return null;
        const val = std.mem.readInt(u16, self.raw[self.cursor..][0..2], .little);
        self.cursor += 2;
        return val;
    }
};

/// Zero-allocation iterator over a list of 32-bit Service UUIDs (AD Type 0x04 / 0x05).
pub const ServiceUuids32Iterator = struct {
    raw: []const u8,
    cursor: usize = 0,

    pub fn next(self: *ServiceUuids32Iterator) ?u32 {
        if (self.cursor + 4 > self.raw.len) return null;
        const val = std.mem.readInt(u32, self.raw[self.cursor..][0..4], .little);
        self.cursor += 4;
        return val;
    }
};

/// Zero-allocation iterator over a list of 128-bit Service UUIDs (AD Type 0x06 / 0x07).
pub const ServiceUuids128Iterator = struct {
    raw: []const u8,
    cursor: usize = 0,

    pub fn next(self: *ServiceUuids128Iterator) ?UUID {
        if (self.cursor + 16 > self.raw.len) return null;
        const le_bytes: *const [16]u8 = self.raw[self.cursor..][0..16];
        self.cursor += 16;
        return UUID.fromLittleEndian(le_bytes.*);
    }
};

/// Represents a single AD structure within an advertising or scan response packet.
pub const AdStructure = struct {
    ad_type: AdType,
    data: []const u8,

    /// Extracts flags if the type is `0x01`.
    pub fn asFlags(self: AdStructure) ?AdvertisingFlags {
        if (self.ad_type != .flags or self.data.len < 1) return null;
        return AdvertisingFlags.fromByte(self.data[0]);
    }

    /// Extracts the local device name (complete or shortened).
    pub fn asLocalName(self: AdStructure) ?[]const u8 {
        if (self.ad_type == .complete_local_name or self.ad_type == .shortened_local_name) {
            return self.data;
        }
        return null;
    }

    /// Extracts the local device name if it is a valid UTF-8 sequence.
    pub fn asValidLocalName(self: AdStructure) ?[]const u8 {
        const name = self.asLocalName() orelse return null;
        if (std.unicode.utf8ValidateSlice(name)) {
            return name;
        }
        return null;
    }

    /// Extracts the transmit power level in dBm (AD Type 0x0A).
    pub fn asTxPower(self: AdStructure) ?i8 {
        if (self.ad_type != .tx_power_level or self.data.len < 1) return null;
        return @as(i8, @bitCast(self.data[0]));
    }

    /// Extracts the appearance code (AD Type 0x19, 2 bytes little-endian).
    pub fn asAppearance(self: AdStructure) ?u16 {
        if (self.ad_type != .appearance or self.data.len < 2) return null;
        return std.mem.readInt(u16, self.data[0..2], .little);
    }

    /// Extracts manufacturer specific data (AD Type 0xFF).
    pub fn asManufacturerData(self: AdStructure) ?ManufacturerData {
        if (self.ad_type != .manufacturer_specific_data or self.data.len < 2) return null;
        const company_id = std.mem.readInt(u16, self.data[0..2], .little);
        return ManufacturerData{
            .company_id = company_id,
            .payload = self.data[2..],
        };
    }

    /// Extracts Service Data with 16-bit UUID (AD Type 0x16).
    pub fn asServiceData16(self: AdStructure) ?ServiceData16 {
        if (self.ad_type != .service_data_16bit or self.data.len < 2) return null;
        return ServiceData16{
            .uuid16 = std.mem.readInt(u16, self.data[0..2], .little),
            .data = self.data[2..],
        };
    }

    /// Extracts Service Data with 32-bit UUID (AD Type 0x20).
    pub fn asServiceData32(self: AdStructure) ?ServiceData32 {
        if (self.ad_type != .service_data_32bit or self.data.len < 4) return null;
        return ServiceData32{
            .uuid32 = std.mem.readInt(u32, self.data[0..4], .little),
            .data = self.data[4..],
        };
    }

    /// Extracts Service Data with 128-bit UUID (AD Type 0x21).
    pub fn asServiceData128(self: AdStructure) ?ServiceData128 {
        if (self.ad_type != .service_data_128bit or self.data.len < 16) return null;
        const le_bytes: *const [16]u8 = self.data[0..16];
        return ServiceData128{
            .uuid = UUID.fromLittleEndian(le_bytes.*),
            .data = self.data[16..],
        };
    }

    /// Returns an iterator over 16-bit Service UUIDs (AD Type 0x02 or 0x03).
    pub fn asServiceUuids16(self: AdStructure) ?ServiceUuids16Iterator {
        if (self.ad_type != .incomplete_16bit_service_uuids and self.ad_type != .complete_16bit_service_uuids) {
            return null;
        }
        return ServiceUuids16Iterator{ .raw = self.data };
    }

    /// Returns an iterator over 32-bit Service UUIDs (AD Type 0x04 or 0x05).
    pub fn asServiceUuids32(self: AdStructure) ?ServiceUuids32Iterator {
        if (self.ad_type != .incomplete_32bit_service_uuids and self.ad_type != .complete_32bit_service_uuids) {
            return null;
        }
        return ServiceUuids32Iterator{ .raw = self.data };
    }

    /// Returns an iterator over 128-bit Service UUIDs (AD Type 0x06 or 0x07).
    pub fn asServiceUuids128(self: AdStructure) ?ServiceUuids128Iterator {
        if (self.ad_type != .incomplete_128bit_service_uuids and self.ad_type != .complete_128bit_service_uuids) {
            return null;
        }
        return ServiceUuids128Iterator{ .raw = self.data };
    }
};

/// Zero-allocation iterator over a raw advertising packet (length + type + data).
/// Prevents heap allocations during high-frequency packet processing.
pub const AdIterator = struct {
    raw_data: []const u8,
    cursor: usize = 0,

    pub fn init(raw_data: []const u8) AdIterator {
        return AdIterator{ .raw_data = raw_data };
    }

    pub inline fn next(self: *AdIterator) ?AdStructure {
        if (self.cursor >= self.raw_data.len) return null;
        const remaining = self.raw_data[self.cursor..];
        const elem_len: usize = remaining[0];
        // A valid AD structure must contain at least 1 byte (the AD Type) (Core Spec v5.4, Vol 3, Part C, 11).
        // elem_len < 1 (0x00) signals the end of valid data or zero-padding at the packet tail.
        // remaining.len <= elem_len guarantees at least 1 byte for length header + elem_len bytes payload.
        if (elem_len < 1 or remaining.len <= elem_len) return null;

        const type_byte = remaining[1];
        const total_elem_bytes = 1 + elem_len;
        const data_slice = remaining[2..total_elem_bytes];
        self.cursor += total_elem_bytes;

        return AdStructure{
            .ad_type = @enumFromInt(type_byte),
            .data = data_slice,
        };
    }
};

/// Fast, zero-allocation summary view of key fields in an advertising packet.
pub const AdvertisingReport = struct {
    local_name: ?[]const u8 = null,
    flags: ?AdvertisingFlags = null,
    tx_power: ?i8 = null,
    appearance: ?u16 = null,
    raw_manufacturer_data: ?[]const u8 = null,
    raw_service_data16: ?[]const u8 = null,
    raw_service_data32: ?[]const u8 = null,
    raw_service_data128: ?[]const u8 = null,
    secondary_phy: ?PhyType = null,
    periodic_interval_ms: ?u32 = null,
    is_extended: bool = false,

    /// Returns the local device name if it is a valid UTF-8 sequence.
    pub fn getValidLocalName(self: AdvertisingReport) ?[]const u8 {
        const name = self.local_name orelse return null;
        if (std.unicode.utf8ValidateSlice(name)) {
            return name;
        }
        return null;
    }

    /// On-demand zero-copy view of Manufacturer Data (AD Type 0xFF).
    pub inline fn getManufacturerData(self: AdvertisingReport) ?ManufacturerData {
        const raw = self.raw_manufacturer_data orelse return null;
        if (raw.len < 2) return null;
        return ManufacturerData{
            .company_id = std.mem.readInt(u16, raw[0..2], .little),
            .payload = raw[2..],
        };
    }

    /// On-demand zero-copy view of Service Data with 16-bit UUID (AD Type 0x16).
    pub inline fn getServiceData16(self: AdvertisingReport) ?ServiceData16 {
        const raw = self.raw_service_data16 orelse return null;
        if (raw.len < 2) return null;
        return ServiceData16{
            .uuid16 = std.mem.readInt(u16, raw[0..2], .little),
            .data = raw[2..],
        };
    }

    /// On-demand zero-copy view of Service Data with 32-bit UUID (AD Type 0x20).
    pub inline fn getServiceData32(self: AdvertisingReport) ?ServiceData32 {
        const raw = self.raw_service_data32 orelse return null;
        if (raw.len < 4) return null;
        return ServiceData32{
            .uuid32 = std.mem.readInt(u32, raw[0..4], .little),
            .data = raw[4..],
        };
    }

    /// On-demand zero-copy view of Service Data with 128-bit UUID (AD Type 0x21).
    pub inline fn getServiceData128(self: AdvertisingReport) ?ServiceData128 {
        const raw = self.raw_service_data128 orelse return null;
        if (raw.len < 16) return null;
        const le_bytes: *const [16]u8 = raw[0..16];
        return ServiceData128{
            .uuid = UUID.fromLittleEndian(le_bytes.*),
            .data = raw[16..],
        };
    }

    /// Parses an advertising packet in a single zero-allocation pass.
    pub fn parse(raw_data: []const u8) AdvertisingReport {
        var report = AdvertisingReport{};
        var it = AdIterator.init(raw_data);

        while (it.next()) |ad| {
            switch (ad.ad_type) {
                .flags => {
                    if (ad.data.len >= 1) {
                        report.flags = @as(AdvertisingFlags, @bitCast(ad.data[0]));
                    }
                },
                .complete_local_name => {
                    report.local_name = ad.data;
                },
                .shortened_local_name => {
                    if (report.local_name == null) {
                        report.local_name = ad.data;
                    }
                },
                .tx_power_level => {
                    if (ad.data.len >= 1) {
                        report.tx_power = @as(i8, @bitCast(ad.data[0]));
                    }
                },
                .appearance => {
                    if (ad.data.len >= 2) {
                        report.appearance = std.mem.readInt(u16, ad.data[0..2], .little);
                    }
                },
                .manufacturer_specific_data => {
                    report.raw_manufacturer_data = ad.data;
                },
                .service_data_16bit => {
                    report.raw_service_data16 = ad.data;
                },
                .service_data_32bit => {
                    report.raw_service_data32 = ad.data;
                },
                .service_data_128bit => {
                    report.raw_service_data128 = ad.data;
                },
                .advertising_interval, .periodic_advertising_interval => {
                    if (ad.data.len >= 2) {
                        const units = std.mem.readInt(u16, ad.data[0..2], .little);
                        report.periodic_interval_ms = @as(u32, units) * 5 / 4;
                    }
                },
                else => {},
            }
        }

        return report;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "AdIterator: parse standard advertising packet" {
    // Packet layout:
    // 1. Flags (3 Bytes): Len=0x02, Type=0x01, Value=0x06 (General Discoverable | BR/EDR Not Supported)
    // 2. Complete Local Name (9 Bytes): Len=0x08, Type=0x09, "Zig-BLE"
    // 3. Tx Power (3 Bytes): Len=0x02, Type=0x0A, 0x04 (+4 dBm)
    const packet = [_]u8{
        0x02, 0x01, 0x06,
        0x08, 0x09, 'Z',
        'i',  'g',  '-',
        'B',  'L',  'E',
        0x02, 0x0A, 0x04,
    };

    var it = AdIterator.init(&packet);

    const ad1 = it.next().?;
    try std.testing.expectEqual(AdType.flags, ad1.ad_type);
    const flags = ad1.asFlags().?;
    try std.testing.expect(flags.le_general_discoverable);
    try std.testing.expect(flags.br_edr_not_supported);
    try std.testing.expect(!flags.le_limited_discoverable);

    const ad2 = it.next().?;
    try std.testing.expectEqual(AdType.complete_local_name, ad2.ad_type);
    try std.testing.expectEqualStrings("Zig-BLE", ad2.asLocalName().?);

    const ad3 = it.next().?;
    try std.testing.expectEqual(AdType.tx_power_level, ad3.ad_type);
    try std.testing.expectEqual(@as(i8, 4), ad3.asTxPower().?);

    try std.testing.expect(it.next() == null);
}

test "AdIterator: parse manufacturer specific data" {
    // Manufacturer Data for Nordic Semiconductor (Company ID: 0x0059, Little-Endian: 59 00)
    const packet = [_]u8{
        0x06, 0xFF, 0x59, 0x00, 0xAA, 0xBB, 0xCC,
    };

    var it = AdIterator.init(&packet);
    const ad = it.next().?;
    try std.testing.expectEqual(AdType.manufacturer_specific_data, ad.ad_type);

    const mfg = ad.asManufacturerData().?;
    try std.testing.expectEqual(@as(u16, 0x0059), mfg.company_id);
    try std.testing.expectEqualStrings("Nordic Semiconductor ASA", mfg.getCompanyName().?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, mfg.payload);
}

test "AdvertisingReport: zero-allocation full parse" {
    const packet = [_]u8{
        0x02, 0x01, 0x06,
        0x06, 0x09, 'H',
        'e',  'a',  'r',
        't',
        0x03, 0x19, 0x40, 0x03, // Appearance: 0x0340 = 832 (Heart Rate Sensor, Little-Endian: 40 03)
        0x00, 0x00, // Padding
    };

    const report = AdvertisingReport.parse(&packet);
    try std.testing.expectEqualStrings("Heart", report.local_name.?);
    try std.testing.expect(report.flags.?.br_edr_not_supported);
    try std.testing.expectEqual(@as(u16, 832), report.appearance.?);
}

test "AdIterator: handle 1-byte structure (type only, 0-byte payload) and zero-padding without panic" {
    // A packet with a 1-byte element (length = 1, AdType = 0x0A Tx Power, 0 bytes payload)
    // followed by zero-padding (0x00)
    const packet = [_]u8{
        0x01, 0x0A, // length = 1, type = 0x0A (Tx Power), data = []
        0x00, 0x00, // zero-padding
    };

    var it = AdIterator.init(&packet);
    const ad1 = it.next().?;
    try std.testing.expectEqual(AdType.tx_power_level, ad1.ad_type);
    try std.testing.expectEqual(@as(usize, 0), ad1.data.len);

    // Next element encounters 0x00 -> returns null cleanly, no panic!
    try std.testing.expect(it.next() == null);
}

test "AdIterator: Service Data 16, 32, and 128 bit" {
    // 1. Service Data 16-Bit: UUID 0x180D (Heart Rate, Little-Endian: 0x0D, 0x18), Data: [0x50, 0x60]
    // 2. Service Data 32-Bit: UUID 0x12345678 (Little-Endian: 0x78, 0x56, 0x34, 0x12), Data: [0xAA]
    // 3. Service Data 128-Bit: UUID 16 bytes little-endian, Data: [0x01, 0x02]
    const packet = [_]u8{
        // Service Data 16-bit: Len = 5, Typ = 0x16, UUID = 0x0D, 0x18, Data = 0x50, 0x60
        0x05, 0x16, 0x0D, 0x18, 0x50, 0x60,
        // Service Data 32-bit: Len = 6, Typ = 0x20, UUID = 78 56 34 12, Data = AA
        0x06, 0x20, 0x78, 0x56, 0x34, 0x12,
        0xAA,
        // Service Data 128-bit: Len = 19, Typ = 0x21, UUID = 16 bytes, Data = 01 02
        0x13, 0x21,
        // 16 bytes UUID in little-endian (e.g. 0000180d-0000-1000-8000-00805f9b34fb in LE)
        0xFB, 0x34, 0x9B,
        0x5F, 0x80, 0x00, 0x00, 0x80, 0x00,
        0x10, 0x00, 0x00, 0x0D, 0x18, 0x00,
        0x00, 0x01, 0x02,
    };

    var it = AdIterator.init(&packet);

    // 1. Service Data 16
    const ad1 = it.next().?;
    try std.testing.expectEqual(AdType.service_data_16bit, ad1.ad_type);
    const sd16 = ad1.asServiceData16().?;
    try std.testing.expectEqual(@as(u16, 0x180D), sd16.uuid16);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x50, 0x60 }, sd16.data);
    try std.testing.expect(sd16.getUuid().is16Bit());
    try std.testing.expectEqual(@as(?u16, 0x180D), sd16.getUuid().to16());

    // 2. Service Data 32
    const ad2 = it.next().?;
    try std.testing.expectEqual(AdType.service_data_32bit, ad2.ad_type);
    const sd32 = ad2.asServiceData32().?;
    try std.testing.expectEqual(@as(u32, 0x12345678), sd32.uuid32);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAA}, sd32.data);
    try std.testing.expectEqual(@as(?u32, 0x12345678), sd32.getUuid().to32());

    // 3. Service Data 128
    const ad3 = it.next().?;
    try std.testing.expectEqual(AdType.service_data_128bit, ad3.ad_type);
    const sd128 = ad3.asServiceData128().?;
    try std.testing.expect(sd128.uuid.is16Bit());
    try std.testing.expectEqual(@as(?u16, 0x180D), sd128.uuid.to16());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, sd128.data);

    try std.testing.expect(it.next() == null);
}

test "AdIterator: Service UUID list iterators (16-bit, 32-bit, 128-bit)" {
    // Packet with:
    // - Complete 16-bit Service UUIDs (0x180D, 0x180A)
    // - Complete 32-bit Service UUIDs (0x12345678)
    // - Incomplete 128-bit Service UUIDs (1x 128-bit UUID)
    const packet = [_]u8{
        // 16-bit list: Len = 5, Typ = 0x03, UUIDs: 0x180D (0D 18), 0x180A (0A 18)
        0x05, 0x03, 0x0D, 0x18, 0x0A, 0x18,
        // 32-bit list: Len = 5, Typ = 0x05, UUID: 0x12345678 (78 56 34 12)
        0x05, 0x05, 0x78, 0x56, 0x34, 0x12,
        // 128-bit list: Len = 17, Typ = 0x06, 16-byte UUID in LE
        0x11, 0x06, 0xFB, 0x34, 0x9B, 0x5F,
        0x80, 0x00, 0x00, 0x80, 0x00, 0x10,
        0x00, 0x00, 0x0D, 0x18, 0x00, 0x00,
    };

    var it = AdIterator.init(&packet);

    // 16-bit list
    const ad1 = it.next().?;
    var u16_it = ad1.asServiceUuids16().?;
    try std.testing.expectEqual(@as(?u16, 0x180D), u16_it.next());
    try std.testing.expectEqual(@as(?u16, 0x180A), u16_it.next());
    try std.testing.expectEqual(@as(?u16, null), u16_it.next());

    // 32-bit list
    const ad2 = it.next().?;
    var u32_it = ad2.asServiceUuids32().?;
    try std.testing.expectEqual(@as(?u32, 0x12345678), u32_it.next());
    try std.testing.expectEqual(@as(?u32, null), u32_it.next());

    // 128-bit list
    const ad3 = it.next().?;
    var u128_it = ad3.asServiceUuids128().?;
    const parsed_u128 = u128_it.next().?;
    try std.testing.expect(parsed_u128.is16Bit());
    try std.testing.expectEqual(@as(?u16, 0x180D), parsed_u128.to16());
    try std.testing.expectEqual(@as(?UUID, null), u128_it.next());

    try std.testing.expect(it.next() == null);
}

test "AdvertisingFlags bitpack round-trip" {
    var flags = AdvertisingFlags{
        .le_general_discoverable = true,
        .br_edr_not_supported = true,
    };
    const b = flags.toByte();
    try std.testing.expectEqual(@as(u8, 0x06), b);

    const from_b = AdvertisingFlags.fromByte(b);
    try std.testing.expect(from_b.le_general_discoverable);
    try std.testing.expect(from_b.br_edr_not_supported);
    try std.testing.expect(!from_b.le_limited_discoverable);
}

test "AdIterator & AdvertisingReport: PRNG continuous fuzzing (25,000 iterations)" {
    var prng = std.Random.DefaultPrng.init(0x1337BEEF);
    const rand = prng.random();

    var buffer: [1650]u8 = undefined;

    const base_seeds = [_][]const u8{
        "",
        "\x00",
        "\x01",
        "\x01\x01",
        "\xFF\x01",
        "\x02\x01\x06\x09\x09Zig-BLE\x03\x19\x40\x03",
        "\x05\x16\x0D\x18\x50\x60\x06\x20\x78\x56\x34\x12\xAA",
        "\x05\x09\xC0\x80\xF5\x80", // Invalid UTF-8
        "\x10\x21\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F", // Truncated 128-bit UUID
        "\x02\xFF\x59", // Truncated company ID
    };

    const iterations: usize = 25_000;

    for (0..iterations) |i| {
        var len: usize = 0;

        if (i % 8 == 0) {
            // Generate Extended Advertising PDU (up to 1650 bytes)
            const target_len = rand.intRangeAtMost(usize, 1, 1650);
            var cursor: usize = 0;
            while (cursor + 2 < target_len) {
                const rem = target_len - cursor;
                const elem_len = rand.intRangeAtMost(usize, 1, @min(rem - 1, 255));
                buffer[cursor] = @truncate(elem_len);
                buffer[cursor + 1] = rand.int(u8);
                for (cursor + 2..cursor + 1 + elem_len) |idx| {
                    if (idx < target_len) buffer[idx] = rand.int(u8);
                }
                cursor += 1 + elem_len;
            }
            len = target_len;
        } else {
            const seed = base_seeds[i % base_seeds.len];
            @memcpy(buffer[0..seed.len], seed);
            len = seed.len;

            // Apply 1-3 mutations
            const mutations = rand.intRangeAtMost(usize, 1, 3);
            for (0..mutations) |_| {
                const choice = rand.intRangeAtMost(u8, 0, 5);
                switch (choice) {
                    0 => if (len > 0) {
                        buffer[rand.intRangeLessThan(usize, 0, len)] ^= (@as(u8, 1) << rand.intRangeAtMost(u3, 0, 7));
                    },
                    1 => if (len > 0) {
                        buffer[rand.intRangeLessThan(usize, 0, len)] = rand.int(u8);
                    },
                    2 => if (len > 0) {
                        // Length anomaly
                        buffer[0] = switch (rand.intRangeLessThan(u8, 0, 4)) {
                            0 => 0,
                            1 => 1,
                            2 => 255,
                            else => @truncate(len),
                        };
                    },
                    3 => if (len < buffer.len) {
                        buffer[len] = rand.int(u8);
                        len += 1;
                    },
                    4 => if (len > 0) {
                        len -= 1;
                    },
                    else => {},
                }
            }
        }

        const slice = buffer[0..len];

        // 1. TLV Walk via AdIterator
        var it = AdIterator.init(slice);
        var elem_count: usize = 0;
        while (it.next()) |elem| {
            elem_count += 1;
            if (elem_count > slice.len + 2) {
                @panic("AdIterator non-termination!");
            }
            _ = elem.asFlags();
            _ = elem.asLocalName();
            _ = elem.asValidLocalName();
            _ = elem.asTxPower();
            _ = elem.asAppearance();
            if (elem.asManufacturerData()) |mfg| {
                _ = mfg.getCompanyName();
            }
            if (elem.asServiceData16()) |sd| {
                _ = sd.getUuid();
            }
            if (elem.asServiceData32()) |sd| {
                _ = sd.getUuid();
            }
            _ = elem.asServiceData128();
            if (elem.asServiceUuids16()) |val| {
                var u16_it = val;
                var c: usize = 0;
                while (u16_it.next()) |_| {
                    c += 1;
                    if (c > elem.data.len) @panic("ServiceUuids16 infinite loop!");
                }
            }
            if (elem.asServiceUuids32()) |val| {
                var u32_it = val;
                var c: usize = 0;
                while (u32_it.next()) |_| {
                    c += 1;
                    if (c > elem.data.len) @panic("ServiceUuids32 infinite loop!");
                }
            }
            if (elem.asServiceUuids128()) |val| {
                var u128_it = val;
                var c: usize = 0;
                while (u128_it.next()) |_| {
                    c += 1;
                    if (c > elem.data.len) @panic("ServiceUuids128 infinite loop!");
                }
            }
        }

        // 2. One-Pass Parser via AdvertisingReport.parse
        const report = AdvertisingReport.parse(slice);
        if (report.local_name) |name| {
            _ = report.getValidLocalName();
            _ = std.unicode.utf8ValidateSlice(name);
        }
        if (report.getManufacturerData()) |mfg| {
            _ = mfg.getCompanyName();
        }
        if (report.getServiceData16()) |sd| {
            _ = sd.getUuid();
        }
        if (report.getServiceData32()) |sd| {
            _ = sd.getUuid();
        }
        if (report.getServiceData128()) |sd| {
            _ = sd.uuid;
        }
    }
}

test "Bluetooth 5.0+ Extended Advertising types and interval parsing" {
    try std.testing.expectEqualStrings("1M", PhyType.le_1m.toString());
    try std.testing.expectEqualStrings("2M", PhyType.le_2m.toString());
    try std.testing.expectEqualStrings("Coded", PhyType.le_coded.toString());

    try std.testing.expect(SecondaryChannel.none.toBluezString() == null);
    try std.testing.expectEqualStrings("Coded", SecondaryChannel.coded.toBluezString().?);

    // Packet with Advertising Interval (AD Type 0x1A: 2 bytes units of 1.25ms)
    // 0x00A0 = 160 units * 1.25ms = 200 ms
    const adv_int_pkt = [_]u8{
        0x03, 0x1A, 0xA0, 0x00,
    };
    const rep = AdvertisingReport.parse(&adv_int_pkt);
    try std.testing.expectEqual(@as(?u32, 200), rep.periodic_interval_ms);
}
