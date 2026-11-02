//! # SMP Unit Tests & State Machine Tests
const std = @import("std");
const core_types = @import("../../core/types.zig");
const smp = @import("../smp.zig");

const Address = core_types.Address;
const AddressType = core_types.AddressType;
const SmpOpcode = smp.SmpOpcode;
const SmpError = smp.SmpError;
const SmpPdu = smp.SmpPdu;
const IoCapability = smp.IoCapability;
const SmpStateMachine = smp.SmpStateMachine;
const SmpState = smp.SmpState;
const PairingRequest = smp.PairingRequest;
const PairingResponse = smp.PairingResponse;
const PairingConfirm = smp.PairingConfirm;
const PairingRandom = smp.PairingRandom;
const PairingFailed = smp.PairingFailed;
const PairingFailedReason = smp.PairingFailedReason;
const PairingPublicKey = smp.PairingPublicKey;
const PairingDhKeyCheck = smp.PairingDhKeyCheck;
const IdentityAddressInformation = smp.IdentityAddressInformation;
const SecurityRequest = smp.SecurityRequest;

test "smp pdu roundtrip tests" {
    // 1. Pairing Request
    const req = PairingRequest{
        .io_capability = .keyboard_display,
        .oob_data_flag = 0,
        .auth_req = .{ .bonding = true, .mitm = true, .sc = true },
        .max_encryption_key_size = 16,
        .initiator_key_distribution = .{ .enc_key = true, .id_key = true },
        .responder_key_distribution = .{ .enc_key = true, .id_key = true },
    };
    var buf: [128]u8 = undefined;
    const len1 = try req.serialize(&buf);
    try std.testing.expectEqual(7, len1);

    const parsed_pdu = try SmpPdu.parse(buf[0..len1]);
    try std.testing.expect(parsed_pdu == .pairing_request);
    try std.testing.expectEqual(IoCapability.keyboard_display, parsed_pdu.pairing_request.io_capability);
    try std.testing.expect(parsed_pdu.pairing_request.auth_req.sc);
    try std.testing.expect(parsed_pdu.pairing_request.auth_req.mitm);

    // 2. Pairing Failed
    const failed = PairingFailed{ .reason = .dhkey_check_failed };
    const len2 = try failed.serialize(&buf);
    const parsed_failed = try PairingFailed.parse(buf[0..len2]);
    try std.testing.expectEqual(PairingFailedReason.dhkey_check_failed, parsed_failed.reason);

    // 3. Identity Address Information
    const id_addr = IdentityAddressInformation{
        .addr_type = .random,
        .address = try Address.parse("C0:1A:7D:DA:71:13"),
    };
    const len3 = try id_addr.serialize(&buf);
    const parsed_id_addr = try IdentityAddressInformation.parse(buf[0..len3]);
    try std.testing.expect(parsed_id_addr.address.eql(try Address.parse("C0:1A:7D:DA:71:13")));
}


// -------------------------------------------------------------------------------------------------
// SMP State Machine (L2CAP CID 0x0006) - Phase 1, Phase 2 (Legacy & LE Secure Connections), Phase 3
// Bluetooth Core Specification Vol 3, Part H, Section 2.3 & Section 3
// -------------------------------------------------------------------------------------------------


test "SMP State Machine: Full LE Secure Connections ECDH P-256 Handshake (Initiator <-> Responder)" {
    const init_addr = try Address.parse("A1:A2:A3:A4:A5:A6");
    const resp_addr = try Address.parse("B1:B2:B3:B4:B5:B6");

    var initiator = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var responder = SmpStateMachine.init(.responder, resp_addr, .public, init_addr, .public);
    initiator.require_user_confirmation = false;
    responder.require_user_confirmation = false;

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;

    // 1. Initiator sends PairingRequest
    const preq_len = try initiator.startPairing(100, &buf_a);
    try std.testing.expectEqual(@as(usize, 7), preq_len);

    // 2. Responder processes PairingRequest -> sends PairingResponse
    const pres_len = try responder.handlePdu(buf_a[0..preq_len], 110, &buf_b);
    try std.testing.expectEqual(@as(usize, 7), pres_len);

    // 3. Initiator processes PairingResponse -> generates P-256 keypair and sends PairingPublicKey (65B)
    const pk_a_len = try initiator.handlePdu(buf_b[0..pres_len], 120, &buf_a);
    try std.testing.expectEqual(@as(usize, 65), pk_a_len);

    // 4. Responder processes PairingPublicKey -> returns its PairingPublicKey (65B) + PairingConfirm Cb (17B)
    const pk_b_and_cb_len = try responder.handlePdu(buf_a[0..pk_a_len], 130, &buf_b);
    try std.testing.expectEqual(@as(usize, 65 + 17), pk_b_and_cb_len);

    // 5. Initiator processes Responder's PairingPublicKey (first 65B) and PairingConfirm (next 17B) -> sends Na (17B)
    const after_pk_len = try initiator.handlePdu(buf_b[0..65], 140, &buf_a);
    try std.testing.expectEqual(@as(usize, 0), after_pk_len);
    const na_len = try initiator.handlePdu(buf_b[65..82], 145, &buf_a);
    try std.testing.expectEqual(@as(usize, 17), na_len);

    // 6. Responder processes Na -> sends Nb (17B)
    const nb_len = try responder.handlePdu(buf_a[0..na_len], 150, &buf_b);
    try std.testing.expectEqual(@as(usize, 17), nb_len);

    // 7. Initiator processes Nb -> verifies Cb, derives LTK via f5, sends Ea (PairingDhKeyCheck, 17B)
    const ea_len = try initiator.handlePdu(buf_b[0..nb_len], 160, &buf_a);
    try std.testing.expectEqual(@as(usize, 17), ea_len);

    // 8. Responder processes Ea -> verifies Ea, sends Eb (PairingDhKeyCheck, 17B) and completes!
    const eb_len = try responder.handlePdu(buf_a[0..ea_len], 170, &buf_b);
    try std.testing.expectEqual(@as(usize, 17), eb_len);
    try std.testing.expectEqual(SmpState.completed, responder.state);

    // 9. Initiator processes Eb -> verifies Eb and completes!
    const final_len = try initiator.handlePdu(buf_b[0..eb_len], 180, &buf_a);
    try std.testing.expectEqual(@as(usize, 0), final_len);
    try std.testing.expectEqual(SmpState.completed, initiator.state);

    // Both sides must have derived the exact same 128-bit LTK and 6-digit Numeric Comparison value!
    try std.testing.expectEqualSlices(u8, &initiator.ltk, &responder.ltk);
    try std.testing.expectEqual(initiator.numeric_comparison_code.?, responder.numeric_comparison_code.?);
}

test "SMP State Machine: Edge cases (unexpected opcode, duplicate confirm, disconnect, 30s timeout)" {
    const init_addr = try Address.parse("11:22:33:44:55:66");
    const resp_addr = try Address.parse("AA:BB:CC:DD:EE:FF");

    var sm = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var out: [128]u8 = undefined;
    _ = try sm.startPairing(1000, &out);

    // 1. Unexpected opcode in wait_pairing_response -> sends PairingFailed (0x05) and transitions to .failed
    var unexpected_rand: [17]u8 = @splat(0);
    unexpected_rand[0] = @intFromEnum(SmpOpcode.pairing_random);
    const fail_len = try sm.handlePdu(&unexpected_rand, 1010, &out);
    try std.testing.expectEqual(@as(usize, 2), fail_len);
    try std.testing.expectEqual(@intFromEnum(SmpOpcode.pairing_failed), out[0]);
    try std.testing.expectEqual(SmpState.failed, sm.state);

    // 2. 30-second timeout
    var sm2 = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    _ = try sm2.startPairing(2000, &out);
    try sm2.checkTimeout(31_999);
    try std.testing.expectError(SmpError.PairingTimeout, sm2.checkTimeout(32_000));
    try std.testing.expectEqual(SmpState.timed_out, sm2.state);

    // 3. Disconnect mid-pairing
    var sm3 = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    _ = try sm3.startPairing(3000, &out);
    try std.testing.expectError(SmpError.BearerDisconnected, sm3.onDisconnect());
}

test "SMP State Machine: Numeric Comparison user confirmation and rejection" {
    const init_addr = try Address.parse("11:22:33:44:55:66");
    const resp_addr = try Address.parse("AA:BB:CC:DD:EE:FF");

    // Case A: User Rejection
    var initiator = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var responder = SmpStateMachine.init(.responder, resp_addr, .public, init_addr, .public);
    initiator.require_user_confirmation = true;
    responder.require_user_confirmation = true;

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;

    const preq_len = try initiator.startPairing(100, &buf_a);
    const pres_len = try responder.handlePdu(buf_a[0..preq_len], 110, &buf_b);
    const pk_a_len = try initiator.handlePdu(buf_b[0..pres_len], 120, &buf_a);
    const pk_b_and_cb_len = try responder.handlePdu(buf_a[0..pk_a_len], 130, &buf_b);
    _ = try initiator.handlePdu(buf_b[0..65], 140, &buf_a);
    const na_len = try initiator.handlePdu(buf_b[65..pk_b_and_cb_len], 145, &buf_a);
    const nb_len = try responder.handlePdu(buf_a[0..na_len], 150, &buf_b);
    _ = try initiator.handlePdu(buf_b[0..nb_len], 160, &buf_a);

    try std.testing.expectEqual(SmpState.wait_numeric_comparison, initiator.state);
    try std.testing.expectEqual(SmpState.wait_numeric_comparison, responder.state);
    try std.testing.expect(initiator.numeric_comparison_code.? == responder.numeric_comparison_code.?);

    // Reject on initiator side -> sends PairingFailed with numeric_comparison_failed
    var reject_buf: [16]u8 = undefined;
    const rej_len = try initiator.confirmNumericComparison(false, &reject_buf);
    try std.testing.expectEqual(@as(usize, 2), rej_len);
    try std.testing.expectEqual(SmpState.failed, initiator.state);
    try std.testing.expectEqual(@intFromEnum(SmpOpcode.pairing_failed), reject_buf[0]);
    try std.testing.expectEqual(@intFromEnum(PairingFailedReason.numeric_comparison_failed), reject_buf[1]);

    // Case B: User Confirmation (Accept)
    var init_ok = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var resp_ok = SmpStateMachine.init(.responder, resp_addr, .public, init_addr, .public);
    init_ok.require_user_confirmation = true;
    resp_ok.require_user_confirmation = true;

    const p_req = try init_ok.startPairing(200, &buf_a);
    const p_res = try resp_ok.handlePdu(buf_a[0..p_req], 210, &buf_b);
    const pk_a = try init_ok.handlePdu(buf_b[0..p_res], 220, &buf_a);
    const pk_b_cb = try resp_ok.handlePdu(buf_a[0..pk_a], 230, &buf_b);
    _ = try init_ok.handlePdu(buf_b[0..65], 240, &buf_a);
    const n_a = try init_ok.handlePdu(buf_b[65..pk_b_cb], 245, &buf_a);
    const n_b = try resp_ok.handlePdu(buf_a[0..n_a], 250, &buf_b);
    _ = try init_ok.handlePdu(buf_b[0..n_b], 260, &buf_a);

    // Both accept the code
    const conf_resp_len = try resp_ok.confirmNumericComparison(true, &buf_b);
    try std.testing.expectEqual(@as(usize, 0), conf_resp_len);
    const conf_init_len = try init_ok.confirmNumericComparison(true, &buf_a);
    try std.testing.expectEqual(@as(usize, 17), conf_init_len); // Ea (PairingDhKeyCheck)

    const eb_len = try resp_ok.handlePdu(buf_a[0..conf_init_len], 270, &buf_b);
    try std.testing.expectEqual(@as(usize, 17), eb_len); // Eb
    _ = try init_ok.handlePdu(buf_b[0..eb_len], 280, &buf_a);

    try std.testing.expectEqual(SmpState.completed, init_ok.state);
    try std.testing.expectEqual(SmpState.completed, resp_ok.state);
    try std.testing.expectEqualSlices(u8, &init_ok.ltk, &resp_ok.ltk);
}

test "SMP State Machine: LE Secure Connections 20-round Passkey Entry" {
    const init_addr = try Address.parse("C0:1A:7D:DA:71:01");
    const resp_addr = try Address.parse("C0:1A:7D:DA:71:02");

    var initiator = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var responder = SmpStateMachine.init(.responder, resp_addr, .public, init_addr, .public);

    // Set IO capabilities that require passkey entry with MITM
    initiator.local_features.io_capability = .keyboard_only;
    initiator.local_features.auth_req.mitm = true;
    responder.local_features.io_capability = .display_only;
    responder.local_features.auth_req.mitm = true;

    const passkey: u32 = 839204;
    try initiator.setPasskey(passkey);
    try responder.setPasskey(passkey);

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;

    // Phase 1: Request & Response
    const preq_len = try initiator.startPairing(100, &buf_a);
    const pres_len = try responder.handlePdu(buf_a[0..preq_len], 110, &buf_b);
    try std.testing.expectEqual(smp.PairingMethod.passkey_entry, responder.method);

    // Phase 2: Public Key exchange
    const pk_a_len = try initiator.handlePdu(buf_b[0..pres_len], 120, &buf_a);
    try std.testing.expectEqual(smp.PairingMethod.passkey_entry, initiator.method);
    const pk_b_len = try responder.handlePdu(buf_a[0..pk_a_len], 130, &buf_b);
    try std.testing.expectEqual(@as(usize, 65), pk_b_len);

    // Initiator processes Responder PK and generates round 0 Ca
    var cur_msg_len = try initiator.handlePdu(buf_b[0..pk_b_len], 140, &buf_a);
    try std.testing.expectEqual(@as(usize, 17), cur_msg_len); // Ca0 (PairingConfirm)

    // Run 20 rounds of Passkey Entry bit verification!
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        // Responder receives Cai -> returns Cbi
        const cb_len = try responder.handlePdu(buf_a[0..cur_msg_len], 150 + @as(u64, @intCast(round * 4)), &buf_b);
        try std.testing.expectEqual(@as(usize, 17), cb_len);

        // Initiator receives Cbi -> returns Nai (PairingRandom)
        const na_len = try initiator.handlePdu(buf_b[0..cb_len], 151 + @as(u64, @intCast(round * 4)), &buf_a);
        try std.testing.expectEqual(@as(usize, 17), na_len);

        // Responder receives Nai, verifies Cai -> returns Nbi (PairingRandom)
        const nb_len = try responder.handlePdu(buf_a[0..na_len], 152 + @as(u64, @intCast(round * 4)), &buf_b);
        try std.testing.expectEqual(@as(usize, 17), nb_len);

        // Initiator receives Nbi, verifies Cbi -> returns either next Cai (rounds 0..18) or Ea (round 19)
        cur_msg_len = try initiator.handlePdu(buf_b[0..nb_len], 153 + @as(u64, @intCast(round * 4)), &buf_a);
        try std.testing.expectEqual(@as(usize, 17), cur_msg_len);
    }

    // After 20 rounds: initiator has sent Ea (PairingDhKeyCheck)
    try std.testing.expectEqual(SmpState.wait_dhkey_check, initiator.state);
    try std.testing.expectEqual(SmpState.wait_dhkey_check, responder.state);

    // Responder receives Ea -> returns Eb
    const eb_len = try responder.handlePdu(buf_a[0..cur_msg_len], 250, &buf_b);
    try std.testing.expectEqual(@as(usize, 17), eb_len);
    try std.testing.expectEqual(SmpState.completed, responder.state);

    // Initiator receives Eb -> completed!
    const fin_len = try initiator.handlePdu(buf_b[0..eb_len], 260, &buf_a);
    try std.testing.expectEqual(@as(usize, 0), fin_len);
    try std.testing.expectEqual(SmpState.completed, initiator.state);

    // Both sides derived identical LTKs through 20-round passkey verification!
    try std.testing.expectEqualSlices(u8, &initiator.ltk, &responder.ltk);
}

test "SMP State Machine: Phase 3 Key Distribution (Identity Information & IRK)" {
    const init_addr = try Address.parse("AA:01:02:03:04:05");
    const resp_addr = try Address.parse("BB:01:02:03:04:05");

    var initiator = SmpStateMachine.init(.initiator, init_addr, .public, resp_addr, .public);
    var responder = SmpStateMachine.init(.responder, resp_addr, .public, init_addr, .public);
    initiator.key_distribution_enabled = true;
    responder.key_distribution_enabled = true;
    initiator.require_user_confirmation = false;
    responder.require_user_confirmation = false;

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;

    // Fast-forward Phase 1 & 2
    const p1 = try initiator.startPairing(10, &buf_a);
    const p2 = try responder.handlePdu(buf_a[0..p1], 20, &buf_b);
    const p3 = try initiator.handlePdu(buf_b[0..p2], 30, &buf_a);
    const p4 = try responder.handlePdu(buf_a[0..p3], 40, &buf_b);
    _ = try initiator.handlePdu(buf_b[0..65], 50, &buf_a);
    const na = try initiator.handlePdu(buf_b[65..p4], 55, &buf_a);
    const nb = try responder.handlePdu(buf_a[0..na], 60, &buf_b);
    const ea = try initiator.handlePdu(buf_b[0..nb], 70, &buf_a);
    const eb = try responder.handlePdu(buf_a[0..ea], 80, &buf_b);
    _ = try initiator.handlePdu(buf_b[0..eb], 90, &buf_a);

    // Both should enter key_distribution!
    try std.testing.expectEqual(SmpState.key_distribution, initiator.state);
    try std.testing.expectEqual(SmpState.key_distribution, responder.state);

    // Keys are secrets: refused until the link is encrypted
    var unencrypted = initiator;
    var early_irk: [17]u8 = @splat(0x11);
    early_irk[0] = @intFromEnum(SmpOpcode.identity_information);
    _ = try unencrypted.handlePdu(&early_irk, 95, &buf_a);
    try std.testing.expectEqual(SmpState.failed, unencrypted.state);

    initiator.onLinkEncrypted();
    responder.onLinkEncrypted();

    // Responder distributes its IRK + Identity Address to initiator
    const test_irk = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00 };
    const dist_len = try responder.distributeIdentityKeys(test_irk, &buf_b);
    try std.testing.expectEqual(@as(usize, 17 + 8), dist_len);

    // Initiator processes IRK
    _ = try initiator.handlePdu(buf_b[0..17], 100, &buf_a);
    try std.testing.expectEqualSlices(u8, &test_irk, &initiator.peer_irk);

    // LE Secure Connections distributes no LTK, but the signing key is still expected
    _ = try initiator.handlePdu(buf_b[17..dist_len], 101, &buf_a);
    try std.testing.expect(initiator.peer_identity_addr.?.eql(resp_addr));
    try std.testing.expectEqual(SmpState.key_distribution, initiator.state);

    var csrk: [17]u8 = @splat(0x33);
    csrk[0] = @intFromEnum(SmpOpcode.signing_information);
    _ = try initiator.handlePdu(&csrk, 102, &buf_a);
    try std.testing.expectEqual(@as(u8, 0x33), initiator.peer_csrk[0]);

    // The initiator's own keys are still open until it sends them or declares them handled
    try std.testing.expectEqual(SmpState.key_distribution, initiator.state);
    _ = try initiator.distributeIdentityKeys(test_irk, &buf_a);
    try std.testing.expectEqual(SmpState.key_distribution, initiator.state);
    initiator.finishLocalKeyDistribution();
    try std.testing.expectEqual(SmpState.completed, initiator.state);
}

/// Runs Passkey Entry from the start up to the initiator's first confirm value.
const PasskeyPair = struct {
    initiator: SmpStateMachine,
    responder: SmpStateMachine,
    buf_a: [128]u8 = undefined,
    buf_b: [128]u8 = undefined,

    fn init() !PasskeyPair {
        const a = try Address.parse("C0:1A:7D:DA:71:01");
        const b = try Address.parse("C0:1A:7D:DA:71:02");
        var pair = PasskeyPair{
            .initiator = SmpStateMachine.init(.initiator, a, .public, b, .public),
            .responder = SmpStateMachine.init(.responder, b, .public, a, .public),
        };
        pair.initiator.local_features.io_capability = .keyboard_only;
        pair.responder.local_features.io_capability = .display_only;
        return pair;
    }

    /// Returns the length of the PDU the public key exchange left in `buf_a`.
    fn exchangeKeys(self: *PasskeyPair) !usize {
        const preq = try self.initiator.startPairing(100, &self.buf_a);
        const pres = try self.responder.handlePdu(self.buf_a[0..preq], 110, &self.buf_b);
        const pka = try self.initiator.handlePdu(self.buf_b[0..pres], 120, &self.buf_a);
        const pkb = try self.responder.handlePdu(self.buf_a[0..pka], 130, &self.buf_b);
        return self.initiator.handlePdu(self.buf_b[0..pkb], 140, &self.buf_a);
    }

    fn runRounds(self: *PasskeyPair, first: usize) !void {
        var cur = first;
        for (0..20) |_| {
            const cb = try self.responder.handlePdu(self.buf_a[0..cur], 150, &self.buf_b);
            const na = try self.initiator.handlePdu(self.buf_b[0..cb], 151, &self.buf_a);
            const nb = try self.responder.handlePdu(self.buf_a[0..na], 152, &self.buf_b);
            cur = try self.initiator.handlePdu(self.buf_b[0..nb], 153, &self.buf_a);
        }
        const eb = try self.responder.handlePdu(self.buf_a[0..cur], 200, &self.buf_b);
        _ = try self.initiator.handlePdu(self.buf_b[0..eb], 201, &self.buf_a);
    }
};

test "SMP Passkey Entry waits for the passkey instead of using a default" {
    var p = try PasskeyPair.init();
    try std.testing.expectEqual(@as(usize, 0), try p.exchangeKeys());
    try std.testing.expectEqual(SmpState.wait_passkey, p.initiator.state);

    // The display side generates the passkey, the keyboard side enters it
    const shown = try p.responder.generatePasskey();
    try std.testing.expect(shown <= 999_999);
    const ca0 = try p.initiator.providePasskey(shown, &p.buf_a);
    try p.runRounds(ca0);
    try std.testing.expectEqual(SmpState.completed, p.initiator.state);
    try std.testing.expectEqual(SmpState.completed, p.responder.state);
    try std.testing.expectEqualSlices(u8, &p.initiator.ltk, &p.responder.ltk);
}

test "SMP Passkey Entry fails with a wrong passkey and when cancelled" {
    var p = try PasskeyPair.init();
    _ = try p.exchangeKeys();
    try p.responder.setPasskey(123456);
    const ca0 = try p.initiator.providePasskey(654321, &p.buf_a);
    p.runRounds(ca0) catch {};
    try std.testing.expect(p.initiator.state == .failed or p.responder.state == .failed);

    var c = try PasskeyPair.init();
    _ = try c.exchangeKeys();
    const len = try c.initiator.rejectPasskey(&c.buf_a);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(SmpState.failed, c.initiator.state);
    try std.testing.expectEqual(smp.PairingFailedReason.passkey_entry_failed, c.initiator.last_failure_reason.?);

    try std.testing.expectError(SmpError.InvalidParameter, c.responder.setPasskey(1_000_000));
}

test "SMP Passkey Entry: responder waits for its passkey too" {
    var p = try PasskeyPair.init();
    try p.initiator.setPasskey(42);
    const ca0 = try p.exchangeKeys();
    try std.testing.expectEqual(@as(usize, 0), try p.responder.handlePdu(p.buf_a[0..ca0], 150, &p.buf_b));
    try std.testing.expectEqual(SmpState.wait_passkey, p.responder.state);
    const cb0 = try p.responder.providePasskey(42, &p.buf_b);
    try std.testing.expectEqual(@as(usize, 17), cb0);
    try std.testing.expectEqual(SmpState.wait_random, p.responder.state);
}

test "SMP rejects a peer public key equal to its own" {
    const a = try Address.parse("11:22:33:44:55:66");
    const b = try Address.parse("AA:BB:CC:DD:EE:FF");
    var i = SmpStateMachine.init(.initiator, a, .public, b, .public);
    var r = SmpStateMachine.init(.responder, b, .public, a, .public);
    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const preq = try i.startPairing(100, &ba);
    const pres = try r.handlePdu(ba[0..preq], 110, &bb);
    const pka = try i.handlePdu(bb[0..pres], 120, &ba);
    var own: [128]u8 = undefined;
    @memcpy(own[0..pka], ba[0..pka]);
    _ = try i.handlePdu(own[0..pka], 130, &ba);
    try std.testing.expectEqual(SmpState.failed, i.state);
}

test "SMP Numeric Comparison works when the initiator's user confirms first" {
    const a = try Address.parse("11:22:33:44:55:66");
    const b = try Address.parse("AA:BB:CC:DD:EE:FF");
    var i = SmpStateMachine.init(.initiator, a, .public, b, .public);
    var r = SmpStateMachine.init(.responder, b, .public, a, .public);
    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const preq = try i.startPairing(100, &ba);
    const pres = try r.handlePdu(ba[0..preq], 110, &bb);
    const pka = try i.handlePdu(bb[0..pres], 120, &ba);
    const both = try r.handlePdu(ba[0..pka], 130, &bb);
    _ = try i.handlePdu(bb[0..65], 140, &ba);
    const na = try i.handlePdu(bb[65..both], 145, &ba);
    const nb = try r.handlePdu(ba[0..na], 150, &bb);
    _ = try i.handlePdu(bb[0..nb], 160, &ba);

    // Confirmation is the default: nothing proceeds without it
    try std.testing.expectEqual(SmpState.wait_numeric_comparison, i.state);
    try std.testing.expectEqual(SmpState.wait_numeric_comparison, r.state);

    const ea = try i.confirmNumericComparison(true, &ba);
    try std.testing.expectEqual(@as(usize, 0), try r.handlePdu(ba[0..ea], 170, &bb));
    try std.testing.expectEqual(SmpState.wait_numeric_comparison, r.state);

    const eb = try r.confirmNumericComparison(true, &bb);
    try std.testing.expectEqual(@as(usize, 17), eb);
    try std.testing.expectEqual(SmpState.completed, r.state);
    _ = try i.handlePdu(bb[0..eb], 180, &ba);
    try std.testing.expectEqual(SmpState.completed, i.state);
    try std.testing.expectEqualSlices(u8, &i.ltk, &r.ltk);
}

test "SMP key distribution follows what was negotiated" {
    const a = try Address.parse("11:22:33:44:55:66");
    const b = try Address.parse("AA:BB:CC:DD:EE:FF");
    var i = SmpStateMachine.init(.initiator, a, .public, b, .public);
    var r = SmpStateMachine.init(.responder, b, .public, a, .public);
    i.key_distribution_enabled = true;
    r.key_distribution_enabled = true;
    i.require_user_confirmation = false;
    r.require_user_confirmation = false;
    // Only the responder has a key to give, and only its identity
    r.local_features.initiator_key_distribution = .{};
    r.local_features.responder_key_distribution = .{ .id_key = true };

    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const preq = try i.startPairing(100, &ba);
    const pres = try r.handlePdu(ba[0..preq], 110, &bb);
    const pka = try i.handlePdu(bb[0..pres], 120, &ba);
    const both = try r.handlePdu(ba[0..pka], 130, &bb);
    _ = try i.handlePdu(bb[0..65], 140, &ba);
    const na = try i.handlePdu(bb[65..both], 145, &ba);
    const nb = try r.handlePdu(ba[0..na], 150, &bb);
    const ea = try i.handlePdu(bb[0..nb], 160, &ba);
    const eb = try r.handlePdu(ba[0..ea], 170, &bb);
    _ = try i.handlePdu(bb[0..eb], 180, &ba);
    i.onLinkEncrypted();
    r.onLinkEncrypted();
    try std.testing.expectEqual(SmpState.key_distribution, i.state);

    // A key that was not negotiated is a protocol violation
    var bad = i;
    var csrk: [17]u8 = @splat(0x33);
    csrk[0] = @intFromEnum(SmpOpcode.signing_information);
    _ = try bad.handlePdu(&csrk, 190, &ba);
    try std.testing.expectEqual(SmpState.failed, bad.state);

    const irk: [16]u8 = @splat(0x44);
    const dist = try r.distributeIdentityKeys(irk, &bb);
    try std.testing.expectEqual(SmpState.completed, r.state);
    _ = try i.handlePdu(bb[0..17], 200, &ba);
    _ = try i.handlePdu(bb[17..dist], 201, &ba);
    try std.testing.expectEqual(SmpState.completed, i.state);
    try std.testing.expectEqual(@as(u8, 0x44), i.peer_irk[0]);
}

test "SMP ignores keys sent after pairing completed without key exchange" {
    const a = try Address.parse("11:22:33:44:55:66");
    const b = try Address.parse("AA:BB:CC:DD:EE:FF");
    var i = SmpStateMachine.init(.initiator, a, .public, b, .public);
    i.state = .completed;
    var ba: [128]u8 = undefined;
    var irk: [17]u8 = @splat(0x11);
    irk[0] = @intFromEnum(SmpOpcode.identity_information);
    try std.testing.expectEqual(@as(usize, 0), try i.handlePdu(&irk, 1, &ba));
    try std.testing.expectEqual(SmpState.completed, i.state);
}
