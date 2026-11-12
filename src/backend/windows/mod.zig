//! # Zig-BLE Native Windows WinRT Backend
//!
//! Full-featured, zero-dependency Windows 10/11 BLE backend implemented directly
//! over the COM/WinRT ABI (`combase.dll` & `Windows.Devices.Bluetooth`).
//! Modularized for maintainability and clean domain separation.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const vtable_mod = @import("../vtable.zig");

pub const bindings = @import("bindings.zig");
pub const radio_mod = @import("radio.zig");
pub const helpers = @import("helpers.zig");
pub const device_mod = @import("device.zig");
pub const scan_mod = @import("scan.zig");
pub const pairing_mod = @import("pairing.zig");
pub const gatt_mod = @import("gatt.zig");

pub const WindowsRadio = radio_mod.WindowsRadio;
pub const RadioInfo = radio_mod.RadioInfo;

const log = std.log.scoped(.zig_ble);

/// Upper bound per CCCD write when subscriptions are turned off before a disconnect.
const disconnect_write_ms = 2_000;

// Core BLE types re-exports
pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const CharacteristicSelector = types.CharacteristicSelector;
pub const CharacteristicInfo = types.CharacteristicInfo;
pub const ConnectionEvent = types.ConnectionEvent;
pub const ConnectionEventCallback = types.ConnectionEventCallback;
pub const PairingCallbacks = types.PairingCallbacks;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const BleError = types.BleError;
pub const TimeoutConfig = types.TimeoutConfig;
pub const PcapHook = types.PcapHook;
pub const BackendVTable = vtable_mod.BackendVTable;
pub const Backend = vtable_mod.Backend;

// Device & Pool types re-exports
pub const PoolConfig = device_mod.PoolConfig;
pub const WinCharacteristicSlot = device_mod.WinCharacteristicSlot;
pub const ReconnectCallback = *const fn (address: Address, user_data: ?*anyopaque) void;

// Pairing types re-exports
pub const PairingAction = pairing_mod.PairingAction;
pub const evaluatePairingCeremony = pairing_mod.evaluatePairingCeremony;

// WinRT interop helpers re-exports
pub const u64ToAddress = helpers.u64ToAddress;
pub const addressToU64 = helpers.addressToU64;
pub const guidToUuid = helpers.guidToUuid;
pub const uuidToGuid = helpers.uuidToGuid;
pub const createHStringComptime = helpers.createHStringComptime;
pub const createHStringRuntime = helpers.createHStringRuntime;
pub const deleteHString = helpers.deleteHString;
pub const hstringToUtf8 = helpers.hstringToUtf8;
pub const awaitAsync = helpers.awaitAsync;
pub const readIBuffer = helpers.readIBuffer;
pub const createIBuffer = helpers.createIBuffer;

const GUID = bindings.GUID;
const HSTRING = bindings.HSTRING;
const Combase = bindings.Combase;

pub fn WindowsBackendWithConfig(comptime pool_config: PoolConfig) type {
    return struct {
        const Self = @This();
        pub const DeviceContext = device_mod.DeviceContext(pool_config, Self);
        pub const ReconnectCallbackFn = ReconnectCallback;
        pub const PairingAction = pairing_mod.PairingAction;
        pub const evaluatePairingCeremony = pairing_mod.evaluatePairingCeremony;

        ro_initialized: bool = false,
        powered: bool = false,
        scanning: bool = false,
        radio: ?WindowsRadio = null,

        adapter: ?*bindings.IBluetoothAdapter = null,
        watcher: ?*bindings.IBluetoothLEAdvertisementWatcher = null,
        watcher_token: bindings.EventRegistrationToken = 0,
        watcher_handler: bindings.AdvertisementReceivedHandler = undefined,

        scan_filter: ScanFilter = .{},
        active_scan_cb: ?ScanCallback = null,
        active_scan_user_data: ?*anyopaque = null,

        connection_event_cb: ?ConnectionEventCallback = null,
        connection_event_user_data: ?*anyopaque = null,
        reconnect_cb: ?ReconnectCallback = null,
        reconnect_user_data: ?*anyopaque = null,

        pairing_callbacks: PairingCallbacks = .{},
        timeouts: TimeoutConfig = .{},
        pcap_hook: ?PcapHook = null,
        /// Serializes backend calls; may be held while waiting for WinRT operations.
        mutex: types.SyncMutex = .{},
        /// Guards the state WinRT callback threads touch (callbacks, `scan_filter`,
        /// `scan_cache`, per-characteristic notification callbacks). Never held across a
        /// WinRT call, so callbacks cannot deadlock against `mutex`. Lock order: `mutex`, then this.
        state_mutex: types.SyncMutex = .{},
        /// Merged advertisement + scan response data, also used to pick the address type on connect.
        scan_cache: types.ScanCache = .{},
        /// Use Windows' GATT cache for service discovery instead of reading services over the
        /// air on every connect. Faster, but can return stale services after a firmware update.
        use_cached_services: bool = false,
        /// Only read the characteristics of these services during `connect` and lazy discovery,
        /// which saves round trips on devices with many services. Empty means all services.
        service_filter: []const UUID = &.{},
        is_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        devices: [pool_config.max_devices]DeviceContext = @splat(.{}),

        pub fn init() Self {
            return .{};
        }

        pub fn initWithTimeouts(timeouts: TimeoutConfig) Self {
            return .{ .timeouts = timeouts };
        }

        pub fn deinit(self: *Self) void {
            closeAdapter(@ptrCast(self));
        }

        pub fn setPairingCallbacks(self: *Self, callbacks: PairingCallbacks) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pairing_callbacks = callbacks;
        }

        pub fn setConnectionEventCallback(self: *Self, cb: ?ConnectionEventCallback, user_data: ?*anyopaque) void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            self.connection_event_cb = cb;
            self.connection_event_user_data = user_data;
        }

        pub fn setReconnectCallback(self: *Self, cb: ?ReconnectCallback, user_data: ?*anyopaque) void {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            self.reconnect_cb = cb;
            self.reconnect_user_data = user_data;
        }

        pub fn setPcapHook(self: *Self, hook: ?PcapHook) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pcap_hook = hook;
        }

        pub fn allocateDeviceSlot(self: *Self, addr: Address) BleError!*DeviceContext {
            for (&self.devices) |*d| {
                if (d.in_use and d.address.eql(addr)) return d;
            }
            for (&self.devices) |*d| {
                if (!d.in_use) {
                    d.* = .{
                        .in_use = true,
                        .address = addr,
                        .parent_backend = self,
                    };
                    return d;
                }
            }
            // Slots of disconnected devices stay assigned so a reconnect finds its slot; reuse
            // them when no slot is free. Devices with rotating addresses would exhaust the pool.
            for (&self.devices) |*d| {
                if (!d.is_connected.load(.acquire)) {
                    d.releaseAll();
                    d.* = .{
                        .in_use = true,
                        .address = addr,
                        .parent_backend = self,
                    };
                    return d;
                }
            }
            return BleError.PoolExhausted;
        }

        pub fn findDeviceByAddress(self: *Self, addr: Address) ?*DeviceContext {
            for (&self.devices) |*d| {
                if (d.in_use and d.address.eql(addr)) return d;
            }
            return null;
        }

        pub fn ensureWinRtInitialized(self: *Self) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            if (!self.ro_initialized) {
                const hr = Combase.RoInitialize(bindings.RO_INIT_MULTITHREADED);
                if (hr < 0 and hr != bindings.RPC_E_CHANGED_MODE) {
                    return BleError.IoError;
                }
                self.ro_initialized = (hr >= 0);
            }
        }

        pub fn openAdapter(ctx: *anyopaque, index: u16) BleError!void {
            _ = index;
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            self.is_closed.store(false, .release);
            try self.ensureWinRtInitialized();

            if (self.adapter != null) {
                self.powered = true;
                return;
            }

            const class_hstr = try helpers.createHStringComptime("Windows.Devices.Bluetooth.BluetoothAdapter");
            defer helpers.deleteHString(class_hstr);

            var statics: ?*bindings.IBluetoothAdapterStatics = null;
            const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_IBluetoothAdapterStatics, @ptrCast(&statics));
            if (hr < 0 or statics == null) return BleError.AdapterNotFound;
            const st = statics.?;
            defer _ = st.lpVtbl.Release(st);

            var async_op: ?*bindings.IAsyncOperationGeneric = null;
            if (st.lpVtbl.GetDefaultAsync(st, &async_op) < 0 or async_op == null) {
                return BleError.AdapterNotFound;
            }

            const adapter_raw = (try helpers.awaitAsync(async_op.?, self.timeouts.connect_ms)) orelse return BleError.AdapterNotFound;
            self.adapter = @ptrCast(@alignCast(adapter_raw));
            if (self.radio == null) {
                if (WindowsRadio.init()) |mut_r| {
                    var r = mut_r;
                    r.openDefault() catch |err| {
                        log.debug("WindowsRadio.openDefault skipped: {s}", .{@errorName(err)});
                    };
                    self.radio = r;
                }
            }
            self.powered = true;
        }

        pub fn closeAdapter(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.is_closed.store(true, .release);
            self.watcher_handler.deactivate();

            if (builtin.os.tag != .windows) {
                self.powered = false;
                self.scanning = false;
                return;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            self.stopScanInternal();

            for (&self.devices) |*d| {
                if (d.in_use) {
                    d.disableSubscriptionsOnPeer(@min(self.timeouts.write_ms, disconnect_write_ms));
                    d.releaseAll();
                    d.in_use = false;
                }
            }

            if (self.adapter) |adp| {
                _ = adp.lpVtbl.Release(adp);
                self.adapter = null;
            }
            if (self.radio) |*r| {
                r.deinit();
                self.radio = null;
            }

            {
                self.state_mutex.lock();
                defer self.state_mutex.unlock();
                self.active_scan_cb = null;
                self.connection_event_cb = null;
                self.reconnect_cb = null;
            }
            self.powered = false;
        }

        pub fn setPowered(ctx: *anyopaque, powered: bool) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!powered) {
                return BleError.NotSupported;
            }
            if (self.adapter == null) {
                try openAdapter(ctx, 0);
            }
            self.powered = true;
        }

        pub fn isPowered(ctx: *anyopaque) BleError!bool {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            if (self.adapter) |adp| {
                var le_supported: u8 = 0;
                if (adp.lpVtbl.get_IsLowEnergySupported(adp, &le_supported) >= 0) {
                    return le_supported != 0 and self.powered;
                }
            }
            return self.powered;
        }

        fn onWatcherReceived(backend_ctx: *anyopaque, args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(backend_ctx));
            scan_mod.handleWatcherReceived(self, args);
        }

        pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            return scan_mod.startScan(self, filter, cb, user_data, onWatcherReceived);
        }

        fn stopScanInternal(self: *Self) void {
            scan_mod.stopScanInternal(self);
        }

        pub fn stopScan(ctx: *anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopScanInternal();
        }

        fn onConnectionStatusChanged(dev_ctx: *anyopaque, sender: ?*bindings.IBluetoothLEDevice) callconv(.c) void {
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_ctx));
            const backend = dev.parent_backend orelse return;
            if (backend.is_closed.load(.acquire)) return;

            const ble_dev = sender orelse dev.ble_device orelse return;
            var status: bindings.BluetoothConnectionStatus = .Disconnected;
            if (ble_dev.lpVtbl.get_ConnectionStatus(ble_dev, &status) < 0) return;

            dev.handleConnectionStatusTransition(status == .Connected);
        }

        pub fn simulateConnectionStatusTransition(dev: *DeviceContext, connected: bool) void {
            dev.handleConnectionStatusTransition(connected);
        }

        pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) BleError!*anyopaque {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            try self.ensureWinRtInitialized();

            const eff_timeout = if (timeout_ms == 0) self.timeouts.connect_ms else timeout_ms;
            var dev_slot = try self.allocateDeviceSlot(addr);
            if (dev_slot.auto_resubscribe) dev_slot.saved_subscriptions.capture(dev_slot.characteristics[0..dev_slot.characteristics_len]);
            dev_slot.disableSubscriptionsOnPeer(@min(self.timeouts.write_ms, disconnect_write_ms));
            dev_slot.releaseAll();
            dev_slot.parent_backend = self;
            dev_slot.connection_state.store(.connecting, .release);

            const class_hstr = try helpers.createHStringComptime("Windows.Devices.Bluetooth.BluetoothLEDevice");
            defer helpers.deleteHString(class_hstr);

            var statics: ?*bindings.IBluetoothLEDeviceStatics = null;
            const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_IBluetoothLEDeviceStatics, @ptrCast(&statics));
            if (hr < 0 or statics == null) return BleError.ConnectionFailed;
            const st = statics.?;
            defer _ = st.lpVtbl.Release(st);

            const addr_type = self.knownAddressType(addr);
            const deadline = helpers.Kernel32.GetTickCount64() + eff_timeout;
            try self.openLink(dev_slot, st, addr, addr_type, eff_timeout);

            // Windows connects lazily with the first GATT operation, which often reports
            // `Unreachable` or takes longer than `discovery_ms` while the link is still coming
            // up; keep trying within the connect timeout.
            var disc_res = self.discoverUnlocked(dev_slot, deadline);
            while (disc_res == BleError.ConnectionFailed or disc_res == BleError.ConnectionTimeout) {
                if (helpers.Kernel32.GetTickCount64() >= deadline) break;
                // When the peer never answers Windows' first ATT request (seen with BlueZ
                // peripherals), that link stays unusable until Windows drops it at the 30 s ATT
                // timeout. Release it, wait for the drop and connect again.
                dev_slot.releaseAll();
                waitForLinkDown(st, addr, addr_type, deadline);
                if (helpers.Kernel32.GetTickCount64() >= deadline) break;
                try self.openLink(dev_slot, st, addr, addr_type, eff_timeout);
                disc_res = self.discoverUnlocked(dev_slot, deadline);
            }
            disc_res catch |err| {
                dev_slot.connection_state.store(.disconnected, .release);
                dev_slot.releaseAll();
                return err;
            };
            dev_slot.resubscribe_pending.store(false, .release);
            self.restoreSubscriptions(dev_slot);

            return @ptrCast(dev_slot);
        }

        /// Opens the WinRT objects for `addr` in `dev_slot`; the link itself comes up with the
        /// first GATT operation. Expects `self.mutex` held.
        fn openLink(self: *Self, dev_slot: *DeviceContext, st: *bindings.IBluetoothLEDeviceStatics, addr: Address, addr_type: ?types.AddressType, timeout_ms: u32) BleError!void {
            const ble_dev = try fromBluetoothAddress(st, addr, addr_type, timeout_ms);
            dev_slot.ble_device = ble_dev;

            var dev3: ?*bindings.IBluetoothLEDevice3 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice3, @ptrCast(&dev3)) >= 0) {
                dev_slot.ble_device3 = dev3;
            }

            dev_slot.gatt_session = gatt_mod.openGattSession(ble_dev, timeout_ms) catch |err| blk: {
                log.warn("WinRT GattSession for {f} unavailable ({s}); Windows may drop an idle connection", .{ addr, @errorName(err) });
                break :blk null;
            };

            dev_slot.conn_status_handler = .{
                .dev_ctx = @ptrCast(dev_slot),
                .on_status_changed = onConnectionStatusChanged,
            };
            if (ble_dev.lpVtbl.add_ConnectionStatusChanged(ble_dev, @ptrCast(&dev_slot.conn_status_handler), &dev_slot.conn_status_token) >= 0) {
                dev_slot.conn_status_registered = true;
            }

            {
                self.state_mutex.lock();
                defer self.state_mutex.unlock();
                dev_slot.is_connected.store(true, .release);
                dev_slot.connection_state.store(.connected, .release);
                dev_slot.was_connected_once = true;
            }
            dev_slot.bond_state = pairing_mod.queryWinRtBondState(ble_dev);
            dev_slot.bond_changed = false;
        }

        /// One discovery attempt, bounded by `deadline`. Releases `self.mutex` meanwhile.
        fn discoverUnlocked(self: *Self, dev_slot: *DeviceContext, deadline: u64) BleError!void {
            self.mutex.unlock();
            defer self.mutex.lock();
            // `Unreachable` within the first seconds: the link is still coming up. Later it means
            // this link is stuck, which the caller handles by connecting again.
            const coming_up_until = @min(helpers.Kernel32.GetTickCount64() + 5_000, deadline);
            var res = discoverServices(@ptrCast(self), @ptrCast(dev_slot));
            while (res == BleError.ConnectionFailed and helpers.Kernel32.GetTickCount64() + 300 < coming_up_until) {
                helpers.Kernel32.Sleep(300);
                res = discoverServices(@ptrCast(self), @ptrCast(dev_slot));
            }
            return res;
        }

        /// Waits until Windows reports `addr` disconnected, or until `deadline`.
        fn waitForLinkDown(st: *bindings.IBluetoothLEDeviceStatics, addr: Address, addr_type: ?types.AddressType, deadline: u64) void {
            while (helpers.Kernel32.GetTickCount64() < deadline) {
                helpers.Kernel32.Sleep(250);
                const probe = fromBluetoothAddress(st, addr, addr_type, 2_000) catch continue;
                var status: bindings.BluetoothConnectionStatus = .Connected;
                _ = probe.lpVtbl.get_ConnectionStatus(probe, &status);
                var closable: ?*bindings.IClosable = null;
                if (probe.lpVtbl.QueryInterface(probe, &bindings.IID_IClosable, @ptrCast(&closable)) >= 0) {
                    if (closable) |cl| {
                        _ = cl.lpVtbl.Close(cl);
                        _ = cl.lpVtbl.Release(cl);
                    }
                }
                _ = probe.lpVtbl.Release(probe);
                if (status == .Disconnected) return;
            }
        }

        /// Address type seen while scanning, if any. Random addresses need it to resolve reliably.
        fn knownAddressType(self: *Self, addr: Address) ?types.AddressType {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            const dev = self.scan_cache.find(addr) orelse return null;
            return dev.address_type;
        }

        fn fromBluetoothAddress(st: *bindings.IBluetoothLEDeviceStatics, addr: Address, addr_type: ?types.AddressType, timeout_ms: u32) BleError!*bindings.IBluetoothLEDevice {
            const addr64 = helpers.addressToU64(addr);
            var async_op: ?*bindings.IAsyncOperationGeneric = null;

            const is_random = if (addr_type) |t| t != .public else false;
            var statics2: ?*bindings.IBluetoothLEDeviceStatics2 = null;
            if (is_random and st.lpVtbl.QueryInterface(st, &bindings.IID_IBluetoothLEDeviceStatics2, @ptrCast(&statics2)) >= 0 and statics2 != null) {
                const st2 = statics2.?;
                defer _ = st2.lpVtbl.Release(st2);
                if (st2.lpVtbl.FromBluetoothAddressWithBluetoothAddressTypeAsync(st2, addr64, .Random, &async_op) < 0) async_op = null;
            }
            if (async_op == null) {
                if (st.lpVtbl.FromBluetoothAddressAsync(st, addr64, &async_op) < 0 or async_op == null) {
                    return BleError.ConnectionFailed;
                }
            }

            const dev_raw = (try helpers.awaitAsync(async_op.?, timeout_ms)) orelse return BleError.DeviceNotFound;
            return @ptrCast(@alignCast(dev_raw));
        }

        pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            dev.connection_state.store(.disconnecting, .release);
            if (dev.auto_resubscribe) dev.saved_subscriptions.capture(dev.characteristics[0..dev.characteristics_len]);
            dev.disableSubscriptionsOnPeer(@min(self.timeouts.write_ms, disconnect_write_ms));
            dev.releaseAll();
            dev.connection_state.store(.disconnected, .release);
        }

        /// Sets up the saved subscriptions on the current connection. Caller holds `mutex`.
        fn restoreSubscriptions(self: *Self, dev: *DeviceContext) void {
            for (dev.saved_subscriptions.slice()) |sub| {
                gatt_mod.subscribeNotifications(self, dev, sub.char, sub.cb, sub.user_data, onCharacteristicValueChanged) catch |err| {
                    log.warn("Resubscribing to {f} failed: {s}", .{ sub.char.uuid, @errorName(err) });
                };
            }
            dev.saved_subscriptions.clear();
        }

        pub fn getConnectionState(ctx: *anyopaque, dev_handle: *anyopaque) types.ConnectionState {
            if (builtin.os.tag != .windows) return .disconnected;
            _ = ctx;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return dev.connection_state.load(.acquire);
        }

        pub fn setAutoResubscribe(ctx: *anyopaque, dev_handle: *anyopaque, enabled: bool) void {
            if (builtin.os.tag != .windows) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            dev.auto_resubscribe = enabled;
            if (!enabled) dev.saved_subscriptions.clear();
        }

        pub fn discoverServicesFiltered(ctx: *anyopaque, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

            // Rediscovers, because the list may have been narrowed before. Subscriptions on
            // services that stay are set up again on the new characteristic objects.
            dev.saved_subscriptions.capture(dev.characteristics[0..dev.characteristics_len]);
            dev.clearSubscriptions();
            dev.releaseGatt();
            const result = gatt_mod.discoverServicesFiltered(self, dev, filter_uuids);
            self.restoreSubscriptions(dev);
            return result;
        }

        pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
            if (builtin.os.tag != .windows) return false;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return false;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected.load(.acquire)) return false;
            if (dev.ble_device) |ble_dev| {
                var status: bindings.BluetoothConnectionStatus = .Disconnected;
                if (ble_dev.lpVtbl.get_ConnectionStatus(ble_dev, &status) >= 0) {
                    if (status == .Disconnected) {
                        if (!dev.auto_resubscribe) dev.clearSubscriptions();
                        dev.is_connected.store(false, .release);
                        dev.connection_state.store(.disconnected, .release);
                        return false;
                    }
                    return true;
                }
            }
            return dev.is_connected.load(.acquire);
        }

        pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return dev.rssi;
        }

        pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.discoverServices(self, dev);
        }

        pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, buf: []u8) BleError!usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.readCharacteristic(self, dev, char, buf);
        }

        pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.writeCharacteristic(self, dev, char, data, with_response);
        }

        fn onCharacteristicValueChanged(char_ctx: *anyopaque, args: *bindings.IGattValueChangedEventArgs) callconv(.c) void {
            const slot: *WinCharacteristicSlot = @ptrCast(@alignCast(char_ctx));
            const dev_ptr = slot.parent_device orelse return;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_ptr));
            gatt_mod.handleCharacteristicValueChanged(slot, dev, args);
        }

        pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.subscribeNotifications(self, dev, char, cb, user_data, onCharacteristicValueChanged);
        }

        pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.unsubscribeNotifications(self, dev, char);
        }

        /// WinRT delivers callbacks on its own threads, so there is nothing to pump; this only
        /// waits, which lets one `processEvents` loop work on every backend.
        pub fn processEvents(ctx: *anyopaque, timeout_ms: u32) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            self.resubscribeRestoredLinks();
            helpers.Kernel32.Sleep(timeout_ms);
        }

        /// WinRT threads must not wait for GATT operations, so links Windows restored by itself
        /// get their CCCDs written here.
        fn resubscribeRestoredLinks(self: *Self) void {
            for (&self.devices) |*dev| {
                if (!dev.resubscribe_pending.swap(false, .acq_rel)) continue;
                self.mutex.lock();
                defer self.mutex.unlock();
                if (!dev.in_use or !dev.is_connected.load(.acquire)) continue;
                dev.saved_subscriptions.capture(dev.characteristics[0..dev.characteristics_len]);
                self.restoreSubscriptions(dev);
            }
        }

        pub fn readDescriptor(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.readDescriptor(self, dev, char, descriptor, buf);
        }

        pub fn writeDescriptor(ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.writeDescriptor(self, dev, char, descriptor, data);
        }

        pub fn getCharacteristics(ctx: *anyopaque, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.getCharacteristics(self, dev, out);
        }

        pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.exchangeMtu(self, dev, target_mtu);
        }

        pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return pairing_mod.pairDevice(self, dev, io_cap);
        }

        pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return pairing_mod.unpairDevice(self, dev);
        }

        pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.is_closed.load(.acquire)) return .not_bonded;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (dev.ble_device) |ble_dev| {
                if (!dev.bond_changed) dev.bond_state = pairing_mod.queryWinRtBondState(ble_dev);
            }
            return dev.bond_state;
        }

        pub const vtable: BackendVTable = .{
            .name = "WindowsWinRT",
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
            .getCharacteristics = getCharacteristics,
            .processEvents = processEvents,
            .readDescriptor = readDescriptor,
            .writeDescriptor = writeDescriptor,
            .getConnectionState = getConnectionState,
            .setAutoResubscribe = setAutoResubscribe,
            .discoverServicesFiltered = discoverServicesFiltered,
        };

        pub fn asBackend(self: *Self) Backend {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
            };
        }
    };
}

pub const WindowsBackend = WindowsBackendWithConfig(.{});
pub const WinDeviceContext = WindowsBackend.DeviceContext;

test {
    _ = @import("tests.zig");
}
