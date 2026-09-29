//! Zig-BLE Core: Platform-independent BLE domain logic conforming to the Bluetooth Core Specification.
const std = @import("std");

pub const types = @import("types.zig");
pub const assigned_numbers = @import("assigned_numbers.zig");
pub const gatt = @import("gatt.zig");
pub const advertising = @import("advertising.zig");

// Re-export primary types for ergonomic access
pub const Address = types.Address;
pub const AddressType = types.AddressType;
pub const DeviceAddress = types.DeviceAddress;
pub const UUID = types.UUID;

pub const Services = assigned_numbers.Services;
pub const Characteristics = assigned_numbers.Characteristics;
pub const Descriptors = assigned_numbers.Descriptors;
pub const CompanyId = assigned_numbers.CompanyId;
pub const Appearance = assigned_numbers.Appearance;

pub const CharacteristicProperties = gatt.CharacteristicProperties;
pub const Cccd = gatt.Cccd;
pub const ServiceType = gatt.ServiceType;
pub const WriteType = gatt.WriteType;

pub const AdType = advertising.AdType;
pub const AdvertisingFlags = advertising.AdvertisingFlags;
pub const ManufacturerData = advertising.ManufacturerData;
pub const ServiceData16 = advertising.ServiceData16;
pub const ServiceData32 = advertising.ServiceData32;
pub const ServiceData128 = advertising.ServiceData128;
pub const ServiceUuids16Iterator = advertising.ServiceUuids16Iterator;
pub const ServiceUuids32Iterator = advertising.ServiceUuids32Iterator;
pub const ServiceUuids128Iterator = advertising.ServiceUuids128Iterator;
pub const AdStructure = advertising.AdStructure;
pub const AdIterator = advertising.AdIterator;
pub const AdvertisingReport = advertising.AdvertisingReport;

test {
    std.testing.refAllDecls(@This());
    _ = types;
    _ = assigned_numbers;
    _ = gatt;
    _ = advertising;
}
