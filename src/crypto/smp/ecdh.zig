//! # SMP Cryptographic Primitives & ECDH P-256 Helpers
const std = @import("std");
const types_mod = @import("types.zig");
const pdu_mod = @import("pdu.zig");
const toolbox = @import("../toolbox.zig");
const P256 = std.crypto.ecc.P256;

pub const SmpError = types_mod.SmpError;
pub const IoCapability = types_mod.IoCapability;
pub const AuthReq = types_mod.AuthReq;
pub const PairingMethod = types_mod.PairingMethod;
pub const PairingRequest = pdu_mod.PairingRequest;
pub const PairingResponse = pdu_mod.PairingResponse;

pub const EcdhKeyPair = struct {
    secret_be: [32]u8,
    pub_x_le: [32]u8,
    pub_y_le: [32]u8,
};

/// Generates a FIPS P-256 ECDH keypair via `std.crypto.ecc.P256`.
/// Returns the private scalar in big-endian and the public X, Y coordinates in little-endian wire order.
pub fn generateEcdhKeyPair(secret_override_be: ?[32]u8) SmpError!EcdhKeyPair {
    var secret_be: [32]u8 = undefined;
    if (secret_override_be) |override| {
        secret_be = override;
    } else {
        toolbox.getRandomBytes(&secret_be) catch return SmpError.EntropyUnavailable;
        secret_be[0] &= 0x7F;
        secret_be[31] |= 0x01;
    }

    const pub_pt = P256.basePoint.mul(secret_be, .big) catch return SmpError.InvalidParameter;
    const sec1 = pub_pt.toUncompressedSec1();

    var x_le: [32]u8 = undefined;
    var y_le: [32]u8 = undefined;
    for (0..32) |i| {
        x_le[i] = sec1[32 - i];
        y_le[i] = sec1[64 - i];
    }

    return .{
        .secret_be = secret_be,
        .pub_x_le = x_le,
        .pub_y_le = y_le,
    };
}

/// Computes the 32-byte ECDH P-256 shared secret (DHKey) in little-endian byte order.
/// Validates that the peer public key lies on the P-256 curve via `P256.fromSec1`.
pub fn computeDhKey(local_secret_be: [32]u8, peer_pub_x_le: [32]u8, peer_pub_y_le: [32]u8) SmpError![32]u8 {
    var sec1: [65]u8 = undefined;
    sec1[0] = 0x04;
    for (0..32) |i| {
        sec1[1 + i] = peer_pub_x_le[31 - i];
        sec1[33 + i] = peer_pub_y_le[31 - i];
    }

    const peer_pt = P256.fromSec1(&sec1) catch return SmpError.InvalidParameter;
    const shared_pt = peer_pt.mul(local_secret_be, .big) catch return SmpError.InvalidParameter;
    const shared_sec1 = shared_pt.toUncompressedSec1();

    var dhkey_le: [32]u8 = undefined;
    for (0..32) |i| {
        dhkey_le[i] = shared_sec1[32 - i];
    }
    return dhkey_le;
}

/// Selects the pairing method according to Vol 3, Part H, Section 2.3.5.1.
pub fn selectPairingMethod(
    use_sc: bool,
    init_oob: u8,
    resp_oob: u8,
    init_mitm: bool,
    resp_mitm: bool,
    init_io: IoCapability,
    resp_io: IoCapability,
) PairingMethod {
    if (use_sc) {
        if (init_oob == 0x01 or resp_oob == 0x01) return .oob;
    } else {
        if (init_oob == 0x01 and resp_oob == 0x01) return .oob;
    }
    if (!init_mitm and !resp_mitm) return .just_works;
    if (init_io == .no_input_no_output or resp_io == .no_input_no_output) return .just_works;

    if (use_sc) {
        const init_yes_no = (init_io == .display_yes_no or init_io == .keyboard_display);
        const resp_yes_no = (resp_io == .display_yes_no or resp_io == .keyboard_display);
        if (init_yes_no and resp_yes_no) return .numeric_comparison;
    }
    return .passkey_entry;
}
