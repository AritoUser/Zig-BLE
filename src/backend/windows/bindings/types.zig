//! # Windows COM & WinRT Core Types & GUIDs
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../../types.zig");

pub const WINAPI: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const HRESULT = i32;
pub const ULONG = u32;
pub const HSTRING = ?*anyopaque;
pub const EventRegistrationToken = i64;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
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

/// 128-bit Windows COM GUID structure (RFC 4122 binary representation).
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn toUUID(self: GUID) types.UUID {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.Data1, .big);
        std.mem.writeInt(u16, bytes[4..6], self.Data2, .big);
        std.mem.writeInt(u16, bytes[6..8], self.Data3, .big);
        @memcpy(bytes[8..16], self.Data4[0..8]);
        return .{ .bytes = bytes };
    }

    pub fn fromUUID(uuid: types.UUID) GUID {
        const b = uuid.bytes;
        return .{
            .Data1 = std.mem.readInt(u32, b[0..4], .big),
            .Data2 = std.mem.readInt(u16, b[4..6], .big),
            .Data3 = std.mem.readInt(u16, b[6..8], .big),
            .Data4 = b[8..16].*,
        };
    }

    pub fn parse(comptime str: []const u8) GUID {
        @setEvalBranchQuota(5000);
        comptime {
            if (str.len != 36) @compileError("GUID string must be 36 characters (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)");
            var d4: [8]u8 = undefined;
            const d1 = std.fmt.parseInt(u32, str[0..8], 16) catch unreachable;
            const d2 = std.fmt.parseInt(u16, str[9..13], 16) catch unreachable;
            const d3 = std.fmt.parseInt(u16, str[14..18], 16) catch unreachable;
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

