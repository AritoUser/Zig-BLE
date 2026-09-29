const std = @import("std");
const types = @import("../core/types.zig");
const Address = types.Address;

/// Single Source of Truth for all D-Bus paths, interfaces, properties,
/// methods, and signals of the official Linux kernel BlueZ specification.
pub const BlueZ = struct {
    /// D-Bus Service Name for the Bluetooth daemon
    pub const service_name = "org.bluez";

    /// Root object path for the D-Bus ObjectManager
    pub const root_path = "/";

    /// Standard D-Bus interface names
    pub const Interfaces = struct {
        pub const adapter = "org.bluez.Adapter1";
        pub const device = "org.bluez.Device1";
        pub const gatt_service = "org.bluez.GattService1";
        pub const gatt_characteristic = "org.bluez.GattCharacteristic1";
        pub const gatt_descriptor = "org.bluez.GattDescriptor1";
        pub const battery = "org.bluez.Battery1";
        pub const le_advertising_manager = "org.bluez.LEAdvertisingManager1";
        pub const le_advertisement = "org.bluez.LEAdvertisement1";
        pub const agent_manager = "org.bluez.AgentManager1";
        pub const agent = "org.bluez.Agent1";

        // Standard Freedesktop D-Bus interfaces
        pub const object_manager = "org.freedesktop.DBus.ObjectManager";
        pub const properties = "org.freedesktop.DBus.Properties";
        pub const introspectable = "org.freedesktop.DBus.Introspectable";
    };

    /// Adapter1 interface (Bluetooth Controller, e.g. hci0)
    pub const Adapter1 = struct {
        pub const interface_name = Interfaces.adapter;

        pub const Methods = struct {
            pub const StartDiscovery = "StartDiscovery";
            pub const StopDiscovery = "StopDiscovery";
            pub const RemoveDevice = "RemoveDevice";
            pub const SetDiscoveryFilter = "SetDiscoveryFilter";
            pub const GetDiscoveryFilters = "GetDiscoveryFilters";
        };

        pub const Properties = struct {
            pub const Address = "Address"; // string
            pub const AddressType = "AddressType"; // string: "public" | "random"
            pub const Name = "Name"; // string
            pub const Alias = "Alias"; // string
            pub const Class = "Class"; // u32
            pub const Powered = "Powered"; // bool
            pub const Discoverable = "Discoverable"; // bool
            pub const DiscoverableTimeout = "DiscoverableTimeout"; // u32
            pub const Pairable = "Pairable"; // bool
            pub const PairableTimeout = "PairableTimeout"; // u32
            pub const Discovering = "Discovering"; // bool
            pub const UUIDs = "UUIDs"; // array of strings
            pub const Modalias = "Modalias"; // string
            pub const Roles = "Roles"; // array of strings
        };
    };

    /// Device1 interface (represents a discovered or connected BLE device)
    pub const Device1 = struct {
        pub const interface_name = Interfaces.device;

        pub const Methods = struct {
            pub const Connect = "Connect";
            pub const Disconnect = "Disconnect";
            pub const ConnectProfile = "ConnectProfile";
            pub const DisconnectProfile = "DisconnectProfile";
            pub const Pair = "Pair";
            pub const CancelPairing = "CancelPairing";
        };

        pub const Properties = struct {
            pub const Address = "Address"; // string "XX:XX:XX:XX:XX:XX"
            pub const AddressType = "AddressType"; // string: "public" | "random"
            pub const Name = "Name"; // string
            pub const Alias = "Alias"; // string
            pub const Class = "Class"; // u32
            pub const Appearance = "Appearance"; // u16
            pub const Icon = "Icon"; // string
            pub const Paired = "Paired"; // bool
            pub const Trusted = "Trusted"; // bool
            pub const Blocked = "Blocked"; // bool
            pub const LegacyPairing = "LegacyPairing"; // bool
            pub const RSSI = "RSSI"; // i16
            pub const Connected = "Connected"; // bool
            pub const UUIDs = "UUIDs"; // array of strings
            pub const Modalias = "Modalias"; // string
            pub const Adapter = "Adapter"; // object path
            pub const ManufacturerData = "ManufacturerData"; // dict: u16 -> variant array of bytes
            pub const ServiceData = "ServiceData"; // dict: string -> variant array of bytes
            pub const TxPower = "TxPower"; // i16
            /// Essential: Becomes true once BlueZ has resolved all GATT services and characteristics!
            /// Prevents the ServicesResolved race condition.
            pub const ServicesResolved = "ServicesResolved"; // bool
        };
    };

    /// GattService1 interface (GATT Primary or Secondary Service)
    pub const GattService1 = struct {
        pub const interface_name = Interfaces.gatt_service;

        pub const Properties = struct {
            pub const UUID = "UUID"; // string 128-bit
            pub const Primary = "Primary"; // bool
            pub const Device = "Device"; // object path
            pub const Includes = "Includes"; // array of object paths
        };
    };

    /// GattCharacteristic1 interface (GATT Characteristic)
    pub const GattCharacteristic1 = struct {
        pub const interface_name = Interfaces.gatt_characteristic;

        pub const Methods = struct {
            pub const ReadValue = "ReadValue"; // args: dict flags -> returns array of bytes
            pub const WriteValue = "WriteValue"; // args: array of bytes, dict flags
            pub const AcquireWrite = "AcquireWrite"; // args: dict flags -> returns fd, u16 mtu
            pub const AcquireNotify = "AcquireNotify"; // args: dict flags -> returns fd, u16 mtu
            pub const StartNotify = "StartNotify";
            pub const StopNotify = "StopNotify";
        };

        pub const Properties = struct {
            pub const UUID = "UUID"; // string 128-bit
            pub const Service = "Service"; // object path
            pub const Value = "Value"; // array of bytes
            pub const WriteAcquired = "WriteAcquired"; // bool
            pub const NotifyAcquired = "NotifyAcquired"; // bool
            pub const Notifying = "Notifying"; // bool
            pub const Flags = "Flags"; // array of strings ("read", "write", "notify", etc.)
            pub const MTU = "MTU"; // u16
        };
    };

    /// GattDescriptor1 interface (GATT Descriptor, e.g. CCCD 0x2902)
    pub const GattDescriptor1 = struct {
        pub const interface_name = Interfaces.gatt_descriptor;

        pub const Methods = struct {
            pub const ReadValue = "ReadValue"; // args: dict flags -> returns array of bytes
            pub const WriteValue = "WriteValue"; // args: array of bytes, dict flags
        };

        pub const Properties = struct {
            pub const UUID = "UUID"; // string 128-bit
            pub const Characteristic = "Characteristic"; // object path
            pub const Value = "Value"; // array of bytes
            pub const Flags = "Flags"; // array of strings
        };
    };

    /// Battery1 interface (optionally provided by BlueZ if Battery Service is active)
    pub const Battery1 = struct {
        pub const interface_name = Interfaces.battery;

        pub const Properties = struct {
            pub const Percentage = "Percentage"; // u8 (0..100)
        };
    };

    /// LEAdvertisingManager1 interface (manager for broadcast & peripheral advertisements)
    pub const LEAdvertisingManager1 = struct {
        pub const interface_name = Interfaces.le_advertising_manager;

        pub const Methods = struct {
            pub const RegisterAdvertisement = "RegisterAdvertisement";
            pub const UnregisterAdvertisement = "UnregisterAdvertisement";
        };

        pub const Properties = struct {
            pub const ActiveInstances = "ActiveInstances"; // u8
            pub const SupportedInstances = "SupportedInstances"; // u8
            pub const SupportedIncludes = "SupportedIncludes"; // array of strings
            pub const SupportedSecondaryChannels = "SupportedSecondaryChannels"; // array of strings
        };
    };

    /// LEAdvertisement1 interface (implemented by application via D-Bus)
    pub const LEAdvertisement1 = struct {
        pub const interface_name = Interfaces.le_advertisement;

        pub const Methods = struct {
            pub const Release = "Release";
        };

        pub const Properties = struct {
            pub const Type = "Type"; // string: "broadcast" | "peripheral"
            pub const ServiceUUIDs = "ServiceUUIDs"; // array of strings
            pub const ManufacturerData = "ManufacturerData"; // dict {q: ay}
            pub const SolicitUUIDs = "SolicitUUIDs"; // array of strings
            pub const ServiceData = "ServiceData"; // dict {s: ay}
            pub const Data = "Data"; // dict {y: ay}
            pub const Discoverable = "Discoverable"; // bool
            pub const DiscoverableTimeout = "DiscoverableTimeout"; // u16
            pub const Includes = "Includes"; // array of strings
            pub const LocalName = "LocalName"; // string
            pub const Appearance = "Appearance"; // u16
            pub const Duration = "Duration"; // u16
            pub const Timeout = "Timeout"; // u16
        };
    };

    /// GattManager1 interface (manager for local GATT server applications)
    pub const GattManager1 = struct {
        pub const interface_name = "org.bluez.GattManager1";

        pub const Methods = struct {
            pub const RegisterApplication = "RegisterApplication";
            pub const UnregisterApplication = "UnregisterApplication";
        };
    };

    /// AgentManager1 interface (registration of Bluetooth pairing agents)
    pub const AgentManager1 = struct {
        pub const interface_name = Interfaces.agent_manager;
        pub const object_path = "/org/bluez";

        pub const Methods = struct {
            pub const RegisterAgent = "RegisterAgent";
            pub const UnregisterAgent = "UnregisterAgent";
            pub const RequestDefaultAgent = "RequestDefaultAgent";
        };

        pub const Capability = struct {
            pub const DisplayOnly = "DisplayOnly";
            pub const DisplayYesNo = "DisplayYesNo";
            pub const KeyboardOnly = "KeyboardOnly";
            pub const NoInputNoOutput = "NoInputNoOutput";
            pub const KeyboardDisplay = "KeyboardDisplay";
        };
    };

    /// Agent1 interface (Bluetooth pairing & authentication handler)
    pub const Agent1 = struct {
        pub const interface_name = Interfaces.agent;

        pub const Methods = struct {
            pub const Release = "Release";
            pub const RequestPinCode = "RequestPinCode";
            pub const DisplayPinCode = "DisplayPinCode";
            pub const RequestPasskey = "RequestPasskey";
            pub const DisplayPasskey = "DisplayPasskey";
            pub const RequestConfirmation = "RequestConfirmation";
            pub const RequestAuthorization = "RequestAuthorization";
            pub const AuthorizeService = "AuthorizeService";
            pub const Cancel = "Cancel";
        };
    };

    /// ObjectManager & Properties signals & methods
    pub const ObjectManager = struct {
        pub const interface_name = Interfaces.object_manager;

        pub const Methods = struct {
            pub const GetManagedObjects = "GetManagedObjects";
        };

        pub const Signals = struct {
            pub const InterfacesAdded = "InterfacesAdded";
            pub const InterfacesRemoved = "InterfacesRemoved";
        };
    };

    pub const Properties = struct {
        pub const interface_name = Interfaces.properties;

        pub const Methods = struct {
            pub const Get = "Get";
            pub const Set = "Set";
            pub const GetAll = "GetAll";
        };

        pub const Signals = struct {
            pub const PropertiesChanged = "PropertiesChanged";
        };
    };

    // ========================================================================
    // Helper functions for D-Bus path conversions
    // ========================================================================

    /// Constructs the canonical BlueZ D-Bus object path for a device:
    /// Format: `<adapter_path>/dev_XX_XX_XX_XX_XX_XX` (BlueZ replaces colons with underscores).
    pub fn buildDevicePath(
        buf: *[96]u8,
        adapter_path: []const u8,
        address: Address,
    ) []const u8 {
        var addr_buf: [17]u8 = undefined;
        const mac_str = address.formatBuf(&addr_buf);

        // Replace ':' with '_'
        var mac_underscore: [17]u8 = undefined;
        for (mac_str, 0..) |c, i| {
            mac_underscore[i] = if (c == ':') '_' else c;
        }

        const formatted = std.fmt.bufPrint(buf, "{s}/dev_{s}", .{ adapter_path, &mac_underscore }) catch unreachable;
        return formatted;
    }

    /// Parses the MAC address from a BlueZ object path like `/org/bluez/hci0/dev_0C_CD_D0_22_B1_D1`.
    pub fn parseAddressFromDevicePath(path: []const u8) ?Address {
        const marker = "/dev_";
        const idx = std.mem.indexOf(u8, path, marker) orelse return null;
        const sub = path[idx + marker.len ..];
        if (sub.len < 17) return null;

        var mac_colon: [17]u8 = undefined;
        for (sub[0..17], 0..) |c, i| {
            mac_colon[i] = if (c == '_') ':' else c;
        }

        return Address.parse(&mac_colon) catch null;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "BlueZ constants: basic definitions" {
    try std.testing.expectEqualStrings("org.bluez", BlueZ.service_name);
    try std.testing.expectEqualStrings("/", BlueZ.root_path);
    try std.testing.expectEqualStrings("org.bluez.Adapter1", BlueZ.Adapter1.interface_name);
    try std.testing.expectEqualStrings("org.bluez.Device1", BlueZ.Device1.interface_name);
    try std.testing.expectEqualStrings("ServicesResolved", BlueZ.Device1.Properties.ServicesResolved);
}

test "BlueZ path helpers: build and parse device path" {
    // Sample adapter MAC: 0C:CD:D0:22:B1:D1
    const addr = try Address.parse("0C:CD:D0:22:B1:D1");

    var buf: [96]u8 = undefined;
    const path = BlueZ.buildDevicePath(&buf, "/org/bluez/hci0", addr);
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_0C_CD_D0_22_B1_D1", path);

    // Reverse parse from D-Bus path
    const parsed_addr = BlueZ.parseAddressFromDevicePath(path).?;
    try std.testing.expect(addr.eql(parsed_addr));
}
