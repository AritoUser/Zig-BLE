//! # Zig-BLE Native Windows WinRT Backend
//!
//! Full-featured, zero-dependency Windows 10/11 BLE backend implemented directly
//! over the COM/WinRT ABI (`combase.dll` & `Windows.Devices.Bluetooth`).
//!
//! ## Concurrency & Callback Threading Model
//! - WinRT delivers asynchronous completions and event callbacks (`AdvertisementWatcher.Received`,
//!   `GattCharacteristic.ValueChanged`, `BluetoothLEDevice.ConnectionStatusChanged`,
//!   `DeviceInformationCustomPairing.PairingRequested`) on Windows MTA worker threads.
//! - Internal backend state is synchronized via `mutex` (`std.Thread.Mutex`).
//! - Every COM delegate carries an atomic `active` flag that is cleared before `remove_*` and `deinit`,
//!   guaranteeing that no callback ever fires after `unsubscribe`, `disconnect`, or `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const vtable_mod = @import("../vtable.zig");
pub const bindings = @import("bindings.zig");
pub const radio_mod = @import("radio.zig");
pub const WindowsRadio = radio_mod.WindowsRadio;
pub const RadioInfo = radio_mod.RadioInfo;
const core = @import("../../core/mod.zig");

const log = std.log.scoped(.zig_ble);

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

const GUID = bindings.GUID;
const HSTRING = bindings.HSTRING;
const HRESULT = bindings.HRESULT;
const Combase = bindings.Combase;

/// Configurable static pool dimensions for zero-allocation Windows BLE device, service, and characteristic slots.
pub const PoolConfig = struct {
    max_devices: usize = 8,
    max_services_per_device: usize = 16,
    max_characteristics_per_device: usize = 64,
};

pub const ReconnectCallback = *const fn (address: Address, user_data: ?*anyopaque) void;

// ============================================================================
// Conversion Helpers: Zig-BLE <-> WinRT Types
// ============================================================================

/// Converts a 48-bit `u64` WinRT Bluetooth address into a 6-byte Big-Endian `Address`.
pub fn u64ToAddress(addr64: u64) Address {
    var bytes: [6]u8 = undefined;
    std.mem.writeInt(u48, &bytes, @truncate(addr64), .big);
    return Address{ .bytes = bytes };
}

/// Converts a 6-byte Big-Endian `Address` into a 48-bit `u64` WinRT Bluetooth address.
pub fn addressToU64(addr: Address) u64 {
    return @as(u64, std.mem.readInt(u48, &addr.bytes, .big));
}

/// Converts a WinRT `GUID` into a Zig-BLE `UUID` (16-byte Big-Endian RFC 4122).
pub fn guidToUuid(g: GUID) UUID {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], g.Data1, .big);
    std.mem.writeInt(u16, b[4..6], g.Data2, .big);
    std.mem.writeInt(u16, b[6..8], g.Data3, .big);
    @memcpy(b[8..16], &g.Data4);
    return UUID{ .bytes = b };
}

/// Converts a Zig-BLE `UUID` (16-byte Big-Endian RFC 4122) into a WinRT `GUID`.
pub fn uuidToGuid(u: UUID) GUID {
    return GUID{
        .Data1 = std.mem.readInt(u32, u.bytes[0..4], .big),
        .Data2 = std.mem.readInt(u16, u.bytes[4..6], .big),
        .Data3 = std.mem.readInt(u16, u.bytes[6..8], .big),
        .Data4 = u.bytes[8..16].*,
    };
}

/// Creates a WinRT `HSTRING` from a compile-time UTF-8 string literal.
pub fn createHStringComptime(comptime utf8: []const u8) BleError!HSTRING {
    if (builtin.os.tag != .windows) return null;
    const utf16 = comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8);
    var hstr: HSTRING = null;
    const hr = Combase.WindowsCreateString(utf16.ptr, @intCast(utf16.len), &hstr);
    if (hr < 0) return BleError.IoError;
    return hstr;
}

/// Creates a WinRT `HSTRING` from a runtime UTF-8 slice using a stack UTF-16 buffer.
pub fn createHStringRuntime(utf8: []const u8) BleError!HSTRING {
    if (builtin.os.tag != .windows) return null;
    var utf16_buf: [256]u16 = undefined;
    const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8) catch return BleError.InvalidParameter;
    var hstr: HSTRING = null;
    const hr = Combase.WindowsCreateString(&utf16_buf, @intCast(utf16_len), &hstr);
    if (hr < 0) return BleError.IoError;
    return hstr;
}

pub fn deleteHString(hstr: HSTRING) void {
    if (builtin.os.tag != .windows) return;
    if (hstr != null) {
        _ = Combase.WindowsDeleteString(hstr);
    }
}

/// Extracts UTF-8 text from an `HSTRING` into `out_buf` (zero heap allocation).
pub fn hstringToUtf8(hstr: HSTRING, out_buf: []u8) usize {
    if (builtin.os.tag != .windows or hstr == null) return 0;
    var len: u32 = 0;
    const raw_ptr = Combase.WindowsGetStringRawBuffer(hstr, &len) orelse return 0;
    if (len == 0) return 0;
    const utf16_slice = raw_ptr[0..len];
    return std.unicode.utf16LeToUtf8(out_buf, utf16_slice) catch 0;
}

const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(bindings.WINAPI) void;
} else struct {
    fn Sleep(dwMilliseconds: u32) void {
        _ = dwMilliseconds;
    }
};

/// Synchronously awaits any WinRT `IAsyncOperation<T>` with a timeout and extracts the result pointer/value.
pub fn awaitAsync(op: *bindings.IAsyncOperationGeneric, timeout_ms: u32) BleError!?*anyopaque {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    defer _ = op.lpVtbl.Release(op);

    var async_info: ?*bindings.IAsyncInfo = null;
    const qi_hr = op.lpVtbl.QueryInterface(op, &bindings.IID_IAsyncInfo, @ptrCast(&async_info));
    if (qi_hr < 0 or async_info == null) return BleError.IoError;
    const info = async_info.?;
    defer {
        _ = info.lpVtbl.Close(info);
        _ = info.lpVtbl.Release(info);
    }

    const eff_timeout: u32 = if (timeout_ms == 0) 10_000 else timeout_ms;
    var elapsed_ms: u32 = 0;
    const poll_step_ms: u32 = 2;

    while (elapsed_ms < eff_timeout) {
        var status: bindings.AsyncStatus = .Started;
        const st_hr = info.lpVtbl.get_Status(info, &status);
        if (st_hr < 0) return BleError.IoError;

        switch (status) {
            .Started => {
                Kernel32.Sleep(poll_step_ms);
                elapsed_ms += poll_step_ms;
            },
            .Completed => {
                var result: ?*anyopaque = null;
                const res_hr = op.lpVtbl.GetResults(op, &result);
                if (res_hr < 0) return BleError.IoError;
                return result;
            },
            .Canceled => return BleError.ConnectionTimeout,
            .Error => {
                var err_code: HRESULT = 0;
                _ = info.lpVtbl.get_ErrorCode(info, &err_code);
                return BleError.GattError;
            },
        }
    }

    _ = info.lpVtbl.Cancel(info);
    return BleError.ConnectionTimeout;
}

/// Reads raw bytes from a WinRT `IBuffer` via `IBufferByteAccess` into `dest` with zero heap allocations.
pub fn readIBuffer(buffer: *bindings.IBuffer, dest: []u8) BleError!usize {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    var length: u32 = 0;
    if (buffer.lpVtbl.get_Length(buffer, &length) < 0) return BleError.ReadFailed;
    if (length == 0) return 0;

    var byte_access: ?*bindings.IBufferByteAccess = null;
    const hr = buffer.lpVtbl.QueryInterface(buffer, &bindings.IID_IBufferByteAccess, @ptrCast(&byte_access));
    if (hr < 0 or byte_access == null) return BleError.ReadFailed;
    const ba = byte_access.?;
    defer _ = ba.lpVtbl.Release(ba);

    var raw_ptr: [*]u8 = undefined;
    if (ba.lpVtbl.Buffer(ba, &raw_ptr) < 0) return BleError.ReadFailed;

    const copy_len = @min(dest.len, @as(usize, length));
    @memcpy(dest[0..copy_len], raw_ptr[0..copy_len]);
    return copy_len;
}

/// Creates a WinRT `IBuffer` from a byte slice via `Windows.Security.Cryptography.CryptographicBuffer`.
pub fn createIBuffer(data: []const u8) BleError!*bindings.IBuffer {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    const class_hstr = try createHStringComptime("Windows.Security.Cryptography.CryptographicBuffer");
    defer deleteHString(class_hstr);

    var crypto_statics: ?*bindings.ICryptographicBufferStatics = null;
    const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_ICryptographicBufferStatics, @ptrCast(&crypto_statics));
    if (hr < 0 or crypto_statics == null) return BleError.WriteFailed;
    const statics = crypto_statics.?;
    defer _ = statics.lpVtbl.Release(statics);

    var buffer: ?*bindings.IBuffer = null;
    const dummy: [1]u8 = .{0};
    const ptr: [*]const u8 = if (data.len > 0) data.ptr else &dummy;
    const create_hr = statics.lpVtbl.CreateFromByteArray(statics, @intCast(data.len), ptr, &buffer);
    if (create_hr < 0 or buffer == null) return BleError.WriteFailed;
    return buffer.?;
}

// ============================================================================
// Device & Characteristic Contexts
// ============================================================================

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

pub fn WindowsBackendWithConfig(comptime pool_config: PoolConfig) type {
    return struct {
        const Self = @This();

        pub const DeviceContext = struct {
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
            parent_backend: ?*Self = null,

            services: [pool_config.max_services_per_device]?*bindings.IGattDeviceService = @splat(null),
            services_len: u8 = 0,

            characteristics: [pool_config.max_characteristics_per_device]WinCharacteristicSlot = @splat(.{}),
            characteristics_len: u8 = 0,

            notify_cb: ?NotificationCallback = null,
            notify_user_data: ?*anyopaque = null,
            subscribed_uuid: ?UUID = null,

            mtu: u16 = 23,
            bond_state: types.BondState = .not_bonded,

            pub fn findCharacteristic(self: *DeviceContext, uuid: UUID) ?*WinCharacteristicSlot {
                for (self.characteristics[0..self.characteristics_len]) |*ch| {
                    if (ch.uuid.eql(uuid)) return ch;
                }
                return null;
            }

            pub fn addCharacteristic(self: *DeviceContext, uuid: UUID, ptr: *bindings.IGattCharacteristic) BleError!void {
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

            pub fn addService(self: *DeviceContext, svc: *bindings.IGattDeviceService) BleError!void {
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
            pub fn clearSubscriptions(self: *DeviceContext) void {
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

            pub fn handleConnectionStatusTransition(self: *DeviceContext, connected: bool) void {
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

            pub fn releaseAll(self: *DeviceContext) void {
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

        fn ensureWinRtInitialized(self: *Self) BleError!void {
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

            const class_hstr = try createHStringComptime("Windows.Devices.Bluetooth.BluetoothAdapter");
            defer deleteHString(class_hstr);

            var statics: ?*bindings.IBluetoothAdapterStatics = null;
            const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_IBluetoothAdapterStatics, @ptrCast(&statics));
            if (hr < 0 or statics == null) return BleError.AdapterNotFound;
            const st = statics.?;
            defer _ = st.lpVtbl.Release(st);

            var async_op: ?*bindings.IAsyncOperationGeneric = null;
            if (st.lpVtbl.GetDefaultAsync(st, &async_op) < 0 or async_op == null) {
                return BleError.AdapterNotFound;
            }

            const adapter_raw = (try awaitAsync(async_op.?, self.timeouts.connect_ms)) orelse return BleError.AdapterNotFound;
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
            // Prevent any further callbacks from firing
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
                // Toggling Windows radio state off requires Windows.Devices.Radios elevation; report honestly.
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
            if (self.is_closed.load(.acquire)) return;
            const cb = self.active_scan_cb orelse return;

            var addr64: u64 = 0;
            if (args.lpVtbl.get_BluetoothAddress(args, &addr64) < 0) return;

            var rssi: i16 = -127;
            _ = args.lpVtbl.get_RawSignalStrengthInDBm(args, &rssi);

            if (self.scan_filter.min_rssi) |min_r| {
                if (rssi < min_r) return;
            }

            var discovered = DiscoveredDevice{
                .address = u64ToAddress(addr64),
                .rssi = rssi,
            };

            if (self.findDeviceByAddress(discovered.address)) |existing_dev| {
                existing_dev.rssi = rssi;
            }

            var adv_ptr: ?*bindings.IBluetoothLEAdvertisement = null;
            if (args.lpVtbl.get_Advertisement(args, &adv_ptr) >= 0) {
                if (adv_ptr) |adv| {
                    defer _ = adv.lpVtbl.Release(adv);

                    var name_hstr: HSTRING = null;
                    if (adv.lpVtbl.get_LocalName(adv, &name_hstr) >= 0 and name_hstr != null) {
                        defer deleteHString(name_hstr);
                        var name_buf: [64]u8 = undefined;
                        const name_len = hstringToUtf8(name_hstr, &name_buf);
                        if (name_len > 0) {
                            discovered.setName(name_buf[0..name_len]);
                        }
                    }

                    var uuids_vec: ?*bindings.IVectorViewGuid = null;
                    if (adv.lpVtbl.get_ServiceUuids(adv, @ptrCast(&uuids_vec)) >= 0) {
                        if (uuids_vec) |uv| {
                            defer _ = uv.lpVtbl.Release(uv);
                            var count: u32 = 0;
                            if (uv.lpVtbl.get_Size(uv, &count) >= 0) {
                                var i: u32 = 0;
                                while (i < count and i < 8) : (i += 1) {
                                    var g: GUID = undefined;
                                    if (uv.lpVtbl.GetAt(uv, i, &g) >= 0) {
                                        _ = discovered.addServiceUuid(guidToUuid(g));
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (self.scan_filter.service_uuids.len > 0) {
                var matched = false;
                for (self.scan_filter.service_uuids) |req_uuid| {
                    for (discovered.getServiceUuids()) |adv_uuid| {
                        if (req_uuid.eql(adv_uuid)) {
                            matched = true;
                            break;
                        }
                    }
                    if (matched) break;
                }
                if (!matched) return;
            }

            if (!self.is_closed.load(.acquire)) {
                cb(&discovered, self.active_scan_user_data);
            }
        }

        pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            try self.ensureWinRtInitialized();

            if (self.scanning) {
                self.stopScanInternal();
            }

            self.scan_filter = filter;
            self.active_scan_cb = cb;
            self.active_scan_user_data = user_data;

            if (self.watcher == null) {
                const class_hstr = try createHStringComptime("Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher");
                defer deleteHString(class_hstr);

                var inspectable: ?*bindings.IInspectable = null;
                const hr = Combase.RoActivateInstance(class_hstr, &inspectable);
                if (hr < 0 or inspectable == null) return BleError.AdapterNotFound;
                const insp = inspectable.?;
                defer _ = insp.release();

                var watcher_ptr: ?*bindings.IBluetoothLEAdvertisementWatcher = null;
                if (insp.queryInterface(&bindings.IID_IBluetoothLEAdvertisementWatcher, @ptrCast(&watcher_ptr)) < 0 or watcher_ptr == null) {
                    return BleError.AdapterNotFound;
                }
                self.watcher = watcher_ptr;
            }

            const w = self.watcher.?;
            const mode: bindings.BluetoothLEScanningMode = if (filter.active) .Active else .Passive;
            _ = w.lpVtbl.put_ScanningMode(w, mode);

            self.watcher_handler = .{
                .backend_ctx = @ptrCast(self),
                .on_received = onWatcherReceived,
            };

            const add_hr = w.lpVtbl.add_Received(w, @ptrCast(&self.watcher_handler), &self.watcher_token);
            if (add_hr < 0) return BleError.IoError;

            const start_hr = w.lpVtbl.Start(w);
            if (start_hr < 0) {
                self.watcher_handler.deactivate();
                _ = w.lpVtbl.remove_Received(w, self.watcher_token);
                self.watcher_token = 0;
                return BleError.NotPowered;
            }

            self.scanning = true;
        }

        fn stopScanInternal(self: *Self) void {
            if (builtin.os.tag != .windows) return;
            self.watcher_handler.deactivate();
            if (self.watcher) |w| {
                if (self.scanning) {
                    const stop_hr = w.lpVtbl.Stop(w);
                    if (stop_hr < 0) {
                        log.warn("WinRT BluetoothLEAdvertisementWatcher.Stop returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(stop_hr))});
                    }
                    if (self.watcher_token != 0) {
                        const rem_hr = w.lpVtbl.remove_Received(w, self.watcher_token);
                        if (rem_hr < 0) {
                            log.warn("WinRT remove_Received returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(rem_hr))});
                        }
                        self.watcher_token = 0;
                    }
                }
                _ = w.lpVtbl.Release(w);
                self.watcher = null;
            }
            self.scanning = false;
            self.active_scan_cb = null;
            self.active_scan_user_data = null;
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

        /// Handles connection status transitions (`Connected` <-> `Disconnected`), cleaning up
        /// active notification subscriptions on disconnect and invoking connection/reconnect callbacks.
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

            const class_hstr = try createHStringComptime("Windows.Devices.Bluetooth.BluetoothLEDevice");
            defer deleteHString(class_hstr);

            var statics: ?*bindings.IBluetoothLEDeviceStatics = null;
            const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_IBluetoothLEDeviceStatics, @ptrCast(&statics));
            if (hr < 0 or statics == null) return BleError.ConnectionFailed;
            const st = statics.?;
            defer _ = st.lpVtbl.Release(st);

            var async_op: ?*bindings.IAsyncOperationGeneric = null;
            const addr64 = addressToU64(addr);
            if (st.lpVtbl.FromBluetoothAddressAsync(st, addr64, &async_op) < 0 or async_op == null) {
                return BleError.ConnectionFailed;
            }

            const dev_raw = (try awaitAsync(async_op.?, eff_timeout)) orelse return BleError.DeviceNotFound;
            const ble_dev: *bindings.IBluetoothLEDevice = @ptrCast(@alignCast(dev_raw));
            dev_slot.ble_device = ble_dev;

            var dev3: ?*bindings.IBluetoothLEDevice3 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice3, @ptrCast(&dev3)) >= 0) {
                dev_slot.ble_device3 = dev3;
            }

            // Register ConnectionStatusChanged event listener (Item 11)
            dev_slot.conn_status_handler = .{
                .dev_ctx = @ptrCast(dev_slot),
                .on_status_changed = onConnectionStatusChanged,
            };
            if (ble_dev.lpVtbl.add_ConnectionStatusChanged(ble_dev, @ptrCast(&dev_slot.conn_status_handler), &dev_slot.conn_status_token) >= 0) {
                dev_slot.conn_status_registered = true;
            }

            dev_slot.is_connected = true;
            dev_slot.was_connected_once = true;

            // Query initial bond state (Item 6)
            dev_slot.bond_state = queryWinRtBondState(ble_dev);

            // Note: In WinRT, FromBluetoothAddressAsync creates the handle, and GetGattServicesAsync(Uncached)
            // initiates the actual over-the-air radio link establishment.
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
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            const d3 = dev.ble_device3 orelse return BleError.NotConnected;

            if (dev.characteristics_len > 0) return;

            var svcs_op: ?*bindings.IAsyncOperationGeneric = null;
            if (d3.lpVtbl.GetGattServicesWithCacheModeAsync(d3, .Uncached, &svcs_op) < 0 or svcs_op == null) {
                return BleError.GattError;
            }

            const svcs_res_raw = (try awaitAsync(svcs_op.?, self.timeouts.discovery_ms)) orelse return BleError.ServiceNotFound;
            const svcs_res: *bindings.IGattDeviceServicesResult = @ptrCast(@alignCast(svcs_res_raw));
            defer _ = svcs_res.lpVtbl.Release(svcs_res);

            var status: bindings.GattCommunicationStatus = .Unreachable;
            if (svcs_res.lpVtbl.get_Status(svcs_res, &status) < 0 or status != .Success) {
                return BleError.ConnectionFailed;
            }

            var services_vec: ?*bindings.IVectorViewGeneric = null;
            if (svcs_res.lpVtbl.get_Services(svcs_res, &services_vec) < 0 or services_vec == null) {
                return BleError.ServiceNotFound;
            }
            const sv = services_vec.?;
            defer _ = sv.lpVtbl.Release(sv);

            var svc_count: u32 = 0;
            _ = sv.lpVtbl.get_Size(sv, &svc_count);

            var s_idx: u32 = 0;
            while (s_idx < svc_count) : (s_idx += 1) {
                var svc_raw: ?*anyopaque = null;
                if (sv.lpVtbl.GetAt(sv, s_idx, &svc_raw) < 0 or svc_raw == null) continue;
                const svc: *bindings.IGattDeviceService = @ptrCast(@alignCast(svc_raw.?));
                try dev.addService(svc);

                var svc3: ?*bindings.IGattDeviceService3 = null;
                if (svc.lpVtbl.QueryInterface(svc, &bindings.IID_IGattDeviceService3, @ptrCast(&svc3)) >= 0 and svc3 != null) {
                    const s3 = svc3.?;
                    defer _ = s3.lpVtbl.Release(s3);

                    // Query negotiated MaxPduSize from IGattSession if available
                    var session: ?*bindings.IGattSession = null;
                    if (s3.lpVtbl.get_Session(s3, &session) >= 0 and session != null) {
                        const sess = session.?;
                        defer _ = sess.lpVtbl.Release(sess);
                        var max_pdu: u16 = 0;
                        if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
                            dev.mtu = max_pdu;
                        }
                    }

                    var chars_op: ?*bindings.IAsyncOperationGeneric = null;
                    if (s3.lpVtbl.GetCharacteristicsWithCacheModeAsync(s3, .Uncached, &chars_op) >= 0 and chars_op != null) {
                        if (awaitAsync(chars_op.?, self.timeouts.discovery_ms) catch null) |chars_res_raw| {
                            const chars_res: *bindings.IGattCharacteristicsResult = @ptrCast(@alignCast(chars_res_raw));
                            defer _ = chars_res.lpVtbl.Release(chars_res);

                            var c_status: bindings.GattCommunicationStatus = .Unreachable;
                            if (chars_res.lpVtbl.get_Status(chars_res, &c_status) >= 0 and c_status == .Success) {
                                var chars_vec: ?*bindings.IVectorViewGeneric = null;
                                if (chars_res.lpVtbl.get_Characteristics(chars_res, &chars_vec) >= 0 and chars_vec != null) {
                                    const cv = chars_vec.?;
                                    defer _ = cv.lpVtbl.Release(cv);

                                    var char_count: u32 = 0;
                                    _ = cv.lpVtbl.get_Size(cv, &char_count);

                                    var c_idx: u32 = 0;
                                    while (c_idx < char_count) : (c_idx += 1) {
                                        var char_raw: ?*anyopaque = null;
                                        if (cv.lpVtbl.GetAt(cv, c_idx, &char_raw) >= 0 and char_raw != null) {
                                            const ch: *bindings.IGattCharacteristic = @ptrCast(@alignCast(char_raw.?));
                                            var c_guid: GUID = undefined;
                                            if (ch.lpVtbl.get_Uuid(ch, &c_guid) >= 0) {
                                                try dev.addCharacteristic(guidToUuid(c_guid), ch);
                                            } else {
                                                _ = ch.lpVtbl.Release(ch);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) BleError!usize {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected) return BleError.NotConnected;

            if (dev.characteristics_len == 0) {
                self.mutex.unlock();
                const disc_res = discoverServices(ctx, dev_handle);
                self.mutex.lock();
                try disc_res;
            }

            const slot = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

            if (self.pcap_hook) |hook| {
                const req_pdu = [_]u8{ @intFromEnum(core.AttOpcode.read_req), 0x01, 0x00 };
                hook.emit(.host_to_controller, &req_pdu);
            }

            var read_op: ?*bindings.IAsyncOperationGeneric = null;
            if (ch.lpVtbl.ReadValueWithCacheModeAsync(ch, .Uncached, &read_op) < 0 or read_op == null) {
                return BleError.ReadFailed;
            }

            const res_raw = (try awaitAsync(read_op.?, self.timeouts.read_ms)) orelse return BleError.ReadFailed;
            const read_res: *bindings.IGattReadResult = @ptrCast(@alignCast(res_raw));
            defer _ = read_res.lpVtbl.Release(read_res);

            var status: bindings.GattCommunicationStatus = .Unreachable;
            if (read_res.lpVtbl.get_Status(read_res, &status) < 0 or status != .Success) {
                return if (status == .AccessDenied) BleError.PermissionDenied else BleError.ReadFailed;
            }

            var ibuf: ?*bindings.IBuffer = null;
            if (read_res.lpVtbl.get_Value(read_res, &ibuf) < 0 or ibuf == null) {
                return BleError.ReadFailed;
            }
            const b = ibuf.?;
            defer _ = b.lpVtbl.Release(b);

            const n = try readIBuffer(b, buf);
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
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected) return BleError.NotConnected;

            if (dev.characteristics_len == 0) {
                self.mutex.unlock();
                const disc_res = discoverServices(ctx, dev_handle);
                self.mutex.lock();
                try disc_res;
            }

            const slot = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

            const ibuf = try createIBuffer(data);
            defer _ = ibuf.lpVtbl.Release(ibuf);

            if (self.pcap_hook) |hook| {
                var req_pdu: [517]u8 = undefined;
                req_pdu[0] = if (with_response) @intFromEnum(core.AttOpcode.write_req) else @intFromEnum(core.AttOpcode.write_cmd);
                req_pdu[1] = 0x01;
                req_pdu[2] = 0x00;
                const copy_len = @min(req_pdu.len - 3, data.len);
                @memcpy(req_pdu[3 .. 3 + copy_len], data[0..copy_len]);
                hook.emit(.host_to_controller, req_pdu[0 .. 3 + copy_len]);
            }

            var write_op: ?*bindings.IAsyncOperationGeneric = null;
            const opt: bindings.GattWriteOption = if (with_response) .WriteWithResponse else .WriteWithoutResponse;
            if (ch.lpVtbl.WriteValueWithOptionAsync(ch, ibuf, opt, &write_op) < 0 or write_op == null) {
                return BleError.WriteFailed;
            }

            const res_raw = try awaitAsync(write_op.?, self.timeouts.write_ms);
            const status_val: i32 = @intCast(@intFromPtr(res_raw));
            if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
                return if (status_val == @intFromEnum(bindings.GattCommunicationStatus.AccessDenied))
                    BleError.PermissionDenied
                else
                    BleError.WriteFailed;
            }

            if (with_response) {
                if (self.pcap_hook) |hook| {
                    const rsp_pdu = [_]u8{@intFromEnum(core.AttOpcode.write_rsp)};
                    hook.emit(.controller_to_host, &rsp_pdu);
                }
            }
        }

        fn onCharacteristicValueChanged(char_ctx: *anyopaque, args: *bindings.IGattValueChangedEventArgs) callconv(.c) void {
            const slot: *WinCharacteristicSlot = @ptrCast(@alignCast(char_ctx));
            const dev_ptr = slot.parent_device orelse return;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_ptr));
            if (dev.parent_backend) |b| {
                if (b.is_closed.load(.acquire)) return;
            }
            const cb = dev.notify_cb orelse return;

            var ibuf: ?*bindings.IBuffer = null;
            if (args.lpVtbl.get_CharacteristicValue(args, &ibuf) < 0 or ibuf == null) return;
            const b = ibuf.?;
            defer _ = b.lpVtbl.Release(b);

            var stack_buf: [512]u8 = undefined;
            const n = readIBuffer(b, &stack_buf) catch return;

            if (dev.parent_backend) |back| {
                if (back.pcap_hook) |hook| {
                    var pdu_buf: [517]u8 = undefined;
                    pdu_buf[0] = @intFromEnum(core.AttOpcode.handle_value_ntf);
                    pdu_buf[1] = 0x01;
                    pdu_buf[2] = 0x00;
                    const copy_len = @min(pdu_buf.len - 3, n);
                    @memcpy(pdu_buf[3 .. 3 + copy_len], stack_buf[0..copy_len]);
                    hook.emit(.controller_to_host, pdu_buf[0 .. 3 + copy_len]);
                }
            }

            cb(slot.uuid, stack_buf[0..n], dev.notify_user_data);
        }

        pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected) return BleError.NotConnected;

            if (dev.characteristics_len == 0) {
                self.mutex.unlock();
                const disc_res = discoverServices(ctx, dev_handle);
                self.mutex.lock();
                try disc_res;
            }

            const slot = dev.findCharacteristic(char_uuid) orelse return BleError.CharacteristicNotFound;
            const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

            dev.notify_cb = cb;
            dev.notify_user_data = user_data;
            dev.subscribed_uuid = char_uuid;

            slot.value_changed_handler = .{
                .char_ctx = @ptrCast(slot),
                .on_changed = onCharacteristicValueChanged,
            };

            if (!slot.is_subscribed) {
                const add_hr = ch.lpVtbl.add_ValueChanged(ch, @ptrCast(&slot.value_changed_handler), &slot.value_changed_token);
                if (add_hr < 0) return BleError.NotificationFailed;
                slot.is_subscribed = true;
            }

            var props: u32 = 0;
            _ = ch.lpVtbl.get_CharacteristicProperties(ch, &props);
            const cccd_val: bindings.GattClientCharacteristicConfigurationDescriptorValue =
                if ((props & bindings.GattCharacteristicProperties.Indicate) != 0 and (props & bindings.GattCharacteristicProperties.Notify) == 0)
                    .Indicate
                else
                    .Notify;

            var cccd_op: ?*bindings.IAsyncOperationGeneric = null;
            if (ch.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(ch, cccd_val, &cccd_op) < 0 or cccd_op == null) {
                return BleError.NotificationFailed;
            }

            const res_raw = try awaitAsync(cccd_op.?, self.timeouts.write_ms);
            const status_val: i32 = @intCast(@intFromPtr(res_raw));
            if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
                return BleError.NotificationFailed;
            }
        }

        pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            const slot = dev.findCharacteristic(char_uuid) orelse return;
            const ch = slot.char_ptr orelse return;

            slot.value_changed_handler.deactivate();

            if (slot.is_subscribed and slot.value_changed_token != 0) {
                const rem_hr = ch.lpVtbl.remove_ValueChanged(ch, slot.value_changed_token);
                if (rem_hr < 0) {
                    log.warn("WinRT remove_ValueChanged returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(rem_hr))});
                }
                slot.is_subscribed = false;
                slot.value_changed_token = 0;
            }

            dev.notify_cb = null;
            dev.subscribed_uuid = null;

            var cccd_op: ?*bindings.IAsyncOperationGeneric = null;
            if (ch.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(ch, .None, &cccd_op) >= 0 and cccd_op != null) {
                const res_raw = awaitAsync(cccd_op.?, self.timeouts.write_ms) catch |err| {
                    log.warn("WinRT CCCD disable write failed: {s}", .{@errorName(err)});
                    return err;
                };
                const status_val: i32 = @intCast(@intFromPtr(res_raw));
                if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
                    log.warn("WinRT CCCD disable write returned status {d}", .{status_val});
                    return BleError.NotificationFailed;
                }
            }
        }

        /// Queries the actually negotiated ATT MTU (`GattSession.MaxPduSize`) from WinRT
        /// rather than returning the requested `target_mtu`.
        pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            _ = target_mtu;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (!dev.is_connected) return BleError.NotConnected;

            // 1. Query IGattSession from any discovered IGattDeviceService3
            for (dev.services[0..dev.services_len]) |maybe_svc| {
                if (maybe_svc) |svc| {
                    var svc3: ?*bindings.IGattDeviceService3 = null;
                    if (svc.lpVtbl.QueryInterface(svc, &bindings.IID_IGattDeviceService3, @ptrCast(&svc3)) >= 0 and svc3 != null) {
                        const s3 = svc3.?;
                        defer _ = s3.lpVtbl.Release(s3);
                        var session: ?*bindings.IGattSession = null;
                        if (s3.lpVtbl.get_Session(s3, &session) >= 0 and session != null) {
                            const sess = session.?;
                            defer _ = sess.lpVtbl.Release(sess);
                            var max_pdu: u16 = 0;
                            if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
                                dev.mtu = max_pdu;
                                return max_pdu;
                            }
                        }
                    }
                }
            }

            // 2. Fallback: Query IBluetoothLEDevice4.get_BluetoothDeviceId -> IGattSessionStatics.FromDeviceIdAsync
            if (dev.ble_device) |ble_dev| {
                var dev4: ?*bindings.IBluetoothLEDevice4 = null;
                if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice4, @ptrCast(&dev4)) >= 0 and dev4 != null) {
                    const d4 = dev4.?;
                    defer _ = d4.lpVtbl.Release(d4);
                    var bt_dev_id: ?*anyopaque = null;
                    if (d4.lpVtbl.get_BluetoothDeviceId(d4, &bt_dev_id) >= 0 and bt_dev_id != null) {
                        const dev_id_unk: *bindings.IUnknown = @ptrCast(@alignCast(bt_dev_id.?));
                        defer _ = dev_id_unk.release();

                        const sess_hstr = try createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattSession");
                        defer deleteHString(sess_hstr);
                        var sess_statics: ?*bindings.IGattSessionStatics = null;
                        if (Combase.RoGetActivationFactory(sess_hstr, &bindings.IID_IGattSessionStatics, @ptrCast(&sess_statics)) >= 0 and sess_statics != null) {
                            const st = sess_statics.?;
                            defer _ = st.lpVtbl.Release(st);
                            var sess_op: ?*bindings.IAsyncOperationGeneric = null;
                            if (st.lpVtbl.FromDeviceIdAsync(st, bt_dev_id.?, &sess_op) >= 0 and sess_op != null) {
                                if (try awaitAsync(sess_op.?, self.timeouts.mtu_exchange_ms)) |sess_raw| {
                                    const sess: *bindings.IGattSession = @ptrCast(@alignCast(sess_raw));
                                    defer _ = sess.lpVtbl.Release(sess);
                                    var max_pdu: u16 = 0;
                                    if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
                                        dev.mtu = max_pdu;
                                        return max_pdu;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            return BleError.MtuExchangeFailed;
        }

        const PairingSessionContext = struct {
            io_cap: types.IoCapability,
            callbacks: PairingCallbacks,
        };

        /// Evaluates a pairing ceremony request (`DevicePairingKinds`) against `IoCapability` and `PairingCallbacks`.
        /// Extracted so Passkey Entry and Numeric Comparison logic can be unit-tested deterministically.
        pub const PairingAction = union(enum) {
            reject,
            accept_only,
            accept_with_pin: [6]u8,
        };

        pub fn evaluatePairingCeremony(
            pairing_kind: u32,
            pin_str: ?[]const u8,
            io_cap: types.IoCapability,
            callbacks: PairingCallbacks,
        ) PairingAction {
            if (pairing_kind == bindings.DevicePairingKinds.ConfirmOnly) {
                if (callbacks.on_confirm) |confirm_fn| {
                    if (confirm_fn(null, callbacks.user_data)) {
                        return .accept_only;
                    }
                    return .reject;
                }
                if (io_cap == .no_input_no_output) {
                    return .accept_only;
                }
                return .reject;
            } else if (pairing_kind == bindings.DevicePairingKinds.ConfirmPinMatch) {
                const raw = pin_str orelse return .reject;
                const numeric_val = std.fmt.parseInt(u32, raw, 10) catch return .reject;
                if (callbacks.on_confirm) |confirm_fn| {
                    if (confirm_fn(numeric_val, callbacks.user_data)) {
                        return .accept_only;
                    }
                }
                return .reject;
            } else if (pairing_kind == bindings.DevicePairingKinds.DisplayPin) {
                const raw = pin_str orelse return .reject;
                const numeric_val = std.fmt.parseInt(u32, raw, 10) catch return .reject;
                if (callbacks.on_display_passkey) |disp_fn| {
                    disp_fn(numeric_val, callbacks.user_data);
                    return .accept_only;
                }
                return .reject;
            } else if (pairing_kind == bindings.DevicePairingKinds.ProvidePin) {
                if (callbacks.on_request_passkey) |req_fn| {
                    if (req_fn(callbacks.user_data)) |passkey| {
                        if (passkey <= 999_999) {
                            var pin_buf: [6]u8 = undefined;
                            _ = std.fmt.bufPrint(&pin_buf, "{d:0>6}", .{passkey}) catch return .reject;
                            return .{ .accept_with_pin = pin_buf };
                        }
                    }
                }
                return .reject;
            }
            return .reject;
        }

        fn onPairingRequested(pair_ctx: *anyopaque, args: *bindings.IDevicePairingRequestedEventArgs) callconv(.c) void {
            const ctx: *PairingSessionContext = @ptrCast(@alignCast(pair_ctx));
            var kind: u32 = 0;
            if (args.lpVtbl.get_PairingKind(args, &kind) < 0) return;

            var pin_buf: [32]u8 = undefined;
            var pin_slice: ?[]const u8 = null;
            var pin_hstr: HSTRING = null;
            if (args.lpVtbl.get_Pin(args, &pin_hstr) >= 0 and pin_hstr != null) {
                defer deleteHString(pin_hstr);
                const len = hstringToUtf8(pin_hstr, &pin_buf);
                if (len > 0) pin_slice = pin_buf[0..len];
            }

            const action = evaluatePairingCeremony(kind, pin_slice, ctx.io_cap, ctx.callbacks);
            switch (action) {
                .reject => {},
                .accept_only => {
                    _ = args.lpVtbl.Accept(args);
                },
                .accept_with_pin => |pin_digits| {
                    if (createHStringRuntime(&pin_digits)) |hstr| {
                        defer deleteHString(hstr);
                        _ = args.lpVtbl.AcceptWithPin(args, hstr);
                    } else |_| {}
                },
            }
        }

        /// Initiates BLE pairing over `IDeviceInformationCustomPairing` with interactive callbacks
        /// for Passkey Entry and Numeric Comparison (Item 9).
        pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            const ble_dev = dev.ble_device orelse return BleError.NotConnected;

            var dev2: ?*bindings.IBluetoothLEDevice2 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice2, @ptrCast(&dev2)) < 0 or dev2 == null) {
                return BleError.PairingFailed;
            }
            const d2 = dev2.?;
            defer _ = d2.lpVtbl.Release(d2);

            var dev_info: ?*bindings.IDeviceInformation = null;
            if (d2.lpVtbl.get_DeviceInformation(d2, &dev_info) < 0 or dev_info == null) {
                return BleError.PairingFailed;
            }
            const info = dev_info.?;
            defer _ = info.lpVtbl.Release(info);

            var dev_info2: ?*bindings.IDeviceInformation2 = null;
            if (info.lpVtbl.QueryInterface(info, &bindings.IID_IDeviceInformation2, @ptrCast(&dev_info2)) < 0 or dev_info2 == null) {
                return BleError.PairingFailed;
            }
            const info2 = dev_info2.?;
            defer _ = info2.lpVtbl.Release(info2);

            var pairing: ?*bindings.IDeviceInformationPairing = null;
            if (info2.lpVtbl.get_Pairing(info2, &pairing) < 0 or pairing == null) {
                return BleError.PairingFailed;
            }
            const p = pairing.?;
            defer _ = p.lpVtbl.Release(p);

            var is_paired: u8 = 0;
            if (p.lpVtbl.get_IsPaired(p, &is_paired) >= 0 and is_paired != 0) {
                dev.bond_state = .bonded;
                return;
            }

            var pairing2: ?*bindings.IDeviceInformationPairing2 = null;
            if (p.lpVtbl.QueryInterface(p, &bindings.IID_IDeviceInformationPairing2, @ptrCast(&pairing2)) < 0 or pairing2 == null) {
                return BleError.PairingFailed;
            }
            const p2 = pairing2.?;
            defer _ = p2.lpVtbl.Release(p2);

            var custom_pairing: ?*bindings.IDeviceInformationCustomPairing = null;
            if (p2.lpVtbl.get_Custom(p2, &custom_pairing) < 0 or custom_pairing == null) {
                return BleError.PairingFailed;
            }
            const cp = custom_pairing.?;
            defer _ = cp.lpVtbl.Release(cp);

            var session_ctx = PairingSessionContext{
                .io_cap = io_cap,
                .callbacks = self.pairing_callbacks,
            };

            var handler = bindings.PairingRequestedHandler{
                .pair_ctx = @ptrCast(&session_ctx),
                .on_pairing_requested = onPairingRequested,
            };
            var token: bindings.EventRegistrationToken = 0;
            if (cp.lpVtbl.add_PairingRequested(cp, @ptrCast(&handler), &token) < 0) {
                return BleError.PairingFailed;
            }
            defer {
                handler.deactivate();
                _ = cp.lpVtbl.remove_PairingRequested(cp, token);
            }

            const supported_kinds: u32 = switch (io_cap) {
                .no_input_no_output => bindings.DevicePairingKinds.ConfirmOnly,
                .display_only => bindings.DevicePairingKinds.DisplayPin | bindings.DevicePairingKinds.ConfirmOnly,
                .display_yes_no => bindings.DevicePairingKinds.ConfirmPinMatch | bindings.DevicePairingKinds.DisplayPin | bindings.DevicePairingKinds.ConfirmOnly,
                .keyboard_only => bindings.DevicePairingKinds.ProvidePin | bindings.DevicePairingKinds.ConfirmOnly,
                .keyboard_display => bindings.DevicePairingKinds.ConfirmPinMatch | bindings.DevicePairingKinds.ProvidePin | bindings.DevicePairingKinds.DisplayPin | bindings.DevicePairingKinds.ConfirmOnly,
            };

            dev.bond_state = .bonding;
            var pair_op: ?*bindings.IAsyncOperationGeneric = null;
            if (cp.lpVtbl.PairAsync(cp, supported_kinds, &pair_op) < 0 or pair_op == null) {
                dev.bond_state = .not_bonded;
                return BleError.PairingFailed;
            }

            const res_raw = (awaitAsync(pair_op.?, self.timeouts.pair_ms) catch |err| {
                dev.bond_state = .not_bonded;
                return err;
            }) orelse {
                dev.bond_state = .not_bonded;
                return BleError.PairingFailed;
            };

            const pair_res: *bindings.IDevicePairingResult = @ptrCast(@alignCast(res_raw));
            defer _ = pair_res.lpVtbl.Release(pair_res);

            var status: bindings.DevicePairingResultStatus = .Failed;
            if (pair_res.lpVtbl.get_Status(pair_res, &status) < 0) {
                dev.bond_state = .not_bonded;
                return BleError.PairingFailed;
            }

            if (status == .Paired or status == .AlreadyPaired) {
                dev.bond_state = .bonded;
                return;
            }

            dev.bond_state = .not_bonded;
            return BleError.PairingFailed;
        }

        /// Unpairs a bonded BLE peripheral via `IDeviceInformationPairing2.UnpairAsync` (Item 9).
        pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) BleError!void {
            if (builtin.os.tag != .windows) return BleError.NotSupported;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return BleError.InvalidState;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            const ble_dev = dev.ble_device orelse return BleError.NotConnected;

            var dev2: ?*bindings.IBluetoothLEDevice2 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice2, @ptrCast(&dev2)) < 0 or dev2 == null) {
                return BleError.PairingFailed;
            }
            const d2 = dev2.?;
            defer _ = d2.lpVtbl.Release(d2);

            var dev_info: ?*bindings.IDeviceInformation = null;
            if (d2.lpVtbl.get_DeviceInformation(d2, &dev_info) < 0 or dev_info == null) {
                return BleError.PairingFailed;
            }
            const info = dev_info.?;
            defer _ = info.lpVtbl.Release(info);

            var dev_info2: ?*bindings.IDeviceInformation2 = null;
            if (info.lpVtbl.QueryInterface(info, &bindings.IID_IDeviceInformation2, @ptrCast(&dev_info2)) < 0 or dev_info2 == null) {
                return BleError.PairingFailed;
            }
            const info2 = dev_info2.?;
            defer _ = info2.lpVtbl.Release(info2);

            var pairing: ?*bindings.IDeviceInformationPairing = null;
            if (info2.lpVtbl.get_Pairing(info2, &pairing) < 0 or pairing == null) {
                return BleError.PairingFailed;
            }
            const p = pairing.?;
            defer _ = p.lpVtbl.Release(p);

            var pairing2: ?*bindings.IDeviceInformationPairing2 = null;
            if (p.lpVtbl.QueryInterface(p, &bindings.IID_IDeviceInformationPairing2, @ptrCast(&pairing2)) < 0 or pairing2 == null) {
                return BleError.PairingFailed;
            }
            const p2 = pairing2.?;
            defer _ = p2.lpVtbl.Release(p2);

            var unpair_op: ?*bindings.IAsyncOperationGeneric = null;
            if (p2.lpVtbl.UnpairAsync(p2, &unpair_op) < 0 or unpair_op == null) {
                return BleError.PairingFailed;
            }

            const res_raw = (try awaitAsync(unpair_op.?, self.timeouts.pair_ms)) orelse return BleError.PairingFailed;
            const unpair_res: *bindings.IDeviceUnpairingResult = @ptrCast(@alignCast(res_raw));
            defer _ = unpair_res.lpVtbl.Release(unpair_res);

            var status: bindings.DeviceUnpairingResultStatus = .Failed;
            if (unpair_res.lpVtbl.get_Status(unpair_res, &status) < 0) {
                return BleError.PairingFailed;
            }

            if (status == .Unpaired or status == .AlreadyUnpaired) {
                dev.bond_state = .not_bonded;
                return;
            }
            return BleError.PairingFailed;
        }

        fn queryWinRtBondState(ble_dev: *bindings.IBluetoothLEDevice) types.BondState {
            if (builtin.os.tag != .windows) return .not_bonded;
            var dev2: ?*bindings.IBluetoothLEDevice2 = null;
            if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice2, @ptrCast(&dev2)) < 0 or dev2 == null) {
                return .not_bonded;
            }
            const d2 = dev2.?;
            defer _ = d2.lpVtbl.Release(d2);

            var dev_info: ?*bindings.IDeviceInformation = null;
            if (d2.lpVtbl.get_DeviceInformation(d2, &dev_info) < 0 or dev_info == null) {
                return .not_bonded;
            }
            const info = dev_info.?;
            defer _ = info.lpVtbl.Release(info);

            var dev_info2: ?*bindings.IDeviceInformation2 = null;
            if (info.lpVtbl.QueryInterface(info, &bindings.IID_IDeviceInformation2, @ptrCast(&dev_info2)) < 0 or dev_info2 == null) {
                return .not_bonded;
            }
            const info2 = dev_info2.?;
            defer _ = info2.lpVtbl.Release(info2);

            var pairing: ?*bindings.IDeviceInformationPairing = null;
            if (info2.lpVtbl.get_Pairing(info2, &pairing) < 0 or pairing == null) {
                return .not_bonded;
            }
            const p = pairing.?;
            defer _ = p.lpVtbl.Release(p);

            var is_paired: u8 = 0;
            if (p.lpVtbl.get_IsPaired(p, &is_paired) >= 0 and is_paired != 0) {
                return .bonded;
            }
            return .not_bonded;
        }

        /// Queries the real OS pairing state via `DeviceInformation.Pairing.IsPaired` (Item 6).
        pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.is_closed.load(.acquire)) return .not_bonded;
            const dev: *DeviceContext = @ptrCast(@alignCast(dev_handle));
            if (dev.ble_device) |ble_dev| {
                dev.bond_state = queryWinRtBondState(ble_dev);
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

// ============================================================================
// Unit Tests
// ============================================================================

test "WinRT GUID <-> Zig-BLE UUID conversion roundtrip" {
    const hrm_uuid = UUID.from16(0x180D);
    const g = uuidToGuid(hrm_uuid);
    try std.testing.expectEqual(@as(u32, 0x0000180D), g.Data1);
    try std.testing.expectEqual(@as(u16, 0x0000), g.Data2);
    try std.testing.expectEqual(@as(u16, 0x1000), g.Data3);
    try std.testing.expectEqual(@as(u8, 0x80), g.Data4[0]);
    try std.testing.expectEqual(@as(u8, 0xFB), g.Data4[7]);

    const roundtrip = guidToUuid(g);
    try std.testing.expect(hrm_uuid.eql(roundtrip));
}

test "WinRT u64 <-> Zig-BLE Address conversion roundtrip" {
    const addr = try Address.parse("AA:BB:CC:11:22:33");
    const u64_val = addressToU64(addr);
    try std.testing.expectEqual(@as(u64, 0xAABBCC112233), u64_val);

    const roundtrip = u64ToAddress(u64_val);
    try std.testing.expect(addr.eql(roundtrip));
}

test "WindowsBackend structural initialization and VTable conformance" {
    var win = WindowsBackend.init();
    const b = win.asBackend();
    try std.testing.expectEqualStrings("WindowsWinRT", b.getName());
}

test "WindowsBackendWithConfig custom pool sizes and PoolExhausted error" {
    const SmallBackend = WindowsBackendWithConfig(.{
        .max_devices = 2,
        .max_services_per_device = 2,
        .max_characteristics_per_device = 2,
    });
    var win = SmallBackend.init();
    defer win.deinit();

    const a1 = try Address.parse("11:22:33:44:55:01");
    const a2 = try Address.parse("11:22:33:44:55:02");
    const a3 = try Address.parse("11:22:33:44:55:03");

    _ = try win.allocateDeviceSlot(a1);
    _ = try win.allocateDeviceSlot(a2);
    try std.testing.expectError(BleError.PoolExhausted, win.allocateDeviceSlot(a3));
}

test "WindowsBackend ConnectionStatusChanged cleans up subscriptions and invokes reconnect callback" {
    var win = WindowsBackend.init();
    defer win.deinit();

    const addr = try Address.parse("AA:BB:CC:DD:EE:01");
    var dev = try win.allocateDeviceSlot(addr);
    dev.is_connected = true;
    dev.was_connected_once = true;
    dev.subscribed_uuid = UUID.from16(0x2A37);

    const Tracker = struct {
        disconnected_count: usize = 0,
        reconnected_count: usize = 0,
        fn onConnEvent(ev: ConnectionEvent, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            if (ev == .disconnected) self.disconnected_count += 1;
        }
        fn onReconnect(_: Address, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.reconnected_count += 1;
        }
    };
    var tracker = Tracker{};
    win.setConnectionEventCallback(Tracker.onConnEvent, &tracker);
    win.setReconnectCallback(Tracker.onReconnect, &tracker);

    // 1. Simulate sudden radio disconnect
    WindowsBackend.simulateConnectionStatusTransition(dev, false);
    try std.testing.expect(!dev.is_connected);
    try std.testing.expect(dev.subscribed_uuid == null);
    try std.testing.expectEqual(@as(usize, 1), tracker.disconnected_count);

    // 2. Simulate radio reconnect
    WindowsBackend.simulateConnectionStatusTransition(dev, true);
    try std.testing.expect(dev.is_connected);
    try std.testing.expectEqual(@as(usize, 1), tracker.reconnected_count);

    // 3. After deinit(), no callbacks fire
    win.deinit();
    WindowsBackend.simulateConnectionStatusTransition(dev, false);
    try std.testing.expectEqual(@as(usize, 1), tracker.disconnected_count);
}

test "WindowsBackend evaluatePairingCeremony supports Passkey and Numeric Comparison callbacks" {
    const PairTester = struct {
        last_numeric: ?u32 = null,
        displayed_pin: u32 = 0,

        fn onConfirm(num: ?u32, udata: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.last_numeric = num;
            return if (num) |n| (n == 654321) else true;
        }
        fn onProvidePin(_: ?*anyopaque) ?u32 {
            return 420199;
        }
        fn onDisplayPin(pin: u32, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.displayed_pin = pin;
        }
    };

    var tester = PairTester{};
    const cbs = PairingCallbacks{
        .on_confirm = PairTester.onConfirm,
        .on_request_passkey = PairTester.onProvidePin,
        .on_display_passkey = PairTester.onDisplayPin,
        .user_data = &tester,
    };

    // 1. Numeric Comparison (ConfirmPinMatch) matching
    const nc_ok = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ConfirmPinMatch, "654321", .display_yes_no, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.accept_only, nc_ok);
    try std.testing.expectEqual(@as(?u32, 654321), tester.last_numeric);

    // 2. Numeric Comparison mismatching -> rejected
    const nc_bad = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ConfirmPinMatch, "111111", .display_yes_no, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.reject, nc_bad);

    // 3. Passkey Entry (ProvidePin) -> formats 6-digit PIN
    const pk_act = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.ProvidePin, null, .keyboard_only, cbs);
    switch (pk_act) {
        .accept_with_pin => |digits| try std.testing.expectEqualStrings("420199", &digits),
        else => return error.TestUnexpectedResult,
    }

    // 4. DisplayPin -> invokes display callback and accepts
    const disp_act = WindowsBackend.evaluatePairingCeremony(bindings.DevicePairingKinds.DisplayPin, "987654", .display_only, cbs);
    try std.testing.expectEqual(WindowsBackend.PairingAction.accept_only, disp_act);
    try std.testing.expectEqual(@as(u32, 987654), tester.displayed_pin);
}

