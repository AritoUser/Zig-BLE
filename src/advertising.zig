//! Zig-BLE Advertising & Broadcaster: Broadcast BLE advertisements (iBeacon, custom sensor data, etc.)
//! via BlueZ `org.bluez.LEAdvertisingManager1` on Linux and WinRT `BluetoothLEAdvertisementPublisher` on Windows.
//! 100% Zero dynamic heap allocations.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const UUID = core.UUID;
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const log = std.log.scoped(.zig_ble);

const wire = @import("dbus/wire/mod.zig");
const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const win_bindings = if (builtin.os.tag == .windows) @import("backend/windows/bindings.zig") else struct {};
const win_mod = if (builtin.os.tag == .windows) @import("backend/windows/mod.zig") else struct {};

pub const Connection = if (builtin.os.tag == .linux) dbus.Connection else wire.NonLinuxConnection;
pub const Message = if (builtin.os.tag == .linux) dbus.Message else wire.Message;

pub const AdvertisementError = error{
    NotSupported,
    AdvertisementRegistrationFailed,
    Timeout,
    BufferTooSmall,
    IoError,
    InvalidParameter,
};

pub const AdvertisementType = enum {
    peripheral,
    broadcast,

    pub fn toSlice(self: AdvertisementType) [:0]const u8 {
        return switch (self) {
            .peripheral => "peripheral",
            .broadcast => "broadcast",
        };
    }
};

pub const AdvertisementIncludes = struct {
    tx_power: bool = true,
    appearance: bool = false,
    local_name: bool = true,
};

pub const AdvertisementConfig = struct {
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
    /// Secondary advertising channel for Bluetooth 5.0+ Extended Advertising (e.g. .coded for Long Range).
    secondary_channel: ?core.SecondaryChannel = null,
    /// Minimum advertising interval in milliseconds.
    min_interval_ms: ?u32 = null,
    /// Maximum advertising interval in milliseconds.
    max_interval_ms: ?u32 = null,
    /// Explicit transmit power level in dBm.
    tx_power: ?i8 = null,
};

pub const Advertisement = struct {
    conn: ?*Connection = null,
    object_path: [128]u8 = undefined,
    object_path_len: u8 = 0,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,
    config: AdvertisementConfig,
    is_registered: bool = false,

    win_publisher: if (builtin.os.tag == .windows) ?*win_bindings.IBluetoothLEAdvertisementPublisher else void =
        if (builtin.os.tag == .windows) null else {},

    pub fn init(
        conn: *Connection,
        adapter_path: [:0]const u8,
        adv_path: [:0]const u8,
        config: AdvertisementConfig,
    ) Advertisement {
        var adv = Advertisement{
            .conn = conn,
            .config = config,
        };

        const adv_len = @min(adv.object_path.len - 1, adv_path.len);
        @memcpy(adv.object_path[0..adv_len], adv_path[0..adv_len]);
        adv.object_path[adv_len] = 0;
        adv.object_path_len = @intCast(adv_len);

        const adp_len = @min(adv.adapter_path.len - 1, adapter_path.len);
        @memcpy(adv.adapter_path[0..adp_len], adapter_path[0..adp_len]);
        adv.adapter_path[adp_len] = 0;
        adv.adapter_path_len = @intCast(adp_len);

        return adv;
    }

    pub fn getObjectPath(self: *const Advertisement) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getAdapterPath(self: *const Advertisement) [:0]const u8 {
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    /// Registers the advertisement with the OS Bluetooth stack:
    /// - Linux: BlueZ `org.bluez.LEAdvertisingManager1.RegisterAdvertisement`
    /// - Windows: WinRT `Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher`
    pub fn register(self: *Advertisement) !void {
        if (builtin.os.tag == .linux) {
            return self.registerLinux();
        } else if (builtin.os.tag == .windows) {
            return self.registerWindows();
        } else {
            return error.NotSupported;
        }
    }

    fn registerWindows(self: *Advertisement) !void {
        if (builtin.os.tag != .windows) return error.NotSupported;
        if (self.is_registered) return;

        const hr_init = win_bindings.Combase.RoInitialize(win_bindings.RO_INIT_MULTITHREADED);
        if (hr_init < 0 and hr_init != win_bindings.RPC_E_CHANGED_MODE) {
            return error.IoError;
        }

        // Activate BluetoothLEAdvertisementPublisher
        const pub_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher");
        defer win_mod.deleteHString(pub_class);

        var insp: ?*win_bindings.IInspectable = null;
        if (win_bindings.Combase.RoActivateInstance(pub_class, &insp) < 0 or insp == null) {
            return error.AdvertisementRegistrationFailed;
        }
        const publisher_insp = insp.?;
        defer _ = publisher_insp.release();

        var publisher: ?*win_bindings.IBluetoothLEAdvertisementPublisher = null;
        if (publisher_insp.queryInterface(&win_bindings.IID_IBluetoothLEAdvertisementPublisher, @ptrCast(&publisher)) < 0 or publisher == null) {
            return error.AdvertisementRegistrationFailed;
        }
        const pub_ptr = publisher.?;
        errdefer _ = pub_ptr.lpVtbl.Release(pub_ptr);

        var adv_ptr: ?*win_bindings.IBluetoothLEAdvertisement = null;
        if (pub_ptr.lpVtbl.get_Advertisement(pub_ptr, &adv_ptr) >= 0 and adv_ptr != null) {
            const adv = adv_ptr.?;
            defer _ = adv.lpVtbl.Release(adv);

            // 1. Manufacturer Data (supported on all Windows 10/11 BluetoothLEAdvertisementPublisher instances)
            if (self.config.manufacturer_data) |mfg| {
                const mfg_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.Advertisement.BluetoothLEManufacturerData");
                defer win_mod.deleteHString(mfg_class);

                var mfg_factory: ?*win_bindings.IBluetoothLEManufacturerDataFactory = null;
                if (win_bindings.Combase.RoGetActivationFactory(mfg_class, &win_bindings.IID_IBluetoothLEManufacturerDataFactory, @ptrCast(&mfg_factory)) >= 0 and mfg_factory != null) {
                    const mf = mfg_factory.?;
                    defer _ = mf.lpVtbl.Release(mf);

                    const ibuf = try win_mod.createIBuffer(mfg.data);
                    defer _ = ibuf.lpVtbl.Release(ibuf);

                    var mfg_item: ?*win_bindings.IBluetoothLEManufacturerData = null;
                    if (mf.lpVtbl.Create(mf, mfg.company_id, ibuf, &mfg_item) >= 0 and mfg_item != null) {
                        const item = mfg_item.?;
                        defer _ = item.lpVtbl.Release(item);

                        var mfg_vec: ?*win_bindings.IVectorPtr = null;
                        if (adv.lpVtbl.get_ManufacturerData(adv, &mfg_vec) >= 0 and mfg_vec != null) {
                            const mv = mfg_vec.?;
                            defer _ = mv.lpVtbl.Release(mv);
                            _ = mv.lpVtbl.Append(mv, @ptrCast(item));
                        }
                    }
                }
            }

            // 2. Service Data Section (AD Type 0x16 for 16-bit UUID or 0x21 for 128-bit UUID)
            if (self.config.service_data) |sd| {
                const sec_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementDataSection");
                defer win_mod.deleteHString(sec_class);

                var sec_factory: ?*win_bindings.IBluetoothLEAdvertisementDataSectionFactory = null;
                if (win_bindings.Combase.RoGetActivationFactory(sec_class, &win_bindings.IID_IBluetoothLEAdvertisementDataSectionFactory, @ptrCast(&sec_factory)) >= 0 and sec_factory != null) {
                    const sf = sec_factory.?;
                    defer _ = sf.lpVtbl.Release(sf);

                    var section_payload: [252]u8 = undefined;
                    var payload_len: usize = 0;
                    var ad_type: u8 = 0x16; // Service Data - 16-bit UUID
                    if (sd.uuid.to16()) |u16_val| {
                        std.mem.writeInt(u16, section_payload[0..2], u16_val, .little);
                        const copy_len = @min(section_payload.len - 2, sd.data.len);
                        @memcpy(section_payload[2 .. 2 + copy_len], sd.data[0..copy_len]);
                        payload_len = 2 + copy_len;
                    } else {
                        ad_type = 0x21; // Service Data - 128-bit UUID
                        @memcpy(section_payload[0..16], &sd.uuid.bytes);
                        const copy_len = @min(section_payload.len - 16, sd.data.len);
                        @memcpy(section_payload[16 .. 16 + copy_len], sd.data[0..copy_len]);
                        payload_len = 16 + copy_len;
                    }

                    const ibuf = try win_mod.createIBuffer(section_payload[0..payload_len]);
                    defer _ = ibuf.lpVtbl.Release(ibuf);

                    var sec_item: ?*win_bindings.IBluetoothLEAdvertisementDataSection = null;
                    if (sf.lpVtbl.Create(sf, ad_type, ibuf, &sec_item) >= 0 and sec_item != null) {
                        const item = sec_item.?;
                        defer _ = item.lpVtbl.Release(item);

                        var sec_vec: ?*win_bindings.IVectorPtr = null;
                        if (adv.lpVtbl.get_DataSections(adv, &sec_vec) >= 0 and sec_vec != null) {
                            const sv = sec_vec.?;
                            defer _ = sv.lpVtbl.Release(sv);
                            _ = sv.lpVtbl.Append(sv, @ptrCast(item));
                        }
                    }
                }
            }
        }

        const start_hr = pub_ptr.lpVtbl.Start(pub_ptr);
        if (start_hr < 0) {
            log.warn("WinRT BluetoothLEAdvertisementPublisher.Start failed with HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(start_hr))});
            return error.AdvertisementRegistrationFailed;
        }

        self.win_publisher = pub_ptr;
        self.is_registered = true;
    }

    fn registerLinux(self: *Advertisement) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        const conn = self.conn orelse return error.AdvertisementRegistrationFailed;

        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.LEAdvertisingManager1.interface_name,
            BlueZ.LEAdvertisingManager1.Methods.RegisterAdvertisement,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendObjectPath(self.getObjectPath());

        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        const reg_serial = try conn.sendWithSerial(&msg);

        const PredicateContext = struct {
            reg_serial: u32,
            adv_path: [:0]const u8,
            fn isMatch(ctx: @This(), incoming: *const Message) bool {
                const msg_type = incoming.getMessageType();
                if (msg_type == 1) {
                    if (incoming.getPath()) |p| {
                        return std.mem.eql(u8, p, ctx.adv_path);
                    }
                    return false;
                } else if (msg_type == 2 or msg_type == 3) {
                    return incoming.getReplySerial() == ctx.reg_serial;
                }
                return false;
            }
        };
        const ctx = PredicateContext{ .reg_serial = reg_serial, .adv_path = self.object_path[0..self.object_path_len :0] };

        var iters: usize = 0;
        while (iters < 50) : (iters += 1) {
            while (conn.popMatching(ctx, PredicateContext.isMatch)) |incoming| {
                var inc = incoming;
                defer inc.deinit();
                const msg_type = inc.getMessageType();
                if (msg_type == 1) {
                    _ = try self.processMessage(&inc);
                } else if (msg_type == 2) {
                    if (inc.getReplySerial() == reg_serial) {
                        self.is_registered = true;
                        return;
                    }
                } else if (msg_type == 3) {
                    if (inc.getReplySerial() == reg_serial) {
                        return error.AdvertisementRegistrationFailed;
                    }
                }
            }
            _ = conn.pollSocket(100);
        }

        return error.Timeout;
    }

    /// Stops the active advertisement.
    pub fn unregister(self: *Advertisement) !void {
        if (builtin.os.tag == .linux) {
            if (!self.is_registered) return;
            const conn = self.conn orelse return;

            var msg = try Connection.createMethodCall(
                BlueZ.service_name,
                self.getAdapterPath(),
                BlueZ.LEAdvertisingManager1.interface_name,
                BlueZ.LEAdvertisingManager1.Methods.UnregisterAdvertisement,
            );
            defer msg.deinit();

            var b = msg.builder();
            try b.appendObjectPath(self.getObjectPath());

            var reply = try conn.sendMessage(&msg, 5000);
            reply.deinit();

            self.is_registered = false;
        } else if (builtin.os.tag == .windows) {
            if (self.win_publisher) |pub_ptr| {
                if (self.is_registered) {
                    _ = pub_ptr.lpVtbl.Stop(pub_ptr);
                }
                _ = pub_ptr.lpVtbl.Release(pub_ptr);
                self.win_publisher = null;
            }
            self.is_registered = false;
        } else {
            return error.NotSupported;
        }
    }

    /// Handles incoming D-Bus messages addressed to this advertisement object (e.g. GetAll, Release).
    /// Returns true if the message was destined for this object.
    pub fn processMessage(self: *Advertisement, msg: *const Message) !bool {
        if (builtin.os.tag != .linux) return false;
        const conn = self.conn orelse return false;

        const target_path = msg.getPath() orelse return false;
        if (!std.mem.eql(u8, target_path, self.getObjectPath())) return false;

        const member = msg.getMember() orelse return false;
        const iface = msg.getInterface() orelse "";
        if (std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and std.mem.eql(u8, member, BlueZ.ObjectManager.Methods.GetManagedObjects)) {
            var reply = try Connection.createErrorReply(msg, "org.freedesktop.DBus.Error.UnknownMethod", "Not an ObjectManager");
            defer reply.deinit();
            try conn.send(&reply);
            return true;
        } else if (std.mem.eql(u8, iface, BlueZ.Properties.interface_name) and std.mem.eql(u8, member, BlueZ.Properties.Methods.GetAll)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();

            var b = reply.builder();
            var dict = try b.openArray("{sv}");

            try dict.appendDictString(BlueZ.LEAdvertisement1.Properties.Type, self.config.type.toSlice());

            if (self.config.type == .peripheral) {
                try dict.appendDictBool(BlueZ.LEAdvertisement1.Properties.Discoverable, self.config.discoverable);
            }

            if (self.config.local_name) |name| {
                try dict.appendDictString(BlueZ.LEAdvertisement1.Properties.LocalName, name);
            }

            var inc_count: usize = 0;
            var inc_bufs: [3][:0]const u8 = undefined;
            if (self.config.includes.tx_power) {
                inc_bufs[inc_count] = "tx-power";
                inc_count += 1;
            }
            if (self.config.includes.appearance) {
                inc_bufs[inc_count] = "appearance";
                inc_count += 1;
            }
            if (self.config.includes.local_name and self.config.local_name == null) {
                inc_bufs[inc_count] = "local-name";
                inc_count += 1;
            }
            if (inc_count > 0) {
                try dict.appendDictStringArray(BlueZ.LEAdvertisement1.Properties.Includes, inc_bufs[0..inc_count]);
            }

            if (self.config.service_uuids.len > 0) {
                var entry = try dict.openDictEntry();
                try entry.appendString(BlueZ.LEAdvertisement1.Properties.ServiceUUIDs);
                var v = try entry.openVariant("as");
                var arr = try v.openArray("s");
                for (self.config.service_uuids) |uuid| {
                    var u_buf: [36]u8 = undefined;
                    _ = uuid.formatBuf(&u_buf);
                    var null_term: [37]u8 = undefined;
                    @memcpy(null_term[0..36], &u_buf);
                    null_term[36] = 0;
                    try arr.appendString(null_term[0..36 :0]);
                }
                try v.closeContainer(&arr);
                try entry.closeContainer(&v);
                try dict.closeContainer(&entry);
            }

            if (self.config.appearance) |app| {
                try dict.appendDictUInt16(BlueZ.LEAdvertisement1.Properties.Appearance, app);
            }

            if (self.config.manufacturer_data) |mfg| {
                var entry = try dict.openDictEntry();
                try entry.appendString(BlueZ.LEAdvertisement1.Properties.ManufacturerData);
                var v = try entry.openVariant("a{qv}");
                var mfg_dict = try v.openArray("{qv}");
                {
                    var mfg_entry = try mfg_dict.openDictEntry();
                    try mfg_entry.appendUInt16(mfg.company_id);
                    var payload_var = try mfg_entry.openVariant("ay");
                    try payload_var.appendBytes(mfg.data);
                    try mfg_entry.closeContainer(&payload_var);
                    try mfg_dict.closeContainer(&mfg_entry);
                }
                try v.closeContainer(&mfg_dict);
                try entry.closeContainer(&v);
                try dict.closeContainer(&entry);
            }

            if (self.config.service_data) |sd| {
                var entry = try dict.openDictEntry();
                try entry.appendString(BlueZ.LEAdvertisement1.Properties.ServiceData);
                var v = try entry.openVariant("a{sv}");
                var sd_dict = try v.openArray("{sv}");
                {
                    var sd_entry = try sd_dict.openDictEntry();
                    var u_buf: [36]u8 = undefined;
                    _ = sd.uuid.formatBuf(&u_buf);
                    var null_term: [37]u8 = undefined;
                    @memcpy(null_term[0..36], &u_buf);
                    null_term[36] = 0;
                    try sd_entry.appendString(null_term[0..36 :0]);
                    var payload_var = try sd_entry.openVariant("ay");
                    try payload_var.appendBytes(sd.data);
                    try sd_entry.closeContainer(&payload_var);
                    try sd_dict.closeContainer(&sd_entry);
                }
                try v.closeContainer(&sd_dict);
                try entry.closeContainer(&v);
                try dict.closeContainer(&entry);
            }

            if (self.config.secondary_channel) |sec| {
                if (sec.toBluezString()) |sec_str| {
                    var entry = try dict.openDictEntry();
                    try entry.appendString("SecondaryChannel");
                    var v = try entry.openVariant("s");
                    try v.appendString(sec_str);
                    try entry.closeContainer(&v);
                    try dict.closeContainer(&entry);
                }
            }

            if (self.config.min_interval_ms) |min_ms| {
                try dict.appendDictUInt32("MinInterval", min_ms);
            }
            if (self.config.max_interval_ms) |max_ms| {
                try dict.appendDictUInt32("MaxInterval", max_ms);
            }

            if (self.config.tx_power) |pwr| {
                try dict.appendDictInt16("TxPower", pwr);
            }

            try b.closeContainer(&dict);
            try conn.send(&reply);
            return true;
        } else if (std.mem.eql(u8, member, BlueZ.LEAdvertisement1.Methods.Release)) {
            self.is_registered = false;
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try conn.send(&reply);
            return true;
        }

        return false;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Advertisement config defaults" {
    const cfg = AdvertisementConfig{
        .local_name = "Zig-BLE-Test",
    };
    try std.testing.expectEqual(AdvertisementType.peripheral, cfg.type);
    try std.testing.expectEqualStrings("peripheral", cfg.type.toSlice());
    try std.testing.expect(cfg.discoverable);
    try std.testing.expect(cfg.includes.tx_power);
    try std.testing.expect(cfg.includes.local_name);
}

test "Advertisement config with ServiceData" {
    const eddystone_url = [_]u8{ 0x10, 0x08, 0x03, 'z', 'i', 'g' };
    const cfg = AdvertisementConfig{
        .local_name = "Eddystone-Beacon",
        .service_data = .{
            .uuid = UUID.from16(0xFEAA),
            .data = &eddystone_url,
        },
    };
    try std.testing.expect(cfg.service_data != null);
    try std.testing.expect(cfg.service_data.?.uuid.eql(UUID.from16(0xFEAA)));
    try std.testing.expectEqualSlices(u8, &eddystone_url, cfg.service_data.?.data);
}
