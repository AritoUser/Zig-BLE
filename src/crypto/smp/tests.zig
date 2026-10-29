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
