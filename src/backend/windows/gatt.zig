//! # WinRT GATT Operations (Discovery, Read, Write, Notify, MTU)
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");
const helpers = @import("helpers.zig");
const device_mod = @import("device.zig");
const core = @import("../../core/mod.zig");

const BleError = types.BleError;
const UUID = types.UUID;
const NotificationCallback = types.NotificationCallback;
const CharacteristicSelector = types.CharacteristicSelector;
const CharacteristicInfo = types.CharacteristicInfo;
const WinCharacteristicSlot = device_mod.WinCharacteristicSlot;
const GUID = bindings.GUID;
const Combase = bindings.Combase;

const log = std.log.scoped(.zig_ble);

pub fn ensureServicesDiscovered(backend: anytype, dev: anytype) BleError!void {
    if (dev.characteristics_len == 0) {
        backend.mutex.unlock();
        const disc_res = discoverServices(backend, dev);
        backend.mutex.lock();
        try disc_res;
    }
}

pub fn discoverServices(backend: anytype, dev: anytype) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    const d3 = dev.ble_device3 orelse return BleError.NotConnected;

    if (dev.characteristics_len > 0) return;

    var svcs_op: ?*bindings.IAsyncOperationGeneric = null;
    const cache_mode: bindings.BluetoothCacheMode = if (backend.use_cached_services) .Cached else .Uncached;
    if (d3.lpVtbl.GetGattServicesWithCacheModeAsync(d3, cache_mode, &svcs_op) < 0 or svcs_op == null) {
        return BleError.GattError;
    }

    const svcs_res_raw = (try helpers.awaitAsync(svcs_op.?, backend.timeouts.discovery_ms)) orelse return BleError.ServiceNotFound;
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

        var svc_guid: GUID = undefined;
        const svc_uuid = if (svc.lpVtbl.get_Uuid(svc, &svc_guid) >= 0) helpers.guidToUuid(svc_guid) else UUID.from16(0);

        var svc3: ?*bindings.IGattDeviceService3 = null;
        if (svc.lpVtbl.QueryInterface(svc, &bindings.IID_IGattDeviceService3, @ptrCast(&svc3)) >= 0 and svc3 != null) {
            const s3 = svc3.?;
            defer _ = s3.lpVtbl.Release(s3);

            // Query negotiated MaxPduSize from IGattSession if available
            var session: ?*bindings.IGattSession = null;
            if (dev.gatt_session == null and s3.lpVtbl.get_Session(s3, &session) >= 0 and session != null) {
                const sess = session.?;
                defer _ = sess.lpVtbl.Release(sess);
                var max_pdu: u16 = 0;
                if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
                    dev.mtu = max_pdu;
                }
            }

            // A service whose characteristics cannot be read (Windows denies access to HID, for
            // example) is skipped with a warning instead of failing the whole connection.
            discoverCharacteristics(backend, dev, s3, svc_uuid, cache_mode) catch |err| switch (err) {
                BleError.PoolExhausted => return err,
                else => log.warn("Skipping characteristics of service {f}: {s}", .{ svc_uuid, @errorName(err) }),
            };
        }
    }
}

fn discoverCharacteristics(backend: anytype, dev: anytype, s3: *bindings.IGattDeviceService3, svc_uuid: UUID, cache_mode: bindings.BluetoothCacheMode) BleError!void {
    var chars_op: ?*bindings.IAsyncOperationGeneric = null;
    if (s3.lpVtbl.GetCharacteristicsWithCacheModeAsync(s3, cache_mode, &chars_op) < 0 or chars_op == null) {
        return BleError.GattError;
    }
    const chars_res_raw = (try helpers.awaitAsync(chars_op.?, backend.timeouts.discovery_ms)) orelse return BleError.GattError;
    const chars_res: *bindings.IGattCharacteristicsResult = @ptrCast(@alignCast(chars_res_raw));
    defer _ = chars_res.lpVtbl.Release(chars_res);

    var c_status: bindings.GattCommunicationStatus = .Unreachable;
    if (chars_res.lpVtbl.get_Status(chars_res, &c_status) < 0) return BleError.GattError;
    switch (c_status) {
        .Success => {},
        .AccessDenied => return BleError.PermissionDenied,
        .Unreachable => return BleError.NotConnected,
        else => return BleError.GattError,
    }

    var chars_vec: ?*bindings.IVectorViewGeneric = null;
    if (chars_res.lpVtbl.get_Characteristics(chars_res, &chars_vec) < 0 or chars_vec == null) {
        return BleError.GattError;
    }
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
                try dev.addCharacteristic(svc_uuid, helpers.guidToUuid(c_guid), ch);
            } else {
                _ = ch.lpVtbl.Release(ch);
            }
        }
    }
}

pub fn readCharacteristic(backend: anytype, dev: anytype, char: CharacteristicSelector, buf: []u8) BleError!usize {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    try ensureServicesDiscovered(backend, dev);

    const slot = dev.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
    const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

    if (backend.pcap_hook) |hook| {
        const req_pdu = [_]u8{ @intFromEnum(core.AttOpcode.read_req), 0x01, 0x00 };
        hook.emit(.host_to_controller, &req_pdu);
    }

    var read_op: ?*bindings.IAsyncOperationGeneric = null;
    if (ch.lpVtbl.ReadValueWithCacheModeAsync(ch, .Uncached, &read_op) < 0 or read_op == null) {
        return BleError.ReadFailed;
    }

    const res_raw = (try helpers.awaitAsync(read_op.?, backend.timeouts.read_ms)) orelse return BleError.ReadFailed;
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

    const n = try helpers.readIBuffer(b, buf);
    if (backend.pcap_hook) |hook| {
        var rsp_pdu: [517]u8 = undefined;
        rsp_pdu[0] = @intFromEnum(core.AttOpcode.read_rsp);
        const copy_len = @min(rsp_pdu.len - 1, n);
        @memcpy(rsp_pdu[1 .. 1 + copy_len], buf[0..copy_len]);
        hook.emit(.controller_to_host, rsp_pdu[0 .. 1 + copy_len]);
    }
    return n;
}

pub fn writeCharacteristic(backend: anytype, dev: anytype, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    try ensureServicesDiscovered(backend, dev);

    const slot = dev.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
    const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

    const ibuf = try helpers.createIBuffer(data);
    defer _ = ibuf.lpVtbl.Release(ibuf);

    if (backend.pcap_hook) |hook| {
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

    const res_raw = try helpers.awaitAsync(write_op.?, backend.timeouts.write_ms);
    const status_val: i32 = @intCast(@intFromPtr(res_raw));
    if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
        return if (status_val == @intFromEnum(bindings.GattCommunicationStatus.AccessDenied))
            BleError.PermissionDenied
        else
            BleError.WriteFailed;
    }

    if (with_response) {
        if (backend.pcap_hook) |hook| {
            const rsp_pdu = [_]u8{@intFromEnum(core.AttOpcode.write_rsp)};
            hook.emit(.controller_to_host, &rsp_pdu);
        }
    }
}

pub fn handleCharacteristicValueChanged(slot: *WinCharacteristicSlot, dev: anytype, args: *bindings.IGattValueChangedEventArgs) void {
    const backend = dev.parent_backend orelse return;
    if (backend.is_closed.load(.acquire)) return;
    // Runs on a WinRT thread: copy the callback under `state_mutex`, call it without the lock.
    const cb, const user_data = blk: {
        backend.state_mutex.lock();
        defer backend.state_mutex.unlock();
        break :blk .{ slot.notify_cb orelse return, slot.notify_user_data };
    };

    var ibuf: ?*bindings.IBuffer = null;
    if (args.lpVtbl.get_CharacteristicValue(args, &ibuf) < 0 or ibuf == null) return;
    const b = ibuf.?;
    defer _ = b.lpVtbl.Release(b);

    var stack_buf: [512]u8 = undefined;
    const n = helpers.readIBuffer(b, &stack_buf) catch return;

    {
        if (backend.pcap_hook) |hook| {
            var pdu_buf: [517]u8 = undefined;
            pdu_buf[0] = @intFromEnum(core.AttOpcode.handle_value_ntf);
            pdu_buf[1] = 0x01;
            pdu_buf[2] = 0x00;
            const copy_len = @min(pdu_buf.len - 3, n);
            @memcpy(pdu_buf[3 .. 3 + copy_len], stack_buf[0..copy_len]);
            hook.emit(.controller_to_host, pdu_buf[0 .. 3 + copy_len]);
        }
    }

    cb(slot.uuid, stack_buf[0..n], user_data);
}

pub fn subscribeNotifications(
    backend: anytype,
    dev: anytype,
    char: CharacteristicSelector,
    cb: NotificationCallback,
    user_data: ?*anyopaque,
    value_changed_fn: *const fn (ctx: *anyopaque, args: *bindings.IGattValueChangedEventArgs) callconv(.c) void,
) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    try ensureServicesDiscovered(backend, dev);

    const slot = dev.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
    const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

    {
        backend.state_mutex.lock();
        defer backend.state_mutex.unlock();
        slot.notify_cb = cb;
        slot.notify_user_data = user_data;
    }

    slot.value_changed_handler = .{
        .char_ctx = @ptrCast(slot),
        .on_changed = value_changed_fn,
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

    const res_raw = try helpers.awaitAsync(cccd_op.?, backend.timeouts.write_ms);
    const status_val: i32 = @intCast(@intFromPtr(res_raw));
    if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
        return BleError.NotificationFailed;
    }
}

pub fn unsubscribeNotifications(backend: anytype, dev: anytype, char: CharacteristicSelector) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    const slot = dev.findCharacteristic(char) orelse return;
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

    {
        backend.state_mutex.lock();
        defer backend.state_mutex.unlock();
        slot.notify_cb = null;
        slot.notify_user_data = null;
    }

    var cccd_op: ?*bindings.IAsyncOperationGeneric = null;
    if (ch.lpVtbl.WriteClientCharacteristicConfigurationDescriptorAsync(ch, .None, &cccd_op) >= 0 and cccd_op != null) {
        const res_raw = helpers.awaitAsync(cccd_op.?, backend.timeouts.write_ms) catch |err| {
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

/// Returns the first descriptor `descriptor` of the selected characteristic; the caller releases it.
fn openDescriptor(backend: anytype, dev: anytype, char: CharacteristicSelector, descriptor: UUID) BleError!*bindings.IGattDescriptor {
    try ensureServicesDiscovered(backend, dev);
    const slot = dev.findCharacteristic(char) orelse return BleError.CharacteristicNotFound;
    const ch = slot.char_ptr orelse return BleError.CharacteristicNotFound;

    var ch3: ?*bindings.IGattCharacteristic3 = null;
    if (ch.lpVtbl.QueryInterface(ch, &bindings.IID_IGattCharacteristic3, @ptrCast(&ch3)) < 0) return BleError.NotSupported;
    const c3 = ch3 orelse return BleError.NotSupported;
    defer _ = c3.lpVtbl.Release(c3);

    const cache_mode: bindings.BluetoothCacheMode = if (backend.use_cached_services) .Cached else .Uncached;
    var op: ?*bindings.IAsyncOperationGeneric = null;
    if (c3.lpVtbl.GetDescriptorsForUuidWithCacheModeAsync(c3, helpers.uuidToGuid(descriptor), cache_mode, &op) < 0 or op == null) {
        return BleError.GattError;
    }
    const res_raw = (try helpers.awaitAsync(op.?, backend.timeouts.discovery_ms)) orelse return BleError.DescriptorNotFound;
    const res: *bindings.IGattDescriptorsResult = @ptrCast(@alignCast(res_raw));
    defer _ = res.lpVtbl.Release(res);

    var status: bindings.GattCommunicationStatus = .Unreachable;
    if (res.lpVtbl.get_Status(res, &status) < 0) return BleError.GattError;
    switch (status) {
        .Success => {},
        .AccessDenied => return BleError.PermissionDenied,
        .Unreachable => return BleError.NotConnected,
        else => return BleError.GattError,
    }

    var vec: ?*bindings.IVectorViewGeneric = null;
    if (res.lpVtbl.get_Descriptors(res, &vec) < 0) return BleError.GattError;
    const v = vec orelse return BleError.DescriptorNotFound;
    defer _ = v.lpVtbl.Release(v);
    var count: u32 = 0;
    if (v.lpVtbl.get_Size(v, &count) < 0 or count == 0) return BleError.DescriptorNotFound;
    var item: ?*anyopaque = null;
    if (v.lpVtbl.GetAt(v, 0, &item) < 0) return BleError.GattError;
    return @ptrCast(@alignCast(item orelse return BleError.DescriptorNotFound));
}

pub fn readDescriptor(backend: anytype, dev: anytype, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    const desc = try openDescriptor(backend, dev, char, descriptor);
    defer _ = desc.lpVtbl.Release(desc);

    var op: ?*bindings.IAsyncOperationGeneric = null;
    if (desc.lpVtbl.ReadValueWithCacheModeAsync(desc, .Uncached, &op) < 0 or op == null) return BleError.ReadFailed;
    const res_raw = (try helpers.awaitAsync(op.?, backend.timeouts.read_ms)) orelse return BleError.ReadFailed;
    const read_res: *bindings.IGattReadResult = @ptrCast(@alignCast(res_raw));
    defer _ = read_res.lpVtbl.Release(read_res);

    var status: bindings.GattCommunicationStatus = .Unreachable;
    if (read_res.lpVtbl.get_Status(read_res, &status) < 0 or status != .Success) {
        return if (status == .AccessDenied) BleError.PermissionDenied else BleError.ReadFailed;
    }
    var ibuf: ?*bindings.IBuffer = null;
    if (read_res.lpVtbl.get_Value(read_res, &ibuf) < 0) return BleError.ReadFailed;
    const b = ibuf orelse return BleError.ReadFailed;
    defer _ = b.lpVtbl.Release(b);
    return helpers.readIBuffer(b, buf);
}

pub fn writeDescriptor(backend: anytype, dev: anytype, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    const desc = try openDescriptor(backend, dev, char, descriptor);
    defer _ = desc.lpVtbl.Release(desc);

    const ibuf = try helpers.createIBuffer(data);
    defer _ = ibuf.lpVtbl.Release(ibuf);
    var op: ?*bindings.IAsyncOperationGeneric = null;
    if (desc.lpVtbl.WriteValueAsync(desc, ibuf, &op) < 0 or op == null) return BleError.WriteFailed;
    const res_raw = try helpers.awaitAsync(op.?, backend.timeouts.write_ms);
    const status_val: i32 = @intCast(@intFromPtr(res_raw));
    if (status_val != @intFromEnum(bindings.GattCommunicationStatus.Success)) {
        return if (status_val == @intFromEnum(bindings.GattCommunicationStatus.AccessDenied))
            BleError.PermissionDenied
        else
            BleError.WriteFailed;
    }
}

pub fn getCharacteristics(backend: anytype, dev: anytype, out: []CharacteristicInfo) BleError!usize {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    try ensureServicesDiscovered(backend, dev);
    return CharacteristicInfo.list(dev.characteristics[0..dev.characteristics_len], out);
}

pub fn exchangeMtu(backend: anytype, dev: anytype, target_mtu: u16) BleError!u16 {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    _ = target_mtu;
    if (backend.is_closed.load(.acquire)) return BleError.InvalidState;
    if (!dev.is_connected.load(.acquire)) return BleError.NotConnected;

    // 1. The session opened at connect time
    if (dev.gatt_session) |sess| {
        var max_pdu: u16 = 0;
        if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
            dev.mtu = max_pdu;
            return max_pdu;
        }
    }

    // 2. Query IGattSession from any discovered IGattDeviceService3
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

    // 3. Fallback: open a session now (it is kept for later calls and released on disconnect)
    if (dev.gatt_session == null) {
        if (dev.ble_device) |ble_dev| {
            dev.gatt_session = try openGattSession(ble_dev, backend.timeouts.mtu_exchange_ms);
            if (dev.gatt_session) |sess| {
                var max_pdu: u16 = 0;
                if (sess.lpVtbl.get_MaxPduSize(sess, &max_pdu) >= 0 and max_pdu >= 23) {
                    dev.mtu = max_pdu;
                    return max_pdu;
                }
            }
        }
    }

    return BleError.MtuExchangeFailed;
}

/// Opens the device's `GattSession` with `MaintainConnection = true`. Windows has no explicit
/// connect: the link belongs to the GATT sessions that want it, and without this flag Windows
/// drops it after a few idle seconds. Returns null if the device offers no session.
pub fn openGattSession(ble_dev: *bindings.IBluetoothLEDevice, timeout_ms: u32) BleError!?*bindings.IGattSession {
    if (builtin.os.tag != .windows) return BleError.NotSupported;

    var dev4: ?*bindings.IBluetoothLEDevice4 = null;
    if (ble_dev.lpVtbl.QueryInterface(ble_dev, &bindings.IID_IBluetoothLEDevice4, @ptrCast(&dev4)) < 0) return null;
    const d4 = dev4 orelse return null;
    defer _ = d4.lpVtbl.Release(d4);

    var bt_dev_id: ?*anyopaque = null;
    if (d4.lpVtbl.get_BluetoothDeviceId(d4, &bt_dev_id) < 0) return null;
    const dev_id = bt_dev_id orelse return null;
    const dev_id_unk: *bindings.IUnknown = @ptrCast(@alignCast(dev_id));
    defer _ = dev_id_unk.release();

    const sess_hstr = try helpers.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattSession");
    defer helpers.deleteHString(sess_hstr);
    var sess_statics: ?*bindings.IGattSessionStatics = null;
    if (Combase.RoGetActivationFactory(sess_hstr, &bindings.IID_IGattSessionStatics, @ptrCast(&sess_statics)) < 0) return null;
    const st = sess_statics orelse return null;
    defer _ = st.lpVtbl.Release(st);

    var sess_op: ?*bindings.IAsyncOperationGeneric = null;
    if (st.lpVtbl.FromDeviceIdAsync(st, dev_id, &sess_op) < 0 or sess_op == null) return null;
    const sess_raw = (try helpers.awaitAsync(sess_op.?, timeout_ms)) orelse return null;
    const sess: *bindings.IGattSession = @ptrCast(@alignCast(sess_raw));

    var can_maintain: u8 = 0;
    if (sess.lpVtbl.get_CanMaintainConnection(sess, &can_maintain) >= 0 and can_maintain != 0) {
        if (sess.lpVtbl.put_MaintainConnection(sess, 1) < 0) {
            log.warn("WinRT GattSession.MaintainConnection could not be set; Windows may drop an idle connection", .{});
        }
    } else {
        log.warn("WinRT GattSession cannot maintain the connection; Windows may drop an idle connection", .{});
    }
    return sess;
}
