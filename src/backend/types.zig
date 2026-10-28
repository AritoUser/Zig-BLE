//! # Zig-BLE Backend Types & Common Data Structures
//!
//! Common domain types, callbacks, and error definitions for the
//! Pluggable Backend Hardware Abstraction Layer (HAL).
//! 100% Zero-allocation, thread-safe, and Little-Endian compliant.

const std = @import("std");
const core = @import("../core/mod.zig");
pub const Address = core.Address;
pub const AddressType = core.AddressType;
pub const UUID = core.UUID;
pub const WriteType = core.WriteType;
pub const AttErrorCode = core.AttErrorCode;

/// Standardized BLE error set across all backends.
pub const BleError = error{
    NotSupported,
    NotPowered,
    AdapterNotFound,
    DeviceNotFound,
    NotConnected,
    AlreadyConnected,
    ConnectionTimeout,
    ConnectionFailed,
    Disconnected,
    ServiceNotFound,
    CharacteristicNotFound,
    DescriptorNotFound,
    ReadFailed,
    WriteFailed,
    NotificationFailed,
    PermissionDenied,
    AuthenticationFailed,
    BufferTooSmall,
    InvalidParameter,
    OutOfMemory,
    PoolExhausted,
    Timeout,
    DaemonDisconnected,
    InvalidState,
    IoError,
    GattError,

    // Granular ATT & Security errors (v1.1.0)
    InsufficientAuthentication, // ATT 0x05
    InsufficientEncryption, // ATT 0x0F
    CccdImproperlyConfigured, // ATT 0xFD
    ValueNotAllowed, // ATT 0x13
    MtuExchangeFailed,
    PairingFailed,
};

/// Configurable timeouts (in milliseconds) for all blocking BLE operations.
/// Prevents any operation (Connect, Read, Write, Service Discovery, Pairing) from hanging indefinitely.
pub const TimeoutConfig = struct {
    connect_ms: u32 = 10_000,
    discovery_ms: u32 = 10_000,
    read_ms: u32 = 5_000,
    write_ms: u32 = 5_000,
    pair_ms: u32 = 30_000,
    mtu_exchange_ms: u32 = 5_000,
};

/// Bond state of a remote BLE peer device.
pub const BondState = enum(u8) {
    not_bonded = 0,
    bonding = 1,
    bonded = 2,
};

/// IO Capabilities for BLE Security Manager (SMP) pairing.
pub const IoCapability = enum(u8) {
    display_only = 0,
    display_yes_no = 1,
    keyboard_only = 2,
    no_input_no_output = 3,
    keyboard_display = 4,
};

/// Callback invoked for Numeric Comparison (when `numeric_value != null`) or Just Works confirmation (`numeric_value == null`).
/// Return `true` to accept pairing, `false` to reject.
pub const PairingConfirmCallback = *const fn (numeric_value: ?u32, user_data: ?*anyopaque) bool;

/// Callback invoked when the remote peer displays a passkey and the local host must provide the 6-digit PIN (000000..999999).
pub const PairingPasskeyCallback = *const fn (user_data: ?*anyopaque) ?u32;

/// Callback invoked when the local host generates a 6-digit passkey that must be displayed to the user.
pub const PairingDisplayPasskeyCallback = *const fn (passkey: u32, user_data: ?*anyopaque) void;

/// Interactive pairing callbacks for Passkey Entry and Numeric Comparison across backends.
pub const PairingCallbacks = struct {
    on_confirm: ?PairingConfirmCallback = null,
    on_request_passkey: ?PairingPasskeyCallback = null,
    on_display_passkey: ?PairingDisplayPasskeyCallback = null,
    user_data: ?*anyopaque = null,
};

/// BLE GAP Scanning Configuration Filter
pub const ScanFilter = struct {
    /// Service UUIDs to filter for (empty = all devices)
    service_uuids: []const UUID = &.{},
    /// Filter out duplicate advertisement packets from same address
    filter_duplicates: bool = true,
    /// Explicitly control duplicate packets if supported by backend
    duplicate_data: ?bool = null,
    /// Minimum RSSI threshold in dBm (e.g. -85)
    min_rssi: ?i16 = null,
    /// Active scan requests Scan Response packets
    active: bool = true,
};

/// Zero-allocation Discovered BLE Device descriptor
pub const DiscoveredDevice = struct {
    address: Address,
    address_type: AddressType = .public,
    rssi: ?i16 = null,

    name_buffer: [64]u8 = undefined,
    name_len: u8 = 0,

    mfg_buffer: [64]u8 = undefined,
    mfg_len: u8 = 0,
    company_id: ?u16 = null,

    service_uuids: [8]UUID = undefined,
    service_uuids_len: u8 = 0,

    pub fn getName(self: *const DiscoveredDevice) ?[]const u8 {
        if (self.name_len == 0) return null;
        return self.name_buffer[0..self.name_len];
    }

    pub fn setName(self: *DiscoveredDevice, name: []const u8) void {
        const len = @min(self.name_buffer.len, name.len);
        @memcpy(self.name_buffer[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn getManufacturerData(self: *const DiscoveredDevice) ?[]const u8 {
        if (self.mfg_len == 0) return null;
        return self.mfg_buffer[0..self.mfg_len];
    }

    pub fn setManufacturerData(self: *DiscoveredDevice, company: u16, data: []const u8) void {
        self.company_id = company;
        const len = @min(self.mfg_buffer.len, data.len);
        @memcpy(self.mfg_buffer[0..len], data[0..len]);
        self.mfg_len = @intCast(len);
    }

    pub fn getServiceUuids(self: *const DiscoveredDevice) []const UUID {
        return self.service_uuids[0..self.service_uuids_len];
    }

    pub fn addServiceUuid(self: *DiscoveredDevice, uuid: UUID) bool {
        if (self.service_uuids_len < self.service_uuids.len) {
            self.service_uuids[self.service_uuids_len] = uuid;
            self.service_uuids_len += 1;
            return true;
        }
        return false;
    }
};

/// Callback invoked on advertisement detection
pub const ScanCallback = *const fn (device: *const DiscoveredDevice, user_data: ?*anyopaque) void;

/// Callback invoked on characteristic notification or indication
pub const NotificationCallback = *const fn (uuid: UUID, data: []const u8, user_data: ?*anyopaque) void;

/// Connection parameters negotiated with peripheral
pub const ConnectionParameters = struct {
    /// Connection interval in 1.25 ms units (6 .. 3200 = 7.5 ms .. 4.0 s)
    interval: u16,
    /// Slave latency in connection events (0 .. 499)
    latency: u16,
    /// Supervision timeout in 10 ms units (10 .. 3200 = 100 ms .. 32.0 s)
    supervision_timeout: u16,
};

/// Connection event type for lifecycle listeners
pub const ConnectionEvent = union(enum) {
    connected: struct {
        address: Address,
    },
    disconnected: struct {
        address: Address,
        reason_code: u8,
    },
    parameters_updated: ConnectionParameters,
};

/// Callback invoked on connection state changes (connected, disconnected, parameters_updated).
pub const ConnectionEventCallback = *const fn (event: ConnectionEvent, user_data: ?*anyopaque) void;

/// Direction of a captured BLE packet for PCAP/btsnoop diagnostic export.
pub const PcapDirection = enum(u8) {
    host_to_controller = 0,
    controller_to_host = 1,
};

/// Optional diagnostic hook for capturing ATT/L2CAP operations in backends.
pub const PcapHookFn = *const fn (direction: PcapDirection, att_pdu: []const u8, user_data: ?*anyopaque) void;

pub const PcapHook = struct {
    callback: PcapHookFn,
    user_data: ?*anyopaque = null,

    pub fn emit(self: PcapHook, direction: PcapDirection, att_pdu: []const u8) void {
        self.callback(direction, att_pdu, self.user_data);
    }
};

/// Cross-platform atomic mutex for thread-safe backend state synchronization.
pub const SyncMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SyncMutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SyncMutex) void {
        self.locked.store(false, .release);
    }
};

test "DiscoveredDevice zero-alloc helper tests" {
    var dev: DiscoveredDevice = .{
        .address = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } },
        .rssi = -65,
    };

    try std.testing.expect(dev.getName() == null);
    dev.setName("SmartSensor_01");
    try std.testing.expectEqualStrings("SmartSensor_01", dev.getName().?);

    dev.setManufacturerData(0x0059, &[_]u8{ 0x01, 0x02, 0x03 });
    try std.testing.expectEqual(@as(u16, 0x0059), dev.company_id.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, dev.getManufacturerData().?);

    const test_uuid = UUID.from16(0x180D);
    try std.testing.expect(dev.addServiceUuid(test_uuid));
    try std.testing.expectEqual(@as(usize, 1), dev.getServiceUuids().len);
    try std.testing.expect(dev.getServiceUuids()[0].eql(test_uuid));
}
