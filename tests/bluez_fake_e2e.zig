//! # BlueZ backend end-to-end test against a simulated `org.bluez` (Linux)
//!
//! Runs `BluezBackend` over a real D-Bus connection without Bluetooth hardware or
//! `bluetoothd`: a second connection in this process owns the name `org.bluez` on a private
//! bus and answers like BlueZ. It proves the D-Bus traffic of the backend (scan results,
//! connect, discovery, notifications, disconnect reasons), not BlueZ's or a radio's behavior.
//!
//! Needs a private bus, see `scripts/run_bluez_fake_e2e.sh`.

const std = @import("std");
const builtin = @import("builtin");
const ble = @import("Zig_BLE");

comptime {
    if (builtin.os.tag != .linux) @compileError("bluez_fake_e2e runs on Linux only");
}

const wire = ble.wire;
const Connection = ble.Connection;
const Message = wire.Message;
const MessageBuilder = wire.MessageBuilder;
const UUID = ble.UUID;
const BlueZ = ble.bluez.BlueZ;

const adapter_path = "/org/bluez/hci0";
const dev_path = adapter_path ++ "/dev_AA_BB_CC_11_22_33";
const cached_dev_path = adapter_path ++ "/dev_11_22_33_44_55_66";
const hid_service = dev_path ++ "/service0010";
const report_a = hid_service ++ "/char0011";
const report_b = hid_service ++ "/char0014";
const report_b_desc = report_b ++ "/desc0016";
const battery_service = dev_path ++ "/service0020";
const battery_level = battery_service ++ "/char0021";

const hid_uuid = "00001812-0000-1000-8000-00805f9b34fb";
const report_uuid = "00002a4d-0000-1000-8000-00805f9b34fb";
const battery_service_uuid = "0000180f-0000-1000-8000-00805f9b34fb";
const battery_level_uuid = "00002a19-0000-1000-8000-00805f9b34fb";
const report_ref_uuid = "00002908-0000-1000-8000-00805f9b34fb";

/// Control bytes written to `report_a` to make the fake device act.
const cmd_notify: u8 = 0x01;
const cmd_remote_disconnect: u8 = 0x02;
const cmd_deny_reads: u8 = 0x03;

const FakeBluez = struct {
    conn: Connection,
    stop: std.atomic.Value(bool) = .init(false),
    connected: bool = false,
    resolved: bool = false,
    /// Services resolve some time after `Connect` returned, as on real BlueZ.
    resolve_at_ms: ?i64 = null,
    deny_reads: bool = false,

    fn run(self: *FakeBluez) void {
        while (!self.stop.load(.acquire)) {
            _ = self.conn.pollSocket(10);
            while (self.conn.popMessage()) |msg| {
                defer msg.deinit();
                if (msg.fixed_header.msg_type == .method_call) {
                    self.handle(&msg) catch |err| std.debug.print("fake bluez: {s}\n", .{@errorName(err)});
                }
            }
            if (self.resolve_at_ms) |at| {
                if (wire.getMonotonicMs() >= at) {
                    self.resolve_at_ms = null;
                    self.resolved = true;
                    self.emitBool(dev_path, BlueZ.Device1.Properties.ServicesResolved, true) catch {};
                }
            }
        }
    }

    fn handle(self: *FakeBluez, msg: *const Message) !void {
        const member = msg.getMember() orelse return;
        const path = msg.getPath() orelse return;
        const eql = std.mem.eql;

        if (eql(u8, member, "GetManagedObjects")) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            var b = reply.builder();
            try self.writeManagedObjects(&b);
            return self.conn.send(&reply);
        }
        if (eql(u8, member, "Get")) {
            var it = msg.iterator();
            _ = it.getString();
            const prop = it.getString() orelse return;
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            var b = reply.builder();
            if (eql(u8, prop, BlueZ.GattCharacteristic1.Properties.MTU)) {
                var v = try b.openVariant("q");
                try v.appendUInt16(185);
                try b.closeContainer(&v);
            } else {
                var v = try b.openVariant("b");
                const value = if (eql(u8, prop, BlueZ.Device1.Properties.ServicesResolved)) self.resolved else self.connected;
                try v.appendBool(value);
                try b.closeContainer(&v);
            }
            return self.conn.send(&reply);
        }
        if (eql(u8, member, "Connect") and !eql(u8, path, dev_path)) {
            var reply = try Connection.createErrorReply(msg, "org.freedesktop.DBus.Error.UnknownObject", "no such device");
            defer reply.deinit();
            return self.conn.send(&reply);
        }
        if (eql(u8, member, "ReadValue") and self.deny_reads) {
            self.deny_reads = false;
            var reply = try Connection.createErrorReply(msg, "org.bluez.Error.NotPermitted", "Read not permitted");
            defer reply.deinit();
            return self.conn.send(&reply);
        }
        if (eql(u8, member, "ReadValue")) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            var b = reply.builder();
            if (eql(u8, path, report_a)) {
                try b.appendBytes(&.{0xA0});
            } else if (eql(u8, path, report_b)) {
                try b.appendBytes(&.{0xB0});
            } else if (eql(u8, path, battery_level)) {
                try b.appendBytes(&.{90});
            } else {
                try b.appendBytes(&.{ 0x01, 0x02 }); // report reference descriptor
            }
            return self.conn.send(&reply);
        }

        // Everything else succeeds with an empty reply; actions follow the reply as on BlueZ.
        var reply = try Connection.createMethodReturn(msg);
        defer reply.deinit();
        try self.conn.send(&reply);

        if (eql(u8, member, "StartDiscovery")) {
            try self.emitInterfacesAdded();
            try self.emitRssi(dev_path, -48);
            // Known from an earlier session: only an RSSI update, the name must come from the cache
            try self.emitRssi(cached_dev_path, -70);
        } else if (eql(u8, member, "Connect")) {
            self.connected = true;
            self.resolved = false;
            self.resolve_at_ms = wire.getMonotonicMs() + 150;
            try self.emitBool(dev_path, BlueZ.Device1.Properties.Connected, true);
        } else if (eql(u8, member, "Disconnect")) {
            try self.dropLink(BlueZ.Device1.Reasons.Local);
        } else if (eql(u8, member, "WriteValue") and eql(u8, path, report_a)) {
            var it = msg.iterator();
            const data = it.getFixedBytes() orelse return;
            if (data.len == 1 and data[0] == cmd_notify) {
                try self.emitValue(report_a, &.{0x11});
                try self.emitValue(report_b, &.{0x22});
                try self.emitValue(battery_level, &.{0x33});
            } else if (data.len == 1 and data[0] == cmd_deny_reads) {
                self.deny_reads = true;
            } else if (data.len == 1 and data[0] == cmd_remote_disconnect) {
                try self.dropLink(BlueZ.Device1.Reasons.Remote);
            }
        }
    }

    fn dropLink(self: *FakeBluez, reason: [:0]const u8) !void {
        self.connected = false;
        self.resolved = false;
        var sig = try Message.createSignal(std.heap.page_allocator, dev_path, BlueZ.Device1.interface_name, BlueZ.Device1.Signals.Disconnected);
        defer sig.deinit();
        var b = sig.builder();
        try b.appendString(reason);
        try b.appendString("fake disconnect");
        try self.conn.send(&sig);
        try self.emitBool(dev_path, BlueZ.Device1.Properties.Connected, false);
    }

    fn propertiesChanged(path: [:0]const u8) !Message {
        return Message.createSignal(std.heap.page_allocator, path, BlueZ.Properties.interface_name, BlueZ.Properties.Signals.PropertiesChanged);
    }

    fn closeProps(b: *MessageBuilder, dict: *MessageBuilder) !void {
        try b.closeContainer(dict);
        var inv = try b.openArray("s");
        try b.closeContainer(&inv);
    }

    fn emitBool(self: *FakeBluez, path: [:0]const u8, key: [:0]const u8, value: bool) !void {
        var sig = try propertiesChanged(path);
        defer sig.deinit();
        var b = sig.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        var dict = try b.openArray("{sv}");
        try dict.appendDictBool(key, value);
        try closeProps(&b, &dict);
        try self.conn.send(&sig);
    }

    fn emitRssi(self: *FakeBluez, path: [:0]const u8, rssi: i16) !void {
        var sig = try propertiesChanged(path);
        defer sig.deinit();
        var b = sig.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        var dict = try b.openArray("{sv}");
        try dict.appendDictInt16(BlueZ.Device1.Properties.RSSI, rssi);
        try closeProps(&b, &dict);
        try self.conn.send(&sig);
    }

    fn emitValue(self: *FakeBluez, path: [:0]const u8, value: []const u8) !void {
        var sig = try propertiesChanged(path);
        defer sig.deinit();
        var b = sig.builder();
        try b.appendString(BlueZ.GattCharacteristic1.interface_name);
        var dict = try b.openArray("{sv}");
        try dict.appendDictBytes(BlueZ.GattCharacteristic1.Properties.Value, value);
        try closeProps(&b, &dict);
        try self.conn.send(&sig);
    }

    fn writeDeviceProps(props: *MessageBuilder, address: [:0]const u8, name: [:0]const u8, rssi: i16) !void {
        try props.appendDictString(BlueZ.Device1.Properties.Address, address);
        try props.appendDictString(BlueZ.Device1.Properties.AddressType, "random");
        try props.appendDictString(BlueZ.Device1.Properties.Name, name);
        try props.appendDictInt16(BlueZ.Device1.Properties.RSSI, rssi);
        try props.appendDictInt16(BlueZ.Device1.Properties.TxPower, -8);
        try props.appendDictStringArray(BlueZ.Device1.Properties.UUIDs, &.{"0000180d-0000-1000-8000-00805f9b34fb"});
        var entry = try props.openDictEntry();
        try entry.appendString(BlueZ.Device1.Properties.ManufacturerData);
        var v = try entry.openVariant("a{qv}");
        var arr = try v.openArray("{qv}");
        var company = try arr.openDictEntry();
        try company.appendUInt16(0x004C);
        var data = try company.openVariant("ay");
        try data.appendBytes(&.{ 0x02, 0x15 });
        try company.closeContainer(&data);
        try arr.closeContainer(&company);
        try v.closeContainer(&arr);
        try entry.closeContainer(&v);
        try props.closeContainer(&entry);
    }

    fn emitInterfacesAdded(self: *FakeBluez) !void {
        var sig = try Message.createSignal(std.heap.page_allocator, "/", BlueZ.ObjectManager.interface_name, BlueZ.ObjectManager.Signals.InterfacesAdded);
        defer sig.deinit();
        var b = sig.builder();
        try b.appendObjectPath(dev_path);
        var ifaces = try b.openArray("{sa{sv}}");
        var iface = try ifaces.openDictEntry();
        try iface.appendString(BlueZ.Device1.interface_name);
        var props = try iface.openArray("{sv}");
        try writeDeviceProps(&props, "AA:BB:CC:11:22:33", "HRM-Strap", -60);
        try iface.closeContainer(&props);
        try ifaces.closeContainer(&iface);
        try b.closeContainer(&ifaces);
        try self.conn.send(&sig);
    }

    const GattObject = struct {
        path: [:0]const u8,
        iface: [:0]const u8,
        uuid: [:0]const u8,
        parent_key: [:0]const u8,
        parent: [:0]const u8,
    };

    /// Deliberately not in handle order: `GetManagedObjects` gives no ordering guarantee.
    const gatt_objects = [_]GattObject{
        .{ .path = report_b_desc, .iface = BlueZ.GattDescriptor1.interface_name, .uuid = report_ref_uuid, .parent_key = "Characteristic", .parent = report_b },
        .{ .path = battery_level, .iface = BlueZ.GattCharacteristic1.interface_name, .uuid = battery_level_uuid, .parent_key = "Service", .parent = battery_service },
        .{ .path = report_b, .iface = BlueZ.GattCharacteristic1.interface_name, .uuid = report_uuid, .parent_key = "Service", .parent = hid_service },
        .{ .path = report_a, .iface = BlueZ.GattCharacteristic1.interface_name, .uuid = report_uuid, .parent_key = "Service", .parent = hid_service },
        .{ .path = battery_service, .iface = BlueZ.GattService1.interface_name, .uuid = battery_service_uuid, .parent_key = "Device", .parent = dev_path },
        .{ .path = hid_service, .iface = BlueZ.GattService1.interface_name, .uuid = hid_uuid, .parent_key = "Device", .parent = dev_path },
    };

    fn writeManagedObjects(self: *FakeBluez, b: *MessageBuilder) !void {
        var root = try b.openArray("{oa{sa{sv}}}");
        {
            var obj = try root.openDictEntry();
            try obj.appendObjectPath(cached_dev_path);
            var ifaces = try obj.openArray("{sa{sv}}");
            var iface = try ifaces.openDictEntry();
            try iface.appendString(BlueZ.Device1.interface_name);
            var props = try iface.openArray("{sv}");
            try writeDeviceProps(&props, "11:22:33:44:55:66", "Cached-Name", -99);
            try iface.closeContainer(&props);
            try ifaces.closeContainer(&iface);
            try obj.closeContainer(&ifaces);
            try root.closeContainer(&obj);
        }
        // Like BlueZ, GATT objects exist only once the services are resolved.
        if (self.resolved) {
            for (gatt_objects) |o| {
                var obj = try root.openDictEntry();
                try obj.appendObjectPath(o.path);
                var ifaces = try obj.openArray("{sa{sv}}");
                var iface = try ifaces.openDictEntry();
                try iface.appendString(o.iface);
                var props = try iface.openArray("{sv}");
                try props.appendDictString("UUID", o.uuid);
                try props.appendDictObjectPath(o.parent_key, o.parent);
                try iface.closeContainer(&props);
                try ifaces.closeContainer(&iface);
                try obj.closeContainer(&ifaces);
                try root.closeContainer(&obj);
            }
        }
        try b.closeContainer(&root);
    }
};

var failures: usize = 0;

fn check(ok: bool, name: []const u8) void {
    std.debug.print("[{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", name });
    if (!ok) failures += 1;
}

const ScanLog = struct {
    count: usize = 0,
    hrm: ?ble.DiscoveredDevice = null,
    cached: ?ble.DiscoveredDevice = null,

    fn onScan(dev: *const ble.DiscoveredDevice, udata: ?*anyopaque) void {
        const self: *ScanLog = @ptrCast(@alignCast(udata));
        self.count += 1;
        if (dev.address.bytes[0] == 0xAA) self.hrm = dev.* else self.cached = dev.*;
    }
};

const NotifyLog = struct {
    hits: usize = 0,
    last: u8 = 0,

    fn onNotify(_: UUID, data: []const u8, udata: ?*anyopaque) void {
        const self: *NotifyLog = @ptrCast(@alignCast(udata));
        self.hits += 1;
        self.last = data[0];
    }
};

const ConnLog = struct {
    disconnects: usize = 0,
    reason: ?u8 = 0xFF,

    fn onEvent(ev: ble.ConnectionEvent, udata: ?*anyopaque) void {
        const self: *ConnLog = @ptrCast(@alignCast(udata));
        if (ev == .disconnected) {
            self.disconnects += 1;
            self.reason = ev.disconnected.reason_code;
        }
    }
};

fn pumpUntil(adapter: *ble.UnifiedAdapter, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    const deadline = wire.getMonotonicMs() + 2000;
    while (!done(ctx) and wire.getMonotonicMs() < deadline) {
        try adapter.processEvents(20);
    }
}

var bluez_backend: ble.BluezBackend = .{};
var fake: FakeBluez = undefined;

const Pumper = struct {
    adapter: *ble.UnifiedAdapter,
    stop: std.atomic.Value(bool) = .init(false),
    errors: usize = 0,

    fn run(self: *Pumper) void {
        while (!self.stop.load(.acquire)) {
            self.adapter.processEvents(5) catch {
                self.errors += 1;
            };
        }
    }
};

pub fn main() !void {
    fake = .{ .conn = try Connection.initSystem() };
    _ = try fake.conn.requestName(BlueZ.service_name, 0);
    const fake_thread = try std.Thread.spawn(.{}, FakeBluez.run, .{&fake});

    const backend = bluez_backend.asBackend();
    try backend.openAdapter(0);
    var adapter = ble.UnifiedAdapter.init(backend);

    // F1: scan results over real D-Bus signals
    var scan = ScanLog{};
    try adapter.startScan(.{}, ScanLog.onScan, &scan);
    try pumpUntil(&adapter, &scan, struct {
        fn f(s: *ScanLog) bool {
            return s.count >= 3;
        }
    }.f);
    try adapter.stopScan();
    check(scan.count == 3, "scan: InterfacesAdded and two RSSI updates reach the callback");
    if (scan.hrm) |d| {
        check(std.mem.eql(u8, d.getName() orelse "", "HRM-Strap"), "scan: name from InterfacesAdded");
        check(d.rssi == -48, "scan: RSSI update merged");
        check(d.address_type == .random, "scan: address type");
        check(d.company_id == 0x004C, "scan: manufacturer data");
        check(d.tx_power == -8, "scan: TX power");
        check(d.getServiceUuids().len == 1 and d.getServiceUuids()[0].eql(UUID.from16(0x180D)), "scan: service UUIDs");
    } else check(false, "scan: device reported");
    if (scan.cached) |d| {
        check(std.mem.eql(u8, d.getName() orelse "", "Cached-Name"), "scan: RSSI-only update gets the known name from GetManagedObjects");
        check(d.rssi == -70, "scan: fresh RSSI replaces the cached one");
    } else check(false, "scan: cached device reported");

    // F6: unknown device and waiting for ServicesResolved
    const unknown = try ble.Address.parse("00:00:00:00:00:01");
    if (adapter.connect(unknown, 1000)) |_| {
        check(false, "connect: unknown device fails");
    } else |err| {
        check(err == error.DeviceNotFound, "connect: unknown device returns DeviceNotFound");
    }

    var conn_log = ConnLog{};
    bluez_backend.setConnectionEventCallback(ConnLog.onEvent, &conn_log);

    const addr = try ble.Address.parse("AA:BB:CC:11:22:33");
    const started = wire.getMonotonicMs();
    var dev = try adapter.connect(addr, 3000);
    const took = wire.getMonotonicMs() - started;
    check(took >= 100, "connect: waits for ServicesResolved");
    check(dev.isConnected(), "connect: device is connected");

    // F3: same UUID twice, handle order, service UUIDs
    const report = UUID.from16(0x2A4D);
    const battery = UUID.from16(0x2A19);
    var infos: [8]ble.CharacteristicInfo = undefined;
    const n = try dev.getCharacteristics(&infos);
    check(n == 3, "discovery: three characteristics, none overwritten");
    if (n == 3) {
        check(infos[0].uuid.eql(report) and infos[0].instance == 0, "discovery: first report in handle order");
        check(infos[1].uuid.eql(report) and infos[1].instance == 1, "discovery: second report in handle order");
        check(infos[2].uuid.eql(battery), "discovery: battery level last");
        check(infos[0].service_uuid.eql(UUID.from16(0x1812)), "discovery: HID service UUID");
        check(infos[2].service_uuid.eql(UUID.from16(0x180F)), "discovery: battery service UUID");
    }

    var buf: [8]u8 = undefined;
    _ = try dev.readCharacteristic(report, &buf);
    check(buf[0] == 0xA0, "read: plain UUID selects the first report");
    _ = try dev.readCharacteristic(.{ .uuid = report, .instance = 1 }, &buf);
    check(buf[0] == 0xB0, "read: instance selects the second report");
    _ = try dev.readCharacteristic(ble.CharacteristicSelector.inService(UUID.from16(0x180F), battery), &buf);
    check(buf[0] == 90, "read: selector with service");
    check(dev.readCharacteristic(ble.CharacteristicSelector.inService(UUID.from16(0x180F), report), &buf) == error.CharacteristicNotFound, "read: wrong service is not found");

    try dev.writeCharacteristic(report, &.{cmd_deny_reads}, true);
    check(dev.readCharacteristic(report, &buf) == error.PermissionDenied, "read: NotPermitted maps to PermissionDenied");

    const ref = UUID.from16(0x2908);
    const desc_len = try dev.readDescriptor(.{ .uuid = report, .instance = 1 }, ref, &buf);
    check(desc_len == 2 and buf[1] == 0x02, "descriptor: read from the right characteristic");
    check(dev.readDescriptor(report, ref, &buf) == error.DescriptorNotFound, "descriptor: other instance has none");
    check((try dev.exchangeMtu(247)) == 185, "mtu: negotiated value from BlueZ");

    // Slots: more devices than slots, with disconnected ones being reused
    var slots_ok = true;
    for (0..bluez_backend.devices.len - 1) |i| {
        const slot = bluez_backend.allocateDeviceSlot(.{ .bytes = .{ 0x02, 0, 0, 0, 0, @intCast(i) } }) orelse {
            slots_ok = false;
            break;
        };
        slot.is_connected = true;
    }
    check(slots_ok, "slots: every other slot can be used");
    const new_addr = ble.Address{ .bytes = .{ 0x03, 0, 0, 0, 0, 0 } };
    check(bluez_backend.allocateDeviceSlot(new_addr) == null, "slots: all connected means pool exhausted");
    for (&bluez_backend.devices) |*d| {
        if (!d.address.eql(addr)) d.is_connected = false;
    }
    check(bluez_backend.allocateDeviceSlot(new_addr) != null, "slots: a disconnected slot is reused");

    // F2: independent subscriptions
    var battery_log = NotifyLog{};
    var report_log = NotifyLog{};
    try dev.subscribe(battery, NotifyLog.onNotify, &battery_log);
    try dev.subscribe(.{ .uuid = report, .instance = 1 }, NotifyLog.onNotify, &report_log);
    try dev.writeCharacteristic(report, &.{cmd_notify}, true);
    const Both = struct { a: *NotifyLog, b: *NotifyLog };
    try pumpUntil(&adapter, Both{ .a = &battery_log, .b = &report_log }, struct {
        fn f(c: Both) bool {
            return c.a.hits >= 1 and c.b.hits >= 1;
        }
    }.f);
    check(battery_log.hits == 1 and battery_log.last == 0x33, "notify: battery callback gets its value");
    check(report_log.hits == 1 and report_log.last == 0x22, "notify: second report callback gets its value");

    try dev.unsubscribe(.{ .uuid = report, .instance = 1 });
    try dev.writeCharacteristic(report, &.{cmd_notify}, true);
    try pumpUntil(&adapter, &battery_log, struct {
        fn f(l: *NotifyLog) bool {
            return l.hits >= 2;
        }
    }.f);
    check(battery_log.hits == 2, "notify: unsubscribing one keeps the other");
    check(report_log.hits == 1, "notify: unsubscribed characteristic stays silent");

    // A reply that arrives while nobody waits for it yet must stay queued for its caller.
    // This window is too small for the thread test below to hit reliably.
    {
        const conn = &bluez_backend.conn.?;
        var call = try Connection.createMethodCall(BlueZ.service_name, dev_path, BlueZ.Properties.interface_name, BlueZ.Properties.Methods.Get);
        defer call.deinit();
        var b = call.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        try b.appendString(BlueZ.Device1.Properties.Connected);
        const serial = try conn.sendWithSerial(&call);
        for (0..5) |_| try adapter.processEvents(20);
        const reply = conn.popMatching(serial, struct {
            fn f(want: u32, m: *const Message) bool {
                return m.fixed_header.msg_type == .method_return and m.getReplySerial() == want;
            }
        }.f);
        check(reply != null, "threads: processEvents leaves method replies queued");
        if (reply) |r| r.deinit();
    }

    // Method calls while another thread pumps events: replies must not get lost
    var pumper = Pumper{ .adapter = &adapter };
    const pump_thread = try std.Thread.spawn(.{}, Pumper.run, .{&pumper});
    var failed_reads: usize = 0;
    for (0..300) |_| {
        _ = dev.readCharacteristic(battery, &buf) catch {
            failed_reads += 1;
        };
    }
    pumper.stop.store(true, .release);
    pump_thread.join();
    check(failed_reads == 0, "threads: 300 reads with a concurrent processEvents loop");
    check(pumper.errors == 0, "threads: processEvents reports no errors");

    // F11: disconnect reason
    try dev.writeCharacteristic(report, &.{cmd_remote_disconnect}, true);
    try pumpUntil(&adapter, &conn_log, struct {
        fn f(l: *ConnLog) bool {
            return l.disconnects >= 1;
        }
    }.f);
    // Let `Connected = false` arrive as well; it must not report a second disconnect.
    try adapter.processEvents(50);
    check(conn_log.disconnects == 1, "disconnect: reported exactly once");
    check(conn_log.reason == 0x13, "disconnect: remote reason from Device1.Disconnected");
    check(dev.readCharacteristic(battery, &buf) == error.NotConnected, "disconnect: GATT calls return NotConnected");
    check(!dev.isConnected(), "disconnect: device is not connected");

    // Recovery after a bluetoothd restart: new bus connection, scanning works again
    try bluez_backend.recoverAfterDaemonRestart();
    var rescan = ScanLog{};
    try adapter.startScan(.{}, ScanLog.onScan, &rescan);
    try pumpUntil(&adapter, &rescan, struct {
        fn f(s: *ScanLog) bool {
            return s.count >= 3;
        }
    }.f);
    try adapter.stopScan();
    check(rescan.count == 3, "recovery: scan results arrive over the new bus connection");

    bluez_backend.deinit();
    fake.stop.store(true, .release);
    fake_thread.join();
    fake.conn.deinit();

    std.debug.print("\n{s}: {d} failed\n", .{ if (failures == 0) "All checks passed" else "FAILED", failures });
    if (failures != 0) std.process.exit(1);
}
