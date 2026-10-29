//! # Bond Store Unit Tests
const std = @import("std");
const builtin = @import("builtin");
const types_mod = @import("types.zig");
const store_mod = @import("store.zig");
const platform_mod = @import("platform.zig");

const Address = types_mod.Address;
const AddressType = types_mod.AddressType;
const BondRecord = types_mod.BondRecord;
const MemoryBondStore = store_mod.MemoryBondStore;
const loadOrCreateKeyFile = platform_mod.loadOrCreateKeyFile;
const DeleteFileA = platform_mod.DeleteFileA;

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

