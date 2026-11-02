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

/// Advertisement fields read from one WinRT report. Each field is optional because a scan
/// response or a short advertisement carries only some of them.
const ReportData = struct {
    address: types.Address,
    rssi: i16,
    address_type: ?types.AddressType = null,
    tx_power: ?i16 = null,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    uuids: [8]types.UUID = undefined,
    uuids_len: usize = 0,
    company_id: ?u16 = null,
    mfg_buf: [64]u8 = undefined,
    mfg_len: usize = 0,
    service_data_uuid: ?types.UUID = null,
    service_data_buf: [64]u8 = undefined,
    service_data_len: usize = 0,
};

/// Runs on a WinRT thread. Reads the report without locks, merges it into the scan cache
/// under `state_mutex` (WinRT delivers advertisement and scan response as separate reports),
/// and calls the scan callback after releasing the lock.
pub fn handleWatcherReceived(backend: anytype, args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs) void {
    if (backend.is_closed.load(.acquire)) return;

    var addr64: u64 = 0;
    if (args.lpVtbl.get_BluetoothAddress(args, &addr64) < 0) return;
    var rssi: i16 = -127;
    _ = args.lpVtbl.get_RawSignalStrengthInDBm(args, &rssi);

    var report = ReportData{ .address = helpers.u64ToAddress(addr64), .rssi = rssi };
    readReportDetails(args, &report);
    readAdvertisement(args, &report);

    const cb, const user_data, const device = blk: {
        backend.state_mutex.lock();
        defer backend.state_mutex.unlock();
        const cb = backend.active_scan_cb orelse return;

        if (backend.findDeviceByAddress(report.address)) |existing_dev| {
            existing_dev.rssi = rssi;
        }

        const dev = backend.scan_cache.get(report.address);
        dev.rssi = report.rssi;
        if (report.tx_power) |tx| dev.tx_power = tx;
        if (report.address_type) |t| dev.address_type = t;
        if (report.tx_power) |t| dev.tx_power = t;
        if (report.name_len > 0) dev.setName(report.name_buf[0..report.name_len]);
        if (report.uuids_len > 0) {
            dev.service_uuids_len = 0;
            for (report.uuids[0..report.uuids_len]) |u| _ = dev.addServiceUuid(u);
        }
        if (report.company_id) |company| dev.setManufacturerData(company, report.mfg_buf[0..report.mfg_len]);
        if (report.service_data_uuid) |s_uuid| {
            dev.setServiceData(s_uuid, report.service_data_buf[0..report.service_data_len]);
        }

        if (!backend.scan_filter.matches(dev)) return;
        break :blk .{ cb, backend.active_scan_user_data, dev.* };
    };

    if (!backend.is_closed.load(.acquire)) {
        cb(&device, user_data);
    }
}

/// Address type and TX power (Windows 10 1803+, `IBluetoothLEAdvertisementReceivedEventArgs2`).
fn readReportDetails(args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs, report: *ReportData) void {
    var args2: ?*bindings.IBluetoothLEAdvertisementReceivedEventArgs2 = null;
    if (args.lpVtbl.QueryInterface(args, &bindings.IID_IBluetoothLEAdvertisementReceivedEventArgs2, @ptrCast(&args2)) < 0) return;
    const a2 = args2 orelse return;
    defer _ = a2.lpVtbl.Release(a2);

    var addr_type: i32 = 0;
    if (a2.lpVtbl.get_BluetoothAddressType(a2, &addr_type) >= 0) {
        report.address_type = switch (addr_type) {
            @intFromEnum(bindings.BluetoothAddressType.Public) => .public,
            @intFromEnum(bindings.BluetoothAddressType.Random) => .random,
            else => null,
        };
    }

    var tx_ref: ?*anyopaque = null;
    if (a2.lpVtbl.get_TransmitPowerLevelInDBm(a2, &tx_ref) >= 0) {
        const ref_unk: *bindings.IUnknown = @ptrCast(@alignCast(tx_ref orelse return));
        defer _ = ref_unk.release();
        var prop: ?*bindings.IPropertyValue = null;
        if (ref_unk.queryInterface(&bindings.IID_IPropertyValue, @ptrCast(&prop)) >= 0) {
            const pv = prop orelse return;
            defer _ = pv.lpVtbl.Release(pv);
            var tx: i16 = 0;
            if (pv.lpVtbl.GetInt16(pv, &tx) >= 0) report.tx_power = tx;
        }
    }
}

/// Local name, service UUIDs and the first manufacturer data entry.
fn readAdvertisement(args: *bindings.IBluetoothLEAdvertisementReceivedEventArgs, report: *ReportData) void {
    var adv_ptr: ?*bindings.IBluetoothLEAdvertisement = null;
    if (args.lpVtbl.get_Advertisement(args, &adv_ptr) < 0) return;
    const adv = adv_ptr orelse return;
    defer _ = adv.lpVtbl.Release(adv);

    var name_hstr: HSTRING = null;
    if (adv.lpVtbl.get_LocalName(adv, &name_hstr) >= 0 and name_hstr != null) {
        defer helpers.deleteHString(name_hstr);
        report.name_len = helpers.hstringToUtf8(name_hstr, &report.name_buf);
    }

    var uuids_vec: ?*bindings.IVectorViewGuid = null;
    if (adv.lpVtbl.get_ServiceUuids(adv, @ptrCast(&uuids_vec)) >= 0) {
        if (uuids_vec) |uv| {
            defer _ = uv.lpVtbl.Release(uv);
            var count: u32 = 0;
            if (uv.lpVtbl.get_Size(uv, &count) >= 0) {
                var i: u32 = 0;
                while (i < count and report.uuids_len < report.uuids.len) : (i += 1) {
                    var g: GUID = undefined;
                    if (uv.lpVtbl.GetAt(uv, i, &g) >= 0) {
                        report.uuids[report.uuids_len] = helpers.guidToUuid(g);
                        report.uuids_len += 1;
                    }
                }
            }
        }
    }

    readManufacturerData(adv, report);
    readDataSections(adv, report);
}

/// The first manufacturer data entry, if any.
fn readManufacturerData(adv: *bindings.IBluetoothLEAdvertisement, report: *ReportData) void {
    var mfg_vec: ?*bindings.IVectorPtr = null;
    if (adv.lpVtbl.get_ManufacturerData(adv, &mfg_vec) < 0) return;
    const mv = mfg_vec orelse return;
    defer _ = mv.lpVtbl.Release(mv);
    var count: u32 = 0;
    if (mv.lpVtbl.get_Size(mv, &count) < 0 or count == 0) return;
    var item: ?*anyopaque = null;
    if (mv.lpVtbl.GetAt(mv, 0, &item) < 0) return;
    const md: *bindings.IBluetoothLEManufacturerData = @ptrCast(@alignCast(item orelse return));
    defer _ = md.lpVtbl.Release(md);

    var company: u16 = 0;
    if (md.lpVtbl.get_CompanyId(md, &company) < 0) return;
    var data: ?*bindings.IBuffer = null;
    if (md.lpVtbl.get_Data(md, &data) < 0) return;
    const buf = data orelse return;
    defer _ = buf.lpVtbl.Release(buf);
    // Longer payloads are truncated to the size `DiscoveredDevice` keeps.
    report.mfg_len = helpers.readIBuffer(buf, &report.mfg_buf) catch return;
    report.company_id = company;
}

/// TX power, if `IBluetoothLEAdvertisementReceivedEventArgs2` did not report it, and the first
/// service data section.
fn readDataSections(adv: *bindings.IBluetoothLEAdvertisement, report: *ReportData) void {
    var sections_vec: ?*bindings.IVectorPtr = null;
    if (adv.lpVtbl.get_DataSections(adv, &sections_vec) < 0) return;
    const sv = sections_vec orelse return;
    defer _ = sv.lpVtbl.Release(sv);
    var count: u32 = 0;
    if (sv.lpVtbl.get_Size(sv, &count) < 0) return;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var item: ?*anyopaque = null;
        if (sv.lpVtbl.GetAt(sv, i, &item) < 0) continue;
        const ds: *bindings.IBluetoothLEAdvertisementDataSection = @ptrCast(@alignCast(item orelse continue));
        defer _ = ds.lpVtbl.Release(ds);

        var data_type: u8 = 0;
        if (ds.lpVtbl.get_DataType(ds, &data_type) < 0) continue;
        var data_buf_ptr: ?*bindings.IBuffer = null;
        if (ds.lpVtbl.get_Data(ds, &data_buf_ptr) < 0) continue;
        const data_buf = data_buf_ptr orelse continue;
        defer _ = data_buf.lpVtbl.Release(data_buf);

        var temp_raw: [255]u8 = undefined;
        const raw_len = helpers.readIBuffer(data_buf, &temp_raw) catch continue;
        const raw = temp_raw[0..raw_len];

        if (data_type == 0x0A and raw.len >= 1) {
            if (report.tx_power == null) report.tx_power = @as(i8, @bitCast(raw[0]));
            continue;
        }
        if (report.service_data_uuid != null) continue;
        const uuid: types.UUID, const uuid_len: usize = switch (data_type) {
            0x16 => if (raw.len >= 2) .{ .from16(std.mem.readInt(u16, raw[0..2], .little)), 2 } else continue,
            0x20 => if (raw.len >= 4) .{ .from32(std.mem.readInt(u32, raw[0..4], .little)), 4 } else continue,
            0x21 => if (raw.len >= 16) .{ .fromLittleEndian(raw[0..16].*), 16 } else continue,
            else => continue,
        };
        const payload = raw[uuid_len..];
        const copy_len = @min(report.service_data_buf.len, payload.len);
        @memcpy(report.service_data_buf[0..copy_len], payload[0..copy_len]);
        report.service_data_len = copy_len;
        report.service_data_uuid = uuid;
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

    {
        backend.state_mutex.lock();
        defer backend.state_mutex.unlock();
        backend.scan_filter = filter;
        backend.active_scan_cb = cb;
        backend.active_scan_user_data = user_data;
        backend.scan_cache.reset();
    }

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
    if (add_hr < 0) {
        log.err("WinRT add_Received returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(add_hr))});
        return BleError.IoError;
    }

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
    backend.state_mutex.lock();
    defer backend.state_mutex.unlock();
    backend.active_scan_cb = null;
    backend.active_scan_user_data = null;
}
