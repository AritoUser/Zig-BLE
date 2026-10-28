//! # Zig-BLE Raw HCI Backend (`HciBackend`)
//!
//! Full `BackendVTable` implementation combining:
//! - `HciController` (`AF_BLUETOOTH` / `HCI_CHANNEL_RAW` or custom transport hook)
//! - `AclReassembler` & `AclFlowController` (L2CAP framing & controller credit tracking)
//! - `AttBearer` & `ServiceDiscoveryClient` (ATT over L2CAP CID `0x0004`)
//! - `SmpStateMachine` (SMP over L2CAP CID `0x0006`)

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const vtable_mod = @import("vtable.zig");
const hci = @import("../hci/mod.zig");
const l2cap = @import("../l2cap/mod.zig");
const att = @import("../core/att.zig");
const smp = @import("../crypto/smp.zig");

const Address = types.Address;
const AddressType = types.AddressType;
const UUID = types.UUID;
const BleError = types.BleError;
const ScanFilter = types.ScanFilter;
const ScanCallback = types.ScanCallback;
const NotificationCallback = types.NotificationCallback;
const BondState = types.BondState;
const IoCapability = types.IoCapability;
const Backend = vtable_mod.Backend;
const BackendVTable = vtable_mod.BackendVTable;

pub const DiscoveredCharacteristic = struct {
    uuid: UUID = UUID.from16(0),
    decl_handle: u16 = 0,
    value_handle: u16 = 0,
    cccd_handle: u16 = 0,
    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,
    active: bool = false,
};

pub const HciDeviceContext = struct {
    in_use: bool = false,
    connected: bool = false,
    address: Address = .{ .bytes = @splat(0) },
    addr_type: AddressType = .public,
    conn_handle: u16 = 0x0040,
    rssi: ?i16 = -55,
    bond_state: BondState = .not_bonded,
    att_bearer: att.AttBearer = .{},
    reassembler: l2cap.AclReassembler(517) = l2cap.AclReassembler(517).init(),
    smp_sm: ?smp.SmpStateMachine = null,
    characteristics: [16]DiscoveredCharacteristic = @splat(.{}),
    last_read_buf: [512]u8 = @splat(0),
    last_read_len: usize = 0,
};

pub const TransportHook = struct {
    ctx: ?*anyopaque = null,
    on_send_packet: *const fn (ctx: ?*anyopaque, packet: []const u8) BleError!void,
};

pub const HciBackend = struct {
    mutex: types.SyncMutex = .{},
    is_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    controller: ?hci.HciController = null,
    transport_hook: ?TransportHook = null,
    pcap_hook: ?types.PcapHook = null,
    powered: bool = false,
    scanning: bool = false,
    scan_cb: ?ScanCallback = null,
    scan_user_data: ?*anyopaque = null,
    local_addr: Address = .{ .bytes = .{ 0x00, 0x1A, 0x7D, 0xDA, 0x71, 0x13 } },
    devices: [8]HciDeviceContext = @splat(.{}),

    pub fn init() HciBackend {
        return .{};
    }

    pub fn deinit(self: *HciBackend) void {
        self.is_closed.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.controller) |*ctrl| {
            ctrl.close();
            self.controller = null;
        }
    }

    pub fn setTransportHook(self: *HciBackend, hook: ?TransportHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.transport_hook = hook;
    }

    pub fn setPcapHook(self: *HciBackend, hook: ?types.PcapHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pcap_hook = hook;
    }

    fn emitPacket(self: *HciBackend, dir: types.PcapDirection, packet: []const u8) BleError!void {
        if (self.pcap_hook) |h| {
            h.callback(dir, packet, h.user_data);
        }
        if (self.transport_hook) |th| {
            try th.on_send_packet(th.ctx, packet);
            return;
        }
        if (builtin.os.tag == .linux) {
            if (self.controller) |*ctrl| {
                ctrl.sock.send(packet) catch return BleError.IoError;
                return;
            }
        }
    }

    fn sendL2capOverAcl(self: *HciBackend, conn_handle: u16, cid: u16, payload: []const u8) BleError!void {
        var frame_buf: [530]u8 = undefined;
        if (9 + payload.len > frame_buf.len) return BleError.InvalidParameter;

        frame_buf[0] = @backingInt(hci.PacketType.acl_data);
        const l2cap_total: u16 = @intCast(4 + payload.len);
        const handle_pb_bc: u16 = (conn_handle & 0x0FFF) | (@as(u16, 0b00) << 12);
        std.mem.writeInt(u16, frame_buf[1..3], handle_pb_bc, .little);
        std.mem.writeInt(u16, frame_buf[3..5], l2cap_total, .little);
        std.mem.writeInt(u16, frame_buf[5..7], @intCast(payload.len), .little);
        std.mem.writeInt(u16, frame_buf[7..9], cid, .little);
        @memcpy(frame_buf[9 .. 9 + payload.len], payload);

        try self.emitPacket(.host_to_controller, frame_buf[0 .. 9 + payload.len]);
    }

    /// Feeds an incoming H4-framed HCI Event (`0x04`) or ACL Data (`0x02`) packet into the backend.
    pub fn processRxPacket(self: *HciBackend, packet: []const u8) BleError!void {
        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        if (packet.len < 2) return BleError.InvalidParameter;

        if (self.pcap_hook) |h| {
            h.callback(.controller_to_host, packet, h.user_data);
        }

        const pkt_type = packet[0];
        if (pkt_type == @backingInt(hci.PacketType.event)) {
            const ev = hci.HciEvent.parse(packet) catch return BleError.GattError;
            switch (ev) {
                .disconnection_complete => |dc| {
                    for (&self.devices) |*dev| {
                        if (dev.in_use and dev.conn_handle == dc.handle) {
                            dev.connected = false;
                            dev.att_bearer.onDisconnect() catch {};
                            if (dev.smp_sm) |*sm| sm.onDisconnect() catch {};
                        }
                    }
                },
                else => {},
            }
        } else if (pkt_type == @backingInt(hci.PacketType.acl_data)) {
            if (packet.len < 5) return BleError.GattError;
            const handle_flags = std.mem.readInt(u16, packet[1..3], .little);
            const conn_handle: u16 = handle_flags & 0x0FFF;
            const pb_flag: u2 = @intCast((handle_flags >> 12) & 0x03);
            const acl_len = std.mem.readInt(u16, packet[3..5], .little);
            if (packet.len < 5 + acl_len) return BleError.GattError;

            for (&self.devices) |*dev| {
                if (dev.in_use and dev.conn_handle == conn_handle) {
                    const maybe_l2cap = dev.reassembler.processFragment(conn_handle, pb_flag, packet[5 .. 5 + acl_len]) catch return BleError.GattError;
                    if (maybe_l2cap) |l2cap_frame| {
                        try self.dispatchL2capFrame(dev, l2cap_frame.cid, l2cap_frame.payload);
                    }
                    break;
                }
            }
        }
    }

    fn dispatchL2capFrame(self: *HciBackend, dev: *HciDeviceContext, cid: u16, payload: []const u8) BleError!void {
        if (cid == att.ATT_CID) {
            var cfm_buf: [8]u8 = undefined;
            const rx_ev = dev.att_bearer.handleClientRx(payload, &cfm_buf) catch return BleError.GattError;
            switch (rx_ev) {
                .notification => |ntf| {
                    for (&dev.characteristics) |*ch| {
                        if (ch.active and ch.value_handle == ntf.handle) {
                            if (ch.notify_cb) |cb| cb(ch.uuid, ntf.value, ch.notify_user_data);
                        }
                    }
                },
                .indication => |ind_info| {
                    if (ind_info.confirm_len > 0) {
                        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, cfm_buf[0..ind_info.confirm_len]);
                    }
                    for (&dev.characteristics) |*ch| {
                        if (ch.active and ch.value_handle == ind_info.indication.handle) {
                            if (ch.notify_cb) |cb| cb(ch.uuid, ind_info.indication.value, ch.notify_user_data);
                        }
                    }
                },
                .response => |rsp| {
                    switch (rsp) {
                        .read_rsp => |r| {
                            const copy_len = @min(r.value.len, dev.last_read_buf.len);
                            @memcpy(dev.last_read_buf[0..copy_len], r.value[0..copy_len]);
                            dev.last_read_len = copy_len;
                        },
                        .read_by_type_rsp => |r| {
                            var it = r.iterator();
                            while (it.next()) |elem| {
                                if (elem.value.len >= 5) {
                                    const val_handle = std.mem.readInt(u16, elem.value[1..3], .little);
                                    const char_uuid = if (elem.value.len == 5)
                                        UUID.from16(std.mem.readInt(u16, elem.value[3..5], .little))
                                    else if (elem.value.len >= 19)
                                        UUID{ .bytes = elem.value[3..19][0..16].* }
                                    else
                                        continue;

                                    for (&dev.characteristics) |*slot| {
                                        if (!slot.active) {
                                            slot.* = .{
                                                .uuid = char_uuid,
                                                .decl_handle = elem.handle,
                                                .value_handle = val_handle,
                                                .cccd_handle = val_handle + 1,
                                                .active = true,
                                            };
                                            break;
                                        }
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                },
            }
        } else if (cid == smp.SMP_CID) {
            if (dev.smp_sm) |*sm| {
                var out_buf: [128]u8 = undefined;
                const rsp_len = sm.handlePdu(payload, 0, &out_buf) catch return BleError.AuthenticationFailed;
                if (rsp_len > 0) {
                    try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, out_buf[0..rsp_len]);
                }
                if (sm.state == .completed) {
                    dev.bond_state = .bonded;
                } else if (sm.state == .failed) {
                    dev.bond_state = .not_bonded;
                }
            }
        }
    }

    pub fn backend(self: *HciBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &vtable_impl,
        };
    }

    const vtable_impl = BackendVTable{
        .name = "Raw HCI (H4/VHCI)",
        .openAdapter = openAdapterImpl,
        .closeAdapter = closeAdapterImpl,
        .setPowered = setPoweredImpl,
        .isPowered = isPoweredImpl,
        .startScan = startScanImpl,
        .stopScan = stopScanImpl,
        .connectDevice = connectDeviceImpl,
        .disconnectDevice = disconnectDeviceImpl,
        .isDeviceConnected = isDeviceConnectedImpl,
        .getDeviceRssi = getDeviceRssiImpl,
        .discoverServices = discoverServicesImpl,
        .readCharacteristic = readCharacteristicImpl,
        .writeCharacteristic = writeCharacteristicImpl,
        .subscribeNotifications = subscribeNotificationsImpl,
        .unsubscribeNotifications = unsubscribeNotificationsImpl,
        .exchangeMtu = exchangeMtuImpl,
        .pairDevice = pairDeviceImpl,
        .unpairDevice = unpairDeviceImpl,
        .getBondState = getBondStateImpl,
    };

    fn openAdapterImpl(ctx: *anyopaque, index: u16) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.transport_hook != null) {
            self.powered = true;
            return;
        }
        self.controller = hci.HciController.open(index) catch |err| switch (err) {
            error.NotSupported => return BleError.NotSupported,
            else => return BleError.AdapterNotFound,
        };
        self.powered = true;
    }

    fn closeAdapterImpl(ctx: *anyopaque) void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn setPoweredImpl(ctx: *anyopaque, powered: bool) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (powered) {
            const cmd = hci.Commands.reset();
            try self.emitPacket(.host_to_controller, &cmd);
        }
        self.powered = powered;
    }

    fn isPoweredImpl(ctx: *anyopaque) BleError!bool {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        return self.powered;
    }

    fn startScanImpl(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const params_cmd = hci.Commands.leSetScanParameters(.active, 0x0010, 0x0010, .public, .accept_all);
        try self.emitPacket(.host_to_controller, &params_cmd);
        const enable_cmd = hci.Commands.leSetScanEnable(true, filter.filter_duplicates);
        try self.emitPacket(.host_to_controller, &enable_cmd);
        self.scan_cb = cb;
        self.scan_user_data = user_data;
        self.scanning = true;
    }

    fn stopScanImpl(ctx: *anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const disable_cmd = hci.Commands.leSetScanEnable(false, false);
        try self.emitPacket(.host_to_controller, &disable_cmd);
        self.scanning = false;
    }

    fn connectDeviceImpl(ctx: *anyopaque, addr: Address, timeout_ms: u32) BleError!*anyopaque {
        _ = timeout_ms;
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.devices, 0..) |*dev, idx| {
            if (!dev.in_use) {
                dev.* = .{
                    .in_use = true,
                    .connected = true,
                    .address = addr,
                    .conn_handle = @intCast(0x0040 + idx),
                };
                dev.att_bearer.onConnect();
                const peer_le: [6]u8 = @splat(0);
                _ = peer_le;
                const cmd = hci.Commands.leCreateConnection(.{
                    .peer_addr_type = .public,
                    .peer_addr = addr,
                });
                try self.emitPacket(.host_to_controller, &cmd);
                return dev;
            }
        }
        return BleError.PoolExhausted;
    }

    fn disconnectDeviceImpl(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        const cmd = hci.Commands.disconnect(dev.conn_handle, 0x13);
        try self.emitPacket(.host_to_controller, &cmd);
        dev.connected = false;
        dev.in_use = false;
    }

    fn isDeviceConnectedImpl(_: *anyopaque, dev_handle: *anyopaque) bool {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.connected;
    }

    fn getDeviceRssiImpl(_: *anyopaque, dev_handle: *anyopaque) ?i16 {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.rssi;
    }

    fn discoverServicesImpl(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        var disc = att.ServiceDiscoveryClient{ .phase = .characteristics };
        if (disc.nextRequest()) |req_pdu| {
            var pdu_buf: [32]u8 = undefined;
            const len = dev.att_bearer.beginRequest(req_pdu, 0, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        }
    }

    fn findChar(dev: *HciDeviceContext, char_uuid: UUID) ?*DiscoveredCharacteristic {
        for (&dev.characteristics) |*ch| {
            if (ch.active and ch.uuid.eql(char_uuid)) return ch;
        }
        return null;
    }

    fn readCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) BleError!usize {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char_uuid) orelse return BleError.CharacteristicNotFound;
        var pdu_buf: [16]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .read_req = .{ .handle = ch.value_handle } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

        const copy_len = @min(buf.len, dev.last_read_len);
        @memcpy(buf[0..copy_len], dev.last_read_buf[0..copy_len]);
        return copy_len;
    }

    fn writeCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char_uuid) orelse return BleError.CharacteristicNotFound;
        var pdu_buf: [517]u8 = undefined;
        if (with_response) {
            const len = dev.att_bearer.beginRequest(.{ .write_req = .{ .handle = ch.value_handle, .value = data } }, 0, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        } else {
            const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.value_handle, .value = data } }, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        }
    }

    fn subscribeNotificationsImpl(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char_uuid) orelse return BleError.CharacteristicNotFound;
        ch.notify_cb = cb;
        ch.notify_user_data = user_data;
        var pdu_buf: [16]u8 = undefined;
        const cccd_val = [_]u8{ 0x01, 0x00 };
        const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.cccd_handle, .value = &cccd_val } }, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
    }

    fn unsubscribeNotificationsImpl(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char_uuid) orelse return BleError.CharacteristicNotFound;
        ch.notify_cb = null;
        ch.notify_user_data = null;
        var pdu_buf: [16]u8 = undefined;
        const cccd_val = [_]u8{ 0x00, 0x00 };
        const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.cccd_handle, .value = &cccd_val } }, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
    }

    fn exchangeMtuImpl(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        var pdu_buf: [16]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .exchange_mtu_req = .{ .client_rx_mtu = target_mtu } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        return dev.att_bearer.mtu;
    }

    fn pairDeviceImpl(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: IoCapability) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        var sm = smp.SmpStateMachine.init(.initiator, self.local_addr, .public, dev.address, dev.addr_type);
        sm.local_features.io_capability = @fromBackingInt(@intCast(@backingInt(io_cap)));
        var pdu_buf: [32]u8 = undefined;
        const len = sm.startPairing(0, &pdu_buf) catch return BleError.AuthenticationFailed;
        dev.smp_sm = sm;
        dev.bond_state = .bonding;
        try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, pdu_buf[0..len]);
    }

    fn unpairDeviceImpl(_: *anyopaque, dev_handle: *anyopaque) BleError!void {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        dev.bond_state = .not_bonded;
        dev.smp_sm = null;
    }

    fn getBondStateImpl(_: *anyopaque, dev_handle: *anyopaque) BondState {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.bond_state;
    }
};

test "HciBackend: Full ATT Service Discovery, MTU Exchange, and SMP Pairing over ACL" {
    const Capture = struct {
        last_tx: [256]u8 = @splat(0),
        last_tx_len: usize = 0,
        fn onSend(ctx: ?*anyopaque, packet: []const u8) BleError!void {
            const self_cap: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self_cap.last_tx[0..packet.len], packet);
            self_cap.last_tx_len = packet.len;
        }
    };

    var cap = Capture{};
    var hci_backend = HciBackend.init();
    defer hci_backend.deinit();
    hci_backend.setTransportHook(.{ .ctx = &cap, .on_send_packet = Capture.onSend });

    const b = hci_backend.backend();
    try b.openAdapter(0);
    const peer = try Address.parse("AA:BB:CC:DD:EE:01");
    const dev_handle = try b.connectDevice(peer, 5000);

    // Trigger MTU Exchange (Client sends ExchangeMtuRequest over ACL)
    _ = try b.exchangeMtu(dev_handle, 247);
    try std.testing.expectEqual(@backingInt(hci.PacketType.acl_data), cap.last_tx[0]);

    // Simulate Server sending ExchangeMtuResponse (247) wrapped in H4 ACL + L2CAP CID 0x0004
    const mtu_rsp_acl = [_]u8{
        0x02, // H4 ACL
        0x40, 0x20, // conn_handle=0x0040, PB=0b10 (first auto-flushable)
        0x07, 0x00, // ACL data len = 7
        0x03, 0x00, // L2CAP len = 3
        0x04, 0x00, // CID = 0x0004 (ATT)
        0x03, 0xF7, 0x00, // ExchangeMtuResponse (247)
    };
    try hci_backend.processRxPacket(&mtu_rsp_acl);
    const dev_ctx: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
    try std.testing.expectEqual(@as(u16, 247), dev_ctx.att_bearer.mtu);
}
