//! # OS Platform Security & Storage (DPAPI, 0600 File Permissions)
const std = @import("std");
const builtin = @import("builtin");
const types_mod = @import("types.zig");
const toolbox = @import("../../crypto/toolbox.zig");

const BondStoreError = types_mod.BondStoreError;

// -------------------------------------------------------------------------------------------------
// Windows DPAPI & Win32 Atomic File Helpers
// -------------------------------------------------------------------------------------------------

pub const DATA_BLOB = extern struct {
    cbData: u32,
    pbData: [*]u8,
};

pub const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;

pub extern "crypt32" fn CryptProtectData(
    pDataIn: *const DATA_BLOB,
    szDataDescr: ?[*:0]const u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) i32;

pub extern "crypt32" fn CryptUnprotectData(
    pDataIn: *const DATA_BLOB,
    ppszDataDescr: ?*?[*:0]u16,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: u32,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) i32;

pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn WriteFile(
    hFile: *anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn ReadFile(
    hFile: *anyopaque,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn FlushFileBuffers(hFile: *anyopaque) callconv(.winapi) i32;
pub extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
pub extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) i32;
pub extern "kernel32" fn MoveFileExA(
    lpExistingFileName: [*:0]const u8,
    lpNewFileName: [*:0]const u8,
    dwFlags: u32,
) callconv(.winapi) i32;

pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const CREATE_ALWAYS: u32 = 2;
pub const OPEN_EXISTING: u32 = 3;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
pub const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
pub const INVALID_HANDLE_VALUE_INT: usize = std.math.maxInt(usize);

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

