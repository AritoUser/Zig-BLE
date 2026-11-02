//! # Zig-BLE Backend VTable & Interface Wrapper
//!
//! Provides the polymorphic VTable definition allowing any Bluetooth transport
//! (BlueZ, WinRT, CoreBluetooth, UART H4/H5, HCI, or Virtual Mock) to be plugged into
//! the unified Zig-BLE public API with concrete `BleError` error sets.

const std = @import("std");
const types = @import("types.zig");
const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const ScanFilter = types.ScanFilter;
const ScanCallback = types.ScanCallback;
const NotificationCallback = types.NotificationCallback;
const CharacteristicSelector = types.CharacteristicSelector;
const CharacteristicInfo = types.CharacteristicInfo;

/// Function pointers table for BLE backends.
pub const BackendVTable = struct {
    name: []const u8,

    // Adapter Operations
    openAdapter: *const fn (ctx: *anyopaque, index: u16) BleError!void,
    closeAdapter: *const fn (ctx: *anyopaque) void,
    setPowered: *const fn (ctx: *anyopaque, powered: bool) BleError!void,
    isPowered: *const fn (ctx: *anyopaque) BleError!bool,
    startScan: *const fn (ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void,
    stopScan: *const fn (ctx: *anyopaque) BleError!void,

    // Device Operations
    connectDevice: *const fn (ctx: *anyopaque, addr: Address, timeout_ms: u32) BleError!*anyopaque,
    disconnectDevice: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) BleError!void,
    isDeviceConnected: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) bool,
    getDeviceRssi: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) ?i16,

    // GATT Client Operations
    discoverServices: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) BleError!void,
    readCharacteristic: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, buf: []u8) BleError!usize,
    writeCharacteristic: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, data: []const u8, with_response: bool) BleError!void,
    subscribeNotifications: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void,
    unsubscribeNotifications: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector) BleError!void,

    // ATT MTU & Throughput Negotiation (v1.1.0)
    exchangeMtu: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 = null,

    // Security Manager & Bonding Lifecycle (v1.1.0)
    pairDevice: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) BleError!void = null,
    unpairDevice: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque) BleError!void = null,
    getBondState: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque) types.BondState = null,

    // High-Throughput Linux SCM_RIGHTS FD Handover (v1.1.0)
    acquireNotifyFd: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, out_mtu: *u16) BleError!std.posix.fd_t = null,

    /// Reads or writes a descriptor of a characteristic, e.g. the Characteristic User
    /// Description (0x2901) or Presentation Format (0x2904) (v1.4.0).
    readDescriptor: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, buf: []u8) BleError!usize = null,
    writeDescriptor: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, char: CharacteristicSelector, descriptor: UUID, data: []const u8) BleError!void = null,

    /// Lists the discovered characteristics in attribute-handle order (v1.4.0).
    getCharacteristics: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize = null,

    /// Delivers pending scan results, notifications and connection events, waiting up to
    /// `timeout_ms` (v1.4.0). Backends whose callbacks arrive on their own threads (WinRT)
    /// only wait; backends without it (mock) return immediately.
    processEvents: ?*const fn (ctx: *anyopaque, timeout_ms: u32) BleError!void = null,

    /// Returns the observable connection state (v1.4.0).
    getConnectionState: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque) types.ConnectionState = null,

    /// Configures automatic re-subscription of active notifications when the device reconnects (v1.4.0).
    setAutoResubscribe: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, enabled: bool) void = null,

    /// Discovers services matching `filter_uuids`, or all services if empty (v1.4.0).
    discoverServicesFiltered: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void = null,
};

/// Type-erased, zero-allocation Backend handle
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const BackendVTable,

    pub inline fn getName(self: Backend) []const u8 {
        return self.vtable.name;
    }

    pub inline fn openAdapter(self: Backend, index: u16) BleError!void {
        return self.vtable.openAdapter(self.ptr, index);
    }

    pub inline fn closeAdapter(self: Backend) void {
        self.vtable.closeAdapter(self.ptr);
    }

    pub inline fn setPowered(self: Backend, powered: bool) BleError!void {
        return self.vtable.setPowered(self.ptr, powered);
    }

    pub inline fn isPowered(self: Backend) BleError!bool {
        return self.vtable.isPowered(self.ptr);
    }

    pub inline fn startScan(self: Backend, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) BleError!void {
        return self.vtable.startScan(self.ptr, filter, cb, user_data);
    }

    pub inline fn stopScan(self: Backend) BleError!void {
        return self.vtable.stopScan(self.ptr);
    }

    pub inline fn connectDevice(self: Backend, addr: Address, timeout_ms: u32) BleError!*anyopaque {
        return self.vtable.connectDevice(self.ptr, addr, timeout_ms);
    }

    pub inline fn disconnectDevice(self: Backend, dev_handle: *anyopaque) BleError!void {
        return self.vtable.disconnectDevice(self.ptr, dev_handle);
    }

    pub inline fn isDeviceConnected(self: Backend, dev_handle: *anyopaque) bool {
        return self.vtable.isDeviceConnected(self.ptr, dev_handle);
    }

    pub inline fn getDeviceRssi(self: Backend, dev_handle: *anyopaque) ?i16 {
        return self.vtable.getDeviceRssi(self.ptr, dev_handle);
    }

    pub inline fn discoverServices(self: Backend, dev_handle: *anyopaque) BleError!void {
        return self.vtable.discoverServices(self.ptr, dev_handle);
    }

    // `char` is a `UUID` or a `CharacteristicSelector`.

    pub inline fn readCharacteristic(self: Backend, dev_handle: *anyopaque, char: anytype, buf: []u8) BleError!usize {
        return self.vtable.readCharacteristic(self.ptr, dev_handle, .from(char), buf);
    }

    pub inline fn writeCharacteristic(self: Backend, dev_handle: *anyopaque, char: anytype, data: []const u8, with_response: bool) BleError!void {
        return self.vtable.writeCharacteristic(self.ptr, dev_handle, .from(char), data, with_response);
    }

    pub inline fn subscribeNotifications(self: Backend, dev_handle: *anyopaque, char: anytype, cb: NotificationCallback, user_data: ?*anyopaque) BleError!void {
        return self.vtable.subscribeNotifications(self.ptr, dev_handle, .from(char), cb, user_data);
    }

    pub inline fn unsubscribeNotifications(self: Backend, dev_handle: *anyopaque, char: anytype) BleError!void {
        return self.vtable.unsubscribeNotifications(self.ptr, dev_handle, .from(char));
    }

    pub inline fn exchangeMtu(self: Backend, dev_handle: *anyopaque, target_mtu: u16) BleError!u16 {
        if (self.vtable.exchangeMtu) |f| return f(self.ptr, dev_handle, target_mtu);
        return types.BleError.NotSupported;
    }

    pub inline fn pairDevice(self: Backend, dev_handle: *anyopaque, io_cap: types.IoCapability) BleError!void {
        if (self.vtable.pairDevice) |f| return f(self.ptr, dev_handle, io_cap);
        return types.BleError.NotSupported;
    }

    pub inline fn unpairDevice(self: Backend, dev_handle: *anyopaque) BleError!void {
        if (self.vtable.unpairDevice) |f| return f(self.ptr, dev_handle);
        return types.BleError.NotSupported;
    }

    pub inline fn getBondState(self: Backend, dev_handle: *anyopaque) types.BondState {
        if (self.vtable.getBondState) |f| return f(self.ptr, dev_handle);
        return .not_bonded;
    }

    pub inline fn acquireNotifyFd(self: Backend, dev_handle: *anyopaque, char: anytype, out_mtu: *u16) BleError!std.posix.fd_t {
        if (self.vtable.acquireNotifyFd) |f| return f(self.ptr, dev_handle, .from(char), out_mtu);
        return types.BleError.NotSupported;
    }

    pub inline fn readDescriptor(self: Backend, dev_handle: *anyopaque, char: anytype, descriptor: UUID, buf: []u8) BleError!usize {
        if (self.vtable.readDescriptor) |f| return f(self.ptr, dev_handle, .from(char), descriptor, buf);
        return types.BleError.NotSupported;
    }

    pub inline fn writeDescriptor(self: Backend, dev_handle: *anyopaque, char: anytype, descriptor: UUID, data: []const u8) BleError!void {
        if (self.vtable.writeDescriptor) |f| return f(self.ptr, dev_handle, .from(char), descriptor, data);
        return types.BleError.NotSupported;
    }

    pub inline fn getCharacteristics(self: Backend, dev_handle: *anyopaque, out: []CharacteristicInfo) BleError!usize {
        if (self.vtable.getCharacteristics) |f| return f(self.ptr, dev_handle, out);
        return types.BleError.NotSupported;
    }

    /// Delivers pending events, waiting up to `timeout_ms` for the first one.
    pub inline fn processEvents(self: Backend, timeout_ms: u32) BleError!void {
        if (self.vtable.processEvents) |f| return f(self.ptr, timeout_ms);
    }

    pub inline fn getConnectionState(self: Backend, dev_handle: *anyopaque) types.ConnectionState {
        if (self.vtable.getConnectionState) |f| return f(self.ptr, dev_handle);
        return if (self.isDeviceConnected(dev_handle)) .connected else .disconnected;
    }

    pub inline fn setAutoResubscribe(self: Backend, dev_handle: *anyopaque, enabled: bool) void {
        if (self.vtable.setAutoResubscribe) |f| f(self.ptr, dev_handle, enabled);
    }

    pub inline fn discoverServicesFiltered(self: Backend, dev_handle: *anyopaque, filter_uuids: []const UUID) BleError!void {
        if (self.vtable.discoverServicesFiltered) |f| return f(self.ptr, dev_handle, filter_uuids);
        return self.vtable.discoverServices(self.ptr, dev_handle);
    }
};
