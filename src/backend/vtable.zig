//! # Zig-BLE Backend VTable & Interface Wrapper
//!
//! Provides the polymorphic VTable definition allowing any Bluetooth transport
//! (BlueZ, WinRT, CoreBluetooth, UART H4, or Virtual Mock) to be plugged into
//! the unified Zig-BLE public API.

const std = @import("std");
const types = @import("types.zig");
const Address = types.Address;
const UUID = types.UUID;
const ScanFilter = types.ScanFilter;
const ScanCallback = types.ScanCallback;
const NotificationCallback = types.NotificationCallback;

/// Function pointers table for BLE backends.
pub const BackendVTable = struct {
    name: []const u8,

    // Adapter Operations
    openAdapter: *const fn (ctx: *anyopaque, index: u16) anyerror!void,
    closeAdapter: *const fn (ctx: *anyopaque) void,
    setPowered: *const fn (ctx: *anyopaque, powered: bool) anyerror!void,
    isPowered: *const fn (ctx: *anyopaque) anyerror!bool,
    startScan: *const fn (ctx: *anyopaque, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) anyerror!void,
    stopScan: *const fn (ctx: *anyopaque) anyerror!void,

    // Device Operations
    connectDevice: *const fn (ctx: *anyopaque, addr: Address, timeout_ms: u32) anyerror!*anyopaque,
    disconnectDevice: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void,
    isDeviceConnected: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) bool,
    getDeviceRssi: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) ?i16,

    // GATT Client Operations
    discoverServices: *const fn (ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void,
    readCharacteristic: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) anyerror!usize,
    writeCharacteristic: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) anyerror!void,
    subscribeNotifications: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) anyerror!void,
    unsubscribeNotifications: *const fn (ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID) anyerror!void,

    // ATT MTU & Throughput Negotiation (v1.1.0)
    exchangeMtu: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, target_mtu: u16) anyerror!u16 = null,

    // Security Manager & Bonding Lifecycle (v1.1.0)
    pairDevice: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, io_cap: types.IoCapability) anyerror!void = null,
    unpairDevice: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque) anyerror!void = null,
    getBondState: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque) types.BondState = null,

    // High-Throughput Linux SCM_RIGHTS FD Handover (v1.1.0)
    acquireNotifyFd: ?*const fn (ctx: *anyopaque, dev_handle: *anyopaque, char_uuid: UUID, out_mtu: *u16) anyerror!std.posix.fd_t = null,
};

/// Type-erased, zero-allocation Backend handle
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const BackendVTable,

    pub inline fn getName(self: Backend) []const u8 {
        return self.vtable.name;
    }

    pub inline fn openAdapter(self: Backend, index: u16) !void {
        return self.vtable.openAdapter(self.ptr, index);
    }

    pub inline fn closeAdapter(self: Backend) void {
        self.vtable.closeAdapter(self.ptr);
    }

    pub inline fn setPowered(self: Backend, powered: bool) !void {
        return self.vtable.setPowered(self.ptr, powered);
    }

    pub inline fn isPowered(self: Backend) !bool {
        return self.vtable.isPowered(self.ptr);
    }

    pub inline fn startScan(self: Backend, filter: ScanFilter, cb: ScanCallback, user_data: ?*anyopaque) !void {
        return self.vtable.startScan(self.ptr, filter, cb, user_data);
    }

    pub inline fn stopScan(self: Backend) !void {
        return self.vtable.stopScan(self.ptr);
    }

    pub inline fn connectDevice(self: Backend, addr: Address, timeout_ms: u32) !*anyopaque {
        return self.vtable.connectDevice(self.ptr, addr, timeout_ms);
    }

    pub inline fn disconnectDevice(self: Backend, dev_handle: *anyopaque) !void {
        return self.vtable.disconnectDevice(self.ptr, dev_handle);
    }

    pub inline fn isDeviceConnected(self: Backend, dev_handle: *anyopaque) bool {
        return self.vtable.isDeviceConnected(self.ptr, dev_handle);
    }

    pub inline fn getDeviceRssi(self: Backend, dev_handle: *anyopaque) ?i16 {
        return self.vtable.getDeviceRssi(self.ptr, dev_handle);
    }

    pub inline fn discoverServices(self: Backend, dev_handle: *anyopaque) !void {
        return self.vtable.discoverServices(self.ptr, dev_handle);
    }

    pub inline fn readCharacteristic(self: Backend, dev_handle: *anyopaque, char_uuid: UUID, buf: []u8) !usize {
        return self.vtable.readCharacteristic(self.ptr, dev_handle, char_uuid, buf);
    }

    pub inline fn writeCharacteristic(self: Backend, dev_handle: *anyopaque, char_uuid: UUID, data: []const u8, with_response: bool) !void {
        return self.vtable.writeCharacteristic(self.ptr, dev_handle, char_uuid, data, with_response);
    }

    pub inline fn subscribeNotifications(self: Backend, dev_handle: *anyopaque, char_uuid: UUID, cb: NotificationCallback, user_data: ?*anyopaque) !void {
        return self.vtable.subscribeNotifications(self.ptr, dev_handle, char_uuid, cb, user_data);
    }

    pub inline fn unsubscribeNotifications(self: Backend, dev_handle: *anyopaque, char_uuid: UUID) !void {
        return self.vtable.unsubscribeNotifications(self.ptr, dev_handle, char_uuid);
    }

    pub inline fn exchangeMtu(self: Backend, dev_handle: *anyopaque, target_mtu: u16) !u16 {
        if (self.vtable.exchangeMtu) |f| return f(self.ptr, dev_handle, target_mtu);
        return types.BleError.NotSupported;
    }

    pub inline fn pairDevice(self: Backend, dev_handle: *anyopaque, io_cap: types.IoCapability) !void {
        if (self.vtable.pairDevice) |f| return f(self.ptr, dev_handle, io_cap);
        return types.BleError.NotSupported;
    }

    pub inline fn unpairDevice(self: Backend, dev_handle: *anyopaque) !void {
        if (self.vtable.unpairDevice) |f| return f(self.ptr, dev_handle);
        return types.BleError.NotSupported;
    }

    pub inline fn getBondState(self: Backend, dev_handle: *anyopaque) types.BondState {
        if (self.vtable.getBondState) |f| return f(self.ptr, dev_handle);
        return .not_bonded;
    }

    pub inline fn acquireNotifyFd(self: Backend, dev_handle: *anyopaque, char_uuid: UUID, out_mtu: *u16) !std.posix.fd_t {
        if (self.vtable.acquireNotifyFd) |f| return f(self.ptr, dev_handle, char_uuid, out_mtu);
        return types.BleError.NotSupported;
    }
};
