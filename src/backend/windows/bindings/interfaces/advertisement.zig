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

const core_ifaces = @import("core.zig");
pub const IAsyncOperationGeneric = core_ifaces.IAsyncOperationGeneric;
pub const IVectorGuid = core_ifaces.IVectorGuid;
pub const IVectorPtr = core_ifaces.IVectorPtr;
pub const IBuffer = core_ifaces.IBuffer;

// ============================================================================
// BluetoothAdapter Interfaces
// ============================================================================

pub const IBluetoothAdapterStatics = extern struct {
    lpVtbl: *const IBluetoothAdapterStaticsVtbl,
};

pub const IBluetoothAdapterStaticsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetDeviceSelector: *const fn (self: *anyopaque, result: *HSTRING) callconv(WINAPI) HRESULT,
    FromIdAsync: *const fn (self: *anyopaque, deviceId: HSTRING, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetDefaultAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IBluetoothAdapter = extern struct {
    lpVtbl: *const IBluetoothAdapterVtbl,
};

pub const IBluetoothAdapterVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceId: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_BluetoothAddress: *const fn (self: *anyopaque, value: *u64) callconv(WINAPI) HRESULT,
    get_IsClassicSupported: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_IsLowEnergySupported: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_IsPeripheralRoleSupported: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_IsCentralRoleSupported: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_IsAdvertisementOffloadSupported: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    GetRadioAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

// ============================================================================
// BluetoothLEAdvertisementWatcher, Publisher & Event Args
// ============================================================================

pub const IBluetoothLEAdvertisementWatcher = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementWatcherVtbl,
};

pub const IBluetoothLEAdvertisementWatcherVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_MinSamplingInterval: *const anyopaque,
    get_MaxSamplingInterval: *const anyopaque,
    get_MinOutOfRangeTimeout: *const anyopaque,
    get_MaxOutOfRangeTimeout: *const anyopaque,
    get_Status: *const fn (self: *anyopaque, value: *BluetoothLEAdvertisementWatcherStatus) callconv(WINAPI) HRESULT,
    get_ScanningMode: *const fn (self: *anyopaque, value: *BluetoothLEScanningMode) callconv(WINAPI) HRESULT,
    put_ScanningMode: *const fn (self: *anyopaque, value: BluetoothLEScanningMode) callconv(WINAPI) HRESULT,
    get_SignalStrengthFilter: *const anyopaque,
    put_SignalStrengthFilter: *const anyopaque,
    get_AdvertisementFilter: *const anyopaque,
    put_AdvertisementFilter: *const anyopaque,
    Start: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    Stop: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    add_Received: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_Received: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
    add_Stopped: *const anyopaque,
    remove_Stopped: *const anyopaque,
};

pub const IBluetoothLEAdvertisementReceivedEventArgs = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementReceivedEventArgsVtbl,
};

pub const IBluetoothLEAdvertisementReceivedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_RawSignalStrengthInDBm: *const fn (self: *anyopaque, value: *i16) callconv(WINAPI) HRESULT,
    get_BluetoothAddress: *const fn (self: *anyopaque, value: *u64) callconv(WINAPI) HRESULT,
    get_AdvertisementType: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    get_Timestamp: *const fn (self: *anyopaque, value: *i64) callconv(WINAPI) HRESULT,
    get_Advertisement: *const fn (self: *anyopaque, value: *?*IBluetoothLEAdvertisement) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEAdvertisement = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementVtbl,
};

pub const IBluetoothLEAdvertisementVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Flags: *const anyopaque,
    put_Flags: *const anyopaque,
    get_LocalName: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    put_LocalName: *const fn (self: *anyopaque, value: HSTRING) callconv(WINAPI) HRESULT,
    get_ServiceUuids: *const fn (self: *anyopaque, value: *?*IVectorGuid) callconv(WINAPI) HRESULT,
    get_ManufacturerData: *const fn (self: *anyopaque, value: *?*IVectorPtr) callconv(WINAPI) HRESULT,
    get_DataSections: *const fn (self: *anyopaque, value: *?*IVectorPtr) callconv(WINAPI) HRESULT,
    GetManufacturerDataByCompanyId: *const anyopaque,
    GetSectionsByType: *const anyopaque,
};

pub const IBluetoothLEManufacturerData = extern struct {
    lpVtbl: *const IBluetoothLEManufacturerDataVtbl,
};

pub const IBluetoothLEManufacturerDataVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_CompanyId: *const fn (self: *anyopaque, value: *u16) callconv(WINAPI) HRESULT,
    put_CompanyId: *const fn (self: *anyopaque, value: u16) callconv(WINAPI) HRESULT,
    get_Data: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    put_Data: *const fn (self: *anyopaque, value: *IBuffer) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEManufacturerDataFactory = extern struct {
    lpVtbl: *const IBluetoothLEManufacturerDataFactoryVtbl,
};

pub const IBluetoothLEManufacturerDataFactoryVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    Create: *const fn (self: *anyopaque, companyId: u16, data: *IBuffer, value: *?*IBluetoothLEManufacturerData) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEAdvertisementDataSection = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementDataSectionVtbl,
};

pub const IBluetoothLEAdvertisementDataSectionVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DataType: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    put_DataType: *const fn (self: *anyopaque, value: u8) callconv(WINAPI) HRESULT,
    get_Data: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    put_Data: *const fn (self: *anyopaque, value: *IBuffer) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEAdvertisementDataSectionFactory = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementDataSectionFactoryVtbl,
};

pub const IBluetoothLEAdvertisementDataSectionFactoryVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    Create: *const fn (self: *anyopaque, dataType: u8, data: *IBuffer, value: *?*IBluetoothLEAdvertisementDataSection) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEAdvertisementPublisher = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementPublisherVtbl,
};

pub const IBluetoothLEAdvertisementPublisherVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, value: *BluetoothLEAdvertisementPublisherStatus) callconv(WINAPI) HRESULT,
    get_Advertisement: *const fn (self: *anyopaque, value: *?*IBluetoothLEAdvertisement) callconv(WINAPI) HRESULT,
    Start: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    Stop: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    add_StatusChanged: *const anyopaque,
    remove_StatusChanged: *const anyopaque,
};

pub const IBluetoothLEAdvertisementPublisherFactory = extern struct {
    lpVtbl: *const IBluetoothLEAdvertisementPublisherFactoryVtbl,
};

pub const IBluetoothLEAdvertisementPublisherFactoryVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    Create: *const fn (self: *anyopaque, advertisement: *IBluetoothLEAdvertisement, value: *?*IBluetoothLEAdvertisementPublisher) callconv(WINAPI) HRESULT,
};

// ============================================================================
