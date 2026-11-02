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

/// Standardized BLE error set across all backends. Contains only errors a backend can return;
/// protocol parser errors stay in `core.AttError` and `crypto.SmpError`.
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
    MtuExchangeFailed,
    PairingFailed,
    CccdImproperlyConfigured,
    ValueNotAllowed,
    InsufficientAuthentication,
    InsufficientEncryption,
};

/// Maps an ATT error code (Core Spec Vol 3, Part F, 3.4.1.1) to the matching `BleError`,
/// or `fallback` for codes without a more specific error.
pub fn bleErrorFromAtt(code: u8, fallback: BleError) BleError {
    return switch (code) {
        0x02, 0x03, 0x08 => BleError.PermissionDenied, // Read/Write Not Permitted, Insufficient Authorization
        0x05 => BleError.InsufficientAuthentication,
        0x0F => BleError.InsufficientEncryption,
        else => fallback,
    };
}

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

/// Observable connection state of a BLE peer device.
pub const ConnectionState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    disconnecting = 3,
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

    /// Applies `min_rssi` and `service_uuids` (any listed UUID matches) to a device.
    pub fn matches(self: ScanFilter, device: *const DiscoveredDevice) bool {
        if (self.min_rssi) |min| {
            const rssi = device.rssi orelse return false;
            if (rssi < min) return false;
        }
        if (self.service_uuids.len == 0) return true;
        for (self.service_uuids) |wanted| {
            for (device.getServiceUuids()) |advertised| {
                if (wanted.eql(advertised)) return true;
            }
        }
        return false;
    }
};

/// Zero-allocation Discovered BLE Device descriptor
pub const DiscoveredDevice = struct {
    address: Address,
    address_type: AddressType = .public,
    rssi: ?i16 = null,
    /// Transmit power from the advertisement in dBm, if the device sends it.
    tx_power: ?i16 = null,

    name_buffer: [64]u8 = undefined,
    name_len: u8 = 0,

    mfg_buffer: [64]u8 = undefined,
    mfg_len: u8 = 0,
    company_id: ?u16 = null,

    service_data_uuid: ?UUID = null,
    service_data_buffer: [64]u8 = undefined,
    service_data_len: u8 = 0,

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

    pub fn getServiceData(self: *const DiscoveredDevice) ?struct { uuid: UUID, data: []const u8 } {
        if (self.service_data_len == 0 or self.service_data_uuid == null) return null;
        return .{
            .uuid = self.service_data_uuid.?,
            .data = self.service_data_buffer[0..self.service_data_len],
        };
    }

    pub fn setServiceData(self: *DiscoveredDevice, uuid: UUID, data: []const u8) void {
        self.service_data_uuid = uuid;
        const len = @min(self.service_data_buffer.len, data.len);
        @memcpy(self.service_data_buffer[0..len], data[0..len]);
        self.service_data_len = @intCast(len);
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

/// Selects one GATT characteristic of a connected device.
///
/// A device can contain the same characteristic UUID more than once, e.g. every HID report
/// is 0x2A4D and a device may expose two Battery services. `service` restricts the match to
/// one service UUID (`null` matches any service); `instance` picks the n-th match in
/// attribute-handle order (0 = first).
pub const CharacteristicSelector = struct {
    uuid: UUID,
    service: ?UUID = null,
    instance: u8 = 0,

    pub fn of(uuid: UUID) CharacteristicSelector {
        return .{ .uuid = uuid };
    }

    pub fn inService(service: UUID, uuid: UUID) CharacteristicSelector {
        return .{ .uuid = uuid, .service = service };
    }

    /// Converts a `UUID` or a `CharacteristicSelector` (including an anonymous struct
    /// literal such as `.{ .uuid = u, .instance = 1 }`) into a selector.
    pub fn from(char: anytype) CharacteristicSelector {
        const T = @TypeOf(char);
        if (T == UUID) return .of(char);
        if (T == CharacteristicSelector) return char;
        var sel: CharacteristicSelector = .{ .uuid = char.uuid };
        if (@hasField(T, "service")) sel.service = char.service;
        if (@hasField(T, "instance")) sel.instance = char.instance;
        return sel;
    }

    /// Returns the index of the selected characteristic in `slots`, which must be in
    /// attribute-handle order and have `uuid` and `service_uuid` fields.
    pub fn find(self: CharacteristicSelector, slots: anytype) ?usize {
        var seen: u8 = 0;
        for (slots, 0..) |*slot, i| {
            if (!slot.uuid.eql(self.uuid)) continue;
            if (self.service) |s| {
                if (!slot.service_uuid.eql(s)) continue;
            }
            if (seen == self.instance) return i;
            seen += 1;
        }
        return null;
    }
};

/// One discovered characteristic, as listed by `getCharacteristics`. Passing
/// `selector()` back to read, write or subscribe addresses exactly this characteristic.
pub const CharacteristicInfo = struct {
    service_uuid: UUID,
    uuid: UUID,
    /// Index among the characteristics with the same service and characteristic UUID.
    instance: u8 = 0,

    pub fn selector(self: CharacteristicInfo) CharacteristicSelector {
        return .{ .uuid = self.uuid, .service = self.service_uuid, .instance = self.instance };
    }

    /// Fills `out` from `slots` (handle order, with `uuid` and `service_uuid` fields)
    /// and returns the number of entries written.
    pub fn list(slots: anytype, out: []CharacteristicInfo) usize {
        const n = @min(slots.len, out.len);
        for (slots[0..n], 0..) |*slot, i| {
            var instance: u8 = 0;
            for (slots[0..i]) |*prev| {
                if (prev.uuid.eql(slot.uuid) and prev.service_uuid.eql(slot.service_uuid)) instance += 1;
            }
            out[i] = .{ .service_uuid = slot.service_uuid, .uuid = slot.uuid, .instance = instance };
        }
        return n;
    }
};

/// Advertisement data merged per device while scanning. BlueZ reports only changed
/// properties (often just `RSSI`) and WinRT reports advertisement and scan response
/// separately, so each scan result is assembled from everything seen so far for that address. Holds the 32 most recently updated devices.
pub const ScanCache = struct {
    entries: [32]DiscoveredDevice = undefined,
    /// Last update per entry; 0 marks a free entry.
    stamps: [32]u64 = @splat(0),
    clock: u64 = 0,

    pub fn reset(self: *ScanCache) void {
        self.stamps = @splat(0);
        self.clock = 0;
    }

    /// Returns the cached data for `address` without inserting it.
    pub fn find(self: *const ScanCache, address: Address) ?*const DiscoveredDevice {
        for (self.stamps, 0..) |stamp, i| {
            if (stamp != 0 and self.entries[i].address.eql(address)) return &self.entries[i];
        }
        return null;
    }

    /// Returns the entry for `address`, reusing the least recently updated one when full.
    pub fn get(self: *ScanCache, address: Address) *DiscoveredDevice {
        self.clock += 1;
        var oldest: usize = 0;
        for (self.stamps, 0..) |stamp, i| {
            if (stamp != 0 and self.entries[i].address.eql(address)) {
                self.stamps[i] = self.clock;
                return &self.entries[i];
            }
            if (stamp < self.stamps[oldest]) oldest = i;
        }
        self.entries[oldest] = .{ .address = address };
        self.stamps[oldest] = self.clock;
        return &self.entries[oldest];
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
        /// HCI disconnect reason (e.g. 0x08 timeout, 0x13 remote user, 0x16 local host),
        /// or null when the platform does not report it (WinRT, older BlueZ).
        reason_code: ?u8,
    },
    parameters_updated: ConnectionParameters,
};

/// Notification subscriptions remembered across a reconnect (`setAutoResubscribe`).
pub const SavedSubscriptions = struct {
    pub const Item = struct {
        char: CharacteristicSelector,
        cb: NotificationCallback,
        user_data: ?*anyopaque,
    };

    items: [16]Item = undefined,
    len: u8 = 0,

    /// Replaces the saved list with the subscribed characteristics in `slots` (fields `uuid`,
    /// `service_uuid`, `notify_cb`, `notify_user_data`). Keeps the old list if none is subscribed:
    /// the slots may already have been released for this connection.
    pub fn capture(self: *SavedSubscriptions, slots: anytype) void {
        var infos: [64]CharacteristicInfo = undefined;
        const n = CharacteristicInfo.list(slots, &infos);
        var found: u8 = 0;
        for (slots[0..n], infos[0..n]) |*slot, info| {
            const cb = slot.notify_cb orelse continue;
            if (found == self.items.len) break;
            self.items[found] = .{ .char = info.selector(), .cb = cb, .user_data = slot.notify_user_data };
            found += 1;
        }
        if (found > 0) self.len = found;
    }

    pub fn slice(self: *const SavedSubscriptions) []const Item {
        return self.items[0..self.len];
    }

    pub fn clear(self: *SavedSubscriptions) void {
        self.len = 0;
    }
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

/// Blocking mutex for backend state; waiting threads sleep instead of spinning (see `src/sync.zig`).
pub const SyncMutex = @import("../sync.zig").Mutex;

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

    dev.tx_power = -12;
    try std.testing.expectEqual(@as(?i16, -12), dev.tx_power);

    const sdata_uuid = UUID.from16(0x181A);
    dev.setServiceData(sdata_uuid, &[_]u8{ 0xAB, 0xCD });
    const sdata = dev.getServiceData().?;
    try std.testing.expect(sdata.uuid.eql(sdata_uuid));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, sdata.data);

    const test_uuid = UUID.from16(0x180D);
    try std.testing.expect(dev.addServiceUuid(test_uuid));
    try std.testing.expectEqual(@as(usize, 1), dev.getServiceUuids().len);
    try std.testing.expect(dev.getServiceUuids()[0].eql(test_uuid));
}

test "CharacteristicSelector picks by UUID, service and instance" {
    const Slot = struct { uuid: UUID, service_uuid: UUID };
    const hid = UUID.from16(0x1812);
    const report = UUID.from16(0x2A4D);
    const slots = [_]Slot{
        .{ .uuid = report, .service_uuid = hid },
        .{ .uuid = UUID.from16(0x2A19), .service_uuid = UUID.from16(0x180F) },
        .{ .uuid = report, .service_uuid = hid },
        .{ .uuid = report, .service_uuid = UUID.from16(0xFFF0) },
    };

    try std.testing.expectEqual(@as(?usize, 0), CharacteristicSelector.from(report).find(&slots));
    try std.testing.expectEqual(@as(?usize, 2), CharacteristicSelector.from(.{ .uuid = report, .instance = 1 }).find(&slots));
    try std.testing.expectEqual(@as(?usize, 3), CharacteristicSelector.from(.{ .uuid = report, .instance = 2 }).find(&slots));
    try std.testing.expectEqual(@as(?usize, 3), CharacteristicSelector.inService(UUID.from16(0xFFF0), report).find(&slots));
    try std.testing.expectEqual(@as(?usize, null), CharacteristicSelector.from(.{ .uuid = report, .service = hid, .instance = 2 }).find(&slots));

    var infos: [4]CharacteristicInfo = undefined;
    try std.testing.expectEqual(@as(usize, 4), CharacteristicInfo.list(&slots, &infos));
    try std.testing.expectEqual(@as(u8, 1), infos[2].instance);
    try std.testing.expectEqual(@as(u8, 0), infos[3].instance);
    for (infos, 0..) |info, i| {
        try std.testing.expectEqual(@as(?usize, i), info.selector().find(&slots));
    }
}

test "ScanCache merges per address and evicts the least recently updated entry" {
    var cache: ScanCache = .{};
    const a = Address{ .bytes = .{ 1, 0, 0, 0, 0, 0 } };
    cache.get(a).setName("first");
    cache.get(a).rssi = -50;
    try std.testing.expectEqualStrings("first", cache.find(a).?.getName().?);
    try std.testing.expectEqual(@as(?i16, -50), cache.find(a).?.rssi);

    // Fill the cache; `a` is the oldest entry and gets evicted
    for (1..cache.entries.len + 1) |i| {
        _ = cache.get(.{ .bytes = .{ 2, @intCast(i), 0, 0, 0, 0 } });
    }
    try std.testing.expect(cache.find(a) == null);

    cache.reset();
    try std.testing.expect(cache.find(.{ .bytes = .{ 2, 1, 0, 0, 0, 0 } }) == null);
}

test "ScanFilter.matches applies RSSI threshold and service UUIDs" {
    var dev = DiscoveredDevice{ .address = .{ .bytes = @splat(0) }, .rssi = -70 };
    _ = dev.addServiceUuid(UUID.from16(0x180D));
    try std.testing.expect((ScanFilter{}).matches(&dev));
    try std.testing.expect(!(ScanFilter{ .min_rssi = -60 }).matches(&dev));
    try std.testing.expect((ScanFilter{ .service_uuids = &.{ UUID.from16(0x180F), UUID.from16(0x180D) } }).matches(&dev));
    try std.testing.expect(!(ScanFilter{ .service_uuids = &.{UUID.from16(0x180F)} }).matches(&dev));
    dev.rssi = null;
    try std.testing.expect(!(ScanFilter{ .min_rssi = -60 }).matches(&dev));
}

test "bleErrorFromAtt maps permission errors and keeps the fallback" {
    try std.testing.expectEqual(BleError.PermissionDenied, bleErrorFromAtt(0x02, BleError.ReadFailed));
    try std.testing.expectEqual(BleError.InsufficientAuthentication, bleErrorFromAtt(0x05, BleError.ReadFailed));
    try std.testing.expectEqual(BleError.InsufficientEncryption, bleErrorFromAtt(0x0F, BleError.ReadFailed));
    try std.testing.expectEqual(BleError.ReadFailed, bleErrorFromAtt(0x0E, BleError.ReadFailed));
}
