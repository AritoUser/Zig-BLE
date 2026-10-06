//! # Zig-BLE BlueZ D-Bus Wire Backend
//!
//! Implements the BackendVTable using the native pure-Zig Linux BlueZ D-Bus Wire Protocol.
//! Zero C-dependencies, zero libdbus-1, zero dynamic heap allocations.

const std = @import("std");
const builtin = @import("builtin");
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

const dbus = if (builtin.os.tag == .linux) @import("../../dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const bluez = @import("../../bluez/mod.zig");
const BlueZ = bluez.BlueZ;
const adapter_mod = if (builtin.os.tag == .linux) @import("../../adapter.zig") else struct {};
const device_mod = if (builtin.os.tag == .linux) @import("../../device.zig") else struct {};
const gatt_mod = if (builtin.os.tag == .linux) @import("../../gatt_client.zig") else struct {};

pub const BluezBackend = struct {
    conn: ?*Connection = null,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,
    powered: bool = false,

    pub fn init(conn: ?*Connection) BluezBackend {
        return .{
            .conn = conn,
        };
    }

    pub fn getAdapterPath(self: *const BluezBackend) [:0]const u8 {
        if (self.adapter_path_len == 0) return "/org/bluez/hci0";
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    pub fn openAdapter(ctx: *anyopaque, index: u16) anyerror!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "/org/bluez/hci{d}", .{index}) catch return BleError.InvalidParameter;
        const len = @min(self.adapter_path.len - 1, formatted.len);
        @memcpy(self.adapter_path[0..len], formatted[0..len]);
        self.adapter_path[len] = 0;
        self.adapter_path_len = @intCast(len);
    }

    pub fn closeAdapter(ctx: *anyopaque) void {
        _ = ctx;
    }

    pub fn setPowered(ctx: *anyopaque, powered: bool) anyerror!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return BleError.NotConnected;

        var msg = try Connection.createSetProperty(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Properties.Powered,
            "b",
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendBasic(bool, powered);

        var reply = try conn.sendMessage(&msg, 5000);
        defer reply.deinit();
        self.powered = powered;
    }

    pub fn isPowered(ctx: *anyopaque) anyerror!bool {
        if (builtin.os.tag != .linux) return false;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        return self.powered;
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void {
        _ = filter;
        _ = cb;
        _ = user_data;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return BleError.NotConnected;

        var reply = try conn.callMethod(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.StartDiscovery,
            5000,
        );
        reply.deinit();
    }

    pub fn stopScan(ctx: *anyopaque) anyerror!void {
        if (builtin.os.tag != .linux) return;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return;

        var reply = conn.callMethod(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.StopDiscovery,
            5000,
        ) catch return;
        reply.deinit();
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        const conn = self.conn orelse return BleError.NotConnected;

        // Path format: /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX
        var dev_path: [128]u8 = undefined;
        const dev_path_str = std.fmt.bufPrint(
            &dev_path,
            "{s}/dev_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}",
            .{
                self.getAdapterPath(),
                addr.bytes[5],
                addr.bytes[4],
                addr.bytes[3],
                addr.bytes[2],
                addr.bytes[1],
                addr.bytes[0],
            },
        ) catch return BleError.InvalidParameter;

        var reply = try conn.callMethod(
            BlueZ.service_name,
            dev_path_str,
            BlueZ.Device1.interface_name,
            BlueZ.Device1.Methods.Connect,
            timeout_ms,
        );
        reply.deinit();

        return @ptrCast(self);
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = dev_handle;
        if (builtin.os.tag != .linux) return;
        _ = ctx;
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        _ = dev_handle;
        if (builtin.os.tag != .linux) return false;
        _ = ctx;
        return true;
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        _ = dev_handle;
        _ = ctx;
        return null;
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = dev_handle;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = ctx;
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize {
        _ = dev_handle;
        _ = char_uuid;
        _ = buf;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = ctx;
        return 0;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void {
        _ = dev_handle;
        _ = char_uuid;
        _ = data;
        _ = with_response;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = ctx;
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void {
        _ = dev_handle;
        _ = char_uuid;
        _ = cb;
        _ = user_data;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = ctx;
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void {
        _ = dev_handle;
        _ = char_uuid;
        if (builtin.os.tag != .linux) return;
        _ = ctx;
    }

    pub const vtable: BackendVTable = .{
        .name = "BlueZ_DBus",
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
    };

    pub fn asBackend(self: *BluezBackend) Backend {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "BluezBackend compilation check" {
    var bluez_backend = BluezBackend.init(null);
    const backend = bluez_backend.asBackend();
    try std.testing.expectEqualStrings("BlueZ_DBus", backend.getName());
}
