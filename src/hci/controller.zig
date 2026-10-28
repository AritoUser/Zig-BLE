//! High-level Zero-Daemon BLE Controller based on Raw HCI Sockets.
//! Provides turnkey scanning, advertising, connection lifecycle management,
//! and credit-based ACL flow control directly over raw HCI transports.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const filter_mod = @import("filter.zig");
const HciFilter = filter_mod.HciFilter;
const socket_mod = @import("socket.zig");
const HciSocket = socket_mod.HciSocket;
const HciError = socket_mod.HciError;
const commands_mod = @import("commands.zig");
const Commands = commands_mod.Commands;
const events_mod = @import("events.zig");
const HciEvent = events_mod.HciEvent;
const HciAdvertisingReport = events_mod.HciAdvertisingReport;
const CompletedPacketsIterator = events_mod.CompletedPacketsIterator;
const types = @import("../core/types.zig");
const Address = types.Address;
const log = std.log.scoped(.zig_ble);

pub const HciScanConfig = struct {
    scan_type: commands_mod.ScanType = .active,
    /// Interval in units of 0.625 ms (default 0x0010 = 10 ms)
    interval: u16 = 0x0010,
    /// Window in units of 0.625 ms (default 0x0010 = 10 ms)
    window: u16 = 0x0010,
    own_addr_type: commands_mod.AddressType = .public,
    filter_duplicates: bool = true,
};

/// Controller-to-Host / Host-to-Controller LE ACL Data Flow Controller
/// (Bluetooth Core Spec v5.4, Vol 4, Part E, Section 4.1.1 & 7.8.2).
///
/// Tracks the controller's `le_acl_data_packet_length` and `total_num_le_acl_data_packets`
/// reported by `HCI_LE_Read_Buffer_Size`, maintains per-connection-handle in-flight packet
/// counts, and replenishes credits upon receiving `Number of Completed Packets` (`0x13`)
/// or `Disconnection Complete` (`0x05`).
pub const AclFlowController = struct {
    pub const max_connections = 8;

    pub const ConnectionFlowSlot = struct {
        in_use: bool = false,
        handle: u16 = 0,
        in_flight: u16 = 0,
    };

    max_packet_length: u16 = 27,
    total_packets: u16 = 8,
    available_credits: u16 = 8,
    slots: [max_connections]ConnectionFlowSlot = @splat(.{}),

    pub fn init(max_packet_length: u16, total_packets: u16) AclFlowController {
        const eff_len: u16 = if (max_packet_length == 0) 27 else max_packet_length;
        const eff_pkts: u16 = if (total_packets == 0) 1 else total_packets;
        return .{
            .max_packet_length = eff_len,
            .total_packets = eff_pkts,
            .available_credits = eff_pkts,
        };
    }

    /// Updates the flow controller parameters from a `Command Complete` return payload
    /// of `LE_Read_Buffer_Size` (`[status: 1B] [pkt_len: 2B LE] [total_pkts: 1B]`).
    pub fn updateFromLeReadBufferSize(self: *AclFlowController, return_params: []const u8) bool {
        if (return_params.len < 3) return false;
        const pkt_len = std.mem.readInt(u16, return_params[0..2], .little);
        const total_pkts = return_params[2];
        if (pkt_len == 0 or total_pkts == 0) return false;
        self.max_packet_length = pkt_len;
        self.total_packets = total_pkts;
        self.available_credits = total_pkts;
        return true;
    }

    pub fn registerConnection(self: *AclFlowController, handle: u16) void {
        for (&self.slots) |*s| {
            if (s.in_use and s.handle == handle) return;
        }
        for (&self.slots) |*s| {
            if (!s.in_use) {
                s.* = .{
                    .in_use = true,
                    .handle = handle,
                    .in_flight = 0,
                };
                return;
            }
        }
    }

    /// Attempts to acquire 1 ACL packet credit for `handle`.
    /// Returns `true` if a credit was acquired, or `false` if the controller buffer is full.
    pub fn tryAcquireCredit(self: *AclFlowController, handle: u16) bool {
        if (self.available_credits == 0) return false;
        self.registerConnection(handle);
        for (&self.slots) |*s| {
            if (s.in_use and s.handle == handle) {
                self.available_credits -= 1;
                s.in_flight +|= 1;
                return true;
            }
        }
        return false;
    }

    /// Processes `Number of Completed Packets` (Event `0x13`), decrementing in-flight counts
    /// and returning credits to `available_credits` without exceeding `total_packets`.
    pub fn onNumberOfCompletedPackets(self: *AclFlowController, iter: CompletedPacketsIterator) void {
        var it = iter;
        while (it.next()) |entry| {
            for (&self.slots) |*s| {
                if (s.in_use and s.handle == entry.handle) {
                    const released = @min(s.in_flight, entry.num_completed_packets);
                    s.in_flight -= released;
                    self.available_credits = @min(self.total_packets, self.available_credits +| released);
                    break;
                }
            }
        }
    }

    /// Reclaims all in-flight credits for a disconnected handle on `Disconnection Complete` (Event `0x05`).
    pub fn onDisconnectionComplete(self: *AclFlowController, handle: u16) void {
        for (&self.slots) |*s| {
            if (s.in_use and s.handle == handle) {
                self.available_credits = @min(self.total_packets, self.available_credits +| s.in_flight);
                s.* = .{};
                return;
            }
        }
    }

    pub fn getInFlight(self: *const AclFlowController, handle: u16) u16 {
        for (&self.slots) |*s| {
            if (s.in_use and s.handle == handle) return s.in_flight;
        }
        return 0;
    }
};

pub const HciController = struct {
    sock: HciSocket,
    is_scanning: bool = false,
    flow: AclFlowController = .{},

    /// Opens the specified HCI device (e.g. hci0 -> 0) and initializes the controller.
    pub fn open(device_index: u16) HciError!HciController {
        var sock = try HciSocket.open(device_index, constants.HCI_CHANNEL_RAW);
        errdefer sock.close();

        var ctrl = HciController{
            .sock = sock,
            .is_scanning = false,
            .flow = .{},
        };
        ctrl.queryLeBufferSize() catch |err| {
            log.debug("Initial LE_Read_Buffer_Size query skipped/failed: {s}", .{@errorName(err)});
        };
        return ctrl;
    }

    /// Releases the HCI socket.
    pub fn close(self: *HciController) void {
        if (self.is_scanning) {
            self.stopScan() catch |err| {
                log.warn("HciController.close stopScan failed: {s}", .{@errorName(err)});
            };
        }
        self.sock.close();
    }

    /// Queries `HCI_LE_Read_Buffer_Size` (`0x2002`) and configures `self.flow`.
    pub fn queryLeBufferSize(self: *HciController) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        const cmd = Commands.leReadBufferSize();
        try self.sock.send(&cmd);

        var buf: [256]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            if (self.sock.poll(50) == 0) continue;
            const n = try self.sock.readPacket(&buf);
            if (n == 0) continue;

            const evt = HciEvent.parse(buf[0..n]) catch continue;
            switch (evt) {
                .command_complete => |cc| {
                    if (cc.opcode == constants.Opcode.le_read_buffer_size and cc.status == .success) {
                        _ = self.flow.updateFromLeReadBufferSize(cc.return_params);
                        return;
                    }
                },
                else => {},
            }
        }
    }

    /// Reads the hardware Bluetooth MAC address (BD_ADDR) of this controller.
    pub fn readBdAddr(self: *HciController) HciError!Address {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        const cmd = Commands.readBdAddr();
        try self.sock.send(&cmd);

        var buf: [256]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            if (self.sock.poll(100) == 0) continue;
            const n = try self.sock.readPacket(&buf);
            if (n == 0) continue;

            const evt = HciEvent.parse(buf[0..n]) catch continue;
            switch (evt) {
                .command_complete => |cc| {
                    if (cc.opcode == constants.Opcode.read_bd_addr and cc.return_params.len >= 6) {
                        if (cc.status != .success) return HciError.CommandFailed;
                        const p = cc.return_params;
                        return Address.fromLittleEndian(p[0..6].*);
                    }
                },
                else => {},
            }
        }
        return HciError.Timeout;
    }

    /// Initiates a BLE connection via `HCI_LE_Create_Connection` (`0x200D`) and waits for `LE_Connection_Complete`.
    pub fn createConnection(self: *HciController, params: commands_mod.CreateConnectionParams, timeout_ms: u32) HciError!u16 {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        const cmd = Commands.leCreateConnection(params);
        try self.sock.send(&cmd);

        var buf: [256]u8 = undefined;
        var elapsed: u32 = 0;
        while (elapsed < timeout_ms) : (elapsed += 50) {
            if (self.sock.poll(50) == 0) continue;
            const n = try self.sock.readPacket(&buf);
            if (n == 0) continue;

            const evt = HciEvent.parse(buf[0..n]) catch continue;
            self.processFlowEvent(evt);
            switch (evt) {
                .command_status => |cs| {
                    if (cs.opcode == constants.Opcode.le_create_connection and cs.status != .success) {
                        return HciError.CommandFailed;
                    }
                },
                .le_connection_complete => |cc| {
                    if (cc.status != .success) return HciError.CommandFailed;
                    self.flow.registerConnection(cc.handle);
                    return cc.handle;
                },
                .le_enhanced_connection_complete => |ecc| {
                    if (ecc.status != .success) return HciError.CommandFailed;
                    self.flow.registerConnection(ecc.handle);
                    return ecc.handle;
                },
                else => {},
            }
        }
        return HciError.Timeout;
    }

    /// Terminates an active BLE connection via `HCI_Disconnect` (`0x0406`).
    pub fn disconnect(self: *HciController, handle: u16, reason: u8) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        const cmd = Commands.disconnect(handle, reason);
        try self.sock.send(&cmd);
    }

    /// Updates connection parameters via `HCI_LE_Connection_Update` (`0x2013`).
    pub fn updateConnectionParameters(
        self: *HciController,
        handle: u16,
        interval_min: u16,
        interval_max: u16,
        latency: u16,
        supervision_timeout: u16,
    ) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        const cmd = Commands.leConnectionUpdate(handle, interval_min, interval_max, latency, supervision_timeout, 0, 0);
        try self.sock.send(&cmd);
    }

    /// Requests Data Length Extension (DLE) update via `HCI_LE_Set_Data_Length` (`0x2022`).
    pub fn setDataLength(self: *HciController, handle: u16, tx_octets: u16, tx_time: u16) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        const cmd = Commands.leSetDataLength(handle, tx_octets, tx_time);
        try self.sock.send(&cmd);
    }

    /// Starts link encryption via `HCI_LE_Start_Encryption` (`0x2019`).
    pub fn startEncryption(self: *HciController, handle: u16, rand: u64, ediv: u16, ltk: [16]u8) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        const cmd = Commands.leStartEncryption(handle, rand, ediv, ltk);
        try self.sock.send(&cmd);
    }

    /// Processes flow-control-relevant HCI events (`Number of Completed Packets` and `Disconnection Complete`).
    pub fn processFlowEvent(self: *HciController, evt: HciEvent) void {
        switch (evt) {
            .number_of_completed_packets => |it| self.flow.onNumberOfCompletedPackets(it),
            .disconnection_complete => |dc| {
                if (dc.status == .success) {
                    self.flow.onDisconnectionComplete(dc.handle);
                }
            },
            .le_connection_complete => |cc| {
                if (cc.status == .success) {
                    self.flow.registerConnection(cc.handle);
                }
            },
            .le_enhanced_connection_complete => |ecc| {
                if (ecc.status == .success) {
                    self.flow.registerConnection(ecc.handle);
                }
            },
            else => {},
        }
    }

    /// Segments an L2CAP PDU (`[L2CAP_Len: 2B LE] [CID: 2B LE] [Information Payload]`) into
    /// controller-sized HCI ACL fragments (`0x02`) and transmits each fragment while respecting
    /// `AclFlowController` packet credits.
    pub fn sendL2capPdu(self: *HciController, handle: u16, cid: u16, payload: []const u8) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        var l2cap_buf: [520]u8 = undefined;
        if (4 + payload.len > l2cap_buf.len) return HciError.InvalidArgument;
        std.mem.writeInt(u16, l2cap_buf[0..2], @intCast(payload.len), .little);
        std.mem.writeInt(u16, l2cap_buf[2..4], cid, .little);
        @memcpy(l2cap_buf[4 .. 4 + payload.len], payload);
        const total_l2cap = l2cap_buf[0 .. 4 + payload.len];

        const max_frag = @max(@as(usize, 27), self.flow.max_packet_length);
        var offset: usize = 0;
        var is_first = true;

        while (offset < total_l2cap.len) {
            while (!self.flow.tryAcquireCredit(handle)) {
                var evt_buf: [256]u8 = undefined;
                if (self.sock.poll(50) == 0) return HciError.Timeout;
                const n = try self.sock.readPacket(&evt_buf);
                if (n > 0) {
                    if (HciEvent.parse(evt_buf[0..n])) |evt| {
                        self.processFlowEvent(evt);
                    } else |_| {}
                }
            }

            const chunk_len = @min(max_frag, total_l2cap.len - offset);
            var acl_pkt: [5 + 255]u8 = undefined;
            acl_pkt[0] = @intFromEnum(constants.PacketType.acl_data);
            // PB Flag: 0b00 (First non-automatically-flushable packet) or 0b01 (Continuing fragment)
            const pb_bits: u16 = if (is_first) 0x0000 else (0x0001 << 12);
            const handle_pb: u16 = (handle & 0x0FFF) | pb_bits;
            std.mem.writeInt(u16, acl_pkt[1..3], handle_pb, .little);
            std.mem.writeInt(u16, acl_pkt[3..5], @intCast(chunk_len), .little);
            @memcpy(acl_pkt[5 .. 5 + chunk_len], total_l2cap[offset .. offset + chunk_len]);

            try self.sock.send(acl_pkt[0 .. 5 + chunk_len]);
            offset += chunk_len;
            is_first = false;
        }
    }

    /// Configures socket filtering and begins Bluetooth Low Energy scanning.
    pub fn startScan(self: *HciController, config: HciScanConfig) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        // 1. Install kernel-level packet filter for LE Meta events and Command Complete
        const filter = HciFilter.initLeScan();
        try self.sock.setFilter(filter);

        // 2. Set LE Event Mask (all LE events enabled)
        const mask_cmd = Commands.leSetEventMask(0x00000000000003FF);
        try self.sock.send(&mask_cmd);

        // 3. Set Scan Parameters
        const param_cmd = Commands.leSetScanParameters(
            config.scan_type,
            config.interval,
            config.window,
            config.own_addr_type,
            .accept_all,
        );
        try self.sock.send(&param_cmd);

        // 4. Enable Scanning
        const enable_cmd = Commands.leSetScanEnable(true, config.filter_duplicates);
        try self.sock.send(&enable_cmd);

        self.is_scanning = true;
    }

    /// Stops BLE scanning.
    pub fn stopScan(self: *HciController) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        if (!self.is_scanning) return;

        const disable_cmd = Commands.leSetScanEnable(false, false);
        try self.sock.send(&disable_cmd);
        self.is_scanning = false;
    }

    /// Reads and parses the next advertising report.
    /// Returns null if no packet arrived within `timeout_ms`.
    pub fn readReport(self: *HciController, buf: []u8, timeout_ms: c_int) HciError!?HciAdvertisingReport {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        if (self.sock.poll(timeout_ms) == 0) return null;
        const n = try self.sock.readPacket(buf);
        if (n == 0) return null;

        const evt = HciEvent.parse(buf[0..n]) catch return null;
        self.processFlowEvent(evt);
        switch (evt) {
            .le_advertising_report => |mut_it| {
                var it = mut_it;
                return it.next();
            },
            else => return null,
        }
    }
};

test "HciController: non-linux mock check" {
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(HciError.NotSupported, HciController.open(0));
    }
}

test "AclFlowController: credit acquisition, Number of Completed Packets replenishment, and disconnect cleanup" {
    var flow = AclFlowController.init(27, 3);
    try std.testing.expectEqual(@as(u16, 27), flow.max_packet_length);
    try std.testing.expectEqual(@as(u16, 3), flow.available_credits);

    // Update from LE_Read_Buffer_Size return_params (251 bytes, 4 buffers)
    try std.testing.expect(flow.updateFromLeReadBufferSize(&[_]u8{ 0xFB, 0x00, 0x04 }));
    try std.testing.expectEqual(@as(u16, 251), flow.max_packet_length);
    try std.testing.expectEqual(@as(u16, 4), flow.available_credits);

    // Acquire 3 credits on handle 0x0040 and 1 credit on handle 0x0041
    try std.testing.expect(flow.tryAcquireCredit(0x0040));
    try std.testing.expect(flow.tryAcquireCredit(0x0040));
    try std.testing.expect(flow.tryAcquireCredit(0x0040));
    try std.testing.expect(flow.tryAcquireCredit(0x0041));
    try std.testing.expectEqual(@as(u16, 0), flow.available_credits);
    try std.testing.expectEqual(@as(u16, 3), flow.getInFlight(0x0040));
    try std.testing.expectEqual(@as(u16, 1), flow.getInFlight(0x0041));

    // Buffer full -> tryAcquireCredit returns false
    try std.testing.expect(!flow.tryAcquireCredit(0x0040));

    // Receive Number of Completed Packets (2 completed for 0x0040)
    const raw_ncp = [_]u8{ 0x04, 0x13, 5, 0x01, 0x40, 0x00, 0x02, 0x00 };
    const evt = try HciEvent.parse(&raw_ncp);
    flow.onNumberOfCompletedPackets(evt.number_of_completed_packets);
    try std.testing.expectEqual(@as(u16, 2), flow.available_credits);
    try std.testing.expectEqual(@as(u16, 1), flow.getInFlight(0x0040));

    // Disconnection of 0x0040 reclaims remaining 1 in-flight credit
    flow.onDisconnectionComplete(0x0040);
    try std.testing.expectEqual(@as(u16, 3), flow.available_credits);
    try std.testing.expectEqual(@as(u16, 0), flow.getInFlight(0x0040));
}
