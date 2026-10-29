//! # Security Manager Protocol (SMP) State Machine
const std = @import("std");
const core_types = @import("../../core/types.zig");
const types_mod = @import("types.zig");
const pdu_mod = @import("pdu.zig");
const ecdh_mod = @import("ecdh.zig");
const toolbox = @import("../toolbox.zig");

pub const Address = core_types.Address;
pub const AddressType = core_types.AddressType;
pub const SmpOpcode = types_mod.SmpOpcode;
pub const IoCapability = types_mod.IoCapability;
pub const AuthReq = types_mod.AuthReq;
pub const KeyDistribution = types_mod.KeyDistribution;
pub const PairingFailedReason = types_mod.PairingFailedReason;
pub const SmpError = types_mod.SmpError;
pub const SMP_CID = types_mod.SMP_CID;
pub const SMP_TIMEOUT_MS = types_mod.SMP_TIMEOUT_MS;
pub const SmpRole = types_mod.SmpRole;
pub const PairingMethod = types_mod.PairingMethod;
pub const SmpState = types_mod.SmpState;

pub const PairingRequest = pdu_mod.PairingRequest;
pub const PairingResponse = pdu_mod.PairingResponse;
pub const PairingConfirm = pdu_mod.PairingConfirm;
pub const PairingRandom = pdu_mod.PairingRandom;
pub const PairingFailed = pdu_mod.PairingFailed;
pub const EncryptionInformation = pdu_mod.EncryptionInformation;
pub const MasterIdentification = pdu_mod.MasterIdentification;
pub const IdentityInformation = pdu_mod.IdentityInformation;
pub const IdentityAddressInformation = pdu_mod.IdentityAddressInformation;
pub const SigningInformation = pdu_mod.SigningInformation;
pub const SecurityRequest = pdu_mod.SecurityRequest;
pub const PairingPublicKey = pdu_mod.PairingPublicKey;
pub const PairingDhKeyCheck = pdu_mod.PairingDhKeyCheck;
pub const SmpPdu = pdu_mod.SmpPdu;

pub const EcdhKeyPair = ecdh_mod.EcdhKeyPair;
pub const generateEcdhKeyPair = ecdh_mod.generateEcdhKeyPair;
pub const computeDhKey = ecdh_mod.computeDhKey;
pub const selectPairingMethod = ecdh_mod.selectPairingMethod;

fn encodeSmpAddr7(addr: Address, addr_type: AddressType) [7]u8 {
    var out: [7]u8 = undefined;
    for (0..6) |i| {
        out[i] = addr.bytes[5 - i];
    }
    out[6] = if (addr_type == .public) 0x00 else 0x01;
    return out;
}

/// Full SMP State Machine supporting Initiator and Responder roles over L2CAP CID `0x0006`.
pub const SmpStateMachine = struct {
    role: SmpRole,
    state: SmpState = .idle,
    local_addr: Address,
    local_addr_type: AddressType = .public,
    peer_addr: Address,
    peer_addr_type: AddressType = .public,

    local_features: PairingRequest = .{
        .io_capability = .display_yes_no,
        .oob_data_flag = 0,
        .auth_req = .{ .bonding = true, .mitm = true, .sc = true },
        .max_encryption_key_size = 16,
        .initiator_key_distribution = .{ .enc_key = true, .id_key = true, .sign_key = true },
        .responder_key_distribution = .{ .enc_key = true, .id_key = true, .sign_key = true },
    },

    preq_bytes: [7]u8 = @splat(0),
    pres_bytes: [7]u8 = @splat(0),
    use_sc: bool = true,
    method: PairingMethod = .just_works,

    local_ecdh: ?EcdhKeyPair = null,
    peer_pub_x_le: [32]u8 = @splat(0),
    peer_pub_y_le: [32]u8 = @splat(0),
    dhkey_le: [32]u8 = @splat(0),

    local_rand: [16]u8 = @splat(0),
    peer_rand: [16]u8 = @splat(0),
    local_confirm: [16]u8 = @splat(0),
    peer_confirm: [16]u8 = @splat(0),
    passkey_r: [16]u8 = @splat(0),

    confirm_received: bool = false,
    random_received: bool = false,
    public_key_received: bool = false,

    mackey: [16]u8 = @splat(0),
    ltk: [16]u8 = @splat(0),
    stk: [16]u8 = @splat(0),
    numeric_comparison_code: ?u32 = null,
    last_failure_reason: ?PairingFailedReason = null,
    timer_started_ms: u64 = 0,

    pub fn init(
        role: SmpRole,
        local_addr: Address,
        local_addr_type: AddressType,
        peer_addr: Address,
        peer_addr_type: AddressType,
    ) SmpStateMachine {
        return .{
            .role = role,
            .local_addr = local_addr,
            .local_addr_type = local_addr_type,
            .peer_addr = peer_addr,
            .peer_addr_type = peer_addr_type,
        };
    }

    /// Checks whether the 30-second SMP timer has expired.
    pub fn checkTimeout(self: *SmpStateMachine, now_ms: u64) SmpError!void {
        switch (self.state) {
            .idle, .completed, .failed, .timed_out, .disconnected => return,
            else => {
                if (now_ms -| self.timer_started_ms >= SMP_TIMEOUT_MS) {
                    self.state = .timed_out;
                    return SmpError.PairingTimeout;
                }
            },
        }
    }

    /// Aborts any active pairing session upon link disconnection.
    pub fn onDisconnect(self: *SmpStateMachine) SmpError!void {
        const active = switch (self.state) {
            .idle, .completed, .failed, .timed_out, .disconnected => false,
            else => true,
        };
        self.state = .disconnected;
        if (active) return SmpError.BearerDisconnected;
    }

    /// Initiator starts Phase 1 by sending `PairingRequest` (`0x01`).
    pub fn startPairing(self: *SmpStateMachine, now_ms: u64, out_buf: []u8) SmpError!usize {
        if (self.role != .initiator) return SmpError.InvalidParameter;
        if (self.state == .disconnected) return SmpError.BearerDisconnected;
        if (self.state == .timed_out) return SmpError.PairingTimeout;

        const len = try self.local_features.serialize(out_buf);
        @memcpy(&self.preq_bytes, out_buf[0..7]);
        self.state = .wait_pairing_response;
        self.timer_started_ms = now_ms;
        self.confirm_received = false;
        self.random_received = false;
        self.public_key_received = false;
        return len;
    }

    fn failWithReason(self: *SmpStateMachine, reason: PairingFailedReason, out_buf: []u8) SmpError!usize {
        self.state = .failed;
        self.last_failure_reason = reason;
        return (PairingFailed{ .reason = reason }).serialize(out_buf);
    }

    /// Processes an incoming SMP PDU on L2CAP CID `0x0006` and writes the next outgoing PDU (if any) to `out_buf`.
    pub fn handlePdu(self: *SmpStateMachine, raw_pdu: []const u8, now_ms: u64, out_buf: []u8) SmpError!usize {
        if (self.state == .disconnected) return SmpError.BearerDisconnected;
        if (self.state == .timed_out) return SmpError.PairingTimeout;
        if (raw_pdu.len == 0) return SmpError.BufferTooShort;

        const pdu = SmpPdu.parse(raw_pdu) catch |err| {
            const reason: PairingFailedReason = if (err == error.InvalidOpcode) .command_not_supported else .invalid_parameters;
            return self.failWithReason(reason, out_buf);
        };

        if (pdu == .pairing_failed) {
            self.state = .failed;
            self.last_failure_reason = pdu.pairing_failed.reason;
            return 0;
        }

        // Reject duplicate confirm/random/public_key PDUs anywhere in the ceremony
        switch (pdu) {
            .pairing_public_key => if (self.public_key_received) return self.failWithReason(.unspecified_reason, out_buf),
            .pairing_confirm => if (self.confirm_received) return self.failWithReason(.unspecified_reason, out_buf),
            .pairing_random => if (self.random_received) return self.failWithReason(.unspecified_reason, out_buf),
            else => {},
        }

        self.timer_started_ms = now_ms;

        return switch (self.state) {
            .idle => {
                if (self.role == .responder and pdu == .pairing_request) {
                    const req = pdu.pairing_request;
                    if (req.max_encryption_key_size < 7 or req.max_encryption_key_size > 16) {
                        return self.failWithReason(.encryption_key_size, out_buf);
                    }
                    @memcpy(&self.preq_bytes, raw_pdu[0..7]);
                    const rsp = PairingResponse{
                        .io_capability = self.local_features.io_capability,
                        .oob_data_flag = self.local_features.oob_data_flag,
                        .auth_req = self.local_features.auth_req,
                        .max_encryption_key_size = @min(req.max_encryption_key_size, self.local_features.max_encryption_key_size),
                        .initiator_key_distribution = req.initiator_key_distribution,
                        .responder_key_distribution = req.responder_key_distribution,
                    };
                    const len = try rsp.serialize(out_buf);
                    @memcpy(&self.pres_bytes, out_buf[0..7]);
                    self.use_sc = req.auth_req.sc and rsp.auth_req.sc;
                    self.method = selectPairingMethod(
                        self.use_sc,
                        req.oob_data_flag,
                        rsp.oob_data_flag,
                        req.auth_req.mitm,
                        rsp.auth_req.mitm,
                        req.io_capability,
                        rsp.io_capability,
                    );
                    self.state = if (self.use_sc) .wait_public_key else .wait_confirm;
                    return len;
                }
                return self.failWithReason(.unspecified_reason, out_buf);
            },
            .wait_pairing_response => {
                if (self.role == .initiator and pdu == .pairing_response) {
                    const rsp = pdu.pairing_response;
                    if (rsp.max_encryption_key_size < 7 or rsp.max_encryption_key_size > 16) {
                        return self.failWithReason(.encryption_key_size, out_buf);
                    }
                    @memcpy(&self.pres_bytes, raw_pdu[0..7]);
                    const req = try PairingRequest.parse(&self.preq_bytes);
                    self.use_sc = req.auth_req.sc and rsp.auth_req.sc;
                    self.method = selectPairingMethod(
                        self.use_sc,
                        req.oob_data_flag,
                        rsp.oob_data_flag,
                        req.auth_req.mitm,
                        rsp.auth_req.mitm,
                        req.io_capability,
                        rsp.io_capability,
                    );

                    if (self.use_sc) {
                        if (self.local_ecdh == null) {
                            self.local_ecdh = try generateEcdhKeyPair(null);
                        }
                        self.state = .wait_public_key;
                        return (PairingPublicKey{
                            .x = self.local_ecdh.?.pub_x_le,
                            .y = self.local_ecdh.?.pub_y_le,
                        }).serialize(out_buf);
                    } else {
                        try self.prepareLegacyConfirm();
                        self.state = .wait_confirm;
                        return (PairingConfirm{ .confirm_value = self.local_confirm }).serialize(out_buf);
                    }
                }
                return self.failWithReason(.unspecified_reason, out_buf);
            },
            .wait_public_key => {
                if (pdu != .pairing_public_key) {
                    return self.failWithReason(.unspecified_reason, out_buf);
                }
                self.public_key_received = true;
                self.peer_pub_x_le = pdu.pairing_public_key.x;
                self.peer_pub_y_le = pdu.pairing_public_key.y;

                if (self.local_ecdh == null) {
                    self.local_ecdh = try generateEcdhKeyPair(null);
                }
                self.dhkey_le = computeDhKey(
                    self.local_ecdh.?.secret_be,
                    self.peer_pub_x_le,
                    self.peer_pub_y_le,
                ) catch {
                    return self.failWithReason(.invalid_parameters, out_buf);
                };

                toolbox.getRandomBytes(&self.local_rand) catch return SmpError.EntropyUnavailable;

                if (self.role == .responder) {
                    // Responder sends PairingPublicKey followed by PairingConfirm (Cb) in Just Works / Numeric Comparison
                    const pk_len = try (PairingPublicKey{
                        .x = self.local_ecdh.?.pub_x_le,
                        .y = self.local_ecdh.?.pub_y_le,
                    }).serialize(out_buf);
                    self.local_confirm = toolbox.f4(
                        self.local_ecdh.?.pub_x_le,
                        self.peer_pub_x_le,
                        self.local_rand,
                        0,
                    );
                    const cfm_len = try (PairingConfirm{ .confirm_value = self.local_confirm }).serialize(out_buf[pk_len..]);
                    self.state = .wait_random;
                    return pk_len + cfm_len;
                } else {
                    self.state = .wait_confirm;
                    return 0;
                }
            },
            .wait_confirm => {
                if (pdu != .pairing_confirm) {
                    return self.failWithReason(.unspecified_reason, out_buf);
                }
                self.confirm_received = true;
                self.peer_confirm = pdu.pairing_confirm.confirm_value;

                if (self.use_sc) {
                    // Initiator received Cb from Responder -> now send Na (PairingRandom)
                    self.state = .wait_random;
                    return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                } else {
                    if (self.role == .responder) {
                        try self.prepareLegacyConfirm();
                        self.state = .wait_random;
                        return (PairingConfirm{ .confirm_value = self.local_confirm }).serialize(out_buf);
                    } else {
                        self.state = .wait_random;
                        return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                    }
                }
            },
            .wait_random => {
                if (pdu != .pairing_random) {
                    return self.failWithReason(.unspecified_reason, out_buf);
                }
                self.random_received = true;
                self.peer_rand = pdu.pairing_random.random_value;

                if (self.use_sc) {
                    if (self.role == .initiator) {
                        // Verify Responder's confirm Cb = f4(PKb_x, PKa_x, Nb, 0)
                        const expected_cb = toolbox.f4(
                            self.peer_pub_x_le,
                            self.local_ecdh.?.pub_x_le,
                            self.peer_rand,
                            0,
                        );
                        if (!std.crypto.timing_safe.eql([16]u8, expected_cb, self.peer_confirm)) {
                            return self.failWithReason(.confirm_value_failed, out_buf);
                        }
                        self.numeric_comparison_code = toolbox.g2(
                            self.local_ecdh.?.pub_x_le,
                            self.peer_pub_x_le,
                            self.local_rand,
                            self.peer_rand,
                        );
                        self.deriveScKeysAndSendCheck();
                        const ea = self.computeLocalDhKeyCheck();
                        self.state = .wait_dhkey_check;
                        return (PairingDhKeyCheck{ .check_value = ea }).serialize(out_buf);
                    } else {
                        // Responder received Na -> send Nb and compute g2 + f5
                        self.numeric_comparison_code = toolbox.g2(
                            self.peer_pub_x_le,
                            self.local_ecdh.?.pub_x_le,
                            self.peer_rand,
                            self.local_rand,
                        );
                        self.deriveScKeysAndSendCheck();
                        self.state = .wait_dhkey_check;
                        return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                    }
                } else {
                    // Legacy pairing confirm verification
                    const expected = self.computeLegacyConfirmForPeer();
                    if (!std.crypto.timing_safe.eql([16]u8, expected, self.peer_confirm)) {
                        return self.failWithReason(.confirm_value_failed, out_buf);
                    }
                    const r1 = if (self.role == .initiator) self.peer_rand else self.local_rand;
                    const r2 = if (self.role == .initiator) self.local_rand else self.peer_rand;
                    self.stk = toolbox.s1(self.passkey_r, r1, r2);
                    if (self.role == .responder) {
                        self.state = .completed;
                        return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                    } else {
                        self.state = .completed;
                        return 0;
                    }
                }
            },
            .wait_dhkey_check => {
                if (pdu != .pairing_dhkey_check) {
                    return self.failWithReason(.unspecified_reason, out_buf);
                }
                const expected_peer_check = self.computePeerDhKeyCheck();
                if (!std.crypto.timing_safe.eql([16]u8, expected_peer_check, pdu.pairing_dhkey_check.check_value)) {
                    return self.failWithReason(.dhkey_check_failed, out_buf);
                }
                if (self.role == .responder) {
                    const eb = self.computeLocalDhKeyCheck();
                    self.state = .completed;
                    return (PairingDhKeyCheck{ .check_value = eb }).serialize(out_buf);
                } else {
                    self.state = .completed;
                    return 0;
                }
            },
            else => return self.failWithReason(.unspecified_reason, out_buf),
        };
    }

    fn unexpected_opcode_or_params() PairingFailedReason {
        return .unspecified_reason;
    }

    fn prepareLegacyConfirm(self: *SmpStateMachine) SmpError!void {
        toolbox.getRandomBytes(&self.local_rand) catch return SmpError.EntropyUnavailable;
        const ia_addr = if (self.role == .initiator) self.local_addr else self.peer_addr;
        const ra_addr = if (self.role == .initiator) self.peer_addr else self.local_addr;
        const iat: u1 = if ((if (self.role == .initiator) self.local_addr_type else self.peer_addr_type) == .public) 0 else 1;
        const rat: u1 = if ((if (self.role == .initiator) self.peer_addr_type else self.local_addr_type) == .public) 0 else 1;

        var ia_le: [6]u8 = undefined;
        var ra_le: [6]u8 = undefined;
        var preq_le: [7]u8 = undefined;
        var pres_le: [7]u8 = undefined;
        for (0..6) |i| {
            ia_le[i] = ia_addr.bytes[5 - i];
            ra_le[i] = ra_addr.bytes[5 - i];
        }
        for (0..7) |i| {
            preq_le[i] = self.preq_bytes[i];
            pres_le[i] = self.pres_bytes[i];
        }
        self.local_confirm = toolbox.c1(self.passkey_r, self.local_rand, pres_le, preq_le, iat, rat, ia_le, ra_le);
    }

    fn computeLegacyConfirmForPeer(self: *const SmpStateMachine) [16]u8 {
        const ia_addr = if (self.role == .initiator) self.local_addr else self.peer_addr;
        const ra_addr = if (self.role == .initiator) self.peer_addr else self.local_addr;
        const iat: u1 = if ((if (self.role == .initiator) self.local_addr_type else self.peer_addr_type) == .public) 0 else 1;
        const rat: u1 = if ((if (self.role == .initiator) self.peer_addr_type else self.local_addr_type) == .public) 0 else 1;

        var ia_le: [6]u8 = undefined;
        var ra_le: [6]u8 = undefined;
        var preq_le: [7]u8 = undefined;
        var pres_le: [7]u8 = undefined;
        for (0..6) |i| {
            ia_le[i] = ia_addr.bytes[5 - i];
            ra_le[i] = ra_addr.bytes[5 - i];
        }
        for (0..7) |i| {
            preq_le[i] = self.preq_bytes[i];
            pres_le[i] = self.pres_bytes[i];
        }
        return toolbox.c1(self.passkey_r, self.peer_rand, pres_le, preq_le, iat, rat, ia_le, ra_le);
    }

    fn deriveScKeysAndSendCheck(self: *SmpStateMachine) void {
        const na = if (self.role == .initiator) self.local_rand else self.peer_rand;
        const nb = if (self.role == .initiator) self.peer_rand else self.local_rand;
        const a1 = encodeSmpAddr7(
            if (self.role == .initiator) self.local_addr else self.peer_addr,
            if (self.role == .initiator) self.local_addr_type else self.peer_addr_type,
        );
        const a2 = encodeSmpAddr7(
            if (self.role == .initiator) self.peer_addr else self.local_addr,
            if (self.role == .initiator) self.peer_addr_type else self.local_addr_type,
        );
        const derived = toolbox.f5(self.dhkey_le, na, nb, a1, a2);
        self.mackey = derived.mackey;
        self.ltk = derived.ltk;
    }

    fn computeLocalDhKeyCheck(self: *const SmpStateMachine) [16]u8 {
        const a_init = encodeSmpAddr7(
            if (self.role == .initiator) self.local_addr else self.peer_addr,
            if (self.role == .initiator) self.local_addr_type else self.peer_addr_type,
        );
        const a_resp = encodeSmpAddr7(
            if (self.role == .initiator) self.peer_addr else self.local_addr,
            if (self.role == .initiator) self.peer_addr_type else self.local_addr_type,
        );
        if (self.role == .initiator) {
            const iocap = [3]u8{ self.preq_bytes[1], self.preq_bytes[2], self.preq_bytes[3] };
            return toolbox.f6(self.mackey, self.local_rand, self.peer_rand, self.passkey_r, iocap, a_init, a_resp);
        } else {
            const iocap = [3]u8{ self.pres_bytes[1], self.pres_bytes[2], self.pres_bytes[3] };
            return toolbox.f6(self.mackey, self.local_rand, self.peer_rand, self.passkey_r, iocap, a_resp, a_init);
        }
    }

    fn computePeerDhKeyCheck(self: *const SmpStateMachine) [16]u8 {
        const a_init = encodeSmpAddr7(
            if (self.role == .initiator) self.local_addr else self.peer_addr,
            if (self.role == .initiator) self.local_addr_type else self.peer_addr_type,
        );
        const a_resp = encodeSmpAddr7(
            if (self.role == .initiator) self.peer_addr else self.local_addr,
            if (self.role == .initiator) self.peer_addr_type else self.local_addr_type,
        );
        if (self.role == .initiator) {
            const iocap = [3]u8{ self.pres_bytes[1], self.pres_bytes[2], self.pres_bytes[3] };
            return toolbox.f6(self.mackey, self.peer_rand, self.local_rand, self.passkey_r, iocap, a_resp, a_init);
        } else {
            const iocap = [3]u8{ self.preq_bytes[1], self.preq_bytes[2], self.preq_bytes[3] };
            return toolbox.f6(self.mackey, self.peer_rand, self.local_rand, self.passkey_r, iocap, a_init, a_resp);
        }
    }
};

