//! # Windows Backend Unit Tests
const std = @import("std");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");
const mod = @import("mod.zig");
const helpers = @import("helpers.zig");
const pairing = @import("pairing.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const ConnectionEvent = types.ConnectionEvent;
const PairingCallbacks = types.PairingCallbacks;
const WindowsBackend = mod.WindowsBackend;
const WindowsBackendWithConfig = mod.WindowsBackendWithConfig;

test "WinRT GUID <-> Zig-BLE UUID conversion roundtrip" {
    const hrm_uuid = UUID.from16(0x180D);
    const g = helpers.uuidToGuid(hrm_uuid);
    try std.testing.expectEqual(@as(u32, 0x0000180D), g.Data1);
    try std.testing.expectEqual(@as(u16, 0x0000), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x1000), g.Data3);
    try std.testing.expectEqual(@as(u8, 0x80), g.Data4[0]);
    try std.testing.expectEqual(@as(u8, 0xFB), g.Data4[7]);

    const roundtrip = helpers.guidToUuid(g);
    try std.testing.expect(hrm_uuid.eql(roundtrip));
}

test "WinRT u64 <-> Zig-BLE Address conversion roundtrip" {
    const addr = try Address.parse("AA:BB:CC:11:22:33");
    const u64_val = helpers.addressToU64(addr);
    try std.testing.expectEqual(@as(u64, 0xAABBCC112233), u64_val);

    const roundtrip = helpers.u64ToAddress(u64_val);
    try std.testing.expect(addr.eql(roundtrip));
}

test "WindowsBackend structural initialization and VTable conformance" {
    var win = WindowsBackend.init();
    const b = win.asBackend();
    try std.testing.expectEqualStrings("WindowsWinRT", b.getName());
}

test "WindowsBackendWithConfig custom pool sizes and PoolExhausted error" {
    const SmallBackend = WindowsBackendWithConfig(.{
        .max_devices = 2,
        .max_services_per_device = 2,
        .max_characteristics_per_device = 2,
    });
    var win = SmallBackend.init();
    defer win.deinit();

    const a1 = try Address.parse("11:22:33:44:55:01");
    const a2 = try Address.parse("11:22:33:44:55:02");
    const a3 = try Address.parse("11:22:33:44:55:03");

    _ = try win.allocateDeviceSlot(a1);
    _ = try win.allocateDeviceSlot(a2);
    try std.testing.expectError(BleError.PoolExhausted, win.allocateDeviceSlot(a3));
}

test "WindowsBackend ConnectionStatusChanged cleans up subscriptions and invokes reconnect callback" {
    var win = WindowsBackend.init();
    defer win.deinit();

    const addr = try Address.parse("AA:BB:CC:DD:EE:01");
    var dev = try win.allocateDeviceSlot(addr);
    dev.is_connected = true;
    dev.was_connected_once = true;
    dev.subscribed_uuid = UUID.from16(0x2A37);

    const Tracker = struct {
        disconnected_count: usize = 0,
        reconnected_count: usize = 0,
        fn onConnEvent(ev: ConnectionEvent, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            if (ev == .disconnected) self.disconnected_count += 1;
        }
        fn onReconnect(_: Address, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.reconnected_count += 1;
        }
    };
    var tracker = Tracker{};
    win.setConnectionEventCallback(Tracker.onConnEvent, &tracker);
    win.setReconnectCallback(Tracker.onReconnect, &tracker);

    // 1. Simulate sudden radio disconnect
    WindowsBackend.simulateConnectionStatusTransition(dev, false);
    try std.testing.expect(!dev.is_connected);
    try std.testing.expect(dev.subscribed_uuid == null);
    try std.testing.expectEqual(@as(usize, 1), tracker.disconnected_count);

    // 2. Simulate radio reconnect
    WindowsBackend.simulateConnectionStatusTransition(dev, true);
    try std.testing.expect(dev.is_connected);
    try std.testing.expectEqual(@as(usize, 1), tracker.reconnected_count);

    // 3. After deinit(), no callbacks fire
    win.deinit();
    WindowsBackend.simulateConnectionStatusTransition(dev, false);
    try std.testing.expectEqual(@as(usize, 1), tracker.disconnected_count);
}

test "WindowsBackend evaluatePairingCeremony supports Passkey and Numeric Comparison callbacks" {
    const PairTester = struct {
        last_numeric: ?u32 = null,
        displayed_pin: u32 = 0,

        fn onConfirm(num: ?u32, udata: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.last_numeric = num;
            return if (num) |n| (n == 654321) else true;
        }
        fn onProvidePin(_: ?*anyopaque) ?u32 {
            return 420199;
        }
        fn onDisplayPin(pin: u32, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.displayed_pin = pin;
        }
    };

    var tester = PairTester{};
    const cbs = PairingCallbacks{
        .on_confirm = PairTester.onConfirm,
        .on_request_passkey = PairTester.onProvidePin,
        .on_display_passkey = PairTester.onDisplayPin,
        .user_data = &tester,
    };

    // 1. Numeric Comparison (ConfirmPinMatch) matching
    const nc_ok = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ConfirmPinMatch, "654321", .display_yes_no, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.accept_only, nc_ok);
    try std.testing.expectEqual(@as(?u32, 654321), tester.last_numeric);

    // 2. Numeric Comparison mismatching -> rejected
    const nc_bad = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ConfirmPinMatch, "111111", .display_yes_no, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.reject, nc_bad);

    // 3. Passkey Entry (ProvidePin) -> formats 6-digit PIN
    const pk_act = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ProvidePin, null, .keyboard_only, cbs);
    switch (pk_act) {
        .accept_with_pin => |digits| try std.testing.expectEqualStrings("420199", &digits),
        else => return error.TestUnexpectedResult,
    }

    // 4. DisplayPin -> invokes display callback and accepts
    const disp_act = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.DisplayPin, "987654", .display_only, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.accept_only, disp_act);
    try std.testing.expectEqual(@as(u32, 987654), tester.displayed_pin);
}
