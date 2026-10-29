//! # Bond Store Types & Interfaces
const std = @import("std");
const core_types = @import("../../core/types.zig");

pub const Address = core_types.Address;
pub const AddressType = core_types.AddressType;

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

