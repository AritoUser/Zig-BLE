//! # Zig-BLE Hardware Abstraction Layer (HAL) & Backend Registry
//!
//! Exposes unified backend types, polymorphic BackendVTable, and concrete backends
//! for Linux (BlueZ & Raw HCI), Windows (WinRT), UART (H4/H5), macOS (NotSupported stub),
//! and in-memory testing (MockController).

const std = @import("std");
const builtin = @import("builtin");

pub const types = @import("types.zig");
pub const BleError = types.BleError;
pub const TimeoutConfig = types.TimeoutConfig;
pub const Address = types.Address;
pub const AddressType = types.AddressType;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const ConnectionParameters = types.ConnectionParameters;
pub const ConnectionEvent = types.ConnectionEvent;
pub const ConnectionEventCallback = types.ConnectionEventCallback;
pub const BondState = types.BondState;
pub const IoCapability = types.IoCapability;
pub const PairingCallbacks = types.PairingCallbacks;
pub const PcapDirection = types.PcapDirection;
pub const PcapHook = types.PcapHook;

pub const vtable = @import("vtable.zig");
pub const BackendVTable = vtable.BackendVTable;
pub const Backend = vtable.Backend;

pub const mock = @import("mock/mod.zig");
pub const MockController = mock.MockController;
pub const MockDevice = mock.MockDevice;
pub const MockCharacteristic = mock.MockCharacteristic;

pub const bluez = @import("bluez/mod.zig");
pub const BluezBackend = bluez.BluezBackend;

pub const windows = @import("windows/mod.zig");
pub const WindowsBackend = windows.WindowsBackend;
pub const WindowsBackendWithConfig = windows.WindowsBackendWithConfig;
pub const PoolConfig = windows.PoolConfig;

pub const unified = @import("unified.zig");
pub const UnifiedAdapter = unified.UnifiedAdapter;
pub const UnifiedDevice = unified.UnifiedDevice;

pub const hci_backend = @import("hci.zig");
pub const HciBackend = hci_backend.HciBackend;

pub const uart_backend = @import("uart.zig");
pub const UartBackend = uart_backend.UartBackend;
pub const UartFramingMode = uart_backend.UartFramingMode;

/// macOS CoreBluetooth stub backend: explicitly returns `BleError.NotSupported` for OS radio
/// operations while all pure-Zig protocol parsers (ATT, GATT, SMP, HCI, H4/H5, Advertising) remain available.
pub const MacosBackend = struct {
    pub fn init() MacosBackend {
        return .{};
    }
    pub fn deinit(_: *MacosBackend) void {}
    pub fn backend(self: *MacosBackend) Backend {
        return .{ .ptr = self, .vtable = &macos_vtable };
    }
    const macos_vtable = BackendVTable{
        .name = "macOS CoreBluetooth (Stub - NotSupported)",
        .openAdapter = struct {
            fn f(_: *anyopaque, _: u16) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .closeAdapter = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .setPowered = struct {
            fn f(_: *anyopaque, _: bool) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .isPowered = struct {
            fn f(_: *anyopaque) BleError!bool {
                return BleError.NotSupported;
            }
        }.f,
        .startScan = struct {
            fn f(_: *anyopaque, _: ScanFilter, _: ScanCallback, _: ?*anyopaque) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .stopScan = struct {
            fn f(_: *anyopaque) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .connectDevice = struct {
            fn f(_: *anyopaque, _: Address, _: u32) BleError!*anyopaque {
                return BleError.NotSupported;
            }
        }.f,
        .disconnectDevice = struct {
            fn f(_: *anyopaque, _: *anyopaque) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .isDeviceConnected = struct {
            fn f(_: *anyopaque, _: *anyopaque) bool {
                return false;
            }
        }.f,
        .getDeviceRssi = struct {
            fn f(_: *anyopaque, _: *anyopaque) ?i16 {
                return null;
            }
        }.f,
        .discoverServices = struct {
            fn f(_: *anyopaque, _: *anyopaque) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .readCharacteristic = struct {
            fn f(_: *anyopaque, _: *anyopaque, _: UUID, _: []u8) BleError!usize {
                return BleError.NotSupported;
            }
        }.f,
        .writeCharacteristic = struct {
            fn f(_: *anyopaque, _: *anyopaque, _: UUID, _: []const u8, _: bool) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .subscribeNotifications = struct {
            fn f(_: *anyopaque, _: *anyopaque, _: UUID, _: NotificationCallback, _: ?*anyopaque) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
        .unsubscribeNotifications = struct {
            fn f(_: *anyopaque, _: *anyopaque, _: UUID) BleError!void {
                return BleError.NotSupported;
            }
        }.f,
    };
};

pub const BackendKind = enum {
    bluez,
    winrt,
    hci_raw,
    uart_h4,
    uart_h5,
    macos_stub,
    mock,
};

/// Resolves the default native backend for the current compilation target.
pub const default_backend_kind: BackendKind = switch (builtin.os.tag) {
    .linux => .bluez,
    .windows => .winrt,
    .macos => .macos_stub,
    else => .mock,
};

test "MacosBackend returns BleError.NotSupported" {
    var mac = MacosBackend.init();
    defer mac.deinit();
    try std.testing.expectError(BleError.NotSupported, mac.backend().openAdapter(0));
}

test {
    _ = types;
    _ = vtable;
    _ = mock;
    _ = bluez;
    _ = windows;
    _ = unified;
    _ = hci_backend;
    _ = uart_backend;
}
