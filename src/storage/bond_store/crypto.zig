//! # Bond Store Key Wrapping & Crypto Primitives
const std = @import("std");
const Aes128 = std.crypto.core.aes.Aes128;

/// Fallback key for in-memory images and for the inner layer of the Windows DPAPI blob. It is
/// public (it is in this source file), so it only obfuscates; it is never used for Linux files.
pub const DEFAULT_STORE_WRAP_KEY = [16]u8{
    0x5A, 0x42, 0x4C, 0x45, 0xA5, 0x5A, 0x3C, 0xC3,
    0x96, 0x69, 0x0F, 0xF0, 0x1E, 0xE1, 0x87, 0x78,
};

pub fn deriveSubkeys(master_key: [16]u8) struct { enc_key: [16]u8, mac_key: [16]u8 } {
    const enc_domain = [16]u8{ 'Z', 'B', 'G', 'R', '-', 'A', 'E', 'S', '-', 'C', 'T', 'R', '-', 'K', 'E', 'Y' };
    const mac_domain = [16]u8{ 'Z', 'B', 'G', 'R', '-', 'C', 'M', 'A', 'C', '-', 'T', 'A', 'G', 'K', 'E', 'Y' };

    var enc_key: [16]u8 = undefined;
    var mac_key: [16]u8 = undefined;
    const ctx = Aes128.initEnc(master_key);
    ctx.encrypt(&enc_key, &enc_domain);
    ctx.encrypt(&mac_key, &mac_domain);
    return .{ .enc_key = enc_key, .mac_key = mac_key };
}

pub fn cryptKeyBlock(enc_key: [16]u8, nonce: [16]u8, record_idx: u32, slot_id: u8, in_block: [16]u8) [16]u8 {
    var ctr_block = nonce;
    const prev_ctr = std.mem.readInt(u32, ctr_block[12..16], .little);
    std.mem.writeInt(u32, ctr_block[12..16], prev_ctr +% (record_idx * 4 + slot_id), .little);
    ctr_block[11] ^= slot_id;

    var keystream: [16]u8 = undefined;
    Aes128.initEnc(enc_key).encrypt(&keystream, &ctr_block);

    var out: [16]u8 = undefined;
    for (0..16) |i| {
        out[i] = in_block[i] ^ keystream[i];
    }
    std.crypto.secureZero(u8, &keystream);
    return out;
}

