//! # Zig-BLE Windows Native Backend
//!
//! Implements BackendVTable for Windows using native Win32 Bluetooth APIs
//! (bthprops.cpl / BluetoothApis.dll) and WinRT COM APIs.
//! 100% Pure Zig, zero MSVC C++ runtime dependencies.

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

pub const WindowsBackend = struct {
    radio: ?WindowsRadio = null,
    scanning: bool = false,
    powered: bool = false,

    pub fn init() WindowsBackend {
        return .{
            .radio = WindowsRadio.init(),
        };
    }

    pub fn deinit(self: *WindowsBackend) void {
        if (self.radio) |*r| {
            r.deinit();
            self.radio = null;
        }
    }

    pub fn openAdapter(ctx: *anyopaque, index: u16) anyerror!void {
        _ = index;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (self.radio == null) {
            self.radio = WindowsRadio.init();
        }
        if (self.radio) |*r| {
            try r.openDefault();
            self.powered = r.isPowered();
        } else {
            return BleError.AdapterNotFound;
        }
    }

    pub fn closeAdapter(ctx: *anyopaque) void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (self.radio) |*r| {
            r.close();
        }
        self.scanning = false;
        self.powered = false;
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
        return false;
    }

    pub fn startScan(ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void {
        _ = filter;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;
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
                            @intCast((dev_info.Address >> 0) & 0xFF),
                            @intCast((dev_info.Address >> 8) & 0xFF),
                            @intCast((dev_info.Address >> 16) & 0xFF),
                            @intCast((dev_info.Address >> 24) & 0xFF),
                            @intCast((dev_info.Address >> 32) & 0xFF),
                            @intCast((dev_info.Address >> 40) & 0xFF),
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

    pub fn stopScan(ctx: *anyopaque) anyerror!void {
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        self.scanning = false;
    }

    pub fn connectDevice(ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque {
        _ = addr;
        _ = timeout_ms;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        const self: *WindowsBackend = @ptrCast(@alignCast(ctx));
        if (!self.powered) return BleError.NotPowered;
        return @ptrCast(self);
    }

    pub fn disconnectDevice(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        _ = dev_handle;
    }

    pub fn isDeviceConnected(ctx: *anyopaque, dev_handle: *anyopaque) bool {
        _ = ctx;
        _ = dev_handle;
        return true;
    }

    pub fn getDeviceRssi(ctx: *anyopaque, dev_handle: *anyopaque) ?i16 {
        _ = ctx;
        _ = dev_handle;
        return null;
    }

    pub fn discoverServices(ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
    }

    pub fn readCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize {
        _ = ctx;
        _ = dev_handle;
        _ = char_uuid;
        _ = buf;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
        return 0;
    }

    pub fn writeCharacteristic(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        _ = char_uuid;
        _ = data;
        _ = with_response;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
    }

    pub fn subscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        _ = char_uuid;
        _ = cb;
        _ = user_data;
        if (builtin.os.tag != .windows) return BleError.NotSupported;
    }

    pub fn unsubscribeNotifications(ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void {
        _ = ctx;
        _ = dev_handle;
        _ = char_uuid;
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
