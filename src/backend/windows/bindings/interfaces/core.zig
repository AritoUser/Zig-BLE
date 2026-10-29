//! # WinRT COM Interfaces Submodule
const types = @import("../types.zig");
const iids = @import("../iids.zig");

const WINAPI = types.WINAPI;
const HRESULT = types.HRESULT;
const ULONG = types.ULONG;
const HSTRING = types.HSTRING;
const EventRegistrationToken = types.EventRegistrationToken;
const GUID = types.GUID;
const TrustLevel = types.TrustLevel;
const AsyncStatus = types.AsyncStatus;
const BluetoothConnectionStatus = types.BluetoothConnectionStatus;
const BluetoothError = types.BluetoothError;
const BluetoothLEAdvertisementWatcherStatus = types.BluetoothLEAdvertisementWatcherStatus;
const BluetoothLEAdvertisementPublisherStatus = types.BluetoothLEAdvertisementPublisherStatus;
const BluetoothLEScanningMode = types.BluetoothLEScanningMode;
const BluetoothCacheMode = types.BluetoothCacheMode;
const GattCommunicationStatus = types.GattCommunicationStatus;
const GattWriteOption = types.GattWriteOption;
const GattClientCharacteristicConfigurationDescriptorValue = types.GattClientCharacteristicConfigurationDescriptorValue;
const GattProtectionLevel = types.GattProtectionLevel;
const DevicePairingProtectionLevel = types.DevicePairingProtectionLevel;
const DevicePairingResultStatus = types.DevicePairingResultStatus;
const DeviceUnpairingResultStatus = types.DeviceUnpairingResultStatus;

pub const IUnknown = extern struct {
    lpVtbl: *const IUnknownVtbl,

    pub inline fn queryInterface(self: *IUnknown, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.lpVtbl.QueryInterface(self, iid, out);
    }
    pub inline fn addRef(self: *IUnknown) ULONG {
        return self.lpVtbl.AddRef(self);
    }
    pub inline fn release(self: *IUnknown) ULONG {
        return self.lpVtbl.Release(self);
    }
};

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
};

pub const IInspectable = extern struct {
    lpVtbl: *const IInspectableVtbl,

    pub inline fn release(self: *IInspectable) ULONG {
        return self.lpVtbl.Release(self);
    }
    pub inline fn queryInterface(self: *IInspectable, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.lpVtbl.QueryInterface(self, iid, out);
    }
};

pub const IInspectableVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    // IInspectable
    GetIids: *const fn (self: *anyopaque, iidCount: *ULONG, iids: *?[*]GUID) callconv(WINAPI) HRESULT,
    GetRuntimeClassName: *const fn (self: *anyopaque, className: *HSTRING) callconv(WINAPI) HRESULT,
    GetTrustLevel: *const fn (self: *anyopaque, trustLevel: *TrustLevel) callconv(WINAPI) HRESULT,
};

pub const IClosable = extern struct {
    lpVtbl: *const IClosableVtbl,
};

pub const IClosableVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,
    Close: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};

pub const IDeferral = extern struct {
    lpVtbl: *const IDeferralVtbl,
};

pub const IDeferralVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,
    Complete: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};

/// Generic WinRT IAsyncInfo interface (queried from any IAsyncOperation<T>)
pub const IAsyncInfo = extern struct {
    lpVtbl: *const IAsyncInfoVtbl,
};

pub const IAsyncInfoVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Id: *const fn (self: *anyopaque, id: *u32) callconv(WINAPI) HRESULT,
    get_Status: *const fn (self: *anyopaque, status: *AsyncStatus) callconv(WINAPI) HRESULT,
    get_ErrorCode: *const fn (self: *anyopaque, errorCode: *HRESULT) callconv(WINAPI) HRESULT,
    Cancel: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    Close: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};

/// Generic layout for any `IAsyncOperation<T>` where `T` is a pointer or 32-bit enum/integer.
pub const IAsyncOperationGeneric = extern struct {
    lpVtbl: *const IAsyncOperationGenericVtbl,
};

pub const IAsyncOperationGenericVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    put_Completed: *const fn (self: *anyopaque, handler: ?*anyopaque) callconv(WINAPI) HRESULT,
    get_Completed: *const fn (self: *anyopaque, handler: *?*anyopaque) callconv(WINAPI) HRESULT,
    GetResults: *const fn (self: *anyopaque, results: *?*anyopaque) callconv(WINAPI) HRESULT,
};

/// Generic layout for `IVectorView<T*>`
pub const IVectorViewGeneric = extern struct {
    lpVtbl: *const IVectorViewGenericVtbl,
};

pub const IVectorViewGenericVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetAt: *const fn (self: *anyopaque, index: u32, item: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_Size: *const fn (self: *anyopaque, size: *u32) callconv(WINAPI) HRESULT,
    IndexOf: *const fn (self: *anyopaque, value: ?*anyopaque, index: *u32, found: *u8) callconv(WINAPI) HRESULT,
    GetMany: *const anyopaque,
};

/// Generic layout for `IVectorView<GUID>` (where GetAt returns a 128-bit GUID value)
pub const IVectorViewGuid = extern struct {
    lpVtbl: *const IVectorViewGuidVtbl,
};

pub const IVectorViewGuidVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetAt: *const fn (self: *anyopaque, index: u32, item: *GUID) callconv(WINAPI) HRESULT,
    get_Size: *const fn (self: *anyopaque, size: *u32) callconv(WINAPI) HRESULT,
    IndexOf: *const anyopaque,
    GetMany: *const anyopaque,
};

/// Generic layout for `IVector<GUID>` (mutable vector of GUIDs, e.g. `IBluetoothLEAdvertisement.get_ServiceUuids`)
pub const IVectorGuid = extern struct {
    lpVtbl: *const IVectorGuidVtbl,
};

pub const IVectorGuidVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetAt: *const fn (self: *anyopaque, index: u32, item: *GUID) callconv(WINAPI) HRESULT,
    get_Size: *const fn (self: *anyopaque, size: *u32) callconv(WINAPI) HRESULT,
    GetView: *const anyopaque,
    IndexOf: *const anyopaque,
    SetAt: *const anyopaque,
    InsertAt: *const anyopaque,
    RemoveAt: *const fn (self: *anyopaque, index: u32) callconv(WINAPI) HRESULT,
    Append: *const fn (self: *anyopaque, value: GUID) callconv(WINAPI) HRESULT,
    RemoveAtEnd: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    Clear: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};

/// Generic layout for `IVector<T*>` (mutable vector of COM pointers, e.g. `ManufacturerData` / `DataSections`)
pub const IVectorPtr = extern struct {
    lpVtbl: *const IVectorPtrVtbl,
};

pub const IVectorPtrVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetAt: *const fn (self: *anyopaque, index: u32, item: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_Size: *const fn (self: *anyopaque, size: *u32) callconv(WINAPI) HRESULT,
    GetView: *const anyopaque,
    IndexOf: *const anyopaque,
    SetAt: *const anyopaque,
    InsertAt: *const anyopaque,
    RemoveAt: *const fn (self: *anyopaque, index: u32) callconv(WINAPI) HRESULT,
    Append: *const fn (self: *anyopaque, value: ?*anyopaque) callconv(WINAPI) HRESULT,
    RemoveAtEnd: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    Clear: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};


// ============================================================================
// Storage.Streams.IBuffer & CryptographicBuffer
// ============================================================================

pub const IBuffer = extern struct {
    lpVtbl: *const IBufferVtbl,
};

pub const IBufferVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Capacity: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_Length: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    put_Length: *const fn (self: *anyopaque, value: u32) callconv(WINAPI) HRESULT,
};

/// Classic COM interface (`Windows.Storage.Streams.IBufferByteAccess`) to get raw `[*]u8` pointer directly!
pub const IBufferByteAccess = extern struct {
    lpVtbl: *const IBufferByteAccessVtbl,
};

pub const IBufferByteAccessVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,

    Buffer: *const fn (self: *anyopaque, value: *[*]u8) callconv(WINAPI) HRESULT,
};

pub const ICryptographicBufferStatics = extern struct {
    lpVtbl: *const ICryptographicBufferStaticsVtbl,
};

pub const ICryptographicBufferStaticsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    Compare: *const anyopaque,
    GenerateRandom: *const anyopaque,
    GenerateRandomNumber: *const anyopaque,
    CreateFromByteArray: *const fn (self: *anyopaque, valueLength: u32, value: [*]const u8, buffer: *?*IBuffer) callconv(WINAPI) HRESULT,
    CopyToByteArray: *const fn (self: *anyopaque, buffer: *IBuffer, valueLength: *u32, value: *?[*]u8) callconv(WINAPI) HRESULT,
};

