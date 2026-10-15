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

pub const BluezDevice = struct {
    backend: *BluezBackend,
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,
    address: Address,
    is_active: bool = false,

    characteristics: [64]CharEntry = undefined,
    characteristics_len: u8 = 0,

    pub const CharEntry = struct {
        uuid: UUID,
        path: [224]u8,
        path_len: u8,

        pub fn getPath(self: *const CharEntry) [:0]const u8 {
            return self.path[0..self.path_len :0];
        }
    };

    pub fn getObjectPath(self: *const BluezDevice) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn findCharacteristic(self: *BluezDevice, uuid: UUID) ?*CharEntry {
        for (self.characteristics[0..self.characteristics_len]) |*entry| {
            if (entry.uuid.eql(uuid)) return entry;
        }
        return null;
    }

    pub fn addCharacteristic(self: *BluezDevice, uuid: UUID, path: [:0]const u8) !void {
        if (self.characteristics_len >= self.characteristics.len) return error.OutOfMemory;
        var entry = &self.characteristics[self.characteristics_len];
        entry.uuid = uuid;
        const len = @min(entry.path.len - 1, path.len);
        @memcpy(entry.path[0..len], path[0..len]);
        entry.path[len] = 0;
        entry.path_len = @intCast(len);
        self.characteristics_len += 1;
    }
};

pub const SubContext = struct {
    char_uuid: UUID,
    cb: NotificationCallback,
    user_data: ?*anyopaque,
    active: bool = false,
};

pub const BluezBackend = struct {
    conn: ?*Connection = null,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,
    powered: bool = false,

    scan_cb: ?ScanCallback = null,
    scan_user_data: ?*anyopaque = null,
    scanning: bool = false,

    devices: [16]BluezDevice = undefined,
    devices_len: u8 = 0,

    sub_contexts: [16]SubContext = undefined,
    dispatcher: if (builtin.os.tag == .linux) gatt_mod.NotificationDispatcher else struct {} =
        if (builtin.os.tag == .linux) gatt_mod.NotificationDispatcher.init() else .{},

    pub fn init(conn: ?*Connection) BluezBackend {
        var self = BluezBackend{
            .conn = conn,
            .devices = undefined,
            .devices_len = 0,
            .sub_contexts = undefined,
        };
        for (&self.devices) |*d| {
            d.is_active = false;
        }
        for (&self.sub_contexts) |*s| {
            s.active = false;
        }
        return self;
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
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        for (&self.devices) |*d| {
            d.is_active = false;
        }
        self.scanning = false;
    }

    pub fn setPowered(ctx: *anyopaque, powered: bool) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const conn = self.conn orelse return BleError.NotConnected;

            var msg = try Connection.createMethodCall(
                BlueZ.service_name,
                self.getAdapterPath(),
                BlueZ.Properties.interface_name,
                BlueZ.Properties.Methods.Set,
            );
            defer msg.deinit();

            var b = msg.builder();
            try b.appendString(BlueZ.Adapter1.interface_name);
            try b.appendString(BlueZ.Adapter1.Properties.Powered);
            var v = try b.openVariant("b");
            try v.appendBool(powered);
            try b.closeContainer(&v);

            var reply = try conn.sendMessage(&msg, 5000);
            reply.deinit();
            self.powered = powered;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn isPowered(ctx: *anyopaque) anyerror!bool {
        if (builtin.os.tag != .linux) return false;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        return self.powered;
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const conn = self.conn orelse return BleError.NotConnected;

            self.scan_cb = cb;
            self.scan_user_data = user_data;

            var adapter = adapter_mod.Adapter.init(conn, self.getAdapterPath());
            adapter.setDiscoveryFilter(.{
                .transport = "le",
                .duplicate_data = filter.duplicate_data,
            }) catch {};

            adapter.startDiscovery() catch return BleError.IoError;
            self.scanning = true;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn stopScan(ctx: *anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const conn = self.conn orelse return;

            var adapter = adapter_mod.Adapter.init(conn, self.getAdapterPath());
            adapter.stopDiscovery() catch {};
            self.scanning = false;
            self.scan_cb = null;
            self.scan_user_data = null;
        } else {
            return;
        }
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const conn = self.conn orelse return BleError.NotConnected;

            var dev_path: [160]u8 = undefined;
            const dev_path_str = std.fmt.bufPrintSentinel(
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
                0,
            ) catch return BleError.InvalidParameter;

            var reply = conn.callMethod(
                BlueZ.service_name,
                dev_path_str,
                BlueZ.Device1.interface_name,
                BlueZ.Device1.Methods.Connect,
                @intCast(@min(timeout_ms, std.math.maxInt(i32))),
            ) catch return BleError.ConnectionFailed;
            reply.deinit();

            var slot: ?*BluezDevice = null;
            for (&self.devices) |*d| {
                if (!d.is_active) {
                    slot = d;
                    break;
                }
            }
            const dev = slot orelse return BleError.OutOfMemory;

            dev.* = .{
                .backend = self,
                .address = addr,
                .is_active = true,
                .characteristics = undefined,
                .characteristics_len = 0,
            };
            const len = @min(dev.object_path.len - 1, dev_path_str.len);
            @memcpy(dev.object_path[0..len], dev_path_str[0..len]);
            dev.object_path[len] = 0;
            dev.object_path_len = @intCast(len);

            return @ptrCast(dev);
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return;

            var reply = conn.callMethod(
                BlueZ.service_name,
                dev.getObjectPath(),
                BlueZ.Device1.interface_name,
                BlueZ.Device1.Methods.Disconnect,
                5000,
            ) catch return;
            reply.deinit();
            dev.is_active = false;
        } else {
            return;
        }
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_active) return false;
            const conn = self.conn orelse return false;

            var dev_inst = device_mod.Device.init(conn, dev.getObjectPath());
            return dev_inst.isConnected() catch false;
        } else {
            return false;
        }
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_active) return null;
            const conn = self.conn orelse return null;

            var dev_inst = device_mod.Device.init(conn, dev.getObjectPath());
            return dev_inst.getRSSI() catch null;
        } else {
            return null;
        }
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            var dev_inst = device_mod.Device.init(conn, dev.getObjectPath());
            dev_inst.waitForServicesResolved(15000) catch return BleError.ServiceNotFound;

            var reply = conn.callMethod(
                BlueZ.service_name,
                BlueZ.root_path,
                BlueZ.ObjectManager.interface_name,
                BlueZ.ObjectManager.Methods.GetManagedObjects,
                5000,
            ) catch return BleError.ServiceNotFound;
            defer reply.deinit();

            const Collector = struct {
                target_dev_path: [:0]const u8,
                target_dev: *BluezDevice,

                pub fn onGattCharacteristic(col: *@This(), c: bluez.GattCharacteristicInfo) void {
                    if (std.mem.startsWith(u8, c.getObjectPath(), col.target_dev_path)) {
                        col.target_dev.addCharacteristic(c.uuid, c.getObjectPath()) catch {};
                    }
                }
            };

            var col = Collector{
                .target_dev_path = dev.getObjectPath(),
                .target_dev = dev,
            };
            var it = reply.iterator();
            bluez.parseManagedObjects(&it, Collector, &col);
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            const entry = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            var ch = gatt_mod.GattCharacteristic.init(conn, entry.getPath());
            return ch.readValue(buf) catch BleError.ReadFailed;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            const entry = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            var ch = gatt_mod.GattCharacteristic.init(conn, entry.getPath());
            const write_type: @import("../../core/mod.zig").WriteType = if (with_response) .with_response else .without_response;
            ch.writeValue(data, write_type) catch return BleError.WriteFailed;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            const entry = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            var ch = gatt_mod.GattCharacteristic.init(conn, entry.getPath());
            ch.startNotify() catch return BleError.NotificationFailed;

            var slot: ?*SubContext = null;
            for (&self.sub_contexts) |*s| {
                if (s.active and s.char_uuid.eql(char_uuid)) return;
                if (!s.active and slot == null) slot = s;
            }
            const sub = slot orelse return BleError.OutOfMemory;
            sub.* = .{
                .char_uuid = char_uuid,
                .cb = cb,
                .user_data = user_data,
                .active = true,
            };

            const Handler = struct {
                fn onValue(path: [:0]const u8, data: []const u8, udata: ?*anyopaque) void {
                    _ = path;
                    const s: *SubContext = @ptrCast(@alignCast(udata orelse return));
                    s.cb(s.char_uuid, data, s.user_data);
                }
            };

            self.dispatcher.subscribe(entry.getPath(), Handler.onValue, @ptrCast(sub)) catch {
                sub.active = false;
                return BleError.NotificationFailed;
            };
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return;

            const entry = dev.findCharacteristic(char_uuid) orelse return;
            var ch = gatt_mod.GattCharacteristic.init(conn, entry.getPath());
            ch.stopNotify() catch {};

            for (&self.sub_contexts) |*s| {
                if (s.active and s.char_uuid.eql(char_uuid)) {
                    s.active = false;
                    break;
                }
            }
        } else {
            return;
        }
    }

    pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) anyerror!u16 {
        _ = ctx;
        _ = dev_handle;
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        return target_mtu;
    }

    pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) anyerror!void {
        _ = io_cap;
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            var dev_inst = device_mod.Device.init(conn, dev.getObjectPath());
            dev_inst.pair() catch return BleError.AuthenticationFailed;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            var msg = Connection.createMethodCall(
                BlueZ.service_name,
                self.getAdapterPath(),
                BlueZ.Adapter1.interface_name,
                BlueZ.Adapter1.Methods.RemoveDevice,
            ) catch return BleError.IoError;
            defer msg.deinit();

            var b = msg.builder();
            b.appendObjectPath(dev.getObjectPath()) catch return BleError.IoError;

            var reply = conn.sendMessage(&msg, 5000) catch return BleError.IoError;
            reply.deinit();
            dev.is_active = false;
        } else {
            return BleError.NotSupported;
        }
    }

    pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return .not_bonded;

            var dev_inst = device_mod.Device.init(conn, dev.getObjectPath());
            const is_paired = dev_inst.isPaired() catch false;
            return if (is_paired) .bonded else .not_bonded;
        } else {
            return .not_bonded;
        }
    }

    pub fn acquireNotifyFd(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, out_mtu: *u16) anyerror!std.posix.fd_t {
        if (builtin.os.tag == .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            const dev: *BluezDevice = @ptrCast(@alignCast(dev_handle));
            const conn = self.conn orelse return BleError.NotConnected;

            const entry = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            var ch = gatt_mod.GattCharacteristic.init(conn, entry.getPath());
            const stream = ch.acquireNotify() catch return BleError.IoError;
            out_mtu.* = stream.mtu;
            return stream.fd;
        } else {
            return BleError.NotSupported;
        }
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
        .exchangeMtu = exchangeMtu,
        .pairDevice = pairDevice,
        .unpairDevice = unpairDevice,
        .getBondState = getBondState,
        .acquireNotifyFd = acquireNotifyFd,
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

test "BluezDevice zero-allocation static storage test" {
    var bluez_backend = BluezBackend.init(null);
    var dev: BluezDevice = .{
        .backend = &bluez_backend,
        .address = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } },
        .is_active = true,
        .characteristics = undefined,
        .characteristics_len = 0,
    };

    const dummy_uuid = UUID.from16(0x2A19);
    try dev.addCharacteristic(dummy_uuid, "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002");

    try std.testing.expectEqual(@as(u8, 1), dev.characteristics_len);
    const entry = dev.findCharacteristic(dummy_uuid);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002", entry.?.getPath());
    try std.testing.expect(dev.findCharacteristic(UUID.from16(0x2A37)) == null);
}
