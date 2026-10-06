//! # Zig-BLE Hardware Abstraction Layer (HAL) & Backend Registry
//!
//! Exposes unified backend types, polymorphic BackendVTable, and concrete backends
//! for Linux (BlueZ), Windows (WinRT), and in-memory testing (MockController).

const std = @import("std");
const builtin = @import("builtin");

pub const types = @import("types.zig");
pub const BleError = types.BleError;
pub const Address = types.Address;
pub const AddressType = types.AddressType;
pub const UUID = types.UUID;
pub const ScanFilter = types.ScanFilter;
pub const DiscoveredDevice = types.DiscoveredDevice;
pub const ScanCallback = types.ScanCallback;
pub const NotificationCallback = types.NotificationCallback;
pub const ConnectionParameters = types.ConnectionParameters;
pub const ConnectionEvent = types.ConnectionEvent;

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

pub const unified = @import("unified.zig");
pub const UnifiedAdapter = unified.UnifiedAdapter;
pub const UnifiedDevice = unified.UnifiedDevice;

pub const BackendKind = enum {
    bluez,
    winrt,
    uart_h4,
    mock,
};

/// Resolves the default native backend for the current compilation target.
pub const default_backend_kind: BackendKind = switch (builtin.os.tag) {
    .linux => .bluez,
    .windows => .winrt,
    else => .mock,
};

test {
    _ = types;
    _ = vtable;
    _ = mock;
    _ = bluez;
    _ = windows;
    _ = unified;
}
