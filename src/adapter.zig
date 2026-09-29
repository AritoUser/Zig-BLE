//! Zig-BLE Adapter: Represents a local Bluetooth controller (e.g. hci0).
//! Wraps the org.bluez.Adapter1 D-Bus interface.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const DBusError = if (builtin.os.tag == .linux) dbus.DBusError else anyerror;
const object_manager = @import("bluez/object_manager.zig");
const AdapterInfo = object_manager.AdapterInfo;

pub const Adapter = struct {
    conn: *Connection,
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,

    pub fn init(conn: *Connection, path: [:0]const u8) Adapter {
        var adapter = Adapter{
            .conn = conn,
        };
        const len = @min(adapter.object_path.len - 1, path.len);
        @memcpy(adapter.object_path[0..len], path[0..len]);
        adapter.object_path[len] = 0;
        adapter.object_path_len = @intCast(len);
        return adapter;
    }

    pub fn getObjectPath(self: *const Adapter) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    /// Finds the first available Bluetooth adapter on the system bus.
    pub fn findDefault(conn: *Connection) !?Adapter {
        if (builtin.os.tag != .linux) return null;

        var reply = try conn.callMethod(
            BlueZ.service_name,
            BlueZ.root_path,
            BlueZ.ObjectManager.interface_name,
            BlueZ.ObjectManager.Methods.GetManagedObjects,
            5000,
        );
        defer reply.deinit();

        const Finder = struct {
            found_path: ?[128]u8 = null,
            found_len: u8 = 0,

            pub fn onAdapter(self: *@This(), info: AdapterInfo) void {
                if (self.found_path == null) {
                    var buf: [128]u8 = undefined;
                    const path = info.getObjectPath();
                    const len = @min(buf.len - 1, path.len);
                    @memcpy(buf[0..len], path[0..len]);
                    buf[len] = 0;
                    self.found_path = buf;
                    self.found_len = @intCast(len);
                }
            }
        };

        var finder = Finder{};
        var it = reply.iterator();
        object_manager.parseManagedObjects(&it, Finder, &finder);

        if (finder.found_path) |buf| {
            return Adapter.init(conn, buf[0..finder.found_len :0]);
        }
        return null;
    }

    /// Powers the adapter on or off (Powered = true / false).
    pub fn setPowered(self: *Adapter, powered: bool) !void {
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
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

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();
    }

    pub const DiscoveryFilter = struct {
        transport: ?[:0]const u8 = "le",
        duplicate_data: ?bool = null,
    };

    /// Sets discovery filter parameters (e.g. BLE / LE transport only).
    pub fn setDiscoveryFilter(self: *Adapter, filter: DiscoveryFilter) !void {
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.SetDiscoveryFilter,
        );
        defer msg.deinit();

        var b = msg.builder();
        var dict = try b.openArray("{sv}");
        if (filter.transport) |t| {
            try dict.appendDictString("Transport", t);
        }
        if (filter.duplicate_data) |dup| {
            try dict.appendDictBool("DuplicateData", dup);
        }
        try b.closeContainer(&dict);

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();
    }

    /// Starts BLE discovery / scanning.
    pub fn startDiscovery(self: *Adapter) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.StartDiscovery,
            5000,
        );
        reply.deinit();
    }

    /// Stops BLE discovery / scanning.
    pub fn stopDiscovery(self: *Adapter) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.StopDiscovery,
            5000,
        );
        reply.deinit();
    }

    /// Fetches the current adapter properties.
    pub fn getInfo(self: *Adapter) !AdapterInfo {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.GetAll,
            5000,
        );
        defer reply.deinit();

        var it = reply.iterator();
        return object_manager.parseAdapterProps(self.getObjectPath(), &it);
    }
};
