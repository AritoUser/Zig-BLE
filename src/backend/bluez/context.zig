//! # Linux BlueZ Backend Contexts & Slots
const std = @import("std");
const types = @import("../types.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const NotificationCallback = types.NotificationCallback;
const CharacteristicSelector = types.CharacteristicSelector;
const CharacteristicProperties = @import("../../core/mod.zig").CharacteristicProperties;

pub const DaemonRestartCallback = *const fn (user_data: ?*anyopaque) void;

pub const ScanCache = types.ScanCache;

pub const BluezCharacteristicSlot = struct {
    uuid: UUID,
    service_uuid: UUID = UUID.from16(0),
    object_path: [224]u8 = undefined,
    object_path_len: u8 = 0,
    is_notifying: bool = false,
    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,
    /// From the `Flags` property; all false when BlueZ did not report any.
    properties: CharacteristicProperties = .{},

    pub fn getPath(self: *const BluezCharacteristicSlot) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn setPath(self: *BluezCharacteristicSlot, p: []const u8) void {
        const len = @min(self.object_path.len - 1, p.len);
        @memcpy(self.object_path[0..len], p[0..len]);
        self.object_path[len] = 0;
        self.object_path_len = @intCast(len);
    }

    /// Object path of the GATT service this characteristic belongs to.
    pub fn getServicePath(self: *const BluezCharacteristicSlot) []const u8 {
        const path = self.getPath();
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[0..slash];
    }

    /// BlueZ names characteristics `.../serviceXXXX/charYYYY` with fixed-width hex handles,
    /// so ordering by path is ordering by attribute handle.
    fn lessThan(_: void, a: BluezCharacteristicSlot, b: BluezCharacteristicSlot) bool {
        return std.mem.lessThan(u8, a.getPath(), b.getPath());
    }
};

pub const BluezDescriptorSlot = struct {
    uuid: UUID,
    object_path: [256]u8 = undefined,
    object_path_len: u16 = 0,

    pub fn getPath(self: *const BluezDescriptorSlot) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn setPath(self: *BluezDescriptorSlot, p: []const u8) void {
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
    connection_state: std.atomic.Value(types.ConnectionState) = .init(.disconnected),
    auto_resubscribe: bool = false,
    saved_subscriptions: types.SavedSubscriptions = .{},
    /// BlueZ restored the link without a `connect` call.
    external_reconnect: bool = false,
    /// Services of an externally restored link are resolved; `processEvents` subscribes again.
    resubscribe_pending: bool = false,
    rssi: ?i16 = null,

    characteristics: [64]BluezCharacteristicSlot = undefined,
    characteristics_len: u8 = 0,

    descriptors: [32]BluezDescriptorSlot = undefined,
    descriptors_len: u8 = 0,

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

    pub fn findCharacteristic(self: *BluezDeviceContext, char: CharacteristicSelector) ?*BluezCharacteristicSlot {
        const chars = self.characteristics[0..self.characteristics_len];
        const idx = char.find(chars) orelse return null;
        return &chars[idx];
    }

    pub fn findCharacteristicByPath(self: *BluezDeviceContext, path: []const u8) ?*BluezCharacteristicSlot {
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            if (std.mem.eql(u8, ch.getPath(), path)) return ch;
        }
        return null;
    }

    /// Adds a characteristic, keyed by its object path: characteristics with the same UUID
    /// (e.g. several HID reports) each get their own slot, and rediscovery keeps existing
    /// slots and their subscriptions.
    pub fn addCharacteristic(self: *BluezDeviceContext, uuid: UUID, path: []const u8, properties: CharacteristicProperties) BleError!void {
        if (self.findCharacteristicByPath(path)) |existing| {
            existing.uuid = uuid;
            existing.properties = properties;
            return;
        }
        if (self.characteristics_len >= self.characteristics.len) {
            return BleError.PoolExhausted;
        }
        var slot = &self.characteristics[self.characteristics_len];
        slot.* = .{ .uuid = uuid, .properties = properties };
        slot.setPath(path);
        self.characteristics_len += 1;
    }

    /// Adds a descriptor, keyed by its object path (`<characteristic path>/descXXXX`).
    pub fn addDescriptor(self: *BluezDeviceContext, uuid: UUID, path: []const u8) BleError!void {
        for (self.descriptors[0..self.descriptors_len]) |*d| {
            if (std.mem.eql(u8, d.getPath(), path)) return;
        }
        if (self.descriptors_len >= self.descriptors.len) return BleError.PoolExhausted;
        var slot = &self.descriptors[self.descriptors_len];
        slot.* = .{ .uuid = uuid };
        slot.setPath(path);
        self.descriptors_len += 1;
    }

    pub fn findDescriptor(self: *BluezDeviceContext, char: *const BluezCharacteristicSlot, uuid: UUID) ?*BluezDescriptorSlot {
        const char_path = char.getPath();
        for (self.descriptors[0..self.descriptors_len]) |*d| {
            const p = d.getPath();
            if (d.uuid.eql(uuid) and p.len > char_path.len and std.mem.startsWith(u8, p, char_path) and p[char_path.len] == '/') return d;
        }
        return null;
    }

    /// Restores attribute-handle order after discovery (`GetManagedObjects` is unordered).
    pub fn sortCharacteristics(self: *BluezDeviceContext) void {
        std.mem.sort(BluezCharacteristicSlot, self.characteristics[0..self.characteristics_len], {}, BluezCharacteristicSlot.lessThan);
    }

    /// Applies the end of a link to the subscriptions: the peer has forgotten them, and only
    /// `auto_resubscribe` keeps their callbacks for the next connection.
    pub fn endSubscriptionsWithLink(self: *BluezDeviceContext) void {
        if (!self.auto_resubscribe) {
            self.clearSubscriptions();
            return;
        }
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            ch.is_notifying = false;
        }
    }

    /// Cleans up all active notification subscriptions upon disconnect or daemon restart.
    pub fn clearSubscriptions(self: *BluezDeviceContext) void {
        for (self.characteristics[0..self.characteristics_len]) |*ch| {
            ch.is_notifying = false;
            ch.notify_cb = null;
            ch.notify_user_data = null;
        }
    }
};

