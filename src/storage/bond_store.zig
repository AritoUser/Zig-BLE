//! # Zig-BLE Security & Bond Store
//!
//! Implements Bluetooth GAP/SMP Bond Storage and Client Characteristic Configuration
//! Descriptor (CCCD) state persistence across connections and device restarts
//! according to Bluetooth Core Specification Vol 3, Part C & Part H.
//! Zero heap allocation by default for fixed embedded capacity.

const std = @import("std");
const core_types = @import("../core/types.zig");
pub const Address = core_types.Address;
pub const AddressType = core_types.AddressType;

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
        saveBond: *const fn (ctx: *anyopaque, record: BondRecord) anyerror!void,
        loadBond: *const fn (ctx: *anyopaque, addr: Address) ?BondRecord,
        deleteBond: *const fn (ctx: *anyopaque, addr: Address) anyerror!void,
        saveCccd: *const fn (ctx: *anyopaque, addr: Address, handle: u16, value: u16) anyerror!void,
        loadCccd: *const fn (ctx: *anyopaque, addr: Address, handle: u16) u16,
        clearCccds: *const fn (ctx: *anyopaque, addr: Address) anyerror!void,
        getBondCount: *const fn (ctx: *anyopaque) usize,
    };

    pub fn saveBond(self: BondStore, record: BondRecord) anyerror!void {
        return self.vtable.saveBond(self.ptr, record);
    }

    pub fn loadBond(self: BondStore, addr: Address) ?BondRecord {
        return self.vtable.loadBond(self.ptr, addr);
    }

    pub fn deleteBond(self: BondStore, addr: Address) anyerror!void {
        return self.vtable.deleteBond(self.ptr, addr);
    }

    pub fn saveCccd(self: BondStore, addr: Address, handle: u16, value: u16) anyerror!void {
        return self.vtable.saveCccd(self.ptr, addr, handle, value);
    }

    pub fn loadCccd(self: BondStore, addr: Address, handle: u16) u16 {
        return self.vtable.loadCccd(self.ptr, addr, handle);
    }

    pub fn clearCccds(self: BondStore, addr: Address) anyerror!void {
        return self.vtable.clearCccds(self.ptr, addr);
    }

    pub fn getBondCount(self: BondStore) usize {
        return self.vtable.getBondCount(self.ptr);
    }
};

/// High-performance in-memory bond store with zero heap allocations and fixed capacity.
pub fn MemoryBondStore(comptime max_devices: usize) type {
    return struct {
        const Self = @This();

        records: [max_devices]?BondRecord = @splat(null),
        count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn save(self: *Self, record: BondRecord) !void {
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

        pub fn delete(self: *Self, addr: Address) !void {
            for (&self.records) |*slot| {
                if (slot.*) |record| {
                    if (record.address.eql(addr)) {
                        slot.* = null;
                        self.count -= 1;
                        return;
                    }
                }
            }
        }

        pub fn setCccd(self: *Self, addr: Address, handle: u16, value: u16) !void {
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

        pub fn clearAllCccds(self: *Self, addr: Address) !void {
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

        pub fn serialize(self: *const Self, out_buf: []u8) !usize {
            if (out_buf.len < 8) return error.BufferTooSmall;
            @memcpy(out_buf[0..4], "ZBGR");
            std.mem.writeInt(u32, @ptrCast(out_buf[4..8]), @intCast(self.count), .little);
            var offset: usize = 8;

            for (self.records) |slot| {
                if (slot) |rec| {
                    const required = 6 + 1 + 16 + 8 + 2 + 1 + (if (rec.keys.irk != null) @as(usize, 16) else 0) + 1 + 1 + 2 + rec.cccd_count * 4;
                    if (offset + required > out_buf.len) return error.BufferTooSmall;

                    @memcpy(out_buf[offset .. offset + 6], &rec.address.bytes);
                    offset += 6;
                    out_buf[offset] = @intFromEnum(rec.address_type);
                    offset += 1;
                    @memcpy(out_buf[offset .. offset + 16], &rec.keys.ltk);
                    offset += 16;
                    std.mem.writeInt(u64, @ptrCast(out_buf[offset .. offset + 8]), rec.keys.rand, .little);
                    offset += 8;
                    std.mem.writeInt(u16, @ptrCast(out_buf[offset .. offset + 2]), rec.keys.ediv, .little);
                    offset += 2;

                    if (rec.keys.irk) |irk| {
                        out_buf[offset] = 1;
                        offset += 1;
                        @memcpy(out_buf[offset .. offset + 16], &irk);
                        offset += 16;
                    } else {
                        out_buf[offset] = 0;
                        offset += 1;
                    }

                    out_buf[offset] = if (rec.keys.authenticated) 1 else 0;
                    offset += 1;
                    out_buf[offset] = rec.keys.key_size;
                    offset += 1;

                    std.mem.writeInt(u16, @ptrCast(out_buf[offset .. offset + 2]), @intCast(rec.cccd_count), .little);
                    offset += 2;
                    for (rec.cccds[0..rec.cccd_count]) |entry| {
                        std.mem.writeInt(u16, @ptrCast(out_buf[offset .. offset + 2]), entry.handle, .little);
                        offset += 2;
                        std.mem.writeInt(u16, @ptrCast(out_buf[offset .. offset + 2]), entry.value, .little);
                        offset += 2;
                    }
                }
            }
            return offset;
        }

        pub fn deserialize(self: *Self, in_buf: []const u8) !void {
            if (in_buf.len < 8) return error.InvalidData;
            if (!std.mem.eql(u8, in_buf[0..4], "ZBGR")) return error.InvalidMagic;
            const count = std.mem.readInt(u32, @ptrCast(in_buf[4..8]), .little);
            var offset: usize = 8;

            var i: usize = 0;
            while (i < count and i < max_devices) : (i += 1) {
                if (offset + 35 > in_buf.len) return error.UnexpectedEof;
                var rec: BondRecord = undefined;
                @memcpy(&rec.address.bytes, in_buf[offset .. offset + 6]);
                offset += 6;
                rec.address_type = @enumFromInt(in_buf[offset]);
                offset += 1;
                @memcpy(&rec.keys.ltk, in_buf[offset .. offset + 16]);
                offset += 16;
                rec.keys.rand = std.mem.readInt(u64, @ptrCast(in_buf[offset .. offset + 8]), .little);
                offset += 8;
                rec.keys.ediv = std.mem.readInt(u16, @ptrCast(in_buf[offset .. offset + 2]), .little);
                offset += 2;

                const has_irk = in_buf[offset] == 1;
                offset += 1;
                if (has_irk) {
                    if (offset + 16 > in_buf.len) return error.UnexpectedEof;
                    var irk_bytes: [16]u8 = undefined;
                    @memcpy(&irk_bytes, in_buf[offset .. offset + 16]);
                    rec.keys.irk = irk_bytes;
                    offset += 16;
                } else {
                    rec.keys.irk = null;
                }

                if (offset + 4 > in_buf.len) return error.UnexpectedEof;
                rec.keys.authenticated = in_buf[offset] == 1;
                offset += 1;
                rec.keys.key_size = in_buf[offset];
                offset += 1;

                const cccd_cnt = std.mem.readInt(u16, @ptrCast(in_buf[offset .. offset + 2]), .little);
                offset += 2;
                rec.cccd_count = @min(@as(usize, cccd_cnt), MAX_CCCDS_PER_DEVICE);
                var c: usize = 0;
                while (c < cccd_cnt) : (c += 1) {
                    if (offset + 4 > in_buf.len) return error.UnexpectedEof;
                    const handle = std.mem.readInt(u16, @ptrCast(in_buf[offset .. offset + 2]), .little);
                    offset += 2;
                    const val = std.mem.readInt(u16, @ptrCast(in_buf[offset .. offset + 2]), .little);
                    offset += 2;
                    if (c < MAX_CCCDS_PER_DEVICE) {
                        rec.cccds[c] = .{ .handle = handle, .value = val };
                    }
                }
                try self.save(rec);
            }
        }

        const vtable_impl = BondStore.VTable{
            .saveBond = struct {
                fn call(ctx: *anyopaque, record: BondRecord) anyerror!void {
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
                fn call(ctx: *anyopaque, addr: Address) anyerror!void {
                    const s: *Self = @ptrCast(@alignCast(ctx));
                    try s.delete(addr);
                }
            }.call,
            .saveCccd = struct {
                fn call(ctx: *anyopaque, addr: Address, handle: u16, value: u16) anyerror!void {
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
                fn call(ctx: *anyopaque, addr: Address) anyerror!void {
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

test "MemoryBondStore binary serialization roundtrip" {
    const dev = Address{ .bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 } };
    var store1 = MemoryBondStore(8).init();

    var rec = BondRecord{
        .address = dev,
        .keys = .{
            .ltk = @splat(0x99),
            .rand = 0x123456789ABCDEF0,
            .ediv = 0x5678,
            .authenticated = true,
            .irk = @splat(0x77),
        },
    };
    rec.setCccd(0x0020, 0x0001);
    try store1.save(rec);

    var bin_buf: [512]u8 = undefined;
    const written = try store1.serialize(&bin_buf);
    try std.testing.expect(written > 8);

    var store2 = MemoryBondStore(8).init();
    try store2.deserialize(bin_buf[0..written]);

    const loaded = store2.load(dev).?;
    try std.testing.expectEqual(@as(u8, 0x99), loaded.keys.ltk[0]);
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), loaded.keys.rand);
    try std.testing.expectEqual(@as(u16, 0x5678), loaded.keys.ediv);
    try std.testing.expect(loaded.keys.irk != null);
    try std.testing.expectEqual(@as(u8, 0x77), loaded.keys.irk.?[0]);
    try std.testing.expectEqual(@as(u16, 0x0001), loaded.getCccd(0x0020));
}
