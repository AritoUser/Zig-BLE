//! # In-Memory Bond Store & File Persistence Engine
const std = @import("std");
const builtin = @import("builtin");
const types_mod = @import("types.zig");
const crypto_mod = @import("crypto.zig");
const platform_mod = @import("platform.zig");
const toolbox = @import("../../crypto/toolbox.zig");

const Address = types_mod.Address;
const BondRecord = types_mod.BondRecord;
const BondStore = types_mod.BondStore;
const BondStoreError = types_mod.BondStoreError;
const MAX_CCCDS_PER_DEVICE = types_mod.MAX_CCCDS_PER_DEVICE;

const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

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
            return initWithKey(try platform_mod.loadOrCreateKeyFile(key_path));
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
            return self.encryption_key orelse crypto_mod.DEFAULT_STORE_WRAP_KEY;
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

            var subkeys = crypto_mod.deriveSubkeys(self.effectiveMasterKey());
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
                    const enc_ltk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 1, rec.keys.ltk);
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
                        const enc_irk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 2, irk);
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
                        const enc_csrk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, rec_idx, 3, csrk);
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

            var subkeys = crypto_mod.deriveSubkeys(self.effectiveMasterKey());
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
                rec.keys.ltk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 1, enc_ltk);
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
                    rec.keys.irk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 2, enc_irk);
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
                    rec.keys.csrk = crypto_mod.cryptKeyBlock(subkeys.enc_key, nonce, @intCast(i), 3, enc_csrk);
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

        /// Imports a v1.2.x bond store image (plaintext keys, no integrity tag).
        pub fn deserializeLegacy(self: *Self, in_buf: []const u8) BondStoreError!void {
            try self.parseLegacy(in_buf, false);
            try self.parseLegacy(in_buf, true);
        }

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
                const dpapi_len = try platform_mod.dpapiProtect(raw_buf[0..raw_len], &dpapi_buf);

                const handle_opt = platform_mod.CreateFileA(
                    tmp_path.ptr,
                    platform_mod.GENERIC_WRITE,
                    0,
                    null,
                    platform_mod.CREATE_ALWAYS,
                    platform_mod.FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (handle_opt == null or @intFromPtr(handle_opt.?) == platform_mod.INVALID_HANDLE_VALUE_INT) {
                    return error.IoError;
                }
                const handle = handle_opt.?;

                var written: u32 = 0;
                const write_ok = platform_mod.WriteFile(handle, &dpapi_buf, @intCast(dpapi_len), &written, null);
                const flush_ok = platform_mod.FlushFileBuffers(handle);
                _ = platform_mod.CloseHandle(handle);

                if (write_ok == 0 or flush_ok == 0 or written != dpapi_len) {
                    _ = platform_mod.DeleteFileA(tmp_path.ptr);
                    return error.IoError;
                }

                if (platform_mod.MoveFileExA(tmp_path.ptr, path.ptr, platform_mod.MOVEFILE_REPLACE_EXISTING | platform_mod.MOVEFILE_WRITE_THROUGH) == 0) {
                    _ = platform_mod.DeleteFileA(tmp_path.ptr);
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

        /// Loads the bond store from `path`, verifying OS-level security and integrity.
        pub fn loadFromFile(self: *Self, path: [:0]const u8) BondStoreError!void {
            if (builtin.os.tag == .linux and self.encryption_key == null) return error.EncryptionKeyRequired;
            if (builtin.os.tag == .windows) {
                const handle_opt = platform_mod.CreateFileA(
                    path.ptr,
                    platform_mod.GENERIC_READ,
                    0,
                    null,
                    platform_mod.OPEN_EXISTING,
                    platform_mod.FILE_ATTRIBUTE_NORMAL,
                    null,
                );
                if (handle_opt == null or @intFromPtr(handle_opt.?) == platform_mod.INVALID_HANDLE_VALUE_INT) {
                    return error.IoError;
                }
                const handle = handle_opt.?;
                defer _ = platform_mod.CloseHandle(handle);

                var dpapi_buf: [8192]u8 = undefined;
                var bytes_read: u32 = 0;
                if (platform_mod.ReadFile(handle, &dpapi_buf, dpapi_buf.len, &bytes_read, null) == 0 or bytes_read == 0) {
                    return error.IoError;
                }

                var raw_buf: [4096]u8 = undefined;
                defer std.crypto.secureZero(u8, &raw_buf);
                const raw_len = try platform_mod.dpapiUnprotect(dpapi_buf[0..bytes_read], &raw_buf);
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
