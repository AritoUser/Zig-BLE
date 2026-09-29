//! Backwards-compatible forwarder to core/types.zig
const core_types = @import("core/types.zig");

pub const AddressType = core_types.AddressType;
pub const Address = core_types.Address;
pub const DeviceAddress = core_types.DeviceAddress;
pub const UUID = core_types.UUID;

test {
    _ = core_types;
}
