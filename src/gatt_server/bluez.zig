//! # BlueZ D-Bus GATT Server Manager & Message Dispatcher
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const constants = @import("../bluez/constants.zig");
const types_mod = @import("types.zig");

const BlueZ = constants.BlueZ;
const Connection = types_mod.Connection;
const Message = types_mod.Message;
const UUID = core.UUID;

const log = std.log.scoped(.zig_ble);

fn appendUuidProp(dict: anytype, prop_name: [:0]const u8, uuid: UUID) !void {
    var u_buf: [36]u8 = undefined;
    _ = uuid.formatBuf(&u_buf);
    var null_term: [37]u8 = undefined;
    @memcpy(null_term[0..36], &u_buf);
    null_term[36] = 0;
    try dict.appendDictString(prop_name, null_term[0..36 :0]);
}

pub fn registerLinux(app: anytype) !void {
    if (builtin.os.tag != .linux) return error.NotSupported;
    const conn = app.conn orelse return error.GattApplicationRegistrationFailed;

    var msg = try Connection.createMethodCall(
        BlueZ.service_name,
        app.getAdapterPath(),
        BlueZ.GattManager1.interface_name,
        BlueZ.GattManager1.Methods.RegisterApplication,
    );
    defer msg.deinit();

    var b = msg.builder();
    try b.appendObjectPath(app.getAppPath());

    var options = try b.openArray("{sv}");
    try b.closeContainer(&options);

    const reg_serial = try conn.sendWithSerial(&msg);

    const PredicateContext = struct {
        reg_serial: u32,
        app_path: [:0]const u8,
        fn isMatch(ctx: @This(), incoming: *const Message) bool {
            const msg_type = incoming.getMessageType();
            if (msg_type == 1) {
                if (incoming.getPath()) |p| {
                    return std.mem.startsWith(u8, p, ctx.app_path);
                }
                return false;
            } else if (msg_type == 2 or msg_type == 3) {
                return incoming.getReplySerial() == ctx.reg_serial;
            }
            return false;
        }
    };
    const ctx = PredicateContext{ .reg_serial = reg_serial, .app_path = app.getAppPath() };

    var iters: usize = 0;
    while (iters < 50) : (iters += 1) {
        while (conn.popMatching(ctx, PredicateContext.isMatch)) |incoming| {
            var inc = incoming;
            defer inc.deinit();
            const msg_type = inc.getMessageType();

            if (msg_type == 1) {
                _ = try processMessage(app, &inc);
            } else if (msg_type == 2) {
                if (inc.getReplySerial() == reg_serial) {
                    app.is_registered = true;
                    return;
                }
            } else if (msg_type == 3) {
                if (inc.getReplySerial() == reg_serial) {
                    if (inc.getErrorName()) |en| {
                        log.err("RegisterApplication failed with D-Bus error: {s}", .{en});
                    }
                    return error.GattApplicationRegistrationFailed;
                }
            }
        }
        _ = conn.pollSocket(100);
    }

    return error.Timeout;
}

pub fn unregisterLinux(app: anytype) !void {
    if (builtin.os.tag != .linux) return;
    if (!app.is_registered) return;
    const conn = app.conn orelse return;

    var msg = try Connection.createMethodCall(
        BlueZ.service_name,
        app.getAdapterPath(),
        BlueZ.GattManager1.interface_name,
        BlueZ.GattManager1.Methods.UnregisterApplication,
    );
    defer msg.deinit();

    var b = msg.builder();
    try b.appendObjectPath(app.getAppPath());

    var reply = try conn.sendMessage(&msg, 5000);
    reply.deinit();

    app.is_registered = false;
}

pub fn processMessage(app: anytype, msg: *const Message) !bool {
    if (builtin.os.tag != .linux) return false;
    const conn = app.conn orelse return false;

    const target_path = msg.getPath() orelse return false;
    const member = msg.getMember() orelse return false;
    const iface = msg.getInterface() orelse "";

    // 1. GetManagedObjects on the application root path
    if (std.mem.eql(u8, target_path, app.getAppPath()) and
        std.mem.eql(u8, iface, BlueZ.ObjectManager.interface_name) and
        std.mem.eql(u8, member, BlueZ.ObjectManager.Methods.GetManagedObjects))
    {
        var reply = try Connection.createMethodReturn(msg);
        defer reply.deinit();

        var b = reply.builder();
        var root_dict = try b.openArray("{oa{sa{sv}}}");

        for (app.services[0..app.service_count]) |*s| {
            var s_entry = try root_dict.openDictEntry();
            try s_entry.appendObjectPath(s.getObjectPath());

            var ifaces_dict = try s_entry.openArray("{sa{sv}}");
            {
                var iface_entry = try ifaces_dict.openDictEntry();
                try iface_entry.appendString(BlueZ.GattService1.interface_name);

                var props_dict = try iface_entry.openArray("{sv}");
                {
                    try appendUuidProp(&props_dict, BlueZ.GattService1.Properties.UUID, s.uuid);
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
                        try appendUuidProp(&c_props_dict, BlueZ.GattCharacteristic1.Properties.UUID, c.uuid);
                        try c_props_dict.appendDictObjectPath(BlueZ.GattCharacteristic1.Properties.Service, c.getServicePath());

                        var flag_bufs: [12][:0]const u8 = undefined;
                        const flags_slice = c.flags.toBluezFlags(&flag_bufs);
                        if (flags_slice.len > 0) {
                            try c_props_dict.appendDictStringArray(BlueZ.GattCharacteristic1.Properties.Flags, flags_slice);
                        }

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
                            try appendUuidProp(&d_props_dict, BlueZ.GattDescriptor1.Properties.UUID, d.uuid);
                            try d_props_dict.appendDictObjectPath(BlueZ.GattDescriptor1.Properties.Characteristic, d.getCharacteristicPath());

                            var df_bufs: [9][:0]const u8 = undefined;
                            const dflags_slice = d.flags.toBluezFlags(&df_bufs);
                            if (dflags_slice.len > 0) {
                                try d_props_dict.appendDictStringArray(BlueZ.GattDescriptor1.Properties.Flags, dflags_slice);
                            }

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
        try conn.send(&reply);
        return true;
    }

    // 2. Invocations addressed to a specific characteristic
    for (app.services[0..app.service_count]) |*s| {
        for (s.characteristics[0..s.char_count]) |*c| {
            if (std.mem.eql(u8, target_path, c.getObjectPath())) {
                if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.ReadValue)) {
                    const val = if (c.read_handler) |rf| rf(c, c.user_data) else c.getValue();
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    var b = reply.builder();
                    try b.appendBytes(val);
                    try conn.send(&reply);
                    return true;
                } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.WriteValue)) {
                    var it = msg.iterator();
                    if (it.getFixedBytes()) |bytes| {
                        c.setValue(bytes);
                        if (c.write_handler) |wf| wf(c, bytes, c.user_data);
                    }
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    try conn.send(&reply);
                    return true;
                } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.StartNotify)) {
                    c.is_notifying = true;
                    if (c.notify_handler) |nf| nf(c, true, c.user_data);
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    try conn.send(&reply);
                    return true;
                } else if (std.mem.eql(u8, member, BlueZ.GattCharacteristic1.Methods.StopNotify)) {
                    c.is_notifying = false;
                    if (c.notify_handler) |nf| nf(c, false, c.user_data);
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    try conn.send(&reply);
                    return true;
                }
            }
        }
    }

    // 3. Invocations addressed to a specific descriptor
    for (app.services[0..app.service_count]) |*s| {
        for (s.characteristics[0..s.char_count]) |*c| {
            for (c.descriptors[0..c.desc_count]) |*d| {
                if (std.mem.eql(u8, target_path, d.getObjectPath())) {
                    if (std.mem.eql(u8, member, BlueZ.GattDescriptor1.Methods.ReadValue)) {
                        const val = if (d.read_handler) |rf| rf(d, d.user_data) else d.getValue();
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        var b = reply.builder();
                        try b.appendBytes(val);
                        try conn.send(&reply);
                        return true;
                    } else if (std.mem.eql(u8, member, BlueZ.GattDescriptor1.Methods.WriteValue)) {
                        var it = msg.iterator();
                        if (it.getFixedBytes()) |bytes| {
                            d.setValue(bytes);
                            if (d.write_handler) |wf| wf(d, bytes, d.user_data);
                        }
                        var reply = try Connection.createMethodReturn(msg);
                        defer reply.deinit();
                        try conn.send(&reply);
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

