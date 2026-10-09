//! Zig-BLE GATT Server: Hosts local GATT services & characteristics
//! via BlueZ org.bluez.GattManager1.
//! 100% Zero dynamic heap allocations.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const UUID = core.UUID;
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const Message = if (builtin.os.tag == .linux) dbus.Message else struct {};
const DBusError = if (builtin.os.tag == .linux) dbus.DBusError else anyerror;

pub const ServerDescriptorFlags = struct {
    read: bool = false,
    write: bool = false,
};

pub const ServerDescriptor = struct {
    pub const ReadFn = *const fn (desc: *ServerDescriptor, user_data: ?*anyopaque) []const u8;
    pub const WriteFn = *const fn (desc: *ServerDescriptor, data: []const u8, user_data: ?*anyopaque) void;

    uuid: UUID,
    object_path: [180]u8 = undefined,
    object_path_len: u8 = 0,
    char_path: [160]u8 = undefined,
    char_path_len: u8 = 0,
    flags: ServerDescriptorFlags,

    value: [128]u8 = undefined,
    value_len: u8 = 0,

    read_handler: ?ReadFn = null,
    write_handler: ?WriteFn = null,
    user_data: ?*anyopaque = null,

    pub fn getObjectPath(self: *const ServerDescriptor) [:0]const u8 {
        if (self.object_path_len == 0) return "";
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getCharacteristicPath(self: *const ServerDescriptor) [:0]const u8 {
        if (self.char_path_len == 0) return "";
        return self.char_path[0..self.char_path_len :0];
    }

    pub fn setValue(self: *ServerDescriptor, data: []const u8) void {
        const len = @min(self.value.len, data.len);
        @memcpy(self.value[0..len], data[0..len]);
        self.value_len = @intCast(len);
    }

    pub fn getValue(self: *const ServerDescriptor) []const u8 {
        return self.value[0..self.value_len];
    }

    /// Sets the descriptor value by serializing a strongly-typed value.
    pub fn setTyped(self: *ServerDescriptor, val: anytype) !void {
        var raw_buf: [128]u8 = undefined;
        const len = try core.format.serialize(val, &raw_buf);
        self.setValue(raw_buf[0..len]);
    }

    /// Gets the descriptor value deserialized into type `T`.
    pub fn getTyped(self: *const ServerDescriptor, comptime T: type) !T {
        return core.format.deserialize(T, self.getValue());
    }
};

pub const ServerCharacteristicFlags = struct {
    read: bool = false,
    write: bool = false,
    write_without_response: bool = false,
    notify: bool = false,
    indicate: bool = false,
};

pub const ServerCharacteristic = struct {
    pub const ReadFn = *const fn (char: *ServerCharacteristic, user_data: ?*anyopaque) []const u8;
    pub const WriteFn = *const fn (char: *ServerCharacteristic, data: []const u8, user_data: ?*anyopaque) void;
    pub const NotifyStateFn = *const fn (char: *ServerCharacteristic, enabled: bool, user_data: ?*anyopaque) void;

    uuid: UUID,
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,
    service_path: [160]u8 = undefined,
    service_path_len: u8 = 0,
    flags: ServerCharacteristicFlags,

    value: [128]u8 = undefined,
    value_len: u8 = 0,
    is_notifying: bool = false,

    read_handler: ?ReadFn = null,
    write_handler: ?WriteFn = null,
    notify_handler: ?NotifyStateFn = null,
    user_data: ?*anyopaque = null,

    descriptors: [4]ServerDescriptor = undefined,
    desc_count: usize = 0,

    pub fn getObjectPath(self: *const ServerCharacteristic) [:0]const u8 {
        if (self.object_path_len == 0) return "";
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn getServicePath(self: *const ServerCharacteristic) [:0]const u8 {
        if (self.service_path_len == 0) return "";
        return self.service_path[0..self.service_path_len :0];
    }

    pub fn setValue(self: *ServerCharacteristic, data: []const u8) void {
        const len = @min(self.value.len, data.len);
        @memcpy(self.value[0..len], data[0..len]);
        self.value_len = @intCast(len);
    }

    pub fn getValue(self: *const ServerCharacteristic) []const u8 {
        return self.value[0..self.value_len];
    }

    pub fn addDescriptor(
        self: *ServerCharacteristic,
        uuid: UUID,
        flags: ServerDescriptorFlags,
    ) !*ServerDescriptor {
        if (self.desc_count >= self.descriptors.len) return error.MaxDescriptorsReached;

        var d = &self.descriptors[self.desc_count];
        d.uuid = uuid;
        d.flags = flags;
        d.value_len = 0;
        d.read_handler = null;
        d.write_handler = null;
        d.user_data = null;

        const cp_len = self.object_path_len;
        @memcpy(d.char_path[0..cp_len], self.object_path[0..cp_len]);
        d.char_path[cp_len] = 0;
        d.char_path_len = cp_len;

        var path_buf: [180]u8 = undefined;
        const d_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/desc{d}", .{ self.getObjectPath(), self.desc_count }, 0) catch return error.BufferTooSmall;
        const d_len = @min(d.object_path.len - 1, d_path.len);
        @memcpy(d.object_path[0..d_len], d_path[0..d_len]);
        d.object_path[d_len] = 0;
        d.object_path_len = @intCast(d_len);

        self.desc_count += 1;
        return d;
    }

    /// Sets the standardized Bluetooth SIG 'Characteristic User Description' (UUID 0x2901).
    pub fn setUserDescription(self: *ServerCharacteristic, description: []const u8) !*ServerDescriptor {
        const d = try self.addDescriptor(UUID.from16(0x2901), .{ .read = true });
        d.setValue(description);
        return d;
    }

    /// Updates the characteristic value and, if a client subscribed to notifications,
    /// sends a D-Bus PropertiesChanged signal that BlueZ transmits over the air as an ATT Handle Value Notification.
    pub fn notify(self: *ServerCharacteristic, conn: *Connection, data: []const u8) !void {
        self.setValue(data);
        if (!self.is_notifying) return;
        if (builtin.os.tag != .linux) return;

        var sig = try Connection.createSignal(
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Signals.PropertiesChanged,
        );
        defer sig.deinit();

        var b = sig.builder();
        try b.appendString(BlueZ.GattCharacteristic1.interface_name);

        // changed_properties a{sv}
        var changed = try b.openArray("{sv}");
        try changed.appendDictBytes(BlueZ.GattCharacteristic1.Properties.Value, self.getValue());
        try b.closeContainer(&changed);

        // invalidated_properties as
        var invalidated = try b.openArray("as");
        try b.closeContainer(&invalidated);

        try conn.send(&sig);
    }

    /// Sets the characteristic value by serializing a strongly-typed value
    /// (e.g. integer, float, bool, Sfloat, Float32, enum, packed/extern struct).
    pub fn setTyped(self: *ServerCharacteristic, val: anytype) !void {
        var raw_buf: [128]u8 = undefined;
        const len = try core.format.serialize(val, &raw_buf);
        self.setValue(raw_buf[0..len]);
    }

    /// Gets the characteristic value deserialized into type `T`.
    pub fn getTyped(self: *const ServerCharacteristic, comptime T: type) !T {
        return core.format.deserialize(T, self.getValue());
    }

    /// Serializes `val` into bytes and, if a client is subscribed, notifies the client over the air.
    pub fn notifyTyped(self: *ServerCharacteristic, conn: *Connection, val: anytype) !void {
        var raw_buf: [128]u8 = undefined;
        const len = try core.format.serialize(val, &raw_buf);
        try self.notify(conn, raw_buf[0..len]);
    }

    /// Attaches a standardized Bluetooth SIG 'Characteristic Presentation Format' descriptor (UUID 0x2904).
    pub fn setPresentationFormat(self: *ServerCharacteristic, format_desc: core.CharacteristicPresentationFormat) !*ServerDescriptor {
        const d = try self.addDescriptor(core.assigned_numbers.Descriptors.characteristic_presentation_format, .{ .read = true });
        const enc = format_desc.encode();
        d.setValue(&enc);
        return d;
    }
};

pub const ServerService = struct {
    uuid: UUID,
    primary: bool = true,
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,

    characteristics: [8]ServerCharacteristic = undefined,
    char_count: usize = 0,

    pub fn getObjectPath(self: *const ServerService) [:0]const u8 {
        if (self.object_path_len == 0) return "";
        return self.object_path[0..self.object_path_len :0];
    }

    pub fn addCharacteristic(
        self: *ServerService,
        uuid: UUID,
        flags: ServerCharacteristicFlags,
    ) !*ServerCharacteristic {
        if (self.char_count >= self.characteristics.len) return error.MaxCharacteristicsReached;

        var ch = &self.characteristics[self.char_count];
        ch.uuid = uuid;
        ch.flags = flags;
        ch.value_len = 0;
        ch.is_notifying = false;
        ch.read_handler = null;
        ch.write_handler = null;
        ch.notify_handler = null;
        ch.user_data = null;
        ch.desc_count = 0;

        // Copy service path
        const s_len = self.object_path_len;
        @memcpy(ch.service_path[0..s_len], self.object_path[0..s_len]);
        ch.service_path[s_len] = 0;
        ch.service_path_len = s_len;

        // Generate characteristic path: <service_path>/char<idx>
        var path_buf: [160]u8 = undefined;
        const c_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/char{d}", .{ self.getObjectPath(), self.char_count }, 0) catch return error.BufferTooSmall;
        const c_len = @min(ch.object_path.len - 1, c_path.len);
        @memcpy(ch.object_path[0..c_len], c_path[0..c_len]);
        ch.object_path[c_len] = 0;
        ch.object_path_len = @intCast(c_len);

        self.char_count += 1;
        return ch;
    }
};

pub const GattApplication = struct {
    conn: *Connection,
    app_path: [128]u8 = undefined,
    app_path_len: u8 = 0,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,

    services: [4]ServerService = undefined,
    service_count: usize = 0,
    is_registered: bool = false,

    pub fn init(
        conn: *Connection,
        adapter_path: [:0]const u8,
        app_path: [:0]const u8,
    ) GattApplication {
        var app = GattApplication{
            .conn = conn,
        };

        const ap_len = @min(app.app_path.len - 1, app_path.len);
        @memcpy(app.app_path[0..ap_len], app_path[0..ap_len]);
        app.app_path[ap_len] = 0;
        app.app_path_len = @intCast(ap_len);

        const ad_len = @min(app.adapter_path.len - 1, adapter_path.len);
        @memcpy(app.adapter_path[0..ad_len], adapter_path[0..ad_len]);
        app.adapter_path[ad_len] = 0;
        app.adapter_path_len = @intCast(ad_len);

        return app;
    }

    pub fn getAppPath(self: *const GattApplication) [:0]const u8 {
        return self.app_path[0..self.app_path_len :0];
    }

    pub fn getAdapterPath(self: *const GattApplication) [:0]const u8 {
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    pub fn createService(self: *GattApplication, uuid: UUID, primary: bool) !*ServerService {
        if (self.service_count >= self.services.len) return error.MaxServicesReached;

        var s = &self.services[self.service_count];
        s.uuid = uuid;
        s.primary = primary;
        s.char_count = 0;

        var path_buf: [160]u8 = undefined;
        const s_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/service{d}", .{ self.getAppPath(), self.service_count }, 0) catch return error.BufferTooSmall;
        const s_len = @min(s.object_path.len - 1, s_path.len);
        @memcpy(s.object_path[0..s_len], s_path[0..s_len]);
        s.object_path[s_len] = 0;
        s.object_path_len = @intCast(s_len);

        self.service_count += 1;
        return s;
    }

    /// Registers the GATT server application with BlueZ GattManager1.
    pub fn register(self: *GattApplication) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;

        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.GattManager1.interface_name,
            BlueZ.GattManager1.Methods.RegisterApplication,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendObjectPath(self.getAppPath());

        // Empty options dictionary a{sv}
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        const reg_serial = try self.conn.sendWithSerial(&msg);

        const PredicateContext = struct {
            reg_serial: u32,
            app_path: [:0]const u8,
            fn isMatch(ctx: @This(), incoming: *const Message) bool {
                const msg_type = incoming.getMessageType();
                if (msg_type == 1) { // DBUS_MESSAGE_TYPE_METHOD_CALL
                    if (incoming.getPath()) |p| {
                        return std.mem.startsWith(u8, p, ctx.app_path);
                    }
                    return false;
                } else if (msg_type == 2 or msg_type == 3) { // METHOD_RETURN or ERROR
                    return incoming.getReplySerial() == ctx.reg_serial;
                }
                return false;
            }
        };
        const ctx = PredicateContext{ .reg_serial = reg_serial, .app_path = self.getAppPath() };

        // Event loop to respond to BlueZ's GetManagedObjects callback
        var iters: usize = 0;
        while (iters < 50) : (iters += 1) {
            while (self.conn.popMatching(ctx, PredicateContext.isMatch)) |incoming| {
                var inc = incoming;
                defer inc.deinit();
                const msg_type = inc.getMessageType();

                if (msg_type == 1) { // DBUS_MESSAGE_TYPE_METHOD_CALL
                    _ = try self.processMessage(&inc);
                } else if (msg_type == 2) { // DBUS_MESSAGE_TYPE_METHOD_RETURN
                    if (inc.getReplySerial() == reg_serial) {
                        self.is_registered = true;
                        return;
                    }
                } else if (msg_type == 3) { // DBUS_MESSAGE_TYPE_ERROR
                    if (inc.getReplySerial() == reg_serial) {
                        if (inc.getErrorName()) |en| {
                            std.debug.print("RegisterApplication failed with D-Bus error: {s}\n", .{en});
                        }
                        return error.GattApplicationRegistrationFailed;
                    }
                }
            }
            _ = self.conn.pollSocket(100);
        }

        return error.Timeout;
    }

    /// Unregisters the GATT application from BlueZ.
    pub fn unregister(self: *GattApplication) !void {
        if (builtin.os.tag != .linux) return;
        if (!self.is_registered) return;

        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.GattManager1.interface_name,
            BlueZ.GattManager1.Methods.UnregisterApplication,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendObjectPath(self.getAppPath());

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();

        self.is_registered = false;
    }

    /// Handles incoming D-Bus method calls (GetManagedObjects, ReadValue, WriteValue, StartNotify, StopNotify).
    pub fn processMessage(self: *GattApplication, msg: *const Message) !bool {
        if (builtin.os.tag != .linux) return false;

        const target_path = msg.getPath() orelse return false;
        const member = msg.getMember() orelse return false;
        const iface = msg.getInterface() orelse "";

        // 1. GetManagedObjects on the application root path
        if (std.mem.eql(u8, target_path, self.getAppPath()) and
            std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and
            std.mem.eql(u8, member, BlueZ.ObjectManager.Methods.GetManagedObjects))
        {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();

            var b = reply.builder();
            // a{oa{sa{sv}}}
            var root_dict = try b.openArray("{oa{sa{sv}}}");

            // Serialize all services
            for (self.services[0..self.service_count]) |*s| {
                var s_entry = try root_dict.openDictEntry();
                try s_entry.appendObjectPath(s.getObjectPath());

                var ifaces_dict = try s_entry.openArray("{sa{sv}}");
                {
                    var iface_entry = try ifaces_dict.openDictEntry();
                    try iface_entry.appendString(BlueZ.GattService1.interface_name);

                    var props_dict = try iface_entry.openArray("{sv}");
                    {
                        var u_buf: [36]u8 = undefined;
                        _ = s.uuid.formatBuf(&u_buf);
                        var null_term: [37]u8 = undefined;
                        @memcpy(null_term[0..36], &u_buf);
                        null_term[36] = 0;
                        try props_dict.appendDictString(BlueZ.GattService1.Properties.UUID, null_term[0..36 :0]);
                        try props_dict.appendDictBool(BlueZ.GattService1.Properties.Primary, s.primary);
                    }
                    try iface_entry.closeContainer(&props_dict);
                    try ifaces_dict.closeContainer(&iface_entry);
                }
                try s_entry.closeContainer(&ifaces_dict);
                try root_dict.closeContainer(&s_entry);

                // Serialize all characteristics of this service
                for (s.characteristics[0..s.char_count]) |*c| {
                    var c_entry = try root_dict.openDictEntry();
                    try c_entry.appendObjectPath(c.getObjectPath());

                    var c_ifaces_dict = try c_entry.openArray("{sa{sv}}");
                    {
                        var c_iface_entry = try c_ifaces_dict.openDictEntry();
                        try c_iface_entry.appendString(BlueZ.GattCharacteristic1.interface_name);

                        var c_props_dict = try c_iface_entry.openArray("{sv}");
                        {
                            var u_buf: [36]u8 = undefined;
                            _ = c.uuid.formatBuf(&u_buf);
                            var null_term: [37]u8 = undefined;
                            @memcpy(null_term[0..36], &u_buf);
                            null_term[36] = 0;
                            try c_props_dict.appendDictString(BlueZ.GattCharacteristic1.Properties.UUID, null_term[0..36 :0]);
                            try c_props_dict.appendDictObjectPath(BlueZ.GattCharacteristic1.Properties.Service, c.getServicePath());

                            // Flags
                            var flag_bufs: [5][:0]const u8 = undefined;
                            var f_count: usize = 0;
                            if (c.flags.read) {
                                flag_bufs[f_count] = "read";
                                f_count += 1;
                            }
                            if (c.flags.write) {
                                flag_bufs[f_count] = "write";
                                f_count += 1;
                            }
                            if (c.flags.write_without_response) {
                                flag_bufs[f_count] = "write-without-response";
                                f_count += 1;
                            }
                            if (c.flags.notify) {
                                flag_bufs[f_count] = "notify";
                                f_count += 1;
                            }
                            if (c.flags.indicate) {
                                flag_bufs[f_count] = "indicate";
                                f_count += 1;
                            }
                            if (f_count > 0) {
                                try c_props_dict.appendDictStringArray(BlueZ.GattCharacteristic1.Properties.Flags, flag_bufs[0..f_count]);
                            }

                            // Initial value
                            if (c.value_len > 0) {
                                try c_props_dict.appendDictBytes(BlueZ.GattCharacteristic1.Properties.Value, c.getValue());
                            }
                        }
                        try c_iface_entry.closeContainer(&c_props_dict);
                        try c_ifaces_dict.closeContainer(&c_iface_entry);
                    }
                    try c_entry.closeContainer(&c_ifaces_dict);
                    try root_dict.closeContainer(&c_entry);

                    // Serialize all descriptors of this characteristic
                    for (c.descriptors[0..c.desc_count]) |*d| {
                        var d_entry = try root_dict.openDictEntry();
                        try d_entry.appendObjectPath(d.getObjectPath());

                        var d_ifaces_dict = try d_entry.openArray("{sa{sv}}");
                        {
                            var d_iface_entry = try d_ifaces_dict.openDictEntry();
                            try d_iface_entry.appendString(BlueZ.GattDescriptor1.interface_name);

                            var d_props_dict = try d_iface_entry.openArray("{sv}");
                            {
                                var du_buf: [36]u8 = undefined;
                                _ = d.uuid.formatBuf(&du_buf);
                                var d_null_term: [37]u8 = undefined;
                                @memcpy(d_null_term[0..36], &du_buf);
                                d_null_term[36] = 0;
                                try d_props_dict.appendDictString(BlueZ.GattDescriptor1.Properties.UUID, d_null_term[0..36 :0]);
                                try d_props_dict.appendDictObjectPath(BlueZ.GattDescriptor1.Properties.Characteristic, d.getCharacteristicPath());

                                // Flags
                                var df_bufs: [2][:0]const u8 = undefined;
                                var df_count: usize = 0;
                                if (d.flags.read) {
                                    df_bufs[df_count] = "read";
                                    df_count += 1;
                                }
                                if (d.flags.write) {
                                    df_bufs[df_count] = "write";
                                    df_count += 1;
                                }
                                if (df_count > 0) {
                                    try d_props_dict.appendDictStringArray(BlueZ.GattDescriptor1.Properties.Flags, df_bufs[0..df_count]);
                                }

                                // Value
                                if (d.value_len > 0) {
                                    try d_props_dict.appendDictBytes(BlueZ.GattDescriptor1.Properties.Value, d.getValue());
                                }
                            }
                            try d_iface_entry.closeContainer(&d_props_dict);
                            try d_ifaces_dict.closeContainer(&d_iface_entry);
                        }
                        try d_entry.closeContainer(&d_ifaces_dict);
                        try root_dict.closeContainer(&d_entry);
                    }
                }
            }

            try b.closeContainer(&root_dict);
            try self.conn.send(&reply);
            return true;
        }

        // 2. Invocations addressed to a specific characteristic
        for (self.services[0..self.service_count]) |*s| {
            for (s.characteristics[0..s.char_count]) |*c| {
                if (std.mem.eql(u8, target_path, c.getObjectPath())) {
                    if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.ReadValue)) {
                        const val = if (c.read_handler) |rf| rf(c, c.user_data) else c.getValue();
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        var b = reply.builder();
                        try b.appendBytes(val);
                        try self.conn.send(&reply);
                        return true;
                    } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.WriteValue)) {
                        var it = msg.iterator();
                        if (it.getFixedBytes()) |bytes| {
                            c.setValue(bytes);
                            if (c.write_handler) |wf| wf(c, bytes, c.user_data);
                        }
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        try self.conn.send(&reply);
                        return true;
                    } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.StartNotify)) {
                        c.is_notifying = true;
                        if (c.notify_handler) |nf| nf(c, true, c.user_data);
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        try self.conn.send(&reply);
                        return true;
                    } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.StopNotify)) {
                        c.is_notifying = false;
                        if (c.notify_handler) |nf| nf(c, false, c.user_data);
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        try self.conn.send(&reply);
                        return true;
                    }
                }
            }
        }

        // 3. Invocations addressed to a specific descriptor
        for (self.services[0..self.service_count]) |*s| {
            for (s.characteristics[0..s.char_count]) |*c| {
                for (c.descriptors[0..c.desc_count]) |*d| {
                    if (std.mem.eql(u8, target_path, d.getObjectPath())) {
                        if (std.mem.eql(u8, member, BlueZ.GattDescriptor1.Methods.ReadValue)) {
                            const val = if (d.read_handler) |rf| rf(d, d.user_data) else d.getValue();
                            var reply = try Connection.createMethodReturn(msg);
                            defer reply.deinit();
                            var b = reply.builder();
                            try b.appendBytes(val);
                            try self.conn.send(&reply);
                            return true;
                        } else if (std.mem.eql(u8, member, BlueZ.GattDescriptor1.Methods.WriteValue)) {
                            var it = msg.iterator();
                            if (it.getFixedBytes()) |bytes| {
                                d.setValue(bytes);
                                if (d.write_handler) |wf| wf(d, bytes, d.user_data);
                            }
                            var reply = try Connection.createMethodReturn(msg);
                            defer reply.deinit();
                            try self.conn.send(&reply);
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "ServerCharacteristic: initialization and value update" {
    var char = ServerCharacteristic{
        .uuid = UUID.from16(0x2A37),
        .flags = .{ .read = true, .notify = true },
    };
    try std.testing.expectEqual(@as(u8, 0), char.value_len);

    char.setValue(&[_]u8{ 0x00, 0x48 }); // 72 bpm
    try std.testing.expectEqual(@as(u8, 2), char.value_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x48 }, char.getValue());
}

test "ServerService: add characteristics within limit" {
    var s = ServerService{
        .uuid = UUID.from16(0x180D),
        .primary = true,
    };
    const c1 = try s.addCharacteristic(UUID.from16(0x2A37), .{ .notify = true });
    try std.testing.expect(c1.flags.notify);
    try std.testing.expectEqual(@as(usize, 1), s.char_count);

    const c2 = try s.addCharacteristic(UUID.from16(0x2A38), .{ .read = true });
    try std.testing.expect(c2.flags.read);
    try std.testing.expectEqual(@as(usize, 2), s.char_count);
}

test "ServerCharacteristic: add descriptor and set user description" {
    var s = ServerService{
        .uuid = UUID.from16(0x180D),
        .primary = true,
    };
    const s_path = "/org/zig_ble/app0/service0";
    @memcpy(s.object_path[0..s_path.len], s_path);
    s.object_path[s_path.len] = 0;
    s.object_path_len = s_path.len;

    const c = try s.addCharacteristic(UUID.from16(0x2A37), .{ .notify = true });

    const desc = try c.setUserDescription("Heart Rate Monitor");
    try std.testing.expectEqual(@as(usize, 1), c.desc_count);
    try std.testing.expectEqualStrings("Heart Rate Monitor", desc.getValue());
    try std.testing.expect(desc.flags.read);
    try std.testing.expect(desc.uuid.eql(UUID.from16(0x2901)));
    try std.testing.expectEqualStrings("/org/zig_ble/app0/service0/char0/desc0", desc.getObjectPath());
}

test "ServerCharacteristic: setTyped and getTyped with Sfloat" {
    var char = ServerCharacteristic{
        .uuid = UUID.from16(0x2A1C), // Temperature Measurement
        .flags = .{ .read = true },
    };
    const s = core.Sfloat.fromF32(36.8);
    try char.setTyped(s);

    const retrieved = try char.getTyped(core.Sfloat);
    try std.testing.expectEqual(s.raw, retrieved.raw);
    try std.testing.expectApproxEqAbs(@as(f32, 36.8), try retrieved.toF32(), 0.01);
}

test "ServerCharacteristic: setPresentationFormat" {
    var s = ServerService{
        .uuid = UUID.from16(0x1809), // Health Thermometer
        .primary = true,
    };
    const s_path = "/org/zig_ble/app0/service0";
    @memcpy(s.object_path[0..s_path.len], s_path);
    s.object_path[s_path.len] = 0;
    s.object_path_len = s_path.len;

    const c = try s.addCharacteristic(UUID.from16(0x2A1C), .{ .read = true });
    const cpf_desc = try c.setPresentationFormat(.{
        .format = .sfloat,
        .exponent = 0,
        .unit = core.Units.celsius,
    });

    try std.testing.expectEqual(@as(usize, 1), c.desc_count);
    try std.testing.expect(cpf_desc.uuid.eql(UUID.from16(0x2904)));
    const decoded_cpf = try cpf_desc.getTyped(core.CharacteristicPresentationFormat);
    try std.testing.expectEqual(core.FormatType.sfloat, decoded_cpf.format);
    try std.testing.expectEqual(core.Units.celsius, decoded_cpf.unit);
}
