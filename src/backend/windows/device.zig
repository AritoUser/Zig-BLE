//! # WinRT Device & Characteristic Contexts
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.zig_ble);

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const NotificationCallback = types.NotificationCallback;
const CharacteristicSelector = types.CharacteristicSelector;

/// Configurable static pool dimensions for zero-allocation Windows BLE device, service, and characteristic slots.
pub const PoolConfig = struct {
    max_devices: usize = 8,
    max_services_per_device: usize = 16,
    max_characteristics_per_device: usize = 64,
};

pub const WinCharacteristicSlot = struct {
    uuid: UUID = UUID.from16(0),
    service_uuid: UUID = UUID.from16(0),
    char_ptr: ?*bindings.IGattCharacteristic = null,
    value_changed_token: bindings.EventRegistrationToken = 0,
    is_subscribed: bool = false,
    value_changed_handler: bindings.GattValueChangedHandler = undefined,
    parent_device: ?*anyopaque = null,
    notify_cb: ?NotificationCallback = null,
    notify_user_data: ?*anyopaque = null,

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
        /// Written by WinRT `ConnectionStatusChanged` threads, hence atomic.
        is_connected: std.atomic.Value(bool) = .init(false),
        connection_state: std.atomic.Value(types.ConnectionState) = .init(.disconnected),
        /// Guarded by the backend's `state_mutex`.
        auto_resubscribe: bool = false,
        saved_subscriptions: types.SavedSubscriptions = .{},
        /// Windows restored the link itself; `processEvents` writes the CCCDs again.
        resubscribe_pending: std.atomic.Value(bool) = .init(false),
        was_connected_once: bool = false,
        ble_device: ?*bindings.IBluetoothLEDevice = null,
        ble_device3: ?*bindings.IBluetoothLEDevice3 = null,
        /// GATT session with `MaintainConnection = true`; keeps Windows from dropping an idle link.
        gatt_session: ?*bindings.IGattSession = null,

        conn_status_token: bindings.EventRegistrationToken = 0,
        conn_status_registered: bool = false,
        conn_status_handler: bindings.ConnectionStatusChangedHandler = undefined,
        parent_backend: ?*BackendType = null,

        services: [pool_config.max_services_per_device]?*bindings.IGattDeviceService = @splat(null),
        services_len: u8 = 0,

        characteristics: [pool_config.max_characteristics_per_device]WinCharacteristicSlot = @splat(.{}),
        characteristics_len: u8 = 0,

        mtu: u16 = 23,
        bond_state: types.BondState = .not_bonded,
        /// Set by `pair` / `unpair`: the DeviceInformation of `ble_device` is a snapshot from
        /// when it was opened and misses a pairing done since.
        bond_changed: bool = false,

        pub fn findCharacteristic(self: *Self, char: CharacteristicSelector) ?*WinCharacteristicSlot {
            const chars = self.characteristics[0..self.characteristics_len];
            const idx = char.find(chars) orelse return null;
            return &chars[idx];
        }

        /// Appends a characteristic in discovery (attribute-handle) order. Characteristics with
        /// the same UUID, e.g. several HID reports, each get their own slot.
        pub fn addCharacteristic(self: *Self, service_uuid: UUID, uuid: UUID, ptr: *bindings.IGattCharacteristic) BleError!void {
            if (self.characteristics_len >= self.characteristics.len) {
                if (builtin.os.tag == .windows) {
                    _ = ptr.lpVtbl.Release(ptr);
                }
                return BleError.PoolExhausted;
            }
            self.characteristics[self.characteristics_len] = .{
                .uuid = uuid,
                .service_uuid = service_uuid,
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

        /// Stops delivering notifications without touching the WinRT registrations, so it is
        /// safe on WinRT callback threads. The caller holds the backend's `state_mutex`.
        pub fn dropNotificationCallbacks(self: *Self) void {
            for (self.characteristics[0..self.characteristics_len]) |*ch| {
                ch.notify_cb = null;
                ch.notify_user_data = null;
            }
        }

        /// Ends all notification subscriptions and removes their WinRT registrations.
        /// Must not be called with `state_mutex` held (it calls into WinRT).
        pub fn clearSubscriptions(self: *Self) void {
            if (self.parent_backend) |backend| {
                backend.state_mutex.lock();
                defer backend.state_mutex.unlock();
                self.dropNotificationCallbacks();
            } else {
                self.dropNotificationCallbacks();
            }
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
        }

        /// Runs on WinRT threads. Only touches state guarded by `state_mutex` and calls the
        /// application's callbacks after releasing it; WinRT registrations are left for the
        /// next backend call to clean up.
        pub fn handleConnectionStatusTransition(self: *Self, connected: bool) void {
            const backend = self.parent_backend orelse {
                self.is_connected.store(connected, .release);
                self.connection_state.store(if (connected) .connected else .disconnected, .release);
                if (!connected and !self.auto_resubscribe) self.dropNotificationCallbacks();
                return;
            };
            if (backend.is_closed.load(.acquire)) return;

            var event: ?types.ConnectionEvent = null;
            var reconnected = false;
            var conn_cb: ?types.ConnectionEventCallback = null;
            var conn_ud: ?*anyopaque = null;
            var reconnect_cb: ?BackendType.ReconnectCallbackFn = null;
            var reconnect_ud: ?*anyopaque = null;
            {
                backend.state_mutex.lock();
                defer backend.state_mutex.unlock();
                const was_connected = self.is_connected.swap(connected, .acq_rel);
                self.connection_state.store(if (connected) .connected else .disconnected, .release);
                if (!connected) {
                    if (!self.auto_resubscribe) self.dropNotificationCallbacks();
                    // WinRT does not report a disconnect reason.
                    if (was_connected) event = .{ .disconnected = .{ .address = self.address, .reason_code = null } };
                } else if (!was_connected) {
                    event = .{ .connected = .{ .address = self.address } };
                    reconnected = self.was_connected_once;
                    self.was_connected_once = true;
                    if (self.auto_resubscribe) self.resubscribe_pending.store(true, .release);
                }
                conn_cb = backend.connection_event_cb;
                conn_ud = backend.connection_event_user_data;
                reconnect_cb = backend.reconnect_cb;
                reconnect_ud = backend.reconnect_user_data;
            }

            if (backend.is_closed.load(.acquire)) return;
            if (event) |ev| {
                if (conn_cb) |cb| cb(ev, conn_ud);
            }
            if (reconnected) {
                if (reconnect_cb) |cb| cb(self.address, reconnect_ud);
            }
        }

        /// Turns notifications and indications off on the peer, before the link is given up.
        /// Windows keeps a link whose peer still sends indications, even after every object
        /// of the device is released, so a disconnect without this never reaches the air.
        pub fn disableSubscriptionsOnPeer(self: *Self, timeout_ms: u32) void {
            if (builtin.os.tag != .windows) return;
            if (!self.is_connected.load(.acquire)) return;
            for (self.characteristics[0..self.characteristics_len]) |*slot| {
                if (!slot.is_subscribed) continue;
                const ch = slot.char_ptr orelse continue;
                var op: ?*bindings.IAsyncOperationGeneric = null;
                if (ch.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(ch, .None, &op) < 0 or op == null) continue;
                _ = helpers.awaitAsync(op.?, timeout_ms) catch |err| {
                    log.debug("WinRT CCCD disable of {f} before disconnect failed: {s}", .{ slot.uuid, @errorName(err) });
                    // On a link that is gone or stuck the remaining writes would wait as long.
                    if (err == BleError.ConnectionTimeout) return;
                };
            }
        }

        /// Releases discovered services and characteristics; the connection stays up.
        pub fn releaseGatt(self: *Self) void {
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
            }
            self.services_len = 0;
        }

        pub fn releaseAll(self: *Self) void {
            self.conn_status_handler.deactivate();
            self.releaseGatt();

            if (builtin.os.tag == .windows) {
                if (self.gatt_session) |sess| {
                    _ = sess.lpVtbl.put_MaintainConnection(sess, 0);
                    var closable: ?*bindings.IClosable = null;
                    if (sess.lpVtbl.QueryInterface(sess, &bindings.IID_IClosable, @ptrCast(&closable)) >= 0) {
                        if (closable) |cl| {
                            _ = cl.lpVtbl.Close(cl);
                            _ = cl.lpVtbl.Release(cl);
                        }
                    }
                    _ = sess.lpVtbl.Release(sess);
                    self.gatt_session = null;
                }

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
            self.is_connected.store(false, .release);
        }
    };
}

