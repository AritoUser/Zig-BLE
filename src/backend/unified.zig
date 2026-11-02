//! # Zig-BLE Unified Public API (Adapter & Device)
//!
//! Exposes a clean, cross-platform, zero-allocation API over any Backend implementation.

const std = @import("std");
const types = @import("types.zig");
const vtable_mod = @import("vtable.zig");

pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const CharacteristicSelector = types.CharacteristicSelector;
pub const CharacteristicInfo = types.CharacteristicInfo;
pub const BleError = types.BleError;
pub const TimeoutConfig = types.TimeoutConfig;
pub const Backend = vtable_mod.Backend;

pub const UnifiedDevice = struct {
    backend: Backend,
    handle: *anyopaque,
    address: Address,

    pub fn disconnect(self: *UnifiedDevice) BleError!void {
        return self.backend.disconnectDevice(self.handle);
    }

    pub fn isConnected(self: *UnifiedDevice) bool {
        return self.backend.isDeviceConnected(self.handle);
    }

    pub fn getRSSI(self: *UnifiedDevice) ?i16 {
        return self.backend.getDeviceRssi(self.handle);
    }

    pub fn discoverServices(self: *UnifiedDevice) BleError!void {
        return self.backend.discoverServices(self.handle);
    }

    // `char` is a `UUID` (first characteristic with that UUID) or a `CharacteristicSelector`,
    // e.g. `.{ .uuid = UUID.from16(0x2A4D), .instance = 1 }` for the second HID report.

    pub fn readCharacteristic(self: *UnifiedDevice, char: anytype, buf: []u8) BleError!usize {
        return self.backend.readCharacteristic(self.handle, char, buf);
    }

    pub fn writeCharacteristic(self: *UnifiedDevice, char: anytype, data: []const u8, with_response: bool) BleError!void {
        return self.backend.writeCharacteristic(self.handle, char, data, with_response);
    }

    /// Each characteristic keeps its own callback; subscribing to one does not affect others.
    pub fn subscribe(self: *UnifiedDevice, char: anytype, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        return self.backend.subscribeNotifications(self.handle, char, cb, user_data);
    }

    pub fn unsubscribe(self: *UnifiedDevice, char: anytype) BleError!void {
        return self.backend.unsubscribeNotifications(self.handle, char);
    }

    /// Reads a descriptor of `char`, e.g. `UUID.from16(0x2901)` for the User Description.
    pub fn readDescriptor(self: *UnifiedDevice, char: anytype, descriptor: UUID, buf: []u8) BleError!usize {
        return self.backend.readDescriptor(self.handle, char, descriptor, buf);
    }

    /// Writes a descriptor of `char`. Use `subscribe` rather than writing the CCCD (0x2902).
    pub fn writeDescriptor(self: *UnifiedDevice, char: anytype, descriptor: UUID, data: []const u8) BleError!void {
        return self.backend.writeDescriptor(self.handle, char, descriptor, data);
    }

    /// Lists the discovered characteristics in attribute-handle order and returns how many
    /// were written to `out`.
    pub fn getCharacteristics(self: *UnifiedDevice, out: []CharacteristicInfo) BleError!usize {
        return self.backend.getCharacteristics(self.handle, out);
    }

    pub fn exchangeMtu(self: *UnifiedDevice, target_mtu: u16) BleError!u16 {
        return self.backend.exchangeMtu(self.handle, target_mtu);
    }

    pub fn pair(self: *UnifiedDevice, io_cap: types.IoCapability) BleError!void {
        return self.backend.pairDevice(self.handle, io_cap);
    }

    pub fn unpair(self: *UnifiedDevice) BleError!void {
        return self.backend.unpairDevice(self.handle);
    }

    pub fn getBondState(self: *UnifiedDevice) types.BondState {
        return self.backend.getBondState(self.handle);
    }

    pub fn acquireNotifyFd(self: *UnifiedDevice, char: anytype, out_mtu: *u16) BleError!std.posix.fd_t {
        return self.backend.acquireNotifyFd(self.handle, char, out_mtu);
    }
};

pub const UnifiedAdapter = struct {
    backend: Backend,
    timeouts: TimeoutConfig = .{},

    pub fn init(backend_inst: Backend) UnifiedAdapter {
        return .{ .backend = backend_inst };
    }

    pub fn initWithTimeouts(backend_inst: Backend, timeouts: TimeoutConfig) UnifiedAdapter {
        return .{ .backend = backend_inst, .timeouts = timeouts };
    }

    pub fn getBackendName(self: *const UnifiedAdapter) []const u8 {
        return self.backend.getName();
    }

    pub fn setPowered(self: *UnifiedAdapter, powered: bool) BleError!void {
        return self.backend.setPowered(powered);
    }

    pub fn isPowered(self: *UnifiedAdapter) BleError!bool {
        return self.backend.isPowered();
    }

    pub fn startScan(self: *UnifiedAdapter, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
        return self.backend.startScan(filter, cb, user_data);
    }

    pub fn stopScan(self: *UnifiedAdapter) BleError!void {
        return self.backend.stopScan();
    }

    /// Delivers pending scan results, notifications and connection events, waiting up to
    /// `timeout_ms` for the first one. Call it regularly, e.g. in the main loop. BlueZ needs
    /// it to deliver any callback; on Windows callbacks arrive on WinRT threads and this only waits.
    pub fn processEvents(self: *UnifiedAdapter, timeout_ms: u32) BleError!void {
        return self.backend.processEvents(timeout_ms);
    }

    pub fn connect(self: *UnifiedAdapter, addr: Address, timeout_ms: u32) BleError!UnifiedDevice {
        const eff_timeout = if (timeout_ms == 0) self.timeouts.connect_ms else timeout_ms;
        const handle = try self.backend.connectDevice(addr, eff_timeout);
        return UnifiedDevice{
            .backend = self.backend,
            .handle = handle,
            .address = addr,
        };
    }
};

test "UnifiedAdapter with MockController Test" {
    const mock_mod = @import("mock/mod.zig");
    var mock = mock_mod.MockController.init();
    var adapter = UnifiedAdapter.init(mock.asBackend());

    try std.testing.expectEqualStrings("MockController", adapter.getBackendName());

    try adapter.setPowered(true);
    try std.testing.expect(try adapter.isPowered());

    const addr = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    var dev = mock_mod.MockDevice{ .address = addr, .rssi = -70 };
    dev.setName("TempSensor");
    var char = mock_mod.MockCharacteristic{
        .uuid = UUID.from16(0x2A1C), // Temperature Measurement
    };
    char.setValue(&[_]u8{ 0x00, 25, 0 }); // 25 C
    _ = dev.addCharacteristic(char);
    _ = try mock.addDevice(dev);

    var connected_dev = try adapter.connect(addr, 1000);
    try std.testing.expect(connected_dev.isConnected());
    try std.testing.expectEqual(@as(?i16, -70), connected_dev.getRSSI());

    var buf: [16]u8 = undefined;
    const len = try connected_dev.readCharacteristic(UUID.from16(0x2A1C), &buf);
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqual(@as(u8, 25), buf[1]);

    try connected_dev.disconnect();
    try std.testing.expect(!connected_dev.isConnected());
}

test "UnifiedDevice keeps one subscription per characteristic and addresses duplicate UUIDs" {
    const mock_mod = @import("mock/mod.zig");
    var mock = mock_mod.MockController.init();
    var adapter = UnifiedAdapter.init(mock.asBackend());
    try adapter.setPowered(true);

    const hid = UUID.from16(0x1812);
    const report = UUID.from16(0x2A4D);
    const battery_level = UUID.from16(0x2A19);
    const addr = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x77 } };
    var dev = mock_mod.MockDevice{ .address = addr };
    var report_a = mock_mod.MockCharacteristic{ .uuid = report, .service_uuid = hid };
    report_a.setValue(&.{0xA0});
    var report_b = mock_mod.MockCharacteristic{ .uuid = report, .service_uuid = hid };
    report_b.setValue(&.{0xB0});
    _ = dev.addCharacteristic(report_a);
    _ = dev.addCharacteristic(report_b);
    _ = dev.addCharacteristic(.{ .uuid = battery_level, .service_uuid = UUID.from16(0x180F) });
    _ = try mock.addDevice(dev);

    var connected = try adapter.connect(addr, 1000);

    // Duplicate UUIDs: a plain UUID selects the first, `instance` the others
    var buf: [4]u8 = undefined;
    _ = try connected.readCharacteristic(report, &buf);
    try std.testing.expectEqual(@as(u8, 0xA0), buf[0]);
    _ = try connected.readCharacteristic(.{ .uuid = report, .service = hid, .instance = 1 }, &buf);
    try std.testing.expectEqual(@as(u8, 0xB0), buf[0]);
    try std.testing.expectError(BleError.CharacteristicNotFound, connected.readCharacteristic(.{ .uuid = report, .instance = 2 }, &buf));

    var infos: [8]CharacteristicInfo = undefined;
    const n = try connected.getCharacteristics(&infos);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 1), infos[1].instance);
    _ = try connected.readCharacteristic(infos[1].selector(), &buf);
    try std.testing.expectEqual(@as(u8, 0xB0), buf[0]);

    // Each subscription keeps its own callback and survives unsubscribing another one
    const Counter = struct {
        hits: usize = 0,
        fn onNotify(_: UUID, _: []const u8, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.hits += 1;
        }
    };
    var battery_hits = Counter{};
    var report_hits = Counter{};
    try connected.subscribe(battery_level, Counter.onNotify, &battery_hits);
    try connected.subscribe(.{ .uuid = report, .instance = 1 }, Counter.onNotify, &report_hits);

    try mock.triggerNotification(addr, battery_level, &.{90});
    try mock.triggerNotification(addr, CharacteristicSelector{ .uuid = report, .instance = 1 }, &.{1});
    try mock.triggerNotification(addr, report, &.{2}); // first report is not subscribed
    try std.testing.expectEqual(@as(usize, 1), battery_hits.hits);
    try std.testing.expectEqual(@as(usize, 1), report_hits.hits);

    try connected.unsubscribe(.{ .uuid = report, .instance = 1 });
    try mock.triggerNotification(addr, battery_level, &.{89});
    try mock.triggerNotification(addr, CharacteristicSelector{ .uuid = report, .instance = 1 }, &.{3});
    try std.testing.expectEqual(@as(usize, 2), battery_hits.hits);
    try std.testing.expectEqual(@as(usize, 1), report_hits.hits);

    // processEvents returns immediately on backends without an event queue
    try adapter.processEvents(0);
}

test "UnifiedDevice reads and writes descriptors" {
    const mock_mod = @import("mock/mod.zig");
    var mock = mock_mod.MockController.init();
    var adapter = UnifiedAdapter.init(mock.asBackend());
    try adapter.setPowered(true);

    const addr = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x88 } };
    var dev = mock_mod.MockDevice{ .address = addr };
    var temp = mock_mod.MockCharacteristic{ .uuid = UUID.from16(0x2A6E) };
    _ = temp.addDescriptor(.init(UUID.from16(0x2901), "Room"));
    _ = dev.addCharacteristic(temp);
    _ = try mock.addDevice(dev);

    var connected = try adapter.connect(addr, 1000);
    var buf: [16]u8 = undefined;
    const n = try connected.readDescriptor(UUID.from16(0x2A6E), UUID.from16(0x2901), &buf);
    try std.testing.expectEqualStrings("Room", buf[0..n]);

    try connected.writeDescriptor(UUID.from16(0x2A6E), UUID.from16(0x2901), "Kitchen");
    const m = try connected.readDescriptor(UUID.from16(0x2A6E), UUID.from16(0x2901), &buf);
    try std.testing.expectEqualStrings("Kitchen", buf[0..m]);

    try std.testing.expectError(BleError.DescriptorNotFound, connected.readDescriptor(UUID.from16(0x2A6E), UUID.from16(0x2904), &buf));
}
