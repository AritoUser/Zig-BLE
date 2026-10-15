//! Zig-BLE Pairing Agent: Implements org.bluez.Agent1 for authorization & pairing
//! of Bluetooth LE connections (Central & Peripheral).
//! 100% Zero dynamic heap allocations.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("bluez/constants.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const Message = if (builtin.os.tag == .linux) dbus.Message else struct {};
const DBusError = if (builtin.os.tag == .linux) dbus.DBusError else anyerror;

pub const AgentCapability = enum {
    no_input_no_output,
    display_only,
    display_yes_no,
    keyboard_only,
    keyboard_display,

    pub fn toSlice(self: AgentCapability) [:0]const u8 {
        return switch (self) {
            .no_input_no_output => BlueZ.AgentManager1.Capability.NoInputNoOutput,
            .display_only => BlueZ.AgentManager1.Capability.DisplayOnly,
            .display_yes_no => BlueZ.AgentManager1.Capability.DisplayYesNo,
            .keyboard_only => BlueZ.AgentManager1.Capability.KeyboardOnly,
            .keyboard_display => BlueZ.AgentManager1.Capability.KeyboardDisplay,
        };
    }
};

pub const AgentCallbacks = struct {
    request_passkey: ?*const fn (device_path: [:0]const u8, user_data: ?*anyopaque) ?u32 = null,
    request_pin_code: ?*const fn (device_path: [:0]const u8, user_data: ?*anyopaque) ?[:0]const u8 = null,
    request_confirmation: ?*const fn (device_path: [:0]const u8, passkey: u32, user_data: ?*anyopaque) bool = null,
    request_authorization: ?*const fn (device_path: [:0]const u8, user_data: ?*anyopaque) bool = null,
    authorize_service: ?*const fn (device_path: [:0]const u8, uuid: [:0]const u8, user_data: ?*anyopaque) bool = null,
    user_data: ?*anyopaque = null,

    /// Opt-in flag to automatically accept numeric confirmation/authorization
    /// in automated test harnesses and headless CI environments.
    auto_accept: bool = false,
};

pub const Agent = struct {
    conn: *Connection,
    agent_path: [128]u8 = undefined,
    agent_path_len: u8 = 0,
    capability: AgentCapability = .no_input_no_output,
    callbacks: AgentCallbacks = .{},
    is_registered: bool = false,

    pub fn init(conn: *Connection, agent_path: [:0]const u8, capability: AgentCapability) Agent {
        return initWithCallbacks(conn, agent_path, capability, .{});
    }

    pub fn initWithCallbacks(
        conn: *Connection,
        agent_path: [:0]const u8,
        capability: AgentCapability,
        callbacks: AgentCallbacks,
    ) Agent {
        var a = Agent{
            .conn = conn,
            .capability = capability,
            .callbacks = callbacks,
        };
        const len = @min(a.agent_path.len - 1, agent_path.len);
        @memcpy(a.agent_path[0..len], agent_path[0..len]);
        a.agent_path[len] = 0;
        a.agent_path_len = @intCast(len);
        return a;
    }

    pub fn setCallbacks(self: *Agent, callbacks: AgentCallbacks) void {
        self.callbacks = callbacks;
    }

    pub fn getObjectPath(self: *const Agent) [:0]const u8 {
        return self.agent_path[0..self.agent_path_len :0];
    }

    /// Registers the agent with BlueZ AgentManager1 and promotes it to default agent.
    pub fn register(self: *Agent) !void {
        if (builtin.os.tag != .linux) return error.NotSupported;

        // 1. RegisterAgent(agent_path, capability)
        {
            var msg = try Connection.createMethodCall(
                BlueZ.service_name,
                BlueZ.AgentManager1.object_path,
                BlueZ.AgentManager1.interface_name,
                BlueZ.AgentManager1.Methods.RegisterAgent,
            );
            defer msg.deinit();

            var b = msg.builder();
            try b.appendObjectPath(self.getObjectPath());
            try b.appendString(self.capability.toSlice());

            var reply = try self.conn.sendMessage(&msg, 3000);
            defer reply.deinit();
        }

        // 2. RequestDefaultAgent(agent_path)
        {
            var msg = try Connection.createMethodCall(
                BlueZ.service_name,
                BlueZ.AgentManager1.object_path,
                BlueZ.AgentManager1.interface_name,
                BlueZ.AgentManager1.Methods.RequestDefaultAgent,
            );
            defer msg.deinit();

            var b = msg.builder();
            try b.appendObjectPath(self.getObjectPath());

            var reply = try self.conn.sendMessage(&msg, 3000);
            defer reply.deinit();
        }

        self.is_registered = true;
    }

    /// Unregisters the agent.
    pub fn unregister(self: *Agent) !void {
        if (builtin.os.tag != .linux) return;
        if (!self.is_registered) return;

        var msg = try Connection.createMethodCall(
            BlueZ.service_name,
            BlueZ.AgentManager1.object_path,
            BlueZ.AgentManager1.interface_name,
            BlueZ.AgentManager1.Methods.UnregisterAgent,
        );
        defer msg.deinit();

        var b = msg.builder();
        try b.appendObjectPath(self.getObjectPath());

        var reply = try self.conn.sendMessage(&msg, 3000);
        defer reply.deinit();

        self.is_registered = false;
    }

    fn reject(self: *Agent, msg: *const Message, err_msg: [:0]const u8) !void {
        var reply = try Connection.createErrorReply(msg, "org.bluez.Error.Rejected", err_msg);
        defer reply.deinit();
        try self.conn.send(&reply);
    }

    /// Handles incoming D-Bus requests from BlueZ to this agent.
    /// Returns true if the message was destined for this agent and handled.
    pub fn processMessage(self: *Agent, msg: *const Message) !bool {
        if (builtin.os.tag != .linux) return false;

        const target_path = msg.getPath() orelse return false;
        if (!std.mem.eql(u8, target_path, self.getObjectPath())) return false;

        const iface = msg.getInterface() orelse return false;
        if (!std.mem.eql(u8, iface, BlueZ.Agent1.interface_name)) return false;

        const member = msg.getMember() orelse return false;

        // Release()
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.Release)) {
            self.is_registered = false;
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try self.conn.send(&reply);
            return true;
        }

        // RequestConfirmation(device, passkey) - Numeric Comparison
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestConfirmation)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse "";
            const passkey = it.getUInt32() orelse 0;
            const accept = if (self.callbacks.request_confirmation) |cb|
                cb(dev_path, passkey, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                var reply = try Connection.createMethodReturn(msg);
                defer reply.deinit();
                try self.conn.send(&reply);
            } else {
                try self.reject(msg, "Pairing confirmation rejected");
            }
            return true;
        }

        // RequestAuthorization(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestAuthorization)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse "";
            const accept = if (self.callbacks.request_authorization) |cb|
                cb(dev_path, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                var reply = try Connection.createMethodReturn(msg);
                defer reply.deinit();
                try self.conn.send(&reply);
            } else {
                try self.reject(msg, "Device authorization rejected");
            }
            return true;
        }

        // AuthorizeService(device, uuid)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.AuthorizeService)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse "";
            const service_uuid = it.getString() orelse "";
            const accept = if (self.callbacks.authorize_service) |cb|
                cb(dev_path, service_uuid, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                var reply = try Connection.createMethodReturn(msg);
                defer reply.deinit();
                try self.conn.send(&reply);
            } else {
                try self.reject(msg, "Service authorization rejected");
            }
            return true;
        }

        // RequestPasskey(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPasskey)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse "";
            if (self.callbacks.request_passkey) |cb| {
                if (cb(dev_path, self.callbacks.user_data)) |passkey| {
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    var b = reply.builder();
                    try b.appendUInt32(passkey);
                    try self.conn.send(&reply);
                } else {
                    try self.reject(msg, "Passkey entry rejected by user");
                }
            } else if (self.callbacks.auto_accept) {
                var reply = try Connection.createMethodReturn(msg);
                defer reply.deinit();
                var b = reply.builder();
                try b.appendUInt32(0);
                try self.conn.send(&reply);
            } else {
                try self.reject(msg, "No passkey callback configured");
            }
            return true;
        }

        // RequestPinCode(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPinCode)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse "";
            if (self.callbacks.request_pin_code) |cb| {
                if (cb(dev_path, self.callbacks.user_data)) |pin| {
                    var reply = try Connection.createMethodReturn(msg);
                    defer reply.deinit();
                    var b = reply.builder();
                    try b.appendString(pin);
                    try self.conn.send(&reply);
                } else {
                    try self.reject(msg, "PIN code entry rejected by user");
                }
            } else if (self.callbacks.auto_accept) {
                var reply = try Connection.createMethodReturn(msg);
                defer reply.deinit();
                var b = reply.builder();
                try b.appendString("0000");
                try self.conn.send(&reply);
            } else {
                try self.reject(msg, "No PIN code callback configured");
            }
            return true;
        }

        // DisplayPasskey, DisplayPinCode, Cancel -> acknowledge with empty return
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.DisplayPasskey) or
            std.mem.eql(u8, member, BlueZ.Agent1.Methods.DisplayPinCode) or
            std.mem.eql(u8, member, BlueZ.Agent1.Methods.Cancel))
        {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try self.conn.send(&reply);
            return true;
        }

        return false;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Agent: initialization and capability formatting" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};
    const a = Agent.init(&dummy_conn, "/org/zig_ble/agent", .no_input_no_output);
    try std.testing.expectEqualStrings("/org/zig_ble/agent", a.getObjectPath());
    try std.testing.expectEqualStrings("NoInputNoOutput", a.capability.toSlice());
    try std.testing.expect(!a.callbacks.auto_accept);
}

test "Agent: custom callbacks and auto_accept configuration" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};

    const DummyCallbacks = struct {
        fn onPasskey(_: [:0]const u8, _: ?*anyopaque) ?u32 {
            return 123456;
        }
    };

    var a = Agent.initWithCallbacks(
        &dummy_conn,
        "/org/zig_ble/agent",
        .keyboard_display,
        .{
            .request_passkey = DummyCallbacks.onPasskey,
            .auto_accept = true,
        },
    );

    try std.testing.expectEqualStrings("KeyboardDisplay", a.capability.toSlice());
    try std.testing.expect(a.callbacks.auto_accept);
    try std.testing.expect(a.callbacks.request_passkey != null);
    try std.testing.expectEqual(@as(?u32, 123456), a.callbacks.request_passkey.?("/org/bluez/dev_1", null));
}
