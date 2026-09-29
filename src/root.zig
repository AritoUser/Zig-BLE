//! # Zig-BLE: Native, Pure-Zig Bluetooth Low Energy Stack
//!
//! A high-performance, allocation-conscious Bluetooth Low Energy (BLE) engine for **Zig 0.16.0+**,
//! strictly adhering to the **Bluetooth Core Specification (v5.4 / v6.0)** and the Linux **BlueZ D-Bus Wire Protocol**.
//!
//! ## Architectural Pillars
//! 1. **100% Pure Zig**: Zero C-dependencies, zero `libdbus-1`, zero sysroot requirements for cross-compilation.
//! 2. **Zero-Allocation Hot-Paths**: Packet parsing, notification dispatching, and D-Bus message deserialization
//!    execute without heap allocations (`no-alloc`), slicing directly from network buffers.
//! 3. **Strict Memory & Hardware Alignment**: Multi-byte integers and structs enforce Little-Endian encoding
//!    and aligned offsets to prevent unaligned trap faults on embedded ARM, MIPS, and RISC-V targets.
//! 4. **Dual Role Architecture**: Supports both Central (GATT Client / Scanner) and Peripheral (GATT Server / Broadcaster) roles.
//!
//! ## Modules Overview
//! - `core`: Platform-independent BLE primitives (UUID, Address, Advertising, GATT types, Bluetooth SIG Assigned Numbers).
//! - `wire`: Pure-Zig D-Bus Wire Protocol engine (Reader, Writer, Header, SASL Auth, SCM_RIGHTS Unix Sockets).
//! - `Adapter`: Linux Bluetooth adapter controller (discovery, powering, pairing filters).
//! - `Device`: Remote BLE peripheral manager (connection, RSSI streaming, GATT exploration).
//! - `GattCharacteristic`: GATT characteristic I/O (Read, Write, AcquireWrite pipe streaming, Notifications).
//! - `Peripheral`: Unified peripheral engine for GATT server hosting and custom advertisement beaconing.

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
pub const CharacteristicProps = core.CharacteristicProps;
pub const Cccd = core.Cccd;
pub const ServiceType = core.ServiceType;
pub const WriteType = core.WriteType;
pub const AttOpcode = core.AttOpcode;
pub const ParseError = core.ParseError;
pub const NotificationData = core.NotificationData;
pub const parseNotification = core.parseNotification;

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
pub const PhyType = core.PhyType;
pub const SecondaryChannel = core.SecondaryChannel;

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

// Standard BLE Profiles & Beacons
pub const profiles = @import("profiles/mod.zig");
pub const HeartRateMeasurement = profiles.HeartRateMeasurement;
pub const SensorContactStatus = profiles.SensorContactStatus;
pub const BodySensorLocation = profiles.BodySensorLocation;
pub const BatteryService = profiles.BatteryService;
pub const EnvironmentalSensing = profiles.EnvironmentalSensing;
pub const NordicUart = profiles.NordicUart;
pub const IBeacon = profiles.IBeacon;
pub const Eddystone = profiles.Eddystone;

// L2CAP Connection-Oriented Channels (High-Speed Streaming)
pub const l2cap = @import("l2cap/mod.zig");
pub const L2capSocket = l2cap.L2capSocket;
pub const sockaddr_l2 = l2cap.sockaddr_l2;

test {
    std.testing.refAllDecls(@This());
    _ = core;
    _ = profiles;
    _ = l2cap;
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


