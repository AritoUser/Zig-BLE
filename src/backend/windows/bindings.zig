//! # Windows Bluetooth & GATT Native C-ABI Bindings
//!
//! Provides dynamic resolution and zero-allocation invocation of Windows Bluetooth APIs
//! (bthprops.cpl / BluetoothApis.dll) and WinRT COM APIs (combase.dll).
//! Zero external C dependencies, zero SDK requirements, pure Zig.

const std = @import("std");
const windows = std.os.windows;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn toUUID(self: GUID) @import("../../core/types.zig").UUID {
        // Windows GUID has mixed-endian fields: Data1 (LE), Data2 (LE), Data3 (LE), Data4 (BE)
        var bytes: [16]u8 = undefined;
        bytes[0] = @intCast(self.Data1 & 0xFF);
        bytes[1] = @intCast((self.Data1 >> 8) & 0xFF);
        bytes[2] = @intCast((self.Data1 >> 16) & 0xFF);
        bytes[3] = @intCast((self.Data1 >> 24) & 0xFF);
        bytes[4] = @intCast(self.Data2 & 0xFF);
        bytes[5] = @intCast((self.Data2 >> 8) & 0xFF);
        bytes[6] = @intCast(self.Data3 & 0xFF);
        bytes[7] = @intCast((self.Data3 >> 8) & 0xFF);
        @memcpy(bytes[8..16], self.Data4[0..8]);
        return .{ .bytes = bytes };
    }
};

pub const BTH_LE_UUID = extern struct {
    IsShortUuid: windows.BOOLEAN,
    Value: extern union {
        ShortUuid: u16,
        LongUuid: GUID,
    },
};

pub const BTH_LE_GATT_SERVICE = extern struct {
    ServiceUuid: BTH_LE_UUID,
    AttributeHandle: windows.USHORT,
};

pub const BTH_LE_GATT_CHARACTERISTIC = extern struct {
    ServiceHandle: windows.USHORT,
    CharacteristicUuid: BTH_LE_UUID,
    AttributeHandle: windows.USHORT,
    ValueHandle: windows.USHORT,
    IsNotifiable: windows.BOOLEAN,
    IsIndicatable: windows.BOOLEAN,
    IsSignedWritable: windows.BOOLEAN,
    IsWritableWithoutResponse: windows.BOOLEAN,
    IsWritable: windows.BOOLEAN,
    IsReadable: windows.BOOLEAN,
    HasExtendedProperties: windows.BOOLEAN,
};

pub const BTH_LE_GATT_DESCRIPTOR = extern struct {
    ServiceHandle: windows.USHORT,
    CharacteristicHandle: windows.USHORT,
    DescriptorType: u32,
    DescriptorUuid: BTH_LE_UUID,
    AttributeHandle: windows.USHORT,
};

pub const BTH_LE_GATT_CHARACTERISTIC_VALUE = extern struct {
    DataSize: windows.ULONG,
    Data: [1]u8,
};

pub const BLUETOOTH_FIND_RADIO_PARAMS = extern struct {
    dwSize: windows.DWORD = @sizeOf(BLUETOOTH_FIND_RADIO_PARAMS),
};

pub const BLUETOOTH_RADIO_INFO = extern struct {
    dwSize: windows.DWORD = @sizeOf(BLUETOOTH_RADIO_INFO),
    address: u64,
    szName: [248]u16,
    ulClassofDevice: windows.ULONG,
    lmpSubversion: windows.USHORT,
    manufacturer: windows.USHORT,
};

// Function pointer signatures for Bluetooth APIs
pub const BluetoothFindFirstRadioFn = *const fn (
    pbtfrp: *const BLUETOOTH_FIND_RADIO_PARAMS,
    phRadio: *windows.HANDLE,
) callconv(.winapi) ?windows.HANDLE;

pub const BluetoothFindRadioCloseFn = *const fn (
    hFind: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub const BluetoothGetRadioInfoFn = *const fn (
    hRadio: windows.HANDLE,
    pRadioInfo: *BLUETOOTH_RADIO_INFO,
) callconv(.winapi) windows.DWORD;

pub const BluetoothGATTGetServicesFn = *const fn (
    hDevice: windows.HANDLE,
    ServicesBufferCount: windows.USHORT,
    ServicesBuffer: ?[*]BTH_LE_GATT_SERVICE,
    ServicesBufferActual: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(.winapi) i32;

pub const BluetoothGATTGetCharacteristicsFn = *const fn (
    hDevice: windows.HANDLE,
    Service: ?*const BTH_LE_GATT_SERVICE,
    CharacteristicsBufferCount: windows.USHORT,
    CharacteristicsBuffer: ?[*]BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicsBufferActual: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(.winapi) i32;

pub const BluetoothGATTGetCharacteristicValueFn = *const fn (
    hDevice: windows.HANDLE,
    Characteristic: *const BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicValueDataSize: windows.ULONG,
    CharacteristicValue: ?*BTH_LE_GATT_CHARACTERISTIC_VALUE,
    CharacteristicValueSizeRequired: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(.winapi) i32;

pub const BluetoothGATTSetCharacteristicValueFn = *const fn (
    hDevice: windows.HANDLE,
    Characteristic: *const BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicValue: *const BTH_LE_GATT_CHARACTERISTIC_VALUE,
    ReliableWriteContext: ?*anyopaque,
    Flags: windows.ULONG,
) callconv(.winapi) i32;

// Device inquiry structures
pub const BLUETOOTH_DEVICE_INFO = extern struct {
    dwSize: windows.DWORD = @sizeOf(BLUETOOTH_DEVICE_INFO),
    Address: u64,
    ulClassofDevice: windows.ULONG,
    fConnected: c_int,
    fRemembered: c_int,
    fAuthenticated: c_int,
    stLastSeen: extern struct {
        wYear: windows.WORD,
        wMonth: windows.WORD,
        wDayOfWeek: windows.WORD,
        wDay: windows.WORD,
        wHour: windows.WORD,
        wMinute: windows.WORD,
        wSecond: windows.WORD,
        wMilliseconds: windows.WORD,
    },
    stLastUsed: extern struct {
        wYear: windows.WORD,
        wMonth: windows.WORD,
        wDayOfWeek: windows.WORD,
        wDay: windows.WORD,
        wHour: windows.WORD,
        wMinute: windows.WORD,
        wSecond: windows.WORD,
        wMilliseconds: windows.WORD,
    },
    szName: [248]u16,
};

pub const BLUETOOTH_DEVICE_SEARCH_PARAMS = extern struct {
    dwSize: windows.DWORD = @sizeOf(BLUETOOTH_DEVICE_SEARCH_PARAMS),
    fReturnAuthenticated: c_int = 1,
    fReturnRemembered: c_int = 1,
    fReturnUnknown: c_int = 1,
    fReturnConnected: c_int = 1,
    fIssueInquiry: c_int = 1,
    cTimeoutMultiplier: u8 = 2,
    hRadio: ?windows.HANDLE = null,
};

pub const BluetoothFindFirstDeviceFn = *const fn (
    pbtsp: *const BLUETOOTH_DEVICE_SEARCH_PARAMS,
    pbtdi: *BLUETOOTH_DEVICE_INFO,
) callconv(.winapi) ?windows.HANDLE;

pub const BluetoothFindNextDeviceFn = *const fn (
    hFind: windows.HANDLE,
    pbtdi: *BLUETOOTH_DEVICE_INFO,
) callconv(.winapi) windows.BOOL;

pub const BluetoothFindDeviceCloseFn = *const fn (
    hFind: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

const builtin = @import("builtin");

// Win32 dynamic loader (conditionally linked on Windows only)
pub const LoadLibraryA = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?windows.HMODULE;
}.LoadLibraryA else struct {
    pub fn LoadLibraryA(_: [*:0]const u8) ?windows.HMODULE {
        return null;
    }
}.LoadLibraryA;

pub const FreeLibrary = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;
}.FreeLibrary else struct {
    pub fn FreeLibrary(_: windows.HMODULE) windows.BOOL {
        return .FALSE;
    }
}.FreeLibrary;

pub const GetProcAddress = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
}.GetProcAddress else struct {
    pub fn GetProcAddress(_: windows.HMODULE, _: [*:0]const u8) ?windows.FARPROC {
        return null;
    }
}.GetProcAddress;

pub const CloseHandle = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
}.CloseHandle else struct {
    pub fn CloseHandle(_: windows.HANDLE) windows.BOOL {
        return .FALSE;
    }
}.CloseHandle;

pub const WindowsBluetoothApis = struct {
    bth_module: windows.HMODULE,

    findFirstRadio: BluetoothFindFirstRadioFn,
    findRadioClose: BluetoothFindRadioCloseFn,
    getRadioInfo: BluetoothGetRadioInfoFn,

    getServices: ?BluetoothGATTGetServicesFn = null,
    getCharacteristics: ?BluetoothGATTGetCharacteristicsFn = null,
    getCharValue: ?BluetoothGATTGetCharacteristicValueFn = null,
    setCharValue: ?BluetoothGATTSetCharacteristicValueFn = null,

    findFirstDevice: ?BluetoothFindFirstDeviceFn = null,
    findNextDevice: ?BluetoothFindNextDeviceFn = null,
    findDeviceClose: ?BluetoothFindDeviceCloseFn = null,

    pub fn load() ?WindowsBluetoothApis {
        if (builtin.os.tag != .windows) return null;
        const mod = LoadLibraryA("bthprops.cpl") orelse LoadLibraryA("BluetoothApis.dll") orelse return null;

        const find_first: BluetoothFindFirstRadioFn = @ptrCast(GetProcAddress(mod, "BluetoothFindFirstRadio") orelse return null);
        const find_close: BluetoothFindRadioCloseFn = @ptrCast(GetProcAddress(mod, "BluetoothFindRadioClose") orelse return null);
        const get_info: BluetoothGetRadioInfoFn = @ptrCast(GetProcAddress(mod, "BluetoothGetRadioInfo") orelse return null);

        var apis = WindowsBluetoothApis{
            .bth_module = mod,
            .findFirstRadio = find_first,
            .findRadioClose = find_close,
            .getRadioInfo = get_info,
        };

        if (GetProcAddress(mod, "BluetoothFindFirstDevice")) |p| {
            apis.findFirstDevice = @ptrCast(p);
        }
        if (GetProcAddress(mod, "BluetoothFindNextDevice")) |p| {
            apis.findNextDevice = @ptrCast(p);
        }
        if (GetProcAddress(mod, "BluetoothFindDeviceClose")) |p| {
            apis.findDeviceClose = @ptrCast(p);
        }

        if (GetProcAddress(mod, "BluetoothGATTGetServices")) |p| {
            apis.getServices = @ptrCast(p);
        }
        if (GetProcAddress(mod, "BluetoothGATTGetCharacteristics")) |p| {
            apis.getCharacteristics = @ptrCast(p);
        }
        if (GetProcAddress(mod, "BluetoothGATTGetCharacteristicValue")) |p| {
            apis.getCharValue = @ptrCast(p);
        }
        if (GetProcAddress(mod, "BluetoothGATTSetCharacteristicValue")) |p| {
            apis.setCharValue = @ptrCast(p);
        }

        return apis;
    }

    pub fn unload(self: *WindowsBluetoothApis) void {
        _ = FreeLibrary(self.bth_module);
    }
};

test "WindowsBluetoothApis bindings check" {
    if (WindowsBluetoothApis.load()) |mut_apis| {
        var apis = mut_apis;
        defer apis.unload();
        try std.testing.expect(@intFromPtr(apis.bth_module) != 0);
    }
}
