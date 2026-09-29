//! Zig-BLE: Native, allocation-conscious Bluetooth Low Energy library for Zig.
const std = @import("std");

pub const core = @import("core/mod.zig");

// Direct exports for common core domain types
pub const types = core.types;
pub const Address = core.Address;
pub const AddressType = core.AddressType;
pub const DeviceAddress = core.DeviceAddress;
pub const UUID = core.UUID;

// Standard GATT & Bluetooth SIG definitions
pub const assigned_numbers = core.assigned_numbers;
pub const Services = core.Services;
pub const Characteristics = core.Characteristics;
pub const Descriptors = core.Descriptors;
pub const CompanyId = core.CompanyId;
pub const Appearance = core.Appearance;

// GATT attributes & properties
pub const gatt = core.gatt;
pub const CharacteristicProperties = core.CharacteristicProperties;
pub const Cccd = core.Cccd;
pub const ServiceType = core.ServiceType;
pub const WriteType = core.WriteType;

// Zero-allocation advertising packet parser
pub const advertising = core.advertising;
pub const AdType = core.AdType;
pub const AdvertisingFlags = core.AdvertisingFlags;
pub const ManufacturerData = core.ManufacturerData;
pub const ServiceData16 = core.ServiceData16;
pub const ServiceData32 = core.ServiceData32;
pub const ServiceData128 = core.ServiceData128;
pub const ServiceUuids16Iterator = core.ServiceUuids16Iterator;
pub const ServiceUuids32Iterator = core.ServiceUuids32Iterator;
pub const ServiceUuids128Iterator = core.ServiceUuids128Iterator;
pub const AdStructure = core.AdStructure;
pub const AdIterator = core.AdIterator;
pub const AdvertisingReport = core.AdvertisingReport;

// Linux BlueZ D-Bus constants and protocol specification
pub const bluez = @import("bluez/mod.zig");
pub const BlueZ = bluez.BlueZ;
pub const AdapterInfo = bluez.AdapterInfo;
pub const DeviceInfo = bluez.DeviceInfo;
pub const GattServiceInfo = bluez.GattServiceInfo;
pub const GattCharacteristicInfo = bluez.GattCharacteristicInfo;
pub const GattDescriptorInfo = bluez.GattDescriptorInfo;

const builtin = @import("builtin");

// High-level BLE Controllers & Clients
pub const Adapter = if (builtin.os.tag == .linux) @import("adapter.zig").Adapter else struct {};

pub const Device = if (builtin.os.tag == .linux) @import("device.zig").Device else struct {};
pub const gatt_client = if (builtin.os.tag == .linux) @import("gatt_client.zig") else struct {};
pub const GattCharacteristic = if (builtin.os.tag == .linux) gatt_client.GattCharacteristic else struct {};
pub const GattStream = if (builtin.os.tag == .linux) gatt_client.GattStream else struct {};
pub const NotificationEvent = if (builtin.os.tag == .linux) gatt_client.NotificationEvent else struct {};
pub const NotificationDispatcher = if (builtin.os.tag == .linux) gatt_client.NotificationDispatcher else struct {};

// Broadcaster & Peripheral Advertising
pub const advertising_server = if (builtin.os.tag == .linux) @import("advertising.zig") else struct {};
pub const Advertisement = if (builtin.os.tag == .linux) advertising_server.Advertisement else struct {};
pub const AdvertisementConfig = if (builtin.os.tag == .linux) advertising_server.AdvertisementConfig else struct {};
pub const AdvertisementType = if (builtin.os.tag == .linux) advertising_server.AdvertisementType else struct {};
pub const AdvertisementIncludes = if (builtin.os.tag == .linux) advertising_server.AdvertisementIncludes else struct {};

// GATT Server / Peripheral Mode
pub const gatt_server = if (builtin.os.tag == .linux) @import("gatt_server.zig") else struct {};
pub const GattApplication = if (builtin.os.tag == .linux) gatt_server.GattApplication else struct {};
pub const ServerService = if (builtin.os.tag == .linux) gatt_server.ServerService else struct {};
pub const ServerCharacteristic = if (builtin.os.tag == .linux) gatt_server.ServerCharacteristic else struct {};
pub const ServerCharacteristicFlags = if (builtin.os.tag == .linux) gatt_server.ServerCharacteristicFlags else struct {};
pub const ServerDescriptor = if (builtin.os.tag == .linux) gatt_server.ServerDescriptor else struct {};
pub const ServerDescriptorFlags = if (builtin.os.tag == .linux) gatt_server.ServerDescriptorFlags else struct {};

// Pairing Agent
pub const agent_mod = if (builtin.os.tag == .linux) @import("agent.zig") else struct {};
pub const Agent = if (builtin.os.tag == .linux) agent_mod.Agent else struct {};
pub const AgentCapability = if (builtin.os.tag == .linux) agent_mod.AgentCapability else struct {};

// Unified High-Level Peripheral
pub const peripheral_mod = if (builtin.os.tag == .linux) @import("peripheral.zig") else struct {};
pub const Peripheral = if (builtin.os.tag == .linux) peripheral_mod.Peripheral else struct {};
pub const PeripheralOptions = if (builtin.os.tag == .linux) peripheral_mod.PeripheralOptions else struct {};

// Universal EventLoop & Background Runner
pub const event_loop_mod = if (builtin.os.tag == .linux) @import("event_loop.zig") else struct {};
pub const EventLoop = if (builtin.os.tag == .linux) event_loop_mod.EventLoop else struct {};
pub const MessageHandler = if (builtin.os.tag == .linux) event_loop_mod.MessageHandler else struct {};

// Pure-Zig D-Bus Wire Protocol Suite (Zero-Allocation, Platform-Independent)
pub const wire = @import("dbus/wire/mod.zig");

// D-Bus layer (active on Linux)
pub const dbus = if (builtin.os.tag == .linux)
    @import("dbus/mod.zig")
else
    struct {
        pub const wire = @import("dbus/wire/mod.zig");
    };
pub const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};

test {
    std.testing.refAllDecls(@This());
    _ = core;
    _ = bluez;
    if (builtin.os.tag == .linux) {
        _ = dbus;
        _ = gatt_client;
        _ = advertising_server;
        _ = gatt_server;
        _ = agent_mod;
        _ = peripheral_mod;
        _ = event_loop_mod;
    }
}


