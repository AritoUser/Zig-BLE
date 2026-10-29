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
    try slot.addCharacteristic(UUID.from16(0x2A37), "/org/bluez/hci0/dev_AA_BB_CC_11_22_33/service0010/char0011");
    slot.characteristics[0].is_notifying = true;
    slot.subscribed_uuid = UUID.from16(0x2A37);

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
    try std.testing.expect(slot.subscribed_uuid == null);
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

