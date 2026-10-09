//! # Zig-BLE Windows Native Backend
//!
//! Implements BackendVTable for Windows using native Win32 Bluetooth APIs
//! (bthprops.cpl / BluetoothApis.dll) and WinRT COM APIs (combase.dll).
//! 100% Pure Zig, zero MSVC C++ runtime dependencies, zero external C libraries.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const vtable_mod = @import("../vtable.zig");

pub const Address = types.Address;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const BleError = types.BleError;
pub const BackendVTable = vtable_mod.BackendVTable;
pub const Backend = vtable_mod.Backend;

pub const bindings = @import("bindings.zig");
pub const radio_mod = @import("radio.zig");
pub const WindowsRadio = radio_mod.WindowsRadio;
pub const RadioInfo = radio_mod.RadioInfo;

pub const WindowsDevice = struct {
    device_obj: *anyopaque,
    device: *const bindings.IBluetoothLEDevice,
    device3: ?*const bindings.IBluetoothLEDevice3 = null,
    closable: ?*const bindings.IClosable = null,
    address: Address,
    characteristics: std.AutoHashMap(UUID, CharEntry),
    subscriptions: std.AutoHashMap(UUID, SubEntry),
    services: std.ArrayList(*anyopaque),
    allocator: std.mem.Allocator,
    backend: *WindowsBackend,

    pub const CharEntry = struct {
        char_obj: *anyopaque,
        char: *const bindings.IGattCharacteristic,
        char3: ?*const bindings.IGattCharacteristic3 = null,
        service_obj: *anyopaque,
        service: *const bindings.IGattDeviceService,
        service3: ?*const bindings.IGattDeviceService3 = null,
    };

    pub const SubscriptionContext = struct {
        dev: *WindowsDevice,
        char_uuid: UUID,
        cb: NotificationCallback,
        user_data: ?*anyopaque,
    };

    pub const SubEntry = struct {
        cookie: bindings.EventRegistrationToken,
        handler: *bindings.GattValueChangedHandler,
        ctx: *SubscriptionContext,
    };

    pub fn deinit(self: *WindowsDevice) void {
        // Unsubscribe all active notification handlers
        var sub_iter = self.subscriptions.iterator();
        while (sub_iter.next()) |entry| {
            const char_uuid = entry.key_ptr.*;
            const sub = entry.value_ptr.*;
            if (self.characteristics.get(char_uuid)) |char_entry| {
                _ = char_entry.char.lpVtbl.remove_ValueChanged(char_entry.char_obj, sub.cookie);
            }
            self.allocator.destroy(sub.handler);
            self.allocator.destroy(sub.ctx);
        }
        self.subscriptions.deinit();

        // Release characteristic objects
        var char_iter = self.characteristics.iterator();
        while (char_iter.next()) |entry| {
            const unk: *const bindings.IUnknown = @ptrCast(@alignCast(entry.value_ptr.char_obj));
            _ = unk.lpVtbl.Release(entry.value_ptr.char_obj);
        }
        self.characteristics.deinit();

        // Close and release service objects
        for (self.services.items) |svc_obj| {
            const unk: *const bindings.IUnknown = @ptrCast(@alignCast(svc_obj));
            var closable_obj: ?*anyopaque = null;
            if (unk.lpVtbl.QueryInterface(svc_obj, &bindings.IID_IClosable, &closable_obj) == bindings.S_OK and closable_obj != null) {
                const closable: *const bindings.IClosable = @ptrCast(@alignCast(closable_obj.?));
                _ = closable.lpVtbl.Close(closable_obj.?);
                _ = unk.lpVtbl.Release(closable_obj.?);
            }
            _ = unk.lpVtbl.Release(svc_obj);
        }
        self.services.deinit(self.allocator);

        // Close device if IClosable is supported
        if (self.closable) |c| {
            _ = c.lpVtbl.Close(self.device_obj);
        }

        // Release device object
        const dev_unk: *const bindings.IUnknown = @ptrCast(@alignCast(self.device_obj));
        _ = dev_unk.lpVtbl.Release(self.device_obj);
    }
};

pub const WindowsBackend = struct {
    radio: ?WindowsRadio = null,
    winrt: ?bindings.WindowsWinRtApis = null,
    allocator: std.mem.Allocator,

    // WinRT Advertisement Watcher state
    watcher_obj: ?*anyopaque = null,
    watcher_sink: ?*bindings.AdvReceivedHandler = null,
    watcher_token: bindings.EventRegistrationToken = .{ .value = 0 },
    scan_cb: ?ScanCallback = null,
    scan_user_data: ?*anyopaque = null,

    scanning: bool = false,
    powered: bool = false,

    pub fn init() WindowsBackend {
        return .{
            .radio = WindowsRadio.init(),
            .winrt = bindings.WindowsWinRtApis.load(),
            .allocator = std.heap.page_allocator,
        };
    }

    pub fn deinit(self: *WindowsBackend) void {
        self.closeAdapterInternal();
        if (self.radio) |*r| {
            r.deinit();
            self.radio = null;
        }
        if (self.winrt) |*w| {
            w.unload();
            self.winrt = null;
        }
    }

    fn closeAdapterInternal(self: *WindowsBackend) void {
        if (self.scanning) {
            _ = self.stopScanInternal() catch {};
        }
        if (self.radio) |*r| {
            r.close();
        }
        if (self.winrt) |*w| {
            w.roUninitialize();
        }
        self.scanning = false;
        self.powered = false;
    }

    pub fn openAdapter(ctx: *anyopaque, index: u16) anyerror!void {
        _ = index;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));

        if (self.winrt == null) {
            self.winrt = bindings.WindowsWinRtApis.load();
        }
        if (self.winrt) |*w| {
            const hr = w.roInitialize(1); // RO_INIT_MULTITHREADED
            if (hr != bindings.S_OK and hr != bindings.S_FALSE) {
                return BleError.IoError;
            }
        }

        if (self.radio == null) {
            self.radio = WindowsRadio.init();
        }
        if (self.radio) |*r| {
            try r.openDefault();
            self.powered = r.isPowered();
        } else {
            // If Win32 radio not found but WinRT is loaded, consider it powered
            if (self.winrt != null) {
                self.powered = true;
            } else {
                return BleError.AdapterNotFound;
            }
        }
    }

    pub fn closeAdapter(ctx: *anyopaque) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.closeAdapterInternal();
    }

    pub fn setPowered(ctx: *anyopaque, powered: bool) anyerror!void {
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (powered) {
            if (self.radio) |*r| {
                if (!r.isPowered()) try r.openDefault();
            }
        } else {
            if (self.radio) |*r| {
                r.close();
            }
        }
        self.powered = powered;
    }

    pub fn isPowered(ctx: *anyopaque) anyerror!bool {
        if (builtin.os.tag != .windows) return false;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (self.radio) |*r| {
            return r.isPowered();
        }
        return self.powered;
    }

    fn onAdvReceived(ctx_ptr: *anyopaque, dev: *const DiscoveredDevice) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx_ptr));
        if (self.scan_cb) |cb| {
            var mutable_dev = dev.*;
            cb(&mutable_dev, self.scan_user_data);
        }
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void {
        _ = filter;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;

        self.scan_cb = cb;
        self.scan_user_data = user_data;

        // Try modern WinRT BluetoothLEAdvertisementWatcher first
        if (self.winrt) |*w| {
            const watcher_obj = w.activateInstance("Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher") orelse {
                return BleError.IoError;
            };
            self.watcher_obj = watcher_obj;

            const watcher: *const bindings.IBluetoothLEAdvertisementWatcher = @ptrCast(@alignCast(watcher_obj));
            // Set active scanning mode so Windows requests Scan Response packets
            _ = watcher.lpVtbl.put_ScanningMode(watcher_obj, .Active);

            const sink = try self.allocator.create(bindings.AdvReceivedHandler);
            sink.* = bindings.AdvReceivedHandler.init(onAdvReceived, @ptrCast(self), w);
            self.watcher_sink = sink;

            var token: bindings.EventRegistrationToken = undefined;
            if (watcher.lpVtbl.add_Received(watcher_obj, sink, &token) != bindings.S_OK) {
                self.allocator.destroy(sink);
                self.watcher_sink = null;
                const unk: *const bindings.IUnknown = @ptrCast(@alignCast(watcher_obj));
                _ = unk.lpVtbl.Release(watcher_obj);
                self.watcher_obj = null;
                return BleError.IoError;
            }
            self.watcher_token = token;

            if (watcher.lpVtbl.Start(watcher_obj) != bindings.S_OK) {
                _ = watcher.lpVtbl.remove_Received(watcher_obj, token);
                self.allocator.destroy(sink);
                self.watcher_sink = null;
                const unk: *const bindings.IUnknown = @ptrCast(@alignCast(watcher_obj));
                _ = unk.lpVtbl.Release(watcher_obj);
                self.watcher_obj = null;
                return BleError.IoError;
            }

            self.scanning = true;
            return;
        }

        // Fallback: Legacy Win32 inquiry
        const radio = self.radio orelse return BleError.AdapterNotFound;
        const find_first = radio.apis.findFirstDevice orelse return BleError.NotSupported;
        const find_next = radio.apis.findNextDevice orelse return BleError.NotSupported;
        const find_close = radio.apis.findDeviceClose orelse return BleError.NotSupported;

        self.scanning = true;

        var search_params = bindings.BLUETOOTH_DEVICE_SEARCH_PARAMS{
            .hRadio = radio.radio_handle,
            .fReturnAuthenticated = 1,
            .fReturnRemembered = 1,
            .fReturnUnknown = 1,
            .fReturnConnected = 1,
            .fIssueInquiry = 1,
            .cTimeoutMultiplier = 2,
        };

        var dev_info = std.mem.zeroes(bindings.BLUETOOTH_DEVICE_INFO);
        dev_info.dwSize = @sizeOf(bindings.BLUETOOTH_DEVICE_INFO);

        const h_find = find_first(&search_params, &dev_info);
        if (h_find) |hf| {
            defer _ = find_close(hf);

            while (self.scanning) {
                var discovered = DiscoveredDevice{
                    .address = Address{
                        .bytes = [_]u8{
                            @intCast((dev_info.Address >> 40) & 0xFF),
                            @intCast((dev_info.Address >> 32) & 0xFF),
                            @intCast((dev_info.Address >> 24) & 0xFF),
                            @intCast((dev_info.Address >> 16) & 0xFF),
                            @intCast((dev_info.Address >> 8) & 0xFF),
                            @intCast((dev_info.Address >> 0) & 0xFF),
                        },
                    },
                    .rssi = null,
                };

                var len: usize = 0;
                while (len < dev_info.szName.len and dev_info.szName[len] != 0) : (len += 1) {}
                var name_utf8: [64]u8 = undefined;
                if (std.unicode.utf16LeToUtf8(&name_utf8, dev_info.szName[0..len])) |utf8_len| {
                    discovered.setName(name_utf8[0..utf8_len]);
                } else |_| {}

                cb(&discovered, user_data);

                dev_info = std.mem.zeroes(bindings.BLUETOOTH_DEVICE_INFO);
                dev_info.dwSize = @sizeOf(bindings.BLUETOOTH_DEVICE_INFO);
                if (find_next(hf, &dev_info) == .FALSE) break;
            }
        }
    }

    fn stopScanInternal(self: *WindowsBackend) anyerror!void {
        if (self.watcher_obj) |w_obj| {
            const watcher: *const bindings.IBluetoothLEAdvertisementWatcher = @ptrCast(@alignCast(w_obj));
            _ = watcher.lpVtbl.Stop(w_obj);
            _ = watcher.lpVtbl.remove_Received(w_obj, self.watcher_token);

            if (self.watcher_sink) |sink| {
                self.allocator.destroy(sink);
                self.watcher_sink = null;
            }

            const unk: *const bindings.IUnknown = @ptrCast(@alignCast(w_obj));
            _ = unk.lpVtbl.Release(w_obj);
            self.watcher_obj = null;
        }
        self.scanning = false;
    }

    pub fn stopScan(ctx: *anyopaque) anyerror!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        try self.stopScanInternal();
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque {
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;

        const winrt = self.winrt orelse return BleError.NotSupported;

        // Convert MAC Address (Big-Endian in Zig-BLE) to u64
        var addr_u64: u64 = 0;
        for (addr.bytes, 0..) |b, i| {
            addr_u64 |= @as(u64, b) << @intCast((5 - i) * 8);
        }

        const statics_obj = winrt.getActivationFactory(
            "Windows.Devices.Bluetooth.BluetoothLEDevice",
            &bindings.IID_IBluetoothLEDeviceStatics,
        ) orelse return BleError.IoError;
        const statics: *const bindings.IBluetoothLEDeviceStatics = @ptrCast(@alignCast(statics_obj));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(statics_obj))).lpVtbl.Release(statics_obj);

        var async_op: ?*anyopaque = null;
        if (statics.lpVtbl.FromBluetoothAddressAsync(statics_obj, addr_u64, &async_op) != bindings.S_OK or async_op == null) {
            return BleError.ConnectionFailed;
        }

        const dev_raw = winrt.awaitAsync(?*anyopaque, async_op.?, timeout_ms) catch {
            return BleError.ConnectionFailed;
        };
        const dev_obj = dev_raw orelse return BleError.DeviceNotFound;

        const dev_unk: *const bindings.IUnknown = @ptrCast(@alignCast(dev_obj));
        var dev_ptr: ?*anyopaque = null;
        if (dev_unk.lpVtbl.QueryInterface(dev_obj, &bindings.IID_IBluetoothLEDevice, &dev_ptr) != bindings.S_OK or dev_ptr == null) {
            _ = dev_unk.lpVtbl.Release(dev_obj);
            return BleError.IoError;
        }

        var dev3_ptr: ?*anyopaque = null;
        _ = dev_unk.lpVtbl.QueryInterface(dev_obj, &bindings.IID_IBluetoothLEDevice3, &dev3_ptr);

        var closable_ptr: ?*anyopaque = null;
        _ = dev_unk.lpVtbl.QueryInterface(dev_obj, &bindings.IID_IClosable, &closable_ptr);

        const dev = try self.allocator.create(WindowsDevice);
        dev.* = .{
            .device_obj = dev_obj,
            .device = @ptrCast(@alignCast(dev_ptr.?)),
            .device3 = if (dev3_ptr) |p| @ptrCast(@alignCast(p)) else null,
            .closable = if (closable_ptr) |p| @ptrCast(@alignCast(p)) else null,
            .address = addr,
            .characteristics = std.AutoHashMap(UUID, WindowsDevice.CharEntry).init(self.allocator),
            .subscriptions = std.AutoHashMap(UUID, WindowsDevice.SubEntry).init(self.allocator),
            .services = .empty,
            .allocator = self.allocator,
            .backend = self,
        };

        return @ptrCast(dev);
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        dev.deinit();
        dev.allocator.destroy(dev);
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        _ = ctx;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        var status: i32 = 0;
        if (dev.device.lpVtbl.get_ConnectionStatus(dev.device_obj, &status) == bindings.S_OK) {
            return status == 1; // 1 = Connected, 0 = Disconnected
        }
        return true;
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        _ = ctx;
        _ = dev_handle;
        return null;
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        _ = ctx;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        const winrt = dev.backend.winrt orelse return BleError.NotSupported;
        const device3 = dev.device3 orelse return BleError.NotSupported;

        // Query services uncached (1 = Uncached)
        var services_op: ?*anyopaque = null;
        if (device3.lpVtbl.GetGattServicesWithCacheModeAsync(dev.device_obj, 1, &services_op) != bindings.S_OK or services_op == null) {
            return BleError.ServiceNotFound;
        }

        const res_obj = try winrt.awaitAsync(?*anyopaque, services_op.?, 15000);
        const result_raw = res_obj orelse return BleError.ServiceNotFound;
        const result: *const bindings.IGattDeviceServicesResult = @ptrCast(@alignCast(result_raw));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(result_raw))).lpVtbl.Release(result_raw);

        var status: bindings.GattCommunicationStatus = .Success;
        _ = result.lpVtbl.get_Status(result_raw, &status);
        if (status != .Success) {
            if (status == .AccessDenied) return BleError.AuthenticationFailed;
            return BleError.ServiceNotFound;
        }

        var services_vec_obj: ?*anyopaque = null;
        if (result.lpVtbl.get_Services(result_raw, &services_vec_obj) != bindings.S_OK or services_vec_obj == null) {
            return BleError.ServiceNotFound;
        }
        const services_vec: *const bindings.IVectorView = @ptrCast(@alignCast(services_vec_obj.?));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(services_vec_obj.?))).lpVtbl.Release(services_vec_obj.?);

        var num_services: u32 = 0;
        _ = services_vec.lpVtbl.get_Size(services_vec_obj.?, &num_services);

        var i: u32 = 0;
        while (i < num_services) : (i += 1) {
            var svc_obj: ?*anyopaque = null;
            if (services_vec.lpVtbl.GetAt(services_vec_obj.?, i, &svc_obj) != bindings.S_OK or svc_obj == null) continue;

            const svc_raw = svc_obj.?;
            try dev.services.append(dev.allocator, svc_raw);

            const svc_unk: *const bindings.IUnknown = @ptrCast(@alignCast(svc_raw));
            var svc3_ptr: ?*anyopaque = null;
            if (svc_unk.lpVtbl.QueryInterface(svc_raw, &bindings.IID_IGattDeviceService3, &svc3_ptr) != bindings.S_OK or svc3_ptr == null) {
                continue;
            }
            const svc3: *const bindings.IGattDeviceService3 = @ptrCast(@alignCast(svc3_ptr.?));
            defer _ = svc_unk.lpVtbl.Release(svc3_ptr.?);

            const svc: *const bindings.IGattDeviceService = @ptrCast(@alignCast(svc_raw));

            // Discover characteristics for this service
            var char_op: ?*anyopaque = null;
            if (svc3.lpVtbl.GetCharacteristicsWithCacheModeAsync(svc_raw, 1, &char_op) != bindings.S_OK or char_op == null) {
                continue;
            }

            const char_res_obj = winrt.awaitAsync(?*anyopaque, char_op.?, 15000) catch continue;
            const char_res_raw = char_res_obj orelse continue;
            const char_result: *const bindings.IGattCharacteristicsResult = @ptrCast(@alignCast(char_res_raw));
            defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(char_res_raw))).lpVtbl.Release(char_res_raw);

            var char_status: bindings.GattCommunicationStatus = .Success;
            _ = char_result.lpVtbl.get_Status(char_res_raw, &char_status);
            if (char_status != .Success) continue;

            var char_vec_obj: ?*anyopaque = null;
            if (char_result.lpVtbl.get_Characteristics(char_res_raw, &char_vec_obj) != bindings.S_OK or char_vec_obj == null) continue;
            const char_vec: *const bindings.IVectorView = @ptrCast(@alignCast(char_vec_obj.?));
            defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(char_vec_obj.?))).lpVtbl.Release(char_vec_obj.?);

            var num_chars: u32 = 0;
            _ = char_vec.lpVtbl.get_Size(char_vec_obj.?, &num_chars);

            var j: u32 = 0;
            while (j < num_chars) : (j += 1) {
                var char_obj: ?*anyopaque = null;
                if (char_vec.lpVtbl.GetAt(char_vec_obj.?, j, &char_obj) != bindings.S_OK or char_obj == null) continue;

                const char_raw = char_obj.?;
                const ch_unk: *const bindings.IUnknown = @ptrCast(@alignCast(char_raw));

                var ch_ptr: ?*anyopaque = null;
                if (ch_unk.lpVtbl.QueryInterface(char_raw, &bindings.IID_IGattCharacteristic, &ch_ptr) != bindings.S_OK or ch_ptr == null) {
                    _ = ch_unk.lpVtbl.Release(char_raw);
                    continue;
                }
                const ch: *const bindings.IGattCharacteristic = @ptrCast(@alignCast(ch_ptr.?));

                var ch3_ptr: ?*anyopaque = null;
                _ = ch_unk.lpVtbl.QueryInterface(char_raw, &bindings.IID_IGattCharacteristic3, &ch3_ptr);

                var guid_val: bindings.GUID = undefined;
                if (ch.lpVtbl.get_Uuid(char_raw, &guid_val) == bindings.S_OK) {
                    const char_uuid = guid_val.toUUID();
                    try dev.characteristics.put(char_uuid, .{
                        .char_obj = char_raw,
                        .char = ch,
                        .char3 = if (ch3_ptr) |p| @ptrCast(@alignCast(p)) else null,
                        .service_obj = svc_raw,
                        .service = svc,
                        .service3 = svc3,
                    });
                } else {
                    _ = ch_unk.lpVtbl.Release(char_raw);
                }
            }
        }
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize {
        _ = ctx;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        const winrt = dev.backend.winrt orelse return BleError.NotSupported;

        const char_entry = dev.characteristics.get(char_uuid) orelse return BleError.CharacteristicNotFound;

        var read_op: ?*anyopaque = null;
        if (char_entry.char.lpVtbl.ReadValueWithCacheModeAsync(char_entry.char_obj, 1, &read_op) != bindings.S_OK or read_op == null) {
            return BleError.ReadFailed;
        }

        const res_obj = try winrt.awaitAsync(?*anyopaque, read_op.?, 5000);
        const res_raw = res_obj orelse return BleError.ReadFailed;
        const read_result: *const bindings.IGattReadResult = @ptrCast(@alignCast(res_raw));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(res_raw))).lpVtbl.Release(res_raw);

        var status: bindings.GattCommunicationStatus = .Success;
        _ = read_result.lpVtbl.get_Status(res_raw, &status);
        if (status != .Success) {
            if (status == .AccessDenied) return BleError.AuthenticationFailed;
            return BleError.ReadFailed;
        }

        var ibuffer_obj: ?*anyopaque = null;
        if (read_result.lpVtbl.get_Value(res_raw, &ibuffer_obj) != bindings.S_OK or ibuffer_obj == null) {
            return BleError.ReadFailed;
        }
        const ibuffer_raw = ibuffer_obj.?;
        const buf_unk: *const bindings.IUnknown = @ptrCast(@alignCast(ibuffer_raw));
        defer _ = buf_unk.lpVtbl.Release(ibuffer_raw);

        var byte_access_obj: ?*anyopaque = null;
        if (buf_unk.lpVtbl.QueryInterface(ibuffer_raw, &bindings.IID_IBufferByteAccess, &byte_access_obj) != bindings.S_OK or byte_access_obj == null) {
            return BleError.ReadFailed;
        }
        const byte_access: *const bindings.IBufferByteAccess = @ptrCast(@alignCast(byte_access_obj.?));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(byte_access_obj.?))).lpVtbl.Release(byte_access_obj.?);

        const ibuffer: *const bindings.IBuffer = @ptrCast(@alignCast(ibuffer_raw));
        var length: u32 = 0;
        _ = ibuffer.lpVtbl.get_Length(ibuffer_raw, &length);

        var raw_bytes: ?[*]u8 = null;
        if (byte_access.lpVtbl.Buffer(byte_access_obj.?, &raw_bytes) != bindings.S_OK or raw_bytes == null) {
            return BleError.ReadFailed;
        }

        const copy_len = @min(buf.len, length);
        @memcpy(buf[0..copy_len], raw_bytes.?[0..copy_len]);
        return copy_len;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void {
        _ = ctx;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        const winrt = dev.backend.winrt orelse return BleError.NotSupported;

        const char_entry = dev.characteristics.get(char_uuid) orelse return BleError.CharacteristicNotFound;

        // Create IBuffer from raw byte data using ICryptographicBufferStatics
        const crypto_factory_obj = winrt.getActivationFactory(
            "Windows.Security.Cryptography.CryptographicBuffer",
            &bindings.IID_ICryptographicBufferStatics,
        ) orelse return BleError.IoError;
        const crypto: *const bindings.ICryptographicBufferStatics = @ptrCast(@alignCast(crypto_factory_obj));
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(crypto_factory_obj))).lpVtbl.Release(crypto_factory_obj);

        var ibuffer_obj: ?*anyopaque = null;
        if (crypto.lpVtbl.CreateFromByteArray(crypto_factory_obj, @intCast(data.len), data.ptr, &ibuffer_obj) != bindings.S_OK or ibuffer_obj == null) {
            return BleError.IoError;
        }
        defer _ = @as(*const bindings.IUnknown, @ptrCast(@alignCast(ibuffer_obj.?))).lpVtbl.Release(ibuffer_obj.?);

        const write_opt: bindings.GattWriteOption = if (with_response) .WriteWithResponse else .WriteWithoutResponse;
        var write_op: ?*anyopaque = null;

        if (char_entry.char.lpVtbl.WriteValueWithOptionAsync(char_entry.char_obj, ibuffer_obj.?, write_opt, &write_op) != bindings.S_OK or write_op == null) {
            return BleError.WriteFailed;
        }

        const res_status = try winrt.awaitAsync(bindings.GattCommunicationStatus, write_op.?, 5000);
        if (res_status != .Success) {
            if (res_status == .AccessDenied) return BleError.AuthenticationFailed;
            return BleError.WriteFailed;
        }
    }

    fn onValueChangedNotification(ctx_ptr: *anyopaque, data: []const u8) void {
        const sub: *WindowsDevice.SubscriptionContext = @ptrCast(@alignCast(ctx_ptr));
        sub.cb(sub.char_uuid, data, sub.user_data);
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void {
        _ = ctx;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        const winrt = dev.backend.winrt orelse return BleError.NotSupported;

        const char_entry = dev.characteristics.get(char_uuid) orelse return BleError.CharacteristicNotFound;
        if (dev.subscriptions.contains(char_uuid)) return;

        const sub_ctx = try dev.allocator.create(WindowsDevice.SubscriptionContext);
        sub_ctx.* = .{
            .dev = dev,
            .char_uuid = char_uuid,
            .cb = cb,
            .user_data = user_data,
        };

        const handler = try dev.allocator.create(bindings.GattValueChangedHandler);
        handler.* = bindings.GattValueChangedHandler.init(onValueChangedNotification, @ptrCast(sub_ctx));

        var cookie: bindings.EventRegistrationToken = undefined;
        if (char_entry.char.lpVtbl.add_ValueChanged(char_entry.char_obj, handler, &cookie) != bindings.S_OK) {
            dev.allocator.destroy(handler);
            dev.allocator.destroy(sub_ctx);
            return BleError.NotificationFailed;
        }

        // Write CCCD (Notify = 1) to enable hardware notification streaming
        var cccd_op: ?*anyopaque = null;
        if (char_entry.char.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(
            char_entry.char_obj,
            .Notify,
            &cccd_op,
        ) != bindings.S_OK or cccd_op == null) {
            _ = char_entry.char.lpVtbl.remove_ValueChanged(char_entry.char_obj, cookie);
            dev.allocator.destroy(handler);
            dev.allocator.destroy(sub_ctx);
            return BleError.NotificationFailed;
        }

        const cccd_status = winrt.awaitAsync(bindings.GattCommunicationStatus, cccd_op.?, 5000) catch {
            _ = char_entry.char.lpVtbl.remove_ValueChanged(char_entry.char_obj, cookie);
            dev.allocator.destroy(handler);
            dev.allocator.destroy(sub_ctx);
            return BleError.NotificationFailed;
        };

        if (cccd_status != .Success) {
            _ = char_entry.char.lpVtbl.remove_ValueChanged(char_entry.char_obj, cookie);
            dev.allocator.destroy(handler);
            dev.allocator.destroy(sub_ctx);
            if (cccd_status == .AccessDenied) return BleError.AuthenticationFailed;
            return BleError.NotificationFailed;
        }

        try dev.subscriptions.put(char_uuid, .{
            .cookie = cookie,
            .handler = handler,
            .ctx = sub_ctx,
        });
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void {
        _ = ctx;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const dev: *WindowsDevice = @ptrCast(@alignCast(dev_handle));
        const sub = dev.subscriptions.get(char_uuid) orelse return;

        if (dev.characteristics.get(char_uuid)) |char_entry| {
            // Write CCCD (None = 0) to stop hardware stream
            var cccd_op: ?*anyopaque = null;
            if (char_entry.char.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(
                char_entry.char_obj,
                .None,
                &cccd_op,
            ) == bindings.S_OK and cccd_op != null) {
                if (dev.backend.winrt) |*w| {
                    _ = w.awaitAsync(bindings.GattCommunicationStatus, cccd_op.?, 3000) catch {};
                }
            }

            _ = char_entry.char.lpVtbl.remove_ValueChanged(char_entry.char_obj, sub.cookie);
        }

        _ = dev.subscriptions.remove(char_uuid);
        dev.allocator.destroy(sub.handler);
        dev.allocator.destroy(sub.ctx);
    }

    pub fn exchangeMtu(ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) anyerror!u16 {
        _ = ctx;
        _ = dev_handle;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        // On Windows 10/11, WinRT negotiates GATT MTU automatically during L2CAP/ATT connection
        return target_mtu;
    }

    pub fn pairDevice(ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        _ = io_cap;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
    }

    pub fn unpairDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
    }

    pub fn getBondState(ctx: *anyopaque, dev_handle: *anyopaque) types.BondState {
        _ = ctx;
        _ = dev_handle;
        return .bonded;
    }

    pub const vtable: BackendVTable = .{
        .name = "Windows_Native",
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

    pub fn asBackend(self: *WindowsBackend) Backend {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }
};

test "WindowsBackend compilation and instantiation check" {
    var win_backend = WindowsBackend.init();
    defer win_backend.deinit();

    const backend = win_backend.asBackend();
    try std.testing.expectEqualStrings("Windows_Native", backend.getName());

    if (builtin.os.tag == .windows) {
        backend.openAdapter(0) catch |err| {
            if (err == BleError.AdapterNotFound) return;
            return err;
        };
        try std.testing.expect(try backend.isPowered());
        backend.closeAdapter();
    }
}
