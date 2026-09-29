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

pub const Agent = struct {
    conn: *Connection,
    agent_path: [128]u8 = undefined,
    agent_path_len: u8 = 0,
    capability: AgentCapability = .no_input_no_output,
    is_registered: bool = false,

    pub fn init(conn: *Connection, agent_path: [:0]const u8, capability: AgentCapability) Agent {
        var a = Agent{
            .conn = conn,
            .capability = capability,
        };
        const len = @min(a.agent_path.len - 1, agent_path.len);
        @memcpy(a.agent_path[0..len], agent_path[0..len]);
        a.agent_path[len] = 0;
        a.agent_path_len = @intCast(len);
        return a;
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

        // RequestConfirmation(device, passkey) - Just Works / Numeric Comparison Auto-Accept
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestConfirmation)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try self.conn.send(&reply);
            return true;
        }

        // RequestAuthorization(device) - Auto-Accept
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestAuthorization)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try self.conn.send(&reply);
            return true;
        }

        // AuthorizeService(device, uuid) - Auto-Accept Service Access
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.AuthorizeService)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            try self.conn.send(&reply);
            return true;
        }

        // RequestPasskey(device) -> default to 0 if requested
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPasskey)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            var b = reply.builder();
            try b.appendUInt32(0);
            try self.conn.send(&reply);
            return true;
        }

        // RequestPinCode(device) -> "0000"
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPinCode)) {
            var reply = try Connection.createMethodReturn(msg);
            defer reply.deinit();
            var b = reply.builder();
            try b.appendString("0000");
            try self.conn.send(&reply);
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
    var dummy_conn: Connection = undefined;
    const a = Agent.init(&dummy_conn, "/org/zig_ble/agent", .no_input_no_output);
    try std.testing.expectEqualStrings("/org/zig_ble/agent", a.getObjectPath());
    try std.testing.expectEqualStrings("NoInputNoOutput", a.capability.toSlice());
}
