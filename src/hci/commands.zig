//! Zero-allocation HCI Command builders.
//! Strictly adhering to Bluetooth Core Specification v5.4, Vol 4, Part E (HCI).

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("../core/types.zig");
const Address = types.Address;

pub const ScanType = enum(u8) {
    passive = 0x00,
    active = 0x01,
};

pub const AddressType = enum(u8) {
    public = 0x00,
    random = 0x01,
    public_identity = 0x02,
    random_identity = 0x03,
};

pub const ScanFilterPolicy = enum(u8) {
    accept_all = 0x00,
    accept_accept_list_only = 0x01,
    accept_all_undirected_and_rpa = 0x02,
    accept_accept_list_and_rpa = 0x03,
};

pub const AdvType = enum(u8) {
    adv_ind = 0x00, // Connectable undirected
    adv_direct_ind_high = 0x01, // Connectable directed (high duty)
    adv_scan_ind = 0x02, // Scannable undirected
    adv_nonconn_ind = 0x03, // Non-connectable undirected
    adv_direct_ind_low = 0x04, // Connectable directed (low duty)
};

pub const Commands = struct {
    /// Helper to format an HCI command into a fixed buffer.
    /// Buffer layout: [PacketType: 1B] [Opcode: 2B LE] [ParamLen: 1B] [Params: NB]
    pub fn formatCommand(comptime max_param_len: usize) type {
        return struct {
            buf: [4 + max_param_len]u8,
            len: usize,

            pub fn slice(self: *const @This()) []const u8 {
                return self.buf[0..self.len];
            }
        };
    }

    /// HCI_Reset (OGF 0x03, OCF 0x0003)
    pub fn reset() [4]u8 {
        return [_]u8{
            @intFromEnum(constants.PacketType.command),
            @truncate(constants.Opcode.reset & 0xFF),
            @truncate(constants.Opcode.reset >> 8),
            0x00, // Param length: 0
        };
    }

    /// HCI_Read_BD_ADDR (OGF 0x04, OCF 0x0009)
    pub fn readBdAddr() [4]u8 {
        return [_]u8{
            @intFromEnum(constants.PacketType.command),
            @truncate(constants.Opcode.read_bd_addr & 0xFF),
            @truncate(constants.Opcode.read_bd_addr >> 8),
            0x00, // Param length: 0
        };
    }

    /// HCI_Set_Event_Mask (OGF 0x03, OCF 0x0001)
    pub fn setEventMask(mask: u64) [12]u8 {
        var buf: [12]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.set_event_mask, .little);
        buf[3] = 8; // Param length: 8
        std.mem.writeInt(u64, buf[4..12], mask, .little);
        return buf;
    }

    /// HCI_LE_Set_Event_Mask (OGF 0x08, OCF 0x0001)
    pub fn leSetEventMask(mask: u64) [12]u8 {
        var buf: [12]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_event_mask, .little);
        buf[3] = 8; // Param length: 8
        std.mem.writeInt(u64, buf[4..12], mask, .little);
        return buf;
    }

    /// HCI_LE_Set_Scan_Parameters (OGF 0x08, OCF 0x000B)
    /// `interval` & `window`: in units of 0.625 ms (e.g. 0x0010 = 10 ms)
    pub fn leSetScanParameters(
        scan_type: ScanType,
        interval: u16,
        window: u16,
        own_addr_type: AddressType,
        filter_policy: ScanFilterPolicy,
    ) [11]u8 {
        var buf: [11]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_scan_parameters, .little);
        buf[3] = 7; // Param length: 7
        buf[4] = @intFromEnum(scan_type);
        std.mem.writeInt(u16, buf[5..7], interval, .little);
        std.mem.writeInt(u16, buf[7..9], window, .little);
        buf[9] = @intFromEnum(own_addr_type);
        buf[10] = @intFromEnum(filter_policy);
        return buf;
    }

    /// HCI_LE_Set_Scan_Enable (OGF 0x08, OCF 0x000C)
    pub fn leSetScanEnable(enable: bool, filter_duplicates: bool) [6]u8 {
        var buf: [6]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_scan_enable, .little);
        buf[3] = 2; // Param length: 2
        buf[4] = if (enable) 0x01 else 0x00;
        buf[5] = if (filter_duplicates) 0x01 else 0x00;
        return buf;
    }

    /// HCI_LE_Set_Advertising_Parameters (OGF 0x08, OCF 0x0006)
    /// `min_interval` & `max_interval`: in units of 0.625 ms (range 0x0020 to 0x4000)
    pub fn leSetAdvertisingParameters(
        min_interval: u16,
        max_interval: u16,
        adv_type: AdvType,
        own_addr_type: AddressType,
        peer_addr_type: AddressType,
        peer_addr: Address,
        channel_map: u3, // Bit 0: Ch 37, Bit 1: Ch 38, Bit 2: Ch 39 (0x07 for all)
        filter_policy: u8,
    ) [19]u8 {
        var buf: [19]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_advertising_parameters, .little);
        buf[3] = 15; // Param length: 15
        std.mem.writeInt(u16, buf[4..6], min_interval, .little);
        std.mem.writeInt(u16, buf[6..8], max_interval, .little);
        buf[8] = @intFromEnum(adv_type);
        buf[9] = @intFromEnum(own_addr_type);
        buf[10] = @intFromEnum(peer_addr_type);
        // BD_ADDR in little-endian order
        buf[11] = peer_addr.bytes[5];
        buf[12] = peer_addr.bytes[4];
        buf[13] = peer_addr.bytes[3];
        buf[14] = peer_addr.bytes[2];
        buf[15] = peer_addr.bytes[1];
        buf[16] = peer_addr.bytes[0];
        buf[17] = channel_map;
        buf[18] = filter_policy;
        return buf;
    }

    /// HCI_LE_Set_Advertising_Data (OGF 0x08, OCF 0x0008)
    /// Payload up to 31 bytes (standard legacy advertising)
    pub fn leSetAdvertisingData(payload: []const u8) [36]u8 {
        var buf: [36]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_advertising_data, .little);
        buf[3] = 32; // Param length: 32 bytes (1 byte length + 31 bytes data)
        const copy_len = @min(31, payload.len);
        buf[4] = @intCast(copy_len);
        @memcpy(buf[5 .. 5 + copy_len], payload[0..copy_len]);
        if (copy_len < 31) {
            @memset(buf[5 + copy_len .. 36], 0);
        }
        return buf;
    }

    /// HCI_LE_Set_Scan_Response_Data (OGF 0x08, OCF 0x0009)
    pub fn leSetScanResponseData(payload: []const u8) [36]u8 {
        var buf: [36]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_scan_response_data, .little);
        buf[3] = 32;
        const copy_len = @min(31, payload.len);
        buf[4] = @intCast(copy_len);
        @memcpy(buf[5 .. 5 + copy_len], payload[0..copy_len]);
        if (copy_len < 31) {
            @memset(buf[5 + copy_len .. 36], 0);
        }
        return buf;
    }

    /// HCI_LE_Set_Advertise_Enable (OGF 0x08, OCF 0x000A)
    pub fn leSetAdvertiseEnable(enable: bool) [5]u8 {
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_advertise_enable, .little);
        buf[3] = 1; // Param length: 1
        buf[4] = if (enable) 0x01 else 0x00;
        return buf;
    }

    /// HCI_Disconnect (OGF 0x01, OCF 0x0006)
    pub fn disconnect(handle: u16, reason: u8) [7]u8 {
        var buf: [7]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        const op = constants.makeOpcode(constants.Ogf.link_control, 0x0006);
        std.mem.writeInt(u16, buf[1..3], op, .little);
        buf[3] = 3; // Param length: 3
        std.mem.writeInt(u16, buf[4..6], handle, .little);
        buf[6] = reason;
        return buf;
    }
};

test "HCI Commands: reset and scan parameters serialization" {
    const rst = Commands.reset();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x03, 0x0C, 0x00 }, &rst);

    const scan_params = Commands.leSetScanParameters(.active, 0x0010, 0x0010, .public, .accept_all);
    try std.testing.expectEqual(@as(u8, 0x01), scan_params[0]); // HCI_COMMAND_PKT
    try std.testing.expectEqual(@as(u16, 0x200B), std.mem.readInt(u16, scan_params[1..3], .little)); // LE_Set_Scan_Parameters opcode
    try std.testing.expectEqual(@as(u8, 7), scan_params[3]); // Param len
    try std.testing.expectEqual(@as(u8, 0x01), scan_params[4]); // Active scan
    try std.testing.expectEqual(@as(u16, 0x0010), std.mem.readInt(u16, scan_params[5..7], .little)); // Interval
    try std.testing.expectEqual(@as(u16, 0x0010), std.mem.readInt(u16, scan_params[7..9], .little)); // Window

    const scan_en = Commands.leSetScanEnable(true, true);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x0C, 0x20, 0x02, 0x01, 0x01 }, &scan_en);
}
