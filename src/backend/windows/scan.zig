//! # WinRT Advertisement Watcher & LE Scanning
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");
const helpers = @import("helpers.zig");

const BleError = types.BleError;
const DiscoveredDevice = types.DiscoveredDevice;
const ScanFilter = types.ScanFilter;
const ScanCallback = types.ScanCallback;
const GUID = bindings.GUID;
const HSTRING = bindings.HSTRING;
const Combase = bindings.Combase;

const log = std.log.scoped(.zig_ble);

pub fn handleWatcherReceived(backend: anytype, args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs) void {
    if (backend.is_closed.load(.acquire)) return;
    const cb = backend.active_scan_cb orelse return;

    var addr64: u64 = 0;
    if (args.lpVtbl.get_BluetoothAddress(args, &addr64) < 0) return;

    var rssi: i16 = -127;
    _ = args.lpVtbl.get_RawSignalStrengthInDBm(args, &rssi);

    if (backend.scan_filter.min_rssi) |min_r| {
        if (rssi < min_r) return;
    }

    var discovered = DiscoveredDevice{
        .address = helpers.u64ToAddress(addr64),
        .rssi = rssi,
    };

    if (backend.findDeviceByAddress(discovered.address)) |existing_dev| {
        existing_dev.rssi = rssi;
    }

    var adv_ptr: ?*bindings.IBluetoothLEAdvertisement = null;
    if (args.lpVtbl.get_Advertisement(args, &adv_ptr) >= 0) {
        if (adv_ptr) |adv| {
            defer _ = adv.lpVtbl.Release(adv);

            var name_hstr: HSTRING = null;
            if (adv.lpVtbl.get_LocalName(adv, &name_hstr) >= 0 and name_hstr != null) {
                defer helpers.deleteHString(name_hstr);
                var name_buf: [64]u8 = undefined;
                const name_len = helpers.hstringToUtf8(name_hstr, &name_buf);
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
                                _ = discovered.addServiceUuid(helpers.guidToUuid(g));
                            }
                        }
                    }
                }
            }
        }
    }

    if (backend.scan_filter.service_uuids.len > 0) {
        var matched = false;
        for (backend.scan_filter.service_uuids) |req_uuid| {
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

    if (!backend.is_closed.load(.acquire)) {
        cb(&discovered, backend.active_scan_user_data);
    }
}

pub fn startScan(
    backend: anytype,
    filter: ScanFilter,
    cb: ScanCallback,
    user_data: ?*anyopaque,
    watcher_fn: *const fn (ctx: *anyopaque, args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs) callconv(.c) void,
) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    try backend.ensureWinRtInitialized();

    if (backend.scanning) {
        stopScanInternal(backend);
    }

    backend.scan_filter = filter;
    backend.active_scan_cb = cb;
    backend.active_scan_user_data = user_data;

    if (backend.watcher == null) {
        const class_hstr = try helpers.createHStringComptime("Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher");
        defer helpers.deleteHString(class_hstr);

        var inspectable: ?*bindings.IInspectable = null;
        const hr = Combase.RoActivateInstance(class_hstr, &inspectable);
        if (hr < 0 or inspectable == null) return BleError.AdapterNotFound;
        const insp = inspectable.?;
        defer _ = insp.release();

        var watcher_ptr: ?*bindings.IBluetoothLEAdvertisementWatcher = null;
        if (insp.queryInterface(&bindings.IID_IBluetoothLEAdvertisementWatcher, @ptrCast(&watcher_ptr)) < 0 or watcher_ptr == null) {
            return BleError.AdapterNotFound;
        }
        backend.watcher = watcher_ptr;
    }

    const w = backend.watcher.?;
    const mode: bindings.BluetoothLEScanningMode = if (filter.active) .Active else .Passive;
    _ = w.lpVtbl.put_ScanningMode(w, mode);

    backend.watcher_handler = .{
        .backend_ctx = @ptrCast(backend),
        .on_received = watcher_fn,
    };

    const add_hr = w.lpVtbl.add_Received(w, @ptrCast(&backend.watcher_handler), &backend.watcher_token);
    if (add_hr < 0) return BleError.IoError;

    const start_hr = w.lpVtbl.Start(w);
    if (start_hr < 0) {
        backend.watcher_handler.deactivate();
        _ = w.lpVtbl.remove_Received(w, backend.watcher_token);
        backend.watcher_token = 0;
        return BleError.NotPowered;
    }

    backend.scanning = true;
}

pub fn stopScanInternal(backend: anytype) void {
    if (builtin.os.tag != .windows) return;
    backend.watcher_handler.deactivate();
    if (backend.watcher) |w| {
        if (backend.scanning) {
            const stop_hr = w.lpVtbl.Stop(w);
            if (stop_hr < 0) {
                log.warn("WinRT BluetoothLEAdvertisementWatcher.Stop returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(stop_hr))});
            }
            if (backend.watcher_token != 0) {
                const rem_hr = w.lpVtbl.remove_Received(w, backend.watcher_token);
                if (rem_hr < 0) {
                    log.warn("WinRT remove_Received returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(rem_hr))});
                }
                backend.watcher_token = 0;
            }
        }
        _ = w.lpVtbl.Release(w);
        backend.watcher = null;
    }
    backend.scanning = false;
    backend.active_scan_cb = null;
    backend.active_scan_user_data = null;
}
