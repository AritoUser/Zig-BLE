//! # GATT Server Domain Types & Data Models
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const UUID = core.UUID;
const constants = @import("../bluez/constants.zig");
const BlueZ = constants.BlueZ;

const wire = @import("../dbus/wire/mod.zig");
const dbus = if (builtin.os.tag == .linux) @import("../dbus/mod.zig") else struct {};
const win_bindings = if (builtin.os.tag == .windows) @import("../backend/windows/bindings.zig") else struct {};
const win_mod = if (builtin.os.tag == .windows) @import("../backend/windows/mod.zig") else struct {};

pub const Connection = if (builtin.os.tag == .linux) dbus.Connection else wire.NonLinuxConnection;
pub const Message = if (builtin.os.tag == .linux) dbus.Message else wire.Message;

pub const ServerDescriptorFlags = struct {
    read: bool = false,
    write: bool = false,
    encrypt_read: bool = false,
    encrypt_write: bool = false,
    encrypt_authenticated_read: bool = false,
    encrypt_authenticated_write: bool = false,
    secure_read: bool = false,
    secure_write: bool = false,
    authorize: bool = false,

    /// Serializes enabled descriptor permission flags into BlueZ D-Bus string slices.
    pub fn toBluezFlags(self: ServerDescriptorFlags, out_buf: *[9][:0]const u8) [][:0]const u8 {
        var count: usize = 0;
        if (self.read) {
            out_buf[count] = "read";
            count += 1;
        }
        if (self.write) {
            out_buf[count] = "write";
            count += 1;
        }
        if (self.encrypt_read) {
            out_buf[count] = "encrypt-read";
            count += 1;
        }
        if (self.encrypt_write) {
            out_buf[count] = "encrypt-write";
            count += 1;
        }
        if (self.encrypt_authenticated_read) {
            out_buf[count] = "encrypt-authenticated-read";
            count += 1;
        }
        if (self.encrypt_authenticated_write) {
            out_buf[count] = "encrypt-authenticated-write";
            count += 1;
        }
        if (self.secure_read) {
            out_buf[count] = "secure-read";
            count += 1;
        }
        if (self.secure_write) {
            out_buf[count] = "secure-write";
            count += 1;
        }
        if (self.authorize) {
            out_buf[count] = "authorize";
            count += 1;
        }
        return out_buf[0..count];
    }
};

pub const ServerDescriptor = struct {
    pub const ReadFn = *const fn (desc: *ServerDescriptor, user_data: ?*anyopaque) []const u8;
    pub const WriteFn = *const fn (desc: *ServerDescriptor, data: []const u8, user_data: ?*anyopaque) void;

    uuid: UUID = UUID.from16(0),
    object_path: [180]u8 = undefined,
    object_path_len: u8 = 0,
    char_path: [160]u8 = undefined,
    char_path_len: u8 = 0,
    flags: ServerDescriptorFlags = .{},

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
    encrypt_read: bool = false,
    encrypt_write: bool = false,
    encrypt_authenticated_read: bool = false,
    encrypt_authenticated_write: bool = false,
    secure_read: bool = false,
    secure_write: bool = false,
    authorize: bool = false,

    /// Serializes enabled characteristic flags & security permissions into BlueZ D-Bus string slices.
    pub fn toBluezFlags(self: ServerCharacteristicFlags, out_buf: *[12][:0]const u8) [][:0]const u8 {
        var count: usize = 0;
        if (self.read) {
            out_buf[count] = "read";
            count += 1;
        }
        if (self.write) {
            out_buf[count] = "write";
            count += 1;
        }
        if (self.write_without_response) {
            out_buf[count] = "write-without-response";
            count += 1;
        }
        if (self.notify) {
            out_buf[count] = "notify";
            count += 1;
        }
        if (self.indicate) {
            out_buf[count] = "indicate";
            count += 1;
        }
        if (self.encrypt_read) {
            out_buf[count] = "encrypt-read";
            count += 1;
        }
        if (self.encrypt_write) {
            out_buf[count] = "encrypt-write";
            count += 1;
        }
        if (self.encrypt_authenticated_read) {
            out_buf[count] = "encrypt-authenticated-read";
            count += 1;
        }
        if (self.encrypt_authenticated_write) {
            out_buf[count] = "encrypt-authenticated-write";
            count += 1;
        }
        if (self.secure_read) {
            out_buf[count] = "secure-read";
            count += 1;
        }
        if (self.secure_write) {
            out_buf[count] = "secure-write";
            count += 1;
        }
        if (self.authorize) {
            out_buf[count] = "authorize";
            count += 1;
        }
        return out_buf[0..count];
    }

    /// Computes the WinRT `GattCharacteristicProperties` bitmask for this flag set.
    pub fn toWinRtProperties(self: ServerCharacteristicFlags) u32 {
        var props: u32 = 0;
        if (self.read or self.encrypt_read or self.encrypt_authenticated_read or self.secure_read) {
            props |= 0x2; // Read
        }
        if (self.write_without_response) {
            props |= 0x4; // WriteWithoutResponse
        }
        if (self.write or self.encrypt_write or self.encrypt_authenticated_write or self.secure_write) {
            props |= 0x8; // Write
        }
        if (self.notify) {
            props |= 0x10; // Notify
        }
        if (self.indicate) {
            props |= 0x20; // Indicate
        }
        return props;
    }

    /// Maps read security flags to WinRT `GattProtectionLevel` (`0 = Plain`, `2 = EncryptionRequired`, `3 = EncryptionAndAuthenticationRequired`).
    pub fn toWinRtReadProtection(self: ServerCharacteristicFlags) i32 {
        if (self.secure_read or self.encrypt_authenticated_read) return 3;
        if (self.encrypt_read) return 2;
        return 0;
    }

    /// Maps write security flags to WinRT `GattProtectionLevel` (`0 = Plain`, `2 = EncryptionRequired`, `3 = EncryptionAndAuthenticationRequired`).
    pub fn toWinRtWriteProtection(self: ServerCharacteristicFlags) i32 {
        if (self.secure_write or self.encrypt_authenticated_write) return 3;
        if (self.encrypt_write) return 2;
        return 0;
    }
};

pub const ServerCharacteristic = struct {
    pub const ReadFn = *const fn (char: *ServerCharacteristic, user_data: ?*anyopaque) []const u8;
    pub const WriteFn = *const fn (char: *ServerCharacteristic, data: []const u8, user_data: ?*anyopaque) void;
    pub const NotifyStateFn = *const fn (char: *ServerCharacteristic, enabled: bool, user_data: ?*anyopaque) void;

    uuid: UUID = UUID.from16(0),
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,
    service_path: [160]u8 = undefined,
    service_path_len: u8 = 0,
    flags: ServerCharacteristicFlags = .{},

    value: [128]u8 = undefined,
    value_len: u8 = 0,
    is_notifying: bool = false,

    read_handler: ?ReadFn = null,
    write_handler: ?WriteFn = null,
    notify_handler: ?NotifyStateFn = null,
    user_data: ?*anyopaque = null,

    descriptors: [4]ServerDescriptor = undefined,
    desc_count: usize = 0,

    // Windows WinRT local characteristic state
    win_char: if (builtin.os.tag == .windows) ?*win_bindings.IGattLocalCharacteristic else void =
        if (builtin.os.tag == .windows) null else {},
    win_read_token: if (builtin.os.tag == .windows) win_bindings.EventRegistrationToken else void =
        if (builtin.os.tag == .windows) 0 else {},
    win_write_token: if (builtin.os.tag == .windows) win_bindings.EventRegistrationToken else void =
        if (builtin.os.tag == .windows) 0 else {},
    win_read_handler: if (builtin.os.tag == .windows) win_bindings.GattReadRequestedHandler else void =
        if (builtin.os.tag == .windows) undefined else {},
    win_write_handler: if (builtin.os.tag == .windows) win_bindings.GattWriteRequestedHandler else void =
        if (builtin.os.tag == .windows) undefined else {},

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

    /// Updates the characteristic value and transmits an ATT Handle Value Notification/Indication to subscribed clients.
    pub fn notify(self: *ServerCharacteristic, conn: *Connection, data: []const u8) !void {
        self.setValue(data);
        if (builtin.os.tag == .linux) {
            if (!self.is_notifying) return;

            var sig = try Connection.createSignal(
                self.getObjectPath(),
                BlueZ.Properties.interface_name,
                BlueZ.Properties.Signals.PropertiesChanged,
            );
            defer sig.deinit();

            var b = sig.builder();
            try b.appendString(BlueZ.GattCharacteristic1.interface_name);

            var changed = try b.openArray("{sv}");
            try changed.appendDictBytes(BlueZ.GattCharacteristic1.Properties.Value, self.getValue());
            try b.closeContainer(&changed);

            var invalidated = try b.openArray("as");
            try b.closeContainer(&invalidated);

            try conn.send(&sig);
        } else if (builtin.os.tag == .windows) {
            if (self.win_char) |wc| {
                const ibuf = try win_mod.createIBuffer(self.getValue());
                defer _ = ibuf.lpVtbl.Release(ibuf);

                var notify_op: ?*win_bindings.IAsyncOperationGeneric = null;
                if (wc.lpVtbl.NotifyValueAsync(wc, ibuf, &notify_op) >= 0 and notify_op != null) {
                    if (win_mod.awaitAsync(notify_op.?, 5000) catch null) |vec_raw| {
                        const vec_unk: *win_bindings.IUnknown = @ptrCast(@alignCast(vec_raw));
                        _ = vec_unk.release();
                    }
                }
            }
        } else {
            return error.NotSupported;
        }
    }

    /// Sets the characteristic value by serializing a strongly-typed value.
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

    pub fn releaseWindows(self: *ServerCharacteristic) void {
        if (builtin.os.tag == .windows) {
            self.win_read_handler.deactivate();
            self.win_write_handler.deactivate();
            if (self.win_char) |wc| {
                if (self.win_read_token != 0) {
                    _ = wc.lpVtbl.remove_ReadRequested(wc, self.win_read_token);
                    self.win_read_token = 0;
                }
                if (self.win_write_token != 0) {
                    _ = wc.lpVtbl.remove_WriteRequested(wc, self.win_write_token);
                    self.win_write_token = 0;
                }
                _ = wc.lpVtbl.Release(wc);
                self.win_char = null;
            }
        }
    }
};

pub const ServerService = struct {
    uuid: UUID = UUID.from16(0),
    primary: bool = true,
    object_path: [160]u8 = undefined,
    object_path_len: u8 = 0,

    characteristics: [8]ServerCharacteristic = undefined,
    char_count: usize = 0,

    win_provider: if (builtin.os.tag == .windows) ?*win_bindings.IGattServiceProvider else void =
        if (builtin.os.tag == .windows) null else {},

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
        ch.* = .{
            .uuid = uuid,
            .flags = flags,
        };

        const s_len = self.object_path_len;
        @memcpy(ch.service_path[0..s_len], self.object_path[0..s_len]);
        ch.service_path[s_len] = 0;
        ch.service_path_len = s_len;

        var path_buf: [160]u8 = undefined;
        const c_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/char{d}", .{ self.getObjectPath(), self.char_count }, 0) catch return error.BufferTooSmall;
        const c_len = @min(ch.object_path.len - 1, c_path.len);
        @memcpy(ch.object_path[0..c_len], c_path[0..c_len]);
        ch.object_path[c_len] = 0;
        ch.object_path_len = @intCast(c_len);

        self.char_count += 1;
        return ch;
    }

    pub fn releaseWindows(self: *ServerService) void {
        if (builtin.os.tag == .windows) {
            for (self.characteristics[0..self.char_count]) |*ch| {
                ch.releaseWindows();
            }
            if (self.win_provider) |prov| {
                _ = prov.lpVtbl.StopAdvertising(prov);
                _ = prov.lpVtbl.Release(prov);
                self.win_provider = null;
            }
        }
    }
};

