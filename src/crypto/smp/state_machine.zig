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

    /// Null until the application provides it; Passkey Entry never runs with a default value.
    passkey: ?u32 = null,
    passkey_round: u5 = 0,
    /// Numeric Comparison waits for `confirmNumericComparison`. Turning this off accepts the
    /// comparison unseen, which gives up its protection against a man in the middle.
    require_user_confirmation: bool = true,
    user_confirmed: bool = false,
    /// A DHKey check from the initiator that arrived before the local user confirmed.
    early_peer_check: ?[16]u8 = null,
    /// Stay in `key_distribution` after pairing until the negotiated keys are exchanged.
    /// Otherwise pairing completes right away and keys the peer sends are ignored.
    key_distribution_enabled: bool = false,
    /// Keys are only accepted over an encrypted link; see `onLinkEncrypted`.
    link_encrypted: bool = false,
    expected_peer_keys: KeyDistribution = .{},
    pending_local_keys: KeyDistribution = .{},

    peer_ltk: [16]u8 = @splat(0),
    peer_ediv: u16 = 0,
    peer_ltk_rand: [8]u8 = @splat(0),
    peer_irk: [16]u8 = @splat(0),
    peer_csrk: [16]u8 = @splat(0),
    peer_identity_addr: ?Address = null,
    peer_identity_addr_type: ?AddressType = null,

    confirm_received: bool = false,
    random_received: bool = false,
    public_key_received: bool = false,

    mackey: [16]u8 = @splat(0),
    ltk: [16]u8 = @splat(0),
    stk: [16]u8 = @splat(0),
    numeric_comparison_code: ?u32 = null,
    last_failure_reason: ?PairingFailedReason = null,
    timer_started_ms: u64 = 0,

    /// Sets the 6-digit passkey ahead of time (required for legacy Passkey Entry).
    pub fn setPasskey(self: *SmpStateMachine, passkey: u32) SmpError!void {
        if (passkey > 999_999) return SmpError.InvalidParameter;
        self.passkey = passkey;
        std.mem.writeInt(u32, self.passkey_r[0..4], passkey, .little);
        @memset(self.passkey_r[4..16], 0);
    }

    /// Generates a random passkey for the device that displays it, and returns it for display.
    pub fn generatePasskey(self: *SmpStateMachine) SmpError!u32 {
        // Rejection sampling keeps the distribution uniform over 000000..999999.
        const limit: u32 = std.math.maxInt(u32) - (std.math.maxInt(u32) % 1_000_000);
        while (true) {
            var bytes: [4]u8 = undefined;
            toolbox.getRandomBytes(&bytes) catch return SmpError.EntropyUnavailable;
            const value = std.mem.readInt(u32, &bytes, .little);
            if (value >= limit) continue;
            const passkey = value % 1_000_000;
            try self.setPasskey(passkey);
            return passkey;
        }
    }

    /// Continues Passkey Entry from `wait_passkey` with the passkey the user entered.
    pub fn providePasskey(self: *SmpStateMachine, passkey: u32, out_buf: []u8) SmpError!usize {
        if (self.state != .wait_passkey) return SmpError.InvalidParameter;
        try self.setPasskey(passkey);
        return self.sendPasskeyConfirm(out_buf);
    }

    /// Ends pairing from `wait_passkey` because the user cancelled the entry.
    pub fn rejectPasskey(self: *SmpStateMachine, out_buf: []u8) SmpError!usize {
        if (self.state != .wait_passkey) return SmpError.InvalidParameter;
        return self.failWithReason(.passkey_entry_failed, out_buf);
    }

    /// Sends this round's confirm value: Ca as initiator, Cb (with a fresh Nb) as responder.
    fn sendPasskeyConfirm(self: *SmpStateMachine, out_buf: []u8) SmpError!usize {
        if (self.role == .responder) {
            toolbox.getRandomBytes(&self.local_rand) catch return SmpError.EntropyUnavailable;
        }
        const bit_i: u8 = @intCast((self.passkey.? >> self.passkey_round) & 1);
        self.local_confirm = toolbox.f4(
            self.local_ecdh.?.pub_x_le,
            self.peer_pub_x_le,
            self.local_rand,
            0x80 | bit_i,
        );
        self.state = if (self.role == .responder) .wait_random else .wait_confirm;
        return (PairingConfirm{ .confirm_value = self.local_confirm }).serialize(out_buf);
    }

    pub fn confirmNumericComparison(self: *SmpStateMachine, accept: bool, out_buf: []u8) SmpError!usize {
        if (self.state != .wait_numeric_comparison) return SmpError.InvalidParameter;
        if (!accept) {
            return self.failWithReason(.numeric_comparison_failed, out_buf);
        }
        self.user_confirmed = true;
        self.deriveScKeysAndSendCheck();
        self.state = .wait_dhkey_check;
        if (self.role == .initiator) {
            const ea = self.computeLocalDhKeyCheck();
            return (PairingDhKeyCheck{ .check_value = ea }).serialize(out_buf);
        }
        // The initiator's user may have confirmed first.
        if (self.early_peer_check) |check| {
            self.early_peer_check = null;
            return self.finishDhKeyCheck(check, out_buf);
        }
        return 0;
    }

    /// Verifies the peer's DHKey check; as responder also answers with Eb.
    fn finishDhKeyCheck(self: *SmpStateMachine, check_value: [16]u8, out_buf: []u8) SmpError!usize {
        const expected_peer_check = self.computePeerDhKeyCheck();
        if (!std.crypto.timing_safe.eql([16]u8, expected_peer_check, check_value)) {
            return self.failWithReason(.dhkey_check_failed, out_buf);
        }
        self.enterKeyDistribution();
        if (self.role == .responder) {
            const eb = self.computeLocalDhKeyCheck();
            return (PairingDhKeyCheck{ .check_value = eb }).serialize(out_buf);
        }
        return 0;
    }

    /// Works out which keys the negotiated features still require after authentication.
    fn enterKeyDistribution(self: *SmpStateMachine) void {
        self.state = .completed;
        if (!self.key_distribution_enabled) return;

        var initiator_keys = KeyDistribution.fromByte(self.pres_bytes[5]);
        var responder_keys = KeyDistribution.fromByte(self.pres_bytes[6]);
        if (self.use_sc) {
            // LE Secure Connections derives the LTK on both sides; EncKey is not distributed.
            initiator_keys.enc_key = false;
            responder_keys.enc_key = false;
        }
        self.expected_peer_keys = if (self.role == .initiator) responder_keys else initiator_keys;
        self.pending_local_keys = if (self.role == .initiator) initiator_keys else responder_keys;
        self.state = .key_distribution;
        self.completeIfKeysExchanged();
    }

    fn hasKeys(keys: KeyDistribution) bool {
        return keys.enc_key or keys.id_key or keys.sign_key;
    }

    fn completeIfKeysExchanged(self: *SmpStateMachine) void {
        if (!hasKeys(self.expected_peer_keys) and !hasKeys(self.pending_local_keys)) {
            self.state = .completed;
        }
    }

    /// Reports that the link is now encrypted. Keys may only be exchanged after this.
    pub fn onLinkEncrypted(self: *SmpStateMachine) void {
        self.link_encrypted = true;
    }

    /// Sends the local IRK and identity address, if they were negotiated. Requires an encrypted
    /// link. The responder distributes first; the initiator sends after receiving its keys.
    pub fn distributeIdentityKeys(self: *SmpStateMachine, irk: [16]u8, out_buf: []u8) SmpError!usize {
        if (self.state != .key_distribution or !self.link_encrypted or !self.pending_local_keys.id_key) {
            return SmpError.InvalidParameter;
        }
        var len: usize = 0;
        const id_info = IdentityInformation{ .irk = irk };
        len += try id_info.serialize(out_buf[len..]);
        const id_addr = IdentityAddressInformation{
            .addr_type = self.local_addr_type,
            .address = self.local_addr,
        };
        len += try id_addr.serialize(out_buf[len..]);
        self.pending_local_keys.id_key = false;
        self.completeIfKeysExchanged();
        return len;
    }

    /// Declares the remaining local keys handled, e.g. after sending them directly or because
    /// the application has none to send.
    pub fn finishLocalKeyDistribution(self: *SmpStateMachine) void {
        if (self.state != .key_distribution) return;
        self.pending_local_keys = .{};
        self.completeIfKeysExchanged();
    }

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
                        .initiator_key_distribution = .fromByte(req.initiator_key_distribution.toByte() & self.local_features.initiator_key_distribution.toByte()),
                        .responder_key_distribution = .fromByte(req.responder_key_distribution.toByte() & self.local_features.responder_key_distribution.toByte()),
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
                        if (self.method == .passkey_entry and self.passkey == null) {
                            return self.failWithReason(.passkey_entry_failed, out_buf);
                        }
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
                // A peer reflecting our own key could impersonate us (CVE-2020-26558).
                if (std.mem.eql(u8, &self.peer_pub_x_le, &self.local_ecdh.?.pub_x_le)) {
                    return self.failWithReason(.unspecified_reason, out_buf);
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
                    const pk_len = try (PairingPublicKey{
                        .x = self.local_ecdh.?.pub_x_le,
                        .y = self.local_ecdh.?.pub_y_le,
                    }).serialize(out_buf);

                    if (self.method == .passkey_entry) {
                        self.passkey_round = 0;
                        self.state = .wait_confirm;
                        return pk_len;
                    }

                    // In Just Works / Numeric Comparison, Responder sends PK + Cb (f4 with r=0)
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
                    if (self.method == .passkey_entry) {
                        // Initiator starts round 0 of Passkey Entry
                        self.passkey_round = 0;
                        if (self.passkey == null) {
                            self.state = .wait_passkey;
                            return 0;
                        }
                        return self.sendPasskeyConfirm(out_buf);
                    }
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
                    if (self.method == .passkey_entry) {
                        if (self.role == .responder) {
                            // Responder received Cai -> compute and send Cbi
                            if (self.passkey == null) {
                                self.state = .wait_passkey;
                                return 0;
                            }
                            return self.sendPasskeyConfirm(out_buf);
                        } else {
                            // Initiator received Cbi -> send Nai
                            self.state = .wait_random;
                            return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                        }
                    } else {
                        // Initiator received Cb from Responder -> now send Na (PairingRandom)
                        self.state = .wait_random;
                        return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                    }
                } else {
                    if (self.role == .responder) {
                        if (self.method == .passkey_entry and self.passkey == null) {
                            return self.failWithReason(.passkey_entry_failed, out_buf);
                        }
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
                    if (self.method == .passkey_entry) {
                        const bit_i: u8 = @intCast((self.passkey.? >> self.passkey_round) & 1);
                        const r_val: u8 = 0x80 | bit_i;
                        const expected_peer_confirm = toolbox.f4(
                            self.peer_pub_x_le,
                            self.local_ecdh.?.pub_x_le,
                            self.peer_rand,
                            r_val,
                        );
                        if (!std.crypto.timing_safe.eql([16]u8, expected_peer_confirm, self.peer_confirm)) {
                            return self.failWithReason(.confirm_value_failed, out_buf);
                        }

                        if (self.role == .responder) {
                            if (self.passkey_round < 19) {
                                self.passkey_round += 1;
                                self.confirm_received = false;
                                self.random_received = false;
                                self.state = .wait_confirm;
                                return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                            } else {
                                self.deriveScKeysAndSendCheck();
                                self.state = .wait_dhkey_check;
                                return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                            }
                        } else {
                            if (self.passkey_round < 19) {
                                self.passkey_round += 1;
                                self.confirm_received = false;
                                self.random_received = false;
                                toolbox.getRandomBytes(&self.local_rand) catch return SmpError.EntropyUnavailable;
                                const bit_next: u8 = @intCast((self.passkey.? >> self.passkey_round) & 1);
                                const r_next: u8 = 0x80 | bit_next;
                                self.local_confirm = toolbox.f4(
                                    self.local_ecdh.?.pub_x_le,
                                    self.peer_pub_x_le,
                                    self.local_rand,
                                    r_next,
                                );
                                self.state = .wait_confirm;
                                return (PairingConfirm{ .confirm_value = self.local_confirm }).serialize(out_buf);
                            } else {
                                self.deriveScKeysAndSendCheck();
                                const ea = self.computeLocalDhKeyCheck();
                                self.state = .wait_dhkey_check;
                                return (PairingDhKeyCheck{ .check_value = ea }).serialize(out_buf);
                            }
                        }
                    }

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
                        if (self.method == .numeric_comparison and self.require_user_confirmation) {
                            self.state = .wait_numeric_comparison;
                            return 0;
                        }
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
                        if (self.method == .numeric_comparison and self.require_user_confirmation) {
                            self.state = .wait_numeric_comparison;
                            return (PairingRandom{ .random_value = self.local_rand }).serialize(out_buf);
                        }
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
            .wait_numeric_comparison => {
                // The initiator's user may confirm before ours.
                if (self.role == .responder and pdu == .pairing_dhkey_check and self.early_peer_check == null) {
                    self.early_peer_check = pdu.pairing_dhkey_check.check_value;
                    return 0;
                }
                return self.failWithReason(.unspecified_reason, out_buf);
            },
            .wait_dhkey_check => {
                if (pdu != .pairing_dhkey_check) {
                    return self.failWithReason(.unspecified_reason, out_buf);
                }
                return self.finishDhKeyCheck(pdu.pairing_dhkey_check.check_value, out_buf);
            },
            .key_distribution => {
                // Keys are secrets: never accept them over an unencrypted link.
                if (!self.link_encrypted) return self.failWithReason(.unspecified_reason, out_buf);
                switch (pdu) {
                    .encryption_information => |enc| {
                        if (!self.expected_peer_keys.enc_key) return self.failWithReason(.unspecified_reason, out_buf);
                        self.peer_ltk = enc.long_term_key;
                    },
                    .master_identification => |id| {
                        if (!self.expected_peer_keys.enc_key) return self.failWithReason(.unspecified_reason, out_buf);
                        self.peer_ediv = id.ediv;
                        self.peer_ltk_rand = id.rand;
                        self.expected_peer_keys.enc_key = false;
                    },
                    .identity_information => |id| {
                        if (!self.expected_peer_keys.id_key) return self.failWithReason(.unspecified_reason, out_buf);
                        self.peer_irk = id.irk;
                    },
                    .identity_address_information => |ia| {
                        if (!self.expected_peer_keys.id_key) return self.failWithReason(.unspecified_reason, out_buf);
                        self.peer_identity_addr = ia.address;
                        self.peer_identity_addr_type = ia.addr_type;
                        self.expected_peer_keys.id_key = false;
                    },
                    .signing_information => |sign| {
                        if (!self.expected_peer_keys.sign_key) return self.failWithReason(.unspecified_reason, out_buf);
                        self.peer_csrk = sign.csrk;
                        self.expected_peer_keys.sign_key = false;
                    },
                    else => return self.failWithReason(.unspecified_reason, out_buf),
                }
                self.completeIfKeysExchanged();
                return 0;
            },
            .completed => {
                // Pairing succeeded without key exchange being requested; a peer may still
                // send what was negotiated. That must not turn success into failure.
                return switch (pdu) {
                    .encryption_information, .master_identification, .identity_information, .identity_address_information, .signing_information => 0,
                    else => self.failWithReason(.unspecified_reason, out_buf),
                };
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

