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

pub const ExtAdvProperties = packed struct(u16) {
    connectable: bool = false,
    scannable: bool = false,
    directed: bool = false,
    high_duty_directed: bool = false,
    legacy: bool = false,
    anonymous: bool = false,
    include_tx_power: bool = false,
    _reserved: u9 = 0,
};

pub const ExtAdvParams = struct {
    handle: u8 = 0,
    properties: ExtAdvProperties = .{},
    min_interval: u24 = 0x000800, // units of 0.625ms
    max_interval: u24 = 0x000800,
    channel_map: u3 = 0x07, // Channels 37, 38, 39
    own_addr_type: AddressType = .public,
    peer_addr_type: AddressType = .public,
    peer_addr: Address = Address.any,
    filter_policy: u8 = 0,
    tx_power: i8 = 127, // 127 = host has no preference
    primary_phy: u8 = 1, // 1 = LE 1M, 3 = LE Coded
    secondary_max_skip: u8 = 0,
    secondary_phy: u8 = 1, // 1 = LE 1M, 2 = LE 2M, 3 = LE Coded
    sid: u8 = 0,
    scan_req_notification: bool = false,
};

pub const ExtAdvDataCommand = struct {
    buf: [4 + 4 + 251]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ExtAdvDataCommand) []const u8 {
        return self.buf[0..self.len];
    }
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

    // ========================================================================
    // PHY & Speed Management (Bluetooth 5.0+)
    // ========================================================================

    /// HCI_LE_Read_PHY (OGF 0x08, OCF 0x0030)
    pub fn leReadPhy(handle: u16) [6]u8 {
        var buf: [6]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_read_phy, .little);
        buf[3] = 2; // Param length: 2
        std.mem.writeInt(u16, buf[4..6], handle, .little);
        return buf;
    }

    /// HCI_LE_Set_Default_PHY (OGF 0x08, OCF 0x0031)
    /// `all_phys`: Bit 0: No TX preference, Bit 1: No RX preference
    /// `tx_phys` & `rx_phys`: Bit 0: LE 1M, Bit 1: LE 2M, Bit 2: LE Coded
    pub fn leSetDefaultPhy(all_phys: u8, tx_phys: u8, rx_phys: u8) [7]u8 {
        var buf: [7]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_default_phy, .little);
        buf[3] = 3;
        buf[4] = all_phys;
        buf[5] = tx_phys;
        buf[6] = rx_phys;
        return buf;
    }

    /// HCI_LE_Set_PHY (OGF 0x08, OCF 0x0032)
    /// `phy_options`: 0 = No preference, 1 = S=2 preferred, 2 = S=8 preferred
    pub fn leSetPhy(handle: u16, all_phys: u8, tx_phys: u8, rx_phys: u8, phy_options: u16) [11]u8 {
        var buf: [11]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_phy, .little);
        buf[3] = 7;
        std.mem.writeInt(u16, buf[4..6], handle, .little);
        buf[6] = all_phys;
        buf[7] = tx_phys;
        buf[8] = rx_phys;
        std.mem.writeInt(u16, buf[9..11], phy_options, .little);
        return buf;
    }

    // ========================================================================
    // Data Length Extension (DLE) (Bluetooth 4.2+)
    // ========================================================================

    /// HCI_LE_Set_Data_Length (OGF 0x08, OCF 0x0022)
    /// `tx_octets`: 27 to 251 bytes
    /// `tx_time`: 328 to 17040 microseconds
    pub fn leSetDataLength(handle: u16, tx_octets: u16, tx_time: u16) [10]u8 {
        var buf: [10]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_data_length, .little);
        buf[3] = 6;
        std.mem.writeInt(u16, buf[4..6], handle, .little);
        std.mem.writeInt(u16, buf[6..8], tx_octets, .little);
        std.mem.writeInt(u16, buf[8..10], tx_time, .little);
        return buf;
    }

    /// HCI_LE_Read_Suggested_Default_Data_Length (OGF 0x08, OCF 0x0023)
    pub fn leReadSuggestedDefaultDataLength() [4]u8 {
        return [_]u8{
            @intFromEnum(constants.PacketType.command),
            @truncate(constants.Opcode.le_read_suggested_default_data_length & 0xFF),
            @truncate(constants.Opcode.le_read_suggested_default_data_length >> 8),
            0x00,
        };
    }

    /// HCI_LE_Write_Suggested_Default_Data_Length (OGF 0x08, OCF 0x0024)
    pub fn leWriteSuggestedDefaultDataLength(max_tx_octets: u16, max_tx_time: u16) [8]u8 {
        var buf: [8]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_write_suggested_default_data_length, .little);
        buf[3] = 4;
        std.mem.writeInt(u16, buf[4..6], max_tx_octets, .little);
        std.mem.writeInt(u16, buf[6..8], max_tx_time, .little);
        return buf;
    }

    /// HCI_LE_Read_Maximum_Data_Length (OGF 0x08, OCF 0x002F)
    pub fn leReadMaximumDataLength() [4]u8 {
        return [_]u8{
            @intFromEnum(constants.PacketType.command),
            @truncate(constants.Opcode.le_read_maximum_data_length & 0xFF),
            @truncate(constants.Opcode.le_read_maximum_data_length >> 8),
            0x00,
        };
    }

    // ========================================================================
    // Controller Hardware Crypto Acceleration Offload
    // ========================================================================

    /// HCI_LE_Read_Local_P256_Public_Key (OGF 0x08, OCF 0x0025)
    /// Triggers hardware ECDH P-256 keypair generation in the controller.
    /// Completes asynchronously via LE_Read_Local_P256_Public_Key_Complete event.
    pub fn leReadLocalP256PublicKey() [4]u8 {
        return [_]u8{
            @intFromEnum(constants.PacketType.command),
            @truncate(constants.Opcode.le_read_local_p256_public_key & 0xFF),
            @truncate(constants.Opcode.le_read_local_p256_public_key >> 8),
            0x00,
        };
    }

    /// HCI_LE_Generate_DHKey (OGF 0x08, OCF 0x0026)
    /// Generates Diffie-Hellman shared secret key from remote P-256 public key (X + Y).
    pub fn leGenerateDhKey(public_key: [64]u8) [68]u8 {
        var buf: [68]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_generate_dhkey, .little);
        buf[3] = 64;
        @memcpy(buf[4..68], &public_key);
        return buf;
    }

    /// HCI_LE_Generate_DHKey_v2 (OGF 0x08, OCF 0x005E)
    /// `key_type`: 0 = Use generated private key, 1 = Use debug private key
    pub fn leGenerateDhKeyV2(public_key: [64]u8, key_type: u8) [69]u8 {
        var buf: [69]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_generate_dhkey_v2, .little);
        buf[3] = 65;
        @memcpy(buf[4..68], &public_key);
        buf[68] = key_type;
        return buf;
    }

    // ========================================================================
    // Extended Advertising (Bluetooth 5.0+)
    // ========================================================================

    /// HCI_LE_Set_Extended_Advertising_Parameters (OGF 0x08, OCF 0x0036)
    pub fn leSetExtAdvertisingParameters(params: ExtAdvParams) [29]u8 {
        var buf: [29]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_ext_advertising_parameters, .little);
        buf[3] = 25; // 25 parameters bytes
        buf[4] = params.handle;
        std.mem.writeInt(u16, buf[5..7], @as(u16, @bitCast(params.properties)), .little);

        // 24-bit primary min interval
        buf[7] = @truncate(params.min_interval & 0xFF);
        buf[8] = @truncate((params.min_interval >> 8) & 0xFF);
        buf[9] = @truncate((params.min_interval >> 16) & 0xFF);

        // 24-bit primary max interval
        buf[10] = @truncate(params.max_interval & 0xFF);
        buf[11] = @truncate((params.max_interval >> 8) & 0xFF);
        buf[12] = @truncate((params.max_interval >> 16) & 0xFF);

        buf[13] = params.channel_map;
        buf[14] = @intFromEnum(params.own_addr_type);
        buf[15] = @intFromEnum(params.peer_addr_type);

        // BD_ADDR in little-endian order
        buf[16] = params.peer_addr.bytes[5];
        buf[17] = params.peer_addr.bytes[4];
        buf[18] = params.peer_addr.bytes[3];
        buf[19] = params.peer_addr.bytes[2];
        buf[20] = params.peer_addr.bytes[1];
        buf[21] = params.peer_addr.bytes[0];

        buf[22] = params.filter_policy;
        buf[23] = @bitCast(params.tx_power);
        buf[24] = params.primary_phy;
        buf[25] = params.secondary_max_skip;
        buf[26] = params.secondary_phy;
        buf[27] = params.sid;
        buf[28] = if (params.scan_req_notification) 1 else 0;
        return buf;
    }

    /// HCI_LE_Set_Extended_Advertising_Data (OGF 0x08, OCF 0x0037)
    /// `operation`: 0 = Intermediate, 1 = First, 2 = Last, 3 = Complete, 4 = Unchanged
    /// `frag_pref`: 0 = Controller may fragment, 1 = Controller should not fragment
    pub fn leSetExtAdvertisingData(handle: u8, operation: u8, frag_pref: u8, payload: []const u8) ExtAdvDataCommand {
        var cmd = ExtAdvDataCommand{};
        cmd.buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, cmd.buf[1..3], constants.Opcode.le_set_ext_advertising_data, .little);
        const copy_len = @min(251, payload.len);
        cmd.buf[3] = @intCast(4 + copy_len);
        cmd.buf[4] = handle;
        cmd.buf[5] = operation;
        cmd.buf[6] = frag_pref;
        cmd.buf[7] = @intCast(copy_len);
        @memcpy(cmd.buf[8 .. 8 + copy_len], payload[0..copy_len]);
        cmd.len = 8 + copy_len;
        return cmd;
    }

    /// HCI_LE_Set_Extended_Scan_Response_Data (OGF 0x08, OCF 0x0038)
    pub fn leSetExtScanResponseData(handle: u8, operation: u8, frag_pref: u8, payload: []const u8) ExtAdvDataCommand {
        var cmd = ExtAdvDataCommand{};
        cmd.buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, cmd.buf[1..3], constants.Opcode.le_set_ext_scan_response_data, .little);
        const copy_len = @min(251, payload.len);
        cmd.buf[3] = @intCast(4 + copy_len);
        cmd.buf[4] = handle;
        cmd.buf[5] = operation;
        cmd.buf[6] = frag_pref;
        cmd.buf[7] = @intCast(copy_len);
        @memcpy(cmd.buf[8 .. 8 + copy_len], payload[0..copy_len]);
        cmd.len = 8 + copy_len;
        return cmd;
    }

    /// HCI_LE_Set_Extended_Advertising_Enable (OGF 0x08, OCF 0x0039)
    /// `duration`: in units of 10 ms (0 = until disabled)
    /// `max_events`: 0 = no limit
    pub fn leSetExtAdvertiseEnable(enable: bool, handle: u8, duration: u16, max_events: u8) [10]u8 {
        var buf: [10]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_ext_advertise_enable, .little);
        buf[3] = 6;
        buf[4] = if (enable) 1 else 0;
        buf[5] = 1; // Number of sets: 1
        buf[6] = handle;
        std.mem.writeInt(u16, buf[7..9], duration, .little);
        buf[9] = max_events;
        return buf;
    }

    // ========================================================================
    // Extended Scanning & Periodic Advertising (Bluetooth 5.0+)
    // ========================================================================

    /// HCI_LE_Set_Extended_Scan_Enable (OGF 0x08, OCF 0x0042)
    /// `filter_duplicates`: 0 = Disable, 1 = Enable, 2 = Enable per periodic advertising train
    /// `duration` & `period`: in units of 10 ms (0 = scan continuously)
    pub fn leSetExtScanEnable(enable: bool, filter_duplicates: u8, duration: u16, period: u16) [10]u8 {
        var buf: [10]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_ext_scan_enable, .little);
        buf[3] = 6;
        buf[4] = if (enable) 1 else 0;
        buf[5] = filter_duplicates;
        std.mem.writeInt(u16, buf[6..8], duration, .little);
        std.mem.writeInt(u16, buf[8..10], period, .little);
        return buf;
    }

    /// HCI_LE_Set_Periodic_Advertising_Parameters (OGF 0x08, OCF 0x003E)
    /// `min_interval` & `max_interval`: in units of 1.25 ms (range 0x0006 to 0xFFFF)
    pub fn leSetPeriodicAdvertisingParameters(
        handle: u8,
        min_interval: u16,
        max_interval: u16,
        include_tx_power: bool,
    ) [11]u8 {
        var buf: [11]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_periodic_advertising_parameters, .little);
        buf[3] = 7;
        buf[4] = handle;
        std.mem.writeInt(u16, buf[5..7], min_interval, .little);
        std.mem.writeInt(u16, buf[7..9], max_interval, .little);
        std.mem.writeInt(u16, buf[9..11], if (include_tx_power) 0x0040 else 0x0000, .little);
        return buf;
    }

    /// HCI_LE_Set_Periodic_Advertising_Enable (OGF 0x08, OCF 0x0040)
    pub fn leSetPeriodicAdvertisingEnable(enable: bool, handle: u8) [6]u8 {
        var buf: [6]u8 = undefined;
        buf[0] = @intFromEnum(constants.PacketType.command);
        std.mem.writeInt(u16, buf[1..3], constants.Opcode.le_set_periodic_advertising_enable, .little);
        buf[3] = 2;
        buf[4] = if (enable) 1 else 0;
        buf[5] = handle;
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

    // PHY commands
    const read_phy = Commands.leReadPhy(0x0040);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x30, 0x20, 0x02, 0x40, 0x00 }, &read_phy);

    const set_phy = Commands.leSetPhy(0x0040, 0x00, 0x02, 0x02, 0x0001);
    try std.testing.expectEqual(@as(u8, 0x01), set_phy[0]);
    try std.testing.expectEqual(@as(u16, 0x2032), std.mem.readInt(u16, set_phy[1..3], .little));
    try std.testing.expectEqual(@as(u8, 7), set_phy[3]);
    try std.testing.expectEqual(@as(u16, 0x0040), std.mem.readInt(u16, set_phy[4..6], .little));
    try std.testing.expectEqual(@as(u8, 0x02), set_phy[7]); // tx 2M
    try std.testing.expectEqual(@as(u8, 0x02), set_phy[8]); // rx 2M

    // DLE command
    const dle = Commands.leSetDataLength(0x0040, 251, 2120);
    try std.testing.expectEqual(@as(u8, 0x01), dle[0]);
    try std.testing.expectEqual(@as(u16, 0x2022), std.mem.readInt(u16, dle[1..3], .little));
    try std.testing.expectEqual(@as(u16, 251), std.mem.readInt(u16, dle[6..8], .little));
    try std.testing.expectEqual(@as(u16, 2120), std.mem.readInt(u16, dle[8..10], .little));

    // Crypto Offload commands
    const read_p256 = Commands.leReadLocalP256PublicKey();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x25, 0x20, 0x00 }, &read_p256);

    const dummy_pub: [64]u8 = [_]u8{0xAA} ** 64;
    const gen_dhkey = Commands.leGenerateDhKey(dummy_pub);
    try std.testing.expectEqual(@as(u8, 0x01), gen_dhkey[0]);
    try std.testing.expectEqual(@as(u16, 0x2026), std.mem.readInt(u16, gen_dhkey[1..3], .little));
    try std.testing.expectEqual(@as(u8, 64), gen_dhkey[3]);
    try std.testing.expectEqual(@as(u8, 0xAA), gen_dhkey[4]);

    // Extended Advertising
    const ext_adv = Commands.leSetExtAdvertisingParameters(.{
        .handle = 1,
        .properties = .{ .connectable = true, .legacy = false },
        .primary_phy = 3, // Coded PHY
        .secondary_phy = 3,
    });
    try std.testing.expectEqual(@as(u8, 0x01), ext_adv[0]);
    try std.testing.expectEqual(@as(u16, 0x2036), std.mem.readInt(u16, ext_adv[1..3], .little));
    try std.testing.expectEqual(@as(u8, 25), ext_adv[3]);
    try std.testing.expectEqual(@as(u8, 1), ext_adv[4]); // handle 1
    try std.testing.expectEqual(@as(u8, 3), ext_adv[24]); // primary Coded PHY
    try std.testing.expectEqual(@as(u8, 3), ext_adv[26]); // secondary Coded PHY
}
