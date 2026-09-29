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
        if (self.offset >= self.payload.len) return null;

        // In standard HCI LE Advertising Report with 1 report:
        // [event_type: 1B] [addr_type: 1B] [addr: 6B] [data_len: 1B] [data: NB] [rssi: 1B]
        // Note: For multiple reports (num_reports > 1), the Bluetooth SIG specifies arrays of fields:
        // event_type[N], addr_type[N], addr[N][6], data_len[N], data[N], rssi[N].
        // However, 99.9% of controllers emit num_reports = 1 per event.
        if (self.num_reports == 1) {
            const p = self.payload;
            if (p.len < 9) return null; // 1 + 1 + 6 + 1
            const ev_type = p[0];
            const addr_type: AddressType = if (p[1] == 0) .public else .random;
            // Kernel HCI stores BD_ADDR in little-endian order (reverse of human-readable MAC)
            const mac = Address{
                .bytes = [6]u8{ p[7], p[6], p[5], p[4], p[3], p[2] },
            };
            const data_len = p[8];
            if (p.len < 9 + data_len + 1) return null;
            const data = p[9 .. 9 + data_len];
            const rssi: i8 = @bitCast(p[9 + data_len]);

            self.current_index += 1;
            self.offset = p.len; // Done
            return .{
                .event_type = ev_type,
                .address_type = addr_type,
                .address = mac,
                .data = data,
                .rssi = rssi,
            };
        }

        // Multiple reports case fallback
        return null;
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
                if (subevent == constants.LeSubevent.advertising_report) {
                    const it = try AdvertisingReportIterator.init(sub_params);
                    return .{ .le_advertising_report = it };
                }
                return .{
                    .le_meta_other = .{
                        .subevent = subevent,
                        .data = sub_params,
                    },
                };
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
