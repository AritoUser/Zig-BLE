//! Zig-BLE GATT Client: Represents a GATT Characteristic (GattCharacteristic1).
//! Supports ReadValue, WriteValue (with/without response), and StartNotify/StopNotify with zero heap allocations.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const WriteType = core.WriteType;
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const DBusError = if (builtin.os.tag == .linux) dbus.DBusError else anyerror;

/// Direct ATT streaming channel over a native Linux Unix domain socket / file descriptor.
/// Obtained via BlueZ `AcquireNotify` or `AcquireWrite`.
/// Enables zero-copy streaming with maximum BLE throughput bypassing D-Bus daemon overhead.
pub const GattStream = struct {
    fd: std.posix.fd_t,
    mtu: u16,

    /// Closes the file descriptor. Automatically signals BlueZ via socket HUP/EOF
    /// that streaming ended, resetting NotifyAcquired / WriteAcquired.
    pub fn deinit(self: *GattStream) void {
        if (builtin.os.tag == .linux) {
            if (self.fd >= 0) {
                _ = std.posix.system.close(self.fd);
                self.fd = -1;
            }
        }
    }

    /// Reads a raw ATT packet directly from the Linux kernel socket buffer.
    /// Blocks until data arrives or an error/EOF occurs.
    /// Returns the number of bytes read (0 denotes EOF / stream closed).
    pub fn read(self: *GattStream, buf: []u8) !usize {
        if (builtin.os.tag != .linux) return error.NotSupported;
        if (self.fd < 0) return error.NotOpen;
        return std.posix.read(self.fd, buf) catch return error.IOError;
    }

    /// Writes a raw ATT packet directly into the socket.
    /// Returns the number of bytes written.
    pub fn write(self: *GattStream, data: []const u8) !usize {
        if (builtin.os.tag != .linux) return error.NotSupported;
        if (self.fd < 0) return error.NotOpen;
        const rc = std.posix.system.write(self.fd, data.ptr, data.len);
        if (std.posix.errno(rc) != .SUCCESS) return error.IOError;
        return @intCast(rc);
    }
};

pub const GattCharacteristic = struct {
    conn: *Connection,
    object_path: [224]u8 = undefined,
    object_path_len: u8 = 0,

    pub fn init(conn: *Connection, path: [:0]const u8) GattCharacteristic {
        var ch = GattCharacteristic{
            .conn = conn,
        };
        const len = @min(ch.object_path.len - 1, path.len);
        @memcpy(ch.object_path[0..len], path[0..len]);
        ch.object_path[len] = 0;
        ch.object_path_len = @intCast(len);
        return ch;
    }

    pub fn getObjectPath(self: *const GattCharacteristic) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    /// Reads the current value of the characteristic (ATT Read Request).
    /// Writes the result directly into buf with zero heap allocations.
    pub fn readValue(self: *GattCharacteristic, buf: []u8) !usize {
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.ReadValue,
        );
        defer msg.deinit();

        // Empty options dictionary {sv}
        var b = msg.builder();
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getFixedBytes()) |bytes| {
            const copy_len = @min(buf.len, bytes.len);
            @memcpy(buf[0..copy_len], bytes[0..copy_len]);
            return copy_len;
        }
        return 0;
    }

    /// Writes data to the characteristic.
    /// write_type = .with_response (ATT Write Request) or .without_response (ATT Write Command).
    pub fn writeValue(self: *GattCharacteristic, data: []const u8, write_type: WriteType) !void {
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.WriteValue,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendBytes(data);

        // Options dictionary
        var options = try b.openArray("{sv}");
        if (write_type == .without_response) {
            var entry = try options.openDictEntry();
            try entry.appendString("type");
            var v = try entry.openVariant("s");
            try v.appendString("command");
            try entry.closeContainer(&v);
            try options.closeContainer(&entry);
        }
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();
    }

    /// Enables notifications/indications on this characteristic.
    pub fn startNotify(self: *GattCharacteristic) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.StartNotify,
            5000,
        );
        reply.deinit();
    }

    /// Disables notifications/indications.
    pub fn stopNotify(self: *GattCharacteristic) !void {
        var reply = try self.conn.callMethod(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.StopNotify,
            5000,
        );
        reply.deinit();
    }

    /// Obtains a direct Unix file descriptor for ATT notifications/indications via BlueZ `AcquireNotify`.
    /// Completely bypasses the D-Bus daemon and enables zero-copy streaming from the Linux kernel.
    pub fn acquireNotify(self: *GattCharacteristic) !GattStream {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.AcquireNotify,
        );
        defer msg.deinit();

        // Empty options dictionary {sv}
        var b = msg.builder();
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        const fd_idx = it.getUnixFdIndex() orelse return error.InvalidReply;
        const fd = reply.extractFd(fd_idx) orelse return error.InvalidReply;
        const mtu = it.getUInt16() orelse return error.InvalidReply;

        return GattStream{
            .fd = fd,
            .mtu = mtu,
        };
    }

    /// Obtains a direct Unix file descriptor for ATT writes via BlueZ `AcquireWrite`.
    /// Enables high-throughput ATT writes without D-Bus message overhead.
    pub fn acquireWrite(self: *GattCharacteristic) !GattStream {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattCharacteristic1.interface_name,
            BlueZ.GattCharacteristic1.Methods.AcquireWrite,
        );
        defer msg.deinit();

        // Empty options dictionary {sv}
        var b = msg.builder();
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        const fd_idx = it.getUnixFdIndex() orelse return error.InvalidReply;
        const fd = reply.extractFd(fd_idx) orelse return error.InvalidReply;
        const mtu = it.getUInt16() orelse return error.InvalidReply;

        return GattStream{
            .fd = fd,
            .mtu = mtu,
        };
    }

    /// Waits synchronously for the next notification of this characteristic (up to timeout_ms).
    /// Writes received bytes directly into the provided buf (100% zero-allocation).
    /// NOTE: For multi-client systems or simultaneous peripheral hosting, prefer
    /// `NotificationDispatcher` combined with `EventLoop` so messages for other components are preserved.
    pub fn waitForNotification(self: *GattCharacteristic, buf: []u8, timeout_ms: c_int) !?usize {
        if (builtin.os.tag != .linux) return null;
        _ = self.conn.pollSocket(timeout_ms);
        while (self.conn.popMessage()) |msg| {
            defer msg.deinit();
            if (parseNotification(&msg)) |ev| {
                if (std.mem.eql(u8, ev.characteristic_path, self.getObjectPath())) {
                    const copy_len = @min(buf.len, ev.data.len);
                    @memcpy(buf[0..copy_len], ev.data[0..copy_len]);
                    return copy_len;
                }
            }
        }
        return null;
    }

    /// Continuously listens for notifications of this characteristic and invokes the callback for each packet.
    /// Uses max_iterations loops of step_ms for a deterministic loop.
    /// Uses native kernel socket polling (zero CPU overhead).
    pub fn streamNotifications(
        self: *GattCharacteristic,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (ctx: *Context, data: []const u8) void,
        max_iterations: usize,
        step_ms: c_int,
    ) !usize {
        if (builtin.os.tag != .linux) return 0;
        var packet_count: usize = 0;
        var iters: usize = 0;

        while (iters < max_iterations) : (iters += 1) {
            _ = self.conn.pollSocket(step_ms);
            while (self.conn.popMessage()) |msg| {
                defer msg.deinit();
                if (parseNotification(&msg)) |ev| {
                    if (std.mem.eql(u8, ev.characteristic_path, self.getObjectPath())) {
                        packet_count += 1;
                        callback(context, ev.data);
                    }
                }
            }
        }
        return packet_count;
    }
};

/// Represents a received GATT notification / indication packet.
pub const NotificationEvent = struct {
    characteristic_path: [:0]const u8,
    data: []const u8,
};

const Message = if (builtin.os.tag == .linux) dbus.Message else struct {};

/// Parses an incoming D-Bus signal and checks if it is a GATT characteristic value update.
/// 100% Zero-copy: Points directly to the internally buffered payload of the D-Bus message.
pub fn parseNotification(msg: *const Message) ?NotificationEvent {
    if (builtin.os.tag != .linux) return null;
    if (msg.getMessageType() != 4) return null; // DBUS_MESSAGE_TYPE_SIGNAL
    const member = msg.getMember() orelse return null;
    if (!std.mem.eql(u8, member, "PropertiesChanged")) return null;

    const char_path = msg.getPath() orelse return null;
    var it = msg.iterator();
    const iface = it.getString() orelse return null;
    if (!std.mem.eql(u8, iface, BlueZ.GattCharacteristic1.interface_name)) return null;

    if (it.recurse()) |*props_array| {
        var pa = props_array.*;
        while (pa.hasMore()) {
            if (pa.recurse()) |*prop_entry| {
                var pe = prop_entry.*;
                if (pe.getString()) |key| {
                    if (std.mem.eql(u8, key, BlueZ.GattCharacteristic1.Properties.Value)) {
                        if (pe.getVariant()) |*v| {
                            var var_iter = v.*;
                            if (var_iter.getFixedBytes()) |bytes| {
                                return NotificationEvent{
                                    .characteristic_path = char_path,
                                    .data = bytes,
                                };
                            }
                        }
                    }
                }
            }
            _ = pa.next();
        }
    }
    return null;
}

/// Static dispatcher for up to 16 concurrent characteristic streams with zero heap allocations.
pub const NotificationDispatcher = struct {
    pub const HandlerFn = *const fn (char_path: [:0]const u8, data: []const u8, user_data: ?*anyopaque) void;

    pub const Subscription = struct {
        characteristic_path: [224]u8 = undefined,
        path_len: u8 = 0,
        handler: HandlerFn,
        user_data: ?*anyopaque = null,
    };

    subscriptions: [16]Subscription = undefined,
    count: usize = 0,

    pub fn init() NotificationDispatcher {
        return .{};
    }

    /// Subscribes a callback to a specific characteristic.
    pub fn subscribe(
        self: *NotificationDispatcher,
        char_path: [:0]const u8,
        handler: HandlerFn,
        user_data: ?*anyopaque,
    ) !void {
        if (self.count >= self.subscriptions.len) return error.MaxSubscriptionsReached;
        var sub = &self.subscriptions[self.count];
        const len = @min(sub.characteristic_path.len - 1, char_path.len);
        @memcpy(sub.characteristic_path[0..len], char_path[0..len]);
        sub.characteristic_path[len] = 0;
        sub.path_len = @intCast(len);
        sub.handler = handler;
        sub.user_data = user_data;
        self.count += 1;
    }

    /// Processes an incoming D-Bus message and invokes the registered callback on matching notifications.
    pub fn processMessage(self: *NotificationDispatcher, msg: *const Message) bool {
        if (parseNotification(msg)) |ev| {
            for (self.subscriptions[0..self.count]) |*sub| {
                if (std.mem.eql(u8, sub.characteristic_path[0..sub.path_len], ev.characteristic_path)) {
                    sub.handler(ev.characteristic_path, ev.data, sub.user_data);
                    return true;
                }
            }
        }
        return false;
    }
};

/// Client-side representation of a GATT Descriptor (org.bluez.GattDescriptor1).
/// Enables reading and writing remote descriptors such as CCCD (0x2902), User Description (0x2901),
/// Presentation Format (0x2904), etc.
pub const GattDescriptor = struct {
    conn: *Connection,
    object_path: [224]u8 = undefined,
    object_path_len: u8 = 0,

    pub fn init(conn: *Connection, path: [:0]const u8) GattDescriptor {
        var desc = GattDescriptor{
            .conn = conn,
        };
        const len = @min(desc.object_path.len - 1, path.len);
        @memcpy(desc.object_path[0..len], path[0..len]);
        desc.object_path[len] = 0;
        desc.object_path_len = @intCast(len);
        return desc;
    }

    pub fn getObjectPath(self: *const GattDescriptor) [:0]const u8 {
        return self.object_path[0..self.object_path_len :0];
    }

    /// Reads the descriptor's value (ATT Read Request on descriptor handle).
    /// Zero heap allocations: writes bytes directly into `buf`.
    pub fn readValue(self: *GattDescriptor, buf: []u8) !usize {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattDescriptor1.interface_name,
            BlueZ.GattDescriptor1.Methods.ReadValue,
        );
        defer msg.deinit();

        // Empty options dictionary {sv}
        var b = msg.builder();
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getFixedBytes()) |bytes| {
            const copy_len = @min(buf.len, bytes.len);
            @memcpy(buf[0..copy_len], bytes[0..copy_len]);
            return copy_len;
        }
        return 0;
    }

    /// Writes data to the descriptor (ATT Write Request on descriptor handle).
    pub fn writeValue(self: *GattDescriptor, data: []const u8) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.GattDescriptor1.interface_name,
            BlueZ.GattDescriptor1.Methods.WriteValue,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendBytes(data);

        // Empty options dictionary {sv}
        var options = try b.openArray("{sv}");
        try b.closeContainer(&options);

        var reply = try self.conn.sendMessage(&msg, 5000);
        reply.deinit();
    }

    /// Reads the 128-bit UUID property of this descriptor.
    pub fn getUUID(self: *GattDescriptor) !core.UUID {
        if (builtin.os.tag != .linux) return error.NotSupported;
        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            self.getObjectPath(),
            BlueZ.Properties.interface_name,
            BlueZ.Properties.Methods.Get,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendString(BlueZ.GattDescriptor1.interface_name);
        try b.appendString(BlueZ.GattDescriptor1.Properties.UUID);

        var reply = try self.conn.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        if (it.getVariant()) |*v| {
            var var_iter = v.*;
            if (var_iter.getString()) |uuid_str| {
                return core.UUID.parse(uuid_str);
            }
        }
        return error.PropertyNotFound;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "GattStream: struct initialization and deinit" {
    var stream = GattStream{
        .fd = -1,
        .mtu = 512,
    };
    try std.testing.expectEqual(@as(u16, 512), stream.mtu);
    stream.deinit();
    try std.testing.expectEqual(@as(c_int, -1), stream.fd);
}

test "GattDescriptor: init and path handling" {
    var desc = GattDescriptor.init(undefined, "/org/bluez/hci0/dev_XX/service0020/char0021/desc0022");
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_XX/service0020/char0021/desc0022", desc.getObjectPath());
}


