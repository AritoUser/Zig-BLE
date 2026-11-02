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

const log = std.log.scoped(.zig_ble);
const gatt = @import("hci_gatt.zig");
const pairing = @import("hci_pairing.zig");

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

pub const cccd_uuid = UUID.from16(0x2902);

pub const DiscoveredCharacteristic = struct {
    uuid: UUID = UUID.from16(0),
    service_uuid: UUID = UUID.from16(0),
    decl_handle: u16 = 0,
    value_handle: u16 = 0,
    /// 0 if the characteristic has no CCCD. Found by discovery, never assumed.
    cccd_handle: u16 = 0,
    properties: core.CharacteristicProperties = .{},
    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,
    active: bool = false,
};

pub const DiscoveredService = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: UUID,
};

pub const DiscoveredDescriptor = struct {
    handle: u16,
    uuid: UUID,
    /// Value handle of the characteristic it belongs to.
    owner_value_handle: u16,
};

pub const HciDeviceContext = struct {
    in_use: bool = false,
    connected: bool = false,
    connection_state: std.atomic.Value(ConnectionState) = .init(.disconnected),
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

    services: [16]DiscoveredService = undefined,
    services_len: usize = 0,
    descriptors: [32]DiscoveredDescriptor = undefined,
    descriptors_len: usize = 0,
    discovery_overflow: bool = false,
    saved_subscriptions: types.SavedSubscriptions = .{},

    pending_connect: bool = false,
    /// The current ATT request has its response (or error).
    op_done: bool = false,
    pending_disc: bool = false,
    disc: att.ServiceDiscoveryClient = .{},
    last_att_error: ?att.AttErrorCode = null,
    encrypting: bool = false,
    encrypted: bool = false,
    pairing_done: bool = false,
};

pub const TransportHook = struct {
    ctx: ?*anyopaque = null,
    on_send_packet: *const fn (ctx: ?*anyopaque, packet: []const u8) BleError!void,
    /// Delivers pending packets to `processRxPacket`. Without it the backend cannot wait for
    /// the controller, so `connect` returns `NotSupported`.
    poll_packet: ?*const fn (ctx: ?*anyopaque, timeout_ms: u32) BleError!void = null,
    /// For tests that feed packets by hand: `connect` succeeds at once, requests do not wait.
    assume_connected: bool = false,
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
    scan_filter: ScanFilter = .{},
    /// Merged advertisement data, also the source of each device's address type for `connect`.
    scan_cache: types.ScanCache = .{},
    pairing_callbacks: types.PairingCallbacks = .{},
    /// Public address of the controller. It enters the SMP key derivation, so pairing fails
    /// with a wrong value: read from the controller on open, set by hand for other transports.
    local_addr: Address = .{ .bytes = @splat(0) },
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

    pub fn setPairingCallbacks(self: *HciBackend, callbacks: types.PairingCallbacks) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pairing_callbacks = callbacks;
    }

    pub fn setLocalAddress(self: *HciBackend, address: Address) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.local_addr = address;
    }

    pub fn setPcapHook(self: *HciBackend, hook: ?types.PcapHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pcap_hook = hook;
    }

    fn assumeConnected(self: *const HciBackend) bool {
        return if (self.transport_hook) |th| th.assume_connected else false;
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

    pub fn emitPacket(self: *HciBackend, dir: types.PcapDirection, packet: []const u8) BleError!void {
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

    /// Frames an L2CAP PDU as ACL packets no larger than the controller's buffer.
    pub fn sendL2capOverAcl(self: *HciBackend, conn_handle: u16, cid: u16, payload: []const u8) BleError!void {
        var l2cap_buf: [530]u8 = undefined;
        if (4 + payload.len > l2cap_buf.len) return BleError.InvalidParameter;
        std.mem.writeInt(u16, l2cap_buf[0..2], @intCast(payload.len), .little);
        std.mem.writeInt(u16, l2cap_buf[2..4], cid, .little);
        @memcpy(l2cap_buf[4 .. 4 + payload.len], payload);
        const frame = l2cap_buf[0 .. 4 + payload.len];

        const max_fragment: usize = @max(27, self.flow.max_packet_length);
        var offset: usize = 0;
        while (offset < frame.len) {
            const fragment = frame[offset..@min(frame.len, offset + max_fragment)];
            const pb_flag: u16 = if (offset == 0) 0b00 else 0b01;
            var frame_buf: [535]u8 = undefined;
            frame_buf[0] = @backingInt(hci.PacketType.acl_data);
            std.mem.writeInt(u16, frame_buf[1..3], (conn_handle & 0x0FFF) | (pb_flag << 12), .little);
            std.mem.writeInt(u16, frame_buf[3..5], @intCast(fragment.len), .little);
            @memcpy(frame_buf[5 .. 5 + fragment.len], fragment);
            try self.emitPacket(.host_to_controller, frame_buf[0 .. 5 + fragment.len]);
            offset += fragment.len;
        }
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
                                dev.connection_state.store(.connected, .release);
                                dev.pending_connect = false;
                                dev.att_bearer.onConnect();
                                self.flow.registerConnection(cc.handle);
                            } else {
                                dev.connected = false;
                                dev.connection_state.store(.disconnected, .release);
                                dev.pending_connect = false;
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
                                dev.connection_state.store(.connected, .release);
                                dev.pending_connect = false;
                                dev.att_bearer.onConnect();
                                self.flow.registerConnection(ecc.handle);
                            } else {
                                dev.connected = false;
                                dev.connection_state.store(.disconnected, .release);
                                dev.pending_connect = false;
                            }
                            break;
                        }
                    }
                },
                .disconnection_complete => |dc| {
                    for (&self.devices) |*dev| {
                        if (dev.in_use and dev.conn_handle == dc.handle) {
                            dev.connected = false;
                            dev.connection_state.store(.disconnected, .release);
                            dev.pending_connect = false;
                            dev.pending_disc = false;
                            self.flow.onDisconnectionComplete(dc.handle);
                            dev.att_bearer.onDisconnect() catch {};
                            if (dev.smp_sm) |*sm| {
                                sm.onDisconnect() catch {};
                                if (dev.bond_state == .bonding) dev.bond_state = .not_bonded;
                                dev.pairing_done = true;
                            }
                            endSubscriptionsWithLink(dev);
                        }
                    }
                },
                .encryption_change => |ec| {
                    try pairing.onEncryptionChange(self, ec.handle, ec.status == .success and ec.encryption_enabled != 0);
                },
                .number_of_completed_packets => |mut_it| {
                    self.flow.onNumberOfCompletedPackets(mut_it);
                },
                .le_advertising_report => |mut_it| {
                    if (self.scanning and self.scan_cb != null) {
                        var it = mut_it;
                        while (it.next()) |rep| {
                            const disc = self.scan_cache.get(rep.address);
                            disc.address_type = rep.address_type;
                            disc.rssi = rep.rssi;
                            var replaced_uuids = false;
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
                                    .service_data_32bit => {
                                        if (elem.data.len >= 4) {
                                            const u = UUID.from32(std.mem.readInt(u32, elem.data[0..4], .little));
                                            disc.setServiceData(u, elem.data[4..]);
                                        }
                                    },
                                    .service_data_128bit => {
                                        if (elem.data.len >= 16) {
                                            disc.setServiceData(.fromLittleEndian(elem.data[0..16].*), elem.data[16..]);
                                        }
                                    },
                                    .complete_16bit_service_uuids, .incomplete_16bit_service_uuids => {
                                        if (!replaced_uuids) disc.service_uuids_len = 0;
                                        replaced_uuids = true;
                                        var u_idx: usize = 0;
                                        while (u_idx + 2 <= elem.data.len) : (u_idx += 2) {
                                            const u = UUID.from16(std.mem.readInt(u16, elem.data[u_idx..][0..2], .little));
                                            _ = disc.addServiceUuid(u);
                                        }
                                    },
                                    .complete_128bit_service_uuids, .incomplete_128bit_service_uuids => {
                                        if (!replaced_uuids) disc.service_uuids_len = 0;
                                        replaced_uuids = true;
                                        var u_idx: usize = 0;
                                        while (u_idx + 16 <= elem.data.len) : (u_idx += 16) {
                                            _ = disc.addServiceUuid(.fromLittleEndian(elem.data[u_idx..][0..16].*));
                                        }
                                    },
                                    else => {},
                                }
                            }
                            if (self.scan_filter.matches(disc)) self.scan_cb.?(disc, self.scan_user_data);
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
            const rx_ev = dev.att_bearer.handleClientRx(payload, &cfm_buf) catch {
                // The bearer reports a peer's Error Response as a Zig error.
                if (payload.len >= 5 and payload[0] == @intFromEnum(att.AttOpcode.error_rsp)) {
                    return gatt.onAttError(self, dev, @enumFromInt(payload[4]));
                }
                return BleError.GattError;
            };
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
                .response => |rsp| try gatt.onAttResponse(self, dev, rsp),
            }
        } else if (cid == smp.SMP_CID) {
            if (dev.smp_sm) |*sm| {
                var out_buf: [128]u8 = undefined;
                const rsp_len = sm.handlePdu(payload, 0, &out_buf) catch return BleError.AuthenticationFailed;
                if (rsp_len > 0) {
                    try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, out_buf[0..rsp_len]);
                }
                try pairing.advancePairing(self, dev);
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
        if (self.controller) |*ctrl| {
            if (ctrl.readBdAddr()) |addr| {
                self.local_addr = addr;
            } else |err| log.warn("Reading the controller address failed: {s}; pairing will not work", .{@errorName(err)});
            if (ctrl.queryLeBufferSize()) |_| {
                self.flow = ctrl.flow;
            } else |err| log.warn("Reading the controller buffer size failed: {s}", .{@errorName(err)});
        }
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
        self.scan_filter = filter;
        self.scan_cache.reset();
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
        if (!self.shouldWait() and !self.assumeConnected()) {
            log.warn("HciBackend needs a transport that can poll for events; connect cannot wait otherwise", .{});
            return BleError.NotSupported;
        }

        const dev = self.allocateSlot(addr) orelse return BleError.PoolExhausted;
        const auto_resubscribe = dev.auto_resubscribe;
        var saved = dev.saved_subscriptions;
        if (auto_resubscribe) saved.capture(dev.characteristics[0..dev.characteristics_len]);

        // BLE devices mostly use random addresses; the type comes from their advertisements.
        const addr_type: AddressType = if (self.scan_cache.find(addr)) |seen| seen.address_type else .public;
        dev.* = .{
            .in_use = true,
            .connected = false,
            .connection_state = .init(.connecting),
            .pending_connect = true,
            .address = addr,
            .addr_type = addr_type,
            .conn_handle = dev.conn_handle,
            .auto_resubscribe = auto_resubscribe,
            .saved_subscriptions = saved,
        };
        const cmd = hci.Commands.leCreateConnection(.{
            .peer_addr_type = if (addr_type == .public) .public else .random,
            .peer_addr = addr,
        });
        try self.emitPacket(.host_to_controller, &cmd);

        if (!self.shouldWait()) {
            dev.connected = true;
            dev.connection_state.store(.connected, .release);
            dev.pending_connect = false;
            dev.att_bearer.onConnect();
            return @ptrCast(dev);
        }

        const eff_timeout = if (timeout_ms == 0) self.timeouts.connect_ms else timeout_ms;
        self.waitUntil(dev, &dev.pending_connect, false, eff_timeout);
        if (dev.pending_connect) {
            dev.pending_connect = false;
            dev.connection_state.store(.disconnected, .release);
            const cancel = hci.Commands.leCreateConnectionCancel();
            try self.emitPacket(.host_to_controller, &cancel);
            return BleError.ConnectionTimeout;
        }
        if (!dev.connected) {
            dev.connection_state.store(.disconnected, .release);
            return BleError.ConnectionFailed;
        }

        // A peer forgets subscriptions with the link, and handles may have changed.
        if (auto_resubscribe and saved.len > 0) {
            self.discover(dev, &.{}) catch |err| log.warn("HCI discovery for resubscribing failed: {s}", .{@errorName(err)});
            for (saved.slice()) |sub| {
                self.subscribe(dev, sub.char, sub.cb, sub.user_data) catch |err| {
                    log.warn("HCI resubscribe to {f} failed: {s}", .{ sub.char.uuid, @errorName(err) });
                };
            }
            dev.saved_subscriptions.clear();
        }
        return @ptrCast(dev);
    }

    /// The device's old slot, a free one, or that of a disconnected device.
    fn allocateSlot(self: *HciBackend, addr: Address) ?*HciDeviceContext {
        for (&self.devices) |*dev| {
            if (dev.in_use and dev.address.eql(addr)) return dev;
        }
        for (&self.devices, 0..) |*dev, idx| {
            if (!dev.in_use) {
                dev.* = .{ .conn_handle = @intCast(0x0040 + idx) };
                return dev;
            }
        }
        for (&self.devices) |*dev| {
            if (!dev.connected) {
                dev.auto_resubscribe = false;
                dev.characteristics_len = 0;
                dev.saved_subscriptions.clear();
                return dev;
            }
        }
        return null;
    }

    fn disconnectDeviceImpl(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();

        dev.connection_state.store(.disconnecting, .release);
        const cmd = hci.Commands.disconnect(dev.conn_handle, 0x13);
        try self.emitPacket(.host_to_controller, &cmd);

        dev.connected = false;
        dev.connection_state.store(.disconnected, .release);
        dev.att_bearer.onDisconnect() catch {};
        endSubscriptionsWithLink(dev);
    }

    fn endSubscriptionsWithLink(dev: *HciDeviceContext) void {
        if (dev.auto_resubscribe) return;
        for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
            ch.notify_cb = null;
            ch.notify_user_data = null;
        }
    }

    fn isDeviceConnectedImpl(_: *anyopaque, dev_handle: *anyopaque) bool {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.connected;
    }

    fn getConnectionStateImpl(_: *anyopaque, dev_handle: *anyopaque) ConnectionState {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.connection_state.load(.acquire);
    }

    fn setAutoResubscribeImpl(ctx: *anyopaque, dev_handle: *anyopaque, enabled: bool) void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        dev.auto_resubscribe = enabled;
        if (!enabled) dev.saved_subscriptions.clear();
    }

    fn getDeviceRssiImpl(_: *anyopaque, dev_handle: *anyopaque) ?i16 {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev.rssi;
    }

    fn processEventsImpl(ctx: *anyopaque, timeout_ms: u32) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        return self.pumpEvents(timeout_ms);
    }

    /// Pumps events until `flag.* == expected`, the link drops or `timeout_ms` passes.
    /// Caller holds `mutex`; it is released while pumping so callbacks can call back in.
    fn waitUntil(self: *HciBackend, dev: *HciDeviceContext, flag: *const bool, expected: bool, timeout_ms: u32) void {
        const deadline = nowMs() + @as(i64, timeout_ms);
        while (flag.* != expected and (dev.connected or dev.pending_connect)) {
            const now = nowMs();
            if (now >= deadline) return;
            const rem: u32 = @intCast(@min(50, deadline - now));
            self.mutex.unlock();
            self.pumpEvents(rem) catch {};
            self.mutex.lock();
        }
    }

    /// Sends an ATT request and waits for its response. ATT errors map to the matching
    /// `BleError`, or to `fallback`. With `assume_connected` transports it only sends.
    fn attRequest(self: *HciBackend, dev: *HciDeviceContext, req: att.AttPdu, timeout_ms: u32, fallback: BleError) BleError!void {
        if (!dev.connected) return BleError.NotConnected;
        dev.op_done = false;
        dev.last_att_error = null;
        var pdu_buf: [530]u8 = undefined;
        const len = dev.att_bearer.beginRequest(req, 0, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
        if (!self.shouldWait()) return;

        self.waitUntil(dev, &dev.op_done, true, timeout_ms);
        if (!dev.connected) return BleError.NotConnected;
        if (!dev.op_done) return BleError.Timeout;
        if (dev.last_att_error) |code| return types.bleErrorFromAtt(@intFromEnum(code), fallback);
    }

    fn discoverServicesImpl(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        return discoverServicesFilteredImpl(ctx, dev_handle, &.{});
    }

    fn discoverServicesFilteredImpl(ctx: *anyopaque, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.discover(dev, filter_uuids);
    }

    /// Reads services, characteristics and descriptors; the peer may spread each over many
    /// responses. Subscriptions keep their callbacks if the characteristic is still there.
    fn discover(self: *HciBackend, dev: *HciDeviceContext, filter_uuids: []const UUID) BleError!void {
        if (!dev.connected) return BleError.NotConnected;

        var kept: types.SavedSubscriptions = .{};
        kept.capture(dev.characteristics[0..dev.characteristics_len]);

        dev.characteristics_len = 0;
        dev.services_len = 0;
        dev.descriptors_len = 0;
        dev.discovery_overflow = false;
        dev.last_att_error = null;
        dev.op_done = false;
        dev.pending_disc = true;
        dev.disc = .{};
        try gatt.discoveryStep(self, dev);
        if (!self.shouldWait()) return;

        self.waitUntil(dev, &dev.pending_disc, false, self.timeouts.discovery_ms);
        if (!dev.connected) return BleError.NotConnected;
        if (dev.pending_disc) {
            dev.pending_disc = false;
            return BleError.Timeout;
        }
        if (dev.last_att_error) |code| return types.bleErrorFromAtt(@intFromEnum(code), BleError.GattError);
        if (dev.discovery_overflow) return BleError.PoolExhausted;

        if (filter_uuids.len > 0) {
            var n: usize = 0;
            for (dev.characteristics[0..dev.characteristics_len]) |ch| {
                for (filter_uuids) |wanted| {
                    if (wanted.eql(ch.service_uuid)) {
                        dev.characteristics[n] = ch;
                        n += 1;
                        break;
                    }
                }
            }
            dev.characteristics_len = n;
            if (n == 0) return BleError.ServiceNotFound;
        }

        for (kept.slice()) |sub| {
            const ch = findChar(dev, sub.char) orelse continue;
            ch.notify_cb = sub.cb;
            ch.notify_user_data = sub.user_data;
        }
    }

    fn findChar(dev: *HciDeviceContext, char: CharacteristicSelector) ?*DiscoveredCharacteristic {
        const chars = dev.characteristics[0..dev.characteristics_len];
        const idx = char.find(chars) orelse return null;
        return &chars[idx];
    }

    fn getCharacteristicsImpl(_: *anyopaque, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize {
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev.connected) return BleError.NotConnected;
        return CharacteristicInfo.list(dev.characteristics[0..dev.characteristics_len], out);
    }

    fn copyLastRead(dev: *const HciDeviceContext, buf: []u8) usize {
        const copy_len = @min(buf.len, dev.last_read_len);
        @memcpy(buf[0..copy_len], dev.last_read_buf[0..copy_len]);
        return copy_len;
    }

    fn readCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, buf: []u8) BleError!usize {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        try self.attRequest(dev, .{ .read_req = .{ .handle = ch.value_handle } }, self.timeouts.read_ms, BleError.ReadFailed);
        return copyLastRead(dev, buf);
    }

    fn writeCharacteristicImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        if (with_response) {
            return self.attRequest(dev, .{ .write_req = .{ .handle = ch.value_handle, .value = data } }, self.timeouts.write_ms, BleError.WriteFailed);
        }
        var pdu_buf: [530]u8 = undefined;
        const len = dev.att_bearer.sendCommand(.{ .write_cmd = .{ .handle = ch.value_handle, .value = data } }, &pdu_buf) catch return BleError.GattError;
        try self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
    }

    fn descriptorHandle(dev: *const HciDeviceContext, ch: *const DiscoveredCharacteristic, descriptor: UUID) ?u16 {
        if (descriptor.eql(cccd_uuid)) return if (ch.cccd_handle != 0) ch.cccd_handle else null;
        for (dev.descriptors[0..dev.descriptors_len]) |d| {
            if (d.owner_value_handle == ch.value_handle and d.uuid.eql(descriptor)) return d.handle;
        }
        return null;
    }

    fn readDescriptorImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        const handle = descriptorHandle(dev, ch, descriptor) orelse return BleError.DescriptorNotFound;
        try self.attRequest(dev, .{ .read_req = .{ .handle = handle } }, self.timeouts.read_ms, BleError.ReadFailed);
        return copyLastRead(dev, buf);
    }

    fn writeDescriptorImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        const handle = descriptorHandle(dev, ch, descriptor) orelse return BleError.DescriptorNotFound;
        return self.attRequest(dev, .{ .write_req = .{ .handle = handle, .value = data } }, self.timeouts.write_ms, BleError.WriteFailed);
    }

    /// Enables notifications (or indications, if the characteristic only has those) in its
    /// CCCD. A CCCD accepts only Write Requests, and it is not always the next handle.
    fn subscribe(self: *HciBackend, dev: *HciDeviceContext, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        const ch = findChar(dev, char) orelse return BleError.CharacteristicNotFound;
        if (ch.cccd_handle == 0) return BleError.NotificationFailed;
        const value = [_]u8{ if (ch.properties.notify or !ch.properties.indicate) 0x01 else 0x02, 0x00 };
        ch.notify_cb = cb;
        ch.notify_user_data = user_data;
        self.attRequest(dev, .{ .write_req = .{ .handle = ch.cccd_handle, .value = &value } }, self.timeouts.write_ms, BleError.NotificationFailed) catch |err| {
            ch.notify_cb = null;
            ch.notify_user_data = null;
            return err;
        };
    }

    fn subscribeNotificationsImpl(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;
        return self.subscribe(dev, char, cb, user_data);
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
        if (ch.cccd_handle == 0) return;
        const value = [_]u8{ 0x00, 0x00 };
        return self.attRequest(dev, .{ .write_req = .{ .handle = ch.cccd_handle, .value = &value } }, self.timeouts.write_ms, BleError.NotificationFailed);
    }

    fn exchangeMtuImpl(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.attRequest(dev, .{ .exchange_mtu_req = .{ .client_rx_mtu = target_mtu } }, self.timeouts.mtu_exchange_ms, BleError.MtuExchangeFailed);
        return dev.att_bearer.mtu;
    }

    /// Pairs as initiator: runs SMP, asks the application through `PairingCallbacks`, starts
    /// link encryption and takes the peer's keys. `bonded` is only set once the link is
    /// encrypted. Without the needed callback, Numeric Comparison and Passkey Entry are refused.
    fn pairDeviceImpl(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: IoCapability) BleError!void {
        const self: *HciBackend = @ptrCast(@alignCast(ctx));
        const dev: *HciDeviceContext = @ptrCast(@alignCast(dev_handle));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!dev.connected) return BleError.NotConnected;

        var sm = smp.SmpStateMachine.init(.initiator, self.local_addr, .public, dev.address, dev.addr_type);
        sm.local_features.io_capability = @fromBackingInt(@intCast(@backingInt(io_cap)));
        sm.key_distribution_enabled = true;
        // The host has no keys of its own to hand out yet, but takes the peer's.
        sm.local_features.initiator_key_distribution = .{};
        var pdu_buf: [32]u8 = undefined;
        const len = sm.startPairing(0, &pdu_buf) catch return BleError.AuthenticationFailed;
        dev.smp_sm = sm;
        dev.bond_state = .bonding;
        dev.encrypting = false;
        dev.encrypted = false;
        dev.pairing_done = false;
        try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, pdu_buf[0..len]);
        if (!self.shouldWait()) return;

        self.waitUntil(dev, &dev.pairing_done, true, self.timeouts.pair_ms);
        if (!dev.connected) return BleError.NotConnected;
        if (!dev.pairing_done) return BleError.Timeout;
        if (dev.bond_state != .bonded) return BleError.PairingFailed;
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

test {
    _ = @import("hci_tests.zig");
}
