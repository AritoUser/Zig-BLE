//! # Zig-BLE: Native, Pure-Zig Bluetooth Low Energy Stack
//!
//! A high-performance, allocation-conscious Bluetooth Low Energy (BLE) engine for **Zig 0.17.0+**,
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
pub const backend = @import("backend/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const tooling = @import("tooling/mod.zig");
pub const pcap = tooling.pcap;

pub const BondStore = storage.BondStore;
pub const BondRecord = storage.BondRecord;
pub const SecurityKeys = storage.SecurityKeys;
pub const MemoryBondStore = storage.MemoryBondStore;
pub const BondStoreError = storage.BondStoreError;

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
pub const Units = core.Units;

// GATT typing and deserialization engine
pub const format = core.format;
pub const Sfloat = core.Sfloat;
pub const Float32 = core.Float32;
pub const FormatType = core.FormatType;
pub const CharacteristicPresentationFormat = core.CharacteristicPresentationFormat;
pub const serialize = core.serialize;
pub const deserialize = core.deserialize;

// GATT attributes & properties
pub const gatt = core.gatt;
pub const att = core.att;
pub const AttErrorCode = core.AttErrorCode;
pub const AttPdu = core.AttPdu;
pub const AttError = core.AttError;
pub const AttBearer = core.AttBearer;
pub const AttServerAttribute = core.AttServerAttribute;
pub const ServiceDiscoveryClient = core.ServiceDiscoveryClient;
pub const LongReadClient = core.LongReadClient;
pub const QueuedWriteClient = core.QueuedWriteClient;
pub const CharacteristicProperties = core.CharacteristicProperties;
pub const CharacteristicProps = core.CharacteristicProps;
pub const Cccd = core.Cccd;
pub const ServiceType = core.ServiceType;
pub const WriteType = core.WriteType;
pub const AttOpcode = core.AttOpcode;
pub const ParseError = core.ParseError;
pub const NotificationData = core.NotificationData;
pub const parseNotification = core.parseNotification;
pub const transfers = core.transfers;
pub const LongWriteIterator = core.LongWriteIterator;
pub const LongReadReassembler = core.LongReadReassembler;
pub const ServerPrepareWriteQueue = core.ServerPrepareWriteQueue;

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

// Unified Pluggable Backend HAL & Types
pub const Backend = backend.Backend;
pub const BackendVTable = backend.BackendVTable;
pub const UnifiedAdapter = backend.UnifiedAdapter;
pub const UnifiedDevice = backend.UnifiedDevice;
pub const MockController = backend.MockController;
pub const MockDevice = backend.MockDevice;
pub const MockCharacteristic = backend.MockCharacteristic;
pub const ScanFilter = backend.ScanFilter;
pub const DiscoveredDevice = backend.DiscoveredDevice;
pub const BleError = backend.BleError;
pub const TimeoutConfig = backend.TimeoutConfig;
pub const BondState = backend.BondState;
pub const PairingCallbacks = backend.PairingCallbacks;
pub const ConnectionEvent = backend.ConnectionEvent;
pub const ConnectionEventCallback = backend.ConnectionEventCallback;
pub const PcapDirection = backend.PcapDirection;
pub const PcapHook = backend.PcapHook;
pub const WindowsBackend = backend.WindowsBackend;
pub const WindowsBackendWithConfig = backend.WindowsBackendWithConfig;
pub const PoolConfig = backend.PoolConfig;
pub const BluezBackend = backend.BluezBackend;
pub const HciBackend = backend.HciBackend;
pub const UartBackend = backend.UartBackend;
pub const UartFramingMode = backend.UartFramingMode;
pub const MacosBackend = backend.MacosBackend;

// BT 5.2 Enhanced ATT (EATT)
pub const eatt = core.eatt;
pub const EattBearer = core.EattBearer;
pub const EattMultiplexer = core.EattMultiplexer;

// Capture Readers (PCAP & Btsnoop)
pub const PcapReader = tooling.PcapReader;
pub const PcapPacket = tooling.PcapPacket;
pub const BtsnoopReader = tooling.BtsnoopReader;
pub const BtsnoopPacket = tooling.BtsnoopPacket;

const builtin = @import("builtin");

// High-level BLE Controllers & Clients (Linux BlueZ D-Bus API)
pub const Adapter = if (builtin.os.tag == .linux) @import("adapter.zig").Adapter else struct {
    conn: *Connection,
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,

    pub const DiscoveryFilter = struct {
        transport: ?[:0]const u8 = "le",
        duplicate_data: ?bool = null,
    };

    pub fn init(conn: *Connection, path: [:0]const u8) @This() {
        _ = path;
        return .{ .conn = conn };
    }

    pub fn getObjectPath(self: *const @This()) [:0]const u8 {
        _ = self;
        return "/org/bluez/hci0";
    }

    pub fn findDefault(conn: *Connection) !?@This() {
        _ = conn;
        return error.NotSupported;
    }

    pub fn setPowered(self: *@This(), powered: bool) !void {
        _ = self;
        _ = powered;
        return error.NotSupported;
    }

    pub fn setDiscoveryFilter(self: *@This(), filter: DiscoveryFilter) !void {
        _ = self;
        _ = filter;
        return error.NotSupported;
    }

    pub fn startDiscovery(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }

    pub fn stopDiscovery(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }

    pub fn getInfo(self: *@This()) !AdapterInfo {
        _ = self;
        return error.NotSupported;
    }
};

pub const Device = if (builtin.os.tag == .linux) @import("device.zig").Device else struct {
    conn: *Connection,
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,

    pub fn init(conn: *Connection, path: [:0]const u8) @This() {
        _ = path;
        return .{ .conn = conn };
    }
    pub fn getObjectPath(self: *const @This()) [:0]const u8 {
        _ = self;
        return "/org/bluez/hci0/dev_00_00_00_00_00_00";
    }
    pub fn connect(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn disconnect(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn pair(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn cancelPairing(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn isPaired(self: *@This()) !bool {
        _ = self;
        return error.NotSupported;
    }
    pub fn isConnected(self: *@This()) !bool {
        _ = self;
        return error.NotSupported;
    }
    pub fn isTrusted(self: *@This()) !bool {
        _ = self;
        return error.NotSupported;
    }
    pub fn setTrusted(self: *@This(), trusted: bool) !void {
        _ = self;
        _ = trusted;
        return error.NotSupported;
    }
    pub fn getRSSI(self: *@This()) !?i16 {
        _ = self;
        return error.NotSupported;
    }
    pub fn getTxPower(self: *@This()) !?i16 {
        _ = self;
        return error.NotSupported;
    }
    pub fn getMtu(self: *@This()) !?u16 {
        _ = self;
        return error.NotSupported;
    }
};

const NonLinuxGattStream = struct {
    fd: c_int = -1,
    mtu: u16 = 23,
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};
const NonLinuxNotificationEvent = struct {
    characteristic_path: [:0]const u8 = "",
    data: []const u8 = &.{},
};
const NonLinuxNotificationDispatcher = struct {};

pub const gatt_client = if (builtin.os.tag == .linux) @import("gatt_client.zig") else struct {
    pub const GattCharacteristic = struct {
        pub fn readValue(self: *@This(), buf: []u8) !usize {
            _ = self;
            _ = buf;
            return error.NotSupported;
        }
        pub fn writeValue(self: *@This(), data: []const u8, write_type: core.WriteType) !void {
            _ = self;
            _ = data;
            _ = write_type;
            return error.NotSupported;
        }
        pub fn writeValueWithoutResponse(self: *@This(), val: []const u8) !void {
            _ = self;
            _ = val;
            return error.NotSupported;
        }
        pub fn readTyped(self: *@This(), comptime T: type) !T {
            _ = self;
            return error.NotSupported;
        }
        pub fn writeTyped(self: *@This(), val: anytype, write_type: core.WriteType) !void {
            _ = self;
            _ = val;
            _ = write_type;
            return error.NotSupported;
        }
        pub fn startNotify(self: *@This()) !void {
            _ = self;
            return error.NotSupported;
        }
        pub fn stopNotify(self: *@This()) !void {
            _ = self;
            return error.NotSupported;
        }
        pub fn acquireNotify(self: *@This()) !NonLinuxGattStream {
            _ = self;
            return error.NotSupported;
        }
        pub fn acquireWrite(self: *@This()) !NonLinuxGattStream {
            _ = self;
            return error.NotSupported;
        }
        pub fn waitForNotification(self: *@This(), buf: []u8, timeout_ms: c_int) !?usize {
            _ = self;
            _ = buf;
            _ = timeout_ms;
            return error.NotSupported;
        }
        pub fn getMtu(self: *@This()) !?u16 {
            _ = self;
            return error.NotSupported;
        }
    };
    pub const GattDescriptor = struct {
        pub fn readValue(self: *@This(), buf: []u8) !usize {
            _ = self;
            _ = buf;
            return error.NotSupported;
        }
        pub fn writeValue(self: *@This(), val: []const u8) !void {
            _ = self;
            _ = val;
            return error.NotSupported;
        }
        pub fn readTyped(self: *@This(), comptime T: type) !T {
            _ = self;
            return error.NotSupported;
        }
        pub fn writeTyped(self: *@This(), val: anytype) !void {
            _ = self;
            _ = val;
            return error.NotSupported;
        }
        pub fn readString(self: *@This(), buf: []u8) ![]const u8 {
            _ = self;
            _ = buf;
            return error.NotSupported;
        }
        pub fn getUUID(self: *@This()) !core.UUID {
            _ = self;
            return error.NotSupported;
        }
    };
    pub const GattStream = NonLinuxGattStream;
    pub const NotificationEvent = NonLinuxNotificationEvent;
    pub const NotificationDispatcher = NonLinuxNotificationDispatcher;
};
pub const GattCharacteristic = gatt_client.GattCharacteristic;
pub const GattDescriptor = gatt_client.GattDescriptor;
pub const GattStream = gatt_client.GattStream;
pub const NotificationEvent = gatt_client.NotificationEvent;
pub const NotificationDispatcher = gatt_client.NotificationDispatcher;

// Broadcaster & Peripheral Advertising (Supported on Linux BlueZ & Windows WinRT)
pub const advertising_server = @import("advertising.zig");
pub const AdvertisementType = advertising_server.AdvertisementType;
pub const AdvertisementIncludes = advertising_server.AdvertisementIncludes;
pub const AdvertisementConfig = advertising_server.AdvertisementConfig;
pub const Advertisement = advertising_server.Advertisement;

// GATT Server / Peripheral Mode (Supported on Linux BlueZ & Windows WinRT)
pub const gatt_server = @import("gatt_server.zig");
pub const ServerCharacteristicFlags = gatt_server.ServerCharacteristicFlags;
pub const ServerDescriptorFlags = gatt_server.ServerDescriptorFlags;
pub const ServerDescriptor = gatt_server.ServerDescriptor;
pub const ServerCharacteristic = gatt_server.ServerCharacteristic;
pub const ServerService = gatt_server.ServerService;
pub const GattApplication = gatt_server.GattApplication;

// Pairing Agent
pub const agent_mod = @import("agent.zig");
pub const AgentCapability = agent_mod.AgentCapability;
pub const AgentCallbacks = agent_mod.AgentCallbacks;
pub const Agent = agent_mod.Agent;

// Unified High-Level Peripheral
pub const peripheral_mod = @import("peripheral.zig");
pub const PeripheralOptions = peripheral_mod.PeripheralOptions;
pub const Peripheral = peripheral_mod.Peripheral;

// Universal EventLoop & Background Runner
pub const event_loop_mod = if (builtin.os.tag == .linux) @import("event_loop.zig") else struct {};
pub const EventLoop = if (builtin.os.tag == .linux) @import("event_loop.zig").EventLoop else struct {};
pub const MessageHandler = if (builtin.os.tag == .linux) @import("event_loop.zig").MessageHandler else struct {};

// Pure-Zig D-Bus Wire Protocol Suite (Zero-Allocation, Platform-Independent)
pub const wire = @import("dbus/wire/mod.zig");

// D-Bus layer (active on Linux)
pub const dbus = if (builtin.os.tag == .linux)
    @import("dbus/mod.zig")
else
    struct {
        pub const wire = @import("dbus/wire/mod.zig");
    };
pub const Connection = if (builtin.os.tag == .linux)
    dbus.Connection
else
    wire.NonLinuxConnection;

// Standard BLE Profiles & Beacons
pub const profiles = @import("profiles/mod.zig");
pub const HeartRateMeasurement = profiles.HeartRateMeasurement;
pub const SensorContactStatus = profiles.SensorContactStatus;
pub const BodySensorLocation = profiles.BodySensorLocation;
pub const BatteryService = profiles.BatteryService;
pub const DeviceInformationService = profiles.DeviceInformationService;
pub const CurrentTimeService = profiles.CurrentTimeService;
pub const HealthThermometerService = profiles.HealthThermometerService;
pub const BloodPressureService = profiles.BloodPressureService;
pub const HidService = profiles.HidService;
pub const EnvironmentalSensing = profiles.EnvironmentalSensing;
pub const NordicUart = profiles.NordicUart;
pub const Beacon = profiles.Beacon;
pub const IBeacon = profiles.IBeacon;
pub const AppleIBeacon = profiles.AppleIBeacon;
pub const Eddystone = profiles.Eddystone;
pub const EddystoneUrl = profiles.EddystoneUrl;
pub const EddystoneUid = profiles.EddystoneUid;
pub const EddystoneTlm = profiles.EddystoneTlm;

// Bluetooth SIG Fitness, Ergometer & Health Suite (v1.2.0)
pub const pulse_oximeter = profiles.pulse_oximeter;
pub const PlxFeatures = profiles.PlxFeatures;
pub const PlxMeasurementStatus = profiles.PlxMeasurementStatus;
pub const PlxDeviceAndSensorStatus = profiles.PlxDeviceAndSensorStatus;
pub const PlxSpotCheckMeasurement = profiles.PlxSpotCheckMeasurement;
pub const PlxContinuousMeasurement = profiles.PlxContinuousMeasurement;

pub const ftms = profiles.ftms;
pub const IndoorBikeData = profiles.IndoorBikeData;
pub const IndoorBikeAccumulator = profiles.IndoorBikeAccumulator;
pub const TreadmillData = profiles.TreadmillData;
pub const RowerData = profiles.RowerData;
pub const FitnessMachineControlPoint = profiles.FitnessMachineControlPoint;
pub const FitnessMachineFeature = profiles.FitnessMachineFeature;

pub const cpp = profiles.cpp;
pub const CyclingPowerMeasurement = profiles.CyclingPowerMeasurement;
pub const CyclingPowerFeature = profiles.CyclingPowerFeature;
pub const calculateCadenceRpm = profiles.calculateCadenceRpm;
pub const CadenceCalculator = profiles.CadenceCalculator;

pub const rscp = profiles.rscp;
pub const RscMeasurement = profiles.RscMeasurement;
pub const RscFeature = profiles.RscFeature;

// L2CAP Connection-Oriented Channels (High-Speed Streaming) & LE Signaling
pub const l2cap = @import("l2cap/mod.zig");
pub const L2capSocket = l2cap.L2capSocket;
pub const sockaddr_l2 = l2cap.sockaddr_l2;
pub const SecurityLevel = l2cap.SecurityLevel;
pub const bt_security = l2cap.bt_security;
pub const l2cap_options = l2cap.l2cap_options;
pub const AcceptedConnection = l2cap.AcceptedConnection;
pub const L2capSignalingPdu = l2cap.L2capSignalingPdu;
pub const SignalingOpcode = l2cap.SignalingOpcode;
pub const L2capHeader = l2cap.L2capHeader;
pub const AclReassembler = l2cap.AclReassembler;
pub const L2capFrame = l2cap.L2capFrame;
pub const PbFlag = l2cap.PbFlag;
pub const L2capStream = l2cap.L2capStream;
pub const L2capListener = l2cap.L2capListener;
pub const L2capConfig = l2cap.L2capConfig;
pub const connectL2cap = l2cap.connectL2cap;
pub const listenL2cap = l2cap.listenL2cap;

// Raw HCI Subsystem (Zero-Daemon / Embedded Mode)
pub const hci = @import("hci/mod.zig");
pub const HciSocket = hci.HciSocket;
pub const HciController = hci.HciController;
pub const HciFilter = hci.HciFilter;
pub const HciScanConfig = hci.HciScanConfig;
pub const HciEvent = hci.HciEvent;
pub const HciAdvertisingReport = hci.HciAdvertisingReport;
pub const HciExtAdvertisingReport = hci.HciExtAdvertisingReport;
pub const ExtAdvParams = hci.ExtAdvParams;
pub const H4Type = hci.H4Type;
pub const H4Packet = hci.H4Packet;
pub const H4StreamParser = hci.H4StreamParser;
pub const H4Serializer = hci.H4Serializer;
pub const AclFlowController = hci.AclFlowController;
pub const h5 = hci.h5;
pub const H5Header = hci.H5Header;
pub const H5PacketType = hci.H5PacketType;
pub const H5StreamParser = hci.H5StreamParser;
pub const H5Channel = hci.H5Channel;
pub const subrating = hci.subrating;
pub const SubrateParameters = hci.SubrateParameters;
pub const encodeSubrateRequest = hci.encodeSubrateRequest;
pub const decodeSubrateChangeEvent = hci.decodeSubrateChangeEvent;

// Bluetooth Cryptography & Security Manager Protocol (SMP)
pub const crypto = @import("crypto/mod.zig");
pub const smp = crypto.smp;
pub const CryptoError = crypto.CryptoError;
pub const resolveRpa = crypto.resolveRpa;
pub const generateRpa = crypto.generateRpa;
pub const signAtt = crypto.signAtt;
pub const verifyAttSign = crypto.verifyAttSign;
pub const gattHash = crypto.gattHash;
pub const h7 = crypto.h7;
pub const SmpPdu = crypto.SmpPdu;
pub const SmpOpcode = crypto.SmpOpcode;
pub const IoCapability = crypto.IoCapability;
pub const AuthReq = crypto.AuthReq;
pub const PairingFailedReason = crypto.PairingFailedReason;
pub const SmpStateMachine = crypto.SmpStateMachine;
pub const SmpRole = crypto.SmpRole;
pub const SmpState = crypto.SmpState;
pub const PairingMethod = crypto.PairingMethod;
pub const fuzz = @import("fuzz.zig");

test "Non-Linux D-Bus client stubs return error.NotSupported" {
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(error.NotSupported, Connection.initSystem());
        var dummy_conn: Connection = .{};
        try std.testing.expectError(error.NotSupported, Adapter.findDefault(&dummy_conn));
        var dev = Device.init(&dummy_conn, "/org/bluez/hci0/dev_00_00_00_00_00_00");
        try std.testing.expectError(error.NotSupported, dev.isPaired());
        try std.testing.expectError(error.NotSupported, dev.isConnected());
        try std.testing.expectError(error.NotSupported, dev.isTrusted());
        try std.testing.expectError(error.NotSupported, dev.getRSSI());
        try std.testing.expectError(error.NotSupported, dev.getTxPower());
        try std.testing.expectError(error.NotSupported, dev.getMtu());
        var ch: GattCharacteristic = .{};
        var buf: [16]u8 = undefined;
        try std.testing.expectError(error.NotSupported, ch.waitForNotification(&buf, 100));
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = core;
    _ = backend;
    _ = tooling;
    _ = profiles;
    _ = l2cap;
    _ = bluez;
    _ = hci;
    _ = crypto;
    _ = agent_mod;
    _ = advertising_server;
    _ = gatt_server;
    _ = peripheral_mod;
    _ = fuzz;
    if (builtin.os.tag == .linux) {
        _ = dbus;
        _ = gatt_client;
        _ = event_loop_mod;
    }
}
