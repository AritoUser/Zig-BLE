//! # Zig-BLE Storage Subsystem
//!
//! Provides persistence interfaces for Bluetooth LE bonding keys, Identity Resolving Keys (IRK),
//! and Client Characteristic Configuration Descriptor (CCCD) state.

pub const bond_store = @import("bond_store.zig");
pub const BondStore = bond_store.BondStore;
pub const BondRecord = bond_store.BondRecord;
pub const SecurityKeys = bond_store.SecurityKeys;
pub const CccdEntry = bond_store.CccdEntry;
pub const MemoryBondStore = bond_store.MemoryBondStore;
