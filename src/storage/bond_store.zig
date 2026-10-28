//! # Zig-BLE Security & Bond Store
//!
//! Implements Bluetooth GAP/SMP Bond Storage and Client Characteristic Configuration
//! Descriptor (CCCD) state persistence across connections and device restarts
//! according to Bluetooth Core Specification Vol 3, Part C & Part H.
//!
//! Security Hardening:
//! - Keys (LTK, IRK, CSRK) are never serialized in plaintext (AES-128-CTR key wrapping).
//! - Full-image integrity protection via constant-time AES-CMAC-128 verification.
//! - OS-level protection on disk: Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`)
//!   and Linux `0600` (`S_IRUSR | S_IWUSR`) owner-only file mode enforcement.
//! - Linux file persistence requires an explicit store key (`initWithKey` or `initWithKeyFile`);
//!   the built-in default key is only used for in-memory images and inside the DPAPI blob.
//! - Images from v1.2.x (plaintext keys, no MAC) are rejected with `error.LegacyFormat` and can be
//!   imported once via `deserializeLegacy`.
//! - Atomic persistence via write-to-temp-file + flush + atomic rename.

const std = @import("std");
const builtin = @import("builtin");
const core_types = @import("../core/types.zig");
const toolbox = @import("../crypto/toolbox.zig");
pub const Address = core_types.Address;
pub const AddressType = core_types.AddressType;

const Aes128 = std.crypto.core.aes.Aes128;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

pub const BondStoreError = error{
    BondStoreFull,
    BufferTooSmall,
    InvalidData,
    InvalidMagic,
    IntegrityCheckFailed,
    UnexpectedEof,
    EncryptionFailed,
    DecryptionFailed,
    InsecureFilePermissions,
    IoError,
    EntropyUnavailable,
    /// Linux file persistence was requested without an explicit store key.
    EncryptionKeyRequired,
    /// The image is a v1.2.x plaintext bond store; import it with `deserializeLegacy`.
    LegacyFormat,
};

/// Cryptographic security keys exchanged during SMP Pairing / Bonding.
pub const SecurityKeys = struct {
    /// Long Term Key (128-bit) for link-layer AES-CCM encryption.
    ltk: [16]u8 = @splat(0),
    /// Random 64-bit value used in legacy pairing.
    rand: u64 = 0,
    /// Encrypted Diversifier (16-bit).
    ediv: u16 = 0,
    /// Identity Resolving Key (128-bit) to resolve Private Resolvable Addresses (RPA).
    irk: ?[16]u8 = null,
    /// Connection Signature Resolving Key (128-bit) for signed write data.
    csrk: ?[16]u8 = null,
    /// Whether the key was authenticated via Passkey / Numeric Comparison (MITM protection).
    authenticated: bool = false,
    /// Key size in bytes (typically 16).
    key_size: u8 = 16,

    pub fn secureZero(self: *SecurityKeys) void {
        std.crypto.secureZero(u8, &self.ltk);
        if (self.irk) |*irk| std.crypto.secureZero(u8, irk);
        if (self.csrk) |*csrk| std.crypto.secureZero(u8, csrk);
        self.rand = 0;
        self.ediv = 0;
    }
};

/// Maximum cached CCCD entries per bonded device in static storage.
pub const MAX_CCCDS_PER_DEVICE: usize = 16;

/// Entry storing the CCCD state (Notify 0x0001, Indicate 0x0002) for a specific handle.
pub const CccdEntry = struct {
    handle: u16,
    value: u16,
};

/// A complete bond record for a peer device.
pub const BondRecord = struct {
    address: Address,
    address_type: AddressType = .public,
    keys: SecurityKeys,
    cccds: [MAX_CCCDS_PER_DEVICE]CccdEntry = @splat(.{ .handle = 0, .value = 0 }),
    cccd_count: usize = 0,

    pub fn setCccd(self: *BondRecord, handle: u16, value: u16) void {
        for (self.cccds[0..self.cccd_count]) |*entry| {
            if (entry.handle == handle) {
                entry.value = value;
                return;
            }
        }
        if (self.cccd_count < MAX_CCCDS_PER_DEVICE) {
            self.cccds[self.cccd_count] = .{ .handle = handle, .value = value };
            self.cccd_count += 1;
        }
    }

    pub fn getCccd(self: *const BondRecord, handle: u16) u16 {
        for (self.cccds[0..self.cccd_count]) |entry| {
            if (entry.handle == handle) return entry.value;
        }
        return 0; // Default: disabled
    }

    pub fn clearCccds(self: *BondRecord) void {
        self.cccd_count = 0;
    }
};

/// Abstract polymorphic interface for bond storage.
pub const BondStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        saveBond: *const fn (ctx: *anyopaque, record: BondRecord) BondStoreError!void,
        loadBond: *const fn (ctx: *anyopaque, addr: Address) ?BondRecord,
        deleteBond: *const fn (ctx: *anyopaque, addr: Address) BondStoreError!void,
        saveCccd: *const fn (ctx: *anyopaque, addr: Address, handle: u16, value: u16) BondStoreError!void,
        loadCccd: *const fn (ctx: *anyopaque, addr: Address, handle: u16) u16,
        clearCccds: *const fn (ctx: *anyopaque, addr: Address) BondStoreError!void,
        getBondCount: *const fn (ctx: *anyopaque) usize,
    };

    pub fn saveBond(self: BondStore, record: BondRecord) BondStoreError!void {
        return self.vtable.saveBond(self.ptr, record);
    }

    pub fn loadBond(self: BondStore, addr: Address) ?BondRecord {
        return self.vtable.loadBond(self.ptr, addr);
    }

    pub fn deleteBond(self: BondStore, addr: Address) BondStoreError!void {
        return self.vtable.deleteBond(self.ptr, addr);
    }

    pub fn saveCccd(self: BondStore, addr: Address, handle: u16, value: u16) BondStoreError!void {
        return self.vtable.saveCccd(self.ptr, addr, handle, value);
    }

    pub fn loadCccd(self: BondStore, addr: Address, handle: u16) u16 {
        return self.vtable.loadCccd(self.ptr, addr, handle);
    }

    pub fn clearCccds(self: BondStore, addr: Address) BondStoreError!void {
        return self.vtable.clearCccds(self.ptr, addr);
    }

    pub fn getBondCount(self: BondStore) usize {
        return self.vtable.getBondCount(self.ptr);
    }
};

// -------------------------------------------------------------------------------------------------
// Windows DPAPI & Win32 Atomic File Helpers
// -------------------------------------------------------------------------------------------------

const DATA_BLOB = extern struct {
    cbData: u32,
    pbData: [*]u8,
};

const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;

extern "crypt32" fn CryptProtectData(
    pDataIn: *const DATA_BLOB,
    szDataDescr: ?[*:0]const u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) i32;

extern "crypt32" fn CryptUnprotectData(
    pDataIn: *const DATA_BLOB,
    ppszDataDescr: ?*?[*:0]u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) i32;

extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn WriteFile(
    hFile: *anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn ReadFile(
    hFile: *anyopaque,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn FlushFileBuffers(hFile: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExA(
    lpExistingFileName: [*:0]const u8,
    lpNewFileName: [*:0]const u8,
    dwFlags: u32,
) callconv(.winapi) i32;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
const INVALID_HANDLE_VALUE_INT: usize = std.math.maxInt(usize);

/// Protects data using Windows DPAPI (`CryptProtectData` bound to current user credentials).
pub fn dpapiProtect(in_data: []const u8, out_buf: []u8) BondStoreError!usize {
    if (builtin.os.tag != .windows) return error.EncryptionFailed;
    if (in_data.len == 0 or in_data.len > std.math.maxInt(u32)) return error.InvalidData;

    const in_blob = DATA_BLOB{
        .cbData = @intCast(in_data.len),
        .pbData = @constCast(in_data.ptr),
    };
    var out_blob: DATA_BLOB = .{ .cbData = 0, .pbData = undefined };

    if (CryptProtectData(&in_blob, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) == 0) {
        return error.EncryptionFailed;
    }
    defer _ = LocalFree(@ptrCast(out_blob.pbData));

    const protected_len: usize = out_blob.cbData;
    if (protected_len > out_buf.len) return error.BufferTooSmall;

    @memcpy(out_buf[0..protected_len], out_blob.pbData[0..protected_len]);
    return protected_len;
}

/// Unprotects data encrypted with Windows DPAPI (`CryptUnprotectData`).
pub fn dpapiUnprotect(in_data: []const u8, out_buf: []u8) BondStoreError!usize {
    if (builtin.os.tag != .windows) return error.DecryptionFailed;
    if (in_data.len == 0 or in_data.len > std.math.maxInt(u32)) return error.InvalidData;

    const in_blob = DATA_BLOB{
        .cbData = @intCast(in_data.len),
        .pbData = @constCast(in_data.ptr),
    };
    var out_blob: DATA_BLOB = .{ .cbData = 0, .pbData = undefined };

    if (CryptUnprotectData(&in_blob, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) == 0) {
        return error.DecryptionFailed;
    }
    defer {
        std.crypto.secureZero(u8, out_blob.pbData[0..out_blob.cbData]);
        _ = LocalFree(@ptrCast(out_blob.pbData));
    }

    const plain_len: usize = out_blob.cbData;
    if (plain_len > out_buf.len) return error.BufferTooSmall;

    @memcpy(out_buf[0..plain_len], out_blob.pbData[0..plain_len]);
    return plain_len;
}

// -------------------------------------------------------------------------------------------------
// Internal Key Wrapping & Integrity Helpers
// -------------------------------------------------------------------------------------------------

/// Fallback key for in-memory images and for the inner layer of the Windows DPAPI blob. It is
/// public (it is in this source file), so it only obfuscates; it is never used for Linux files.
const DEFAULT_STORE_WRAP_KEY = [16]u8{
    0x5A, 0x42, 0x4C, 0x45, 0xA5, 0x5A, 0x3C, 0xC3,
    0x96, 0x69, 0x0F, 0xF0, 0x1E, 0xE1, 0x87, 0x78,
};

fn deriveSubkeys(master_key: [16]u8) struct { enc_key: [16]u8, mac_key: [16]u8 } {
    const enc_domain = [16]u8{ 'Z', 'B', 'G', 'R', '-', 'A', 'E', 'S', '-', 'C', 'T', 'R', '-', 'K', 'E', 'Y' };
    const mac_domain = [16]u8{ 'Z', 'B', 'G', 'R', '-', 'C', 'M', 'A', 'C', '-', 'T', 'A', 'G', 'K', 'E', 'Y' };

    var enc_key: [16]u8 = undefined;
    var mac_key: [16]u8 = undefined;
    const ctx = Aes128.initEnc(master_key);
    ctx.encrypt(&enc_key, &enc_domain);
    ctx.encrypt(&mac_key, &mac_domain);
    return .{ .enc_key = enc_key, .mac_key = mac_key };
}

fn cryptKeyBlock(enc_key: [16]u8, nonce: [16]u8, record_idx: u32, slot_id: u8, in_block: [16]u8) [16]u8 {
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

/// Loads the 16-byte store key from `path`, or creates it with fresh random bytes and mode `0600`
/// if it does not exist yet. An existing key file readable by group or others is rejected.
/// Linux only; on other targets this returns `error.IoError`.
pub fn loadOrCreateKeyFile(path: [:0]const u8) BondStoreError![16]u8 {
    if (builtin.os.tag != .linux) return error.IoError;
    const linux = std.os.linux;

    var key: [16]u8 = undefined;
    const open_rc = std.posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (std.posix.errno(open_rc)) {
        .SUCCESS => {
            const fd: std.posix.fd_t = @intCast(open_rc);
            defer _ = std.posix.system.close(fd);

            var stx: linux.Statx = undefined;
            const stx_rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MODE = true }, &stx);
            if (linux.errno(stx_rc) != .SUCCESS) return error.IoError;
            if ((stx.mode & 0o077) != 0) return error.InsecureFilePermissions;

            var total: usize = 0;
            while (total < key.len) {
                const r_rc = std.posix.system.read(fd, key[total..].ptr, key.len - total);
                if (std.posix.errno(r_rc) != .SUCCESS) return error.IoError;
                if (r_rc == 0) return error.InvalidData;
                total += r_rc;
            }
            return key;
        },
        .NOENT => {
            toolbox.getRandomBytes(&key) catch return error.EntropyUnavailable;
            errdefer std.crypto.secureZero(u8, &key);

            const flags = std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
            const create_rc = std.posix.system.open(path.ptr, flags, 0o600);
            if (std.posix.errno(create_rc) != .SUCCESS) return error.IoError;
            const fd: std.posix.fd_t = @intCast(create_rc);
            _ = linux.fchmod(fd, 0o600);

            var total: usize = 0;
            while (total < key.len) {
                const w_rc = std.posix.system.write(fd, key[total..].ptr, key.len - total);
                if (std.posix.errno(w_rc) != .SUCCESS or w_rc == 0) {
                    _ = std.posix.system.close(fd);
                    _ = linux.unlink(path.ptr);
                    return error.IoError;
                }
                total += w_rc;
            }
            _ = linux.fsync(fd);
            _ = std.posix.system.close(fd);
            return key;
        },
        else => return error.IoError,
    }
}

/// High-performance in-memory bond store with zero heap allocations and fixed capacity.
pub fn MemoryBondStore(comptime max_devices: usize) type {
    return struct {
        const Self = @This();

        records: [max_devices]?BondRecord = @splat(null),
        count: usize = 0,
        encryption_key: ?[16]u8 = null,

        pub fn init() Self {
            return .{};
        }

        pub fn initWithKey(key: [16]u8) Self {
            return .{ .encryption_key = key };
        }

        /// Initializes the store with the key from `key_path` (see `loadOrCreateKeyFile`).
        pub fn initWithKeyFile(key_path: [:0]const u8) BondStoreError!Self {
            return initWithKey(try loadOrCreateKeyFile(key_path));
        }

        /// Securely wipes all stored keys and master encryption key from memory.
        pub fn deinit(self: *Self) void {
            for (&self.records) |*slot| {
                if (slot.*) |*rec| {
                    rec.keys.secureZero();
                    slot.* = null;
                }
            }
            if (self.encryption_key) |*k| {
                std.crypto.secureZero(u8, k);
                self.encryption_key = null;
            }
            self.count = 0;
        }

        /// Configures a 128-bit master encryption key used for key wrapping and MAC authentication.
        pub fn setEncryptionKey(self: *Self, key: [16]u8) void {
            self.encryption_key = key;
        }

        fn effectiveMasterKey(self: *const Self) [16]u8 {
            return self.encryption_key orelse DEFAULT_STORE_WRAP_KEY;
        }

        pub fn save(self: *Self, record: BondRecord) BondStoreError!void {
            for (&self.records) |*slot| {
                if (slot.*) |existing| {
                    if (existing.address.eql(record.address)) {
                        slot.* = record;
                        return;
                    }
                }
            }
            for (&self.records) |*slot| {
                if (slot.* == null) {
                    slot.* = record;
                    self.count += 1;
                    return;
                }
            }
            return error.BondStoreFull;
        }

        pub fn load(self: *const Self, addr: Address) ?BondRecord {
            for (self.records) |slot| {
                if (slot) |record| {
                    if (record.address.eql(addr)) return record;
                }
            }
            return null;
        }

        pub fn delete(self: *Self, addr: Address) BondStoreError!void {
            for (&self.records) |*slot| {
                if (slot.*) |*record| {
                    if (record.address.eql(addr)) {
                        record.keys.secureZero();
                        slot.* = null;
                        self.count -= 1;
                        return;
                    }
                }
            }
        }

        pub fn setCccd(self: *Self, addr: Address, handle: u16, value: u16) BondStoreError!void {
            for (&self.records) |*slot| {
                if (slot.*) |*record| {
                    if (record.address.eql(addr)) {
                        record.setCccd(handle, value);
                        return;
                    }
                }
            }
            // Auto-create bond record if device exists
            var record = BondRecord{
                .address = addr,
                .keys = .{},
            };
            record.setCccd(handle, value);
            try self.save(record);
        }

        pub fn getCccd(self: *const Self, addr: Address, handle: u16) u16 {
            if (self.load(addr)) |rec| {
                return rec.getCccd(handle);
            }
            return 0;
        }

        pub fn clearAllCccds(self: *Self, addr: Address) BondStoreError!void {
            for (&self.records) |*slot| {
                if (slot.*) |*record| {
                    if (record.address.eql(addr)) {
                        record.clearCccds();
                        return;
                    }
                }
            }
        }

        pub fn asBondStore(self: *Self) BondStore {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &vtable_impl,
            };
        }

        /// Serializes the bond store into `out_buf` with AES-128-CTR encrypted keys (LTK, IRK, CSRK)
        /// and a trailing 16-byte AES-CMAC integrity tag over the entire image.
        pub fn serialize(self: *const Self, out_buf: []u8) BondStoreError!usize {
            // Header (8) + Nonce (16) + MAC (16) = 40 bytes minimum
            if (out_buf.len < 40) return error.BufferTooSmall;

            var subkeys = deriveSubkeys(self.effectiveMasterKey());
            defer {
                std.crypto.secureZero(u8, &subkeys.enc_key);
                std.crypto.secureZero(u8, &subkeys.mac_key);
            }

            var nonce: [16]u8 = undefined;
            toolbox.getRandomBytes(&nonce) catch return error.EntropyUnavailable;

            @memcpy(out_buf[0..4], "ZBGR");
            std.mem.writeInt(u32, out_buf[4..8], @intCast(self.count), .little);
            @memcpy(out_buf[8..24], &nonce);
            var offset: usize = 24;

            var rec_idx: u32 = 0;
            for (self.records) |slot| {
                if (slot) |rec| {
                    const irk_len: usize = if (rec.keys.irk != null) 16 else 0;
                    const csrk_len: usize = if (rec.keys.csrk != null) 16 else 0;
                    const required = 6 + 1 + 16 + 8 + 2 + 1 + irk_len + 1 + csrk_len + 1 + 1 + 2 + rec.cccd_count * 4;
                    if (offset + required + 16 > out_buf.len) return error.BufferTooSmall;

                    @memcpy(out_buf[offset .. offset + 6], &rec.address.bytes);
                    offset += 6;
                    out_buf[offset] = @intFromEnum(rec.address_type);
                    offset += 1;

                    // Encrypt LTK (slot 1)
                    const enc_ltk = cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 1, rec.keys.ltk);
                    @memcpy(out_buf[offset .. offset + 16], &enc_ltk);
                    offset += 16;

                    std.mem.writeInt(u64, out_buf[offset..][0..8], rec.keys.rand, .little);
                    offset += 8;
                    std.mem.writeInt(u16, out_buf[offset..][0..2], rec.keys.ediv, .little);
                    offset += 2;

                    // Encrypt IRK (slot 2)
                    if (rec.keys.irk) |irk| {
                        out_buf[offset] = 1;
                        offset += 1;
                        const enc_irk = cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 2, irk);
                        @memcpy(out_buf[offset .. offset + 16], &enc_irk);
                        offset += 16;
                    } else {
                        out_buf[offset] = 0;
                        offset += 1;
                    }

                    // Encrypt CSRK (slot 3)
                    if (rec.keys.csrk) |csrk| {
                        out_buf[offset] = 1;
                        offset += 1;
                        const enc_csrk = cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 3, csrk);
                        @memcpy(out_buf[offset .. offset + 16], &enc_csrk);
                        offset += 16;
                    } else {
                        out_buf[offset] = 0;
                        offset += 1;
                    }

                    out_buf[offset] = if (rec.keys.authenticated) 1 else 0;
                    offset += 1;
                    out_buf[offset] = rec.keys.key_size;
                    offset += 1;

                    std.mem.writeInt(u16, out_buf[offset..][0..2], @intCast(rec.cccd_count), .little);
                    offset += 2;
                    for (rec.cccds[0..rec.cccd_count]) |entry| {
                        std.mem.writeInt(u16, out_buf[offset..][0..2], entry.handle, .little);
                        offset += 2;
                        std.mem.writeInt(u16, out_buf[offset..][0..2], entry.value, .little);
                        offset += 2;
                    }

                    rec_idx += 1;
                }
            }

            // Compute and append 16-byte AES-CMAC integrity tag over out_buf[0..offset]
            var mac_tag: [16]u8 = undefined;
            CmacAes128.create(&mac_tag, out_buf[0..offset], &subkeys.mac_key);
            @memcpy(out_buf[offset .. offset + 16], &mac_tag);
            offset += 16;

            return offset;
        }

        /// Deserializes a bond store image after verifying the magic header and constant-time
        /// AES-CMAC-128 integrity tag, decrypting LTK, IRK, and CSRK.
        pub fn deserialize(self: *Self, in_buf: []const u8) BondStoreError!void {
            if (in_buf.len < 8) return error.InvalidData;
            if (!std.mem.eql(u8, in_buf[0..4], "ZBGR")) return error.InvalidMagic;
            if (in_buf.len < 40) return error.IntegrityCheckFailed;

            var subkeys = deriveSubkeys(self.effectiveMasterKey());
            defer {
                std.crypto.secureZero(u8, &subkeys.enc_key);
                std.crypto.secureZero(u8, &subkeys.mac_key);
            }

            const payload_end = in_buf.len - 16;
            const actual_mac = in_buf[payload_end..][0..16].*;
            var expected_mac: [16]u8 = undefined;
            CmacAes128.create(&expected_mac, in_buf[0..payload_end], &subkeys.mac_key);

            if (!std.crypto.timing_safe.eql([16]u8, expected_mac, actual_mac)) {
                if (self.parseLegacy(in_buf, false)) |_| return error.LegacyFormat else |_| {}
                return error.IntegrityCheckFailed;
            }

            const count = std.mem.readInt(u32, in_buf[4..8], .little);
            if (count > max_devices) return error.BondStoreFull;

            const nonce = in_buf[8..24].*;
            var offset: usize = 24;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (offset + 34 > payload_end) return error.UnexpectedEof;
                var rec: BondRecord = .{
                    .address = .{ .bytes = @splat(0) },
                    .keys = .{},
                };
                @memcpy(&rec.address.bytes, in_buf[offset .. offset + 6]);
                offset += 6;
                rec.address_type = switch (in_buf[offset]) {
                    0 => .public,
                    1 => .random,
                    else => return error.InvalidData,
                };
                offset += 1;

                var enc_ltk: [16]u8 = undefined;
                @memcpy(&enc_ltk, in_buf[offset .. offset + 16]);
                rec.keys.ltk = cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 1, enc_ltk);
                offset += 16;

                rec.keys.rand = std.mem.readInt(u64, in_buf[offset..][0..8], .little);
                offset += 8;
                rec.keys.ediv = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                offset += 2;

                const has_irk = in_buf[offset];
                offset += 1;
                if (has_irk == 1) {
                    if (offset + 16 > payload_end) return error.UnexpectedEof;
                    var enc_irk: [16]u8 = undefined;
                    @memcpy(&enc_irk, in_buf[offset .. offset + 16]);
                    rec.keys.irk = cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 2, enc_irk);
                    offset += 16;
                } else if (has_irk == 0) {
                    rec.keys.irk = null;
                } else {
                    return error.InvalidData;
                }

                if (offset + 1 > payload_end) return error.UnexpectedEof;
                const has_csrk = in_buf[offset];
                offset += 1;
                if (has_csrk == 1) {
                    if (offset + 16 > payload_end) return error.UnexpectedEof;
                    var enc_csrk: [16]u8 = undefined;
                    @memcpy(&enc_csrk, in_buf[offset .. offset + 16]);
                    rec.keys.csrk = cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 3, enc_csrk);
                    offset += 16;
                } else if (has_csrk == 0) {
                    rec.keys.csrk = null;
                } else {
                    return error.InvalidData;
                }

                if (offset + 4 > payload_end) return error.UnexpectedEof;
                rec.keys.authenticated = in_buf[offset] == 1;
                offset += 1;
                rec.keys.key_size = in_buf[offset];
                offset += 1;

                const cccd_cnt = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                offset += 2;
                rec.cccd_count = @min(@as(usize, cccd_cnt), MAX_CCCDS_PER_DEVICE);
                var c: usize = 0;
                while (c < cccd_cnt) : (c += 1) {
                    if (offset + 4 > payload_end) return error.UnexpectedEof;
                    const handle = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                    offset += 2;
                    const val = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                    offset += 2;
                    if (c < MAX_CCCDS_PER_DEVICE) {
                        rec.cccds[c] = .{ .handle = handle, .value = val };
                    }
                }
                try self.save(rec);
            }

            if (offset != payload_end) return error.IntegrityCheckFailed;
        }

        /// Imports a v1.2.x bond store image (plaintext keys, no integrity tag). The image is not
        /// authenticated, so only use this once to migrate a file you trust, then persist the
        /// store again with `saveToFile` (or `serialize`) and delete the old file.
        pub fn deserializeLegacy(self: *Self, in_buf: []const u8) BondStoreError!void {
            try self.parseLegacy(in_buf, false);
            try self.parseLegacy(in_buf, true);
        }

        /// Parses the v1.2.x layout. With `commit == false` it only validates the structure,
        /// which must consume the buffer exactly.
        fn parseLegacy(self: *Self, in_buf: []const u8, commit: bool) BondStoreError!void {
            if (in_buf.len < 8) return error.InvalidData;
            if (!std.mem.eql(u8, in_buf[0..4], "ZBGR")) return error.InvalidMagic;
            const count = std.mem.readInt(u32, in_buf[4..8], .little);
            if (count > max_devices) return error.BondStoreFull;
            var offset: usize = 8;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (offset + 34 > in_buf.len) return error.UnexpectedEof;
                var rec: BondRecord = .{
                    .address = .{ .bytes = @splat(0) },
                    .keys = .{},
                };
                @memcpy(&rec.address.bytes, in_buf[offset .. offset + 6]);
                offset += 6;
                rec.address_type = switch (in_buf[offset]) {
                    0 => .public,
                    1 => .random,
                    else => return error.InvalidData,
                };
                offset += 1;
                @memcpy(&rec.keys.ltk, in_buf[offset .. offset + 16]);
                offset += 16;
                rec.keys.rand = std.mem.readInt(u64, in_buf[offset..][0..8], .little);
                offset += 8;
                rec.keys.ediv = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                offset += 2;

                const has_irk = in_buf[offset];
                offset += 1;
                if (has_irk == 1) {
                    if (offset + 16 > in_buf.len) return error.UnexpectedEof;
                    var irk: [16]u8 = undefined;
                    @memcpy(&irk, in_buf[offset .. offset + 16]);
                    rec.keys.irk = irk;
                    offset += 16;
                } else if (has_irk != 0) {
                    return error.InvalidData;
                }

                if (offset + 4 > in_buf.len) return error.UnexpectedEof;
                rec.keys.authenticated = in_buf[offset] == 1;
                offset += 1;
                rec.keys.key_size = in_buf[offset];
                offset += 1;

                const cccd_cnt = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                offset += 2;
                rec.cccd_count = @min(@as(usize, cccd_cnt), MAX_CCCDS_PER_DEVICE);
                var c: usize = 0;
                while (c < cccd_cnt) : (c += 1) {
                    if (offset + 4 > in_buf.len) return error.UnexpectedEof;
                    const handle = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                    offset += 2;
                    const val = std.mem.readInt(u16, in_buf[offset..][0..2], .little);
                    offset += 2;
                    if (c < MAX_CCCDS_PER_DEVICE) {
                        rec.cccds[c] = .{ .handle = handle, .value = val };
                    }
                }
                if (commit) try self.save(rec);
            }

            if (offset != in_buf.len) return error.InvalidData;
        }

        /// Atomically saves the bond store to `path` by writing to `<path>.tmp`, flushing,
        /// and atomically renaming to `path`.
        /// - On Windows: Protects the serialized image with Windows DPAPI (`CryptProtectData`).
        /// - On Linux: Enforces `0600` (`S_IRUSR | S_IWUSR`) file permissions and requires an
        ///   explicit store key (`error.EncryptionKeyRequired` otherwise).
        pub fn saveToFile(self: *const Self, path: [:0]const u8) BondStoreError!void {
            if (path.len == 0 or path.len + 5 > 512) return error.InvalidData;
            if (builtin.os.tag == .linux and self.encryption_key == null) return error.EncryptionKeyRequired;

            var tmp_path_buf: [512]u8 = undefined;
            @memcpy(tmp_path_buf[0..path.len], path);
            @memcpy(tmp_path_buf[path.len .. path.len + 4], ".tmp");
            tmp_path_buf[path.len + 4] = 0;
            const tmp_path: [:0]const u8 = tmp_path_buf[0 .. path.len + 4 :0];

            var raw_buf: [4096]u8 = undefined;
            defer std.crypto.secureZero(u8, &raw_buf);
            const raw_len = try self.serialize(&raw_buf);

            if (builtin.os.tag == .windows) {
                var dpapi_buf: [8192]u8 = undefined;
                const dpapi_len = try dpapiProtect(raw_buf[0..raw_len], &dpapi_buf);

                const handle_opt = CreateFileA(
                    tmp_path.ptr,
                    GENERIC_WRITE,
                    0,
                    null,
                    CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (handle_opt == null or @intFromPtr(handle_opt.?) == INVALID_HANDLE_VALUE_INT) {
                    return error.IoError;
                }
                const handle = handle_opt.?;

                var written: u32 = 0;
                const write_ok = WriteFile(handle, &dpapi_buf, @intCast(dpapi_len), &written, null);
                const flush_ok = FlushFileBuffers(handle);
                _ = CloseHandle(handle);

                if (write_ok == 0 or flush_ok == 0 or written != dpapi_len) {
                    _ = DeleteFileA(tmp_path.ptr);
                    return error.IoError;
                }

                if (MoveFileExA(tmp_path.ptr, path.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0) {
                    _ = DeleteFileA(tmp_path.ptr);
                    return error.IoError;
                }
            } else if (builtin.os.tag == .linux) {
                const flags = std.posix.O{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .TRUNC = true,
                    .CLOEXEC = true,
                };
                const mode: std.posix.mode_t = 0o600;
                const open_rc = std.posix.system.open(tmp_path.ptr, flags, mode);
                if (std.posix.errno(open_rc) != .SUCCESS) return error.IoError;
                const fd: std.posix.fd_t = @intCast(open_rc);

                // Explicitly enforce 0600 even if file existed or umask altered permissions
                _ = std.os.linux.fchmod(fd, 0o600);

                var total_written: usize = 0;
                while (total_written < raw_len) {
                    const w_rc = std.posix.system.write(fd, raw_buf[total_written..raw_len].ptr, raw_len - total_written);
                    if (std.posix.errno(w_rc) != .SUCCESS or w_rc == 0) {
                        _ = std.posix.system.close(fd);
                        _ = std.os.linux.unlink(tmp_path.ptr);
                        return error.IoError;
                    }
                    total_written += w_rc;
                }

                _ = std.os.linux.fsync(fd);
                _ = std.posix.system.close(fd);

                const ren_rc = std.os.linux.rename(tmp_path.ptr, path.ptr);
                if (std.os.linux.errno(ren_rc) != .SUCCESS) {
                    _ = std.os.linux.unlink(tmp_path.ptr);
                    return error.IoError;
                }
            } else {
                return error.IoError;
            }
        }

        /// Loads the bond store from `path`, verifying OS-level security (DPAPI on Windows,
        /// `0600` permission check on Linux) and AES-CMAC-128 integrity.
        pub fn loadFromFile(self: *Self, path: [:0]const u8) BondStoreError!void {
            if (builtin.os.tag == .linux and self.encryption_key == null) return error.EncryptionKeyRequired;
            if (builtin.os.tag == .windows) {
                const handle_opt = CreateFileA(
                    path.ptr,
                    GENERIC_READ,
                    0,
                    null,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (handle_opt == null or @intFromPtr(handle_opt.?) == INVALID_HANDLE_VALUE_INT) {
                    return error.IoError;
                }
                const handle = handle_opt.?;
                defer _ = CloseHandle(handle);

                var dpapi_buf: [8192]u8 = undefined;
                var bytes_read: u32 = 0;
                if (ReadFile(handle, &dpapi_buf, dpapi_buf.len, &bytes_read, null) == 0 or bytes_read == 0) {
                    return error.IoError;
                }

                var raw_buf: [4096]u8 = undefined;
                defer std.crypto.secureZero(u8, &raw_buf);
                const raw_len = try dpapiUnprotect(dpapi_buf[0..bytes_read], &raw_buf);
                try self.deserialize(raw_buf[0..raw_len]);
            } else if (builtin.os.tag == .linux) {
                const flags = std.posix.O{
                    .ACCMODE = .RDONLY,
                    .CLOEXEC = true,
                };
                const open_rc = std.posix.system.open(path.ptr, flags, 0);
                if (std.posix.errno(open_rc) != .SUCCESS) return error.IoError;
                const fd: std.posix.fd_t = @intCast(open_rc);
                defer _ = std.posix.system.close(fd);

                // Verify file is not readable/writable by group or others (must be 0600)
                var stx: std.os.linux.Statx = undefined;
                const stx_rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .MODE = true }, &stx);
                if (std.os.linux.errno(stx_rc) == .SUCCESS) {
                    if ((stx.mode & 0o077) != 0) {
                        return error.InsecureFilePermissions;
                    }
                }

                var raw_buf: [4096]u8 = undefined;
                defer std.crypto.secureZero(u8, &raw_buf);
                var total_read: usize = 0;
                while (total_read < raw_buf.len) {
                    const r_rc = std.posix.system.read(fd, raw_buf[total_read..].ptr, raw_buf.len - total_read);
                    if (std.posix.errno(r_rc) != .SUCCESS) return error.IoError;
                    if (r_rc == 0) break;
                    total_read += r_rc;
                }
                try self.deserialize(raw_buf[0..total_read]);
            } else {
                return error.IoError;
            }
        }

        const vtable_impl = BondStore.VTable{
            .saveBond = struct {
                fn call(ctx: *anyopaque, record: BondRecord) BondStoreError!void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.save(record);
                }
            }.call,
            .loadBond = struct {
                fn call(ctx: *anyopaque, addr: Address) ?BondRecord {
                    const s: *const Self = @ptrCast(@alignCast(ctx));
                    return s.load(addr);
                }
            }.call,
            .deleteBond = struct {
                fn call(ctx: *anyopaque, addr: Address) BondStoreError!void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.delete(addr);
                }
            }.call,
            .saveCccd = struct {
                fn call(ctx: *anyopaque, addr: Address, handle: u16, value: u16) BondStoreError!void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.setCccd(addr, handle, value);
                }
            }.call,
            .loadCccd = struct {
                fn call(ctx: *anyopaque, addr: Address, handle: u16) u16 {
                    const s: *const Self = @ptrCast(@alignCast(ctx));
                    return s.getCccd(addr, handle);
                }
            }.call,
            .clearCccds = struct {
                fn call(ctx: *anyopaque, addr: Address) BondStoreError!void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.clearAllCccds(addr);
                }
            }.call,
            .getBondCount = struct {
                fn call(ctx: *anyopaque) usize {
                    const s: *const Self = @ptrCast(@alignCast(ctx));
                    return s.count;
                }
            }.call,
        };
    };
}

test "MemoryBondStore save, load, and cccd persistence" {
    var store = MemoryBondStore(4).init();
    defer store.deinit();
    const bond_store = store.asBondStore();

    const dev1 = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    const dev2 = Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF } };

    const rec1 = BondRecord{
        .address = dev1,
        .keys = .{
            .ltk = @splat(0x42),
            .authenticated = true,
        },
    };
    try bond_store.saveBond(rec1);
    try std.testing.expectEqual(@as(usize, 1), bond_store.getBondCount());

    // Save CCCDs
    try bond_store.saveCccd(dev1, 0x0012, 0x0001); // Notify enabled
    try bond_store.saveCccd(dev1, 0x0015, 0x0002); // Indicate enabled

    // Verify CCCD retrieval
    try std.testing.expectEqual(@as(u16, 0x0001), bond_store.loadCccd(dev1, 0x0012));
    try std.testing.expectEqual(@as(u16, 0x0002), bond_store.loadCccd(dev1, 0x0015));
    try std.testing.expectEqual(@as(u16, 0x0000), bond_store.loadCccd(dev1, 0x9999)); // Non-existent

    // Load full record
    const loaded = bond_store.loadBond(dev1).?;
    try std.testing.expect(loaded.keys.authenticated);
    try std.testing.expectEqual(@as(u8, 0x42), loaded.keys.ltk[0]);
    try std.testing.expectEqual(@as(u16, 0x0001), loaded.getCccd(0x0012));

    // Delete bond
    try bond_store.deleteBond(dev1);
    try std.testing.expectEqual(@as(usize, 0), bond_store.getBondCount());
    try std.testing.expect(bond_store.loadBond(dev1) == null);
    _ = dev2;
}

test "MemoryBondStore binary serialization encrypts keys and verifies MAC integrity" {
    const dev = Address{ .bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 } };
    var store1 = MemoryBondStore(8).init();
    defer store1.deinit();

    const secret_ltk: [16]u8 = @splat(0x99);
    const secret_irk: [16]u8 = @splat(0x77);
    const secret_csrk: [16]u8 = @splat(0x55);

    var rec = BondRecord{
        .address = dev,
        .keys = .{
            .ltk = secret_ltk,
            .rand = 0x123456789ABCDEF0,
            .ediv = 0x5678,
            .authenticated = true,
            .irk = secret_irk,
            .csrk = secret_csrk,
        },
    };
    rec.setCccd(0x0020, 0x0001);
    try store1.save(rec);

    var bin_buf: [512]u8 = undefined;
    const written = try store1.serialize(&bin_buf);
    try std.testing.expect(written >= 40);

    // Ensure LTK, IRK, CSRK are NOT present in plaintext in the serialized buffer
    try std.testing.expect(std.mem.indexOf(u8, bin_buf[0..written], &secret_ltk) == null);
    try std.testing.expect(std.mem.indexOf(u8, bin_buf[0..written], &secret_irk) == null);
    try std.testing.expect(std.mem.indexOf(u8, bin_buf[0..written], &secret_csrk) == null);

    var store2 = MemoryBondStore(8).init();
    defer store2.deinit();
    try store2.deserialize(bin_buf[0..written]);

    const loaded = store2.load(dev).?;
    try std.testing.expectEqualSlices(u8, &secret_ltk, &loaded.keys.ltk);
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), loaded.keys.rand);
    try std.testing.expectEqual(@as(u16, 0x5678), loaded.keys.ediv);
    try std.testing.expect(loaded.keys.irk != null);
    try std.testing.expectEqualSlices(u8, &secret_irk, &loaded.keys.irk.?);
    try std.testing.expect(loaded.keys.csrk != null);
    try std.testing.expectEqualSlices(u8, &secret_csrk, &loaded.keys.csrk.?);
    try std.testing.expectEqual(@as(u16, 0x0001), loaded.getCccd(0x0020));

    // Tamper with payload byte -> must fail MAC integrity verification
    var tampered = bin_buf;
    tampered[25] ^= 0x01;
    var store3 = MemoryBondStore(8).init();
    try std.testing.expectError(error.IntegrityCheckFailed, store3.deserialize(tampered[0..written]));

    // Tamper with MAC tag byte -> must fail MAC integrity verification
    var tampered_mac = bin_buf;
    tampered_mac[written - 1] ^= 0x80;
    try std.testing.expectError(error.IntegrityCheckFailed, store3.deserialize(tampered_mac[0..written]));

    // Wrong custom encryption key -> must fail MAC integrity verification
    var store_wrong_key = MemoryBondStore(8).initWithKey(@splat(0xAA));
    try std.testing.expectError(error.IntegrityCheckFailed, store_wrong_key.deserialize(bin_buf[0..written]));
}

test "MemoryBondStore atomic file persistence with DPAPI (Windows) / 0600 (Linux)" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return;

    const test_path: [:0]const u8 = "zig-cache-bond-store-test.bin";
    defer {
        if (builtin.os.tag == .windows) {
            _ = DeleteFileA(test_path.ptr);
        } else if (builtin.os.tag == .linux) {
            _ = std.os.linux.unlink(test_path.ptr);
        }
    }

    const dev = Address{ .bytes = [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x01 } };
    var store_out = MemoryBondStore(4).initWithKey(@splat(0x33));
    defer store_out.deinit();

    var rec = BondRecord{
        .address = dev,
        .keys = .{
            .ltk = @splat(0xDE),
            .irk = @splat(0xAD),
            .authenticated = true,
        },
    };
    rec.setCccd(0x0042, 0x0002);
    try store_out.save(rec);

    try store_out.saveToFile(test_path);

    var store_in = MemoryBondStore(4).initWithKey(@splat(0x33));
    defer store_in.deinit();
    try store_in.loadFromFile(test_path);

    const restored = store_in.load(dev).?;
    try std.testing.expectEqual(@as(u8, 0xDE), restored.keys.ltk[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), restored.keys.irk.?[0]);
    try std.testing.expect(restored.keys.authenticated);
    try std.testing.expectEqual(@as(u16, 0x0002), restored.getCccd(0x0042));
}

test "MemoryBondStore detects and imports v1.2.x legacy images" {
    // v1.2.x layout: "ZBGR", count, then per record: addr, type, LTK, rand, ediv, IRK flag (+IRK),
    // authenticated, key_size, CCCD count, CCCD entries. No nonce, no MAC, keys in plaintext.
    var legacy: [64]u8 = undefined;
    @memcpy(legacy[0..4], "ZBGR");
    std.mem.writeInt(u32, legacy[4..8], 1, .little);
    var o: usize = 8;
    @memcpy(legacy[o .. o + 6], &[_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 });
    o += 6;
    legacy[o] = 1; // random
    o += 1;
    @memset(legacy[o .. o + 16], 0x5C);
    o += 16;
    std.mem.writeInt(u64, legacy[o..][0..8], 0x1122334455667788, .little);
    o += 8;
    std.mem.writeInt(u16, legacy[o..][0..2], 0xBEEF, .little);
    o += 2;
    legacy[o] = 0; // no IRK
    o += 1;
    legacy[o] = 1; // authenticated
    o += 1;
    legacy[o] = 16; // key size
    o += 1;
    std.mem.writeInt(u16, legacy[o..][0..2], 1, .little);
    o += 2;
    std.mem.writeInt(u16, legacy[o..][0..2], 0x002A, .little);
    o += 2;
    std.mem.writeInt(u16, legacy[o..][0..2], 0x0001, .little);
    o += 2;
    const image = legacy[0..o];

    var store = MemoryBondStore(4).initWithKey(@splat(0x11));
    defer store.deinit();
    try std.testing.expectError(error.LegacyFormat, store.deserialize(image));
    try std.testing.expectEqual(@as(usize, 0), store.count);

    try store.deserializeLegacy(image);
    const addr = Address{ .bytes = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 } };
    const rec = store.load(addr).?;
    try std.testing.expectEqual(AddressType.random, rec.address_type);
    try std.testing.expectEqual(@as(u8, 0x5C), rec.keys.ltk[15]);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), rec.keys.rand);
    try std.testing.expectEqual(@as(u16, 0xBEEF), rec.keys.ediv);
    try std.testing.expect(rec.keys.authenticated);
    try std.testing.expectEqual(@as(u16, 0x0001), rec.getCccd(0x002A));

    // Re-serialized in the current format, the import round-trips with the same key.
    var buf: [256]u8 = undefined;
    const n = try store.serialize(&buf);
    var restored = MemoryBondStore(4).initWithKey(@splat(0x11));
    defer restored.deinit();
    try restored.deserialize(buf[0..n]);
    try std.testing.expect(restored.load(addr) != null);

    // A truncated legacy image is rejected without importing anything.
    var fresh = MemoryBondStore(4).init();
    try std.testing.expectError(error.UnexpectedEof, fresh.deserializeLegacy(image[0 .. o - 3]));
    try std.testing.expectEqual(@as(usize, 0), fresh.count);
}

test "MemoryBondStore requires an explicit key for Linux files and creates 0600 key files" {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;

    var keyless = MemoryBondStore(2).init();
    try std.testing.expectError(error.EncryptionKeyRequired, keyless.saveToFile("zig-cache-bond-keyless.bin"));
    try std.testing.expectError(error.EncryptionKeyRequired, keyless.loadFromFile("zig-cache-bond-keyless.bin"));

    const key_path: [:0]const u8 = "zig-cache-bond-store-test.key";
    _ = linux.unlink(key_path.ptr);
    defer _ = linux.unlink(key_path.ptr);

    const k1 = try loadOrCreateKeyFile(key_path);
    const k2 = try loadOrCreateKeyFile(key_path);
    try std.testing.expectEqualSlices(u8, &k1, &k2);

    var store = try MemoryBondStore(2).initWithKeyFile(key_path);
    defer store.deinit();
    try std.testing.expectEqualSlices(u8, &k1, &store.encryption_key.?);

    _ = linux.chmod(key_path.ptr, 0o644);
    try std.testing.expectError(error.InsecureFilePermissions, loadOrCreateKeyFile(key_path));
}
