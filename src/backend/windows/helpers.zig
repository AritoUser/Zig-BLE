//! # WinRT Conversion & Interop Helpers
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const bindings = @import("bindings.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const GUID = bindings.GUID;
const HSTRING = bindings.HSTRING;
const HRESULT = bindings.HRESULT;
const Combase = bindings.Combase;

// ============================================================================
// Conversion Helpers: Zig-BLE <-> WinRT Types
// ============================================================================

/// Converts a 48-bit `u64` WinRT Bluetooth address into a 6-byte Big-Endian `Address`.
pub fn u64ToAddress(addr64: u64) Address {
    var bytes: [6]u8 = undefined;
    std.mem.writeInt(u48, &bytes, @truncate(addr64), .big);
    return Address{ .bytes = bytes };
}

/// Converts a 6-byte Big-Endian `Address` into a 48-bit `u64` WinRT Bluetooth address.
pub fn addressToU64(addr: Address) u64 {
    return @as(u64, std.mem.readInt(u48, &addr.bytes, .big));
}

/// Converts a WinRT `GUID` into a Zig-BLE `UUID` (16-byte Big-Endian RFC 4122).
pub fn guidToUuid(g: GUID) UUID {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], g.Data1, .big);
    std.mem.writeInt(u16, b[4..6], g.Data2, .big);
    std.mem.writeInt(u16, b[6..8], g.Data3, .big);
    @memcpy(b[8..16], &g.Data4);
    return UUID{ .bytes = b };
}

/// Converts a Zig-BLE `UUID` (16-byte Big-Endian RFC 4122) into a WinRT `GUID`.
pub fn uuidToGuid(u: UUID) GUID {
    return GUID{
        .Data1 = std.mem.readInt(u32, u.bytes[0..4], .big),
        .Data2 = std.mem.readInt(u16, u.bytes[4..6], .big),
        .Data3 = std.mem.readInt(u16, u.bytes[6..8], .big),
        .Data4 = u.bytes[8..16].*,
    };
}

/// Creates a WinRT `HSTRING` from a compile-time UTF-8 string literal.
pub fn createHStringComptime(comptime utf8: []const u8) BleError!HSTRING {
    if (builtin.os.tag != .windows) return null;
    const utf16 = comptime std.unicode.utf8ToUtf16LeStringLiteral(utf8);
    var hstr: HSTRING = null;
    const hr = Combase.WindowsCreateString(utf16.ptr, @intCast(utf16.len), &hstr);
    if (hr < 0) return BleError.IoError;
    return hstr;
}

/// Creates a WinRT `HSTRING` from a runtime UTF-8 slice using a stack UTF-16 buffer.
pub fn createHStringRuntime(utf8: []const u8) BleError!HSTRING {
    if (builtin.os.tag != .windows) return null;
    var utf16_buf: [256]u16 = undefined;
    const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8) catch return BleError.InvalidParameter;
    var hstr: HSTRING = null;
    const hr = Combase.WindowsCreateString(&utf16_buf, @intCast(utf16_len), &hstr);
    if (hr < 0) return BleError.IoError;
    return hstr;
}

pub fn deleteHString(hstr: HSTRING) void {
    if (builtin.os.tag != .windows) return;
    if (hstr != null) {
        _ = Combase.WindowsDeleteString(hstr);
    }
}

/// Extracts UTF-8 text from an `HSTRING` into `out_buf` (zero heap allocation).
pub fn hstringToUtf8(hstr: HSTRING, out_buf: []u8) usize {
    if (builtin.os.tag != .windows or hstr == null) return 0;
    var len: u32 = 0;
    const raw_ptr = Combase.WindowsGetStringRawBuffer(hstr, &len) orelse return 0;
    if (len == 0) return 0;
    const utf16_slice = raw_ptr[0..len];
    return std.unicode.utf16LeToUtf8(out_buf, utf16_slice) catch 0;
}

pub const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(bindings.WINAPI) void;
} else struct {
    fn Sleep(dwMilliseconds: u32) void {
        _ = dwMilliseconds;
    }
};

/// Synchronously awaits any WinRT `IAsyncOperation<T>` with a timeout and extracts the result pointer/value.
pub fn awaitAsync(op: *bindings.IAsyncOperationGeneric, timeout_ms: u32) BleError!?*anyopaque {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    defer _ = op.lpVtbl.Release(op);

    var async_info: ?*bindings.IAsyncInfo = null;
    const qi_hr = op.lpVtbl.QueryInterface(op, &bindings.IID_IAsyncInfo, @ptrCast(&async_info));
    if (qi_hr < 0 or async_info == null) return BleError.IoError;
    const info = async_info.?;
    defer {
        _ = info.lpVtbl.Close(info);
        _ = info.lpVtbl.Release(info);
    }

    const eff_timeout: u32 = if (timeout_ms == 0) 10_000 else timeout_ms;
    var elapsed_ms: u32 = 0;
    const poll_step_ms: u32 = 2;

    while (elapsed_ms < eff_timeout) {
        var status: bindings.AsyncStatus = .Started;
        const st_hr = info.lpVtbl.get_Status(info, &status);
        if (st_hr < 0) return BleError.IoError;

        switch (status) {
            .Started => {
                Kernel32.Sleep(poll_step_ms);
                elapsed_ms += poll_step_ms;
            },
            .Completed => {
                var result: ?*anyopaque = null;
                const res_hr = op.lpVtbl.GetResults(op, &result);
                if (res_hr < 0) return BleError.IoError;
                return result;
            },
            .Canceled => return BleError.ConnectionTimeout,
            .Error => {
                var err_code: HRESULT = 0;
                _ = info.lpVtbl.get_ErrorCode(info, &err_code);
                return BleError.GattError;
            },
        }
    }

    _ = info.lpVtbl.Cancel(info);
    return BleError.ConnectionTimeout;
}

/// Reads raw bytes from a WinRT `IBuffer` via `IBufferByteAccess` into `dest` with zero heap allocations.
pub fn readIBuffer(buffer: *bindings.IBuffer, dest: []u8) BleError!usize {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    var length: u32 = 0;
    if (buffer.lpVtbl.get_Length(buffer, &length) < 0) return BleError.ReadFailed;
    if (length == 0) return 0;

    var byte_access: ?*bindings.IBufferByteAccess = null;
    const hr = buffer.lpVtbl.QueryInterface(buffer, &bindings.IID_IBufferByteAccess, @ptrCast(&byte_access));
    if (hr < 0 or byte_access == null) return BleError.ReadFailed;
    const ba = byte_access.?;
    defer _ = ba.lpVtbl.Release(ba);

    var raw_ptr: [*]u8 = undefined;
    if (ba.lpVtbl.Buffer(ba, &raw_ptr) < 0) return BleError.ReadFailed;

    const copy_len = @min(dest.len, @as(usize, length));
    @memcpy(dest[0..copy_len], raw_ptr[0..copy_len]);
    return copy_len;
}

/// Creates a WinRT `IBuffer` from a byte slice via `Windows.Security.Cryptography.CryptographicBuffer`.
pub fn createIBuffer(data: []const u8) BleError!*bindings.IBuffer {
    if (builtin.os.tag != .windows) return BleError.NotSupported;
    const class_hstr = try createHStringComptime("Windows.Security.Cryptography.CryptographicBuffer");
    defer deleteHString(class_hstr);

    var crypto_statics: ?*bindings.ICryptographicBufferStatics = null;
    const hr = Combase.RoGetActivationFactory(class_hstr, &bindings.IID_ICryptographicBufferStatics, @ptrCast(&crypto_statics));
    if (hr < 0 or crypto_statics == null) return BleError.WriteFailed;
    const statics = crypto_statics.?;
    defer _ = statics.lpVtbl.Release(statics);

    var buffer: ?*bindings.IBuffer = null;
    const dummy: [1]u8 = .{0};
    const ptr: [*]const u8 = if (data.len > 0) data.ptr else &dummy;
    const create_hr = statics.lpVtbl.CreateFromByteArray(statics, @intCast(data.len), ptr, &buffer);
    if (create_hr < 0 or buffer == null) return BleError.WriteFailed;
    return buffer.?;
}
