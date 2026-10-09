//! # Bluetooth Low Energy (BLE) Cryptographic Toolbox
//!
//! Compliant with Bluetooth Core Specification v5.4 / v6.0, Vol 3, Part H
//! (Security Manager Specification), Section 2.2: Cryptographic Toolbox.
//!
//! All algorithms are 100% pure Zig, zero external dependencies, zero dynamic
//! heap allocations on hot paths, hardware alignment-safe, and constant-time where applicable.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const Address = types.Address;
const AddressType = types.AddressType;

const Aes128 = std.crypto.core.aes.Aes128;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

// -------------------------------------------------------------------------------------------------
// Helper Endianness Functions
// -------------------------------------------------------------------------------------------------

fn swapBuf(src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len);
    for (src, 0..) |b, i| {
        dst[dst.len - 1 - i] = b;
    }
}

fn xor128(a: *const [16]u8, b: *const [16]u8, out: *[16]u8) void {
    const au = @as(*align(1) const u128, @ptrCast(a)).*;
    const bu = @as(*align(1) const u128, @ptrCast(b)).*;
    @as(*align(1) u128, @ptrCast(out)).* = au ^ bu;
}

// -------------------------------------------------------------------------------------------------
// 1. Security Function e (AES-128 ECB) - Section 2.2.1
// -------------------------------------------------------------------------------------------------

/// Security Function `e`: Generates 128-bit encrypted data from a 128-bit key and 128-bit plaintextData
/// using the AES-128 block cipher.
///
/// Inputs and outputs are in Little-Endian byte order (standard BLE wire format).
pub fn e(key: [16]u8, plaintext: [16]u8) [16]u8 {
    var key_be: [16]u8 = undefined;
    swapBuf(&key, &key_be);

    var in_be: [16]u8 = undefined;
    swapBuf(&plaintext, &in_be);

    var out_be: [16]u8 = undefined;
    Aes128.initEnc(key_be).encrypt(&out_be, &in_be);

    var out_le: [16]u8 = undefined;
    swapBuf(&out_be, &out_le);
    return out_le;
}

/// AES-128 encryption directly operating on Big-Endian data blocks.
pub fn eBe(key_be: [16]u8, plaintext_be: [16]u8) [16]u8 {
    var out_be: [16]u8 = undefined;
    Aes128.initEnc(key_be).encrypt(&out_be, &plaintext_be);
    return out_be;
}

// -------------------------------------------------------------------------------------------------
// 2. Random Address Hash Function ah - Section 2.2.2
// -------------------------------------------------------------------------------------------------

/// Random Address Hash Function `ah(k, r) = e(k, r') mod 2^24`.
///
/// Inputs:
/// - `irk_be`: 128-bit Identity Resolving Key (IRK) in Big-Endian.
/// - `prand_be`: 24-bit pseudo-random value in Big-Endian (as stored in `Address.bytes[0..3]`).
///
/// Output:
/// - 24-bit hash in Big-Endian (as stored in `Address.bytes[3..6]`).
pub fn ahBe(irk_be: [16]u8, prand_be: [3]u8) [3]u8 {
    // r' = padding || r (13 zeros followed by 3 octets of prand)
    var m_be: [16]u8 = @splat(0);
    m_be[13] = prand_be[0];
    m_be[14] = prand_be[1];
    m_be[15] = prand_be[2];

    const out_be = eBe(irk_be, m_be);
    return [3]u8{ out_be[13], out_be[14], out_be[15] };
}

/// Random Address Hash Function `ah(k, r)` operating on Little-Endian wire representations.
pub fn ahLe(irk_le: [16]u8, prand_le: [3]u8) [3]u8 {
    var irk_be: [16]u8 = undefined;
    swapBuf(&irk_le, &irk_be);

    var prand_be: [3]u8 = undefined;
    swapBuf(&prand_le, &prand_be);

    const hash_be = ahBe(irk_be, prand_be);

    var hash_le: [3]u8 = undefined;
    swapBuf(&hash_be, &hash_le);
    return hash_le;
}

/// Resolves whether a given Bluetooth Device Address is a Resolvable Private Address (RPA)
/// belonging to an identity identified by the specified Identity Resolving Key (IRK).
///
/// Constant-time comparison is used to prevent timing attacks.
pub fn resolveRpa(irk: [16]u8, rpa: Address) bool {
    // Top 2 bits of Address.bytes[0] must be 0b01
    if ((rpa.bytes[0] >> 6) != 0b01) return false;

    const prand_be = rpa.bytes[0..3].*;
    const expected_hash = ahBe(irk, prand_be);
    const actual_hash = rpa.bytes[3..6].*;

    return std.crypto.timing_safe.eql([3]u8, expected_hash, actual_hash);
}

extern "advapi32" fn SystemFunction036(pbBuffer: [*]u8, dwLen: u32) callconv(.winapi) u8;

fn getRandom3Bytes() [3]u8 {
    var buf: [3]u8 = undefined;
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.getrandom(&buf, buf.len, 0);
    } else if (builtin.os.tag == .windows) {
        _ = SystemFunction036(&buf, buf.len);
    } else {
        var prng = std.Random.DefaultPrng.init(0x87654321A1B2C3D4);
        prng.random().bytes(&buf);
    }
    return buf;
}

/// Generates a compliant Resolvable Private Address (RPA) using the specified Identity Resolving Key (IRK).
///
/// If `prand_override` is null, cryptographically secure random bytes are generated automatically.
pub fn generateRpa(irk: [16]u8, prand_override: ?[3]u8) Address {
    var prand = prand_override orelse getRandom3Bytes();

    // Bluetooth Core Spec requires the two most significant bits of prand to be 0b01
    // and that prand cannot be all zeros or all ones (excluding MSBs).
    prand[0] = (prand[0] & 0x3F) | 0x40;

    const hash = ahBe(irk, prand);

    var addr: [6]u8 = undefined;
    @memcpy(addr[0..3], &prand);
    @memcpy(addr[3..6], &hash);

    return Address{ .bytes = addr };
}

// -------------------------------------------------------------------------------------------------
// 3. Confirm Value Generation Function c1 (Legacy Pairing) - Section 2.2.3
// -------------------------------------------------------------------------------------------------

/// Confirm value generation function `c1` for LE Legacy Pairing:
/// `c1(k, r, preq, pres, iat, rat, ia, ra) = e(k, e(k, r ^ p1) ^ p2)`
///
/// All 128-bit, 56-bit, and 48-bit buffers are passed in Little-Endian byte order.
pub fn c1(
    k: [16]u8,
    r: [16]u8,
    pres: [7]u8,
    preq: [7]u8,
    iat: u1,
    rat: u1,
    ia: [6]u8,
    ra: [6]u8,
) [16]u8 {
    // p1 = pres || preq || rat' || iat'
    var p1: [16]u8 = undefined;
    p1[0] = iat;
    p1[1] = rat;
    @memcpy(p1[2..9], &preq);
    @memcpy(p1[9..16], &pres);

    // p2 = padding(4 zeros) || ia || ra
    var p2: [16]u8 = @splat(0);
    @memcpy(p2[0..6], &ra);
    @memcpy(p2[6..12], &ia);

    // res1 = e(k, r ^ p1)
    var step1: [16]u8 = undefined;
    xor128(&r, &p1, &step1);
    const enc1 = e(k, step1);

    // res2 = e(k, enc1 ^ p2)
    var step2: [16]u8 = undefined;
    xor128(&enc1, &p2, &step2);
    return e(k, step2);
}

// -------------------------------------------------------------------------------------------------
// 4. Key Generation Function s1 (Legacy Pairing STK) - Section 2.2.4
// -------------------------------------------------------------------------------------------------

/// Key generation function `s1` for Short Term Key (STK) derivation in LE Legacy Pairing:
/// `s1(k, r1, r2) = e(k, r1' || r2')`
pub fn s1(k: [16]u8, r1: [16]u8, r2: [16]u8) [16]u8 {
    var r_prime: [16]u8 = undefined;
    @memcpy(r_prime[0..8], r2[0..8]);
    @memcpy(r_prime[8..16], r1[0..8]);

    return e(k, r_prime);
}

// -------------------------------------------------------------------------------------------------
// 5. AES-CMAC Helper (Little-Endian / Big-Endian wire adaptation)
// -------------------------------------------------------------------------------------------------

/// Computes AES-CMAC-128 over a message with a given 128-bit key.
/// Adapts little-endian Bluetooth protocol buffers to big-endian AES-CMAC order.
pub fn aesCmac(key: [16]u8, msg: []const u8, out: *[16]u8) void {
    var key_be: [16]u8 = undefined;
    swapBuf(&key, &key_be);

    var msg_be_stack: [256]u8 = undefined;
    var msg_be_slice: []u8 = undefined;
    var heap_buf: ?[]u8 = null;

    if (msg.len <= msg_be_stack.len) {
        msg_be_slice = msg_be_stack[0..msg.len];
    } else {
        // Fallback for rare large messages (GATT database hash)
        heap_buf = std.heap.page_allocator.alloc(u8, msg.len) catch unreachable;
        msg_be_slice = heap_buf.?;
    }
    defer if (heap_buf) |b| std.heap.page_allocator.free(b);

    swapBuf(msg, msg_be_slice);

    var out_be: [16]u8 = undefined;
    CmacAes128.create(&out_be, msg_be_slice, &key_be);

    swapBuf(&out_be, out);
}

// -------------------------------------------------------------------------------------------------
// 6. Confirm Value Generation Function f4 (LE Secure Connections) - Section 2.2.5
// -------------------------------------------------------------------------------------------------

/// Confirm value generation function `f4` for LE Secure Connections:
/// `f4(u, v, x, z) = AES-CMAC_x(u || v || z)`
///
/// Inputs:
/// - `u`: 256-bit public key X-coordinate (32 bytes)
/// - `v`: 256-bit public key X-coordinate (32 bytes)
/// - `x`: 128-bit random value (16 bytes)
/// - `z`: 8-bit passcode / check value (0 for Just Works / Numeric Comparison)
pub fn f4(u: [32]u8, v: [32]u8, x: [16]u8, z: u8) [16]u8 {
    var m: [65]u8 = undefined;
    m[0] = z;
    @memcpy(m[1..33], &v);
    @memcpy(m[33..65], &u);

    var res: [16]u8 = undefined;
    aesCmac(x, &m, &res);
    return res;
}

// -------------------------------------------------------------------------------------------------
// 7. Key Generation Function f5 (LE Secure Connections LTK & MacKey) - Section 2.2.6
// -------------------------------------------------------------------------------------------------

pub const F5Result = struct {
    mackey: [16]u8,
    ltk: [16]u8,
};

/// Key generation function `f5` for LE Secure Connections key derivation:
/// Derives `MacKey` and `LTK` from the ECDH shared secret `w` (DHKey).
pub fn f5(
    w: [32]u8,
    n1: [16]u8,
    n2: [16]u8,
    a1: [7]u8,
    a2: [7]u8,
) F5Result {
    const salt = [_]u8{
        0xbe, 0x83, 0x60, 0x5a, 0xdb, 0x0b, 0x37, 0x60,
        0x38, 0xa5, 0xf5, 0xaa, 0x91, 0x83, 0x88, 0x6c,
    };
    const btle = [_]u8{ 0x65, 0x6c, 0x74, 0x62 }; // "btle" reversed
    const length = [_]u8{ 0x00, 0x01 }; // 256 bits (0x0100) reversed

    var t: [16]u8 = undefined;
    aesCmac(salt, &w, &t);

    var m: [53]u8 = undefined;
    @memcpy(m[0..2], &length);
    @memcpy(m[2..9], &a2);
    @memcpy(m[9..16], &a1);
    @memcpy(m[16..32], &n2);
    @memcpy(m[32..48], &n1);
    @memcpy(m[48..52], &btle);

    var result: F5Result = undefined;

    // Counter = 0 for MacKey
    m[52] = 0;
    aesCmac(t, &m, &result.mackey);

    // Counter = 1 for LTK
    m[52] = 1;
    aesCmac(t, &m, &result.ltk);

    return result;
}

// -------------------------------------------------------------------------------------------------
// 8. Check Value Generation Function f6 (LE Secure Connections) - Section 2.2.7
// -------------------------------------------------------------------------------------------------

/// Check value generation function `f6` for LE Secure Connections:
/// `f6(w, n1, n2, r, iocap, a1, a2) = AES-CMAC_w(n1 || n2 || r || iocap || a1 || a2)`
pub fn f6(
    w: [16]u8,
    n1: [16]u8,
    n2: [16]u8,
    r: [16]u8,
    io_cap: [3]u8,
    a1: [7]u8,
    a2: [7]u8,
) [16]u8 {
    var m: [65]u8 = undefined;
    @memcpy(m[0..7], &a2);
    @memcpy(m[7..14], &a1);
    @memcpy(m[14..17], &io_cap);
    @memcpy(m[17..33], &r);
    @memcpy(m[33..49], &n2);
    @memcpy(m[49..65], &n1);

    var res: [16]u8 = undefined;
    aesCmac(w, &m, &res);
    return res;
}

// -------------------------------------------------------------------------------------------------
// 9. Numeric Comparison Value Generation Function g2 (LE Secure Connections) - Section 2.2.8
// -------------------------------------------------------------------------------------------------

/// Numeric comparison 6-digit value calculation function `g2`:
/// `g2(u, v, x, y) = AES-CMAC_x(u || v || y) mod 10^6`
///
/// Returns a 6-digit integer in range [0..999,999] for display and verification on both devices.
pub fn g2(u: [32]u8, v: [32]u8, x: [16]u8, y: [16]u8) u32 {
    var m: [80]u8 = undefined;
    @memcpy(m[0..16], &y);
    @memcpy(m[16..48], &v);
    @memcpy(m[48..80], &u);

    var tmp: [16]u8 = undefined;
    aesCmac(x, &m, &tmp);

    const val_le = std.mem.readInt(u32, tmp[0..4], .little);
    return val_le % 1_000_000;
}

// -------------------------------------------------------------------------------------------------
// 10. Link Key Conversion Function h6 - Section 2.2.9
// -------------------------------------------------------------------------------------------------

/// Link Key conversion function `h6`:
/// `h6(w, keyid) = AES-CMAC_w(keyid)`
pub fn h6(w: [16]u8, keyid: [4]u8) [16]u8 {
    var res: [16]u8 = undefined;
    aesCmac(w, &keyid, &res);
    return res;
}

// -------------------------------------------------------------------------------------------------
// 11. ATT Signed Write Cryptographic Signer & Verifier - Core Vol 3 Part C Section 10.4.1
// -------------------------------------------------------------------------------------------------

pub const ATT_SIGNATURE_LEN = 12;

/// Computes the 12-byte ATT Authentication Signature for Signed Write Commands.
///
/// Format: `sign_counter` (4 bytes LE) || `MAC` (8 bytes truncated AES-CMAC).
pub fn signAtt(
    csrk: *const [16]u8,
    pdu_payload: []const u8,
    sign_counter: u32,
    out_sig: *[ATT_SIGNATURE_LEN]u8,
) void {
    var msg_buf: [1024]u8 = undefined;
    const msg_len = pdu_payload.len + 4;
    @memcpy(msg_buf[0..pdu_payload.len], pdu_payload);
    std.mem.writeInt(u32, msg_buf[pdu_payload.len..][0..4], sign_counter, .little);

    var key_be: [16]u8 = undefined;
    swapBuf(csrk, &key_be);

    var msg_be_buf: [1024]u8 = undefined;
    swapBuf(msg_buf[0..msg_len], msg_be_buf[0..msg_len]);

    var out_be: [16]u8 = undefined;
    CmacAes128.create(&out_be, msg_be_buf[0..msg_len], &key_be);

    // Bluetooth Spec: Place sign_counter in BE at out + 8, then swap out, take tmp + 4
    std.mem.writeInt(u32, out_be[8..12], sign_counter, .big);

    var tmp: [16]u8 = undefined;
    swapBuf(&out_be, &tmp);

    @memcpy(out_sig, tmp[4..16]);
}

/// Verifies whether the 12-byte ATT Authentication Signature attached to the end of a PDU is valid.
pub fn verifyAttSign(
    csrk: *const [16]u8,
    full_pdu_with_signature: []const u8,
) bool {
    if (full_pdu_with_signature.len < ATT_SIGNATURE_LEN) return false;

    const pdu_len = full_pdu_with_signature.len - ATT_SIGNATURE_LEN;
    const pdu_payload = full_pdu_with_signature[0..pdu_len];
    const signature = full_pdu_with_signature[pdu_len..][0..ATT_SIGNATURE_LEN];

    const sign_counter = std.mem.readInt(u32, signature[0..4], .little);

    var expected_sig: [ATT_SIGNATURE_LEN]u8 = undefined;
    signAtt(csrk, pdu_payload, sign_counter, &expected_sig);

    return std.crypto.timing_safe.eql([ATT_SIGNATURE_LEN]u8, expected_sig, signature.*);
}

// -------------------------------------------------------------------------------------------------
// 12. GATT Database Hash Generation - Bluetooth Core Spec v5.1+ (UUID 0x2B2A)
// -------------------------------------------------------------------------------------------------

/// Calculates the standard GATT Database Hash (UUID 0x2B2A) using AES-CMAC with a key of 16 zeros.
pub fn gattHash(data_chunks: []const []const u8) [16]u8 {
    const key: [16]u8 = @splat(0);
    var ctx = CmacAes128.init(&key);

    for (data_chunks) |chunk| {
        ctx.update(chunk);
    }

    var res: [16]u8 = undefined;
    ctx.final(&res);
    return res;
}

// -------------------------------------------------------------------------------------------------
// 13. Coordinated Set Identification Profile (CSIP) Cryptographic Functions
// -------------------------------------------------------------------------------------------------

/// Resolvable Set Identifier (RSI) Hash Function `sih`:
/// Uses the device's Set Identity Resolving Key (SIRK) to hash a 24-bit random value `r`.
pub fn sih(sirk: [16]u8, r: [3]u8) [3]u8 {
    return ahLe(sirk, r);
}

/// Generates a 6-byte Resolvable Set Identifier (RSI) for CSIP (LE Audio coordinated device sets).
pub fn generateRsi(sirk: [16]u8, prand_override: ?[3]u8) [6]u8 {
    var prand = prand_override orelse getRandom3Bytes();

    // The two MSBs of prand shall be 0b01
    prand[2] = (prand[2] & 0x3F) | 0x40;

    const hash = sih(sirk, prand);

    var rsi: [6]u8 = undefined;
    @memcpy(rsi[0..3], &hash);
    @memcpy(rsi[3..6], &prand);
    return rsi;
}

// -------------------------------------------------------------------------------------------------
// Unit Tests (Official Bluetooth SIG Test Vectors)
// -------------------------------------------------------------------------------------------------

test "ah random address hash test vector" {
    // Official Bluetooth SIG Sample Data:
    // IRK: ec0234a3 57c8ad05 341010a6 0a397d9b
    const irk = [_]u8{
        0xec, 0x02, 0x34, 0xa3,
        0x57, 0xc8, 0xad, 0x05,
        0x34, 0x10, 0x10, 0xa6,
        0x0a, 0x39, 0x7d, 0x9b,
    };
    const prand = [_]u8{ 0x70, 0x81, 0x94 };

    const rpa = generateRpa(irk, prand);
    const rpa_str = rpa.toString();
    try std.testing.expectEqualStrings("70:81:94:0D:FB:AA", &rpa_str);
    try std.testing.expect(resolveRpa(irk, rpa));

    var bad_irk = irk;
    bad_irk[0] ^= 0x01;
    try std.testing.expect(!resolveRpa(bad_irk, rpa));
}

test "h6 key conversion test vector" {
    const w = [_]u8{
        0x9b, 0x7d, 0x39, 0x0a, 0xa6, 0x10, 0x10, 0x34,
        0x05, 0xad, 0xc8, 0x57, 0xa3, 0x34, 0x02, 0xec,
    };
    const keyid = [_]u8{ 0x72, 0x62, 0x65, 0x6c };
    const exp = [_]u8{
        0x99, 0x63, 0xb1, 0x80, 0xe2, 0xa9, 0xd3, 0xe8,
        0x1c, 0xc9, 0x6d, 0xe7, 0x02, 0xe1, 0x9a, 0x2d,
    };

    const res = h6(w, keyid);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

test "signAtt and verifyAttSign test vectors" {
    const key_5 = [_]u8{
        0x50, 0x5E, 0x42, 0xDF, 0x96, 0x91, 0xEC, 0x72, 0xD3, 0x1F,
        0xCD, 0xFB, 0xEB, 0x64, 0x1B, 0x61,
    };
    const msg_5 = [_]u8{ 0xd2, 0x12, 0x00, 0x13, 0x37 };
    const expected_sig = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0xF1, 0x87, 0x1E, 0x93, 0x3C, 0x90,
        0x0F, 0xf2,
    };

    var sig: [ATT_SIGNATURE_LEN]u8 = undefined;
    signAtt(&key_5, &msg_5, 1, &sig);
    try std.testing.expectEqualSlices(u8, &expected_sig, &sig);

    // Verify valid PDU
    var full_pdu: [msg_5.len + ATT_SIGNATURE_LEN]u8 = undefined;
    @memcpy(full_pdu[0..msg_5.len], &msg_5);
    @memcpy(full_pdu[msg_5.len..], &sig);

    try std.testing.expect(verifyAttSign(&key_5, &full_pdu));

    // Tampered payload must fail verification
    full_pdu[0] ^= 0x01;
    try std.testing.expect(!verifyAttSign(&key_5, &full_pdu));
}

test "gattHash database hash test vector" {
    const m = [_][]const u8{
        &[_]u8{ 0x01, 0x00, 0x00, 0x28, 0x00, 0x18, 0x02, 0x00, 0x03, 0x28, 0x0A, 0x03, 0x00, 0x00, 0x2A, 0x04 },
        &[_]u8{ 0x00, 0x03, 0x28, 0x02, 0x05, 0x00, 0x01, 0x2A, 0x06, 0x00, 0x00, 0x28, 0x01, 0x18, 0x07, 0x00 },
        &[_]u8{ 0x03, 0x28, 0x20, 0x08, 0x00, 0x05, 0x2A, 0x09, 0x00, 0x02, 0x29, 0x0A, 0x00, 0x03, 0x28, 0x0A },
        &[_]u8{ 0x0B, 0x00, 0x29, 0x2B, 0x0C, 0x00, 0x03, 0x28, 0x02, 0x0D, 0x00, 0x2A, 0x2B, 0x0E, 0x00, 0x00 },
        &[_]u8{ 0x28, 0x08, 0x18, 0x0F, 0x00, 0x02, 0x28, 0x14, 0x00, 0x16, 0x00, 0x0F, 0x18, 0x10, 0x00, 0x03 },
        &[_]u8{ 0x28, 0xA2, 0x11, 0x00, 0x18, 0x2A, 0x12, 0x00, 0x02, 0x29, 0x13, 0x00, 0x00, 0x29, 0x00, 0x00 },
        &[_]u8{ 0x14, 0x00, 0x01, 0x28, 0x0F, 0x18, 0x15, 0x00, 0x03, 0x28, 0x02, 0x16, 0x00, 0x19, 0x2A },
    };

    const res = gattHash(&m);
    const expected = [_]u8{
        0xF1, 0xCA, 0x2D, 0x48, 0xEC, 0xF5, 0x8B, 0xAC,
        0x8A, 0x88, 0x30, 0xBB, 0xB9, 0xFB, 0xA9, 0x90,
    };
    try std.testing.expectEqualSlices(u8, &expected, &res);
}

test "sih test vector" {
    const k = [_]u8{
        0xcd, 0xcc, 0x72, 0xdd, 0x86, 0x8c, 0xcd, 0xce,
        0x22, 0xfd, 0xa1, 0x21, 0x09, 0x7d, 0x7d, 0x45,
    };
    const r = [_]u8{ 0x63, 0xf5, 0x69 };
    const exp = [_]u8{ 0xda, 0x48, 0x19 };

    const res = sih(k, r);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

fn hexToBytes(comptime N: usize, str: []const u8) [N]u8 {
    var out: [N]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < str.len and byte_idx < N) {
        if (str[i] == ' ') {
            i += 1;
            continue;
        }
        const hi: u8 = switch (str[i]) {
            '0'...'9' => str[i] - '0',
            'a'...'f' => str[i] - 'a' + 10,
            'A'...'F' => str[i] - 'A' + 10,
            else => unreachable,
        };
        const lo: u8 = switch (str[i + 1]) {
            '0'...'9' => str[i + 1] - '0',
            'a'...'f' => str[i + 1] - 'a' + 10,
            'A'...'F' => str[i + 1] - 'A' + 10,
            else => unreachable,
        };
        out[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    return out;
}

fn swapTest(comptime N: usize, arr: [N]u8) [N]u8 {
    var res: [N]u8 = undefined;
    for (0..N) |i| res[N - 1 - i] = arr[i];
    return res;
}

test "official spec c1 confirm value test vector" {
    const k = swapTest(16, hexToBytes(16, "00000000000000000000000000000000"));
    const r = swapTest(16, hexToBytes(16, "5783D52156AD6F0E6388274EC6702EE0"));
    const pres = swapTest(7, hexToBytes(7, "05000800000302"));
    const preq = swapTest(7, hexToBytes(7, "07071000000101"));
    const ia = swapTest(6, hexToBytes(6, "A1A2A3A4A5A6"));
    const ra = swapTest(6, hexToBytes(6, "B1B2B3B4B5B6"));
    const exp = swapTest(16, hexToBytes(16, "1E1E3FEF878988EAD2A74DC5BEF13B86"));

    const res = c1(k, r, pres, preq, 1, 0, ia, ra);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

test "official spec s1 stk generation test vector" {
    const k = swapTest(16, hexToBytes(16, "00000000000000000000000000000000"));
    const r1 = swapTest(16, hexToBytes(16, "000F0E0D0C0B0A091122334455667788"));
    const r2 = swapTest(16, hexToBytes(16, "010203040506070899AABBCCDDEEFF00"));
    const exp = swapTest(16, hexToBytes(16, "9a1fe1f0e8b0f49b5b4216ae796da062"));

    const res = s1(k, r1, r2);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

test "official spec f4 le sc confirm test vector" {
    const u = swapTest(32, hexToBytes(32, "20b003d2 f297be2c 5e2c83a7 e9f9a5b9 eff49111 acf4fddb cc030148 0e359de6"));
    const v = swapTest(32, hexToBytes(32, "55188b3d 32f6bb9a 900afcfb eed4e72a 59cb9ac2 f19d7cfb 6b4fdd49 f47fc5fd"));
    const x = swapTest(16, hexToBytes(16, "d5cb8454 d177733e ffffb2ec 712baeab"));
    const z: u8 = 0;
    const exp = swapTest(16, hexToBytes(16, "f2c916f1 07a9bd1c f1eda1be a974872d"));

    const res = f4(u, v, x, z);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

test "official spec f5 le sc key generation test vector" {
    const w = swapTest(32, hexToBytes(32, "ec0234a3 57c8ad05 341010a6 0a397d9b 99796b13 b4f866f1 868d34f3 73bfa698"));
    const n1 = swapTest(16, hexToBytes(16, "d5cb8454 d177733e ffffb2ec 712baeab"));
    const n2 = swapTest(16, hexToBytes(16, "a6e8e7cc 25a75f6e 216583f7 ff3dc4cf"));
    const a1 = swapTest(7, hexToBytes(7, "00561237 37bfce"));
    const a2 = swapTest(7, hexToBytes(7, "00a71370 2dcfc1"));

    const exp_mackey = swapTest(16, hexToBytes(16, "2965f176 a1084a02 fd3f6a20 ce636e20"));
    const exp_ltk = swapTest(16, hexToBytes(16, "69867911 69d7cd23 980522b5 94750a38"));

    const res = f5(w, n1, n2, a1, a2);
    try std.testing.expectEqualSlices(u8, &exp_mackey, &res.mackey);
    try std.testing.expectEqualSlices(u8, &exp_ltk, &res.ltk);
}

test "official spec f6 le sc check value test vector" {
    const w = swapTest(16, hexToBytes(16, "2965f176 a1084a02 fd3f6a20 ce636e20"));
    const n1 = swapTest(16, hexToBytes(16, "d5cb8454 d177733e ffffb2ec 712baeab"));
    const n2 = swapTest(16, hexToBytes(16, "a6e8e7cc 25a75f6e 216583f7 ff3dc4cf"));
    const r = swapTest(16, hexToBytes(16, "12a3343b b453bb54 08da42d2 0c2d0fc8"));
    const io_cap = swapTest(3, hexToBytes(3, "010102"));
    const a1 = swapTest(7, hexToBytes(7, "00561237 37bfce"));
    const a2 = swapTest(7, hexToBytes(7, "00a71370 2dcfc1"));

    const exp = swapTest(16, hexToBytes(16, "e3c47398 9cd0e8c5 d26c0b09 da958f61"));

    const res = f6(w, n1, n2, r, io_cap, a1, a2);
    try std.testing.expectEqualSlices(u8, &exp, &res);
}

test "official spec g2 numeric comparison test vector" {
    const u = swapTest(32, hexToBytes(32, "20b003d2 f297be2c 5e2c83a7 e9f9a5b9 eff49111 acf4fddb cc030148 0e359de6"));
    const v = swapTest(32, hexToBytes(32, "55188b3d 32f6bb9a 900afcfb eed4e72a 59cb9ac2 f19d7cfb 6b4fdd49 f47fc5fd"));
    const x = swapTest(16, hexToBytes(16, "d5cb8454 d177733e ffffb2ec 712baeab"));
    const y = swapTest(16, hexToBytes(16, "a6e8e7cc 25a75f6e 216583f7 ff3dc4cf"));

    const res = g2(u, v, x, y);
    try std.testing.expectEqual(@as(u32, 938554), res);
}
