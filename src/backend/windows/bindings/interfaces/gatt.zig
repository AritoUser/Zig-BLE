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
pub const IBuffer = core_ifaces.IBuffer;
pub const IInspectable = core_ifaces.IInspectable;
pub const IDeferral = core_ifaces.IDeferral;


pub const IGattSession = extern struct {
    lpVtbl: *const IGattSessionVtbl,
};

pub const IGattSessionVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceId: *const fn (self: *anyopaque, value: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_CanMaintainConnection: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    put_MaintainConnection: *const fn (self: *anyopaque, value: u8) callconv(WINAPI) HRESULT,
    get_MaintainConnection: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    get_MaxPduSize: *const fn (self: *anyopaque, value: *u16) callconv(WINAPI) HRESULT,
    get_SessionStatus: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    add_MaxPduSizeChanged: *const anyopaque,
    remove_MaxPduSizeChanged: *const anyopaque,
    add_SessionStatusChanged: *const anyopaque,
    remove_SessionStatusChanged: *const anyopaque,
};

pub const IGattSessionStatics = extern struct {
    lpVtbl: *const IGattSessionStaticsVtbl,
};

pub const IGattSessionStaticsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    FromDeviceIdAsync: *const fn (self: *anyopaque, deviceId: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattDeviceServicesResult = extern struct {
    lpVtbl: *const IGattDeviceServicesResultVtbl,
};

pub const IGattDeviceServicesResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, value: *GattCommunicationStatus) callconv(WINAPI) HRESULT,
    get_ProtocolError: *const fn (self: *anyopaque, value: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_Services: *const fn (self: *anyopaque, value: *?*IVectorViewGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattDeviceService = extern struct {
    lpVtbl: *const IGattDeviceServiceVtbl,
};

pub const IGattDeviceServiceVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetCharacteristics: *const anyopaque,
    GetIncludedServices: *const anyopaque,
    get_DeviceId: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_Uuid: *const fn (self: *anyopaque, value: *GUID) callconv(WINAPI) HRESULT,
    get_AttributeHandle: *const fn (self: *anyopaque, value: *u16) callconv(WINAPI) HRESULT,
};

pub const IGattDeviceService3 = extern struct {
    lpVtbl: *const IGattDeviceService3Vtbl,
};

pub const IGattDeviceService3Vtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_DeviceAccessInformation: *const anyopaque,
    get_Session: *const fn (self: *anyopaque, value: *?*IGattSession) callconv(WINAPI) HRESULT,
    get_SharingMode: *const anyopaque,
    RequestAccessAsync: *const anyopaque,
    OpenAsync: *const anyopaque,
    GetCharacteristicsAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetCharacteristicsWithCacheModeAsync: *const fn (self: *anyopaque, cacheMode: BluetoothCacheMode, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetCharacteristicsForUuidAsync: *const fn (self: *anyopaque, characteristicUuid: GUID, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    GetCharacteristicsForUuidWithCacheModeAsync: *const fn (self: *anyopaque, characteristicUuid: GUID, cacheMode: BluetoothCacheMode, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattCharacteristicsResult = extern struct {
    lpVtbl: *const IGattCharacteristicsResultVtbl,
};

pub const IGattCharacteristicsResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, value: *GattCommunicationStatus) callconv(WINAPI) HRESULT,
    get_ProtocolError: *const fn (self: *anyopaque, value: *?*anyopaque) callconv(WINAPI) HRESULT,
    get_Characteristics: *const fn (self: *anyopaque, value: *?*IVectorViewGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattCharacteristic = extern struct {
    lpVtbl: *const IGattCharacteristicVtbl,
};

pub const IGattCharacteristicVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    GetDescriptors: *const anyopaque,
    get_CharacteristicProperties: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_ProtectionLevel: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    get_UserDescription: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_Uuid: *const fn (self: *anyopaque, value: *GUID) callconv(WINAPI) HRESULT,
    get_AttributeHandle: *const fn (self: *anyopaque, value: *u16) callconv(WINAPI) HRESULT,
    get_PresentationFormats: *const anyopaque,
    ReadValueAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    ReadValueWithCacheModeAsync: *const fn (self: *anyopaque, cacheMode: BluetoothCacheMode, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    WriteValueAsync: *const fn (self: *anyopaque, value: *IBuffer, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    WriteValueWithOptionAsync: *const fn (self: *anyopaque, value: *IBuffer, writeOption: GattWriteOption, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    ReadClientCharacteristicConfigurationDescriptorAsync: *const anyopaque,
    WriteClientCharacteristicConfigurationDescriptorAsync: *const fn (self: *anyopaque, cccdValue: GattClientCharacteristicConfigurationDescriptorValue, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    add_ValueChanged: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_ValueChanged: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
};

pub const IGattReadResult = extern struct {
    lpVtbl: *const IGattReadResultVtbl,
};

pub const IGattReadResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Status: *const fn (self: *anyopaque, value: *GattCommunicationStatus) callconv(WINAPI) HRESULT,
    get_Value: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
};

pub const IGattValueChangedEventArgs = extern struct {
    lpVtbl: *const IGattValueChangedEventArgsVtbl,
};

pub const IGattValueChangedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_CharacteristicValue: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    get_Timestamp: *const fn (self: *anyopaque, value: *i64) callconv(WINAPI) HRESULT,
};

// ============================================================================
// GATT Server (GattServiceProvider, IGattLocalService, IGattLocalCharacteristic)
// ============================================================================

pub const IGattServiceProviderStatics = extern struct {
    lpVtbl: *const IGattServiceProviderStaticsVtbl,
};

pub const IGattServiceProviderStaticsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    CreateAsync: *const fn (self: *anyopaque, serviceUuid: GUID, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattServiceProviderResult = extern struct {
    lpVtbl: *const IGattServiceProviderResultVtbl,
};

pub const IGattServiceProviderResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Error: *const fn (self: *anyopaque, value: *BluetoothError) callconv(WINAPI) HRESULT,
    get_ServiceProvider: *const fn (self: *anyopaque, value: *?*IGattServiceProvider) callconv(WINAPI) HRESULT,
};

pub const IGattServiceProvider = extern struct {
    lpVtbl: *const IGattServiceProviderVtbl,
};

pub const IGattServiceProviderVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Service: *const fn (self: *anyopaque, value: *?*IGattLocalService) callconv(WINAPI) HRESULT,
    get_AdvertisementStatus: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    add_AdvertisementStatusChanged: *const anyopaque,
    remove_AdvertisementStatusChanged: *const anyopaque,
    StartAdvertising: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    StartAdvertisingWithParameters: *const fn (self: *anyopaque, parameters: *IGattServiceProviderAdvertisingParameters) callconv(WINAPI) HRESULT,
    StopAdvertising: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
};

pub const IGattServiceProviderAdvertisingParameters = extern struct {
    lpVtbl: *const IGattServiceProviderAdvertisingParametersVtbl,
};

pub const IGattServiceProviderAdvertisingParametersVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    put_IsConnectable: *const fn (self: *anyopaque, value: u8) callconv(WINAPI) HRESULT,
    get_IsConnectable: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
    put_IsDiscoverable: *const fn (self: *anyopaque, value: u8) callconv(WINAPI) HRESULT,
    get_IsDiscoverable: *const fn (self: *anyopaque, value: *u8) callconv(WINAPI) HRESULT,
};

pub const IGattLocalService = extern struct {
    lpVtbl: *const IGattLocalServiceVtbl,
};

pub const IGattLocalServiceVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Uuid: *const fn (self: *anyopaque, value: *GUID) callconv(WINAPI) HRESULT,
    CreateCharacteristicAsync: *const fn (self: *anyopaque, characteristicUuid: GUID, parameters: *IGattLocalCharacteristicParameters, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    get_Characteristics: *const fn (self: *anyopaque, value: *?*IVectorViewGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattLocalCharacteristicParameters = extern struct {
    lpVtbl: *const IGattLocalCharacteristicParametersVtbl,
};

pub const IGattLocalCharacteristicParametersVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    put_StaticValue: *const fn (self: *anyopaque, value: *IBuffer) callconv(WINAPI) HRESULT,
    get_StaticValue: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    put_CharacteristicProperties: *const fn (self: *anyopaque, value: u32) callconv(WINAPI) HRESULT,
    get_CharacteristicProperties: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    put_ReadProtectionLevel: *const fn (self: *anyopaque, value: GattProtectionLevel) callconv(WINAPI) HRESULT,
    get_ReadProtectionLevel: *const fn (self: *anyopaque, value: *GattProtectionLevel) callconv(WINAPI) HRESULT,
    put_WriteProtectionLevel: *const fn (self: *anyopaque, value: GattProtectionLevel) callconv(WINAPI) HRESULT,
    get_WriteProtectionLevel: *const fn (self: *anyopaque, value: *GattProtectionLevel) callconv(WINAPI) HRESULT,
    put_UserDescription: *const fn (self: *anyopaque, value: HSTRING) callconv(WINAPI) HRESULT,
    get_UserDescription: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_PresentationFormats: *const anyopaque,
};

pub const IGattLocalCharacteristicResult = extern struct {
    lpVtbl: *const IGattLocalCharacteristicResultVtbl,
};

pub const IGattLocalCharacteristicResultVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Characteristic: *const fn (self: *anyopaque, value: *?*IGattLocalCharacteristic) callconv(WINAPI) HRESULT,
    get_Error: *const fn (self: *anyopaque, value: *BluetoothError) callconv(WINAPI) HRESULT,
};

pub const IGattLocalCharacteristic = extern struct {
    lpVtbl: *const IGattLocalCharacteristicVtbl,
};

pub const IGattLocalCharacteristicVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Uuid: *const fn (self: *anyopaque, value: *GUID) callconv(WINAPI) HRESULT,
    get_StaticValue: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    get_CharacteristicProperties: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_ReadProtectionLevel: *const fn (self: *anyopaque, value: *GattProtectionLevel) callconv(WINAPI) HRESULT,
    get_WriteProtectionLevel: *const fn (self: *anyopaque, value: *GattProtectionLevel) callconv(WINAPI) HRESULT,
    CreateDescriptorAsync: *const anyopaque,
    get_Descriptors: *const anyopaque,
    get_UserDescription: *const fn (self: *anyopaque, value: *HSTRING) callconv(WINAPI) HRESULT,
    get_PresentationFormats: *const anyopaque,
    get_SubscribedClients: *const anyopaque,
    add_SubscribedClientsChanged: *const anyopaque,
    remove_SubscribedClientsChanged: *const anyopaque,
    add_ReadRequested: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_ReadRequested: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
    add_WriteRequested: *const fn (self: *anyopaque, handler: *anyopaque, token: *EventRegistrationToken) callconv(WINAPI) HRESULT,
    remove_WriteRequested: *const fn (self: *anyopaque, token: EventRegistrationToken) callconv(WINAPI) HRESULT,
    NotifyValueAsync: *const fn (self: *anyopaque, value: *IBuffer, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
    NotifyValueForSubscribedClientAsync: *const anyopaque,
};

pub const IGattReadRequestedEventArgs = extern struct {
    lpVtbl: *const IGattReadRequestedEventArgsVtbl,
};

pub const IGattReadRequestedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Session: *const fn (self: *anyopaque, value: *?*IGattSession) callconv(WINAPI) HRESULT,
    GetDeferral: *const fn (self: *anyopaque, value: *?*IDeferral) callconv(WINAPI) HRESULT,
    GetRequestAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattReadRequest = extern struct {
    lpVtbl: *const IGattReadRequestVtbl,
};

pub const IGattReadRequestVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Offset: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_Length: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_State: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    add_StateChanged: *const anyopaque,
    remove_StateChanged: *const anyopaque,
    RespondWithValue: *const fn (self: *anyopaque, value: *IBuffer) callconv(WINAPI) HRESULT,
    RespondWithProtocolError: *const fn (self: *anyopaque, protocolError: u8) callconv(WINAPI) HRESULT,
};

pub const IGattWriteRequestedEventArgs = extern struct {
    lpVtbl: *const IGattWriteRequestedEventArgsVtbl,
};

pub const IGattWriteRequestedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Session: *const fn (self: *anyopaque, value: *?*IGattSession) callconv(WINAPI) HRESULT,
    GetDeferral: *const fn (self: *anyopaque, value: *?*IDeferral) callconv(WINAPI) HRESULT,
    GetRequestAsync: *const fn (self: *anyopaque, operation: *?*IAsyncOperationGeneric) callconv(WINAPI) HRESULT,
};

pub const IGattWriteRequest = extern struct {
    lpVtbl: *const IGattWriteRequestVtbl,
};

pub const IGattWriteRequestVtbl = extern struct {
    QueryInterface: *const fn (self: *anyopaque, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    Release: *const fn (self: *anyopaque) callconv(WINAPI) ULONG,
    GetIids: *const anyopaque,
    GetRuntimeClassName: *const anyopaque,
    GetTrustLevel: *const anyopaque,

    get_Value: *const fn (self: *anyopaque, value: *?*IBuffer) callconv(WINAPI) HRESULT,
    get_Offset: *const fn (self: *anyopaque, value: *u32) callconv(WINAPI) HRESULT,
    get_Option: *const fn (self: *anyopaque, value: *GattWriteOption) callconv(WINAPI) HRESULT,
    get_State: *const fn (self: *anyopaque, value: *i32) callconv(WINAPI) HRESULT,
    add_StateChanged: *const anyopaque,
    remove_StateChanged: *const anyopaque,
    Respond: *const fn (self: *anyopaque) callconv(WINAPI) HRESULT,
    RespondWithProtocolError: *const fn (self: *anyopaque, protocolError: u8) callconv(WINAPI) HRESULT,
};

