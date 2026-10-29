//! # WinRT Device Pairing & Bond State Management
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");
const helpers = @import("helpers.zig");

const BleError = types.BleError;
const PairingCallbacks = types.PairingCallbacks;
const HSTRING = bindings.HSTRING;

pub const PairingSessionContext = struct {
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

pub fn onPairingRequested(pair_ctx: *anyopaque, args: *bindings.IDevicePairingRequestedEventArgs) callconv(.c) void {
    const ctx: *PairingSessionContext = @ptrCast(@alignCast(pair_ctx));
    var kind: u32 = 0;
    if (args.lpVtbl.get_PairingKind(args, &kind) < 0) return;

    var pin_buf: [32]u8 = undefined;
    var pin_slice: ?[]const u8 = null;
    var pin_hstr: HSTRING = null;
    if (args.lpVtbl.get_Pin(args, &pin_hstr) >= 0 and pin_hstr != null) {
        defer helpers.deleteHString(pin_hstr);
        const len = helpers.hstringToUtf8(pin_hstr, &pin_buf);
        if (len > 0) pin_slice = pin_buf[0..len];
    }

    const action = evaluatePairingCeremony(kind, pin_slice, ctx.io_cap, ctx.callbacks);
    switch (action) {
        .reject => {},
        .accept_only => {
            _ = args.lpVtbl.Accept(args);
        },
        .accept_with_pin => |pin_digits| {
            if (helpers.createHStringRuntime(&pin_digits)) |hstr| {
                defer helpers.deleteHString(hstr);
                _ = args.lpVtbl.AcceptWithPin(args, hstr);
            } else |_| {}
        },
    }
}

pub fn queryWinRtBondState(ble_dev: *bindings.IBluetoothLEDevice) types.BondState {
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

pub fn pairDevice(backend: anytype, dev: anytype, io_cap: types.IoCapability) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
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
        .callbacks = backend.pairing_callbacks,
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

    const res_raw = (helpers.awaitAsync(pair_op.?, backend.timeouts.pair_ms) catch |err| {
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

pub fn unpairDevice(backend: anytype, dev: anytype) BleError!void {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
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

    const res_raw = (try helpers.awaitAsync(unpair_op.?, backend.timeouts.pair_ms)) orelse return BleError.PairingFailed;
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

