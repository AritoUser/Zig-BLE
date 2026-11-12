//! # Linux BlueZ Backend Unit Tests
const std = @import("std");
const types = @import("../types.zig");
const wire = @import("../../dbus/wire/mod.zig");
const constants = @import("../../bluez/constants.zig");
const mod = @import("mod.zig");

const Address = types.Address;
const UUID = types.UUID;
const ConnectionEvent = types.ConnectionEvent;
const BlueZ = constants.BlueZ;
const BluezBackend = mod.BluezBackend;

test "BluezBackend structural initialization and VTable conformance" {
    var bluez_back = BluezBackend.init();
    const b = bluez_back.asBackend();
    try std.testing.expectEqualStrings("LinuxBlueZ", b.getName());
}

test "BluezBackend Disconnected signal cleans up subscriptions and fires callback" {
    var bluez_back = BluezBackend.init();
    const addr = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33 } };
    var slot = bluez_back.allocateDeviceSlot(addr).?;
    slot.setPath("/org/bluez/hci0/dev_AA_BB_CC_11_22_33");
    slot.is_connected = true;
    try slot.addCharacteristic(UUID.from16(0x2A37), "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011", .{});
    slot.characteristics[0].is_notifying = true;
    const Noop = struct {
        fn onNotify(_: UUID, _: []const u8, _: ?*anyopaque) void {}
    };
    slot.characteristics[0].notify_cb = Noop.onNotify;

    const DisconnectTracker = struct {
        disconnected_count: usize = 0,
        last_addr: Address = Address{ .bytes = @splat(0) },
        fn onEvent(ev: ConnectionEvent, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            switch (ev) {
                .disconnected => |d| {
                    self.disconnected_count += 1;
                    self.last_addr = d.address;
                },
                else => {},
            }
        }
    };
    var tracker = DisconnectTracker{};
    bluez_back.setConnectionEventCallback(DisconnectTracker.onEvent, &tracker);

    // Build a D-Bus PropertiesChanged signal for org.bluez.Device1 Connected=false
    var sig = try wire.Message.createSignal(
        std.testing.allocator,
        "/org/bluez/hci0/dev_AA_BB_CC_11_22_33",
        BlueZ.Properties.interface_name,
        BlueZ.Properties.Signals.PropertiesChanged,
    );
    defer sig.deinit();
    {
        var b = sig.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        var dict = try b.openArray("{sv}");
        try dict.appendDictBool(BlueZ.Device1.Properties.Connected, false);
        try b.closeContainer(&dict);
        var inv = try b.openArray("s");
        try b.closeContainer(&inv);
    }
    const raw = try sig.finalize(10);
    sig.fixed_header = try wire.FixedHeader.decode(raw[0..16]);
    sig.header_fields = try wire.HeaderFields.parse(raw, sig.fixed_header.fields_len);
    bluez_back.processSignalWireMessage(&sig);

    try std.testing.expect(!slot.is_connected);
    try std.testing.expect(slot.characteristics[0].notify_cb == null);
    try std.testing.expect(!slot.characteristics[0].is_notifying);
    try std.testing.expectEqual(@as(usize, 1), tracker.disconnected_count);
    try std.testing.expect(tracker.last_addr.eql(addr));
}

test "BluezBackend NameOwnerChanged handles bluetoothd daemon restart" {
    var bluez_back = BluezBackend.init();
    const addr = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    var slot = bluez_back.allocateDeviceSlot(addr).?;
    slot.setPath("/org/bluez/hci0/dev_11_22_33_44_55_66");
    slot.is_connected = true;

    const DaemonTracker = struct {
        restarted: bool = false,
        fn onRestart(udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.restarted = true;
        }
    };
    var tracker = DaemonTracker{};
    bluez_back.setDaemonRestartCallback(DaemonTracker.onRestart, &tracker);

    // 1. Simulate bluetoothd vanishing (old_owner=":1.42", new_owner="")
    var sig1 = try wire.Message.createSignal(
        std.testing.allocator,
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
    );
    defer sig1.deinit();
    {
        var b = sig1.builder();
        try b.appendString("org.bluez");
        try b.appendString(":1.42");
        try b.appendString("");
    }
    const raw1 = try sig1.finalize(11);
    sig1.fixed_header = try wire.FixedHeader.decode(raw1[0..16]);
    sig1.header_fields = try wire.HeaderFields.parse(raw1, sig1.fixed_header.fields_len);
    bluez_back.processSignalWireMessage(&sig1);
    try std.testing.expect(!slot.is_connected);

    // 2. Simulate bluetoothd restarting (old_owner="", new_owner=":1.99")
    var sig2 = try wire.Message.createSignal(
        std.testing.allocator,
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
    );
    defer sig2.deinit();
    {
        var b = sig2.builder();
        try b.appendString("org.bluez");
        try b.appendString("");
        try b.appendString(":1.99");
    }
    const raw2 = try sig2.finalize(12);
    sig2.fixed_header = try wire.FixedHeader.decode(raw2[0..16]);
    sig2.header_fields = try wire.HeaderFields.parse(raw2, sig2.fixed_header.fields_len);
    bluez_back.processSignalWireMessage(&sig2);
    try std.testing.expect(tracker.restarted);

    // 3. After deinit(), no callbacks fire
    tracker.restarted = false;
    bluez_back.deinit();
    bluez_back.processSignalWireMessage(&sig2);
    try std.testing.expect(!tracker.restarted);
}

// ---------------------------------------------------------------------------
// Scan results, per-characteristic notifications, duplicate UUIDs (v1.4.0)
// ---------------------------------------------------------------------------

const DiscoveredDevice = types.DiscoveredDevice;

/// Serializes and re-parses a signal so it looks like one read from the bus.
fn finalizeForTest(msg: *wire.Message, serial: u32) !void {
    const raw = try msg.finalize(serial);
    msg.fixed_header = try wire.FixedHeader.decode(raw[0..16]);
    msg.header_fields = try wire.HeaderFields.parse(raw, msg.fixed_header.fields_len);
}

fn initScanningBackend(scan_cb: types.ScanCallback, user_data: ?*anyopaque, filter: types.ScanFilter) BluezBackend {
    var b = BluezBackend.init();
    const adapter = "/org/bluez/hci0";
    @memcpy(b.adapter_path[0..adapter.len], adapter);
    b.adapter_path[adapter.len] = 0;
    b.adapter_path_len = adapter.len;
    b.scanning = true;
    b.scan_filter = filter;
    b.active_scan_cb = scan_cb;
    b.active_scan_user_data = user_data;
    return b;
}

const ScanRecorder = struct {
    count: usize = 0,
    last: DiscoveredDevice = .{ .address = .{ .bytes = @splat(0) } },

    fn onScan(dev: *const DiscoveredDevice, udata: ?*anyopaque) void {
        const self: *ScanRecorder = @ptrCast(@alignCast(udata));
        self.count += 1;
        self.last = dev.*;
    }
};

fn buildInterfacesAdded(path: [:0]const u8, name: [:0]const u8, rssi: i16) !wire.Message {
    var sig = try wire.Message.createSignal(
        std.testing.allocator,
        "/",
        BlueZ.ObjectManager.interface_name,
        BlueZ.ObjectManager.Signals.InterfacesAdded,
    );
    errdefer sig.deinit();
    var b = sig.builder();
    try b.appendObjectPath(path);
    var ifaces = try b.openArray("{sa{sv}}");
    var iface = try ifaces.openDictEntry();
    try iface.appendString(BlueZ.Device1.interface_name);
    var props = try iface.openArray("{sv}");
    try props.appendDictString(BlueZ.Device1.Properties.Address, "AA:BB:CC:11:22:33");
    try props.appendDictString(BlueZ.Device1.Properties.AddressType, "random");
    try props.appendDictString(BlueZ.Device1.Properties.Name, name);
    try props.appendDictInt16(BlueZ.Device1.Properties.RSSI, rssi);
    try props.appendDictStringArray(BlueZ.Device1.Properties.UUIDs, &.{"0000180d-0000-1000-8000-00805f9b34fb"});
    {
        // ManufacturerData: a{qv} with an `ay` variant per company
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
    try iface.closeContainer(&props);
    try ifaces.closeContainer(&iface);
    try b.closeContainer(&ifaces);
    try finalizeForTest(&sig, 20);
    return sig;
}

fn buildRssiChanged(path: [:0]const u8, rssi: i16) !wire.Message {
    var sig = try wire.Message.createSignal(
        std.testing.allocator,
        path,
        BlueZ.Properties.interface_name,
        BlueZ.Properties.Signals.PropertiesChanged,
    );
    errdefer sig.deinit();
    var b = sig.builder();
    try b.appendString(BlueZ.Device1.interface_name);
    var dict = try b.openArray("{sv}");
    try dict.appendDictInt16(BlueZ.Device1.Properties.RSSI, rssi);
    try b.closeContainer(&dict);
    var inv = try b.openArray("s");
    try b.closeContainer(&inv);
    try finalizeForTest(&sig, 21);
    return sig;
}

fn buildValueChanged(char_path: [:0]const u8, value: []const u8) !wire.Message {
    var sig = try wire.Message.createSignal(
        std.testing.allocator,
        char_path,
        BlueZ.Properties.interface_name,
        BlueZ.Properties.Signals.PropertiesChanged,
    );
    errdefer sig.deinit();
    var b = sig.builder();
    try b.appendString(BlueZ.GattCharacteristic1.interface_name);
    var dict = try b.openArray("{sv}");
    try dict.appendDictBytes(BlueZ.GattCharacteristic1.Properties.Value, value);
    try b.closeContainer(&dict);
    var inv = try b.openArray("s");
    try b.closeContainer(&inv);
    try finalizeForTest(&sig, 22);
    return sig;
}

test "BluezBackend reports InterfacesAdded as scan result with name, UUIDs and manufacturer data" {
    var rec = ScanRecorder{};
    var bluez_back = initScanningBackend(ScanRecorder.onScan, &rec, .{});

    var sig = try buildInterfacesAdded("/org/bluez/hci0/dev_AA_BB_CC_11_22_33", "HRM-Strap", -60);
    defer sig.deinit();
    bluez_back.processSignalWireMessage(&sig);

    try std.testing.expectEqual(@as(usize, 1), rec.count);
    try std.testing.expect(rec.last.address.eql(try Address.parse("AA:BB:CC:11:22:33")));
    try std.testing.expectEqual(types.AddressType.random, rec.last.address_type);
    try std.testing.expectEqualStrings("HRM-Strap", rec.last.getName().?);
    try std.testing.expectEqual(@as(?i16, -60), rec.last.rssi);
    try std.testing.expectEqual(@as(usize, 1), rec.last.getServiceUuids().len);
    try std.testing.expect(rec.last.getServiceUuids()[0].eql(UUID.from16(0x180D)));
    try std.testing.expectEqual(@as(?u16, 0x004C), rec.last.company_id);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x15 }, rec.last.getManufacturerData().?);
}

test "BluezBackend merges RSSI-only PropertiesChanged with earlier advertisement data" {
    var rec = ScanRecorder{};
    var bluez_back = initScanningBackend(ScanRecorder.onScan, &rec, .{});

    var added = try buildInterfacesAdded("/org/bluez/hci0/dev_AA_BB_CC_11_22_33", "HRM-Strap", -60);
    defer added.deinit();
    bluez_back.processSignalWireMessage(&added);

    var update = try buildRssiChanged("/org/bluez/hci0/dev_AA_BB_CC_11_22_33", -48);
    defer update.deinit();
    bluez_back.processSignalWireMessage(&update);

    try std.testing.expectEqual(@as(usize, 2), rec.count);
    try std.testing.expectEqual(@as(?i16, -48), rec.last.rssi);
    try std.testing.expectEqualStrings("HRM-Strap", rec.last.getName().?);
}

test "BluezBackend applies scan filter and ignores devices while not scanning" {
    var rec = ScanRecorder{};
    var bluez_back = initScanningBackend(ScanRecorder.onScan, &rec, .{ .min_rssi = -50 });

    var weak = try buildInterfacesAdded("/org/bluez/hci0/dev_AA_BB_CC_11_22_33", "Far", -70);
    defer weak.deinit();
    bluez_back.processSignalWireMessage(&weak);
    try std.testing.expectEqual(@as(usize, 0), rec.count);

    var uuid_rec = ScanRecorder{};
    var by_uuid = initScanningBackend(ScanRecorder.onScan, &uuid_rec, .{ .service_uuids = &.{UUID.from16(0x180F)} });
    by_uuid.processSignalWireMessage(&weak);
    try std.testing.expectEqual(@as(usize, 0), uuid_rec.count);

    // Other adapters and stopped scans produce no results
    var other_adapter = try buildInterfacesAdded("/org/bluez/hci1/dev_AA_BB_CC_11_22_33", "Near", -40);
    defer other_adapter.deinit();
    bluez_back.processSignalWireMessage(&other_adapter);
    try std.testing.expectEqual(@as(usize, 0), rec.count);

    bluez_back.scanning = false;
    var near = try buildInterfacesAdded("/org/bluez/hci0/dev_AA_BB_CC_11_22_33", "Near", -40);
    defer near.deinit();
    bluez_back.processSignalWireMessage(&near);
    try std.testing.expectEqual(@as(usize, 0), rec.count);
}

test "BluezBackend delivers notifications per characteristic, including duplicate UUIDs" {
    var bluez_back = BluezBackend.init();
    const addr = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33 } };
    var slot = bluez_back.allocateDeviceSlot(addr).?;
    slot.setPath("/org/bluez/hci0/dev_AA_BB_CC_11_22_33");
    slot.is_connected = true;

    // Two HID reports with the same UUID plus a battery level, added out of handle order
    const report = UUID.from16(0x2A4D);
    try slot.addCharacteristic(report, "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0014", .{});
    try slot.addCharacteristic(UUID.from16(0x2A19), "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0020/char0021", .{});
    try slot.addCharacteristic(report, "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011", .{});
    // Rediscovery must not create duplicates
    try slot.addCharacteristic(report, "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011", .{});
    try std.testing.expectEqual(@as(u8, 3), slot.characteristics_len);
    slot.sortCharacteristics();
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010", slot.characteristics[0].getServicePath());

    const first_report = slot.findCharacteristic(.of(report)).?;
    const second_report = slot.findCharacteristic(.{ .uuid = report, .instance = 1 }).?;
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011", first_report.getPath());
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0014", second_report.getPath());

    const Counter = struct {
        hits: usize = 0,
        last: u8 = 0,
        fn onNotify(_: UUID, data: []const u8, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.hits += 1;
            self.last = data[0];
        }
    };
    var first = Counter{};
    var second = Counter{};
    first_report.notify_cb = Counter.onNotify;
    first_report.notify_user_data = &first;
    second_report.notify_cb = Counter.onNotify;
    second_report.notify_user_data = &second;

    var to_second = try buildValueChanged("/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0014", &.{0x42});
    defer to_second.deinit();
    bluez_back.processSignalWireMessage(&to_second);
    try std.testing.expectEqual(@as(usize, 0), first.hits);
    try std.testing.expectEqual(@as(usize, 1), second.hits);
    try std.testing.expectEqual(@as(u8, 0x42), second.last);

    var to_first = try buildValueChanged("/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011", &.{0x07});
    defer to_first.deinit();
    bluez_back.processSignalWireMessage(&to_first);
    try std.testing.expectEqual(@as(usize, 1), first.hits);
    try std.testing.expectEqual(@as(u8, 0x07), first.last);
    try std.testing.expectEqual(@as(usize, 1), second.hits);
}

test "BluezBackend reports the disconnect reason from Device1.Disconnected" {
    var bluez_back = BluezBackend.init();
    const addr = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33 } };
    var slot = bluez_back.allocateDeviceSlot(addr).?;
    slot.setPath("/org/bluez/hci0/dev_AA_BB_CC_11_22_33");
    slot.is_connected = true;

    const Tracker = struct {
        count: usize = 0,
        reason: ?u8 = 0xFF,
        fn onEvent(ev: ConnectionEvent, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            if (ev == .disconnected) {
                self.count += 1;
                self.reason = ev.disconnected.reason_code;
            }
        }
    };
    var tracker = Tracker{};
    bluez_back.setConnectionEventCallback(Tracker.onEvent, &tracker);

    var sig = try wire.Message.createSignal(
        std.testing.allocator,
        "/org/bluez/hci0/dev_AA_BB_CC_11_22_33",
        BlueZ.Device1.interface_name,
        BlueZ.Device1.Signals.Disconnected,
    );
    defer sig.deinit();
    {
        var b = sig.builder();
        try b.appendString(BlueZ.Device1.Reasons.Remote);
        try b.appendString("Connection terminated by remote host");
    }
    try finalizeForTest(&sig, 23);
    bluez_back.processSignalWireMessage(&sig);
    try std.testing.expect(!slot.is_connected);
    try std.testing.expectEqual(@as(usize, 1), tracker.count);
    try std.testing.expectEqual(@as(?u8, 0x13), tracker.reason);

    // The following `Connected = false` does not report the disconnect a second time
    var prop = try wire.Message.createSignal(
        std.testing.allocator,
        "/org/bluez/hci0/dev_AA_BB_CC_11_22_33",
        BlueZ.Properties.interface_name,
        BlueZ.Properties.Signals.PropertiesChanged,
    );
    defer prop.deinit();
    {
        var b = prop.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        var dict = try b.openArray("{sv}");
        try dict.appendDictBool(BlueZ.Device1.Properties.Connected, false);
        try b.closeContainer(&dict);
        var inv = try b.openArray("s");
        try b.closeContainer(&inv);
    }
    try finalizeForTest(&prop, 24);
    bluez_back.processSignalWireMessage(&prop);
    try std.testing.expectEqual(@as(usize, 1), tracker.count);
}
