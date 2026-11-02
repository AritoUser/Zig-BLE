//! # HciBackend tests
//!
//! `FakeController` plays controller and peripheral over the transport hook: it answers HCI
//! commands, runs a small ATT server that pages its responses like real devices, and pairs
//! through a real `SmpStateMachine`. No radio is involved, so this checks the host's protocol
//! logic, not the behavior of a real controller.

const std = @import("std");
const types = @import("types.zig");
const core = @import("../core/mod.zig");
const hci = @import("../hci/mod.zig");
const smp = @import("../crypto/smp.zig");
const hci_mod = @import("hci.zig");
const Backend = @import("vtable.zig").Backend;

const HciBackend = hci_mod.HciBackend;
const HciDeviceContext = hci_mod.HciDeviceContext;
const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const ConnectionState = types.ConnectionState;
const CharacteristicInfo = types.CharacteristicInfo;
const BondState = types.BondState;

const conn_handle: u16 = 0x0040;
const peer_addr = Address{ .bytes = .{ 0xC1, 0x22, 0x33, 0x44, 0x55, 0x66 } };
const host_addr = Address{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 } };
const vendor_service_le = [16]u8{ 0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80, 0x00, 0x10, 0x00, 0x00, 0xF0, 0xFF, 0xAB, 0xCD };
const vendor_char_le = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };

const FakeController = struct {
    backend: *HciBackend,
    rx: [64][600]u8 = undefined,
    rx_len: [64]usize = undefined,
    rx_head: usize = 0,
    rx_count: usize = 0,

    l2cap: [600]u8 = undefined,
    l2cap_len: usize = 0,
    max_acl_seen: usize = 0,

    connected: bool = false,
    last_peer_addr_type: ?u8 = null,
    create_connection_count: usize = 0,
    /// CCCD values by attribute handle; a peer forgets them with the link.
    cccd: [32]u16 = @splat(0),
    cccd_writes: usize = 0,
    write_commands_to_cccd: usize = 0,

    responder: ?smp.SmpStateMachine = null,
    encrypted_with: ?[16]u8 = null,
    identity_irk: [16]u8 = @splat(0x5A),

    fn poll(ctx: ?*anyopaque, _: u32) BleError!void {
        const self: *FakeController = @ptrCast(@alignCast(ctx.?));
        while (self.rx_count > 0) {
            const i = self.rx_head;
            self.rx_head = (self.rx_head + 1) % self.rx.len;
            self.rx_count -= 1;
            try self.backend.processRxPacket(self.rx[i][0..self.rx_len[i]]);
        }
    }

    fn queue(self: *FakeController, packet: []const u8) void {
        std.debug.assert(self.rx_count < self.rx.len);
        const i = (self.rx_head + self.rx_count) % self.rx.len;
        @memcpy(self.rx[i][0..packet.len], packet);
        self.rx_len[i] = packet.len;
        self.rx_count += 1;
    }

    fn queueL2cap(self: *FakeController, cid: u16, payload: []const u8) void {
        var pkt: [600]u8 = undefined;
        pkt[0] = 0x02;
        std.mem.writeInt(u16, pkt[1..3], conn_handle | (0b10 << 12), .little);
        std.mem.writeInt(u16, pkt[3..5], @intCast(4 + payload.len), .little);
        std.mem.writeInt(u16, pkt[5..7], @intCast(payload.len), .little);
        std.mem.writeInt(u16, pkt[7..9], cid, .little);
        @memcpy(pkt[9 .. 9 + payload.len], payload);
        self.queue(pkt[0 .. 9 + payload.len]);
    }

    fn onSend(ctx: ?*anyopaque, packet: []const u8) BleError!void {
        const self: *FakeController = @ptrCast(@alignCast(ctx.?));
        switch (packet[0]) {
            0x01 => self.onCommand(packet),
            0x02 => self.onAcl(packet),
            else => {},
        }
    }

    fn onCommand(self: *FakeController, packet: []const u8) void {
        const opcode = std.mem.readInt(u16, packet[1..3], .little);
        switch (opcode) {
            0x200D => { // LE Create Connection
                self.last_peer_addr_type = packet[9];
                self.create_connection_count += 1;
                self.connected = true;
                self.cccd = @splat(0);
                // Peer address follows the type in the command, little endian
                self.queue(&[_]u8{
                    0x04, 0x3E, 19, 0x01, 0x00, 0x40, 0x00, 0x00, packet[9],
                    packet[10], packet[11], packet[12], packet[13], packet[14], packet[15], 0x18, 0x00, 0x00,
                    0x00, 0x48, 0x00, 0x00,
                });
            },
            0x0406 => { // Disconnect
                self.connected = false;
                self.queue(&[_]u8{ 0x04, 0x05, 0x04, 0x00, 0x40, 0x00, 0x16 });
            },
            0x2019 => { // LE Enable Encryption: handle(2), rand(8), ediv(2), ltk(16)
                self.encrypted_with = packet[16..32].*;
                self.queue(&[_]u8{ 0x04, 0x08, 0x04, 0x00, 0x40, 0x00, 0x01 });
                if (self.responder) |*r| {
                    r.onLinkEncrypted();
                    if (r.state == .key_distribution) {
                        var out: [64]u8 = undefined;
                        const len = r.distributeIdentityKeys(self.identity_irk, &out) catch 0;
                        if (len > 0) {
                            self.queueL2cap(smp.SMP_CID, out[0..17]);
                            self.queueL2cap(smp.SMP_CID, out[17..len]);
                        }
                        r.finishLocalKeyDistribution();
                    }
                }
            },
            else => {},
        }
    }

    fn onAcl(self: *FakeController, packet: []const u8) void {
        const header = std.mem.readInt(u16, packet[1..3], .little);
        const pb = (header >> 12) & 0b11;
        const len = std.mem.readInt(u16, packet[3..5], .little);
        self.max_acl_seen = @max(self.max_acl_seen, len);
        if (pb == 0b00) self.l2cap_len = 0;
        @memcpy(self.l2cap[self.l2cap_len .. self.l2cap_len + len], packet[5 .. 5 + len]);
        self.l2cap_len += len;

        const expected = 4 + @as(usize, std.mem.readInt(u16, self.l2cap[0..2], .little));
        if (self.l2cap_len < expected) return;
        const cid = std.mem.readInt(u16, self.l2cap[2..4], .little);
        const payload = self.l2cap[4..expected];
        if (cid == 0x0004) self.onAtt(payload);
        if (cid == 0x0006) self.onSmp(payload);
    }

    fn onSmp(self: *FakeController, payload: []const u8) void {
        const r = if (self.responder) |*s| s else return;
        var out: [128]u8 = undefined;
        const len = r.handlePdu(payload, 1, &out) catch return;
        // Public key and first confirm value come back as two PDUs
        if (len == 65 + 17) {
            self.queueL2cap(smp.SMP_CID, out[0..65]);
            self.queueL2cap(smp.SMP_CID, out[65..len]);
        } else if (len > 0) {
            self.queueL2cap(smp.SMP_CID, out[0..len]);
        }
    }

    // GATT database:
    //   0x0001 service 0x180F (end 0x0008)
    //     0x0002 decl -> 0x0003 Battery Level (read, notify), 0x0004 CCCD
    //     0x0005 decl -> 0x0006 vendor 128-bit (read, indicate), 0x0007 User Description, 0x0008 CCCD
    //   0x0010 service vendor 128-bit (end 0x0018)
    //     0x0011 decl -> 0x0012 Report 0x2A4D (notify), 0x0013 CCCD
    //     0x0014 decl -> 0x0015 Report 0x2A4D (notify), 0x0016 CCCD
    //     0x0017 decl -> 0x0018 0x2A05 (no read)
    fn onAtt(self: *FakeController, pdu: []const u8) void {
        switch (pdu[0]) {
            0x02 => self.queueL2cap(0x0004, &[_]u8{ 0x03, 185, 0 }), // MTU
            0x10 => self.readByGroupType(std.mem.readInt(u16, pdu[1..3], .little)),
            0x08 => self.readByType(std.mem.readInt(u16, pdu[1..3], .little)),
            0x04 => self.findInfo(std.mem.readInt(u16, pdu[1..3], .little)),
            0x0A => self.read(std.mem.readInt(u16, pdu[1..3], .little)),
            0x12 => { // Write Request
                const handle = std.mem.readInt(u16, pdu[1..3], .little);
                if (isCccd(handle)) {
                    self.cccd[handle] = std.mem.readInt(u16, pdu[3..5], .little);
                    self.cccd_writes += 1;
                }
                self.queueL2cap(0x0004, &[_]u8{0x13});
            },
            0x52 => { // Write Command, which a CCCD ignores
                const handle = std.mem.readInt(u16, pdu[1..3], .little);
                if (isCccd(handle)) self.write_commands_to_cccd += 1;
            },
            else => {},
        }
    }

    fn isCccd(handle: u16) bool {
        return handle == 0x0004 or handle == 0x0008 or handle == 0x0013 or handle == 0x0016;
    }

    fn attError(self: *FakeController, request: u8, handle: u16, code: u8) void {
        var e = [_]u8{ 0x01, request, 0, 0, code };
        std.mem.writeInt(u16, e[2..4], handle, .little);
        self.queueL2cap(0x0004, &e);
    }

    fn readByGroupType(self: *FakeController, start: u16) void {
        if (start <= 0x0001) {
            self.queueL2cap(0x0004, &[_]u8{ 0x11, 6, 0x01, 0x00, 0x08, 0x00, 0x0F, 0x18 });
        } else if (start <= 0x0010) {
            var rsp = [_]u8{ 0x11, 20, 0x10, 0x00, 0x18, 0x00 } ++ vendor_service_le;
            self.queueL2cap(0x0004, &rsp);
        } else {
            self.attError(0x10, start, 0x0A);
        }
    }

    fn readByType(self: *FakeController, start: u16) void {
        // At most two declarations per response, and 16- and 128-bit UUIDs never share one
        if (start <= 0x0002) {
            self.queueL2cap(0x0004, &[_]u8{ 0x09, 7, 0x02, 0x00, 0x12, 0x03, 0x00, 0x19, 0x2A });
        } else if (start <= 0x0005) {
            const rsp = [_]u8{ 0x09, 21, 0x05, 0x00, 0x22, 0x06, 0x00 } ++ vendor_char_le;
            self.queueL2cap(0x0004, &rsp);
        } else if (start <= 0x0011) {
            self.queueL2cap(0x0004, &[_]u8{
                0x09, 7, 0x11, 0x00, 0x10, 0x12, 0x00, 0x4D, 0x2A,
                0x14, 0x00, 0x10, 0x15, 0x00, 0x4D, 0x2A,
            });
        } else if (start <= 0x0017) {
            self.queueL2cap(0x0004, &[_]u8{ 0x09, 7, 0x17, 0x00, 0x20, 0x18, 0x00, 0x05, 0x2A });
        } else {
            self.attError(0x08, start, 0x0A);
        }
    }

    fn findInfo(self: *FakeController, start: u16) void {
        if (start <= 0x0004) {
            self.queueL2cap(0x0004, &[_]u8{ 0x05, 1, 0x03, 0x00, 0x19, 0x2A, 0x04, 0x00, 0x02, 0x29 });
        } else if (start <= 0x0008) {
            self.queueL2cap(0x0004, &[_]u8{ 0x05, 1, 0x07, 0x00, 0x01, 0x29, 0x08, 0x00, 0x02, 0x29 });
        } else if (start <= 0x0013) {
            self.queueL2cap(0x0004, &[_]u8{ 0x05, 1, 0x12, 0x00, 0x4D, 0x2A, 0x13, 0x00, 0x02, 0x29 });
        } else if (start <= 0x0016) {
            self.queueL2cap(0x0004, &[_]u8{ 0x05, 1, 0x15, 0x00, 0x4D, 0x2A, 0x16, 0x00, 0x02, 0x29 });
        } else {
            self.attError(0x04, start, 0x0A);
        }
    }

    fn read(self: *FakeController, handle: u16) void {
        switch (handle) {
            0x0003 => self.queueL2cap(0x0004, &[_]u8{ 0x0B, 90 }),
            0x0006 => self.queueL2cap(0x0004, &[_]u8{ 0x0B, 0xBE, 0xEF }),
            0x0007 => self.queueL2cap(0x0004, &[_]u8{ 0x0B, 'H', 'i' }),
            0x0012 => self.attError(0x0A, handle, 0x05), // Insufficient Authentication
            0x0015 => self.queueL2cap(0x0004, &[_]u8{ 0x0B, 0x15 }),
            0x0018 => self.attError(0x0A, handle, 0x02), // Read Not Permitted
            else => self.attError(0x0A, handle, 0x01),
        }
    }

    /// Sends a notification if the peer's CCCD allows it, as a real peer does.
    fn notify(self: *FakeController, value_handle: u16, cccd_handle: u16, byte: u8) void {
        if (self.cccd[cccd_handle] & 0x01 == 0) return;
        var pdu = [_]u8{ 0x1B, 0, 0, byte };
        std.mem.writeInt(u16, pdu[1..3], value_handle, .little);
        self.queueL2cap(0x0004, &pdu);
    }
};

const Harness = struct {
    fake: FakeController = undefined,
    backend: HciBackend = .{},

    fn setUp(self: *Harness) !Backend {
        self.backend = HciBackend.init();
        self.fake = .{ .backend = &self.backend };
        self.backend.local_addr = host_addr;
        self.backend.setTransportHook(.{ .ctx = &self.fake, .on_send_packet = FakeController.onSend, .poll_packet = FakeController.poll });
        self.backend.timeouts = .{ .connect_ms = 1000, .discovery_ms = 1000, .read_ms = 1000, .write_ms = 1000, .pair_ms = 1000, .mtu_exchange_ms = 1000 };
        const b = self.backend.backend();
        try b.openAdapter(0);
        return b;
    }

    fn startResponder(self: *Harness, io: smp.IoCapability) *smp.SmpStateMachine {
        var r = smp.SmpStateMachine.init(.responder, peer_addr, .random, host_addr, .public);
        r.local_features.io_capability = io;
        r.require_user_confirmation = false;
        r.key_distribution_enabled = true;
        r.local_features.responder_key_distribution = .{ .id_key = true };
        self.fake.responder = r;
        return &self.fake.responder.?;
    }
};

const NotifyLog = struct {
    hits: usize = 0,
    last: u8 = 0,
    fn onNotify(_: UUID, data: []const u8, udata: ?*anyopaque) void {
        const self: *NotifyLog = @ptrCast(@alignCast(udata.?));
        self.hits += 1;
        self.last = data[0];
    }
};

fn scanRandomPeer(h: *Harness, b: Backend) !void {
    const Noop = struct {
        fn onScan(_: *const types.DiscoveredDevice, _: ?*anyopaque) void {}
    };
    try b.startScan(.{}, Noop.onScan, null);
    try h.backend.processRxPacket(&[_]u8{
        0x04, 0x3E, 15, 0x02, 0x01, 0x00, 0x01, 0x66, 0x55, 0x44, 0x33, 0x22, 0xC1,
        3,    0x02, 0x01, 0x06, 0xD0,
    });
    try b.stopScan();
}

test "connect uses the address type from the scan, and waits for the event" {
    var h: Harness = .{};
    const b = try h.setUp();
    try scanRandomPeer(&h, b);
    const dev = try b.connectDevice(peer_addr, 1000);
    try std.testing.expectEqual(@as(?u8, 0x01), h.fake.last_peer_addr_type);
    try std.testing.expectEqual(ConnectionState.connected, b.getConnectionState(dev));

    // Never seen: public is the only sensible default
    var h2: Harness = .{};
    const b2 = try h2.setUp();
    _ = try b2.connectDevice(peer_addr, 1000);
    try std.testing.expectEqual(@as(?u8, 0x00), h2.fake.last_peer_addr_type);
}

test "connect refuses to pretend without a way to wait for the controller" {
    const Dummy = struct {
        fn onSend(_: ?*anyopaque, _: []const u8) BleError!void {}
    };
    var backend = HciBackend.init();
    backend.setTransportHook(.{ .ctx = null, .on_send_packet = Dummy.onSend });
    const b = backend.backend();
    try b.openAdapter(0);
    try std.testing.expectError(BleError.NotSupported, b.connectDevice(peer_addr, 100));
}

test "discovery walks every paged response and finds real CCCD handles" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try b.connectDevice(peer_addr, 1000);
    try b.discoverServices(dev);

    var infos: [8]CharacteristicInfo = undefined;
    const n = try b.getCharacteristics(dev, &infos);
    try std.testing.expectEqual(@as(usize, 5), n);

    const battery_service = UUID.from16(0x180F);
    const vendor_service = UUID.fromLittleEndian(vendor_service_le);
    const vendor_char = UUID.fromLittleEndian(vendor_char_le);
    try std.testing.expect(infos[0].uuid.eql(UUID.from16(0x2A19)) and infos[0].service_uuid.eql(battery_service));
    try std.testing.expect(infos[1].uuid.eql(vendor_char) and infos[1].service_uuid.eql(battery_service));
    try std.testing.expect(infos[2].uuid.eql(UUID.from16(0x2A4D)) and infos[2].service_uuid.eql(vendor_service));
    try std.testing.expectEqual(@as(u8, 0), infos[2].instance);
    try std.testing.expectEqual(@as(u8, 1), infos[3].instance);

    const ctx: *HciDeviceContext = @ptrCast(@alignCast(dev));
    try std.testing.expectEqual(@as(u16, 0x0004), ctx.characteristics[0].cccd_handle);
    // A User Description sits between value and CCCD
    try std.testing.expectEqual(@as(u16, 0x0008), ctx.characteristics[1].cccd_handle);
    try std.testing.expectEqual(@as(u16, 0), ctx.characteristics[4].cccd_handle);

    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try b.readCharacteristic(dev, infos[3].selector(), &buf));
    try std.testing.expectEqual(@as(u8, 0x15), buf[0]);
    const m = try b.readDescriptor(dev, vendor_char, UUID.from16(0x2901), &buf);
    try std.testing.expectEqualStrings("Hi", buf[0..m]);
    try std.testing.expectError(BleError.DescriptorNotFound, b.readDescriptor(dev, UUID.from16(0x2A19), UUID.from16(0x2901), &buf));

    // ATT errors say why
    try std.testing.expectError(BleError.InsufficientAuthentication, b.readCharacteristic(dev, UUID.from16(0x2A4D), &buf));
    try std.testing.expectError(BleError.PermissionDenied, b.readCharacteristic(dev, UUID.from16(0x2A05), &buf));
    try std.testing.expectEqual(@as(u16, 185), try b.exchangeMtu(dev, 247));
}

test "filter narrows to a service; subscriptions there survive" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try b.connectDevice(peer_addr, 1000);
    try b.discoverServices(dev);
    var log: NotifyLog = .{};
    try b.subscribeNotifications(dev, UUID.from16(0x2A19), NotifyLog.onNotify, &log);

    try b.discoverServicesFiltered(dev, &.{UUID.from16(0x180F)});
    var infos: [8]CharacteristicInfo = undefined;
    try std.testing.expectEqual(@as(usize, 2), try b.getCharacteristics(dev, &infos));
    h.fake.notify(0x0003, 0x0004, 7);
    try b.processEvents(0);
    try std.testing.expectEqual(@as(usize, 1), log.hits);

    try std.testing.expectError(BleError.ServiceNotFound, b.discoverServicesFiltered(dev, &.{UUID.from16(0x1234)}));
    try b.discoverServices(dev);
    try std.testing.expectEqual(@as(usize, 5), try b.getCharacteristics(dev, &infos));
}

test "subscribe writes the CCCD with a request, and picks indications when needed" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try b.connectDevice(peer_addr, 1000);
    try b.discoverServices(dev);

    var log: NotifyLog = .{};
    try b.subscribeNotifications(dev, UUID.from16(0x2A19), NotifyLog.onNotify, &log);
    try std.testing.expectEqual(@as(u16, 1), h.fake.cccd[0x0004]);
    try std.testing.expectEqual(@as(usize, 0), h.fake.write_commands_to_cccd);

    try b.subscribeNotifications(dev, UUID.fromLittleEndian(vendor_char_le), NotifyLog.onNotify, &log);
    try std.testing.expectEqual(@as(u16, 2), h.fake.cccd[0x0008]);

    // Without a CCCD there is nothing to subscribe to
    try std.testing.expectError(BleError.NotificationFailed, b.subscribeNotifications(dev, UUID.from16(0x2A05), NotifyLog.onNotify, &log));

    h.fake.notify(0x0003, 0x0004, 42);
    try b.processEvents(0);
    try std.testing.expectEqual(@as(usize, 1), log.hits);
    try std.testing.expectEqual(@as(u8, 42), log.last);

    try b.unsubscribeNotifications(dev, UUID.from16(0x2A19));
    try std.testing.expectEqual(@as(u16, 0), h.fake.cccd[0x0004]);
}

test "auto-resubscribe writes the CCCD again on the new connection" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try b.connectDevice(peer_addr, 1000);
    try b.discoverServices(dev);
    b.setAutoResubscribe(dev, true);

    var log: NotifyLog = .{};
    try b.subscribeNotifications(dev, .{ .uuid = UUID.from16(0x2A4D), .instance = 1 }, NotifyLog.onNotify, &log);
    h.fake.notify(0x0015, 0x0016, 1);
    try b.processEvents(0);
    try std.testing.expectEqual(@as(usize, 1), log.hits);

    try b.disconnectDevice(dev);
    try b.processEvents(0);
    try std.testing.expectEqual(ConnectionState.disconnected, b.getConnectionState(dev));
    try std.testing.expectEqual(@as(u16, 1), h.fake.cccd[0x0016]);

    const again = try b.connectDevice(peer_addr, 1000);
    // The fake peer forgot on connect, so this value came from a new write
    try std.testing.expectEqual(@as(u16, 1), h.fake.cccd[0x0016]);
    h.fake.notify(0x0015, 0x0016, 2);
    try b.processEvents(0);
    try std.testing.expectEqual(@as(usize, 2), log.hits);

    // Off: the subscription ends with the link
    b.setAutoResubscribe(again, false);
    try b.disconnectDevice(again);
    try b.processEvents(0);
    _ = try b.connectDevice(peer_addr, 1000);
    try std.testing.expectEqual(@as(u16, 0), h.fake.cccd[0x0016]);
}

test "slots of disconnected devices are reused" {
    var h: Harness = .{};
    const b = try h.setUp();
    for (0..10) |i| {
        const dev = try b.connectDevice(.{ .bytes = .{ 0xD0, 0, 0, 0, 0, @intCast(i) } }, 1000);
        const ctx: *HciDeviceContext = @ptrCast(@alignCast(dev));
        ctx.conn_handle = conn_handle;
        try b.disconnectDevice(dev);
        try b.processEvents(0);
    }
}

const PairingLog = struct {
    compared: ?u32 = null,
    accept: bool = true,
    passkey: ?u32 = null,
    displayed: ?u32 = null,

    fn onConfirm(value: ?u32, udata: ?*anyopaque) bool {
        const self: *PairingLog = @ptrCast(@alignCast(udata.?));
        self.compared = value;
        return self.accept;
    }
    fn onRequest(udata: ?*anyopaque) ?u32 {
        const self: *PairingLog = @ptrCast(@alignCast(udata.?));
        return self.passkey;
    }
    fn onDisplay(value: u32, udata: ?*anyopaque) void {
        const self: *PairingLog = @ptrCast(@alignCast(udata.?));
        self.displayed = value;
    }
};

fn connectForPairing(h: *Harness, b: Backend) !*anyopaque {
    try scanRandomPeer(h, b);
    return b.connectDevice(peer_addr, 1000);
}

test "pairing: Numeric Comparison asks the user, encrypts, then bonds and takes keys" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try connectForPairing(&h, b);
    const r = h.startResponder(.display_yes_no);

    var log: PairingLog = .{};
    h.backend.setPairingCallbacks(.{ .on_confirm = PairingLog.onConfirm, .user_data = &log });
    try b.pairDevice(dev, .display_yes_no);

    try std.testing.expect(log.compared != null);
    try std.testing.expectEqual(BondState.bonded, b.getBondState(dev));
    const ctx: *HciDeviceContext = @ptrCast(@alignCast(dev));
    const sm = &ctx.smp_sm.?;
    // Both sides derived one key, and the link was encrypted with it
    try std.testing.expectEqualSlices(u8, &sm.ltk, &r.ltk);
    try std.testing.expectEqualSlices(u8, &sm.ltk, &h.fake.encrypted_with.?);
    try std.testing.expectEqualSlices(u8, &h.fake.identity_irk, &sm.peer_irk);
    try std.testing.expect(sm.peer_identity_addr.?.eql(peer_addr));
}

test "pairing: Numeric Comparison without a callback or with a refusal fails" {
    for ([_]bool{ false, true }) |with_callback| {
        var h: Harness = .{};
        const b = try h.setUp();
        const dev = try connectForPairing(&h, b);
        _ = h.startResponder(.display_yes_no);
        var log: PairingLog = .{ .accept = false };
        if (with_callback) h.backend.setPairingCallbacks(.{ .on_confirm = PairingLog.onConfirm, .user_data = &log });

        try std.testing.expectError(BleError.PairingFailed, b.pairDevice(dev, .display_yes_no));
        try std.testing.expectEqual(BondState.not_bonded, b.getBondState(dev));
        try std.testing.expect(h.fake.encrypted_with == null);
    }
}

test "pairing: Passkey Entry with the host typing the displayed passkey" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try connectForPairing(&h, b);
    const r = h.startResponder(.display_only);
    const shown = try r.generatePasskey();

    var log: PairingLog = .{ .passkey = shown };
    h.backend.setPairingCallbacks(.{ .on_request_passkey = PairingLog.onRequest, .user_data = &log });
    try b.pairDevice(dev, .keyboard_only);
    try std.testing.expectEqual(BondState.bonded, b.getBondState(dev));
}

test "pairing: Passkey Entry with a wrong passkey or no callback fails" {
    for ([_]bool{ false, true }) |with_callback| {
        var h: Harness = .{};
        const b = try h.setUp();
        const dev = try connectForPairing(&h, b);
        const r = h.startResponder(.display_only);
        const shown = try r.generatePasskey();
        var log: PairingLog = .{ .passkey = (shown + 1) % 1_000_000 };
        if (with_callback) h.backend.setPairingCallbacks(.{ .on_request_passkey = PairingLog.onRequest, .user_data = &log });

        try std.testing.expectError(BleError.PairingFailed, b.pairDevice(dev, .keyboard_only));
        try std.testing.expect(h.fake.encrypted_with == null);
    }
}

test "pairing: the host displays a generated passkey for a keyboard device" {
    var h: Harness = .{};
    const b = try h.setUp();
    const dev = try connectForPairing(&h, b);
    const r = h.startResponder(.keyboard_only);

    // The peer's user types what the host displays
    const Ctx = struct {
        var responder: *smp.SmpStateMachine = undefined;
        var shown: ?u32 = null;
        fn onDisplay(value: u32, _: ?*anyopaque) void {
            shown = value;
            responder.setPasskey(value) catch unreachable;
        }
    };
    Ctx.responder = r;
    h.backend.setPairingCallbacks(.{ .on_display_passkey = Ctx.onDisplay });
    try b.pairDevice(dev, .display_only);
    try std.testing.expect(Ctx.shown != null);
    try std.testing.expectEqual(BondState.bonded, b.getBondState(dev));
}

test "long PDUs are split to the controller's buffer size" {
    var h: Harness = .{};
    const b = try h.setUp();
    h.backend.flow.max_packet_length = 27;
    const dev = try connectForPairing(&h, b);
    _ = h.startResponder(.no_input_no_output);
    try b.pairDevice(dev, .no_input_no_output);
    try std.testing.expect(h.fake.max_acl_seen <= 27);
    try std.testing.expectEqual(BondState.bonded, b.getBondState(dev));
}

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
    hci_backend.setTransportHook(.{ .ctx = &cap, .on_send_packet = Capture.onSend, .assume_connected = true });

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
    hci_backend.setTransportHook(.{ .ctx = null, .on_send_packet = DummyTx.onSend, .assume_connected = true });

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
