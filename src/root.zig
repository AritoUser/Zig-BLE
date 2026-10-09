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
pub const BondState = backend.BondState;
pub const WindowsBackend = backend.WindowsBackend;

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

// High-level BLE Controllers & Clients
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
        return null;
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
        return false;
    }
    pub fn isConnected(self: *@This()) !bool {
        _ = self;
        return false;
    }
    pub fn isTrusted(self: *@This()) !bool {
        _ = self;
        return false;
    }
    pub fn setTrusted(self: *@This(), trusted: bool) !void {
        _ = self;
        _ = trusted;
        return error.NotSupported;
    }
    pub fn getRSSI(self: *@This()) !?i16 {
        _ = self;
        return null;
    }
    pub fn getTxPower(self: *@This()) !?i16 {
        _ = self;
        return null;
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
            return null;
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

// Broadcaster & Peripheral Advertising
pub const advertising_server = if (builtin.os.tag == .linux) @import("advertising.zig") else struct {};
pub const AdvertisementType = if (builtin.os.tag == .linux) advertising_server.AdvertisementType else enum {
    peripheral,
    broadcast,
    pub fn toSlice(self: @This()) [:0]const u8 {
        return switch (self) {
            .peripheral => "peripheral",
            .broadcast => "broadcast",
        };
    }
};
pub const AdvertisementIncludes = if (builtin.os.tag == .linux) advertising_server.AdvertisementIncludes else struct {
    tx_power: bool = true,
    appearance: bool = false,
    local_name: bool = true,
};
pub const AdvertisementConfig = if (builtin.os.tag == .linux) advertising_server.AdvertisementConfig else struct {
    type: AdvertisementType = .peripheral,
    local_name: ?[:0]const u8 = null,
    service_uuids: []const UUID = &.{},
    manufacturer_data: ?struct {
        company_id: u16,
        data: []const u8,
    } = null,
    service_data: ?struct {
        uuid: UUID,
        data: []const u8,
    } = null,
    discoverable: bool = true,
    includes: AdvertisementIncludes = .{},
    appearance: ?u16 = null,
    duration_s: ?u16 = null,
    timeout_s: ?u16 = null,
    secondary_channel: ?core.SecondaryChannel = null,
    min_interval_ms: ?u32 = null,
    max_interval_ms: ?u32 = null,
    tx_power: ?i8 = null,
};
pub const Advertisement = if (builtin.os.tag == .linux) advertising_server.Advertisement else struct {
    conn: *Connection,
    config: AdvertisementConfig,
    pub fn init(conn: *Connection, adapter_path: [:0]const u8, adv_path: [:0]const u8, config: AdvertisementConfig) @This() {
        _ = adapter_path;
        _ = adv_path;
        return .{ .conn = conn, .config = config };
    }
    pub fn register(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn unregister(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
};

// GATT Server / Peripheral Mode
pub const gatt_server = if (builtin.os.tag == .linux) @import("gatt_server.zig") else struct {};
pub const ServerCharacteristicFlags = if (builtin.os.tag == .linux) gatt_server.ServerCharacteristicFlags else struct {
    read: bool = false,
    write: bool = false,
    notify: bool = false,
    indicate: bool = false,
    write_without_response: bool = false,
};
pub const ServerDescriptorFlags = if (builtin.os.tag == .linux) gatt_server.ServerDescriptorFlags else struct {
    read: bool = false,
    write: bool = false,
};
pub const ServerDescriptor = if (builtin.os.tag == .linux) gatt_server.ServerDescriptor else struct {
    pub fn setValue(self: *@This(), val: []const u8) void {
        _ = self;
        _ = val;
    }
};
pub const ServerCharacteristic = if (builtin.os.tag == .linux) gatt_server.ServerCharacteristic else struct {
    pub fn setValue(self: *@This(), val: []const u8) void {
        _ = self;
        _ = val;
    }
    pub fn setUserDescription(self: *@This(), desc: []const u8) !*ServerDescriptor {
        _ = self;
        _ = desc;
        const S = struct {
            var desc_instance: ServerDescriptor = .{};
        };
        return &S.desc_instance;
    }
    pub fn notify(self: *@This(), conn: *Connection, data: []const u8) !void {
        _ = self;
        _ = conn;
        _ = data;
    }
};
pub const ServerService = if (builtin.os.tag == .linux) gatt_server.ServerService else struct {
    pub fn addCharacteristic(self: *@This(), uuid: UUID, flags: ServerCharacteristicFlags) !*ServerCharacteristic {
        _ = self;
        _ = uuid;
        _ = flags;
        const S = struct {
            var char_instance: ServerCharacteristic = .{};
        };
        return &S.char_instance;
    }
};
pub const GattApplication = if (builtin.os.tag == .linux) gatt_server.GattApplication else struct {
    pub fn init(conn: *Connection, adapter_path: [:0]const u8, app_path: [:0]const u8) @This() {
        _ = conn;
        _ = adapter_path;
        _ = app_path;
        return .{};
    }
    pub fn addService(self: *@This(), service: *ServerService) !void {
        _ = self;
        _ = service;
    }
};

// Pairing Agent
pub const agent_mod = if (builtin.os.tag == .linux) @import("agent.zig") else struct {};
pub const AgentCapability = if (builtin.os.tag == .linux) agent_mod.AgentCapability else enum {
    display_only,
    display_yes_no,
    keyboard_only,
    no_input_no_output,
    keyboard_display,
};
pub const Agent = if (builtin.os.tag == .linux) @import("agent.zig").Agent else struct {};

// Unified High-Level Peripheral
pub const peripheral_mod = if (builtin.os.tag == .linux) @import("peripheral.zig") else struct {};
pub const PeripheralOptions = if (builtin.os.tag == .linux) peripheral_mod.PeripheralOptions else struct {
    enable_agent: bool = true,
    agent_capability: AgentCapability = .no_input_no_output,
    app_path: [:0]const u8 = "/org/zig_ble/app0",
    adv_path: [:0]const u8 = "/org/zig_ble/advertisement0",
    agent_path: [:0]const u8 = "/org/zig_ble/agent",
};
pub const Peripheral = if (builtin.os.tag == .linux) peripheral_mod.Peripheral else struct {
    pub fn init(
        conn: *Connection,
        adapter_path: [:0]const u8,
        adv_config: AdvertisementConfig,
        options: PeripheralOptions,
    ) @This() {
        _ = conn;
        _ = adapter_path;
        _ = adv_config;
        _ = options;
        return .{};
    }
    pub fn addService(self: *@This(), uuid: UUID, primary: bool) !*ServerService {
        _ = self;
        _ = uuid;
        _ = primary;
        const S = struct {
            var srv_instance: ServerService = .{};
        };
        return &S.srv_instance;
    }
    pub fn startBackground(self: *@This()) !void {
        _ = self;
        return error.NotSupported;
    }
    pub fn stop(self: *@This()) void {
        _ = self;
    }
};

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
    struct {
        pub fn initSystem() anyerror!@This() {
            return error.NotSupported;
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
        }
        pub fn addMatch(self: *@This(), rule: [:0]const u8) anyerror!void {
            _ = self;
            _ = rule;
            return error.NotSupported;
        }
        pub fn pollSocket(self: *@This(), timeout_ms: c_int) usize {
            _ = self;
            _ = timeout_ms;
            return 0;
        }
        pub fn popMessage(self: *@This()) ?wire.Message {
            _ = self;
            return null;
        }
        pub fn popMatching(
            self: *@This(),
            context: anytype,
            comptime predicate: anytype,
        ) ?wire.Message {
            _ = self;
            _ = context;
            _ = predicate;
            return null;
        }
        pub fn requeueMessage(self: *@This(), msg: wire.Message) !void {
            _ = self;
            _ = msg;
            return error.NotSupported;
        }
        pub fn callMethod(
            self: *@This(),
            dest: [:0]const u8,
            path: [:0]const u8,
            iface: [:0]const u8,
            method: [:0]const u8,
            timeout_ms: u32,
        ) anyerror!wire.Message {
            _ = self;
            _ = dest;
            _ = path;
            _ = iface;
            _ = method;
            _ = timeout_ms;
            return error.NotSupported;
        }
        pub fn sendMessage(self: *@This(), msg: *wire.Message, timeout_ms: u32) anyerror!wire.Message {
            _ = self;
            _ = msg;
            _ = timeout_ms;
            return error.NotSupported;
        }
    };

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
pub const subrating = hci.subrating;
pub const SubrateParameters = hci.SubrateParameters;
pub const encodeSubrateRequest = hci.encodeSubrateRequest;
pub const decodeSubrateChangeEvent = hci.decodeSubrateChangeEvent;

// Bluetooth Cryptography & Security Manager Protocol (SMP)
pub const crypto = @import("crypto/mod.zig");
pub const smp = crypto.smp;
pub const resolveRpa = crypto.resolveRpa;
pub const generateRpa = crypto.generateRpa;
pub const signAtt = crypto.signAtt;
pub const verifyAttSign = crypto.verifyAttSign;
pub const gattHash = crypto.gattHash;
pub const SmpPdu = crypto.SmpPdu;
pub const SmpOpcode = crypto.SmpOpcode;
pub const IoCapability = crypto.IoCapability;
pub const AuthReq = crypto.AuthReq;
pub const PairingFailedReason = crypto.PairingFailedReason;

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
