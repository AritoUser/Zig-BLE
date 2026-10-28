//! # Native Windows WinRT BLE COM Bindings (Zero-Dependency)
//!
//! Pure-Zig COM VTable definitions, GUIDs, and HSTRING helpers for the
//! Windows 10/11 `Windows.Devices.Bluetooth` WinRT APIs.
//! Requires zero C/C++ headers, zero WinMD parsers, and zero external libraries.
//!
//! ## Concurrency & Callback Threading Model
//! - WinRT invokes COM event handlers (`AdvertisementWatcherReceivedHandler`, `GattValueChangedHandler`,
//!   `ConnectionStatusChangedHandler`, `PairingRequestedHandler`, `GattReadRequestedHandler`,
//!   `GattWriteRequestedHandler`) on threads from the Windows MTA (Multi-Threaded Apartment) thread pool.
//! - Every COM delegate carries an atomic `active: std.atomic.Value(bool)` guard and an atomic `ref_count`.
//!   Calling `deactivate()` ensures that no user callback is ever invoked after `unsubscribe` / `stopScan` / `deinit`.

const std = @import("std");
const builtin = @import("builtin");

/// WinRT/COM calling convention. Falls back to the C convention on non-Windows targets so these
/// declarations still type-check there (e.g. `aarch64-macos` has no `.winapi` convention).
pub const WINAPI: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const HRESULT = i32;
pub const ULONG = u32;
pub const HSTRING = ?*anyopaque;
pub const EventRegistrationToken = i64;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

pub const RO_INIT_MULTITHREADED: u32 = 1;

pub const TrustLevel = enum(i32) {
    BaseTrust = 0,
    PartialTrust = 1,
    FullTrust = 2,
};

pub const AsyncStatus = enum(i32) {
    Started = 0,
    Completed = 1,
    Canceled = 2,
    Error = 3,
};

pub const BluetoothConnectionStatus = enum(i32) {
    Disconnected = 0,
    Connected = 1,
};

pub const BluetoothError = enum(i32) {
    Success = 0,
    RadioNotAvailable = 1,
    ResourceInUse = 2,
    DeviceNotConnected = 3,
    OtherError = 4,
    DisabledByPolicy = 5,
    NotSupported = 6,
    DisabledByUser = 7,
    ConsentRequired = 8,
    TransportNotSupported = 9,
};

pub const BluetoothLEAdvertisementWatcherStatus = enum(i32) {
    Created = 0,
    Started = 1,
    Stopping = 2,
    Stopped = 3,
    Aborted = 4,
};

pub const BluetoothLEAdvertisementPublisherStatus = enum(i32) {
    Created = 0,
    Waiting = 1,
    Started = 2,
    Stopping = 3,
    Stopped = 4,
    Aborted = 5,
};

pub const BluetoothLEScanningMode = enum(i32) {
    Passive = 0,
    Active = 1,
    None = 2,
};

pub const BluetoothCacheMode = enum(i32) {
    Cached = 0,
    Uncached = 1,
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

pub const GattProtectionLevel = enum(i32) {
    Plain = 0,
    AuthenticationRequired = 1,
    EncryptionRequired = 2,
    EncryptionAndAuthenticationRequired = 3,
};

pub const GattCharacteristicProperties = struct {
    pub const None: u32 = 0;
    pub const Broadcast: u32 = 0x1;
    pub const Read: u32 = 0x2;
    pub const WriteWithoutResponse: u32 = 0x4;
    pub const Write: u32 = 0x8;
    pub const Notify: u32 = 0x10;
    pub const Indicate: u32 = 0x20;
    pub const AuthenticatedSignedWrites: u32 = 0x40;
    pub const ExtendedProperties: u32 = 0x80;
    pub const ReliableWrites: u32 = 0x100;
    pub const WritableAuxiliaries: u32 = 0x200;
};

pub const DevicePairingKinds = struct {
    pub const None: u32 = 0;
    pub const ConfirmOnly: u32 = 0x1;
    pub const DisplayPin: u32 = 0x2;
    pub const ProvidePin: u32 = 0x4;
    pub const ConfirmPinMatch: u32 = 0x8;
    pub const ProvidePasswordCredential: u32 = 0x10;
};

pub const DevicePairingProtectionLevel = enum(i32) {
    Default = 0,
    None = 1,
    Encryption = 2,
    EncryptionAndAuthentication = 3,
};

pub const DevicePairingResultStatus = enum(i32) {
    Paired = 0,
    NotReadyToPair = 1,
    NotPaired = 2,
    AlreadyPaired = 3,
    ConnectionRejected = 4,
    TooManyConnections = 5,
    HardwareFailure = 6,
    AuthenticationTimeout = 7,
    AuthenticationNotAllowed = 8,
    AuthenticationFailure = 9,
    NoSupportedProfiles = 10,
    ProtectionLevelCouldNotBeMet = 11,
    AccessDenied = 12,
    InvalidCeremonyData = 13,
    PairingCanceled = 14,
    OperationAlreadyInProgress = 15,
    RequiredHandlerNotRegistered = 16,
    RejectedByHandler = 17,
    RemoteDeviceHasAssociation = 18,
    Failed = 19,
};

pub const DeviceUnpairingResultStatus = enum(i32) {
    Unpaired = 0,
    AlreadyUnpaired = 1,
    OperationAlreadyInProgress = 2,
    AccessDenied = 3,
    Failed = 4,
};

/// Standard 128-bit COM GUID (Little-Endian data1/2/3, big-endian data4)
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn parse(comptime str: []const u8) GUID {
        comptime {
            if (str.len != 36) @compileError("GUID string must be 36 chars");
            const d1 = std.fmt.parseInt(u32, str[0..8], 16) catch unreachable;
            const d2 = std.fmt.parseInt(u16, str[9..13], 16) catch unreachable;
            const d3 = std.fmt.parseInt(u16, str[14..18], 16) catch unreachable;
            var d4: [8]u8 = undefined;
            d4[0] = std.fmt.parseInt(u8, str[19..21], 16) catch unreachable;
            d4[1] = std.fmt.parseInt(u8, str[21..23], 16) catch unreachable;
            d4[2] = std.fmt.parseInt(u8, str[24..26], 16) catch unreachable;
            d4[3] = std.fmt.parseInt(u8, str[26..28], 16) catch unreachable;
            d4[4] = std.fmt.parseInt(u8, str[28..30], 16) catch unreachable;
            d4[5] = std.fmt.parseInt(u8, str[30..32], 16) catch unreachable;
            d4[6] = std.fmt.parseInt(u8, str[32..34], 16) catch unreachable;
            d4[7] = std.fmt.parseInt(u8, str[34..36], 16) catch unreachable;
            return GUID{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
        }
    }

    pub fn eql(a: GUID, b: GUID) bool {
        return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and std.mem.eql(u8, &a.Data4, &b.Data4);
    }
};

// ============================================================================
// Core WinRT & Bluetooth Interface GUIDs (Verified from Windows 10 SDK 10.0.19041.0)
// ============================================================================

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
pub const IID_IInspectable = GUID.parse("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
pub const IID_IAgileObject = GUID.parse("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
pub const IID_IActivationFactory = GUID.parse("00000035-0000-0000-c000-000000000046");
pub const IID_IAsyncInfo = GUID.parse("00000036-0000-0000-c000-000000000046");
pub const IID_IClosable = GUID.parse("30d5a829-7fa4-4026-83bb-d75bae4ea99e");
pub const IID_IDeferral = GUID.parse("d6269732-3b7f-46a7-b40b-4fdca2a2c693");

// BluetoothAdapter
pub const IID_IBluetoothAdapterStatics = GUID.parse("8b02fb6a-ac4c-4741-8661-8eab7d17ea9f");
pub const IID_IBluetoothAdapter = GUID.parse("7974f04c-5f7a-4a34-9225-a855f84b1a8b");

// BluetoothLEAdvertisementWatcher & Args
pub const IID_IBluetoothLEAdvertisementWatcher = GUID.parse("a6ac336f-f3d3-4297-8d6c-c81ea6623f40");
pub const IID_IBluetoothLEAdvertisementReceivedEventArgs = GUID.parse("27987ddf-e596-41be-8d43-9e6731d4a913");
pub const IID_IBluetoothLEAdvertisement = GUID.parse("066fb2b7-33d1-4e7d-8367-cf81d0f79653");
pub const IID_IBluetoothLEManufacturerData = GUID.parse("912dba18-6963-4533-b061-4694dafb34e5");
pub const IID_IBluetoothLEManufacturerDataFactory = GUID.parse("c09b39f8-319a-441e-8de5-66a81e877a6c");
pub const IID_IBluetoothLEAdvertisementDataSection = GUID.parse("d7213314-3a43-40f9-b6f0-92bfefc34ae3");
pub const IID_IBluetoothLEAdvertisementDataSectionFactory = GUID.parse("e7a40942-a845-4045-bf7e-3e9971db8a6b");
pub const IID_IBluetoothLEAdvertisementPublisher = GUID.parse("cde820f9-d9fa-43d6-a264-ddd8b7da8b78");
pub const IID_IBluetoothLEAdvertisementPublisherFactory = GUID.parse("5c5f065e-b863-4981-a1af-1c544d8b0c0d");
pub const IID_ITypedEventHandler_Watcher_Received = GUID.parse("90eb4eca-d465-5ea0-a61c-033c8c5ecebe");

// BluetoothLEDevice & GattSession
pub const IID_IBluetoothLEDeviceStatics = GUID.parse("c8cf1a19-f0b6-4bf0-8689-41303de2d9f4");
pub const IID_IBluetoothLEDevice = GUID.parse("b5ee2f7b-4ad8-4642-ac48-80a0b500e887");
pub const IID_IBluetoothLEDevice2 = GUID.parse("26f062b3-7aee-4d31-baba-b1b9775f5916");
pub const IID_IBluetoothLEDevice3 = GUID.parse("aee9e493-44ac-40dc-af33-b2c13c01ca46");
pub const IID_IBluetoothLEDevice4 = GUID.parse("2b605031-2248-4b2f-acf0-7cee36fc5870");
pub const IID_IBluetoothDeviceId = GUID.parse("c17949af-57c1-4642-bcce-e6c06b20ae76");
pub const IID_IBluetoothDeviceIdStatics = GUID.parse("a7884e67-3efb-4f31-bbc2-810e09977404");
pub const IID_IGattSession = GUID.parse("d23b5143-e04e-4c24-999c-9c256f9856b1");
pub const IID_IGattSessionStatics = GUID.parse("2e65b95c-539f-4db7-82a8-73bdbbf73ebf");
pub const IID_ITypedEventHandler_BluetoothLEDevice_IInspectable = GUID.parse("a90661e2-372e-5d1e-bbbb-b8a2ce0e7c4d");

// DeviceInformation & Pairing (Windows.Devices.Enumeration)
pub const IID_IDeviceInformation = GUID.parse("aba0fb95-4398-489d-8e44-e6130927011f");
pub const IID_IDeviceInformation2 = GUID.parse("f156a638-7997-48d9-a10c-269d46533f48");
pub const IID_IDeviceInformationPairing = GUID.parse("2c4769f5-f684-40d5-8469-e8dbaab70485");
pub const IID_IDeviceInformationPairing2 = GUID.parse("f68612fd-0aee-4328-85cc-1c742bb1790d");
pub const IID_IDeviceInformationCustomPairing = GUID.parse("85138c02-4ee6-4914-8370-107a39144c0e");
pub const IID_IDevicePairingRequestedEventArgs = GUID.parse("f717fc56-de6b-487f-8376-0180aca69963");
pub const IID_IDevicePairingResult = GUID.parse("072b02bf-dd95-4025-9b37-de51adba37b7");
pub const IID_IDeviceUnpairingResult = GUID.parse("66f44ad3-79d9-444b-92cf-a92ef72571c7");
pub const IID_ITypedEventHandler_CustomPairing_PairingRequested = GUID.parse("fa65231f-4178-5de1-b2cc-03e22d7702b4");

// GATT Client Services & Characteristics
pub const IID_IGattDeviceServicesResult = GUID.parse("16cab870-8b34-4723-92f4-f0c057c75b2b");
pub const IID_IGattDeviceService = GUID.parse("ac7b7c05-b33c-47cf-b70f-f88f55775d71");
pub const IID_IGattDeviceService3 = GUID.parse("b293a950-0c53-437c-a9b3-5c3210c6e569");
pub const IID_IGattCharacteristicsResult = GUID.parse("e20a3371-33c7-4f08-a698-d58c17184f06");
pub const IID_IGattCharacteristic = GUID.parse("59cb50c1-5934-4f68-a198-eb864fa44e6b");
pub const IID_IGattReadResult = GUID.parse("63a66f08-17a6-4c4e-8999-a97f3126b508");
pub const IID_IGattWriteResult = GUID.parse("4907627f-283c-48c0-9d98-9811b69c6533");
pub const IID_IGattValueChangedEventArgs = GUID.parse("d21b60f2-6d3b-4016-b11a-b88f93179359");
pub const IID_ITypedEventHandler_Characteristic_ValueChanged = GUID.parse("1bac2d2c-414d-52dc-8061-d04b9f6e3352");

// GATT Server (GattServiceProvider, IGattLocalService, IGattLocalCharacteristic)
pub const IID_IGattServiceProvider = GUID.parse("7822b3cd-2889-4f86-a051-3f0aed1c2760");
pub const IID_IGattServiceProviderStatics = GUID.parse("31794063-5256-4054-a4f4-7bbe7755a57e");
pub const IID_IGattServiceProviderResult = GUID.parse("764696d8-c53e-428c-8a48-67afe02c3ae6");
pub const IID_IGattServiceProviderAdvertisingParameters = GUID.parse("e2ce31ab-6315-4c22-9bd7-781dbc3d8d82");
pub const IID_IGattLocalService = GUID.parse("f513e258-f7f7-4902-b803-57fcc7d6fe83");
pub const IID_IGattLocalCharacteristic = GUID.parse("aede376d-5412-4d74-92a8-8deb8526829c");
pub const IID_IGattLocalCharacteristicParameters = GUID.parse("faf73db4-4cff-44c7-8445-040e6ead0063");
pub const IID_IGattLocalCharacteristicResult = GUID.parse("7975de9b-0170-4397-9666-92f863f12ee6");
pub const IID_IGattReadRequestedEventArgs = GUID.parse("93497243-f39c-484b-8ab6-996ba486cfa3");
pub const IID_IGattReadRequest = GUID.parse("f1dd6535-6acd-42a6-a4bb-d789dae0043e");
pub const IID_IGattWriteRequestedEventArgs = GUID.parse("2dec8bbe-a73a-471a-94d5-037deadd0806");
pub const IID_IGattWriteRequest = GUID.parse("aeb6a9ed-de2f-4fc2-a9a8-94ea7844f13d");
pub const IID_ITypedEventHandler_GattLocalCharacteristic_ReadRequested = GUID.parse("218a3e4a-aa9d-500e-bca7-047751bb10a3");
pub const IID_ITypedEventHandler_GattLocalCharacteristic_WriteRequested = GUID.parse("ed61a2fb-7d2a-5ba3-8ebf-8ad878e539a9");

// Storage Streams (IBuffer & CryptographicBuffer)
pub const IID_IBuffer = GUID.parse("905a0fe0-bc53-11df-8c49-001e4fc686da");
pub const IID_IBufferByteAccess = GUID.parse("905a0fef-bc53-11df-8c49-001e4fc686da");
pub const IID_ICryptographicBufferStatics = GUID.parse("320b7e22-3cb0-4cdf-8663-1d28910065eb");

// ============================================================================
// Dynamic WinRT API Functions (combase.dll loaded via kernel32)
// ============================================================================

pub const Combase = if (builtin.os.tag == .windows) struct {
    const HMODULE = windows.HMODULE;
    const FARPROC = windows.FARPROC;

    const RoInitializeFn = *const fn (initType: u32) callconv(WINAPI) HRESULT;
    const RoUninitializeFn = *const fn () callconv(WINAPI) void;
    const RoGetActivationFactoryFn = *const fn (activatableClassId: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(WINAPI) HRESULT;
    const RoActivateInstanceFn = *const fn (activatableClassId: HSTRING, instance: *?*IInspectable) callconv(WINAPI) HRESULT;
    const WindowsCreateStringFn = *const fn (sourceString: ?[*]const u16, length: u32, string: *HSTRING) callconv(WINAPI) HRESULT;
    const WindowsDeleteStringFn = *const fn (string: HSTRING) callconv(WINAPI) HRESULT;
    const WindowsGetStringRawBufferFn = *const fn (string: HSTRING, length: ?*u32) callconv(WINAPI) ?[*]const u16;

    var module_handle: ?HMODULE = null;

    fn getModule() ?HMODULE {
        if (module_handle) |h| return h;
        const h = LoadLibraryA("combase.dll") orelse return null;
        module_handle = h;
        return h;
    }

    pub fn RoInitialize(initType: u32) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoInitializeFn = @ptrCast(GetProcAddress(m, "RoInitialize") orelse return E_FAIL);
        return f(initType);
    }

    pub fn RoUninitialize() void {
        const m = getModule() orelse return;
        const f: RoUninitializeFn = @ptrCast(GetProcAddress(m, "RoUninitialize") orelse return);
        f();
    }

    pub fn RoGetActivationFactory(activatableClassId: HSTRING, iid: *const GUID, factory: *?*anyopaque) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoGetActivationFactoryFn = @ptrCast(GetProcAddress(m, "RoGetActivationFactory") orelse return E_FAIL);
        return f(activatableClassId, iid, factory);
    }

    pub fn RoActivateInstance(activatableClassId: HSTRING, instance: *?*IInspectable) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoActivateInstanceFn = @ptrCast(GetProcAddress(m, "RoActivateInstance") orelse return E_FAIL);
        return f(activatableClassId, instance);
    }

    pub fn WindowsCreateString(sourceString: ?[*]const u16, length: u32, string: *HSTRING) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: WindowsCreateStringFn = @ptrCast(GetProcAddress(m, "WindowsCreateString") orelse return E_FAIL);
        return f(sourceString, length, string);
    }

    pub fn WindowsDeleteString(string: HSTRING) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: WindowsDeleteStringFn = @ptrCast(GetProcAddress(m, "WindowsDeleteString") orelse return E_FAIL);
        return f(string);
    }

    pub fn WindowsGetStringRawBuffer(string: HSTRING, length: ?*u32) ?[*]const u16 {
        const m = getModule() orelse return null;
        const f: WindowsGetStringRawBufferFn = @ptrCast(GetProcAddress(m, "WindowsGetStringRawBuffer") orelse return null);
        return f(string, length);
    }
} else struct {};

// ============================================================================
// Base COM & WinRT VTables
// ============================================================================

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

// ============================================================================
// Pure-Zig Custom COM Event Handlers (ITypedEventHandler Delegates)
// ============================================================================

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<Watcher, ReceivedEventArgs>`
/// and `IAgileObject` (so WinRT invokes it directly from its background thread pool without marshaling).
pub const AdvertisementReceivedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    backend_ctx: *anyopaque,
    on_received: *const fn (ctx: *anyopaque, args: *IBluetoothLEAdvertisementReceivedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *AdvertisementReceivedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *AdvertisementReceivedHandler, sender: ?*anyopaque, args: ?*IBluetoothLEAdvertisementReceivedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *AdvertisementReceivedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *AdvertisementReceivedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_Watcher_Received)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *AdvertisementReceivedHandler, sender: ?*anyopaque, args: ?*IBluetoothLEAdvertisementReceivedEventArgs) callconv(WINAPI) HRESULT {
        _ = sender;
        if (!self.active.load(.acquire)) return S_OK;
        if (args) |a| {
            self.on_received(self.backend_ctx, a);
        }
        return S_OK;
    }
};

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>`
pub const GattValueChangedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_changed: *const fn (char_ctx: *anyopaque, args: *IGattValueChangedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattValueChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattValueChangedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattValueChangedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattValueChangedHandler, sender: ?*anyopaque, args: ?*IGattValueChangedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *GattValueChangedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *GattValueChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_Characteristic_ValueChanged)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *GattValueChangedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *GattValueChangedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *GattValueChangedHandler, sender: ?*anyopaque, args: ?*IGattValueChangedEventArgs) callconv(WINAPI) HRESULT {
        _ = sender;
        if (!self.active.load(.acquire)) return S_OK;
        if (args) |a| {
            self.on_changed(self.char_ctx, a);
        }
        return S_OK;
    }
};

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<BluetoothLEDevice, IInspectable>`
/// for `add_ConnectionStatusChanged`.
pub const ConnectionStatusChangedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    dev_ctx: *anyopaque,
    on_status_changed: *const fn (dev_ctx: *anyopaque, sender: ?*IBluetoothLEDevice) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *ConnectionStatusChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *ConnectionStatusChangedHandler, sender: ?*IBluetoothLEDevice, args: ?*anyopaque) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *ConnectionStatusChangedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *ConnectionStatusChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_BluetoothLEDevice_IInspectable)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *ConnectionStatusChangedHandler, sender: ?*IBluetoothLEDevice, args: ?*anyopaque) callconv(WINAPI) HRESULT {
        _ = args;
        if (!self.active.load(.acquire)) return S_OK;
        self.on_status_changed(self.dev_ctx, sender);
        return S_OK;
    }
};

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<DeviceInformationCustomPairing, DevicePairingRequestedEventArgs>`
pub const PairingRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    pair_ctx: *anyopaque,
    on_pairing_requested: *const fn (pair_ctx: *anyopaque, args: *IDevicePairingRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *PairingRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *PairingRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *PairingRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *PairingRequestedHandler, sender: ?*anyopaque, args: ?*IDevicePairingRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *PairingRequestedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *PairingRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_CustomPairing_PairingRequested)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *PairingRequestedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *PairingRequestedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *PairingRequestedHandler, sender: ?*anyopaque, args: ?*IDevicePairingRequestedEventArgs) callconv(WINAPI) HRESULT {
        _ = sender;
        if (!self.active.load(.acquire)) return S_OK;
        if (args) |a| {
            self.on_pairing_requested(self.pair_ctx, a);
        }
        return S_OK;
    }
};

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<GattLocalCharacteristic, GattReadRequestedEventArgs>`
pub const GattReadRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_read_requested: *const fn (char_ctx: *anyopaque, args: *IGattReadRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattReadRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattReadRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattReadRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattReadRequestedHandler, sender: ?*anyopaque, args: ?*IGattReadRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *GattReadRequestedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *GattReadRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_GattLocalCharacteristic_ReadRequested)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *GattReadRequestedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *GattReadRequestedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *GattReadRequestedHandler, sender: ?*anyopaque, args: ?*IGattReadRequestedEventArgs) callconv(WINAPI) HRESULT {
        _ = sender;
        if (!self.active.load(.acquire)) return S_OK;
        if (args) |a| {
            self.on_read_requested(self.char_ctx, a);
        }
        return S_OK;
    }
};

/// Stack/Struct-allocated COM object implementing `ITypedEventHandler<GattLocalCharacteristic, GattWriteRequestedEventArgs>`
pub const GattWriteRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_write_requested: *const fn (char_ctx: *anyopaque, args: *IGattWriteRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattWriteRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattWriteRequestedHandler, sender: ?*anyopaque, args: ?*IGattWriteRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    pub fn deactivate(self: *GattWriteRequestedHandler) void {
        self.active.store(false, .release);
    }

    fn queryInterface(self: *GattWriteRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
        if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(IID_ITypedEventHandler_GattLocalCharacteristic_WriteRequested)) {
            ppvObject.* = @ptrCast(self);
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return S_OK;
        }
        ppvObject.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG {
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        return if (prev > 0) prev - 1 else 0;
    }

    fn invoke(self: *GattWriteRequestedHandler, sender: ?*anyopaque, args: ?*IGattWriteRequestedEventArgs) callconv(WINAPI) HRESULT {
        _ = sender;
        if (!self.active.load(.acquire)) return S_OK;
        if (args) |a| {
            self.on_write_requested(self.char_ctx, a);
        }
        return S_OK;
    }
};

// ============================================================================
// Win32 Bluetooth APIs (Legacy discovery & radio info)
// ============================================================================

const windows = std.os.windows;
pub const winapi_cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

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
