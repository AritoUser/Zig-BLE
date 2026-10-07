//! # Zig-BLE Virtual Mock Controller Backend
//!
//! A high-performance, 100% in-memory BLE mock adapter and peripheral simulator.
//! Conforms to BackendVTable, allowing automated unit and integration tests
//! without physical Bluetooth hardware on Windows, Linux, and macOS.

const std = @import("std");
const types = @import("../types.zig");
const vtable_mod = @import("../vtable.zig");

pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const BleError = types.BleError;
pub const BackendVTable = vtable_mod.BackendVTable;
pub const Backend = vtable_mod.Backend;

pub const MockCharacteristic = struct {
    uuid: UUID,
    value: [128]u8 = [_]u8{0} ** 128,
    value_len: u8 = 0,
    can_read: bool = true,
    can_write: bool = true,
    can_notify: bool = true,

    pub fn getValue(self: *const MockCharacteristic) []const u8 {
        return self.value[0..self.value_len];
    }

    pub fn setValue(self: *MockCharacteristic, data: []const u8) void {
        const len = @min(self.value.len, data.len);
        @memcpy(self.value[0..len], data[0..len]);
        self.value_len = @intCast(len);
    }
};

pub const MockDevice = struct {
    address: Address,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    rssi: i16 = -55,
    is_connected: bool = false,

    characteristics: [16]MockCharacteristic = undefined,
    characteristics_len: u8 = 0,

    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,
    subscribed_uuid: ?UUID = null,

    mtu: u16 = 23,
    bond_state: types.BondState = .not_bonded,
    io_capability: types.IoCapability = .no_input_no_output,

    pub fn getName(self: *const MockDevice) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *MockDevice, name_str: []const u8) void {
        const len = @min(self.name.len, name_str.len);
        @memcpy(self.name[0..len], name_str[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn addCharacteristic(self: *MockDevice, char: MockCharacteristic) bool {
        if (self.characteristics_len < self.characteristics.len) {
            self.characteristics[self.characteristics_len] = char;
            self.characteristics_len += 1;
            return true;
        }
        return false;
    }

    pub fn findCharacteristic(self: *MockDevice, uuid: UUID) ?*MockCharacteristic {
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            if (ch.uuid.eql(uuid)) return ch;
        }
        return null;
    }
};

pub const MockController = struct {
    powered: bool = false,
    scanning: bool = false,
    active_scan_cb: ?ScanCallback = null,
    active_scan_user_data: ?*anyopaque = null,

    devices: [16]MockDevice = undefined,
    devices_len: u8 = 0,

    pub fn init() MockController {
        return .{};
    }

    pub fn addDevice(self: *MockController, dev: MockDevice) !*MockDevice {
        if (self.devices_len >= self.devices.len) return error.OutOfMemory;
        self.devices[self.devices_len] = dev;
        const ptr = &self.devices[self.devices_len];
        self.devices_len += 1;
        return ptr;
    }

    pub fn findDeviceByAddress(self: *MockController, addr: Address) ?*MockDevice {
        for (self.devices[0..self.devices_len]) |*dev| {
            if (dev.address.eql(addr)) return dev;
        }
        return null;
    }

    pub fn triggerNotification(self: *MockController, addr: Address, uuid: UUID, data: []const u8) !void {
        const dev = self.findDeviceByAddress(addr) orelse return BleError.DeviceNotFound;
        if (!dev.is_connected) return BleError.NotConnected;
        if (dev.notify_cb) |cb| {
            if (dev.subscribed_uuid) |sub_uuid| {
                if (sub_uuid.eql(uuid)) {
                    cb(uuid, data, dev.notify_user_data);
                }
            }
        }
    }

    // Backend implementation methods
    pub fn openAdapter(ctx: *anyopaque, index: u16) anyerror!void {
        _ = index;
        const self: *MockController = @ptrCast(@alignCast(ctx));
        self.powered = true;
    }

    pub fn closeAdapter(ctx: *anyopaque) void {
        const self: *MockController = @ptrCast(@alignCast(ctx));
        self.scanning = false;
        self.powered = false;
    }

    pub fn setPowered(ctx: *anyopaque, powered: bool) anyerror!void {
        const self: *MockController = @ptrCast(@alignCast(ctx));
        self.powered = powered;
        if (!powered) self.scanning = false;
    }

    pub fn isPowered(ctx: *anyopaque) anyerror!bool {
        const self: *MockController = @ptrCast(@alignCast(ctx));
        return self.powered;
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void {
        const self: *MockController = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;
        self.scanning = true;
        self.active_scan_cb = cb;
        self.active_scan_user_data = user_data;

        // Immediately replay registered mock peripherals
        for (self.devices[0..self.devices_len]) |*dev| {
            if (filter.min_rssi) |min_r| {
                if (dev.rssi < min_r) continue;
            }

            var discovered: DiscoveredDevice = .{
                .address = dev.address,
                .rssi = dev.rssi,
            };
            if (dev.name_len > 0) {
                discovered.setName(dev.getName());
            }
            cb(&discovered, user_data);
        }
    }

    pub fn stopScan(ctx: *anyopaque) anyerror!void {
        const self: *MockController = @ptrCast(@alignCast(ctx));
        self.scanning = false;
        self.active_scan_cb = null;
        self.active_scan_user_data = null;
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque {
        _ = timeout_ms;
        const self: *MockController = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;
        const dev = self.findDeviceByAddress(addr) orelse return BleError.DeviceNotFound;
        dev.is_connected = true;
        return @ptrCast(dev);
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        dev.is_connected = false;
        dev.notify_cb = null;
        dev.subscribed_uuid = null;
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        return dev.is_connected;
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        return dev.rssi;
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
        const char = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        if (!char.can_read) return BleError.PermissionDenied;

        const val = char.getValue();
        const copy_len = @min(buf.len, val.len);
        @memcpy(buf[0..copy_len], val[0..copy_len]);
        return copy_len;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void {
        _ = ctx;
        _ = with_response;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
        const char = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        if (!char.can_write) return BleError.PermissionDenied;

        char.setValue(data);
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
        const char = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        if (!char.can_notify) return BleError.PermissionDenied;

        dev.notify_cb = cb;
        dev.notify_user_data = user_data;
        dev.subscribed_uuid = char_uuid;
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (dev.subscribed_uuid) |sub_uuid| {
            if (sub_uuid.eql(char_uuid)) {
                dev.notify_cb = null;
                dev.subscribed_uuid = null;
                dev.notify_user_data = null;
            }
        }
    }

    pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) anyerror!u16 {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
        const negotiated = @min(@max(target_mtu, 23), 517);
        dev.mtu = negotiated;
        return negotiated;
    }

    pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        if (!dev.is_connected) return BleError.NotConnected;
        dev.io_capability = io_cap;
        dev.bond_state = .bonded;
    }

    pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        dev.bond_state = .not_bonded;
    }

    pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
        _ = ctx;
        const dev: *MockDevice = @ptrCast(@alignCast(dev_handle));
        return dev.bond_state;
    }

    pub const vtable: BackendVTable = .{
        .name = "MockController",
        .openAdapter = openAdapter,
        .closeAdapter = closeAdapter,
        .setPowered = setPowered,
        .isPowered = isPowered,
        .startScan = startScan,
        .stopScan = stopScan,
        .connectDevice = connectDevice,
        .disconnectDevice = disconnectDevice,
        .isDeviceConnected = isDeviceConnected,
        .getDeviceRssi = getDeviceRssi,
        .discoverServices = discoverServices,
        .readCharacteristic = readCharacteristic,
        .writeCharacteristic = writeCharacteristic,
        .subscribeNotifications = subscribeNotifications,
        .unsubscribeNotifications = unsubscribeNotifications,
        .exchangeMtu = exchangeMtu,
        .pairDevice = pairDevice,
        .unpairDevice = unpairDevice,
        .getBondState = getBondState,
    };

    pub fn asBackend(self: *MockController) Backend {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "MockController End-to-End Simulation Test" {
    var mock = MockController.init();
    var backend = mock.asBackend();

    // 1. Adapter state
    try std.testing.expectEqual(false, try backend.isPowered());
    try backend.setPowered(true);
    try std.testing.expectEqual(true, try backend.isPowered());

    // 2. Add a simulated Heart Rate Sensor peripheral
    const hr_addr = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF } };
    var dev = MockDevice{ .address = hr_addr, .rssi = -60 };
    dev.setName("SimulatedHRM");

    var hr_char = MockCharacteristic{
        .uuid = UUID.from16(0x2A37), // Heart Rate Measurement
        .can_read = true,
        .can_write = true,
        .can_notify = true,
    };
    hr_char.setValue(&[_]u8{ 0x00, 72 }); // 72 bpm
    _ = dev.addCharacteristic(hr_char);
    _ = try mock.addDevice(dev);

    // 3. Scan for devices
    const ScanTester = struct {
        found_count: usize = 0,
        last_name: [64]u8 = undefined,
        last_name_len: u8 = 0,

        fn onScan(d: *const DiscoveredDevice, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.found_count += 1;
            if (d.getName()) |n| {
                @memcpy(self.last_name[0..n.len], n);
                self.last_name_len = @intCast(n.len);
            }
        }
    };

    var tester = ScanTester{};
    try backend.startScan(.{}, ScanTester.onScan, &tester);
    try std.testing.expectEqual(@as(usize, 1), tester.found_count);
    try std.testing.expectEqualStrings("SimulatedHRM", tester.last_name[0..tester.last_name_len]);
    try backend.stopScan();

    // 4. Connect to device
    const dev_handle = try backend.connectDevice(hr_addr, 1000);
    try std.testing.expect(backend.isDeviceConnected(dev_handle));

    // 5. Read characteristic value
    var read_buf: [16]u8 = undefined;
    const bytes_read = try backend.readCharacteristic(dev_handle, UUID.from16(0x2A37), &read_buf);
    try std.testing.expectEqual(@as(usize, 2), bytes_read);
    try std.testing.expectEqual(@as(u8, 72), read_buf[1]);

    // 6. Write characteristic value
    try backend.writeCharacteristic(dev_handle, UUID.from16(0x2A37), &[_]u8{ 0x00, 85 }, true);
    const bytes_read_after = try backend.readCharacteristic(dev_handle, UUID.from16(0x2A37), &read_buf);
    try std.testing.expectEqual(@as(usize, 2), bytes_read_after);
    try std.testing.expectEqual(@as(u8, 85), read_buf[1]);

    // 7. Subscribe and trigger notifications
    const NotifyTester = struct {
        received_bpm: u8 = 0,
        fn onNotify(uuid: UUID, data: []const u8, udata: ?*anyopaque) void {
            _ = uuid;
            const self: *@This() = @ptrCast(@alignCast(udata));
            if (data.len >= 2) self.received_bpm = data[1];
        }
    };

    var notify_tester = NotifyTester{};
    try backend.subscribeNotifications(dev_handle, UUID.from16(0x2A37), NotifyTester.onNotify, &notify_tester);

    try mock.triggerNotification(hr_addr, UUID.from16(0x2A37), &[_]u8{ 0x00, 92 });
    try std.testing.expectEqual(@as(u8, 92), notify_tester.received_bpm);

    // 8. Disconnect
    try backend.disconnectDevice(dev_handle);
    try std.testing.expect(!backend.isDeviceConnected(dev_handle));
}
