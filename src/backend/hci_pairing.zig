//! # HciBackend: pairing as initiator

const std = @import("std");
const types = @import("types.zig");
const hci = @import("../hci/mod.zig");
const smp = @import("../crypto/smp.zig");
const backend_mod = @import("hci.zig");

const HciBackend = backend_mod.HciBackend;
const HciDeviceContext = backend_mod.HciDeviceContext;
const BleError = types.BleError;

/// Moves pairing forward after the state machine or the link changed.
pub fn advancePairing(self: *HciBackend, dev: *HciDeviceContext) BleError!void {
    const sm = if (dev.smp_sm) |*s| s else return;
    var out_buf: [128]u8 = undefined;
    const callbacks = self.pairing_callbacks;

    switch (sm.state) {
        .wait_numeric_comparison => {
            const accepted = if (callbacks.on_confirm) |confirm| confirm(sm.numeric_comparison_code, callbacks.user_data) else false;
            const len = sm.confirmNumericComparison(accepted, &out_buf) catch return BleError.AuthenticationFailed;
            try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, out_buf[0..len]);
        },
        .wait_passkey => {
            const len = answerPasskey(sm, callbacks, &out_buf) catch return BleError.AuthenticationFailed;
            try self.sendL2capOverAcl(dev.conn_handle, smp.SMP_CID, out_buf[0..len]);
        },
        .key_distribution, .completed => {
            if (!dev.encrypting and !dev.encrypted) {
                dev.encrypting = true;
                const key = if (sm.use_sc) sm.ltk else sm.stk;
                const cmd = hci.Commands.leStartEncryption(dev.conn_handle, 0, 0, key);
                try self.emitPacket(.host_to_controller, &cmd);
            }
        },
        else => {},
    }

    switch (sm.state) {
        .completed => if (dev.encrypted) {
            dev.bond_state = .bonded;
            dev.pairing_done = true;
        },
        .failed, .timed_out, .disconnected => {
            dev.bond_state = .not_bonded;
            dev.pairing_done = true;
        },
        else => {},
    }
}

/// The keyboard side enters the passkey; the display side generates and shows it.
fn answerPasskey(sm: *smp.SmpStateMachine, callbacks: types.PairingCallbacks, out_buf: []u8) smp.SmpError!usize {
    const local = sm.local_features.io_capability;
    const peer: smp.IoCapability = @enumFromInt(sm.pres_bytes[1]);
    const display = local == .display_only or local == .display_yes_no or (local == .keyboard_display and peer == .keyboard_only);
    if (display) {
        const show = callbacks.on_display_passkey orelse return sm.rejectPasskey(out_buf);
        const passkey = try sm.generatePasskey();
        show(passkey, callbacks.user_data);
        return sm.providePasskey(passkey, out_buf);
    }
    const request = callbacks.on_request_passkey orelse return sm.rejectPasskey(out_buf);
    const entered = request(callbacks.user_data) orelse return sm.rejectPasskey(out_buf);
    return sm.providePasskey(entered, out_buf);
}

pub fn onEncryptionChange(self: *HciBackend, handle: u16, success: bool) BleError!void {
    for (&self.devices) |*dev| {
        if (!dev.in_use or dev.conn_handle != handle) continue;
        dev.encrypting = false;
        if (success) {
            dev.encrypted = true;
            if (dev.smp_sm) |*sm| sm.onLinkEncrypted();
            try advancePairing(self, dev);
        } else {
            dev.bond_state = .not_bonded;
            dev.pairing_done = true;
        }
        return;
    }
}
