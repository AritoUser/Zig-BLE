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

// Core BLE types re-exports
pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
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
        mutex: types.SyncMutex = .{},
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
            self.mutex.lock();
            defer self.mutex.unlock();
            self.connection_event_cb = cb;
            self.connection_event_user_data = user_data;
        }

        pub fn setReconnectCallback(self: *Self, cb: ?ReconnectCallback, user_data: ?*anyopaque) void {
            self.mutex.lock();
            defer self.mutex.unlock();
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

            self.active_scan_cb = null;
            self.connection_event_cb = null;
            self.reconnect_cb = null;
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
            dev_slot.releaseAll();
            dev_slot.parent_backend = self;

            const class_hstr = try helpers.createHStringComptime("Windows.Devices.Bluetooth.BluetoothLEDevice");
            defer helpers.deleteHString(class_hstr);

            var statics: ?*bindings.IBluetoothLEDeviceStatics = null;
            const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_IBluetoothLEDeviceStatics, @ptrCast(&statics));
            if (hr < 0 or statics == null) return BleError.ConnectionFailed;
            const st = statics.?;
            defer _ = st.lpVtbl.Release(st);

            var async_op: ?*bindings.IAsyncOperationGeneric = null;
            const addr64 = helpers.addressToU64(addr);
            if (st.lpVtbl.FromBluetoothAddressAsync(st, addr64, &async_op) < 0 or async_op == null) {
                return BleError.ConnectionFailed;
            }

            const dev_raw = (try helpers.awaitAsync(async_op.?, eff_timeout)) orelse return BleError.DeviceNotFound;
            const ble_dev: *bindings.IBluetoothLEDevice = @ptrCast(@alignCast(dev_raw));
            dev_slot.ble_device = ble_dev;

            var dev3: ?*bindings.IBluetoothLEDevice3 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice3, @ptrCast(&dev3)) >= 0) {
                dev_slot.ble_device3 = dev3;
            }

            dev_slot.conn_status_handler = .{
                .dev_ctx = @ptrCast(dev_slot),
                .on_status_changed = onConnectionStatusChanged,
            };
            if (ble_dev.lpVtbl.add_ConnectionStatusChanged(ble_dev, @ptrCast(&dev_slot.conn_status_handler), &dev_slot.conn_status_token) >= 0) {
                dev_slot.conn_status_registered = true;
            }

            dev_slot.is_connected = true;
            dev_slot.was_connected_once = true;
            dev_slot.bond_state = pairing_mod.queryWinRtBondState(ble_dev);

            self.mutex.unlock();
            const disc_res = discoverServices(ctx, @ptrCast(dev_slot));
            self.mutex.lock();
            disc_res catch |err| {
                dev_slot.releaseAll();
                return err;
            };

            return @ptrCast(dev_slot);
        }

        pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            dev.releaseAll();
        }

        pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
            if (builtin.os.tag != .windows) return false;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return false;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected) return false;
            if (dev.ble_device) |ble_dev| {
                var status: bindings.BluetoothConnectionStatus = .Disconnected;
                if (ble_dev.lpVtbl.get_ConnectionStatus(ble_dev, &status) >= 0) {
                    if (status == .Disconnected) {
                        dev.clearSubscriptions();
                        dev.is_connected = false;
                        return false;
                    }
                    return true;
                }
            }
            return dev.is_connected;
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

        pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) BleError!usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.readCharacteristic(self, dev, char_uuid, buf);
        }

        pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.writeCharacteristic(self, dev, char_uuid, data, with_response);
        }

        fn onCharacteristicValueChanged(char_ctx: *anyopaque, args: *bindings.IGattValueChangedEventArgs) callconv(.c) void {
            const slot: *WinCharacteristicSlot = @ptrCast(@alignCast(char_ctx));
            const dev_ptr = slot.parent_device orelse return;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_ptr));
            gatt_mod.handleCharacteristicValueChanged(slot, dev, args);
        }

        pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.subscribeNotifications(self, dev, char_uuid, cb, user_data, onCharacteristicValueChanged);
        }

        pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) BleError!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            return gatt_mod.unsubscribeNotifications(self, dev, char_uuid);
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
                dev.bond_state = pairing_mod.queryWinRtBondState(ble_dev);
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
