//! # WinRT GATT Server Provider & Advertising Engine
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const types_mod = @import("types.zig");

const UUID = core.UUID;
const ServerCharacteristic = types_mod.ServerCharacteristic;
const win_bindings = if (builtin.os.tag == .windows) @import("../backend/windows/bindings.zig") else struct {};
const win_mod = if (builtin.os.tag == .windows) @import("../backend/windows/mod.zig") else struct {};

const log = std.log.scoped(.zig_ble);

pub fn onWinRtReadRequested(char_ctx: *anyopaque, args: *win_bindings.IGattReadRequestedEventArgs) callconv(.c) void {
    if (builtin.os.tag != .windows) return;
    const ch: *ServerCharacteristic = @ptrCast(@alignCast(char_ctx));

    var deferral: ?*win_bindings.IDeferral = null;
    _ = args.lpVtbl.GetDeferral(args, &deferral);
    defer if (deferral) |d| {
        _ = d.lpVtbl.Complete(d);
        _ = d.lpVtbl.Release(d);
    };

    var req_op: ?*win_bindings.IAsyncOperationGeneric = null;
    if (args.lpVtbl.GetRequestAsync(args, &req_op) < 0 or req_op == null) return;

    const req_raw = (win_mod.awaitAsync(req_op.?, 5000) catch null) orelse return;
    const req: *win_bindings.IGattReadRequest = @ptrCast(@alignCast(req_raw));
    defer _ = req.lpVtbl.Release(req);

    const val = if (ch.read_handler) |rf| rf(ch, ch.user_data) else ch.getValue();
    var offset: u32 = 0;
    _ = req.lpVtbl.get_Offset(req, &offset);
    const slice = if (offset < val.len) val[offset..] else &[_]u8{};

    if (win_mod.createIBuffer(slice)) |ibuf| {
        defer _ = ibuf.lpVtbl.Release(ibuf);
        _ = req.lpVtbl.RespondWithValue(req, ibuf);
    } else |_| {
        _ = req.lpVtbl.RespondWithProtocolError(req, 0x06); // Request Not Supported / Read Error
    }
}

pub fn onWinRtWriteRequested(char_ctx: *anyopaque, args: *win_bindings.IGattWriteRequestedEventArgs) callconv(.c) void {
    if (builtin.os.tag != .windows) return;
    const ch: *ServerCharacteristic = @ptrCast(@alignCast(char_ctx));

    var deferral: ?*win_bindings.IDeferral = null;
    _ = args.lpVtbl.GetDeferral(args, &deferral);
    defer if (deferral) |d| {
        _ = d.lpVtbl.Complete(d);
        _ = d.lpVtbl.Release(d);
    };

    var req_op: ?*win_bindings.IAsyncOperationGeneric = null;
    if (args.lpVtbl.GetRequestAsync(args, &req_op) < 0 or req_op == null) return;

    const req_raw = (win_mod.awaitAsync(req_op.?, 5000) catch null) orelse return;
    const req: *win_bindings.IGattWriteRequest = @ptrCast(@alignCast(req_raw));
    defer _ = req.lpVtbl.Release(req);

    var ibuf: ?*win_bindings.IBuffer = null;
    if (req.lpVtbl.get_Value(req, &ibuf) >= 0 and ibuf != null) {
        const b = ibuf.?;
        defer _ = b.lpVtbl.Release(b);

        var data_buf: [512]u8 = undefined;
        if (win_mod.readIBuffer(b, &data_buf)) |n| {
            ch.setValue(data_buf[0..n]);
            if (ch.write_handler) |wf| {
                wf(ch, data_buf[0..n], ch.user_data);
            }
        } else |_| {}
    }

    var opt: win_bindings.GattWriteOption = .WriteWithResponse;
    _ = req.lpVtbl.get_Option(req, &opt);
    if (opt == .WriteWithResponse) {
        _ = req.lpVtbl.Respond(req);
    }
}

pub fn registerWindows(app: anytype) !void {
    if (builtin.os.tag != .windows) return error.NotSupported;
    if (app.is_registered) return;

    const hr_init = win_bindings.Combase.RoInitialize(win_bindings.RO_INIT_MULTITHREADED);
    if (hr_init < 0 and hr_init != win_bindings.RPC_E_CHANGED_MODE) {
        return error.GattApplicationRegistrationFailed;
    }

    const sp_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider");
    defer win_mod.deleteHString(sp_class);

    var sp_statics: ?*win_bindings.IGattServiceProviderStatics = null;
    if (win_bindings.Combase.RoGetActivationFactory(sp_class, &win_bindings.IID_IGattServiceProviderStatics, @ptrCast(&sp_statics)) < 0 or sp_statics == null) {
        return error.GattApplicationRegistrationFailed;
    }
    const statics = sp_statics.?;
    defer _ = statics.lpVtbl.Release(statics);

    errdefer {
        for (app.services[0..app.service_count]) |*s| {
            s.releaseWindows();
        }
    }

    for (app.services[0..app.service_count]) |*s| {
        var create_op: ?*win_bindings.IAsyncOperationGeneric = null;
        if (statics.lpVtbl.CreateAsync(statics, win_mod.uuidToGuid(s.uuid), &create_op) < 0 or create_op == null) {
            return error.GattApplicationRegistrationFailed;
        }

        const sp_res_raw = (try win_mod.awaitAsync(create_op.?, 10_000)) orelse return error.GattApplicationRegistrationFailed;
        const sp_res: *win_bindings.IGattServiceProviderResult = @ptrCast(@alignCast(sp_res_raw));
        defer _ = sp_res.lpVtbl.Release(sp_res);

        var bt_err: win_bindings.BluetoothError = .OtherError;
        if (sp_res.lpVtbl.get_Error(sp_res, &bt_err) < 0 or bt_err != .Success) {
            return error.GattApplicationRegistrationFailed;
        }

        var provider: ?*win_bindings.IGattServiceProvider = null;
        if (sp_res.lpVtbl.get_ServiceProvider(sp_res, &provider) < 0 or provider == null) {
            return error.GattApplicationRegistrationFailed;
        }
        const prov = provider.?;
        s.win_provider = prov;

        var local_svc: ?*win_bindings.IGattLocalService = null;
        if (prov.lpVtbl.get_Service(prov, &local_svc) < 0 or local_svc == null) {
            return error.GattApplicationRegistrationFailed;
        }
        const lsvc = local_svc.?;
        defer _ = lsvc.lpVtbl.Release(lsvc);

        for (s.characteristics[0..s.char_count]) |*ch| {
            const param_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicParameters");
            defer win_mod.deleteHString(param_class);

            var param_insp: ?*win_bindings.IInspectable = null;
            if (win_bindings.Combase.RoActivateInstance(param_class, &param_insp) < 0 or param_insp == null) {
                return error.GattApplicationRegistrationFailed;
            }
            const pinsp = param_insp.?;
            defer _ = pinsp.release();

            var params: ?*win_bindings.IGattLocalCharacteristicParameters = null;
            if (pinsp.queryInterface(&win_bindings.IID_IGattLocalCharacteristicParameters, @ptrCast(&params)) < 0 or params == null) {
                return error.GattApplicationRegistrationFailed;
            }
            const p = params.?;
            defer _ = p.lpVtbl.Release(p);

            _ = p.lpVtbl.put_CharacteristicProperties(p, ch.flags.toWinRtProperties());
            _ = p.lpVtbl.put_ReadProtectionLevel(p, @enumFromInt(ch.flags.toWinRtReadProtection()));
            _ = p.lpVtbl.put_WriteProtectionLevel(p, @enumFromInt(ch.flags.toWinRtWriteProtection()));

            for (ch.descriptors[0..ch.desc_count]) |*d| {
                if (d.uuid.eql(UUID.from16(0x2901)) and d.value_len > 0) {
                    if (win_mod.createHStringRuntime(d.getValue())) |desc_hstr| {
                        defer win_mod.deleteHString(desc_hstr);
                        _ = p.lpVtbl.put_UserDescription(p, desc_hstr);
                    } else |_| {}
                }
            }

            var char_op: ?*win_bindings.IAsyncOperationGeneric = null;
            if (lsvc.lpVtbl.CreateCharacteristicAsync(lsvc, win_mod.uuidToGuid(ch.uuid), p, &char_op) < 0 or char_op == null) {
                return error.GattApplicationRegistrationFailed;
            }

            const char_res_raw = (try win_mod.awaitAsync(char_op.?, 10_000)) orelse return error.GattApplicationRegistrationFailed;
            const char_res: *win_bindings.IGattLocalCharacteristicResult = @ptrCast(@alignCast(char_res_raw));
            defer _ = char_res.lpVtbl.Release(char_res);

            var c_err: win_bindings.BluetoothError = .OtherError;
            if (char_res.lpVtbl.get_Error(char_res, &c_err) < 0 or c_err != .Success) {
                return error.GattApplicationRegistrationFailed;
            }

            var local_char: ?*win_bindings.IGattLocalCharacteristic = null;
            if (char_res.lpVtbl.get_Characteristic(char_res, &local_char) < 0 or local_char == null) {
                return error.GattApplicationRegistrationFailed;
            }
            const lc = local_char.?;
            ch.win_char = lc;

            ch.win_read_handler = .{
                .char_ctx = @ptrCast(ch),
                .on_read_requested = onWinRtReadRequested,
            };
            _ = lc.lpVtbl.add_ReadRequested(lc, @ptrCast(&ch.win_read_handler), &ch.win_read_token);

            ch.win_write_handler = .{
                .char_ctx = @ptrCast(ch),
                .on_write_requested = onWinRtWriteRequested,
            };
            _ = lc.lpVtbl.add_WriteRequested(lc, @ptrCast(&ch.win_write_handler), &ch.win_write_token);
        }

        // Start advertising the GATT service
        const adv_param_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProviderAdvertisingParameters");
        defer win_mod.deleteHString(adv_param_class);

        var adv_insp: ?*win_bindings.IInspectable = null;
        if (win_bindings.Combase.RoActivateInstance(adv_param_class, &adv_insp) >= 0 and adv_insp != null) {
            const ainsp = adv_insp.?;
            defer _ = ainsp.release();

            var adv_params: ?*win_bindings.IGattServiceProviderAdvertisingParameters = null;
            if (ainsp.queryInterface(&win_bindings.IID_IGattServiceProviderAdvertisingParameters, @ptrCast(&adv_params)) >= 0 and adv_params != null) {
                const ap = adv_params.?;
                defer _ = ap.lpVtbl.Release(ap);
                _ = ap.lpVtbl.put_IsConnectable(ap, 1);
                _ = ap.lpVtbl.put_IsDiscoverable(ap, 1);
                const start_hr = prov.lpVtbl.StartAdvertisingWithParameters(prov, ap);
                if (start_hr < 0) {
                    log.warn("WinRT GattServiceProvider.StartAdvertisingWithParameters returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(start_hr))});
                    return error.GattApplicationRegistrationFailed;
                }
            }
        }
    }

    app.is_registered = true;
}
