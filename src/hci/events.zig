//! Zero-allocation HCI Event parser.
//! Slices directly into network/packet buffers with zero heap allocations.
//! Conforms to Bluetooth Core Specification v5.4, Vol 4, Part E (HCI).

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("../core/types.zig");
const Address = types.Address;
const AddressType = types.AddressType;

pub const EventParseError = error{
    BufferTooShort,
    InvalidPacketType,
    InvalidLength,
    InvalidReportStructure,
};

/// An individual advertising report decoded from an LE Meta Advertising Report event.
pub const HciAdvertisingReport = struct {
    event_type: u8,
    address_type: AddressType,
    address: Address,
    data: []const u8,
    rssi: i8,

    pub fn isConnectable(self: *const HciAdvertisingReport) bool {
        return self.event_type == 0x00 or self.event_type == 0x01;
    }

    pub fn isScanResponse(self: *const HciAdvertisingReport) bool {
        return self.event_type == 0x04;
    }
};

/// Zero-allocation iterator for walking multiple advertising reports inside a single LE Advertising Report event.
pub const AdvertisingReportIterator = struct {
    payload: []const u8,
    num_reports: u8,
    current_index: u8 = 0,
    offset: usize = 0,

    pub fn init(payload: []const u8) EventParseError!AdvertisingReportIterator {
        if (payload.len < 1) return EventParseError.BufferTooShort;
        const num = payload[0];
        return .{
            .payload = payload[1..],
            .num_reports = num,
            .current_index = 0,
            .offset = 0,
        };
    }

    pub fn next(self: *AdvertisingReportIterator) ?HciAdvertisingReport {
        if (self.current_index >= self.num_reports) return null;

        const n: usize = self.num_reports;
        if (self.payload.len < n * 9) return null;

        var total_data_len: usize = 0;
        var cur_data_start: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const dlen = self.payload[8 * n + i];
            if (i < self.current_index) {
                cur_data_start += dlen;
            }
            total_data_len += dlen;
        }

        const total_expected_len = n * 9 + total_data_len + n;
        if (self.payload.len < total_expected_len) return null;

        const idx = self.current_index;
        const ev_type = self.payload[idx];
        const addr_type: AddressType = if (self.payload[n + idx] == 0) .public else .random;

        const addr_offset = 2 * n + idx * 6;
        const p = self.payload[addr_offset .. addr_offset + 6];
        const mac = Address{
            .bytes = [6]u8{ p[5], p[4], p[3], p[2], p[1], p[0] },
        };

        const data_len = self.payload[8 * n + idx];
        const data_start = 9 * n + cur_data_start;
        const data = self.payload[data_start .. data_start + data_len];

        const rssi_offset = 9 * n + total_data_len + idx;
        const rssi: i8 = @bitCast(self.payload[rssi_offset]);

        self.current_index += 1;
        return .{
            .event_type = ev_type,
            .address_type = addr_type,
            .address = mac,
            .data = data,
            .rssi = rssi,
        };
    }
};

/// An individual advertising report decoded from an LE Extended Advertising Report event (Bluetooth 5.0+).
pub const HciExtAdvertisingReport = struct {
    event_type: u16,
    address_type: AddressType,
    address: Address,
    primary_phy: u8,
    secondary_phy: u8,
    advertising_sid: u8,
    tx_power: i8,
    rssi: i8,
    periodic_advertising_interval: u16,
    direct_address_type: AddressType,
    direct_address: Address,
    data: []const u8,

    pub fn isConnectable(self: *const HciExtAdvertisingReport) bool {
        return (self.event_type & 0x0001) != 0;
    }

    pub fn isScannable(self: *const HciExtAdvertisingReport) bool {
        return (self.event_type & 0x0002) != 0;
    }

    pub fn isDirected(self: *const HciExtAdvertisingReport) bool {
        return (self.event_type & 0x0004) != 0;
    }

    pub fn isScanResponse(self: *const HciExtAdvertisingReport) bool {
        return (self.event_type & 0x0008) != 0;
    }

    pub fn isLegacy(self: *const HciExtAdvertisingReport) bool {
        return (self.event_type & 0x0010) != 0;
    }
};

/// Zero-allocation iterator for walking multiple reports in an LE Extended Advertising Report event.
pub const ExtAdvertisingReportIterator = struct {
    payload: []const u8,
    num_reports: u8,
    current_index: u8 = 0,
    offset: usize = 0,

    pub fn init(payload: []const u8) EventParseError!ExtAdvertisingReportIterator {
        if (payload.len < 1) return EventParseError.BufferTooShort;
        return .{
            .payload = payload[1..],
            .num_reports = payload[0],
            .current_index = 0,
            .offset = 0,
        };
    }

    pub fn next(self: *ExtAdvertisingReportIterator) ?HciExtAdvertisingReport {
        if (self.current_index >= self.num_reports) return null;
        if (self.offset + 24 > self.payload.len) return null;

        const p = self.payload[self.offset..];
        const event_type = std.mem.readInt(u16, p[0..2], .little);
        const addr_type: AddressType = if (p[2] == 0) .public else .random;
        const mac = Address{
            .bytes = [6]u8{ p[8], p[7], p[6], p[5], p[4], p[3] },
        };
        const prim_phy = p[9];
        const sec_phy = p[10];
        const sid = p[11];
        const tx_power: i8 = @bitCast(p[12]);
        const rssi: i8 = @bitCast(p[13]);
        const periodic_interval = std.mem.readInt(u16, p[14..16], .little);
        const dir_addr_type: AddressType = if (p[16] == 0) .public else .random;
        const dir_mac = Address{
            .bytes = [6]u8{ p[22], p[21], p[20], p[19], p[18], p[17] },
        };
        const data_len = p[23];
        if (p.len < 24 + data_len) return null;
        const data = p[24 .. 24 + data_len];

        self.offset += 24 + data_len;
        self.current_index += 1;

        return .{
            .event_type = event_type,
            .address_type = addr_type,
            .address = mac,
            .primary_phy = prim_phy,
            .secondary_phy = sec_phy,
            .advertising_sid = sid,
            .tx_power = tx_power,
            .rssi = rssi,
            .periodic_advertising_interval = periodic_interval,
            .direct_address_type = dir_addr_type,
            .direct_address = dir_mac,
            .data = data,
        };
    }
};

/// High-level parsed HCI event packet.
pub const HciEvent = union(enum) {
    command_complete: struct {
        num_cmd_packets: u8,
        opcode: u16,
        status: constants.Status,
        return_params: []const u8,
    },
    command_status: struct {
        status: constants.Status,
        num_cmd_packets: u8,
        opcode: u16,
    },
    disconnection_complete: struct {
        status: constants.Status,
        handle: u16,
        reason: u8,
    },
    le_advertising_report: AdvertisingReportIterator,
    le_extended_advertising_report: ExtAdvertisingReportIterator,
    le_connection_complete: struct {
        status: constants.Status,
        handle: u16,
        role: u8,
        peer_address_type: AddressType,
        peer_address: Address,
        conn_interval: u16,
        conn_latency: u16,
        supervision_timeout: u16,
        master_clock_accuracy: u8,
    },
    le_connection_update_complete: struct {
        status: constants.Status,
        handle: u16,
        conn_interval: u16,
        conn_latency: u16,
        supervision_timeout: u16,
    },
    le_data_length_change: struct {
        handle: u16,
        max_tx_octets: u16,
        max_tx_time: u16,
        max_rx_octets: u16,
        max_rx_time: u16,
    },
    le_phy_update_complete: struct {
        status: constants.Status,
        handle: u16,
        tx_phy: u8,
        rx_phy: u8,
    },
    le_read_local_p256_public_key_complete: struct {
        status: constants.Status,
        key_x: [32]u8,
        key_y: [32]u8,
    },
    le_generate_dhkey_complete: struct {
        status: constants.Status,
        dhkey: [32]u8,
    },
    le_meta_other: struct {
        subevent: u8,
        data: []const u8,
    },
    other: struct {
        event_code: u8,
        data: []const u8,
    },

    /// Parses an incoming raw HCI buffer from the socket (including or excluding the 0x04 packet indicator).
    pub fn parse(raw: []const u8) EventParseError!HciEvent {
        var buf = raw;
        if (buf.len == 0) return EventParseError.BufferTooShort;

        // Skip packet indicator if present
        if (buf[0] == @intFromEnum(constants.PacketType.event)) {
            buf = buf[1..];
        }

        if (buf.len < 2) return EventParseError.BufferTooShort;
        const evt_code = buf[0];
        const param_len = buf[1];
        if (buf.len < 2 + param_len) return EventParseError.BufferTooShort;
        const params = buf[2 .. 2 + param_len];

        switch (evt_code) {
            constants.EventCode.command_complete => {
                if (params.len < 3) return EventParseError.BufferTooShort;
                const num_pkts = params[0];
                const opcode = std.mem.readInt(u16, params[1..3], .little);
                const status: constants.Status = if (params.len >= 4)
                    @enumFromInt(params[3])
                else
                    .success;
                const ret_params = if (params.len > 4) params[4..] else &[_]u8{};
                return .{
                    .command_complete = .{
                        .num_cmd_packets = num_pkts,
                        .opcode = opcode,
                        .status = status,
                        .return_params = ret_params,
                    },
                };
            },
            constants.EventCode.command_status => {
                if (params.len < 4) return EventParseError.BufferTooShort;
                const status: constants.Status = @enumFromInt(params[0]);
                const num_pkts = params[1];
                const opcode = std.mem.readInt(u16, params[2..4], .little);
                return .{
                    .command_status = .{
                        .status = status,
                        .num_cmd_packets = num_pkts,
                        .opcode = opcode,
                    },
                };
            },
            constants.EventCode.disconnection_complete => {
                if (params.len < 4) return EventParseError.BufferTooShort;
                const status: constants.Status = @enumFromInt(params[0]);
                const handle = std.mem.readInt(u16, params[1..3], .little);
                const reason = params[3];
                return .{
                    .disconnection_complete = .{
                        .status = status,
                        .handle = handle,
                        .reason = reason,
                    },
                };
            },
            constants.EventCode.le_meta_event => {
                if (params.len < 1) return EventParseError.BufferTooShort;
                const subevent = params[0];
                const sub_params = params[1..];
                switch (subevent) {
                    constants.LeSubevent.advertising_report => {
                        const it = try AdvertisingReportIterator.init(sub_params);
                        return .{ .le_advertising_report = it };
                    },
                    constants.LeSubevent.extended_advertising_report => {
                        const it = try ExtAdvertisingReportIterator.init(sub_params);
                        return .{ .le_extended_advertising_report = it };
                    },
                    constants.LeSubevent.connection_complete => {
                        if (sub_params.len < 18) return EventParseError.BufferTooShort;
                        return .{
                            .le_connection_complete = .{
                                .status = @enumFromInt(sub_params[0]),
                                .handle = std.mem.readInt(u16, sub_params[1..3], .little),
                                .role = sub_params[3],
                                .peer_address_type = if (sub_params[4] == 0) .public else .random,
                                .peer_address = Address{
                                    .bytes = [6]u8{ sub_params[10], sub_params[9], sub_params[8], sub_params[7], sub_params[6], sub_params[5] },
                                },
                                .conn_interval = std.mem.readInt(u16, sub_params[11..13], .little),
                                .conn_latency = std.mem.readInt(u16, sub_params[13..15], .little),
                                .supervision_timeout = std.mem.readInt(u16, sub_params[15..17], .little),
                                .master_clock_accuracy = sub_params[17],
                            },
                        };
                    },
                    constants.LeSubevent.connection_update_complete => {
                        if (sub_params.len < 9) return EventParseError.BufferTooShort;
                        return .{
                            .le_connection_update_complete = .{
                                .status = @enumFromInt(sub_params[0]),
                                .handle = std.mem.readInt(u16, sub_params[1..3], .little),
                                .conn_interval = std.mem.readInt(u16, sub_params[3..5], .little),
                                .conn_latency = std.mem.readInt(u16, sub_params[5..7], .little),
                                .supervision_timeout = std.mem.readInt(u16, sub_params[7..9], .little),
                            },
                        };
                    },
                    constants.LeSubevent.data_length_change => {
                        if (sub_params.len < 10) return EventParseError.BufferTooShort;
                        return .{
                            .le_data_length_change = .{
                                .handle = std.mem.readInt(u16, sub_params[0..2], .little),
                                .max_tx_octets = std.mem.readInt(u16, sub_params[2..4], .little),
                                .max_tx_time = std.mem.readInt(u16, sub_params[4..6], .little),
                                .max_rx_octets = std.mem.readInt(u16, sub_params[6..8], .little),
                                .max_rx_time = std.mem.readInt(u16, sub_params[8..10], .little),
                            },
                        };
                    },
                    constants.LeSubevent.phy_update_complete => {
                        if (sub_params.len < 5) return EventParseError.BufferTooShort;
                        return .{
                            .le_phy_update_complete = .{
                                .status = @enumFromInt(sub_params[0]),
                                .handle = std.mem.readInt(u16, sub_params[1..3], .little),
                                .tx_phy = sub_params[3],
                                .rx_phy = sub_params[4],
                            },
                        };
                    },
                    constants.LeSubevent.read_local_p256_public_key_complete => {
                        if (sub_params.len < 65) return EventParseError.BufferTooShort;
                        return .{
                            .le_read_local_p256_public_key_complete = .{
                                .status = @enumFromInt(sub_params[0]),
                                .key_x = sub_params[1..33].*,
                                .key_y = sub_params[33..65].*,
                            },
                        };
                    },
                    constants.LeSubevent.generate_dhkey_complete => {
                        if (sub_params.len < 33) return EventParseError.BufferTooShort;
                        return .{
                            .le_generate_dhkey_complete = .{
                                .status = @enumFromInt(sub_params[0]),
                                .dhkey = sub_params[1..33].*,
                            },
                        };
                    },
                    else => {
                        return .{
                            .le_meta_other = .{
                                .subevent = subevent,
                                .data = sub_params,
                            },
                        };
                    },
                }
            },
            else => {
                return .{
                    .other = .{
                        .event_code = evt_code,
                        .data = params,
                    },
                };
            },
        }
    }
};

test "HciEvent: parse Command Complete" {
    // 0x04 [Type] 0x0E [Code] 0x04 [Len] 0x01 [NumPkts] 0x03 0x0C [Reset Opcode] 0x00 [Status: Success]
    const raw_pkt = [_]u8{ 0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 };
    const evt = try HciEvent.parse(&raw_pkt);
    switch (evt) {
        .command_complete => |cc| {
            try std.testing.expectEqual(@as(u8, 1), cc.num_cmd_packets);
            try std.testing.expectEqual(constants.Opcode.reset, cc.opcode);
            try std.testing.expectEqual(constants.Status.success, cc.status);
        },
        else => unreachable,
    }
}

test "HciEvent: parse LE Meta Advertising Report" {
    // Packet indicator: 0x04
    // Event: 0x3E (LE Meta)
    // Len: 24 (1B subevent + 1B num + 1B type + 1B addr_type + 6B addr + 1B data_len + 12B data + 1B rssi = 24)
    // Subevent: 0x02
    // Num: 0x01
    // Type: 0x00 (ADV_IND)
    // AddrType: 0x00 (Public)
    // Addr: 11:22:33:44:55:66 (LE in packet: 66 55 44 33 22 11)
    // DataLen: 4 (0x03, 0x09, 'H', 'I')
    // RSSI: -65 (0xBF = 191)
    const raw_adv = [_]u8{
        0x04, 0x3E, 15, 0x02, 0x01, 0x00, 0x00,
        0x66, 0x55, 0x44, 0x33, 0x22, 0x11, // MAC
        0x03, 0x02, 0x01, 0x06, // 3-byte payload: Flags (0x01 = 0x06)
        0xBF, // RSSI (-65 dBm)
    };

    const evt = try HciEvent.parse(&raw_adv);
    switch (evt) {
        .le_advertising_report => |mut_it| {
            var it = mut_it;
            const rep = it.next().?;
            try std.testing.expectEqual(@as(u8, 0x00), rep.event_type);
            try std.testing.expectEqual(AddressType.public, rep.address_type);
            const expected_mac = try Address.parse("11:22:33:44:55:66");
            try std.testing.expect(rep.address.eql(expected_mac));
            try std.testing.expectEqual(@as(usize, 3), rep.data.len);
            try std.testing.expectEqual(@as(i8, -65), rep.rssi);
            try std.testing.expect(it.next() == null);
        },
        else => unreachable,
    }
}

test "HciEvent: parse LE PHY Update Complete" {
    // 0x04 [Type] 0x3E [Code] 0x06 [Len] 0x0C [Subevent] 0x00 [Status] 0x40 0x00 [Handle] 0x02 [TX PHY: 2M] 0x02 [RX PHY: 2M]
    const raw = [_]u8{ 0x04, 0x3E, 0x06, 0x0C, 0x00, 0x40, 0x00, 0x02, 0x02 };
    const evt = try HciEvent.parse(&raw);
    switch (evt) {
        .le_phy_update_complete => |phy| {
            try std.testing.expectEqual(constants.Status.success, phy.status);
            try std.testing.expectEqual(@as(u16, 0x0040), phy.handle);
            try std.testing.expectEqual(@as(u8, 0x02), phy.tx_phy);
            try std.testing.expectEqual(@as(u8, 0x02), phy.rx_phy);
        },
        else => unreachable,
    }
}

test "HciEvent: parse LE Data Length Change" {
    // 0x04 0x3E 0x0B 0x07 [Handle: 0x0040] [TxOctets: 251] [TxTime: 2120] [RxOctets: 251] [RxTime: 2120]
    var raw: [14]u8 = undefined;
    raw[0] = 0x04;
    raw[1] = 0x3E;
    raw[2] = 11;
    raw[3] = 0x07; // subevent data length change
    std.mem.writeInt(u16, raw[4..6], 0x0040, .little);
    std.mem.writeInt(u16, raw[6..8], 251, .little);
    std.mem.writeInt(u16, raw[8..10], 2120, .little);
    std.mem.writeInt(u16, raw[10..12], 251, .little);
    std.mem.writeInt(u16, raw[12..14], 2120, .little);

    const evt = try HciEvent.parse(&raw);
    switch (evt) {
        .le_data_length_change => |dle| {
            try std.testing.expectEqual(@as(u16, 0x0040), dle.handle);
            try std.testing.expectEqual(@as(u16, 251), dle.max_tx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dle.max_tx_time);
            try std.testing.expectEqual(@as(u16, 251), dle.max_rx_octets);
            try std.testing.expectEqual(@as(u16, 2120), dle.max_rx_time);
        },
        else => unreachable,
    }
}

test "HciEvent: parse LE Extended Advertising Report" {
    // Subevent 0x0D: Extended Advertising Report
    var raw: [32]u8 = [_]u8{0} ** 32;
    raw[0] = 0x04; // PacketType.event
    raw[1] = 0x3E; // EventCode.le_meta_event
    raw[2] = 29; // Param length: 1 + 24 + 4 = 29
    raw[3] = 0x0D; // Subevent: extended_advertising_report
    raw[4] = 0x01; // Num reports: 1

    // Report #0 (starts at raw[5]):
    std.mem.writeInt(u16, raw[5..7], 0x0013, .little); // event_type (connectable + directed + legacy)
    raw[7] = 0x00; // addr_type (public)
    @memcpy(raw[8..14], &[_]u8{ 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }); // addr (LE)
    raw[14] = 0x03; // primary_phy (Coded)
    raw[15] = 0x03; // secondary_phy (Coded)
    raw[16] = 0x01; // sid
    raw[17] = @bitCast(@as(i8, -10)); // tx_power
    raw[18] = @bitCast(@as(i8, -75)); // rssi
    std.mem.writeInt(u16, raw[19..21], 0x0050, .little); // periodic interval
    raw[21] = 0x00; // direct addr type
    @memcpy(raw[22..28], &[_]u8{ 0, 0, 0, 0, 0, 0 }); // direct addr
    raw[28] = 0x03; // data_len = 3
    @memcpy(raw[29..32], &[_]u8{ 0x02, 0x01, 0x06 }); // data

    const evt = try HciEvent.parse(&raw);
    switch (evt) {
        .le_extended_advertising_report => |mut_it| {
            var it = mut_it;
            const rep = it.next().?;
            try std.testing.expect(rep.isConnectable());
            try std.testing.expect(rep.isLegacy());
            try std.testing.expectEqual(@as(u8, 3), rep.primary_phy);
            try std.testing.expectEqual(@as(i8, -75), rep.rssi);
            try std.testing.expectEqual(@as(usize, 3), rep.data.len);
            try std.testing.expect(rep.address.eql(try Address.parse("11:22:33:44:55:66")));
            try std.testing.expect(it.next() == null);
        },
        else => unreachable,
    }
}
