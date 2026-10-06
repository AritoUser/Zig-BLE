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
pub const BleError = types.BleError;
pub const Backend = vtable_mod.Backend;

pub const UnifiedDevice = struct {
    backend: Backend,
    handle: *anyopaque,
    address: Address,

    pub fn disconnect(self: *UnifiedDevice) !void {
        return self.backend.disconnectDevice(self.handle);
    }

    pub fn isConnected(self: *UnifiedDevice) bool {
        return self.backend.isDeviceConnected(self.handle);
    }

    pub fn getRSSI(self: *UnifiedDevice) ?i16 {
        return self.backend.getDeviceRssi(self.handle);
    }

    pub fn discoverServices(self: *UnifiedDevice) !void {
        return self.backend.discoverServices(self.handle);
    }

    pub fn readCharacteristic(self: *UnifiedDevice, uuid: UUID, buf: []u8) !usize {
        return self.backend.readCharacteristic(self.handle, uuid, buf);
    }

    pub fn writeCharacteristic(self: *UnifiedDevice, uuid: UUID, data: []const u8, with_response: bool) !void {
        return self.backend.writeCharacteristic(self.handle, uuid, data, with_response);
    }

    pub fn subscribe(self: *UnifiedDevice, uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) !void {
        return self.backend.subscribeNotifications(self.handle, uuid, cb, user_data);
    }

    pub fn unsubscribe(self: *UnifiedDevice, uuid: UUID) !void {
        return self.backend.unsubscribeNotifications(self.handle, uuid);
    }
};

pub const UnifiedAdapter = struct {
    backend: Backend,

    pub fn init(backend_inst: Backend) UnifiedAdapter {
        return .{ .backend = backend_inst };
    }

    pub fn getBackendName(self: *const UnifiedAdapter) []const u8 {
        return self.backend.getName();
    }

    pub fn setPowered(self: *UnifiedAdapter, powered: bool) !void {
        return self.backend.setPowered(powered);
    }

    pub fn isPowered(self: *UnifiedAdapter) !bool {
        return self.backend.isPowered();
    }

    pub fn startScan(self: *UnifiedAdapter, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) !void {
        return self.backend.startScan(filter, cb, user_data);
    }

    pub fn stopScan(self: *UnifiedAdapter) !void {
        return self.backend.stopScan();
    }

    pub fn connect(self: *UnifiedAdapter, addr: Address, timeout_ms: u32) !UnifiedDevice {
        const handle = try self.backend.connectDevice(addr, timeout_ms);
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
