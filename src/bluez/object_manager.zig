//! BlueZ ObjectManager Parser & Domain Models
//! Processes GetManagedObjects and InterfacesAdded/InterfacesRemoved signals.
//! 100% Zero-Heap-Allocation via static buffers and sentinel-terminated slices.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const constants = @import("constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("../dbus/mod.zig") else struct {};
const wire = @import("../dbus/wire/mod.zig");

fn copyBoundedString(dest: []u8, src: []const u8) u8 {
    const copy_len = @min(dest.len - 1, src.len);
    @memcpy(dest[0..copy_len], src[0..copy_len]);
    dest[copy_len] = 0;
    return @intCast(copy_len);
}

fn copyBoundedBytes(dest: []u8, src: []const u8) u8 {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return @intCast(len);
}

/// Information about a local Bluetooth controller (Adapter1).
pub const AdapterInfo = struct {
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,
    address: core.Address = core.Address.any,
    address_type: core.AddressType = .public,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alias: [64]u8 = undefined,
    alias_len: u8 = 0,
    powered: bool = false,
    discoverable: bool = false,
    discovering: bool = false,

    pub fn getObjectPath(self: *const AdapterInfo) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getName(self: *const AdapterInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getAlias(self: *const AdapterInfo) []const u8 {
        return self.alias[0..self.alias_len];
    }
};

/// Information about a discovered or connected BLE device (Device1).
pub const DeviceInfo = struct {
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,
    address: core.Address = core.Address.any,
    address_type: core.AddressType = .public,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    alias: [64]u8 = undefined,
    alias_len: u8 = 0,
    paired: bool = false,
    connected: bool = false,
    /// Essential for preventing BlueZ race conditions:
    /// GATT operations must only be executed after ServicesResolved = true!
    services_resolved: bool = false,
    rssi: ?i16 = null,
    tx_power: ?i16 = null,
    appearance: ?u16 = null,
    manufacturer_id: ?u16 = null,
    manufacturer_data_buf: [64]u8 = undefined,
    manufacturer_data_len: u8 = 0,

    pub fn getObjectPath(self: *const DeviceInfo) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getAdapterPath(self: *const DeviceInfo) [:0]const u8 {
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    pub fn getName(self: *const DeviceInfo) ?[]const u8 {
        if (self.name_len == 0) return null;
        return self.name[0..self.name_len];
    }

    pub fn getAlias(self: *const DeviceInfo) []const u8 {
        return self.alias[0..self.alias_len];
    }

    pub fn getManufacturerData(self: *const DeviceInfo) ?[]const u8 {
        if (self.manufacturer_id == null) return null;
        return self.manufacturer_data_buf[0..self.manufacturer_data_len];
    }
};

/// Information about a GATT service (GattService1).
pub const GattServiceInfo = struct {
    object_path: [192]u8 = undefined,
    object_path_len: u8 = 0,
    device_path: [160]u8 = undefined,
    device_path_len: u8 = 0,
    uuid: core.UUID = core.UUID{ .bytes = [_]u8{0} ** 16 },
    primary: bool = true,

    pub fn getObjectPath(self: *const GattServiceInfo) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getDevicePath(self: *const GattServiceInfo) [:0]const u8 {
        return self.device_path[0..self.device_path_len :0];
    }
};

/// Information about a GATT characteristic (GattCharacteristic1).
pub const GattCharacteristicInfo = struct {
    object_path: [224]u8 = undefined,
    object_path_len: u8 = 0,
    service_path: [192]u8 = undefined,
    service_path_len: u8 = 0,
    uuid: core.UUID = core.UUID{ .bytes = [_]u8{0} ** 16 },
    flags: core.CharacteristicProperties = .{},
    notifying: bool = false,
    mtu: u16 = 23,

    pub fn getObjectPath(self: *const GattCharacteristicInfo) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getServicePath(self: *const GattCharacteristicInfo) [:0]const u8 {
        return self.service_path[0..self.service_path_len :0];
    }
};

/// Information about a GATT descriptor (GattDescriptor1).
pub const GattDescriptorInfo = struct {
    object_path: [256]u8 = undefined,
    object_path_len: u8 = 0,
    characteristic_path: [224]u8 = undefined,
    char_path_len: u8 = 0,
    uuid: core.UUID = core.UUID{ .bytes = [_]u8{0} ** 16 },

    pub fn getObjectPath(self: *const GattDescriptorInfo) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getCharacteristicPath(self: *const GattDescriptorInfo) [:0]const u8 {
        return self.characteristic_path[0..self.char_path_len :0];
    }
};

// ============================================================================
// D-Bus Property-Parser (Zero-Heap-Allocation)
// ============================================================================

pub fn parseAdapterProps(obj_path: [:0]const u8, props_iter: anytype) AdapterInfo {
    var info = AdapterInfo{};
    info.object_path_len = copyBoundedString(&info.object_path, obj_path);

    var it = props_iter.*;
    while (it.hasMore()) {
        if (it.recurse()) |*dict_entry| {
            var entry = dict_entry.*;
            if (entry.getString()) |key| {
                if (entry.getVariant()) |*variant| {
                    var v = variant.*;
                    if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Address)) {
                        if (v.getString()) |s| {
                            if (core.Address.parse(s)) |addr| info.address = addr else |_| {}
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.AddressType)) {
                        if (v.getString()) |s| {
                            if (core.AddressType.parse(s)) |t| {
                                info.address_type = t;
                            }
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Name)) {
                        if (v.getString()) |s| {
                            info.name_len = copyBoundedString(&info.name, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Alias)) {
                        if (v.getString()) |s| {
                            info.alias_len = copyBoundedString(&info.alias, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Powered)) {
                        if (v.getBool()) |b| info.powered = b;
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Discovering)) {
                        if (v.getBool()) |b| info.discovering = b;
                    } else if (std.mem.eql(u8, key, BlueZ.Adapter1.Properties.Discoverable)) {
                        if (v.getBool()) |b| info.discoverable = b;
                    }
                }
            }
        }
        _ = it.next();
    }
    return info;
}

pub fn parseDeviceProps(obj_path: [:0]const u8, props_iter: anytype) DeviceInfo {
    var info = DeviceInfo{};
    info.object_path_len = copyBoundedString(&info.object_path, obj_path);

    var it = props_iter.*;
    while (it.hasMore()) {
        if (it.recurse()) |*dict_entry| {
            var entry = dict_entry.*;
            if (entry.getString()) |key| {
                if (entry.getVariant()) |*variant| {
                    var v = variant.*;
                    if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Address)) {
                        if (v.getString()) |s| {
                            if (core.Address.parse(s)) |addr| info.address = addr else |_| {}
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.AddressType)) {
                        if (v.getString()) |s| {
                            if (core.AddressType.parse(s)) |t| {
                                info.address_type = t;
                            }
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Name)) {
                        if (v.getString()) |s| {
                            info.name_len = copyBoundedString(&info.name, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Alias)) {
                        if (v.getString()) |s| {
                            info.alias_len = copyBoundedString(&info.alias, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Adapter)) {
                        if (v.getObjectPath()) |s| {
                            info.adapter_path_len = copyBoundedString(&info.adapter_path, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Connected)) {
                        if (v.getBool()) |b| info.connected = b;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Paired)) {
                        if (v.getBool()) |b| info.paired = b;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.ServicesResolved)) {
                        if (v.getBool()) |b| info.services_resolved = b;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.RSSI)) {
                        if (v.getInt16()) |n| info.rssi = n;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.TxPower)) {
                        if (v.getInt16()) |n| info.tx_power = n;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.Appearance)) {
                        if (v.getUInt16()) |u| info.appearance = u;
                    } else if (std.mem.eql(u8, key, BlueZ.Device1.Properties.ManufacturerData)) {
                        // Dict of {uint16: variant<array of bytes>}
                        if (v.recurse()) |*mfg_dict| {
                            var md = mfg_dict.*;
                            while (md.hasMore()) {
                                if (md.recurse()) |*mfg_entry| {
                                    var me = mfg_entry.*;
                                    info.manufacturer_id = me.getUInt16();
                                    if (me.getVariant()) |*mv| {
                                        var mvar = mv.*;
                                        if (mvar.getFixedBytes()) |bytes| {
                                            info.manufacturer_data_len = copyBoundedBytes(&info.manufacturer_data_buf, bytes);
                                        }
                                    }
                                }
                                _ = md.next();
                                break; // Take first entry
                            }
                        }
                    }
                }
            }
        }
        _ = it.next();
    }
    return info;
}

pub fn parseGattServiceProps(obj_path: [:0]const u8, props_iter: anytype) GattServiceInfo {
    var info = GattServiceInfo{};
    info.object_path_len = copyBoundedString(&info.object_path, obj_path);

    var it = props_iter.*;
    while (it.hasMore()) {
        if (it.recurse()) |*dict_entry| {
            var entry = dict_entry.*;
            if (entry.getString()) |key| {
                if (entry.getVariant()) |*variant| {
                    var v = variant.*;
                    if (std.mem.eql(u8, key, BlueZ.GattService1.Properties.UUID)) {
                        if (v.getString()) |s| {
                            if (core.UUID.parse(s)) |u| info.uuid = u else |_| {}
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.GattService1.Properties.Device)) {
                        if (v.getObjectPath()) |s| {
                            info.device_path_len = copyBoundedString(&info.device_path, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.GattService1.Properties.Primary)) {
                        if (v.getBool()) |b| info.primary = b;
                    }
                }
            }
        }
        _ = it.next();
    }
    return info;
}

pub fn parseGattCharProps(obj_path: [:0]const u8, props_iter: anytype) GattCharacteristicInfo {
    var info = GattCharacteristicInfo{};
    info.object_path_len = copyBoundedString(&info.object_path, obj_path);

    var it = props_iter.*;
    while (it.hasMore()) {
        if (it.recurse()) |*dict_entry| {
            var entry = dict_entry.*;
            if (entry.getString()) |key| {
                if (entry.getVariant()) |*variant| {
                    var v = variant.*;
                    if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.UUID)) {
                        if (v.getString()) |s| {
                            if (core.UUID.parse(s)) |u| info.uuid = u else |_| {}
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.Service)) {
                        if (v.getObjectPath()) |s| {
                            info.service_path_len = copyBoundedString(&info.service_path, s);
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.Notifying)) {
                        if (v.getBool()) |b| info.notifying = b;
                    } else if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.MTU)) {
                        if (v.getUInt16()) |u| info.mtu = u;
                    } else if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.Flags)) {
                        if (v.recurse()) |*flags_array| {
                            var fa = flags_array.*;
                            while (fa.hasMore()) {
                                if (fa.getString()) |flag_str| {
                                    info.flags.parseBluezFlag(flag_str);
                                }
                                _ = fa.next();
                            }
                        }
                    }
                }
            }
        }
        _ = it.next();
    }
    return info;
}

pub fn parseGattDescProps(obj_path: [:0]const u8, props_iter: anytype) GattDescriptorInfo {
    var info = GattDescriptorInfo{};
    info.object_path_len = copyBoundedString(&info.object_path, obj_path);

    var it = props_iter.*;
    while (it.hasMore()) {
        if (it.recurse()) |*dict_entry| {
            var entry = dict_entry.*;
            if (entry.getString()) |key| {
                if (entry.getVariant()) |*variant| {
                    var v = variant.*;
                    if (std.mem.eql(u8, key, BlueZ.GattDescriptor1.Properties.UUID)) {
                        if (v.getString()) |s| {
                            if (core.UUID.parse(s)) |u| info.uuid = u else |_| {}
                        }
                    } else if (std.mem.eql(u8, key, BlueZ.GattDescriptor1.Properties.Characteristic)) {
                        if (v.getObjectPath()) |s| {
                            info.char_path_len = copyBoundedString(&info.characteristic_path, s);
                        }
                    }
                }
            }
        }
        _ = it.next();
    }
    return info;
}

/// Parses the full D-Bus response of GetManagedObjects (a{oa{sa{sv}}}).
/// Dispatches callbacks to the provided handler (zero-allocation via comptime duck-typing).
pub fn parseManagedObjects(root_iter: anytype, comptime Handler: type, handler: *Handler) void {
    var array_sub = root_iter.recurse() orelse return;

    while (array_sub.hasMore()) {
        if (array_sub.recurse()) |*dict_entry| {
            var de = dict_entry.*;
            const obj_path = de.getObjectPath() orelse {
                _ = array_sub.next();
                continue;
            };

            if (de.recurse()) |*ifaces_array| {
                var ia = ifaces_array.*;
                while (ia.hasMore()) {
                    if (ia.recurse()) |*iface_entry| {
                        var ie = iface_entry.*;
                        const iface_name = ie.getString() orelse {
                            _ = ia.next();
                            continue;
                        };

                        if (ie.recurse()) |*props_iter| {
                            if (std.mem.eql(u8, iface_name, BlueZ.Adapter1.interface_name)) {
                                if (@hasDecl(Handler, "onAdapter")) {
                                    const adapter = parseAdapterProps(obj_path, props_iter);
                                    handler.onAdapter(adapter);
                                }
                            } else if (std.mem.eql(u8, iface_name, BlueZ.Device1.interface_name)) {
                                if (@hasDecl(Handler, "onDevice")) {
                                    const device = parseDeviceProps(obj_path, props_iter);
                                    handler.onDevice(device);
                                }
                            } else if (std.mem.eql(u8, iface_name, BlueZ.GattService1.interface_name)) {
                                if (@hasDecl(Handler, "onGattService")) {
                                    const svc = parseGattServiceProps(obj_path, props_iter);
                                    handler.onGattService(svc);
                                }
                            } else if (std.mem.eql(u8, iface_name, BlueZ.GattCharacteristic1.interface_name)) {
                                if (@hasDecl(Handler, "onGattCharacteristic")) {
                                    const ch = parseGattCharProps(obj_path, props_iter);
                                    handler.onGattCharacteristic(ch);
                                }
                            } else if (std.mem.eql(u8, iface_name, BlueZ.GattDescriptor1.interface_name)) {
                                if (@hasDecl(Handler, "onGattDescriptor")) {
                                    const desc = parseGattDescProps(obj_path, props_iter);
                                    handler.onGattDescriptor(desc);
                                }
                            }
                        }
                    }
                    _ = ia.next();
                }
            }
        }
        _ = array_sub.next();
    }
}

/// Parses parameters of the D-Bus signal InterfacesAdded(o, a{sa{sv}}).
pub fn parseInterfacesAdded(obj_path: [:0]const u8, ifaces_iter: anytype, comptime Handler: type, handler: *Handler) void {
    var array_sub = ifaces_iter.recurse() orelse return;
    while (array_sub.hasMore()) {
        if (array_sub.recurse()) |*iface_entry| {
            var ie = iface_entry.*;
            const iface_name = ie.getString() orelse {
                _ = array_sub.next();
                continue;
            };

            if (ie.recurse()) |*props_iter| {
                if (std.mem.eql(u8, iface_name, BlueZ.Adapter1.interface_name)) {
                    if (@hasDecl(Handler, "onAdapter")) {
                        const adapter = parseAdapterProps(obj_path, props_iter);
                        handler.onAdapter(adapter);
                    }
                } else if (std.mem.eql(u8, iface_name, BlueZ.Device1.interface_name)) {
                    if (@hasDecl(Handler, "onDevice")) {
                        const device = parseDeviceProps(obj_path, props_iter);
                        handler.onDevice(device);
                    }
                } else if (std.mem.eql(u8, iface_name, BlueZ.GattService1.interface_name)) {
                    if (@hasDecl(Handler, "onGattService")) {
                        const svc = parseGattServiceProps(obj_path, props_iter);
                        handler.onGattService(svc);
                    }
                } else if (std.mem.eql(u8, iface_name, BlueZ.GattCharacteristic1.interface_name)) {
                    if (@hasDecl(Handler, "onGattCharacteristic")) {
                        const ch = parseGattCharProps(obj_path, props_iter);
                        handler.onGattCharacteristic(ch);
                    }
                } else if (std.mem.eql(u8, iface_name, BlueZ.GattDescriptor1.interface_name)) {
                    if (@hasDecl(Handler, "onGattDescriptor")) {
                        const desc = parseGattDescProps(obj_path, props_iter);
                        handler.onGattDescriptor(desc);
                    }
                }
            }
        }
        _ = array_sub.next();
    }
}

test "parseManagedObjects correctly decodes adapters and devices without skipping" {
    var body_buf = wire.ByteBuffer.init(std.testing.allocator);
    defer body_buf.deinit();
    var sig_buf = wire.ByteBuffer.init(std.testing.allocator);
    defer sig_buf.deinit();

    var builder = wire.MessageBuilder.init(&body_buf, &sig_buf);

    // Signature: a{oa{sa{sv}}}
    var root_array = try builder.openArray("{oa{sa{sv}}}");
    {
        // Entry 1: Adapter /org/bluez/hci0
        var obj1 = try root_array.openDictEntry();
        try obj1.appendObjectPath("/org/bluez/hci0");

        var ifaces_arr = try obj1.openArray("{sa{sv}}");
        {
            var iface1 = try ifaces_arr.openDictEntry();
            try iface1.appendString("org.bluez.Adapter1");

            var props_arr = try iface1.openArray("{sv}");
            {
                var p1 = try props_arr.openDictEntry();
                try p1.appendString("Address");
                var v1 = try p1.openVariant("s");
                try v1.appendString("0C:CD:D0:22:B1:D1");
                try p1.closeContainer(&v1);
                try props_arr.closeContainer(&p1);

                var p2 = try props_arr.openDictEntry();
                try p2.appendString("Name");
                var v2 = try p2.openVariant("s");
                try v2.appendString("hci0");
                try p2.closeContainer(&v2);
                try props_arr.closeContainer(&p2);

                var p3 = try props_arr.openDictEntry();
                try p3.appendString("Powered");
                var v3 = try p3.openVariant("b");
                try v3.appendBool(true);
                try v3.closeContainer(&v3);
                try props_arr.closeContainer(&p3);
            }
            try iface1.closeContainer(&props_arr);
            try ifaces_arr.closeContainer(&iface1);
        }
        try obj1.closeContainer(&ifaces_arr);
        try root_array.closeContainer(&obj1);

        // Entry 2: Device /org/bluez/hci0/dev_11_22_33_44_55_66
        var obj2 = try root_array.openDictEntry();
        try obj2.appendObjectPath("/org/bluez/hci0/dev_11_22_33_44_55_66");

        var dev_ifaces = try obj2.openArray("{sa{sv}}");
        {
            var dev_iface = try dev_ifaces.openDictEntry();
            try dev_iface.appendString("org.bluez.Device1");

            var dev_props = try dev_iface.openArray("{sv}");
            {
                var dp1 = try dev_props.openDictEntry();
                try dp1.appendString("Address");
                var dv1 = try dp1.openVariant("s");
                try dv1.appendString("11:22:33:44:55:66");
                try dp1.closeContainer(&dv1);
                try dev_props.closeContainer(&dp1);

                var dp2 = try dev_props.openDictEntry();
                try dp2.appendString("Name");
                var dv2 = try dp2.openVariant("s");
                try dv2.appendString("TestDevice");
                try dp2.closeContainer(&dv2);
                try dev_props.closeContainer(&dp2);

                var dp3 = try dev_props.openDictEntry();
                try dp3.appendString("RSSI");
                var dv3 = try dp3.openVariant("n");
                try dv3.appendInt16(-55);
                try dp3.closeContainer(&dv3);
                try dev_props.closeContainer(&dp3);
            }
            try dev_iface.closeContainer(&dev_props);
            try dev_ifaces.closeContainer(&dev_iface);
        }
        try obj2.closeContainer(&dev_ifaces);
        try root_array.closeContainer(&obj2);
    }
    try builder.closeContainer(&root_array);

    const Handler = struct {
        adapter_found: bool = false,
        adapter_powered: bool = false,
        adapter_name_match: bool = false,
        device_found: bool = false,
        device_rssi: ?i16 = null,
        device_name_match: bool = false,

        pub fn onAdapter(self: *@This(), a: AdapterInfo) void {
            self.adapter_found = true;
            self.adapter_powered = a.powered;
            self.adapter_name_match = std.mem.eql(u8, a.getName(), "hci0");
            std.testing.expectEqualStrings("/org/bluez/hci0", a.getObjectPath()) catch unreachable;
        }

        pub fn onDevice(self: *@This(), d: DeviceInfo) void {
            self.device_found = true;
            self.device_rssi = d.rssi;
            if (d.getName()) |name| {
                self.device_name_match = std.mem.eql(u8, name, "TestDevice");
            }
            std.testing.expectEqualStrings("/org/bluez/hci0/dev_11_22_33_44_55_66", d.getObjectPath()) catch unreachable;
        }
    };

    var handler = Handler{};
    var iter = wire.MessageIter.init(body_buf.getSlice(), 0, body_buf.len, sig_buf.getSlice());
    parseManagedObjects(&iter, Handler, &handler);

    try std.testing.expect(handler.adapter_found);
    try std.testing.expect(handler.adapter_powered);
    try std.testing.expect(handler.adapter_name_match);
    try std.testing.expect(handler.device_found);
    try std.testing.expectEqual(@as(?i16, -55), handler.device_rssi);
    try std.testing.expect(handler.device_name_match);
}

