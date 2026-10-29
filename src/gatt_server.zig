//! # Zig-BLE GATT Server: Hosts local GATT services & characteristics
//!
//! Supports hosting local services via BlueZ `org.bluez.GattManager1` on Linux
//! and WinRT `GattServiceProvider` on Windows.
//! 100% Zero dynamic heap allocations. Modularized for maintainability.

pub const types_mod = @import("gatt_server/types.zig");
pub const app_mod = @import("gatt_server/app.zig");
pub const windows_mod = @import("gatt_server/windows.zig");
pub const bluez_mod = @import("gatt_server/bluez.zig");

// Types re-exports
pub const Connection = types_mod.Connection;
pub const Message = types_mod.Message;
pub const ServerDescriptorFlags = types_mod.ServerDescriptorFlags;
pub const ServerDescriptor = types_mod.ServerDescriptor;
pub const ServerCharacteristicFlags = types_mod.ServerCharacteristicFlags;
pub const ServerCharacteristic = types_mod.ServerCharacteristic;
pub const ServerService = types_mod.ServerService;

// Application re-exports
pub const GattApplication = app_mod.GattApplication;

test {
    _ = @import("gatt_server/tests.zig");
}
