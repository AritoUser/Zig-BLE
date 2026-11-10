//! # Zig-BLE Linux BlueZ Backend Implementation
//!
//! Bridges the unified `BackendVTable` interface with the native, zero-allocation
//! Pure-Zig D-Bus Wire Protocol engine (`src/dbus/`, `src/adapter.zig`, `src/device.zig`, `src/gatt_client.zig`).
//!
//! ## Events
//! BlueZ reports scan results, notifications and connection changes as D-Bus signals.
//! They are delivered when the application calls `processEvents` (or
//! `UnifiedAdapter.processEvents`); signals that arrive during other calls are queued until then.
//!
//! ## Concurrency & Lifecycle Guarantees
//! - All public backend operations are synchronized via `mutex` (`SyncMutex`).
//! - Callbacks (`ScanCallback`, `NotificationCallback`, `ConnectionEventCallback`) are invoked
//!   after the mutex is released, so they may call back into the backend, and are suppressed
//!   once `closeAdapter` / `deinit` begins (`is_closed` atomic guard).
//! - Handles `InterfacesAdded` and `PropertiesChanged` (scan results, `Connected`, characteristic
//!   `Value`), `InterfacesRemoved`, and `NameOwnerChanged` (automatic recovery when `bluetoothd` restarts).

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
pub const CharacteristicSelector = types.CharacteristicSelector;
pub const CharacteristicInfo = types.CharacteristicInfo;
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

const signals = @import("signals.zig");
pub const context_mod = @import("context.zig");
pub const DaemonRestartCallback = context_mod.DaemonRestartCallback;
pub const BluezCharacteristicSlot = context_mod.BluezCharacteristicSlot;
pub const BluezDeviceContext = context_mod.BluezDeviceContext;
pub const ScanCache = context_mod.ScanCache;

pub const PendingCallbacks = signals.PendingCallbacks;

/// Maps a failed GATT call. A D-Bus timeout usually means BlueZ is still trying to raise the
/// link's security for a protected attribute.
fn gattError(err: anyerror, fallback: BleError) BleError {
    if (err == error.AccessDenied) return BleError.PermissionDenied;
    if (err == error.Timeout or err == error.NoReply) return BleError.Timeout;
    return fallback;
}

pub const BluezBackend = struct {
    conn: if (builtin.os.tag == .linux) ?dbus.Connection else void = if (builtin.os.tag == .linux) null else {},
    adapter_index: u16 = 0,
    adapter_path: [64]u8 = undefined,
    adapter_path_len: u8 = 0,
    scanning: bool = false,
    active_scan_cb: ?ScanCallback = null,
    active_scan_user_data: ?*anyopaque = null,
    scan_filter: ScanFilter = .{},
    scan_cache: ScanCache = .{},

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
        // Slots of disconnected devices stay assigned so a reconnect finds its slot; reuse them
        // when no slot is free. Devices with rotating addresses would exhaust the pool.
        for (&self.devices) |*d| {
            if (!d.is_connected) {
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

    /// Processes one incoming D-Bus message (scan results, notifications, disconnects,
    /// `bluetoothd` restarts) and invokes the resulting callbacks. `processEvents` calls this
    /// for every queued signal; it is public for tests and custom event loops.
    pub fn processSignalWireMessage(self: *BluezBackend, msg: *const wire.Message) void {
        var pending: PendingCallbacks = .{};
        signals.collectSignal(self, msg, &pending);
        pending.fire(self);
    }

    /// Delivers queued scan results, notifications and connection events, waiting up to
    /// `timeout_ms` for the first signal. Handles at most 256 signals per call so a busy
    /// bus cannot starve the caller.
    pub fn processEvents(ctx: *anyopaque, timeout_ms: u32) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;

        const isSignal = struct {
            fn f(_: void, m: *const wire.Message) bool {
                return m.fixed_header.msg_type == .signal;
            }
        }.f;

        var waited = false;
        var budget: usize = 256;
        while (budget > 0) : (budget -= 1) {
            // Only signals are taken; method replies stay queued for the thread waiting on them.
            const msg = conn_ptr.popMatching({}, isSignal) orelse {
                if (waited or timeout_ms == 0) return;
                waited = true;
                // Poll the socket without the connection's read lock so concurrent calls are not blocked.
                _ = conn_ptr.socket.pollRead(std.math.lossyCast(i32, timeout_ms)) catch return BleError.IoError;
                continue;
            };
            defer msg.deinit();

            var pending: PendingCallbacks = .{};
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                signals.collectSignal(self, &msg, &pending);
                signals.resubscribeRestoredLinks(self, conn_ptr);
            }
            pending.fire(self);
        }
    }

    /// Re-initializes the D-Bus system bus connection and adapter subscription after `bluetoothd` restarts.
    pub fn recoverAfterDaemonRestart(self: *BluezBackend) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        // Declared before the lock: callbacks run after the mutex is released.
        var pending: PendingCallbacks = .{};
        defer pending.fire(self);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        signals.handleDaemonDown(self, &pending);

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
        signals.seedScanCache(self, conn_ptr);

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
        const eff_timeout = if (timeout_ms == 0) self.timeouts.connect_ms else timeout_ms;
        const deadline = wire.getMonotonicMs() + eff_timeout;

        var dev_slot = self.allocateDeviceSlot(addr) orelse return BleError.PoolExhausted;
        dev_slot.connection_state.store(.connecting, .release);

        var path_buf: [96]u8 = undefined;
        const d_path = BlueZ.buildDevicePath(&path_buf, self.getAdapterPath(), addr);
        dev_slot.setPath(d_path);

        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        dev.connectWithTimeout(eff_timeout) catch |err| {
            log.err("BlueZ Device1.Connect failed for {s}: {s}", .{ dev_slot.getPath(), @errorName(err) });
            dev_slot.connection_state.store(.disconnected, .release);
            dev_slot.in_use = false;
            return switch (err) {
                // BlueZ only knows devices it has seen; scan before connecting.
                error.UnknownObject => BleError.DeviceNotFound,
                error.Timeout, error.NoReply => BleError.ConnectionTimeout,
                else => BleError.ConnectionFailed,
            };
        };
        dev_slot.is_connected = true;
        dev_slot.connection_state.store(.connected, .release);

        // Connect returns before BlueZ has resolved the GATT database; GATT calls before
        // `ServicesResolved` would see no characteristics.
        const remaining: u32 = @intCast(std.math.clamp(deadline - wire.getMonotonicMs(), 0, std.math.maxInt(u32)));
        dev.waitForServicesResolved(remaining) catch |err| {
            log.err("BlueZ services of {s} not resolved: {s}", .{ dev_slot.getPath(), @errorName(err) });
            dev.disconnect() catch {};
            dev_slot.is_connected = false;
            dev_slot.connection_state.store(.disconnected, .release);
            dev_slot.in_use = false;
            return if (err == error.Disconnected) BleError.Disconnected else BleError.ConnectionTimeout;
        };
        dev_slot.external_reconnect = false;
        dev_slot.resubscribe_pending = false;

        // The previous connection's GATT objects may be gone.
        if (dev_slot.auto_resubscribe) dev_slot.saved_subscriptions.capture(dev_slot.characteristics[0..dev_slot.characteristics_len]);
        dev_slot.characteristics_len = 0;
        dev_slot.descriptors_len = 0;
        if (dev_slot.auto_resubscribe and dev_slot.saved_subscriptions.len > 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, @ptrCast(dev_slot));
            self.mutex.lock();
            disc_res catch |err| log.warn("BlueZ discovery for resubscribing failed: {s}", .{@errorName(err)});
            for (dev_slot.saved_subscriptions.slice()) |sub| {
                const ch_slot = dev_slot.findCharacteristic(sub.char) orelse {
                    log.warn("BlueZ resubscribe: {f} no longer exists", .{sub.char.uuid});
                    continue;
                };
                var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
                ch.startNotify() catch |err| {
                    log.warn("BlueZ resubscribe failed for {s}: {s}", .{ ch_slot.getPath(), @errorName(err) });
                    continue;
                };
                ch_slot.is_notifying = true;
                ch_slot.notify_cb = sub.cb;
                ch_slot.notify_user_data = sub.user_data;
            }
            dev_slot.saved_subscriptions.clear();
        }
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

        dev_slot.connection_state.store(.disconnecting, .release);
        var dev = device_mod.Device.init(conn_ptr, dev_slot.getPath());
        dev_slot.endSubscriptionsWithLink();
        dev_slot.is_connected = false;
        dev_slot.connection_state.store(.disconnected, .release);
        dev.disconnect() catch |err| {
            // BlueZ removes a device it has not bonded with once the link is gone.
            if (err == error.UnknownObject or err == error.UnknownMethod) return;
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
            dev_slot.connection_state.store(.disconnected, .release);
            dev_slot.endSubscriptionsWithLink();
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

    pub fn getConnectionState(ctx: *anyopaque, dev_handle: *anyopaque) types.ConnectionState {
        if (builtin.os.tag != .linux) return .disconnected;
        _ = ctx;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        return dev_slot.connection_state.load(.acquire);
    }

    pub fn setAutoResubscribe(ctx: *anyopaque, dev_handle: *anyopaque, enabled: bool) void {
        if (builtin.os.tag != .linux) return;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        dev_slot.auto_resubscribe = enabled;
        if (!enabled) dev_slot.saved_subscriptions.clear();
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
        return discoverServicesFiltered(ctx, dev_handle, &.{});
    }

    pub fn discoverServicesFiltered(ctx: *anyopaque, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void {
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
            services: [32]object_manager.GattServiceInfo = undefined,
            services_len: usize = 0,

            fn ownsPath(v_self: *const @This(), path: []const u8) bool {
                const dev_path = v_self.slot.getPath();
                return std.mem.startsWith(u8, path, dev_path) and path.len > dev_path.len and path[dev_path.len] == '/';
            }

            pub fn onGattService(v_self: *@This(), info: object_manager.GattServiceInfo) void {
                if (!v_self.ownsPath(info.getObjectPath())) return;
                if (v_self.services_len == v_self.services.len) {
                    v_self.overflow_error = true;
                    return;
                }
                v_self.services[v_self.services_len] = info;
                v_self.services_len += 1;
            }

            pub fn onGattCharacteristic(v_self: *@This(), info: object_manager.GattCharacteristicInfo) void {
                if (!v_self.ownsPath(info.getObjectPath())) return;
                v_self.slot.addCharacteristic(info.uuid, info.getObjectPath()) catch {
                    v_self.overflow_error = true;
                };
            }

            pub fn onGattDescriptor(v_self: *@This(), info: object_manager.GattDescriptorInfo) void {
                if (!v_self.ownsPath(info.getObjectPath())) return;
                // Descriptors beyond the pool are only unavailable to readDescriptor/writeDescriptor.
                v_self.slot.addDescriptor(info.uuid, info.getObjectPath()) catch {
                    log.warn("BlueZ descriptor pool full; {s} not stored", .{info.getObjectPath()});
                };
            }
        };

        var visitor = DiscoverVisitor{ .slot = dev_slot };
        var it = reply.iterator();
        object_manager.parseManagedObjects(&it, DiscoverVisitor, &visitor);

        var kept: usize = 0;
        for (dev_slot.characteristics[0..dev_slot.characteristics_len]) |*ch| {
            for (visitor.services[0..visitor.services_len]) |*svc| {
                if (std.mem.eql(u8, svc.getObjectPath(), ch.getServicePath())) {
                    ch.service_uuid = svc.uuid;
                    break;
                }
            }

            if (filter_uuids.len > 0) {
                var matches = false;
                for (filter_uuids) |f_uuid| {
                    if (f_uuid.eql(ch.service_uuid)) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) {
                    if (ch.is_notifying) {
                        var gch = gatt_client.GattCharacteristic.init(conn_ptr, ch.getPath());
                        gch.stopNotify() catch |err| log.warn("BlueZ StopNotify failed: {s}", .{@errorName(err)});
                    }
                    continue;
                }
            }

            dev_slot.characteristics[kept] = ch.*;
            kept += 1;
        }
        dev_slot.characteristics_len = @intCast(kept);
        dev_slot.sortCharacteristics();
        if (visitor.overflow_error) return BleError.PoolExhausted;
        if (filter_uuids.len > 0 and kept == 0) return BleError.ServiceNotFound;
    }

    pub fn readDescriptor(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = try self.lookupDescriptor(ctx, dev_handle, char, descriptor);
        var d = gatt_client.GattDescriptor.init(found.conn, found.desc.getPath());
        return d.readValue(buf) catch |err| gattError(err, BleError.ReadFailed);
    }

    pub fn writeDescriptor(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = try self.lookupDescriptor(ctx, dev_handle, char, descriptor);
        var d = gatt_client.GattDescriptor.init(found.conn, found.desc.getPath());
        d.writeValue(data) catch |err| return gattError(err, BleError.WriteFailed);
    }

    /// Finds a discovered descriptor, discovering services first if needed. Caller holds `mutex`.
    fn lookupDescriptor(self: *BluezBackend, ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID) BleError!struct {
        conn: *dbus.Connection,
        desc: *context_mod.BluezDescriptorSlot,
    } {
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
        const ch_slot = dev_slot.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
        const desc = dev_slot.findDescriptor(ch_slot, descriptor) orelse return BleError.DescriptorNotFound;
        return .{ .conn = conn_ptr, .desc = desc };
    }

    pub fn getCharacteristics(ctx: *anyopaque, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));
        if (!dev_slot.is_connected) return BleError.NotConnected;

        if (dev_slot.characteristics_len == 0) {
            self.mutex.unlock();
            const disc_res = discoverServices(ctx, dev_handle);
            self.mutex.lock();
            try disc_res;
        }
        return CharacteristicInfo.list(dev_slot.characteristics[0..dev_slot.characteristics_len], out);
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, buf: []u8) BleError!usize {
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

        const ch_slot = dev_slot.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        if (self.pcap_hook) |hook| {
            const req_pdu = [_]u8{ @intFromEnum(core.AttOpcode.read_req), 0x01, 0x00 };
            hook.emit(.host_to_controller, &req_pdu);
        }
        const n = ch.readValue(buf) catch |err| return gattError(err, BleError.ReadFailed);
        if (self.pcap_hook) |hook| {
            var rsp_pdu: [517]u8 = undefined;
            rsp_pdu[0] = @intFromEnum(core.AttOpcode.read_rsp);
            const copy_len = @min(rsp_pdu.len - 1, n);
            @memcpy(rsp_pdu[1 .. 1 + copy_len], buf[0..copy_len]);
            hook.emit(.controller_to_host, rsp_pdu[0 .. 1 + copy_len]);
        }
        return n;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void {
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

        const ch_slot = dev_slot.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
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
        ch.writeValue(data, w_type) catch |err| return gattError(err, BleError.WriteFailed);
        if (with_response) {
            if (self.pcap_hook) |hook| {
                const rsp_pdu = [_]u8{@intFromEnum(core.AttOpcode.write_rsp)};
                hook.emit(.controller_to_host, &rsp_pdu);
            }
        }
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
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

        const ch_slot = dev_slot.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
        var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
        ch.startNotify() catch return BleError.NotificationFailed;

        ch_slot.is_notifying = true;
        ch_slot.notify_cb = cb;
        ch_slot.notify_user_data = user_data;
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector) BleError!void {
        if (builtin.os.tag != .linux) return BleError.NotSupported;
        const self: *BluezBackend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed.load(.acquire)) return BleError.InvalidState;
        const conn_ptr = if (self.conn) |*c| c else return BleError.AdapterNotFound;
        const dev_slot: *BluezDeviceContext = @ptrCast(@alignCast(dev_handle));

        if (dev_slot.findCharacteristic(char)) |ch_slot| {
            var ch = gatt_client.GattCharacteristic.init(conn_ptr, ch_slot.getPath());
            ch_slot.is_notifying = false;
            ch_slot.notify_cb = null;
            ch_slot.notify_user_data = null;
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
        dev_slot.connection_state.store(.disconnected, .release);
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

    pub fn acquireNotifyFd(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, out_mtu: *u16) BleError!std.posix.fd_t {
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

        const ch_slot = dev_slot.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
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
        .getCharacteristics = getCharacteristics,
        .processEvents = processEvents,
        .getConnectionState = getConnectionState,
        .setAutoResubscribe = setAutoResubscribe,
        .discoverServicesFiltered = discoverServicesFiltered,
        .readDescriptor = readDescriptor,
        .writeDescriptor = writeDescriptor,
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

test "gattError reports timeouts and missing permissions" {
    try std.testing.expectEqual(BleError.PermissionDenied, gattError(error.AccessDenied, BleError.ReadFailed));
    try std.testing.expectEqual(BleError.Timeout, gattError(error.Timeout, BleError.ReadFailed));
    try std.testing.expectEqual(BleError.Timeout, gattError(error.NoReply, BleError.WriteFailed));
    try std.testing.expectEqual(BleError.WriteFailed, gattError(error.Failed, BleError.WriteFailed));
}
