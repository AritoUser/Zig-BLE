//! # Zig-BLE Raw HCI Backend (`HciBackend`)
//!
//! Full `BackendVTable` implementation combining:
//! - `HciController` (`AF_BLUETOOTH` / `HCI_CHANNEL_RAW` or custom transport hook)
//! - `AclReassembler` & `AclFlowController` (L2CAP framing & controller credit tracking)
//! - `AttBearer` & `ServiceDiscoveryClient` (ATT over L2CAP CID `0x0004`)
//! - `SmpStateMachine` (SMP over L2CAP CID `0x0006`)
//! - Full event pump, connection lifecycle, and auto-resubscribe

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const vtable_mod = @import("vtable.zig");
const hci = @import("../hci/mod.zig");
const l2cap = @import("../l2cap/mod.zig");
const att = @import("../core/att.zig");
const smp = @import("../crypto/smp.zig");
const core = @import("../core/mod.zig");

const Address = types.Address;
const AddressType = types.AddressType;
const UUID = types.UUID;
const BleError = types.BleError;
const ScanFilter = types.ScanFilter;
const ScanCallback = types.ScanCallback;
const NotificationCallback = types.NotificationCallback;
const CharacteristicSelector = types.CharacteristicSelector;
const CharacteristicInfo = types.CharacteristicInfo;
const ConnectionState = types.ConnectionState;
const BondState = types.BondState;
const IoCapability = types.IoCapability;
const Backend = vtable_mod.Backend;
const BackendVTable = vtable_mod.BackendVTable;

pub const DiscoveredCharacteristic = struct {
    uuid: UUID = UUID.from16(0),
    service_uuid: UUID = UUID.from16(0),
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
    connection_state: ConnectionState = .disconnected,
    auto_resubscribe: bool = false,
    address: Address = .{ .bytes = @splat(0) },
    addr_type: AddressType = .public,
    conn_handle: u16 = 0x0040,
    rssi: ?i16 = -55,
    bond_state: BondState = .not_bonded,
    att_bearer: att.AttBearer = .{},
    reassembler: l2cap.AclReassembler(517) = l2cap.AclReassembler(517).init(),
    smp_sm: ?smp.SmpStateMachine = null,
    characteristics: [32]DiscoveredCharacteristic = @splat(.{}),
    characteristics_len: usize = 0,
    last_read_buf: [512]u8 = @splat(0),
    last_read_len: usize = 0,

    pending_connect: bool = false,
    pending_read: bool = false,
    read_completed: bool = false,
    pending_write: bool = false,
    write_completed: bool = false,
    pending_mtu: bool = false,
    mtu_completed: bool = false,
    pending_disc: bool = false,
    disc_completed: bool = false,
    last_att_error: ?att.AttErrorCode = null,
};

pub const TransportHook = struct {
    ctx: ?*anyopaque = null,
    on_send_packet: *const fn (ctx: ?*anyopaque, packet: []const u8) BleError!void,
    poll_packet: ?*const fn (ctx: ?*anyopaque, timeout_ms: u32) BleError!void = null,
};

fn nowMs() i64 {
    if (builtin.os.tag == .windows) {
        return @divFloor(std.os.windows.ntdll.RtlGetSystemTimePrecise(), 10_000);
    } else if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @as(i64, @divTrunc(ts.nsec, 1_000_000));
    } else {
        return 0;
    }
}

pub const HciBackend = struct {
    mutex: types.SyncMutex = .{},
    is_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    controller: ?hci.HciController = null,
    flow: hci.AclFlowController = hci.AclFlowController.init(251, 8),
    transport_hook: ?TransportHook = null,
    pcap_hook: ?types.PcapHook = null,
    timeouts: types.TimeoutConfig = .{},
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

    fn shouldWait(self: *const HciBackend) bool {
        if (self.controller != null) return true;
        if (self.transport_hook) |th| {
            return th.poll_packet != null;
        }
        return false;
    }

    /// Pumps incoming packets from the underlying controller socket or transport hook.
    pub fn pumpEvents(self: *HciBackend, timeout_ms: u32) BleError!void {
        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        if (self.controller) |*ctrl| {
            if (builtin.os.tag == .linux) {
                const poll_to: c_int = @intCast(@min(timeout_ms, @as(u32, std.math.maxInt(c_int))));
                if (ctrl.sock.poll(poll_to) > 0) {
                    var buf: [1024]u8 = undefined;
                    const n = ctrl.sock.readPacket(&buf) catch return BleError.IoError;
                    if (n > 0) {
                        try self.processRxPacket(buf[0..n]);
                    }
                }
            }
            return;
        }
        if (self.transport_hook) |th| {
            if (th.poll_packet) |poll_fn| {
                try poll_fn(th.ctx, timeout_ms);
            }
            return;
        }
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
                .le_connection_complete => |cc| {
                    for (&self.devices) |*dev| {
                        if (dev.in_use and dev.pending_connect and (dev.conn_handle == 0 or dev.address.eql(cc.peer_address))) {
                            if (cc.status == .success) {
                                dev.conn_handle = cc.handle;
                                dev.connected = true;
                                dev.connection_state = .connected;
                                dev.pending_connect = false;
                                dev.att_bearer.onConnect();
                                self.flow.registerConnection(cc.handle);
                                if (dev.auto_resubscribe) {
                                    for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
                                        if (ch.active and ch.notify_cb != null and ch.cccd_handle != 0) {
                                            var pdu_buf: [16]u8 = undefined;
                                            const cccd_val = [_]u8{ 0x01, 0x00 };
                                            const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.cccd_handle, .value = &cccd_val } }, &pdu_buf) catch continue;
                                            self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]) catch {};
                                        }
                                    }
                                }
                            } else {
                                dev.connected = false;
                                dev.connection_state = .disconnected;
                                dev.pending_connect = false;
                                dev.in_use = false;
                            }
                            break;
                        }
                    }
                },
                .le_enhanced_connection_complete => |ecc| {
                    for (&self.devices) |*dev| {
                        if (dev.in_use and dev.pending_connect and (dev.conn_handle == 0 or dev.address.eql(ecc.peer_address))) {
                            if (ecc.status == .success) {
                                dev.conn_handle = ecc.handle;
                                dev.connected = true;
                                dev.connection_state = .connected;
                                dev.pending_connect = false;
                                dev.att_bearer.onConnect();
                                self.flow.registerConnection(ecc.handle);
                            } else {
                                dev.connected = false;
                                dev.connection_state = .disconnected;
                                dev.pending_connect = false;
                                dev.in_use = false;
                            }
                            break;
                        }
                    }
                },
                .disconnection_complete => |dc| {
                    for (&self.devices) |*dev| {
                        if (dev.in_use and dev.conn_handle == dc.handle) {
                            dev.connected = false;
                            dev.connection_state = .disconnected;
                            dev.pending_connect = false;
                            dev.pending_read = false;
                            dev.pending_write = false;
                            dev.pending_mtu = false;
                            self.flow.onDisconnectionComplete(dc.handle);
                            dev.att_bearer.onDisconnect() catch {};
                            if (dev.smp_sm) |*sm| sm.onDisconnect() catch {};
                            if (!dev.auto_resubscribe) {
                                for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
                                    ch.notify_cb = null;
                                    ch.notify_user_data = null;
                                }
                            }
                        }
                    }
                },
                .number_of_completed_packets => |mut_it| {
                    self.flow.onNumberOfCompletedPackets(mut_it);
                },
                .le_advertising_report => |mut_it| {
                    if (self.scanning and self.scan_cb != null) {
                        var it = mut_it;
                        while (it.next()) |rep| {
                            var disc = types.DiscoveredDevice{
                                .address = rep.address,
                                .address_type = rep.address_type,
                                .rssi = rep.rssi,
                            };
                            var ad_it = @import("../core/advertising.zig").AdIterator.init(rep.data);
                            while (ad_it.next()) |elem| {
                                switch (elem.ad_type) {
                                    .complete_local_name, .shortened_local_name => disc.setName(elem.data),
                                    .manufacturer_specific_data => {
                                        if (elem.data.len >= 2) {
                                            const cid = std.mem.readInt(u16, elem.data[0..2], .little);
                                            disc.setManufacturerData(cid, elem.data[2..]);
                                        }
                                    },
                                    .tx_power_level => {
                                        if (elem.data.len >= 1) disc.tx_power = @as(i8, @bitCast(elem.data[0]));
                                    },
                                    .service_data_16bit => {
                                        if (elem.data.len >= 2) {
                                            const u = UUID.from16(std.mem.readInt(u16, elem.data[0..2], .little));
                                            disc.setServiceData(u, elem.data[2..]);
                                        }
                                    },
                                    .complete_16bit_service_uuids, .incomplete_16bit_service_uuids => {
                                        var u_idx: usize = 0;
                                        while (u_idx + 2 <= elem.data.len) : (u_idx += 2) {
                                            const u = UUID.from16(std.mem.readInt(u16, elem.data[u_idx..][0..2], .little));
                                            _ = disc.addServiceUuid(u);
                                        }
                                    },
                                    else => {},
                                }
                            }
                            self.scan_cb.?(&disc, self.scan_user_data);
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
                    for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
                        if (ch.active and ch.value_handle == ntf.handle) {
                            if (ch.notify_cb) |cb| cb(ch.uuid, ntf.value, ch.notify_user_data);
                        }
                    }
                },
                .indication => |ind_info| {
                    if (ind_info.confirm_len > 0) {
                        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, cfm_buf[0..ind_info.confirm_len]);
                    }
                    for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
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
                            dev.read_completed = true;
                            dev.pending_read = false;
                        },
                        .write_rsp => {
                            dev.write_completed = true;
                            dev.pending_write = false;
                        },
                        .exchange_mtu_rsp => |r| {
                            dev.att_bearer.mtu = @min(dev.att_bearer.local_max_mtu, r.server_rx_mtu);
                            dev.mtu_completed = true;
                            dev.pending_mtu = false;
                        },
                        .error_rsp => |err_rsp| {
                            dev.last_att_error = err_rsp.error_code;
                            dev.read_completed = true;
                            dev.write_completed = true;
                            dev.mtu_completed = true;
                            dev.disc_completed = true;
                            dev.pending_read = false;
                            dev.pending_write = false;
                            dev.pending_mtu = false;
                            dev.pending_disc = false;
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

                                    if (dev.characteristics_len < dev.characteristics.len) {
                                        dev.characteristics[dev.characteristics_len] = .{
                                            .uuid = char_uuid,
                                            .decl_handle = elem.handle,
                                            .value_handle = val_handle,
                                            .cccd_handle = val_handle + 1,
                                            .active = true,
                                        };
                                        dev.characteristics_len += 1;
                                    }
                                }
                            }
                            dev.disc_completed = true;
                            dev.pending_disc = false;
                        },
                        .read_by_group_type_rsp => {
                            dev.disc_completed = true;
                            dev.pending_disc = false;
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
        .processEvents = processEventsImpl,
        .getConnectionState = getConnectionStateImpl,
        .setAutoResubscribe = setAutoResubscribeImpl,
        .discoverServicesFiltered = discoverServicesFilteredImpl,
        .getCharacteristics = getCharacteristicsImpl,
        .readDescriptor = readDescriptorImpl,
        .writeDescriptor = writeDescriptorImpl,
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
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.devices, 0..) |*dev, idx| {
            if (!dev.in_use) {
                dev.* = .{
                    .in_use = true,
                    .connected = false,
                    .connection_state = .connecting,
                    .pending_connect = true,
                    .address = addr,
                    .conn_handle = @intCast(0x0040 + idx),
                };
                const cmd = hci.Commands.leCreateConnection(.{
                    .peer_addr_type = .public,
                    .peer_addr = addr,
                });
                try self.emitPacket(.host_to_controller, &cmd);

                if (self.shouldWait()) {
                    const eff_timeout = if (timeout_ms == 0) 5000 else timeout_ms;
                    const start = nowMs();
                    const deadline = start + @as(i64, @intCast(eff_timeout));
                    while (dev.pending_connect) {
                        const now = nowMs();
                        if (now >= deadline) {
                            dev.in_use = false;
                            dev.connection_state = .disconnected;
                            dev.pending_connect = false;
                            return BleError.ConnectionTimeout;
                        }
                        const rem: u32 = @intCast(@min(50, deadline - now));
                        self.mutex.unlock();
                        self.pumpEvents(rem) catch {};
                        self.mutex.lock();
                    }
                    if (!dev.connected) {
                        dev.in_use = false;
                        dev.connection_state = .disconnected;
                        return BleError.ConnectionFailed;
                    }
                } else {
                    if (!dev.connected) {
                        dev.connected = true;
                        dev.connection_state = .connected;
                        dev.pending_connect = false;
                        dev.att_bearer.onConnect();
                    }
                }
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

        dev.connection_state = .disconnecting;
        const cmd = hci.Commands.disconnect(dev.conn_handle, 0x13);
        try self.emitPacket(.host_to_controller, &cmd);

        dev.connected = false;
        dev.connection_state = .disconnected;
        dev.in_use = false;
        dev.att_bearer.onDisconnect() catch {};
        if (!dev.auto_resubscribe) {
            for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
                ch.notify_cb = null;
                ch.notify_user_data = null;
            }
        }
    }

    fn isDeviceConnectedImpl(_: *anyopaque, dev_handle: *anyopaque) bool {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.connected;
    }

    fn getConnectionStateImpl(_: *anyopaque, dev_handle: *anyopaque) ConnectionState {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.connection_state;
    }

    fn setAutoResubscribeImpl(_: *anyopaque, dev_handle: *anyopaque, enabled: bool) void {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        dev.auto_resubscribe = enabled;
    }

    fn getDeviceRssiImpl(_: *anyopaque, dev_handle: *anyopaque) ?i16 {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.rssi;
    }

    fn discoverServicesImpl(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        return discoverServicesFilteredImpl(ctx, dev_handle, &.{});
    }

    fn discoverServicesFilteredImpl(ctx: *anyopaque, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        dev.pending_disc = true;
        dev.disc_completed = false;
        dev.last_att_error = null;

        var disc = att.ServiceDiscoveryClient{ .phase = .characteristics };
        if (disc.nextRequest()) |req_pdu| {
            var pdu_buf: [32]u8 = undefined;
            const len = dev.att_bearer.beginRequest(req_pdu, 0, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        }

        if (self.shouldWait()) {
            const start = nowMs();
            const deadline = start + 5000;
            while (!dev.disc_completed and dev.last_att_error == null and dev.connected) {
                const now = nowMs();
                if (now >= deadline) return BleError.Timeout;
                const rem: u32 = @intCast(@min(50, deadline - now));
                self.mutex.unlock();
                self.pumpEvents(rem) catch {};
                self.mutex.lock();
            }
        }

        if (filter_uuids.len > 0) {
            var kept: usize = 0;
            for (dev.characteristics[0..dev.characteristics_len]) |ch| {
                var matches = false;
                for (filter_uuids) |f_uuid| {
                    if (f_uuid.eql(ch.service_uuid) or f_uuid.eql(ch.uuid)) {
                        matches = true;
                        break;
                    }
                }
                if (matches) {
                    dev.characteristics[kept] = ch;
                    kept += 1;
                }
            }
            dev.characteristics_len = kept;
        }
    }

    fn findChar(dev: *HciDeviceContext, char: CharacteristicSelector) ?*DiscoveredCharacteristic {
        const n = dev.characteristics_len;
        const idx = char.find(dev.characteristics[0..n]) orelse return null;
        return &dev.characteristics[idx];
    }

    fn getCharacteristicsImpl(_: *anyopaque, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev.connected) return BleError.NotConnected;
        var count: usize = 0;
        for (dev.characteristics[0..dev.characteristics_len]) |ch| {
            if (ch.active) {
                if (count < out.len) {
                    out[count] = .{
                        .uuid = ch.uuid,
                        .service_uuid = ch.service_uuid,
                        .instance = 0,
                    };
                }
                count += 1;
            }
        }
        return count;
    }

    fn readCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, buf: []u8) BleError!usize {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        dev.pending_read = true;
        dev.read_completed = false;
        dev.last_att_error = null;

        var pdu_buf: [16]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .read_req = .{ .handle = ch.value_handle } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

        if (self.shouldWait()) {
            const start = nowMs();
            const deadline = start + 5000;
            while (!dev.read_completed and dev.last_att_error == null and dev.connected) {
                const now = nowMs();
                if (now >= deadline) return BleError.Timeout;
                const rem: u32 = @intCast(@min(50, deadline - now));
                self.mutex.unlock();
                self.pumpEvents(rem) catch {};
                self.mutex.lock();
            }
            if (!dev.connected) return BleError.NotConnected;
            if (dev.last_att_error != null) return BleError.ReadFailed;
        }

        const copy_len = @min(buf.len, dev.last_read_len);
        @memcpy(buf[0..copy_len], dev.last_read_buf[0..copy_len]);
        return copy_len;
    }

    fn writeCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        if (with_response) {
            dev.pending_write = true;
            dev.write_completed = false;
            dev.last_att_error = null;
            var pdu_buf: [517]u8 = undefined;
            const len = dev.att_bearer.beginRequest(.{ .write_req = .{ .handle = ch.value_handle, .value = data } }, 0, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

            if (self.shouldWait()) {
                const start = nowMs();
                const deadline = start + 5000;
                while (!dev.write_completed and dev.last_att_error == null and dev.connected) {
                    const now = nowMs();
                    if (now >= deadline) return BleError.Timeout;
                    const rem: u32 = @intCast(@min(50, deadline - now));
                    self.mutex.unlock();
                    self.pumpEvents(rem) catch {};
                    self.mutex.lock();
                }
                if (!dev.connected) return BleError.NotConnected;
                if (dev.last_att_error != null) return BleError.WriteFailed;
            }
        } else {
            var pdu_buf: [517]u8 = undefined;
            const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.value_handle, .value = data } }, &pdu_buf) catch return BleError.GattError;
            try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        }
    }

    fn readDescriptorImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        const target_handle = if (descriptor.eql(UUID.from16(0x2902))) ch.cccd_handle else return BleError.DescriptorNotFound;
        if (target_handle == 0) return BleError.DescriptorNotFound;

        dev.pending_read = true;
        dev.read_completed = false;
        dev.last_att_error = null;
        var pdu_buf: [16]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .read_req = .{ .handle = target_handle } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

        if (self.shouldWait()) {
            const start = nowMs();
            const deadline = start + 5000;
            while (!dev.read_completed and dev.last_att_error == null and dev.connected) {
                const now = nowMs();
                if (now >= deadline) return BleError.Timeout;
                const rem: u32 = @intCast(@min(50, deadline - now));
                self.mutex.unlock();
                self.pumpEvents(rem) catch {};
                self.mutex.lock();
            }
            if (!dev.connected) return BleError.NotConnected;
            if (dev.last_att_error != null) return BleError.ReadFailed;
        }

        const copy_len = @min(buf.len, dev.last_read_len);
        @memcpy(buf[0..copy_len], dev.last_read_buf[0..copy_len]);
        return copy_len;
    }

    fn writeDescriptorImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        const target_handle = if (descriptor.eql(UUID.from16(0x2902))) ch.cccd_handle else return BleError.DescriptorNotFound;
        if (target_handle == 0) return BleError.DescriptorNotFound;

        dev.pending_write = true;
        dev.write_completed = false;
        dev.last_att_error = null;
        var pdu_buf: [517]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .write_req = .{ .handle = target_handle, .value = data } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

        if (self.shouldWait()) {
            const start = nowMs();
            const deadline = start + 5000;
            while (!dev.write_completed and dev.last_att_error == null and dev.connected) {
                const now = nowMs();
                if (now >= deadline) return BleError.Timeout;
                const rem: u32 = @intCast(@min(50, deadline - now));
                self.mutex.unlock();
                self.pumpEvents(rem) catch {};
                self.mutex.lock();
            }
            if (!dev.connected) return BleError.NotConnected;
            if (dev.last_att_error != null) return BleError.WriteFailed;
        }
    }

    fn subscribeNotificationsImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        ch.notify_cb = cb;
        ch.notify_user_data = user_data;
        var pdu_buf: [16]u8 = undefined;
        const cccd_val = [_]u8{ 0x01, 0x00 };
        const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.cccd_handle, .value = &cccd_val } }, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
    }

    fn unsubscribeNotificationsImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
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

        dev.pending_mtu = true;
        dev.mtu_completed = false;
        dev.last_att_error = null;

        var pdu_buf: [16]u8 = undefined;
        const len = dev.att_bearer.beginRequest(.{ .exchange_mtu_req = .{ .client_rx_mtu = target_mtu } }, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);

        if (self.shouldWait()) {
            const start = nowMs();
            const deadline = start + 5000;
            while (!dev.mtu_completed and dev.last_att_error == null and dev.connected) {
                const now = nowMs();
                if (now >= deadline) return BleError.Timeout;
                const rem: u32 = @intCast(@min(50, deadline - now));
                self.mutex.unlock();
                self.pumpEvents(rem) catch {};
                self.mutex.lock();
            }
        }
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

    fn processEventsImpl(ctx: *anyopaque, timeout_ms: u32) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        return self.pumpEvents(timeout_ms);
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

test "HciBackend: Advertising reports, ConnectionState lifecycle, and Auto-Resubscribe" {
    const ScanCollector = struct {
        discovered_count: usize = 0,
        last_device: ?types.DiscoveredDevice = null,
        fn onScan(dev: *const types.DiscoveredDevice, user_data: ?*anyopaque) void {
            const self_sc: *@This() = @ptrCast(@alignCast(user_data.?));
            self_sc.discovered_count += 1;
            self_sc.last_device = dev.*;
        }
    };

    var collector = ScanCollector{};
    var hci_backend = HciBackend.init();
    defer hci_backend.deinit();

    const DummyTx = struct {
        fn onSend(_: ?*anyopaque, _: []const u8) BleError!void {}
    };
    hci_backend.setTransportHook(.{ .ctx = null, .on_send_packet = DummyTx.onSend });

    const b = hci_backend.backend();
    try b.openAdapter(0);

    // 1. Scanning & Adv Report delivery
    try b.startScan(.{}, ScanCollector.onScan, &collector);
    const adv_pkt = [_]u8{
        0x04, 0x3E, 22, // Event 0x3E, len 22
        0x02, // le_advertising_report
        0x01, // 1 report
        0x00, // connectable undirected
        0x00, // public addr
        0x01, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, // addr AA:BB:CC:DD:EE:01
        10, // data len
        0x02, 0x01, 0x06, // flags
        0x06, 0x09, 'P', 'o', 'l', 'a', 'r', // Name
        0xD0, // RSSI = -48
    };
    try hci_backend.processRxPacket(&adv_pkt);
    try std.testing.expectEqual(@as(usize, 1), collector.discovered_count);
    try std.testing.expectEqualStrings("Polar", collector.last_device.?.getName().?);
    try std.testing.expectEqual(@as(i16, -48), collector.last_device.?.rssi);
    try b.stopScan();

    // 2. Connect & ConnectionState
    const peer = try Address.parse("AA:BB:CC:DD:EE:01");
    const dev_handle = try b.connectDevice(peer, 1000);
    try std.testing.expectEqual(ConnectionState.connected, b.getConnectionState(dev_handle));
    try std.testing.expect(b.isDeviceConnected(dev_handle));

    // 3. Setup notification and auto-resubscribe
    b.setAutoResubscribe(dev_handle, true);
    const dev_ctx: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
    dev_ctx.characteristics[0] = .{
        .uuid = UUID.from16(0x2A37),
        .decl_handle = 0x0010,
        .value_handle = 0x0011,
        .cccd_handle = 0x0012,
        .active = true,
    };
    dev_ctx.characteristics_len = 1;

    const DummyNotify = struct {
        fn onNtf(_: UUID, _: []const u8, _: ?*anyopaque) void {}
    };
    try b.subscribeNotifications(dev_handle, UUID.from16(0x2A37), DummyNotify.onNtf, null);
    try std.testing.expect(dev_ctx.characteristics[0].notify_cb != null);

    // 4. Simulate remote disconnect
    const disconn_ev = [_]u8{
        0x04, 0x05, 0x04, // Disconnection Complete
        0x00, // status success
        0x40, 0x00, // handle 0x0040
        0x13, // remote user terminated
    };
    try hci_backend.processRxPacket(&disconn_ev);
    try std.testing.expectEqual(ConnectionState.disconnected, b.getConnectionState(dev_handle));
    try std.testing.expect(!b.isDeviceConnected(dev_handle));
    // Subscription preserved because auto_resubscribe is true
    try std.testing.expect(dev_ctx.characteristics[0].notify_cb != null);

    // 5. Reconnect via LE Connection Complete
    const conn_complete = [_]u8{
        0x04, 0x3E, 19,
        0x01, // le_connection_complete
        0x00, // status success
        0x40, 0x00, // handle
        0x00, 0x00,
        0x01, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA,
        0x18, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00,
    };
    dev_ctx.pending_connect = true;
    try hci_backend.processRxPacket(&conn_complete);
    try std.testing.expectEqual(ConnectionState.connected, b.getConnectionState(dev_handle));
    try std.testing.expect(b.isDeviceConnected(dev_handle));

    // 6. Characteristics list
    var char_list: [8]CharacteristicInfo = undefined;
    const num_chars = try b.getCharacteristics(dev_handle, &char_list);
    try std.testing.expectEqual(@as(usize, 1), num_chars);
    try std.testing.expect(char_list[0].uuid.eql(UUID.from16(0x2A37)));
}

test "HciBackend: Synchronous Read and Write with simulated polling controller" {
    const ControllerSim = struct {
        tx_pdu: [256]u8 = @splat(0),
        tx_len: usize = 0,
        backend_ptr: ?*HciBackend = null,

        fn onSend(ctx: ?*anyopaque, packet: []const u8) BleError!void {
            const self_sim: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self_sim.tx_pdu[0..packet.len], packet);
            self_sim.tx_len = packet.len;
        }

        fn pollPacket(ctx: ?*anyopaque, _: u32) BleError!void {
            const self_sim: *@This() = @ptrCast(@alignCast(ctx.?));
            const b = self_sim.backend_ptr orelse return;

            // If an HCI CreateConnection command was transmitted (H4 Command = 0x01), reply with LE Connection Complete
            if (self_sim.tx_len >= 4 and self_sim.tx_pdu[0] == 0x01) {
                const conn_complete = [_]u8{
                    0x04, 0x3E, 19,
                    0x01, // le_connection_complete
                    0x00, // status success
                    0x40, 0x00, // handle 0x0040
                    0x00, 0x00,
                    0x01, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, // peer addr BB:CC:DD:EE:FF:01
                    0x18, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00,
                };
                self_sim.tx_len = 0;
                try b.processRxPacket(&conn_complete);
                return;
            }

            // If an ATT ReadRequest was transmitted, reply with ReadResponse [0x0B, 0x42]
            if (self_sim.tx_len >= 9 and self_sim.tx_pdu[0] == 0x02 and self_sim.tx_pdu[9] == 0x0A) {
                const read_rsp_acl = [_]u8{
                    0x02, 0x40, 0x20, 0x06, 0x00, 0x02, 0x00, 0x04, 0x00,
                    0x0B, 0x42, // ReadResponse: value = 0x42
                };
                self_sim.tx_len = 0;
                try b.processRxPacket(&read_rsp_acl);
                return;
            }
        }
    };

    var sim = ControllerSim{};
    var hci_backend = HciBackend.init();
    defer hci_backend.deinit();
    sim.backend_ptr = &hci_backend;
    hci_backend.setTransportHook(.{
        .ctx = &sim,
        .on_send_packet = ControllerSim.onSend,
        .poll_packet = ControllerSim.pollPacket,
    });

    const b = hci_backend.backend();
    try b.openAdapter(0);
    const peer = try Address.parse("BB:CC:DD:EE:FF:01");
    const dev_handle = try b.connectDevice(peer, 1000);

    const dev_ctx: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
    dev_ctx.characteristics[0] = .{
        .uuid = UUID.from16(0x2A19), // Battery Level
        .decl_handle = 0x0020,
        .value_handle = 0x0021,
        .active = true,
    };
    dev_ctx.characteristics_len = 1;

    var val_buf: [16]u8 = undefined;
    const bytes_read = try b.readCharacteristic(dev_handle, UUID.from16(0x2A19), &val_buf);
    try std.testing.expectEqual(@as(usize, 1), bytes_read);
    try std.testing.expectEqual(@as(u8, 0x42), val_buf[0]);
}
