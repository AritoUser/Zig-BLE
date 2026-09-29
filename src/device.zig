//! Zig-BLE Device: Represents a discovered or connected BLE peripheral (Device1).
//! Encapsulates connection establishment, disconnection, and race-free ServicesResolved synchronization.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const Message = if (builtin.os.tag == .linux) dbus.Message else struct {};
const DBusError = if (builtin.os.tag == .linux) dbus.DBusError else anyerror;
const object_manager = @import("bluez/object_manager.zig");
const DeviceInfo = object_manager.DeviceInfo;

pub const Device = struct {
    conn: *Connection,
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,

    pub fn init(conn: *Connection, path: [:0]const u8) Device {
        var dev = Device{
            .conn = conn,
        };
        const len = @min(dev.object_path.len - 1, path.len);
        @memcpy(dev.object_path[0..len], path[0..len]);
        dev.object_path[len] = 0;
        dev.object_path_len = @intCast(len);
        return dev;
    }

    pub fn getObjectPath(self: *const Device) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    /// Establishes a BLE connection (GAP link establishment).
    pub fn connect(self: *Device) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Device1.interface_name,
            BlueZ.Device1.Methods.Connect,
            30000,
        );
        reply.deinit();
    }

    /// Terminates the active BLE connection (GAP disconnection).
    pub fn disconnect(self: *Device) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Device1.interface_name,
            BlueZ.Device1.Methods.Disconnect,
            5000,
        );
        reply.deinit();
    }

    /// Checks if the peripheral is currently connected.
    pub fn isConnected(self: *Device) !bool {
        return self.getBoolProperty(BlueZ.Device1.Properties.Connected);
    }

    /// Essential to avoid BlueZ race conditions:
    /// Checks whether BlueZ has completely resolved all GATT services and characteristics.
    pub fn areServicesResolved(self: *Device) !bool {
        return self.getBoolProperty(BlueZ.Device1.Properties.ServicesResolved);
    }

    const DeviceSignalEvent = enum {
        services_resolved,
        disconnected,
        none,
    };

    fn checkDevicePropertySignal(msg: *const Message, dev_path: []const u8) DeviceSignalEvent {
        if (builtin.os.tag != .linux) return .none;
        if (msg.getMessageType() != 4) return .none; // DBUS_MESSAGE_TYPE_SIGNAL
        const member = msg.getMember() orelse return .none;
        if (!std.mem.eql(u8, member, "PropertiesChanged")) return .none;
        const path = msg.getPath() orelse return .none;
        if (!std.mem.eql(u8, path, dev_path)) return .none;

        var it = msg.iterator();
        const iface = it.getString() orelse return .none;
        if (!std.mem.eql(u8, iface, BlueZ.Device1.interface_name)) return .none;

        if (it.recurse()) |*dict| {
            var d = dict.*;
            while (d.hasMore()) {
                if (d.recurse()) |*entry| {
                    var e = entry.*;
                    if (e.getString()) |key| {
                        if (std.mem.eql(u8, key, BlueZ.Device1.Properties.ServicesResolved)) {
                            if (e.getVariant()) |*v| {
                                var var_iter = v.*;
                                if (var_iter.getBool()) |resolved| {
                                    if (resolved) return .services_resolved;
                                }
                            }
                        } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Connected)) {
                            if (e.getVariant()) |*v| {
                                var var_iter = v.*;
                                if (var_iter.getBool()) |conn_state| {
                                    if (!conn_state) return .disconnected;
                                }
                            }
                        }
                    }
                }
                _ = d.next();
            }
        }
        return .none;
    }

    /// Blocks on the Linux socket waiting for `ServicesResolved == true`.
    /// Uses native kernel sleeping (pollSocket) and signal-based wakeups without busy waiting.
    pub fn waitForServicesResolved(self: *Device, timeout_ms: u32) !void {
        if (builtin.os.tag != .linux) return;
        if (self.areServicesResolved() catch false) return;
        if (!(self.isConnected() catch false)) return error.Disconnected;

        const step_ms: c_int = 100;
        const max_attempts = (timeout_ms + @as(u32, @intCast(step_ms)) - 1) / @as(u32, @intCast(step_ms));
        var attempts: usize = 0;

        while (attempts < max_attempts) : (attempts += 1) {
            // Kernel sleep via pollSocket on D-Bus file descriptor (0% CPU)
            _ = self.conn.pollSocket(step_ms);

            while (self.conn.popMessage()) |msg| {
                defer msg.deinit();
                const ev = checkDevicePropertySignal(&msg, self.getObjectPath());
                switch (ev) {
                    .services_resolved => return,
                    .disconnected => return error.Disconnected,
                    .none => {},
                }
            }

            // Fallback query once per second
            if (attempts % 10 == 0) {
                if (self.areServicesResolved() catch false) {
                    return;
                }
                if (!(self.isConnected() catch false)) {
                    return error.Disconnected;
                }
            }
        }
        return error.ServicesResolutionTimeout;
    }

    /// Fetches the current device properties.
    pub fn getInfo(self: *Device) !DeviceInfo {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.GetAll,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.Device1.interface_name);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        return object_manager.parseDeviceProps(self.getObjectPath(), &it);
    }

    /// Initiates pairing with the peripheral (Security Manager Protocol).
    /// Uses a 60-second timeout to accommodate user confirmation or passkey entry.
    pub fn pair(self: *Device) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Device1.interface_name,
            BlueZ.Device1.Methods.Pair,
            60000,
        );
        reply.deinit();
    }

    /// Cancels an in-progress pairing attempt.
    pub fn cancelPairing(self: *Device) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Device1.interface_name,
            BlueZ.Device1.Methods.CancelPairing,
            5000,
        );
        reply.deinit();
    }

    /// Marks the peripheral as trusted (or untrusted). Trusted peripherals can
    /// reconnect automatically without user authorization prompts.
    pub fn setTrusted(self: *Device, trusted: bool) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.Set,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        try b.appendString(BlueZ.Device1.Properties.Trusted);
        var v = try b.openVariant("b");
        try v.appendBool(trusted);
        try b.closeContainer(&v);

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();
    }

    /// Checks if the peripheral is marked as trusted in BlueZ.
    pub fn isTrusted(self: *Device) !bool {
        return self.getBoolProperty(BlueZ.Device1.Properties.Trusted);
    }

    /// Checks if the peripheral is currently paired.
    pub fn isPaired(self: *Device) !bool {
        return self.getBoolProperty(BlueZ.Device1.Properties.Paired);
    }

    /// Reads the current signal strength (RSSI in dBm) of the peripheral.
    /// Returns null if the property is absent or the device is out of radio range.
    pub fn getRSSI(self: *Device) !?i16 {
        if (builtin.os.tag != .linux) return null;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.Get,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        try b.appendString(BlueZ.Device1.Properties.RSSI);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getVariant()) |*v| {
            var var_iter = v.*;
            return var_iter.getInt16();
        }
        return null;
    }

    /// Reads the advertised transmit power (TxPower in dBm) of the peripheral.
    pub fn getTxPower(self: *Device) !?i16 {
        if (builtin.os.tag != .linux) return null;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.Get,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        try b.appendString(BlueZ.Device1.Properties.TxPower);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getVariant()) |*v| {
            var var_iter = v.*;
            return var_iter.getInt16();
        }
        return null;
    }

    /// Reads a boolean D-Bus property from the device.
    pub fn getBoolProperty(self: *Device, prop_name: [:0]const u8) !bool {
        if (builtin.os.tag != .linux) return false;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.Get,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.Device1.interface_name);
        try b.appendString(prop_name);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getVariant()) |*v| {
            var var_iter = v.*;
            if (var_iter.getBool()) |val| {
                return val;
            }
        }
        return false;
    }
};

test "Device: init and path handling" {
    var dev = Device.init(undefined, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF");
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", dev.getObjectPath());
}
