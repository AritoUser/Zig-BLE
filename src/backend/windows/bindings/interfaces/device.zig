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
pub const IVectorViewGeneric = core_ifaces.IVectorViewGeneric;
pub const IInspectableVtbl = core_ifaces.IInspectableVtbl;
pub const IDeferral = core_ifaces.IDeferral;
const gatt_ifaces = @import("gatt.zig");
pub const IGattDeviceService = gatt_ifaces.IGattDeviceService;

// BluetoothLEDevice, GattSession, and DeviceInformationPairing Interfaces
// ============================================================================

pub const IBluetoothLEDeviceStatics = extern struct {
    lpVtbl: *const IBluetoothLEDeviceStaticsVtbl,
};

pub const IBluetoothLEDeviceStaticsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    FromIdAsync: *const fn (self: *anyopaque, deviceId: HSTRING, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    FromBluetoothAddressAsync: *const fn (self: *anyopaque, bluetoothAddress: u64, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetDeviceSelector: *const fn (self: *anyopaque, deviceSelector: *HSTRING) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEDevice = extern struct {
    lpVtbl: *const IBluetoothLEDeviceVtbl,
};

pub const IBluetoothLEDeviceVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceId: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_Name: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_GattServices: *const fn (self: *anyopaque, value: *?*IVectorViewGeneric) callconv(WINAPI) HRESULT,
    get_ConnectionStatus: *const fn (self: *anyopaque, value: *BluetoothConnectionStatus) callconv(WINAPI) HRESULT,
    get_BluetoothAddress: *const fn (self: *anyopaque, value: *u64) callconv(WINAPI) HRESULT,
    GetGattService: *const fn (self: *anyopaque, serviceUuid: GUID, service: *?*IGattDeviceService) callconv(WINAPI) HRESULT,
    add_NameChanged: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_NameChanged: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
    add_GattServicesChanged: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_GattServicesChanged: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
    add_ConnectionStatusChanged: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_ConnectionStatusChanged: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEDevice2 = extern struct {
    lpVtbl: *const IBluetoothLEDevice2Vtbl,
};

pub const IBluetoothLEDevice2Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceInformation: *const fn (self: *anyopaque, value: *?*IDeviceInformation) callconv(WINAPI) HRESULT,
    get_Appearance: *const fn (self: *anyopaque, value: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_BluetoothAddressType: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEDevice3 = extern struct {
    lpVtbl: *const IBluetoothLEDevice3Vtbl,
};

pub const IBluetoothLEDevice3Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceAccessInformation: *const anyopaque,
    RequestAccessAsync: *const anyopaque,
    GetGattServicesAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetGattServicesWithCacheModeAsync: *const fn (self: *anyopaque, cacheMode: BluetoothCacheMode, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetGattServicesForUuidAsync: *const fn (self: *anyopaque, serviceUuid: GUID, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetGattServicesForUuidWithCacheModeAsync: *const fn (self: *anyopaque, serviceUuid: GUID, cacheMode: BluetoothCacheMode, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IBluetoothLEDevice4 = extern struct {
    lpVtbl: *const IBluetoothLEDevice4Vtbl,
};

pub const IBluetoothLEDevice4Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_BluetoothDeviceId: *const fn (self: *anyopaque, value: *?*anyopaque) callconv(WINAPI) HRESULT,
};


pub const IDeviceInformation = extern struct {
    lpVtbl: *const IInspectableVtbl,
};

pub const IDeviceInformation2 = extern struct {
    lpVtbl: *const IDeviceInformation2Vtbl,
};

pub const IDeviceInformation2Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Kind: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    get_Pairing: *const fn (self: *anyopaque, value: *?*IDeviceInformationPairing) callconv(WINAPI) HRESULT,
};

pub const IDeviceInformationPairing = extern struct {
    lpVtbl: *const IDeviceInformationPairingVtbl,
};

pub const IDeviceInformationPairingVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_IsPaired: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_CanPair: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    PairAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    PairWithProtectionLevelAsync: *const fn (self: *anyopaque, minProtectionLevel: DevicePairingProtectionLevel, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IDeviceInformationPairing2 = extern struct {
    lpVtbl: *const IDeviceInformationPairing2Vtbl,
};

pub const IDeviceInformationPairing2Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_ProtectionLevel: *const fn (self: *anyopaque, value: *DevicePairingProtectionLevel) callconv(WINAPI) HRESULT,
    get_Custom: *const fn (self: *anyopaque, value: *?*IDeviceInformationCustomPairing) callconv(WINAPI) HRESULT,
    PairWithProtectionLevelAndSettingsAsync: *const anyopaque,
    UnpairAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IDeviceInformationCustomPairing = extern struct {
    lpVtbl: *const IDeviceInformationCustomPairingVtbl,
};

pub const IDeviceInformationCustomPairingVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    PairAsync: *const fn (self: *anyopaque, pairingKindsSupported: u32, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    PairWithProtectionLevelAsync: *const fn (self: *anyopaque, pairingKindsSupported: u32, minProtectionLevel: DevicePairingProtectionLevel, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    PairWithProtectionLevelAndSettingsAsync: *const anyopaque,
    add_PairingRequested: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_PairingRequested: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
};

pub const IDevicePairingRequestedEventArgs = extern struct {
    lpVtbl: *const IDevicePairingRequestedEventArgsVtbl,
};

pub const IDevicePairingRequestedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceInformation: *const fn (self: *anyopaque, value: *?*IDeviceInformation) callconv(WINAPI) HRESULT,
    get_PairingKind: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_Pin: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    Accept: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    AcceptWithPin: *const fn (self: *anyopaque, pin: HSTRING) callconv(WINAPI) HRESULT,
    GetDeferral: *const fn (self: *anyopaque, result: *?*IDeferral) callconv(WINAPI) HRESULT,
};

pub const IDevicePairingResult = extern struct {
    lpVtbl: *const IDevicePairingResultVtbl,
};

pub const IDevicePairingResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, status: *DevicePairingResultStatus) callconv(WINAPI) HRESULT,
    get_ProtectionLevelUsed: *const fn (self: *anyopaque, value: *DevicePairingProtectionLevel) callconv(WINAPI) HRESULT,
};

pub const IDeviceUnpairingResult = extern struct {
    lpVtbl: *const IDeviceUnpairingResultVtbl,
};

pub const IDeviceUnpairingResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, status: *DeviceUnpairingResultStatus) callconv(WINAPI) HRESULT,
};

// ============================================================================
// GATT Client Services & Characteristics Interfaces
// ============================================================================

