//! # Linux BlueZ Backend Contexts & Slots
const std = @import("std");
const types = @import("../types.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const NotificationCallback = types.NotificationCallback;

pub const DaemonRestartCallback = *const fn (user_data: ?*anyopaque) void;

pub const BluezCharacteristicSlot = struct {
    uuid: UUID,
    object_path: [224]u8 = undefined,
    object_path_len: u8 = 0,
    is_notifying: bool = false,

    pub fn getPath(self: *const BluezCharacteristicSlot) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn setPath(self: *BluezCharacteristicSlot, p: []const u8) void {
        const len = @min(self.object_path.len - 1, p.len);
        @memcpy(self.object_path[0..len], p[0..len]);
        self.object_path[len] = 0;
        self.object_path_len = @intCast(len);
    }
};

pub const BluezDeviceContext = struct {
    in_use: bool = false,
    address: Address = Address{ .bytes = @splat(0) },
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,
    is_connected: bool = false,
    rssi: ?i16 = null,

    characteristics: [64]BluezCharacteristicSlot = undefined,
    characteristics_len: u8 = 0,

    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,
    subscribed_uuid: ?UUID = null,
    mtu: u16 = 23,

    pub fn getPath(self: *const BluezDeviceContext) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn setPath(self: *BluezDeviceContext, p: []const u8) void {
        const len = @min(self.object_path.len - 1, p.len);
        @memcpy(self.object_path[0..len], p[0..len]);
        self.object_path[len] = 0;
        self.object_path_len = @intCast(len);
    }

    pub fn findCharacteristic(self: *BluezDeviceContext, uuid: UUID) ?*BluezCharacteristicSlot {
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            if (ch.uuid.eql(uuid)) return ch;
        }
        return null;
    }

    pub fn addCharacteristic(self: *BluezDeviceContext, uuid: UUID, path: []const u8) BleError!void {
        if (self.findCharacteristic(uuid)) |existing| {
            existing.setPath(path);
            return;
        }
        if (self.characteristics_len >= self.characteristics.len) {
            return BleError.PoolExhausted;
        }
        var slot = &self.characteristics[self.characteristics_len];
        slot.* = .{ .uuid = uuid };
        slot.setPath(path);
        self.characteristics_len += 1;
    }

    /// Cleans up all active notification subscriptions upon disconnect or daemon restart.
    pub fn clearSubscriptions(self: *BluezDeviceContext) void {
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            ch.is_notifying = false;
        }
        self.notify_cb = null;
        self.notify_user_data = null;
        self.subscribed_uuid = null;
    }
};
