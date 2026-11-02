//! # BlueZ backend: D-Bus signal handling
//!
//! Turns BlueZ signals into state changes and scan results. Runs with the backend mutex held
//! and collects callbacks, which `PendingCallbacks.fire` invokes after the mutex is released.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const core = @import("../../core/mod.zig");
const object_manager = @import("../../bluez/object_manager.zig");
const constants = @import("../../bluez/constants.zig");
const wire = @import("../../dbus/wire/mod.zig");
const context_mod = @import("context.zig");
const mod = @import("mod.zig");

const dbus = if (builtin.os.tag == .linux) @import("../../dbus/mod.zig") else struct {};
const gatt_client = if (builtin.os.tag == .linux) @import("../../gatt_client.zig") else struct {};

const log = std.log.scoped(.zig_ble);
const BlueZ = constants.BlueZ;
const BluezBackend = mod.BluezBackend;
const Address = types.Address;
const UUID = types.UUID;
const DiscoveredDevice = types.DiscoveredDevice;
const ScanCallback = types.ScanCallback;
const NotificationCallback = types.NotificationCallback;
const ConnectionEvent = types.ConnectionEvent;
const ConnectionEventCallback = types.ConnectionEventCallback;
const DaemonRestartCallback = context_mod.DaemonRestartCallback;

/// Callbacks collected while the backend mutex is held and invoked after it is released.
pub const PendingCallbacks = struct {
    const Pending = union(enum) {
        scan: struct { cb: ScanCallback, user_data: ?*anyopaque, device: DiscoveredDevice },
        /// `data` points into the D-Bus message, which outlives `fire`.
        notification: struct { cb: NotificationCallback, user_data: ?*anyopaque, uuid: UUID, data: []const u8 },
        connection: struct { cb: ConnectionEventCallback, user_data: ?*anyopaque, event: ConnectionEvent },
        daemon_restart: struct { cb: DaemonRestartCallback, user_data: ?*anyopaque },
    };

    /// One message yields at most one event per device slot plus one daemon event.
    items: [16]Pending = undefined,
    len: usize = 0,

    pub fn push(self: *PendingCallbacks, item: Pending) void {
        if (self.len == self.items.len) {
            log.warn("BlueZ event dropped: more than {d} callbacks for one D-Bus signal", .{self.items.len});
            return;
        }
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn fire(self: *const PendingCallbacks, backend: *const BluezBackend) void {
        for (self.items[0..self.len]) |item| {
            if (backend.is_closed.load(.acquire)) return;
            switch (item) {
                .scan => |e| e.cb(&e.device, e.user_data),
                .notification => |e| e.cb(e.uuid, e.data, e.user_data),
                .connection => |e| e.cb(e.event, e.user_data),
                .daemon_restart => |e| e.cb(e.user_data),
            }
        }
    }
};

pub fn collectSignal(self: *BluezBackend, msg: *const wire.Message, pending: *PendingCallbacks) void {
    if (self.is_closed.load(.acquire)) return;
    if (msg.fixed_header.msg_type != .signal) return;

    const iface = msg.getInterface() orelse return;
    const member = msg.getMember() orelse return;

    // 1. Detect bluetoothd restart via org.freedesktop.DBus.NameOwnerChanged
    if (std.mem.eql(u8, iface, "org.freedesktop.DBus") and std.mem.eql(u8, member, "NameOwnerChanged")) {
        var it = msg.iterator();
        const bus_name = it.getString() orelse return;
        const old_owner = it.getString() orelse return;
        const new_owner = it.getString() orelse return;

        if (std.mem.eql(u8, bus_name, BlueZ.service_name)) {
            if (old_owner.len > 0 and new_owner.len == 0) {
                log.info("bluetoothd daemon disconnected from D-Bus; cleaning up active BLE sessions", .{});
                handleDaemonDown(self, pending);
            } else if (new_owner.len > 0) {
                log.info("bluetoothd daemon restarted (new owner: {s}); recovering adapter state", .{new_owner});
                if (self.daemon_restart_cb) |cb| {
                    pending.push(.{ .daemon_restart = .{ .cb = cb, .user_data = self.daemon_restart_user_data } });
                }
            }
        }
        return;
    }

    // 2. New devices while scanning via org.freedesktop.DBus.ObjectManager.InterfacesAdded
    if (std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and
        std.mem.eql(u8, member, BlueZ.ObjectManager.Signals.InterfacesAdded))
    {
        var it = msg.iterator();
        const added_path = it.getObjectPath() orelse return;
        if (!self.scanning or !isDevicePathOnAdapter(self, added_path)) return;

        const Visitor = struct {
            backend: *BluezBackend,
            pending: *PendingCallbacks,
            pub fn onDevice(v: *@This(), info: object_manager.DeviceInfo) void {
                reportScanResult(v.backend, info.address, &info, true, v.pending);
            }
        };
        var visitor = Visitor{ .backend = self, .pending = pending };
        object_manager.parseInterfacesAdded(added_path, &it, Visitor, &visitor);
        return;
    }

    // 3. Disconnect reason via org.bluez.Device1.Disconnected (BlueZ 5.71+). Whichever of this
    //    signal and `Connected = false` comes first reports the disconnect; the reason is
    //    only known if this signal is first.
    if (std.mem.eql(u8, iface, BlueZ.Device1.interface_name) and
        std.mem.eql(u8, member, BlueZ.Device1.Signals.Disconnected))
    {
        const path = msg.getPath() orelse return;
        var it = msg.iterator();
        const reason = it.getString() orelse return;
        handleDeviceDisconnectedPath(self, path, disconnectReasonCode(reason), pending);
        return;
    }

    // 4. Detect device removal via org.freedesktop.DBus.ObjectManager.InterfacesRemoved
    if (std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and
        std.mem.eql(u8, member, BlueZ.ObjectManager.Signals.InterfacesRemoved))
    {
        var it = msg.iterator();
        const removed_path = it.getObjectPath() orelse return;
        if (it.recurse()) |arr_val| {
            var arr = arr_val;
            while (arr.getString()) |removed_iface| {
                if (std.mem.eql(u8, removed_iface, BlueZ.Device1.interface_name)) {
                    handleDeviceDisconnectedPath(self, removed_path, null, pending);
                    break;
                }
            }
        }
        return;
    }

    // 5. PropertiesChanged on Device1 (Connected, advertisement data) or GattCharacteristic1 (Value)
    if (std.mem.eql(u8, iface, BlueZ.Properties.interface_name) and
        std.mem.eql(u8, member, BlueZ.Properties.Signals.PropertiesChanged))
    {
        const path = msg.getPath() orelse return;
        var it = msg.iterator();
        const changed_iface = it.getString() orelse return;
        var dict = it.recurse() orelse return;

        if (std.mem.eql(u8, changed_iface, BlueZ.Device1.interface_name)) {
            if (self.scanning and isDevicePathOnAdapter(self, path)) {
                var props = dict;
                const info = object_manager.parseDeviceProps(path, &props);
                const has_adv_data = info.rssi != null or info.tx_power != null or info.name_len > 0 or
                    info.service_data_uuid != null or
                    info.manufacturer_id != null or info.service_uuids_len > 0;
                if (has_adv_data) {
                    if (BlueZ.parseAddressFromDevicePath(path)) |addr| {
                        reportScanResult(self, addr, &info, false, pending);
                    }
                }
            }
            while (dict.hasMore()) {
                if (dict.recurse()) |entry_val| {
                    var entry = entry_val;
                    const prop_name = entry.getString() orelse break;
                    if (entry.getVariant()) |var_val| {
                        var v = var_val;
                        if (std.mem.eql(u8, prop_name, BlueZ.Device1.Properties.Connected)) {
                            if (v.getBool()) |connected| {
                                if (!connected) {
                                    handleDeviceDisconnectedPath(self, path, null, pending);
                                } else {
                                    handleDeviceConnectedPath(self, path, pending);
                                }
                            }
                        } else if (std.mem.eql(u8, prop_name, BlueZ.Device1.Properties.ServicesResolved)) {
                            if (v.getBool()) |resolved| {
                                if (resolved) {
                                    if (self.findDeviceByPath(path)) |dev| {
                                        if (dev.external_reconnect) {
                                            dev.external_reconnect = false;
                                            dev.resubscribe_pending = dev.auto_resubscribe;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (!dict.next()) break;
            }
        } else if (std.mem.eql(u8, changed_iface, BlueZ.GattCharacteristic1.interface_name)) {
            while (dict.hasMore()) {
                if (dict.recurse()) |entry_val| {
                    var entry = entry_val;
                    const prop_name = entry.getString() orelse break;
                    if (entry.getVariant()) |var_val| {
                        var v = var_val;
                        if (std.mem.eql(u8, prop_name, BlueZ.GattCharacteristic1.Properties.Value)) {
                            if (v.getFixedBytes()) |bytes| {
                                dispatchNotificationForPath(self, path, bytes, pending);
                            }
                        }
                    }
                }
                if (!dict.next()) break;
            }
        }
    }
}

/// True for `<adapter_path>/dev_*` objects of the opened adapter.
pub fn isDevicePathOnAdapter(self: *const BluezBackend, path: []const u8) bool {
    const adapter = self.getAdapterPath();
    if (adapter.len == 0 or !std.mem.startsWith(u8, path, adapter)) return false;
    const rest = path[adapter.len..];
    return std.mem.startsWith(u8, rest, "/dev_") and std.mem.indexOfScalarPos(u8, rest, 1, '/') == null;
}

/// Merges `info` into the scan cache entry for `address`. `full` marks a complete property
/// set (InterfacesAdded, GetManagedObjects) that also carries the address type.
pub fn mergeScanInfo(self: *BluezBackend, address: Address, info: *const object_manager.DeviceInfo, full: bool) *DiscoveredDevice {
    const dev = self.scan_cache.get(address);
    if (full) dev.address_type = info.address_type;
    if (info.rssi) |rssi| dev.rssi = rssi;
    if (info.tx_power) |tx| dev.tx_power = tx;
    if (info.getName()) |name| dev.setName(name);
    if (info.manufacturer_id) |company| dev.setManufacturerData(company, info.getManufacturerData().?);
    if (info.service_data_uuid) |s_uuid| dev.setServiceData(s_uuid, info.service_data_buf[0..info.service_data_len]);
    if (info.service_uuids_len > 0) {
        dev.service_uuids_len = 0;
        for (info.getServiceUuids()) |uuid| _ = dev.addServiceUuid(uuid);
    }
    return dev;
}

pub fn reportScanResult(self: *BluezBackend, address: Address, info: *const object_manager.DeviceInfo, full: bool, pending: *PendingCallbacks) void {
    const dev = mergeScanInfo(self, address, info, full);
    // Cached objects from earlier scans carry no RSSI until the device is actually heard.
    if (dev.rssi == null) return;
    if (!self.scan_filter.matches(dev)) return;
    if (self.active_scan_cb) |cb| {
        pending.push(.{ .scan = .{ .cb = cb, .user_data = self.active_scan_user_data, .device = dev.* } });
    }
}

pub fn handleDaemonDown(self: *BluezBackend, pending: *PendingCallbacks) void {
    self.scanning = false;
    for (&self.devices) |*dev| {
        if (dev.in_use and dev.is_connected) {
            dev.is_connected = false;
            dev.connection_state.store(.disconnected, .release);
            dev.endSubscriptionsWithLink();
            pushConnectionEvent(self, .{ .disconnected = .{ .address = dev.address, .reason_code = null } }, pending);
        }
    }
}

pub fn pushConnectionEvent(self: *BluezBackend, event: ConnectionEvent, pending: *PendingCallbacks) void {
    if (self.connection_event_cb) |cb| {
        pending.push(.{ .connection = .{ .cb = cb, .user_data = self.connection_event_user_data, .event = event } });
    }
}

pub fn handleDeviceConnectedPath(self: *BluezBackend, path: []const u8, pending: *PendingCallbacks) void {
    if (self.findDeviceByPath(path)) |dev| {
        if (!dev.is_connected) {
            dev.is_connected = true;
            dev.connection_state.store(.connected, .release);
            dev.external_reconnect = true;
            pushConnectionEvent(self, .{ .connected = .{ .address = dev.address } }, pending);
        }
    }
}

/// Maps `org.bluez.Reason.*` to the HCI reason code it stands for.
pub fn disconnectReasonCode(reason: []const u8) ?u8 {
    const R = BlueZ.Device1.Reasons;
    if (std.mem.eql(u8, reason, R.Timeout)) return 0x08; // Connection Timeout
    if (std.mem.eql(u8, reason, R.Remote)) return 0x13; // Remote User Terminated Connection
    if (std.mem.eql(u8, reason, R.Local)) return 0x16; // Connection Terminated By Local Host
    if (std.mem.eql(u8, reason, R.Authentication)) return 0x05; // Authentication Failure
    return null;
}

pub fn handleDeviceDisconnectedPath(self: *BluezBackend, path: []const u8, reason_code: ?u8, pending: *PendingCallbacks) void {
    if (self.findDeviceByPath(path)) |dev| {
        const was_connected = dev.is_connected;
        dev.is_connected = false;
        dev.connection_state.store(.disconnected, .release);
        dev.endSubscriptionsWithLink();
        if (was_connected) {
            pushConnectionEvent(self, .{ .disconnected = .{ .address = dev.address, .reason_code = reason_code } }, pending);
        }
    }
}

pub fn dispatchNotificationForPath(self: *BluezBackend, char_path: []const u8, payload: []const u8, pending: *PendingCallbacks) void {
    if (self.pcap_hook) |hook| {
        var pdu_buf: [517]u8 = undefined;
        pdu_buf[0] = @intFromEnum(core.AttOpcode.handle_value_ntf);
        pdu_buf[1] = 0x01;
        pdu_buf[2] = 0x00;
        const copy_len = @min(pdu_buf.len - 3, payload.len);
        @memcpy(pdu_buf[3 .. 3 + copy_len], payload[0..copy_len]);
        hook.emit(.controller_to_host, pdu_buf[0 .. 3 + copy_len]);
    }

    for (&self.devices) |*dev| {
        if (!dev.in_use or !dev.is_connected) continue;
        const ch = dev.findCharacteristicByPath(char_path) orelse continue;
        if (ch.notify_cb) |cb| {
            pending.push(.{ .notification = .{ .cb = cb, .user_data = ch.notify_user_data, .uuid = ch.uuid, .data = payload } });
        }
        return;
    }
}

/// Loads the names and advertisement data BlueZ already knows, so devices that only send
/// an `RSSI` update after `StartDiscovery` are still reported with their name.
pub fn seedScanCache(self: *BluezBackend, conn_ptr: anytype) void {
    self.scan_cache.reset();
    var msg = dbus.Connection.createMethodCall(
        BlueZ.service_name,
        BlueZ.root_path,
        BlueZ.ObjectManager.interface_name,
        BlueZ.ObjectManager.Methods.GetManagedObjects,
    ) catch return;
    defer msg.deinit();
    var reply = conn_ptr.sendMessage(&msg, std.math.lossyCast(i32, self.timeouts.discovery_ms)) catch |err| {
        log.debug("BlueZ GetManagedObjects before scan failed: {s}", .{@errorName(err)});
        return;
    };
    defer reply.deinit();

    const Visitor = struct {
        backend: *BluezBackend,
        pub fn onDevice(v: *@This(), info: object_manager.DeviceInfo) void {
            if (!isDevicePathOnAdapter(v.backend, info.getObjectPath())) return;
            const dev = mergeScanInfo(v.backend, info.address, &info, true);
            // A cached RSSI is stale; only a fresh advertisement makes a device reportable.
            dev.rssi = null;
        }
    };
    var visitor = Visitor{ .backend = self };
    var it = reply.iterator();
    object_manager.parseManagedObjects(&it, Visitor, &visitor);
}

/// Subscribes again on links BlueZ restored by itself. Caller holds `mutex`.
pub fn resubscribeRestoredLinks(self: *BluezBackend, conn_ptr: anytype) void {
    for (&self.devices) |*dev| {
        if (!dev.resubscribe_pending) continue;
        dev.resubscribe_pending = false;
        if (!dev.in_use or !dev.is_connected) continue;
        for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
            if (ch.notify_cb == null or ch.is_notifying) continue;
            var gch = gatt_client.GattCharacteristic.init(conn_ptr, ch.getPath());
            gch.startNotify() catch |err| {
                log.warn("BlueZ resubscribe failed for {s}: {s}", .{ ch.getPath(), @errorName(err) });
                continue;
            };
            ch.is_notifying = true;
        }
    }
}
