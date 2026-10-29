//! # WinRT Device & Characteristic Contexts
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const NotificationCallback = types.NotificationCallback;

/// Configurable static pool dimensions for zero-allocation Windows BLE device, service, and characteristic slots.
pub const PoolConfig = struct {
    max_devices: usize = 8,
    max_services_per_device: usize = 16,
    max_characteristics_per_device: usize = 64,
};

pub const WinCharacteristicSlot = struct {
    uuid: UUID = UUID.from16(0),
    char_ptr: ?*bindings.IGattCharacteristic = null,
    value_changed_token: bindings.EventRegistrationToken = 0,
    is_subscribed: bool = false,
    value_changed_handler: bindings.GattValueChangedHandler = undefined,
    parent_device: ?*anyopaque = null,

    pub fn release(self: *WinCharacteristicSlot) void {
        if (builtin.os.tag == .windows) {
            self.value_changed_handler.deactivate();
            if (self.char_ptr) |cp| {
                if (self.is_subscribed and self.value_changed_token != 0) {
                    _ = cp.lpVtbl.remove_ValueChanged(cp, self.value_changed_token);
                    self.is_subscribed = false;
                    self.value_changed_token = 0;
                }
                _ = cp.lpVtbl.Release(cp);
                self.char_ptr = null;
            }
        }
    }
};

pub fn DeviceContext(comptime pool_config: PoolConfig, comptime BackendType: type) type {
    return struct {
        const Self = @This();

        in_use: bool = false,
        address: Address = Address{ .bytes = @splat(0) },
        rssi: ?i16 = null,
        is_connected: bool = false,
        was_connected_once: bool = false,
        ble_device: ?*bindings.IBluetoothLEDevice = null,
        ble_device3: ?*bindings.IBluetoothLEDevice3 = null,

        conn_status_token: bindings.EventRegistrationToken = 0,
        conn_status_registered: bool = false,
        conn_status_handler: bindings.ConnectionStatusChangedHandler = undefined,
        parent_backend: ?*BackendType = null,

        services: [pool_config.max_services_per_device]?*bindings.IGattDeviceService = @splat(null),
        services_len: u8 = 0,

        characteristics: [pool_config.max_characteristics_per_device]WinCharacteristicSlot = @splat(.{}),
        characteristics_len: u8 = 0,

        notify_cb: ?NotificationCallback = null,
        notify_user_data: ?*anyopaque = null,
        subscribed_uuid: ?UUID = null,

        mtu: u16 = 23,
        bond_state: types.BondState = .not_bonded,

        pub fn findCharacteristic(self: *Self, uuid: UUID) ?*WinCharacteristicSlot {
            for (self.characteristics[0..self.characteristics_len]) |*ch| {
                if (ch.uuid.eql(uuid)) return ch;
            }
            return null;
        }

        pub fn addCharacteristic(self: *Self, uuid: UUID, ptr: *bindings.IGattCharacteristic) BleError!void {
            if (self.findCharacteristic(uuid)) |existing| {
                if (existing.char_ptr != ptr) {
                    existing.release();
                    existing.char_ptr = ptr;
                }
                return;
            }
            if (self.characteristics_len >= self.characteristics.len) {
                if (builtin.os.tag == .windows) {
                    _ = ptr.lpVtbl.Release(ptr);
                }
                return BleError.PoolExhausted;
            }
            self.characteristics[self.characteristics_len] = .{
                .uuid = uuid,
                .char_ptr = ptr,
                .parent_device = @ptrCast(self),
            };
            self.characteristics_len += 1;
        }

        pub fn addService(self: *Self, svc: *bindings.IGattDeviceService) BleError!void {
            if (self.services_len >= self.services.len) {
                if (builtin.os.tag == .windows) {
                    _ = svc.lpVtbl.Release(svc);
                }
                return BleError.PoolExhausted;
            }
            self.services[self.services_len] = svc;
            self.services_len += 1;
        }

        /// Cleans up all active notification subscriptions when a connection drops.
        pub fn clearSubscriptions(self: *Self) void {
            for (self.characteristics[0..self.characteristics_len]) |*ch| {
                ch.value_changed_handler.deactivate();
                if (builtin.os.tag == .windows) {
                    if (ch.char_ptr) |cp| {
                        if (ch.is_subscribed and ch.value_changed_token != 0) {
                            _ = cp.lpVtbl.remove_ValueChanged(cp, ch.value_changed_token);
                        }
                    }
                }
                ch.is_subscribed = false;
                ch.value_changed_token = 0;
            }
            self.notify_cb = null;
            self.notify_user_data = null;
            self.subscribed_uuid = null;
        }

        pub fn handleConnectionStatusTransition(self: *Self, connected: bool) void {
            const backend = self.parent_backend orelse {
                self.is_connected = connected;
                if (!connected) self.clearSubscriptions();
                return;
            };
            if (backend.is_closed.load(.acquire)) return;

            if (!connected) {
                const was_conn = self.is_connected;
                self.is_connected = false;
                self.clearSubscriptions();
                if (was_conn and !backend.is_closed.load(.acquire)) {
                    if (backend.connection_event_cb) |cb| {
                        cb(.{ .disconnected = .{ .address = self.address, .reason_code = 0x08 } }, backend.connection_event_user_data);
                    }
                }
            } else {
                const was_conn = self.is_connected;
                self.is_connected = true;
                if (!was_conn and !backend.is_closed.load(.acquire)) {
                    if (backend.connection_event_cb) |cb| {
                        cb(.{ .connected = .{ .address = self.address } }, backend.connection_event_user_data);
                    }
                    if (self.was_connected_once) {
                        if (backend.reconnect_cb) |rcb| {
                            rcb(self.address, backend.reconnect_user_data);
                        }
                    }
                    self.was_connected_once = true;
                }
            }
        }

        pub fn releaseAll(self: *Self) void {
            self.conn_status_handler.deactivate();
            for (self.characteristics[0..self.characteristics_len]) |*ch| {
                ch.release();
            }
            self.characteristics_len = 0;

            if (builtin.os.tag == .windows) {
                for (self.services[0..self.services_len]) |maybe_svc| {
                    if (maybe_svc) |svc| {
                        var closable: ?*bindings.IClosable = null;
                        if (svc.lpVtbl.QueryInterface(svc, &bindings.IID_IClosable, @ptrCast(&closable)) >= 0) {
                            if (closable) |cl| {
                                _ = cl.lpVtbl.Close(cl);
                                _ = cl.lpVtbl.Release(cl);
                            }
                        }
                        _ = svc.lpVtbl.Release(svc);
                    }
                }
                self.services_len = 0;

                if (self.ble_device3) |d3| {
                    _ = d3.lpVtbl.Release(d3);
                    self.ble_device3 = null;
                }
                if (self.ble_device) |d| {
                    if (self.conn_status_registered and self.conn_status_token != 0) {
                        _ = d.lpVtbl.remove_ConnectionStatusChanged(d, self.conn_status_token);
                        self.conn_status_registered = false;
                        self.conn_status_token = 0;
                    }
                    var closable: ?*bindings.IClosable = null;
                    if (d.lpVtbl.QueryInterface(d, &bindings.IID_IClosable, @ptrCast(&closable)) >= 0) {
                        if (closable) |cl| {
                            _ = cl.lpVtbl.Close(cl);
                            _ = cl.lpVtbl.Release(cl);
                        }
                    }
                    _ = d.lpVtbl.Release(d);
                    self.ble_device = null;
                }
            }
            self.is_connected = false;
            self.notify_cb = null;
            self.subscribed_uuid = null;
        }
    };
}

