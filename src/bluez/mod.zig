//! BlueZ Module: Protocol specification, D-Bus constants, and ObjectManager parser.

pub const constants = @import("constants.zig");
pub const BlueZ = constants.BlueZ;

pub const object_manager = @import("object_manager.zig");
pub const AdapterInfo = object_manager.AdapterInfo;
pub const DeviceInfo = object_manager.DeviceInfo;
pub const GattServiceInfo = object_manager.GattServiceInfo;
pub const GattCharacteristicInfo = object_manager.GattCharacteristicInfo;
pub const GattDescriptorInfo = object_manager.GattDescriptorInfo;
pub const parseManagedObjects = object_manager.parseManagedObjects;
pub const parseInterfacesAdded = object_manager.parseInterfacesAdded;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = constants;
    _ = object_manager;
}
