//! # Windows Bluetooth & GATT Native C-ABI & WinRT COM Bindings
//!
//! Provides dynamic resolution and zero-allocation invocation of Windows Bluetooth APIs
//! (bthprops.cpl / BluetoothApis.dll) and WinRT COM APIs (combase.dll).
//! Zero external C dependencies, zero SDK requirements, pure Zig.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const types = @import("../types.zig");

pub const winapi_cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

pub const HSTRING = ?*anyopaque;
pub const EventRegistrationToken = extern struct {
    value: i64,
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn toUUID(self: GUID) types.UUID {
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

    pub fn fromUUID(uuid: types.UUID) GUID {
        const b = uuid.bytes;
        return .{
            .Data1 = @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24),
            .Data2 = @as(u16, b[4]) | (@as(u16, b[5]) << 8),
            .Data3 = @as(u16, b[6]) | (@as(u16, b[7]) << 8),
            .Data4 = .{ b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] },
        };
    }

    pub fn equals(self: GUID, other: GUID) bool {
        return self.Data1 == other.Data1 and
            self.Data2 == other.Data2 and
            self.Data3 == other.Data3 and
            std.mem.eql(u8, &self.Data4, &other.Data4);
    }
};

// ============================================================================
// Standard COM & WinRT Interface GUIDs
// ============================================================================

pub const IID_IUnknown = GUID{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
pub const IID_IInspectable = GUID{ .Data1 = 0xAF86E2E0, .Data2 = 0xB12D, .Data3 = 0x4C29, .Data4 = .{ 0x9C, 0x5F, 0xD7, 0x57, 0x0D, 0x7C, 0xA9, 0x8E } };
pub const IID_IAgileObject = GUID{ .Data1 = 0x94EA2B94, .Data2 = 0xE9CC, .Data3 = 0x49E0, .Data4 = .{ 0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90 } };
pub const IID_IClosable = GUID{ .Data1 = 0x30D5A756, .Data2 = 0xE5E2, .Data3 = 0x4123, .Data4 = .{ 0x81, 0x0E, 0x66, 0x37, 0x0F, 0xEE, 0x7F, 0x5E } };
pub const IID_IAsyncInfo = GUID{ .Data1 = 0x00000036, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

// WinRT Storage & Crypto
pub const IID_IBuffer = GUID{ .Data1 = 0x905A0FE0, .Data2 = 0xBC53, .Data3 = 0x11DF, .Data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA } };
pub const IID_IBufferByteAccess = GUID{ .Data1 = 0x905A0FEF, .Data2 = 0xBC53, .Data3 = 0x11DF, .Data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA } };
pub const IID_ICryptographicBufferStatics = GUID{ .Data1 = 0x320B7E22, .Data2 = 0x3CB0, .Data3 = 0x4CDF, .Data4 = .{ 0x86, 0x63, 0x1D, 0x28, 0x91, 0x00, 0x65, 0xEB } };

// WinRT Advertisement Watcher
pub const IID_IBluetoothLEAdvertisementWatcher = GUID{ .Data1 = 0xA6AC336F, .Data2 = 0xF3D3, .Data3 = 0x4297, .Data4 = .{ 0x8D, 0x6C, 0xC8, 0x1E, 0xA6, 0x62, 0x3F, 0x40 } };
pub const IID_IBluetoothLEAdvertisementReceivedEventArgs = GUID{ .Data1 = 0x27987DDF, .Data2 = 0xE596, .Data3 = 0x41BE, .Data4 = .{ 0x8D, 0x43, 0x9E, 0x67, 0x31, 0xD4, 0xA9, 0x13 } };
pub const IID_IBluetoothLEAdvertisement = GUID{ .Data1 = 0x066FB2B7, .Data2 = 0x33D1, .Data3 = 0x4E7D, .Data4 = .{ 0x83, 0x67, 0xCF, 0x81, 0xD0, 0xF7, 0x96, 0x53 } };

// WinRT Bluetooth LE Device
pub const IID_IBluetoothLEDeviceStatics = GUID{ .Data1 = 0xC8CF1A19, .Data2 = 0xF0B6, .Data3 = 0x4BF0, .Data4 = .{ 0x86, 0x89, 0x41, 0x30, 0x3D, 0xE2, 0xD9, 0xF4 } };
pub const IID_IBluetoothLEDevice = GUID{ .Data1 = 0xB5EE2F7B, .Data2 = 0x4AD8, .Data3 = 0x4642, .Data4 = .{ 0xAC, 0x48, 0x80, 0xA0, 0xB5, 0x00, 0xE8, 0x87 } };
pub const IID_IBluetoothLEDevice3 = GUID{ .Data1 = 0xAEE9E493, .Data2 = 0x44AC, .Data3 = 0x40DC, .Data4 = .{ 0xAF, 0x33, 0xB2, 0xC1, 0x3C, 0x01, 0xCA, 0x46 } };

// WinRT GATT Service & Characteristic
pub const IID_IGattDeviceServicesResult = GUID{ .Data1 = 0x171DD3EE, .Data2 = 0x016D, .Data3 = 0x419D, .Data4 = .{ 0x83, 0x8A, 0x57, 0x6C, 0xF4, 0x75, 0xA3, 0xD8 } };
pub const IID_IGattDeviceService = GUID{ .Data1 = 0xAC7B7C05, .Data2 = 0xB33C, .Data3 = 0x47CF, .Data4 = .{ 0x99, 0x0F, 0x6B, 0x8F, 0x55, 0x77, 0xDF, 0x71 } };
pub const IID_IGattDeviceService3 = GUID{ .Data1 = 0xB293A950, .Data2 = 0x0C53, .Data3 = 0x437C, .Data4 = .{ 0xA9, 0xB3, 0x5C, 0x32, 0x10, 0xC6, 0xE5, 0x69 } };
pub const IID_IGattCharacteristicsResult = GUID{ .Data1 = 0x1194945C, .Data2 = 0xB257, .Data3 = 0x4F3E, .Data4 = .{ 0x9D, 0xB7, 0xF6, 0x8B, 0xC9, 0xA9, 0xAE, 0xF2 } };
pub const IID_IGattCharacteristic = GUID{ .Data1 = 0x59CB50C1, .Data2 = 0x5934, .Data3 = 0x4F68, .Data4 = .{ 0xA1, 0x98, 0xEB, 0x86, 0x4F, 0xA4, 0x4E, 0x6B } };
pub const IID_IGattCharacteristic3 = GUID{ .Data1 = 0x3F3C663E, .Data2 = 0x93D4, .Data3 = 0x406B, .Data4 = .{ 0xB8, 0x17, 0xDB, 0x81, 0xF8, 0xED, 0x53, 0xB3 } };
pub const IID_IGattValueChangedEventArgs = GUID{ .Data1 = 0xD21BDB54, .Data2 = 0x06E3, .Data3 = 0x4ED8, .Data4 = .{ 0xA2, 0x63, 0xAC, 0xFA, 0xC8, 0xBA, 0x73, 0x13 } };
pub const IID_IGattReadResult = GUID{ .Data1 = 0x63A66F08, .Data2 = 0x1AEA, .Data3 = 0x4C4C, .Data4 = .{ 0xA5, 0x0F, 0x97, 0xBA, 0xE4, 0x74, 0xB3, 0x48 } };
pub const IID_IGattWriteResult = GUID{ .Data1 = 0x4991DDB1, .Data2 = 0xCB2B, .Data3 = 0x44F7, .Data4 = .{ 0x99, 0xFC, 0xD2, 0x9A, 0x28, 0x71, 0xDC, 0x9B } };

// ============================================================================
// WinRT Enums
// ============================================================================

pub const AsyncStatus = enum(i32) {
    Started = 0,
    Completed = 1,
    Canceled = 2,
    Error = 3,
};

pub const BluetoothLEScanningMode = enum(i32) {
    Passive = 0,
    Active = 1,
};

pub const GattCommunicationStatus = enum(i32) {
    Success = 0,
    Unreachable = 1,
    ProtocolError = 2,
    AccessDenied = 3,
};

pub const GattWriteOption = enum(i32) {
    WriteWithResponse = 0,
    WriteWithoutResponse = 1,
};

pub const GattClientCharacteristicConfigurationDescriptorValue = enum(i32) {
    None = 0,
    Notify = 1,
    Indicate = 2,
};

// ============================================================================
// Core COM VTables & Interfaces
// ============================================================================

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
};

pub const IUnknown = extern struct {
    lpVtbl: *const IUnknownVtbl,
};

pub const IInspectableVtbl = extern struct {
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
};

pub const IInspectable = extern struct {
    lpVtbl: *const IInspectableVtbl,
};

pub const IClosableVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IClosable
    Close: *const fn (this: *anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IClosable = extern struct {
    lpVtbl: *const IClosableVtbl,
};

pub const IAsyncInfoVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IAsyncInfo
    get_Id: *const fn (this: *anyopaque, id: *u32) callconv(winapi_cc) HRESULT,
    get_Status: *const fn (this: *anyopaque, status: *AsyncStatus) callconv(winapi_cc) HRESULT,
    get_ErrorCode: *const fn (this: *anyopaque, errorCode: *HRESULT) callconv(winapi_cc) HRESULT,
    Cancel: *const fn (this: *anyopaque) callconv(winapi_cc) HRESULT,
    Close: *const fn (this: *anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IAsyncInfo = extern struct {
    lpVtbl: *const IAsyncInfoVtbl,
};

pub fn IAsyncOperationVtbl(comptime TResult: type) type {
    return extern struct {
        // IInspectable
        QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
        AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
        Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
        GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
        GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
        GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
        // IAsyncOperation
        put_Completed: *const fn (this: *anyopaque, handler: ?*anyopaque) callconv(winapi_cc) HRESULT,
        get_Completed: *const fn (this: *anyopaque, handler: *?*anyopaque) callconv(winapi_cc) HRESULT,
        GetResults: *const fn (this: *anyopaque, results: *TResult) callconv(winapi_cc) HRESULT,
    };
}

pub fn IAsyncOperation(comptime TResult: type) type {
    return extern struct {
        lpVtbl: *const IAsyncOperationVtbl(TResult),
    };
}

pub const IVectorViewVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IVectorView
    GetAt: *const fn (this: *anyopaque, index: u32, item: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_Size: *const fn (this: *anyopaque, size: *u32) callconv(winapi_cc) HRESULT,
    IndexOf: *const fn (this: *anyopaque, value: ?*anyopaque, index: *u32, found: *windows.BOOLEAN) callconv(winapi_cc) HRESULT,
    GetMany: *const fn (this: *anyopaque, startIndex: u32, capacity: u32, value: [*]?*anyopaque, actual: *u32) callconv(winapi_cc) HRESULT,
};

pub const IVectorView = extern struct {
    lpVtbl: *const IVectorViewVtbl,
};

// ============================================================================
// WinRT Storage & Crypto Interfaces
// ============================================================================

pub const IBufferVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBuffer
    get_Capacity: *const fn (this: *anyopaque, value: *u32) callconv(winapi_cc) HRESULT,
    get_Length: *const fn (this: *anyopaque, value: *u32) callconv(winapi_cc) HRESULT,
    put_Length: *const fn (this: *anyopaque, value: u32) callconv(winapi_cc) HRESULT,
};

pub const IBuffer = extern struct {
    lpVtbl: *const IBufferVtbl,
};

pub const IBufferByteAccessVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    // IBufferByteAccess
    Buffer: *const fn (this: *anyopaque, value: *?[*]u8) callconv(winapi_cc) HRESULT,
};

pub const IBufferByteAccess = extern struct {
    lpVtbl: *const IBufferByteAccessVtbl,
};

pub const ICryptographicBufferStaticsVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // ICryptographicBufferStatics
    Compare: *const fn (this: *anyopaque, object1: ?*anyopaque, object2: ?*anyopaque, isEqual: *windows.BOOLEAN) callconv(winapi_cc) HRESULT,
    GenerateRandom: *const fn (this: *anyopaque, length: u32, buffer: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GenerateRandomNumber: *const fn (this: *anyopaque, value: *u32) callconv(winapi_cc) HRESULT,
    CreateFromByteArray: *const fn (this: *anyopaque, valueSize: u32, value: [*]const u8, buffer: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const ICryptographicBufferStatics = extern struct {
    lpVtbl: *const ICryptographicBufferStaticsVtbl,
};

// ============================================================================
// WinRT BLE Advertisement Interfaces
// ============================================================================

pub const IBluetoothLEAdvertisementVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEAdvertisement
    get_Flags: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    put_Flags: *const fn (this: *anyopaque, value: ?*anyopaque) callconv(winapi_cc) HRESULT,
    get_LocalName: *const fn (this: *anyopaque, value: *HSTRING) callconv(winapi_cc) HRESULT,
    put_LocalName: *const fn (this: *anyopaque, value: HSTRING) callconv(winapi_cc) HRESULT,
    get_ServiceUuids: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_ManufacturerData: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_DataSections: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEAdvertisement = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementVtbl,
};

pub const IBluetoothLEAdvertisementReceivedEventArgsVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEAdvertisementReceivedEventArgs
    get_RawSignalStrengthInDBm: *const fn (this: *anyopaque, value: *i16) callconv(winapi_cc) HRESULT,
    get_BluetoothAddress: *const fn (this: *anyopaque, value: *u64) callconv(winapi_cc) HRESULT,
    get_AdvertisementType: *const fn (this: *anyopaque, value: *i32) callconv(winapi_cc) HRESULT,
    get_Timestamp: *const fn (this: *anyopaque, value: *i64) callconv(winapi_cc) HRESULT,
    get_Advertisement: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEAdvertisementReceivedEventArgs = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementReceivedEventArgsVtbl,
};

pub const IBluetoothLEAdvertisementWatcherVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEAdvertisementWatcher
    get_MinSamplingInterval: *const fn (this: *anyopaque, value: *i64) callconv(winapi_cc) HRESULT,
    get_MaxSamplingInterval: *const fn (this: *anyopaque, value: *i64) callconv(winapi_cc) HRESULT,
    get_MinOutOfRangeTimeout: *const fn (this: *anyopaque, value: *i64) callconv(winapi_cc) HRESULT,
    get_MaxOutOfRangeTimeout: *const fn (this: *anyopaque, value: *i64) callconv(winapi_cc) HRESULT,
    get_Status: *const fn (this: *anyopaque, value: *i32) callconv(winapi_cc) HRESULT,
    get_ScanningMode: *const fn (this: *anyopaque, value: *BluetoothLEScanningMode) callconv(winapi_cc) HRESULT,
    put_ScanningMode: *const fn (this: *anyopaque, value: BluetoothLEScanningMode) callconv(winapi_cc) HRESULT,
    get_SignalStrengthFilter: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    put_SignalStrengthFilter: *const fn (this: *anyopaque, value: ?*anyopaque) callconv(winapi_cc) HRESULT,
    get_AdvertisementFilter: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    put_AdvertisementFilter: *const fn (this: *anyopaque, value: ?*anyopaque) callconv(winapi_cc) HRESULT,
    Start: *const fn (this: *anyopaque) callconv(winapi_cc) HRESULT,
    Stop: *const fn (this: *anyopaque) callconv(winapi_cc) HRESULT,
    add_Received: *const fn (this: *anyopaque, handler: ?*anyopaque, token: *EventRegistrationToken) callconv(winapi_cc) HRESULT,
    remove_Received: *const fn (this: *anyopaque, token: EventRegistrationToken) callconv(winapi_cc) HRESULT,
    add_Stopped: *const fn (this: *anyopaque, handler: ?*anyopaque, token: *EventRegistrationToken) callconv(winapi_cc) HRESULT,
    remove_Stopped: *const fn (this: *anyopaque, token: EventRegistrationToken) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEAdvertisementWatcher = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementWatcherVtbl,
};

// ============================================================================
// WinRT BLE Device Interfaces
// ============================================================================

pub const IBluetoothLEDeviceStaticsVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEDeviceStatics
    FromIdAsync: *const fn (this: *anyopaque, deviceId: HSTRING, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    FromBluetoothAddressAsync: *const fn (this: *anyopaque, bluetoothAddress: u64, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetDeviceSelector: *const fn (this: *anyopaque, deviceSelector: *HSTRING) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEDeviceStatics = extern struct {
    lpVtbl: *const IBluetoothLEDeviceStaticsVtbl,
};

pub const IBluetoothLEDevice3Vtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEDevice3
    get_DeviceAccessInformation: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    RequestAccessAsync: *const fn (this: *anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetGattServicesAsync: *const fn (this: *anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetGattServicesWithCacheModeAsync: *const fn (this: *anyopaque, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetGattServicesForUuidAsync: *const fn (this: *anyopaque, serviceUuid: GUID, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetGattServicesForUuidWithCacheModeAsync: *const fn (this: *anyopaque, serviceUuid: GUID, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEDevice3 = extern struct {
    lpVtbl: *const IBluetoothLEDevice3Vtbl,
};

pub const IBluetoothLEDeviceVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IBluetoothLEDevice
    get_DeviceId: *const fn (this: *anyopaque, value: *HSTRING) callconv(winapi_cc) HRESULT,
    get_Name: *const fn (this: *anyopaque, value: *HSTRING) callconv(winapi_cc) HRESULT,
    get_GattServices: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_ConnectionStatus: *const fn (this: *anyopaque, value: *i32) callconv(winapi_cc) HRESULT,
    get_BluetoothAddress: *const fn (this: *anyopaque, value: *u64) callconv(winapi_cc) HRESULT,
};

pub const IBluetoothLEDevice = extern struct {
    lpVtbl: *const IBluetoothLEDeviceVtbl,
};

// ============================================================================
// WinRT GATT Profile Interfaces
// ============================================================================

pub const IGattDeviceServicesResultVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattDeviceServicesResult
    get_Status: *const fn (this: *anyopaque, value: *GattCommunicationStatus) callconv(winapi_cc) HRESULT,
    get_ProtocolError: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_Services: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IGattDeviceServicesResult = extern struct {
    lpVtbl: *const IGattDeviceServicesResultVtbl,
};

pub const IGattDeviceServiceVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattDeviceService
    GetCharacteristics: *const fn (this: *anyopaque, characteristicUuid: GUID, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetIncludedServices: *const fn (this: *anyopaque, serviceUuid: GUID, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_DeviceId: *const fn (this: *anyopaque, value: *HSTRING) callconv(winapi_cc) HRESULT,
    get_Uuid: *const fn (this: *anyopaque, value: *GUID) callconv(winapi_cc) HRESULT,
    get_AttributeHandle: *const fn (this: *anyopaque, value: *u16) callconv(winapi_cc) HRESULT,
};

pub const IGattDeviceService = extern struct {
    lpVtbl: *const IGattDeviceServiceVtbl,
};

pub const IGattDeviceService3Vtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattDeviceService3
    get_DeviceAccessInformation: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_Session: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_SharingMode: *const fn (this: *anyopaque, value: *i32) callconv(winapi_cc) HRESULT,
    RequestAccessAsync: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    OpenAsync: *const fn (this: *anyopaque, sharingMode: i32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetCharacteristicsAsync: *const fn (this: *anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetCharacteristicsWithCacheModeAsync: *const fn (this: *anyopaque, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetCharacteristicsForUuidAsync: *const fn (this: *anyopaque, characteristicUuid: GUID, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IGattDeviceService3 = extern struct {
    lpVtbl: *const IGattDeviceService3Vtbl,
};

pub const IGattCharacteristicsResultVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattCharacteristicsResult
    get_Status: *const fn (this: *anyopaque, value: *GattCommunicationStatus) callconv(winapi_cc) HRESULT,
    get_ProtocolError: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_Characteristics: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IGattCharacteristicsResult = extern struct {
    lpVtbl: *const IGattCharacteristicsResultVtbl,
};

pub const IGattCharacteristicVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattCharacteristic
    GetDescriptors: *const fn (this: *anyopaque, descriptorUuid: GUID, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_CharacteristicProperties: *const fn (this: *anyopaque, value: *u32) callconv(winapi_cc) HRESULT,
    get_ProtectionLevel: *const fn (this: *anyopaque, value: *i32) callconv(winapi_cc) HRESULT,
    put_ProtectionLevel: *const fn (this: *anyopaque, value: i32) callconv(winapi_cc) HRESULT,
    get_UserDescription: *const fn (this: *anyopaque, value: *HSTRING) callconv(winapi_cc) HRESULT,
    get_Uuid: *const fn (this: *anyopaque, value: *GUID) callconv(winapi_cc) HRESULT,
    get_AttributeHandle: *const fn (this: *anyopaque, value: *u16) callconv(winapi_cc) HRESULT,
    get_PresentationFormats: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    ReadValueAsync: *const fn (this: *anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    ReadValueWithCacheModeAsync: *const fn (this: *anyopaque, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteValueAsync: *const fn (this: *anyopaque, value: ?*anyopaque, asyncOp: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteValueWithOptionAsync: *const fn (this: *anyopaque, value: ?*anyopaque, writeOption: GattWriteOption, asyncOp: *?*anyopaque) callconv(winapi_cc) HRESULT,
    ReadClientCharacteristicConfigurationDescriptorAsync: *const fn (this: *anyopaque, asyncOp: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteClientCharacteristicConfigurationDescriptorAsync: *const fn (this: *anyopaque, value: GattClientCharacteristicConfigurationDescriptorValue, asyncOp: *?*anyopaque) callconv(winapi_cc) HRESULT,
    add_ValueChanged: *const fn (this: *anyopaque, handler: ?*anyopaque, token: *EventRegistrationToken) callconv(winapi_cc) HRESULT,
    remove_ValueChanged: *const fn (this: *anyopaque, token: EventRegistrationToken) callconv(winapi_cc) HRESULT,
};

pub const IGattCharacteristic = extern struct {
    lpVtbl: *const IGattCharacteristicVtbl,
};

pub const IGattCharacteristic3Vtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattCharacteristic3
    GetDescriptorsAsync: *const fn (this: *anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetDescriptorsWithCacheModeAsync: *const fn (this: *anyopaque, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetDescriptorsForUuidAsync: *const fn (this: *anyopaque, descriptorUuid: GUID, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    GetDescriptorsForUuidWithCacheModeAsync: *const fn (this: *anyopaque, descriptorUuid: GUID, cacheMode: u32, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteValueWithResultAsync: *const fn (this: *anyopaque, value: ?*anyopaque, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteValueWithResultAndOptionAsync: *const fn (this: *anyopaque, value: ?*anyopaque, writeOption: GattWriteOption, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
    WriteClientCharacteristicConfigurationDescriptorWithResultAsync: *const fn (this: *anyopaque, value: GattClientCharacteristicConfigurationDescriptorValue, operation: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IGattCharacteristic3 = extern struct {
    lpVtbl: *const IGattCharacteristic3Vtbl,
};

pub const IGattValueChangedEventArgsVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattValueChangedEventArgs
    get_CharacteristicValue: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
    get_Timestamp: *const fn (this: *anyopaque, timestamp: *i64) callconv(winapi_cc) HRESULT,
};

pub const IGattValueChangedEventArgs = extern struct {
    lpVtbl: *const IGattValueChangedEventArgsVtbl,
};

pub const IGattReadResultVtbl = extern struct {
    // IInspectable
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    GetIids: *const fn (this: *anyopaque, iidCount: *u32, iids: *[*]GUID) callconv(winapi_cc) HRESULT,
    GetRuntimeClassName: *const fn (this: *anyopaque, className: *HSTRING) callconv(winapi_cc) HRESULT,
    GetTrustLevel: *const fn (this: *anyopaque, trustLevel: *i32) callconv(winapi_cc) HRESULT,
    // IGattReadResult
    get_Status: *const fn (this: *anyopaque, value: *GattCommunicationStatus) callconv(winapi_cc) HRESULT,
    get_Value: *const fn (this: *anyopaque, value: *?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const IGattReadResult = extern struct {
    lpVtbl: *const IGattReadResultVtbl,
};

// ============================================================================
// COM Event Sinks & Handlers (Pure Zig Zero-Alloc Implementations)
// ============================================================================

pub const IEventHandlerVTable = extern struct {
    QueryInterface: *const fn (this: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT,
    AddRef: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Release: *const fn (this: *anyopaque) callconv(winapi_cc) u32,
    Invoke: *const fn (this: *anyopaque, sender: ?*anyopaque, args: ?*anyopaque) callconv(winapi_cc) HRESULT,
};

pub const GattValueChangedHandler = struct {
    vtable: *const IEventHandlerVTable,
    ref_count: std.atomic.Value(u32),
    callback: *const fn (ctx: *anyopaque, data: []const u8) void,
    ctx: *anyopaque,

    pub fn init(callback: *const fn (ctx: *anyopaque, data: []const u8) void, ctx: *anyopaque) GattValueChangedHandler {
        return .{
            .vtable = &handler_vtable,
            .ref_count = std.atomic.Value(u32).init(1),
            .callback = callback,
            .ctx = ctx,
        };
    }

    const handler_vtable: IEventHandlerVTable = .{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    fn qi(this_opaque: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT {
        _ = riid;
        const out = ppvObject orelse return E_POINTER;
        _ = addRef(this_opaque);
        out.* = this_opaque;
        return S_OK;
    }

    fn addRef(this_opaque: *anyopaque) callconv(winapi_cc) u32 {
        const self: *GattValueChangedHandler = @ptrCast(@alignCast(this_opaque));
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(this_opaque: *anyopaque) callconv(winapi_cc) u32 {
        const self: *GattValueChangedHandler = @ptrCast(@alignCast(this_opaque));
        return self.ref_count.fetchSub(1, .monotonic) - 1;
    }

    fn invoke(this_opaque: *anyopaque, sender: ?*anyopaque, args: ?*anyopaque) callconv(winapi_cc) HRESULT {
        _ = sender;
        const self: *GattValueChangedHandler = @ptrCast(@alignCast(this_opaque));
        const args_ptr = args orelse return S_OK;

        const event_args: *const IGattValueChangedEventArgs = @ptrCast(@alignCast(args_ptr));
        var ibuffer_obj: ?*anyopaque = null;
        if (event_args.lpVtbl.get_CharacteristicValue(args_ptr, &ibuffer_obj) != S_OK) return S_OK;
        const buf_ptr = ibuffer_obj orelse return S_OK;
        const unk: *const IUnknown = @ptrCast(@alignCast(buf_ptr));
        defer _ = unk.lpVtbl.Release(buf_ptr);

        var byte_access_obj: ?*anyopaque = null;
        if (unk.lpVtbl.QueryInterface(buf_ptr, &IID_IBufferByteAccess, &byte_access_obj) != S_OK) return S_OK;
        const byte_access: *const IBufferByteAccess = @ptrCast(@alignCast(byte_access_obj.?));
        defer _ = byte_access.lpVtbl.Release(byte_access_obj.?);

        const ibuffer: *const IBuffer = @ptrCast(@alignCast(buf_ptr));
        var len: u32 = 0;
        if (ibuffer.lpVtbl.get_Length(buf_ptr, &len) != S_OK) return S_OK;

        var raw_bytes: ?[*]u8 = null;
        if (byte_access.lpVtbl.Buffer(byte_access_obj.?, &raw_bytes) != S_OK) return S_OK;
        if (raw_bytes) |ptr| {
            self.callback(self.ctx, ptr[0..len]);
        }
        return S_OK;
    }
};

pub const AdvReceivedHandler = struct {
    vtable: *const IEventHandlerVTable,
    ref_count: std.atomic.Value(u32),
    callback: *const fn (ctx: *anyopaque, dev: *const types.DiscoveredDevice) void,
    ctx: *anyopaque,
    apis: *const WindowsWinRtApis,

    pub fn init(
        callback: *const fn (ctx: *anyopaque, dev: *const types.DiscoveredDevice) void,
        ctx: *anyopaque,
        apis: *const WindowsWinRtApis,
    ) AdvReceivedHandler {
        return .{
            .vtable = &handler_vtable,
            .ref_count = std.atomic.Value(u32).init(1),
            .callback = callback,
            .ctx = ctx,
            .apis = apis,
        };
    }

    const handler_vtable: IEventHandlerVTable = .{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    fn qi(this_opaque: *anyopaque, riid: *const GUID, ppvObject: ?*?*anyopaque) callconv(winapi_cc) HRESULT {
        _ = riid;
        const out = ppvObject orelse return E_POINTER;
        _ = addRef(this_opaque);
        out.* = this_opaque;
        return S_OK;
    }

    fn addRef(this_opaque: *anyopaque) callconv(winapi_cc) u32 {
        const self: *AdvReceivedHandler = @ptrCast(@alignCast(this_opaque));
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(this_opaque: *anyopaque) callconv(winapi_cc) u32 {
        const self: *AdvReceivedHandler = @ptrCast(@alignCast(this_opaque));
        return self.ref_count.fetchSub(1, .monotonic) - 1;
    }

    fn invoke(this_opaque: *anyopaque, sender: ?*anyopaque, args: ?*anyopaque) callconv(winapi_cc) HRESULT {
        _ = sender;
        const self: *AdvReceivedHandler = @ptrCast(@alignCast(this_opaque));
        const args_ptr = args orelse return S_OK;

        const event_args: *const IBluetoothLEAdvertisementReceivedEventArgs = @ptrCast(@alignCast(args_ptr));
        var addr_u64: u64 = 0;
        if (event_args.lpVtbl.get_BluetoothAddress(args_ptr, &addr_u64) != S_OK) return S_OK;

        var rssi: i16 = 0;
        _ = event_args.lpVtbl.get_RawSignalStrengthInDBm(args_ptr, &rssi);

        var discovered = types.DiscoveredDevice{
            .address = types.Address{
                .bytes = [_]u8{
                    @intCast((addr_u64 >> 40) & 0xFF),
                    @intCast((addr_u64 >> 32) & 0xFF),
                    @intCast((addr_u64 >> 24) & 0xFF),
                    @intCast((addr_u64 >> 16) & 0xFF),
                    @intCast((addr_u64 >> 8) & 0xFF),
                    @intCast((addr_u64 >> 0) & 0xFF),
                },
            },
            .rssi = rssi,
        };

        var adv_obj: ?*anyopaque = null;
        if (event_args.lpVtbl.get_Advertisement(args_ptr, &adv_obj) == S_OK and adv_obj != null) {
            const adv: *const IBluetoothLEAdvertisement = @ptrCast(@alignCast(adv_obj.?));
            defer _ = @as(*const IUnknown, @ptrCast(@alignCast(adv_obj.?))).lpVtbl.Release(adv_obj.?);

            var local_name_hstr: HSTRING = null;
            if (adv.lpVtbl.get_LocalName(adv_obj.?, &local_name_hstr) == S_OK and local_name_hstr != null) {
                defer _ = self.apis.deleteString(local_name_hstr);
                var raw_len: u32 = 0;
                if (self.apis.getStringRawBuffer(local_name_hstr, &raw_len)) |utf16_ptr| {
                    if (raw_len > 0) {
                        var name_utf8: [64]u8 = undefined;
                        if (std.unicode.utf16LeToUtf8(&name_utf8, utf16_ptr[0..raw_len])) |len| {
                            discovered.setName(name_utf8[0..len]);
                        } else |_| {}
                    }
                }
            }
        }

        self.callback(self.ctx, &discovered);
        return S_OK;
    }
};

// ============================================================================
// WinRT combase.dll Dynamic Loader
// ============================================================================

pub const RoInitializeFn = *const fn (init_type: u32) callconv(winapi_cc) HRESULT;
pub const RoUninitializeFn = *const fn () callconv(winapi_cc) void;
pub const RoGetActivationFactoryFn = *const fn (activatableClassId: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(winapi_cc) HRESULT;
pub const RoActivateInstanceFn = *const fn (activatableClassId: HSTRING, instance: *?*anyopaque) callconv(winapi_cc) HRESULT;
pub const WindowsCreateStringFn = *const fn (sourceString: [*]const u16, length: u32, string: *HSTRING) callconv(winapi_cc) HRESULT;
pub const WindowsDeleteStringFn = *const fn (string: HSTRING) callconv(winapi_cc) HRESULT;
pub const WindowsGetStringRawBufferFn = *const fn (string: HSTRING, length: ?*u32) callconv(winapi_cc) ?[*:0]const u16;

pub const WindowsWinRtApis = struct {
    combase_module: windows.HMODULE,

    roInitialize: RoInitializeFn,
    roUninitialize: RoUninitializeFn,
    roGetActivationFactory: RoGetActivationFactoryFn,
    roActivateInstance: RoActivateInstanceFn,
    createString: WindowsCreateStringFn,
    deleteString: WindowsDeleteStringFn,
    getStringRawBuffer: WindowsGetStringRawBufferFn,

    pub fn load() ?WindowsWinRtApis {
        if (builtin.os.tag != .windows) return null;
        const mod = LoadLibraryA("combase.dll") orelse return null;

        const ro_init: RoInitializeFn = @ptrCast(GetProcAddress(mod, "RoInitialize") orelse return null);
        const ro_uninit: RoUninitializeFn = @ptrCast(GetProcAddress(mod, "RoUninitialize") orelse return null);
        const ro_factory: RoGetActivationFactoryFn = @ptrCast(GetProcAddress(mod, "RoGetActivationFactory") orelse return null);
        const ro_activate: RoActivateInstanceFn = @ptrCast(GetProcAddress(mod, "RoActivateInstance") orelse return null);
        const win_create: WindowsCreateStringFn = @ptrCast(GetProcAddress(mod, "WindowsCreateString") orelse return null);
        const win_delete: WindowsDeleteStringFn = @ptrCast(GetProcAddress(mod, "WindowsDeleteString") orelse return null);
        const win_get_raw: WindowsGetStringRawBufferFn = @ptrCast(GetProcAddress(mod, "WindowsGetStringRawBuffer") orelse return null);

        return WindowsWinRtApis{
            .combase_module = mod,
            .roInitialize = ro_init,
            .roUninitialize = ro_uninit,
            .roGetActivationFactory = ro_factory,
            .roActivateInstance = ro_activate,
            .createString = win_create,
            .deleteString = win_delete,
            .getStringRawBuffer = win_get_raw,
        };
    }

    pub fn createHString(self: *const WindowsWinRtApis, str: []const u8) ?HSTRING {
        var utf16_buf: [256]u16 = undefined;
        if (str.len >= utf16_buf.len) return null;
        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, str) catch return null;
        var hstr: HSTRING = null;
        if (self.createString(&utf16_buf, @intCast(utf16_len), &hstr) != S_OK) return null;
        return hstr;
    }

    pub fn getActivationFactory(self: *const WindowsWinRtApis, class_name: []const u8, iid: *const GUID) ?*anyopaque {
        const hstr = self.createHString(class_name) orelse return null;
        defer _ = self.deleteString(hstr);
        var factory: ?*anyopaque = null;
        if (self.roGetActivationFactory(hstr, iid, &factory) != S_OK) return null;
        return factory;
    }

    pub fn activateInstance(self: *const WindowsWinRtApis, class_name: []const u8) ?*anyopaque {
        const hstr = self.createHString(class_name) orelse return null;
        defer _ = self.deleteString(hstr);
        var instance: ?*anyopaque = null;
        if (self.roActivateInstance(hstr, &instance) != S_OK) return null;
        return instance;
    }

    pub fn awaitAsync(self: *const WindowsWinRtApis, comptime TResult: type, op_obj: *anyopaque, timeout_ms: u32) !TResult {
        _ = self;
        const unk: *const IUnknown = @ptrCast(@alignCast(op_obj));
        var async_info_obj: ?*anyopaque = null;
        if (unk.lpVtbl.QueryInterface(op_obj, &IID_IAsyncInfo, &async_info_obj) != S_OK) {
            return types.BleError.IoError;
        }
        const async_info: *const IAsyncInfo = @ptrCast(@alignCast(async_info_obj.?));
        defer _ = async_info.lpVtbl.Release(async_info_obj.?);

        const start_time = GetTickCount64();
        while (true) {
            var status: AsyncStatus = .Started;
            _ = async_info.lpVtbl.get_Status(async_info_obj.?, &status);
            if (status == .Completed) {
                break;
            } else if (status == .Error) {
                return types.BleError.IoError;
            } else if (status == .Canceled) {
                return types.BleError.ConnectionFailed;
            }
            if (GetTickCount64() - start_time > timeout_ms) {
                _ = async_info.lpVtbl.Cancel(async_info_obj.?);
                return types.BleError.ConnectionTimeout;
            }
            Sleep(5);
        }

        const op: *const IAsyncOperation(TResult) = @ptrCast(@alignCast(op_obj));
        var res: TResult = undefined;
        if (op.lpVtbl.GetResults(op_obj, &res) != S_OK) {
            return types.BleError.IoError;
        }
        return res;
    }

    pub fn unload(self: *WindowsWinRtApis) void {
        _ = FreeLibrary(self.combase_module);
    }
};

// ============================================================================
// Win32 Bluetooth APIs (Legacy discovery & radio info)
// ============================================================================

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

pub const BluetoothFindFirstRadioFn = *const fn (
    pbtfrp: *const BLUETOOTH_FIND_RADIO_PARAMS,
    phRadio: *windows.HANDLE,
) callconv(winapi_cc) ?windows.HANDLE;

pub const BluetoothFindRadioCloseFn = *const fn (
    hFind: windows.HANDLE,
) callconv(winapi_cc) windows.BOOL;

pub const BluetoothGetRadioInfoFn = *const fn (
    hRadio: windows.HANDLE,
    pRadioInfo: *BLUETOOTH_RADIO_INFO,
) callconv(winapi_cc) windows.DWORD;

pub const BluetoothGATTGetServicesFn = *const fn (
    hDevice: windows.HANDLE,
    ServicesBufferCount: windows.USHORT,
    ServicesBuffer: ?[*]BTH_LE_GATT_SERVICE,
    ServicesBufferActual: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(winapi_cc) i32;

pub const BluetoothGATTGetCharacteristicsFn = *const fn (
    hDevice: windows.HANDLE,
    Service: ?*const BTH_LE_GATT_SERVICE,
    CharacteristicsBufferCount: windows.USHORT,
    CharacteristicsBuffer: ?[*]BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicsBufferActual: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(winapi_cc) i32;

pub const BluetoothGATTGetCharacteristicValueFn = *const fn (
    hDevice: windows.HANDLE,
    Characteristic: *const BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicValueDataSize: windows.ULONG,
    CharacteristicValue: ?*BTH_LE_GATT_CHARACTERISTIC_VALUE,
    CharacteristicValueSizeRequired: *windows.USHORT,
    Flags: windows.ULONG,
) callconv(winapi_cc) i32;

pub const BluetoothGATTSetCharacteristicValueFn = *const fn (
    hDevice: windows.HANDLE,
    Characteristic: *const BTH_LE_GATT_CHARACTERISTIC,
    CharacteristicValue: *const BTH_LE_GATT_CHARACTERISTIC_VALUE,
    ReliableWriteContext: ?*anyopaque,
    Flags: windows.ULONG,
) callconv(winapi_cc) i32;


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
) callconv(winapi_cc) ?windows.HANDLE;

pub const BluetoothFindNextDeviceFn = *const fn (
    hFind: windows.HANDLE,
    pbtdi: *BLUETOOTH_DEVICE_INFO,
) callconv(winapi_cc) windows.BOOL;

pub const BluetoothFindDeviceCloseFn = *const fn (
    hFind: windows.HANDLE,
) callconv(winapi_cc) windows.BOOL;

// Win32 dynamic loader
pub const LoadLibraryA = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(winapi_cc) ?windows.HMODULE;
}.LoadLibraryA else struct {
    pub fn LoadLibraryA(_: [*:0]const u8) ?windows.HMODULE {
        return null;
    }
}.LoadLibraryA;

pub const FreeLibrary = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(winapi_cc) windows.BOOL;
}.FreeLibrary else struct {
    pub fn FreeLibrary(_: windows.HMODULE) windows.BOOL {
        return .FALSE;
    }
}.FreeLibrary;

pub const GetProcAddress = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(winapi_cc) ?windows.FARPROC;
}.GetProcAddress else struct {
    pub fn GetProcAddress(_: windows.HMODULE, _: [*:0]const u8) ?windows.FARPROC {
        return null;
    }
}.GetProcAddress;

pub const CloseHandle = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(winapi_cc) windows.BOOL;
}.CloseHandle else struct {
    pub fn CloseHandle(_: windows.HANDLE) windows.BOOL {
        return .FALSE;
    }
}.CloseHandle;

pub const GetTickCount64 = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetTickCount64() callconv(winapi_cc) u64;
}.GetTickCount64 else struct {
    pub fn GetTickCount64() u64 {
        return 0;
    }
}.GetTickCount64;

pub const Sleep = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(winapi_cc) void;
}.Sleep else struct {
    pub fn Sleep(_: windows.DWORD) void {}
}.Sleep;



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

test "WindowsWinRtApis loader check" {
    if (builtin.os.tag == .windows) {
        if (WindowsWinRtApis.load()) |mut_apis| {
            var apis = mut_apis;
            defer apis.unload();
            try std.testing.expect(@intFromPtr(apis.combase_module) != 0);

            // Test RoInitialize
            const hr = apis.roInitialize(1); // RO_INIT_MULTITHREADED
            defer apis.roUninitialize();
            try std.testing.expect(hr == S_OK or hr == S_FALSE);
        }
    }
}
