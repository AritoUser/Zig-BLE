//! # Zig-BLE Linux BlueZ Backend Implementation
//!
//! Bridges the unified `BackendVTable` interface with the native, zero-allocation
//! Pure-Zig D-Bus Wire Protocol engine (`src/dbus/`, `src/adapter.zig`, `src/device.zig`, `src/gatt_client.zig`).
//!
//! ## Concurrency & Lifecycle Guarantees
//! - All public backend operations are synchronized via `mutex` (`std.Thread.Mutex`).
//! - Callbacks (`ScanCallback`, `NotificationCallback`, `ConnectionEventCallback`) are invoked
//!   outside internal state mutations and are strictly suppressed once `closeAdapter` / `deinit` begins
//!   (`is_closed` atomic guard).
//! - Handles `PropertiesChanged` (`Connected = false`), `InterfacesRemoved`, and `NameOwnerChanged`
//!   (automatic recovery when `bluetoothd` restarts).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const vtable_mod = @import("../vtable.zig");
const core = @import("../../core/mod.zig");

const log = std.log.scoped(.zig_ble);

pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const ConnectionEvent = types.ConnectionEvent;
pub const ConnectionEventCallback = types.ConnectionEventCallback;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const BleError = types.BleError;
pub const TimeoutConfig = types.TimeoutConfig;
pub const PcapHook = types.PcapHook;
pub const BackendVTable = vtable_mod.BackendVTable;
pub const Backend = vtable_mod.Backend;

// Conditional imports for Linux D-Bus engine
const dbus = if (builtin.os.tag == .linux) @import("../../dbus/mod.zig") else struct {};
const adapter_mod = if (builtin.os.tag == .linux) @import("../../adapter.zig") else struct {};
const device_mod = if (builtin.os.tag == .linux) @import("../../device.zig") else struct {};
const gatt_client = if (builtin.os.tag == .linux) @import("../../gatt_client.zig") else struct {};
const object_manager = @import("../../bluez/object_manager.zig");
const constants = @import("../../bluez/constants.zig");
const BlueZ = constants.BlueZ;
const wire = @import("../../dbus/wire/mod.zig");

pub const context_mod = @import("context.zig");
pub const DaemonRestartCallback = context_mod.DaemonRestartCallback;
pub const BluezCharacteristicSlot = context_mod.BluezCharacteristicSlot;
pub const BluezDeviceContext = context_mod.BluezDeviceContext;

pub const BluezBackend = struct {
    conn: if (builtin.os.tag == .linux) ?dbus.Connection else void = if (builtin.os.tag == .linux) null else {},
    adapter_index: u16 = 0,
    adapter_path: [64]u8 = undefined,
    adapter_path_len: u8 = 0,
    scanning: bool = false,
    active_scan_cb: ?ScanCallback = null,
    active_scan_user_data: ?*anyopaque = null,
    scan_filter: ScanFilter = .{},

    connection_event_cb: ?ConnectionEventCallback = null,
    connection_event_user_data: ?*anyopaque = null,

    daemon_restart_cb: ?DaemonRestartCallback = null,
    daemon_restart_user_data: ?*anyopaque = null,

    timeouts: TimeoutConfig = .{},
    pcap_hook: ?PcapHook = null,
    mutex: types.SyncMutex = .{},
    is_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    devices: [8]BluezDeviceContext = @splat(.{}),

    pub fn init() BluezBackend {
        return .{};
    }

    pub fn initWithTimeouts(timeouts: TimeoutConfig) BluezBackend {
        return .{ .timeouts = timeouts };
    }

    pub fn deinit(self: *BluezBackend) void {
        closeAdapter(@ptrCast(self));
    }

    pub fn setConnectionEventCallback(self: *BluezBackend, cb: ?ConnectionEventCallback, user_data: ?*anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connection_event_cb = cb;
        self.connection_event_user_data = user_data;
    }

    pub fn setDaemonRestartCallback(self: *BluezBackend, cb: ?DaemonRestartCallback, user_data: ?*anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.daemon_restart_cb = cb;
        self.daemon_restart_user_data = user_data;
    }

    pub fn setPcapHook(self: *BluezBackend, hook: ?PcapHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pcap_hook = hook;
    }

    pub fn getAdapterPath(self: *const BluezBackend) [:0]const u8 {
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    pub fn allocateDeviceSlot(self: *BluezBackend, addr: Address) ?*BluezDeviceContext {
        for (&self.devices) |*d| {
            if (d.in_use and d.address.eql(addr)) return d;
        }
        for (&self.devices) |*d| {
            if (!d.in_use) {
                d.* = .{
                    .in_use = true,
                    .address = addr,
                };
                return d;
            }
        }
        return null;
    }

    pub fn findDeviceByAddress(self: *BluezBackend, addr: Address) ?*BluezDeviceContext {
        for (&self.devices) |*d| {
            if (d.in_use and d.address.eql(addr)) return d;
        }
        return null;
    }

    pub fn findDeviceByPath(self: *BluezBackend, path: []const u8) ?*BluezDeviceContext {
        for (&self.devices) |*d| {
            if (d.in_use and std.mem.eql(u8, d.getPath(), path)) return d;
        }
        return null;
    }

    /// Processes a single incoming D-Bus wire message for disconnect signals, notifications,
    /// and `bluetoothd` daemon restart (`NameOwnerChanged`).
    /// Extracted for cross-platform unit testing as well as live Linux D-Bus stepping.
    pub fn processSignalWireMessage(self: *BluezBackend, msg: *const wire.Message) void {
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
                    self.handleDaemonDown();
                } else if (new_owner.len > 0) {
                    log.info("bluetoothd daemon restarted (new owner: {s}); recovering adapter state", .{new_owner});
                    if (self.daemon_restart_cb) |cb| {
                        if (!self.is_closed.load(.acquire)) {
                            cb(self.daemon_restart_user_data);
                        }
                    }
                }
            }
            return;
        }

        // 2. Detect device removal via org.freedesktop.DBus.ObjectManager.InterfacesRemoved
        if (std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and
            std.mem.eql(u8, member, BlueZ.ObjectManager.Signals.InterfacesRemoved))
        {
            var it = msg.iterator();
            const removed_path = it.getObjectPath() orelse return;
            if (it.recurse()) |arr_val| {
                var arr = arr_val;
                while (arr.getString()) |removed_iface| {
                    if (std.mem.eql(u8, removed_iface, BlueZ.Device1.interface_name)) {
                        self.handleDeviceDisconnectedPath(removed_path, 0x08);
                        break;
                    }
                }
            }
            return;
        }

        // 3. Detect PropertiesChanged on Device1 (Connected = false) or GattCharacteristic1 (Value)
        if (std.mem.eql(u8, iface, BlueZ.Properties.interface_name) and
            std.mem.eql(u8, member, BlueZ.Properties.Signals.PropertiesChanged))
        {
            const path = msg.getPath() orelse return;
            var it = msg.iterator();
            const changed_iface = it.getString() orelse return;
            var dict = it.recurse() orelse return;

            if (std.mem.eql(u8, changed_iface, BlueZ.Device1.interface_name)) {
                while (dict.hasMore()) {
                    if (dict.recurse()) |entry_val| {
                        var entry = entry_val;
                        const prop_name = entry.getString() orelse break;
                        if (entry.getVariant()) |var_val| {
                            var v = var_val;
                            if (std.mem.eql(u8, prop_name, BlueZ.Device1.Properties.Connected)) {
                                if (v.getBool()) |connected| {
                                    if (!connected) {
                                        self.handleDeviceDisconnectedPath(path, 0x13);
                                    } else {
                                        self.handleDeviceConnectedPath(path);
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
                                    self.dispatchNotificationForPath(path, bytes);
                                }
                            }
                        }
                    }
                    if (!dict.next()) break;
                }
            }
        }
    }

    fn handleDaemonDown(self: *BluezBackend) void {
        self.scanning = false;
        for (&self.devices) |*dev| {
            if (dev.in_use and dev.is_connected) {
                const addr = dev.address;
                dev.is_connected = false;
                dev.clearSubscriptions();
                if (!self.is_closed.load(.acquire)) {
                    if (self.connection_event_cb) |cb| {
                        cb(.{ .disconnected = .{ .address = addr, .reason_code = 0x08 } }, self.connection_event_user_data);
                    }
                }
            }
        }
    }

    fn handleDeviceConnectedPath(self: *BluezBackend, path: []const u8) void {
        if (self.findDeviceByPath(path)) |dev| {
            if (!dev.is_connected) {
                dev.is_connected = true;
                if (!self.is_closed.load(.acquire)) {
                    if (self.connection_event_cb) |cb| {
                        cb(.{ .connected = .{ .address = dev.address } }, self.connection_event_user_data);
                    }
                }
            }
        }
    }

    fn handleDeviceDisconnectedPath(self: *BluezBackend, path: []const u8, reason_code: u8) void {
        if (self.findDeviceByPath(path)) |dev| {
            const was_connected = dev.is_connected;
            dev.is_connected = false;
            dev.clearSubscriptions();
            if (was_connected and !self.is_closed.load(.acquire)) {
                if (self.connection_event_cb) |cb| {
                    cb(.{ .disconnected = .{ .address = dev.address, .reason_code = reason_code } }, self.connection_event_user_data);
                }
            }
        }
    }

    fn dispatchNotificationForPath(self: *BluezBackend, char_path: []const u8, payload: []const u8) void {
        if (self.is_closed.load(.acquire)) return;
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
            for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
                if (std.mem.eql(u8, ch.getPath(), char_path)) {
                    if (dev.notify_cb) |cb| {
                        if (dev.subscribed_uuid) |sub_uuid| {
                            if (sub_uuid.eql(ch.uuid)) {
                                cb(ch.uuid, payload, dev.notify_user_data);
                            }
                        }
                    }
                    return;
                }
            }
        }
    }

    /// Re-initializes the D-Bus system bus connection and adapter subscription after `bluetoothd` restarts.
    pub fn recoverAfterDaemonRestart(self: *BluezBackend) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        self.handleDaemonDown();

        if (self.conn) |*c| {
            c.deinit();
            self.conn = null;
        }

        self.conn = dbus.Connection.initSystem() catch return BleError.DaemonDisconnected;
        if (self.conn) |*c| {
            c.addMatch("type='signal',sender='org.bluez'") catch |err| {
                log.warn("Failed to register org.bluez signal match rule: {s}", .{@errorName(err)});
            };
            c.addMatch("type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'") catch |err| {
                log.warn("Failed to register NameOwnerChanged match rule: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn openAdapter(ctx: *anyopaque, index: u16) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.is_closed.store(false, .release);
        self.adapter_index = index;

        if (self.conn == null) {
            self.conn = dbus.Connection.initSystem() catch return BleError.AdapterNotFound;
            if (self.conn) |*c| {
                c.addMatch("type='signal',sender='org.bluez'") catch |err| {
                    log.warn("Failed to register org.bluez signal match rule: {s}", .{@errorName(err)});
                };
                c.addMatch("type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'") catch |err| {
                    log.warn("Failed to register NameOwnerChanged match rule: {s}", .{@errorName(err)});
                };
            }
        }

        const formatted = std.fmt.bufPrintSentinel(&self.adapter_path, "/org/bluez/hci{d}", .{index}, 0) catch return BleError.InvalidParameter;
        self.adapter_path_len = @intCast(formatted.len);
    }

    pub fn closeAdapter(ctx: *anyopaque) void {
        if (builtin.os.tag != .linux) {
            const self: *BluezBackend = @ptrCast(@alignCast(ctx));
            self.is_closed.store(true, .release);
            return;
        }
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        // Set closed flag first so no callbacks can fire during or after teardown
        self.is_closed.store(true, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.devices) |*dev| {
            if (dev.in_use) {
                dev.clearSubscriptions();
                dev.is_connected = false;
                dev.in_use = false;
            }
        }
        self.active_scan_cb = null;
        self.active_scan_user_data = null;
        self.connection_event_cb = null;
        self.daemon_restart_cb = null;
        self.scanning = false;

        if (self.conn) |*c| {
            c.deinit();
            self.conn = null;
        }
    }

    pub fn setPowered(ctx: *anyopaque, powered: bool) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;

        var adp = adapter_mod.Adapter.init(conn_ptr, self.getAdapterPath());
        adp.setPowered(powered) catch return BleError.IoError;
    }

    pub fn isPowered(ctx: *anyopaque) BleError!bool {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;

        var adp = adapter_mod.Adapter.init(conn_ptr, self.getAdapterPath());
        const info = adp.getInfo() catch return BleError.IoError;
        return info.powered;
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;

        self.scan_filter = filter;
        self.active_scan_cb = cb;
        self.active_scan_user_data = user_data;

        var adp = adapter_mod.Adapter.init(conn_ptr, self.getAdapterPath());
        adp.setDiscoveryFilter(.{
            .transport = "le",
            .duplicate_data = filter.duplicate_data orelse !filter.filter_duplicates,
        }) catch |err| {
            log.warn("BlueZ SetDiscoveryFilter failed: {s}", .{@errorName(err)});
            return BleError.IoError;
        };

        adp.startDiscovery() catch |err| {
            log.err("BlueZ StartDiscovery failed: {s}", .{@errorName(err)});
            return BleError.IoError;
        };
        self.scanning = true;
    }

    pub fn stopScan(ctx: *anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;

        var adp = adapter_mod.Adapter.init(conn_ptr, self.getAdapterPath());
        self.scanning = false;
        self.active_scan_cb = null;
        self.active_scan_user_data = null;
        adp.stopDiscovery() catch |err| {
            log.warn("BlueZ StopDiscovery failed: {s}", .{@errorName(err)});
            return BleError.IoError;
        };
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) BleError!*anyopaque {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        _ = timeout_ms;

        var dev_slot = self.allocateDeviceSlot(addr) orelse return BleError.PoolExhausted;

        var path_buf: [96]u8 = undefined;
        const d_path = BlueZ.buildDevicePath(&path_buf, self.getAdapterPath(), addr);
        dev_slot.setPath(d_path);

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        dev.connect() catch |err| {
            log.err("BlueZ Device1.Connect failed for {s}: {s}", .{ dev_slot.getPath(), @errorName(err) });
            return BleError.ConnectionFailed;
        };

        dev_slot.is_connected = true;
        return @ptrCast(dev_slot);
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        dev_slot.clearSubscriptions();
        dev_slot.is_connected = false;
        dev.disconnect() catch |err| {
            log.warn("BlueZ Device1.Disconnect failed: {s}", .{@errorName(err)});
            return BleError.IoError;
        };
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        if (builtin.os.tag != .linux) return false;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return false;
        const conn_ptr = if (self.conn) |*c| c else return false;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        const connected = dev.isConnected() catch false;
        dev_slot.is_connected = connected;
        if (!connected) {
            dev_slot.clearSubscriptions();
        }
        return connected;
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        if (builtin.os.tag != .linux) return null;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return null;
        const conn_ptr = if (self.conn) |*c| c else return null;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        return dev.getRSSI() catch dev_slot.rssi;
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        // Query ObjectManager for all GATT characteristics belonging to this device
        var msg = dbus.Connection.createMethodCall(
            BlueZ.service_name,
            BlueZ.root_path,
            BlueZ.ObjectManager.interface_name,
            BlueZ.ObjectManager.Methods.GetManagedObjects,
        ) catch return BleError.IoError;
        defer msg.deinit();

        var reply = conn_ptr.sendMessage(&msg, std.math.lossyCast(i32, self.timeouts.discovery_ms)) catch return BleError.Timeout;
        defer reply.deinit();

        const DiscoverVisitor = struct {
            slot: *BluezDeviceContext,
            overflow_error: bool = false,

            pub fn onGattCharacteristic(v_self: *@This(), info: object_manager.GattCharacteristicInfo) void {
                // Only add if characteristic path starts with our device's object path
                if (std.mem.startsWith(u8, info.getObjectPath(), v_self.slot.getPath())) {
                    v_self.slot.addCharacteristic(info.uuid, info.getObjectPath()) catch {
                        v_self.overflow_error = true;
                    };
                }
            }
        };

        var visitor = DiscoverVisitor{ .slot = dev_slot };
        var it = reply.iterator();
        object_manager.parseManagedObjects(&it, DiscoverVisitor, &visitor);
        if (visitor.overflow_error) return BleError.PoolExhausted;
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) BleError!usize {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            try disc_res;
        }

        const ch_slot = dev_slot.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        if (self.pcap_hook) |hook| {
            const req_pdu = [_]u8{ @intFromEnum(core.AttOpcode.read_req), 0x01, 0x00 };
            hook.emit(.host_to_controller, &req_pdu);
        }
        const n = ch.readValue(buf) catch return BleError.ReadFailed;
        if (self.pcap_hook) |hook| {
            var rsp_pdu: [517]u8 = undefined;
            rsp_pdu[0] = @intFromEnum(core.AttOpcode.read_rsp);
            const copy_len = @min(rsp_pdu.len - 1, n);
            @memcpy(rsp_pdu[1 .. 1 + copy_len], buf[0..copy_len]);
            hook.emit(.controller_to_host, rsp_pdu[0 .. 1 + copy_len]);
        }
        return n;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            try disc_res;
        }

        const ch_slot = dev_slot.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        const w_type: core.WriteType = if (with_response) .with_response else .without_response;
        if (self.pcap_hook) |hook| {
            var req_pdu: [517]u8 = undefined;
            req_pdu[0] = if (with_response) @intFromEnum(core.AttOpcode.write_req) else @intFromEnum(core.AttOpcode.write_cmd);
            req_pdu[1] = 0x01;
            req_pdu[2] = 0x00;
            const copy_len = @min(req_pdu.len - 3, data.len);
            @memcpy(req_pdu[3 .. 3 + copy_len], data[0..copy_len]);
            hook.emit(.host_to_controller, req_pdu[0 .. 3 + copy_len]);
        }
        ch.writeValue(data, w_type) catch return BleError.WriteFailed;
        if (with_response) {
            if (self.pcap_hook) |hook| {
                const rsp_pdu = [_]u8{@intFromEnum(core.AttOpcode.write_rsp)};
                hook.emit(.controller_to_host, &rsp_pdu);
            }
        }
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            try disc_res;
        }

        const ch_slot = dev_slot.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        ch.startNotify() catch return BleError.NotificationFailed;

        ch_slot.is_notifying = true;
        dev_slot.notify_cb = cb;
        dev_slot.notify_user_data = user_data;
        dev_slot.subscribed_uuid = char_uuid;
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        if (dev_slot.findCharacteristic(char_uuid)) |ch_slot| {
            var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
            ch_slot.is_notifying = false;
            dev_slot.notify_cb = null;
            dev_slot.subscribed_uuid = null;
            ch.stopNotify() catch |err| {
                log.warn("BlueZ GattCharacteristic1.StopNotify failed: {s}", .{@errorName(err)});
                return BleError.NotificationFailed;
            };
        }
    }

    /// Queries the actually negotiated ATT MTU from BlueZ (`GattCharacteristic1.MTU` or `Device1.MTU`)
    /// rather than returning the requested `target_mtu`.
    pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = target_mtu;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            disc_res catch |err| {
                log.debug("Service discovery during exchangeMtu returned: {s}", .{@errorName(err)});
            };
        }

        // 1. Query `MTU` property on the first discovered GattCharacteristic1 (supported across BlueZ 5.48+)
        if (dev_slot.characteristics_len > 0) {
            var ch = gatt_client.GattCharacteristic.init(conn_ptr, dev_slot.characteristics[0].getPath());
            if (ch.getMtu()) |negotiated_mtu| {
                if (negotiated_mtu >= 23) {
                    dev_slot.mtu = negotiated_mtu;
                    return negotiated_mtu;
                }
            } else |err| {
                log.debug("GattCharacteristic1.MTU query failed ({s}), falling back to Device1.MTU", .{@errorName(err)});
            }
        }

        // 2. Query `MTU` property on Device1 (BlueZ 5.62+)
        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        const dev_mtu = dev.getMtu() catch return BleError.MtuExchangeFailed;
        if (dev_mtu < 23) return BleError.MtuExchangeFailed;
        dev_slot.mtu = dev_mtu;
        return dev_mtu;
    }

    pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        _ = io_cap;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        dev.pair() catch return BleError.PairingFailed;
        dev.setTrusted(true) catch |err| {
            log.warn("BlueZ setTrusted(true) after pairing failed: {s}", .{@errorName(err)});
        };
    }

    pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var msg = dbus.Connection.createMethodCall(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.Adapter1.interface_name,
            BlueZ.Adapter1.Methods.RemoveDevice,
        ) catch return BleError.IoError;
        defer msg.deinit();

        var b = msg.builder();
        b.appendObjectPath(dev_slot.getPath()) catch return BleError.IoError;

        var reply = conn_ptr.sendMessage(&msg, std.math.lossyCast(i32, self.timeouts.pair_ms)) catch return BleError.IoError;
        defer reply.deinit();
        dev_slot.clearSubscriptions();
        dev_slot.is_connected = false;
    }

    pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
        if (builtin.os.tag != .linux) return .not_bonded;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return .not_bonded;
        const conn_ptr = if (self.conn) |*c| c else return .not_bonded;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        const is_paired = dev.isPaired() catch false;
        return if (is_paired) .bonded else .not_bonded;
    }

    pub fn acquireNotifyFd(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, out_mtu: *u16) BleError!std.posix.fd_t {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            try disc_res;
        }

        const ch_slot = dev_slot.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        const stream = ch.acquireNotify() catch return BleError.NotificationFailed;
        out_mtu.* = stream.mtu;
        dev_slot.mtu = stream.mtu;
        return stream.fd;
    }

    pub const vtable: BackendVTable = .{
        .name = "LinuxBlueZ",
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

test {
    _ = @import("tests.zig");
}
