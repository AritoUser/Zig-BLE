//! Zig-BLE GATT Server: Hosts local GATT services & characteristics
//! via BlueZ `org.bluez.GattManager1` on Linux and WinRT `GattServiceProvider` on Windows.
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

    /// Updates the characteristic value and transmits an ATT Handle Value Notification/Indication to subscribed clients:
    /// - Linux: Emits D-Bus `PropertiesChanged` signal on `org.bluez.GattCharacteristic1`.
    /// - Windows: Invokes `IGattLocalCharacteristic.NotifyValueAsync(IBuffer)`.
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

    fn releaseWindows(self: *ServerCharacteristic) void {
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

    fn releaseWindows(self: *ServerService) void {
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

pub const GattApplication = struct {
    conn: ?*Connection = null,
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
        s.* = .{
            .uuid = uuid,
            .primary = primary,
            .char_count = 0,
        };

        var path_buf: [160]u8 = undefined;
        const s_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/service{d}", .{ self.getAppPath(), self.service_count }, 0) catch return error.BufferTooSmall;
        const s_len = @min(s.object_path.len - 1, s_path.len);
        @memcpy(s.object_path[0..s_len], s_path[0..s_len]);
        s.object_path[s_len] = 0;
        s.object_path_len = @intCast(s_len);

        self.service_count += 1;
        return s;
    }

    pub fn addService(self: *GattApplication, service: *ServerService) !void {
        if (self.service_count >= self.services.len) return error.MaxServicesReached;
        self.services[self.service_count] = service.*;
        self.service_count += 1;
    }

    /// Registers the GATT server application with the OS Bluetooth stack:
    /// - Linux: BlueZ `org.bluez.GattManager1.RegisterApplication`
    /// - Windows: WinRT `GattServiceProvider.CreateAsync` + `IGattLocalService.CreateCharacteristicAsync`
    pub fn register(self: *GattApplication) !void {
        if (builtin.os.tag == .linux) {
            return self.registerLinux();
        } else if (builtin.os.tag == .windows) {
            return self.registerWindows();
        } else {
            return error.NotSupported;
        }
    }

    fn onWinRtReadRequested(char_ctx: *anyopaque, args: *win_bindings.IGattReadRequestedEventArgs) callconv(.c) void {
        if (builtin.os.tag != .windows) return;
        const ch: *ServerCharacteristic = @ptrCast(@alignCast(char_ctx));

        var deferral: ?*win_bindings.IDeferral = null;
        _ = args.lpVtbl.GetDeferral(args, &deferral);
        defer if (deferral) |d| {
            _ = d.lpVtbl.Complete(d);
            _ = d.lpVtbl.Release(d);
        };

        var req_op: ?*win_bindings.IAsyncOperationGeneric = null;
        if (args.lpVtbl.GetRequestAsync(args, &req_op) < 0 or req_op == null) return;

        const req_raw = (win_mod.awaitAsync(req_op.?, 5000) catch null) orelse return;
        const req: *win_bindings.IGattReadRequest = @ptrCast(@alignCast(req_raw));
        defer _ = req.lpVtbl.Release(req);

        const val = if (ch.read_handler) |rf| rf(ch, ch.user_data) else ch.getValue();
        var offset: u32 = 0;
        _ = req.lpVtbl.get_Offset(req, &offset);
        const slice = if (offset < val.len) val[offset..] else &[_]u8{};

        if (win_mod.createIBuffer(slice)) |ibuf| {
            defer _ = ibuf.lpVtbl.Release(ibuf);
            _ = req.lpVtbl.RespondWithValue(req, ibuf);
        } else |_| {
            _ = req.lpVtbl.RespondWithProtocolError(req, 0x06); // Request Not Supported / Read Error
        }
    }

    fn onWinRtWriteRequested(char_ctx: *anyopaque, args: *win_bindings.IGattWriteRequestedEventArgs) callconv(.c) void {
        if (builtin.os.tag != .windows) return;
        const ch: *ServerCharacteristic = @ptrCast(@alignCast(char_ctx));

        var deferral: ?*win_bindings.IDeferral = null;
        _ = args.lpVtbl.GetDeferral(args, &deferral);
        defer if (deferral) |d| {
            _ = d.lpVtbl.Complete(d);
            _ = d.lpVtbl.Release(d);
        };

        var req_op: ?*win_bindings.IAsyncOperationGeneric = null;
        if (args.lpVtbl.GetRequestAsync(args, &req_op) < 0 or req_op == null) return;

        const req_raw = (win_mod.awaitAsync(req_op.?, 5000) catch null) orelse return;
        const req: *win_bindings.IGattWriteRequest = @ptrCast(@alignCast(req_raw));
        defer _ = req.lpVtbl.Release(req);

        var ibuf: ?*win_bindings.IBuffer = null;
        if (req.lpVtbl.get_Value(req, &ibuf) >= 0 and ibuf != null) {
            const b = ibuf.?;
            defer _ = b.lpVtbl.Release(b);

            var data_buf: [512]u8 = undefined;
            if (win_mod.readIBuffer(b, &data_buf)) |n| {
                ch.setValue(data_buf[0..n]);
                if (ch.write_handler) |wf| {
                    wf(ch, data_buf[0..n], ch.user_data);
                }
            } else |_| {}
        }

        var opt: win_bindings.GattWriteOption = .WriteWithResponse;
        _ = req.lpVtbl.get_Option(req, &opt);
        if (opt == .WriteWithResponse) {
            _ = req.lpVtbl.Respond(req);
        }
    }

    fn registerWindows(self: *GattApplication) !void {
        if (builtin.os.tag != .windows) return error.NotSupported;
        if (self.is_registered) return;

        const hr_init = win_bindings.Combase.RoInitialize(win_bindings.RO_INIT_MULTITHREADED);
        if (hr_init < 0 and hr_init != win_bindings.RPC_E_CHANGED_MODE) {
            return error.GattApplicationRegistrationFailed;
        }

        const sp_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider");
        defer win_mod.deleteHString(sp_class);

        var sp_statics: ?*win_bindings.IGattServiceProviderStatics = null;
        if (win_bindings.Combase.RoGetActivationFactory(sp_class, &win_bindings.IID_IGattServiceProviderStatics, @ptrCast(&sp_statics)) < 0 or sp_statics == null) {
            return error.GattApplicationRegistrationFailed;
        }
        const statics = sp_statics.?;
        defer _ = statics.lpVtbl.Release(statics);

        errdefer {
            for (self.services[0..self.service_count]) |*s| {
                s.releaseWindows();
            }
        }

        for (self.services[0..self.service_count]) |*s| {
            var create_op: ?*win_bindings.IAsyncOperationGeneric = null;
            if (statics.lpVtbl.CreateAsync(statics, win_mod.uuidToGuid(s.uuid), &create_op) < 0 or create_op == null) {
                return error.GattApplicationRegistrationFailed;
            }

            const sp_res_raw = (try win_mod.awaitAsync(create_op.?, 10_000)) orelse return error.GattApplicationRegistrationFailed;
            const sp_res: *win_bindings.IGattServiceProviderResult = @ptrCast(@alignCast(sp_res_raw));
            defer _ = sp_res.lpVtbl.Release(sp_res);

            var bt_err: win_bindings.BluetoothError = .OtherError;
            if (sp_res.lpVtbl.get_Error(sp_res, &bt_err) < 0 or bt_err != .Success) {
                return error.GattApplicationRegistrationFailed;
            }

            var provider: ?*win_bindings.IGattServiceProvider = null;
            if (sp_res.lpVtbl.get_ServiceProvider(sp_res, &provider) < 0 or provider == null) {
                return error.GattApplicationRegistrationFailed;
            }
            const prov = provider.?;
            s.win_provider = prov;

            var local_svc: ?*win_bindings.IGattLocalService = null;
            if (prov.lpVtbl.get_Service(prov, &local_svc) < 0 or local_svc == null) {
                return error.GattApplicationRegistrationFailed;
            }
            const lsvc = local_svc.?;
            defer _ = lsvc.lpVtbl.Release(lsvc);

            for (s.characteristics[0..s.char_count]) |*ch| {
                const param_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicParameters");
                defer win_mod.deleteHString(param_class);

                var param_insp: ?*win_bindings.IInspectable = null;
                if (win_bindings.Combase.RoActivateInstance(param_class, &param_insp) < 0 or param_insp == null) {
                    return error.GattApplicationRegistrationFailed;
                }
                const pinsp = param_insp.?;
                defer _ = pinsp.release();

                var params: ?*win_bindings.IGattLocalCharacteristicParameters = null;
                if (pinsp.queryInterface(&win_bindings.IID_IGattLocalCharacteristicParameters, @ptrCast(&params)) < 0 or params == null) {
                    return error.GattApplicationRegistrationFailed;
                }
                const p = params.?;
                defer _ = p.lpVtbl.Release(p);

                _ = p.lpVtbl.put_CharacteristicProperties(p, ch.flags.toWinRtProperties());
                _ = p.lpVtbl.put_ReadProtectionLevel(p, @enumFromInt(ch.flags.toWinRtReadProtection()));
                _ = p.lpVtbl.put_WriteProtectionLevel(p, @enumFromInt(ch.flags.toWinRtWriteProtection()));

                for (ch.descriptors[0..ch.desc_count]) |*d| {
                    if (d.uuid.eql(UUID.from16(0x2901)) and d.value_len > 0) {
                        if (win_mod.createHStringRuntime(d.getValue())) |desc_hstr| {
                            defer win_mod.deleteHString(desc_hstr);
                            _ = p.lpVtbl.put_UserDescription(p, desc_hstr);
                        } else |_| {}
                    }
                }

                var char_op: ?*win_bindings.IAsyncOperationGeneric = null;
                if (lsvc.lpVtbl.CreateCharacteristicAsync(lsvc, win_mod.uuidToGuid(ch.uuid), p, &char_op) < 0 or char_op == null) {
                    return error.GattApplicationRegistrationFailed;
                }

                const char_res_raw = (try win_mod.awaitAsync(char_op.?, 10_000)) orelse return error.GattApplicationRegistrationFailed;
                const char_res: *win_bindings.IGattLocalCharacteristicResult = @ptrCast(@alignCast(char_res_raw));
                defer _ = char_res.lpVtbl.Release(char_res);

                var c_err: win_bindings.BluetoothError = .OtherError;
                if (char_res.lpVtbl.get_Error(char_res, &c_err) < 0 or c_err != .Success) {
                    return error.GattApplicationRegistrationFailed;
                }

                var local_char: ?*win_bindings.IGattLocalCharacteristic = null;
                if (char_res.lpVtbl.get_Characteristic(char_res, &local_char) < 0 or local_char == null) {
                    return error.GattApplicationRegistrationFailed;
                }
                const lc = local_char.?;
                ch.win_char = lc;

                ch.win_read_handler = .{
                    .char_ctx = @ptrCast(ch),
                    .on_read_requested = onWinRtReadRequested,
                };
                _ = lc.lpVtbl.add_ReadRequested(lc, @ptrCast(&ch.win_read_handler), &ch.win_read_token);

                ch.win_write_handler = .{
                    .char_ctx = @ptrCast(ch),
                    .on_write_requested = onWinRtWriteRequested,
                };
                _ = lc.lpVtbl.add_WriteRequested(lc, @ptrCast(&ch.win_write_handler), &ch.win_write_token);
            }

            // Start advertising the GATT service
            const adv_param_class = try win_mod.createHStringComptime("Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProviderAdvertisingParameters");
            defer win_mod.deleteHString(adv_param_class);

            var adv_insp: ?*win_bindings.IInspectable = null;
            if (win_bindings.Combase.RoActivateInstance(adv_param_class, &adv_insp) >= 0 and adv_insp != null) {
                const ainsp = adv_insp.?;
                defer _ = ainsp.release();

                var adv_params: ?*win_bindings.IGattServiceProviderAdvertisingParameters = null;
                if (ainsp.queryInterface(&win_bindings.IID_IGattServiceProviderAdvertisingParameters, @ptrCast(&adv_params)) >= 0 and adv_params != null) {
                    const ap = adv_params.?;
                    defer _ = ap.lpVtbl.Release(ap);
                    _ = ap.lpVtbl.put_IsConnectable(ap, 1);
                    _ = ap.lpVtbl.put_IsDiscoverable(ap, 1);
                    const start_hr = prov.lpVtbl.StartAdvertisingWithParameters(prov, ap);
                    if (start_hr < 0) {
                        log.warn("WinRT GattServiceProvider.StartAdvertisingWithParameters returned HRESULT 0x{X:0>8}", .{@as(u32, @bitCast(start_hr))});
                        return error.GattApplicationRegistrationFailed;
                    }
                }
            }
        }

        self.is_registered = true;
    }

    fn registerLinux(self: *GattApplication) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        const conn = self.conn orelse return error.GattApplicationRegistrationFailed;

        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getAdapterPath(),
            BlueZ.GattManager1.interface_name,
            BlueZ.GattManager1.Methods.RegisterApplication,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendObjectPath(self.getAppPath());

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
        const ctx = PredicateContext{ .reg_serial = reg_serial, .app_path = self.getAppPath() };

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

    /// Unregisters the GATT application from the OS Bluetooth stack.
    pub fn unregister(self: *GattApplication) !void {
        if (builtin.os.tag == .linux) {
            if (!self.is_registered) return;
            const conn = self.conn orelse return;

            var msg = try Connection.createMethodCall(
                BlueZ.service_name,
                self.getAdapterPath(),
                BlueZ.GattManager1.interface_name,
                BlueZ.GattManager1.Methods.UnregisterApplication,
            );
            defer msg.deinit();

            var b = msg.builder();
            try b.appendObjectPath(self.getAppPath());

            var reply = try conn.sendMessage(&msg, 5000);
            reply.deinit();

            self.is_registered = false;
        } else if (builtin.os.tag == .windows) {
            for (self.services[0..self.service_count]) |*s| {
                s.releaseWindows();
            }
            self.is_registered = false;
        } else {
            return error.NotSupported;
        }
    }

    /// Handles incoming D-Bus method calls (GetManagedObjects, ReadValue, WriteValue, StartNotify, StopNotify).
    pub fn processMessage(self: *GattApplication, msg: *const Message) !bool {
        if (builtin.os.tag != .linux) return false;
        const conn = self.conn orelse return false;

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
            var root_dict = try b.openArray("{oa{sa{sv}}}");

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
                                var du_buf: [36]u8 = undefined;
                                _ = d.uuid.formatBuf(&du_buf);
                                var d_null_term: [37]u8 = undefined;
                                @memcpy(d_null_term[0..36], &du_buf);
                                d_null_term[36] = 0;
                                try d_props_dict.appendDictString(BlueZ.GattDescriptor1.Properties.UUID, d_null_term[0..36 :0]);
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
        for (self.services[0..self.service_count]) |*s| {
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

test "ServerCharacteristicFlags & ServerDescriptorFlags: security and permission flags" {
    const flags = ServerCharacteristicFlags{
        .read = true,
        .write = true,
        .encrypt_read = true,
        .encrypt_authenticated_write = true,
        .secure_read = true,
        .authorize = true,
    };
    var out_buf: [12][:0]const u8 = undefined;
    const slice = flags.toBluezFlags(&out_buf);
    try std.testing.expectEqual(@as(usize, 6), slice.len);
    try std.testing.expectEqualStrings("read", slice[0]);
    try std.testing.expectEqualStrings("write", slice[1]);
    try std.testing.expectEqualStrings("encrypt-read", slice[2]);
    try std.testing.expectEqualStrings("encrypt-authenticated-write", slice[3]);
    try std.testing.expectEqualStrings("secure-read", slice[4]);
    try std.testing.expectEqualStrings("authorize", slice[5]);

    try std.testing.expectEqual(@as(i32, 3), flags.toWinRtReadProtection());
    try std.testing.expectEqual(@as(i32, 3), flags.toWinRtWriteProtection());
    try std.testing.expectEqual(@as(u32, 0x2 | 0x8), flags.toWinRtProperties());

    const dflags = ServerDescriptorFlags{
        .read = true,
        .encrypt_read = true,
        .secure_write = true,
        .authorize = true,
    };
    var dout_buf: [9][:0]const u8 = undefined;
    const dslice = dflags.toBluezFlags(&dout_buf);
    try std.testing.expectEqual(@as(usize, 4), dslice.len);
    try std.testing.expectEqualStrings("read", dslice[0]);
    try std.testing.expectEqualStrings("encrypt-read", dslice[1]);
    try std.testing.expectEqualStrings("secure-write", dslice[2]);
    try std.testing.expectEqualStrings("authorize", dslice[3]);
}
