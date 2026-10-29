//! # Zig-BLE Security & Bond Store
//!
//! Implements Bluetooth GAP/SMP Bond Storage and Client Characteristic Configuration
//! Descriptor (CCCD) state persistence across connections and device restarts
//! according to Bluetooth Core Specification Vol 3, Part C & Part H.
//! Modularized for maintainability and security.

pub const types_mod = @import("bond_store/types.zig");
pub const crypto_mod = @import("bond_store/crypto.zig");
pub const platform_mod = @import("bond_store/platform.zig");
pub const store_mod = @import("bond_store/store.zig");

// Types re-exports
pub const Address = types_mod.Address;
pub const AddressType = types_mod.AddressType;
pub const BondStoreError = types_mod.BondStoreError;
pub const SecurityKeys = types_mod.SecurityKeys;
pub const MAX_CCCDS_PER_DEVICE = types_mod.MAX_CCCDS_PER_DEVICE;
pub const CccdEntry = types_mod.CccdEntry;
pub const BondRecord = types_mod.BondRecord;
pub const BondStore = types_mod.BondStore;

// Platform & Crypto re-exports
pub const DEFAULT_STORE_WRAP_KEY = crypto_mod.DEFAULT_STORE_WRAP_KEY;
pub const dpapiProtect = platform_mod.dpapiProtect;
pub const dpapiUnprotect = platform_mod.dpapiUnprotect;
pub const loadOrCreateKeyFile = platform_mod.loadOrCreateKeyFile;

// Store re-exports
pub const MemoryBondStore = store_mod.MemoryBondStore;

test {
    _ = @import("bond_store/tests.zig");
}
