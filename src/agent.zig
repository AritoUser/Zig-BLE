//! Zig-BLE Pairing Agent: Implements org.bluez.Agent1 for authorization & pairing
//! of Bluetooth LE connections (Central & Peripheral).
//!
//! Security Guarantees:
//! - Default-deny policy: All unhandled pairing, passkey, PIN, confirmation, and service
//!   authorization requests are strictly rejected with `org.bluez.Error.Rejected`.
//! - Input validation: Validates BlueZ device object paths, BLE 6-digit passkey range
//!   (`0..999_999`), PIN code length (`1..16` bytes), and UUID formatting before invoking callbacks.
//! - Anti-spoofing: Rejects non-method-call D-Bus frames (e.g. signals masquerading as Agent1 calls).

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("bluez/constants.zig");
const core = @import("core/mod.zig");
const wire = @import("dbus/wire/mod.zig");
const BlueZ = constants.BlueZ;

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else wire.NonLinuxConnection;
pub const Message = wire.Message;
pub const DBusError = wire.DBusError;

pub const AgentError = error{
    NotSupported,
    InvalidAgentPath,
} || DBusError || std.mem.Allocator.Error;

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
    /// Does NOT synthesize passkeys or PIN codes.
    auto_accept: bool = false,
};

/// Validates that `path` is a well-formed BlueZ device object path (`/org/bluez/...`).
pub fn isValidBluezDevicePath(path: []const u8) bool {
    if (path.len < "/org/bluez/hci0/dev_0".len or path.len > 127) return false;
    if (!std.mem.startsWith(u8, path, "/org/bluez/")) return false;
    if (std.mem.indexOf(u8, path, "//") != null) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (path[path.len - 1] == '/') return false;

    for (path) |c| {
        const valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '/';
        if (!valid) return false;
    }
    return true;
}

/// Validates that `uuid_str` is a valid 16-bit, 32-bit, or 128-bit Bluetooth UUID string.
pub fn isValidServiceUuid(uuid_str: []const u8) bool {
    if (uuid_str.len == 0 or uuid_str.len > 38) return false;
    _ = core.UUID.parse(uuid_str) catch return false;
    return true;
}

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
    pub fn register(self: *Agent) AgentError!void {
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
    pub fn unregister(self: *Agent) AgentError!void {
        if (builtin.os.tag != .linux) return error.NotSupported;
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

    fn createRejectReply(msg: *const Message, err_msg: [:0]const u8) !Message {
        return Message.createErrorReply(msg.allocator, msg, "org.bluez.Error.Rejected", err_msg);
    }

    /// Evaluates an incoming D-Bus message and constructs the appropriate reply (MethodReturn or ErrorReply).
    /// Returns `null` if the message is not a method call targeting this agent's path and `org.bluez.Agent1`.
    pub fn handleRequest(self: *Agent, msg: *const Message) !?Message {
        // Security check: Only process D-Bus METHOD_CALL frames (ignore signals, errors, method_returns)
        if (msg.fixed_header.msg_type != .method_call) return null;

        const target_path = msg.getPath() orelse return null;
        if (!std.mem.eql(u8, target_path, self.getObjectPath())) return null;

        const iface = msg.getInterface() orelse return null;
        if (!std.mem.eql(u8, iface, BlueZ.Agent1.interface_name)) return null;

        const member = msg.getMember() orelse {
            return try createRejectReply(msg, "Missing Agent1 method member");
        };

        // Release()
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.Release)) {
            self.is_registered = false;
            return try Message.createMethodReturn(msg.allocator, msg);
        }

        // Cancel()
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.Cancel)) {
            return try Message.createMethodReturn(msg.allocator, msg);
        }

        // DisplayPasskey(device, passkey, entered)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.DisplayPasskey)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            const passkey = it.getUInt32() orelse return try createRejectReply(msg, "Missing passkey argument");
            if (!isValidBluezDevicePath(dev_path) or passkey > 999_999) {
                return try createRejectReply(msg, "Invalid DisplayPasskey arguments");
            }
            return try Message.createMethodReturn(msg.allocator, msg);
        }

        // DisplayPinCode(device, pincode)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.DisplayPinCode)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            const pin = it.getString() orelse return try createRejectReply(msg, "Missing PIN argument");
            if (!isValidBluezDevicePath(dev_path) or pin.len == 0 or pin.len > 16) {
                return try createRejectReply(msg, "Invalid DisplayPinCode arguments");
            }
            return try Message.createMethodReturn(msg.allocator, msg);
        }

        // RequestConfirmation(device, passkey) - Numeric Comparison
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestConfirmation)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            const passkey = it.getUInt32() orelse return try createRejectReply(msg, "Missing passkey argument");
            if (!isValidBluezDevicePath(dev_path) or passkey > 999_999) {
                return try createRejectReply(msg, "Invalid RequestConfirmation arguments");
            }

            const accept = if (self.callbacks.request_confirmation) |cb|
                cb(dev_path, passkey, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                return try Message.createMethodReturn(msg.allocator, msg);
            } else {
                return try createRejectReply(msg, "Pairing confirmation rejected");
            }
        }

        // RequestAuthorization(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestAuthorization)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            if (!isValidBluezDevicePath(dev_path)) {
                return try createRejectReply(msg, "Invalid device object path");
            }

            const accept = if (self.callbacks.request_authorization) |cb|
                cb(dev_path, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                return try Message.createMethodReturn(msg.allocator, msg);
            } else {
                return try createRejectReply(msg, "Device authorization rejected");
            }
        }

        // AuthorizeService(device, uuid)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.AuthorizeService)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            const service_uuid = it.getString() orelse return try createRejectReply(msg, "Missing service UUID");
            if (!isValidBluezDevicePath(dev_path) or !isValidServiceUuid(service_uuid)) {
                return try createRejectReply(msg, "Invalid AuthorizeService arguments");
            }

            const accept = if (self.callbacks.authorize_service) |cb|
                cb(dev_path, service_uuid, self.callbacks.user_data)
            else
                self.callbacks.auto_accept;

            if (accept) {
                return try Message.createMethodReturn(msg.allocator, msg);
            } else {
                return try createRejectReply(msg, "Service authorization rejected");
            }
        }

        // RequestPasskey(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPasskey)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            if (!isValidBluezDevicePath(dev_path)) {
                return try createRejectReply(msg, "Invalid device object path");
            }

            if (self.callbacks.request_passkey) |cb| {
                if (cb(dev_path, self.callbacks.user_data)) |passkey| {
                    if (passkey > 999_999) {
                        return try createRejectReply(msg, "Passkey out of valid 6-digit range");
                    }
                    var reply = try Message.createMethodReturn(msg.allocator, msg);
                    errdefer reply.deinit();
                    var b = reply.builder();
                    try b.appendUInt32(passkey);
                    return reply;
                } else {
                    return try createRejectReply(msg, "Passkey entry rejected by user");
                }
            } else {
                return try createRejectReply(msg, "No passkey callback configured");
            }
        }

        // RequestPinCode(device)
        if (std.mem.eql(u8, member, BlueZ.Agent1.Methods.RequestPinCode)) {
            var it = msg.iterator();
            const dev_path = it.getObjectPath() orelse return try createRejectReply(msg, "Missing device object path");
            if (!isValidBluezDevicePath(dev_path)) {
                return try createRejectReply(msg, "Invalid device object path");
            }

            if (self.callbacks.request_pin_code) |cb| {
                if (cb(dev_path, self.callbacks.user_data)) |pin| {
                    if (pin.len == 0 or pin.len > 16) {
                        return try createRejectReply(msg, "PIN code length out of range (1..16)");
                    }
                    var reply = try Message.createMethodReturn(msg.allocator, msg);
                    errdefer reply.deinit();
                    var b = reply.builder();
                    try b.appendString(pin);
                    return reply;
                } else {
                    return try createRejectReply(msg, "PIN code entry rejected by user");
                }
            } else {
                return try createRejectReply(msg, "No PIN code callback configured");
            }
        }

        // Any other unknown / unhandled method on org.bluez.Agent1 MUST be rejected
        return try createRejectReply(msg, "Unhandled Agent1 method rejected");
    }

    /// Handles incoming D-Bus requests from BlueZ to this agent.
    /// Returns true if the message was destined for this agent and handled.
    pub fn processMessage(self: *Agent, msg: *const Message) AgentError!bool {
        if (try self.handleRequest(msg)) |reply_val| {
            var reply = reply_val;
            defer reply.deinit();
            if (builtin.os.tag == .linux) {
                try self.conn.send(&reply);
            }
            return true;
        }
        return false;
    }
};

// ============================================================================
// Unit Tests & Security Verification Suite
// ============================================================================

fn buildTestAgentCall(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    iface: [:0]const u8,
    member: [:0]const u8,
    dev_path: ?[:0]const u8,
    u32_arg: ?u32,
    str_arg: ?[:0]const u8,
) !Message {
    var msg = try Message.createMethodCall(allocator, "org.bluez", path, iface, member);
    errdefer msg.deinit();
    var b = msg.builder();
    if (dev_path) |dp| try b.appendObjectPath(dp);
    if (u32_arg) |v| try b.appendUInt32(v);
    if (str_arg) |s| try b.appendString(s);

    const raw = try msg.finalize(42);
    const fixed_hdr = try wire.FixedHeader.decode(raw[0..16]);
    const hf = try wire.HeaderFields.parse(raw, fixed_hdr.fields_len);
    msg.fixed_header = fixed_hdr;
    msg.header_fields = hf;
    return msg;
}

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

test "Agent: unhandled requests are always rejected (default-deny security policy)" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};
    var agent = Agent.init(&dummy_conn, "/org/zig_ble/agent", .keyboard_display);
    const valid_dev = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF";

    // 1. Unhandled RequestConfirmation -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
            valid_dev,
            123456,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }

    // 2. Unhandled RequestAuthorization -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestAuthorization,
            valid_dev,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }

    // 3. Unhandled AuthorizeService -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.AuthorizeService,
            valid_dev,
            null,
            "0000180d-0000-1000-8000-00805f9b34fb",
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }

    // 4. Unhandled RequestPasskey (even with auto_accept = true!) -> Rejected
    agent.callbacks.auto_accept = true;
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestPasskey,
            valid_dev,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }

    // 5. Unhandled RequestPinCode (even with auto_accept = true!) -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestPinCode,
            valid_dev,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }

    // 6. Unknown method on org.bluez.Agent1 -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            "BackdoorUnlockMethod",
            valid_dev,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
        try std.testing.expectEqualStrings("org.bluez.Error.Rejected", reply.getErrorName().?);
    }
}

test "Agent: malicious D-Bus messages (missing args, invalid paths, out-of-range passkey, signal spoofing)" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};

    const Callbacks = struct {
        fn acceptAll(_: [:0]const u8, _: u32, _: ?*anyopaque) bool {
            return true;
        }
        fn badPasskey(_: [:0]const u8, _: ?*anyopaque) ?u32 {
            return 9_999_999; // Invalid > 999,999
        }
        fn badPin(_: [:0]const u8, _: ?*anyopaque) ?[:0]const u8 {
            return "12345678901234567"; // Invalid > 16 bytes
        }
    };

    var agent = Agent.initWithCallbacks(&dummy_conn, "/org/zig_ble/agent", .keyboard_display, .{
        .request_confirmation = Callbacks.acceptAll,
        .request_passkey = Callbacks.badPasskey,
        .request_pin_code = Callbacks.badPin,
        .auto_accept = true,
    });

    // 1. Signal spoofing an Agent1 method call -> ignored (returns null)
    {
        var spoofed_sig = try Message.createSignal(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
        );
        defer spoofed_sig.deinit();
        const raw = try spoofed_sig.finalize(99);
        spoofed_sig.fixed_header = try wire.FixedHeader.decode(raw[0..16]);
        spoofed_sig.header_fields = try wire.HeaderFields.parse(raw, spoofed_sig.fixed_header.fields_len);

        const res = try agent.handleRequest(&spoofed_sig);
        try std.testing.expect(res == null);
    }

    // 2. Empty body on RequestConfirmation (missing device path and passkey) -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
            null,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }

    // 3. Path traversal / non-BlueZ object path -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
            "/org/evil/attacker_dev",
            123456,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }

    // 4. Out-of-range passkey (> 999,999) in incoming RequestConfirmation -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
            1_000_000,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }

    // 5. Malformed service UUID in AuthorizeService -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.AuthorizeService,
            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
            null,
            "not_a_valid_uuid_string!",
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }

    // 6. Callback returning out-of-range passkey -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestPasskey,
            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }

    // 7. Callback returning >16 byte PIN code -> Rejected
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestPinCode,
            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.error_reply, reply.fixed_header.msg_type);
    }
}

test "Agent: valid callback acceptance for Passkey, Confirmation, and Service Authorization" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};

    const ValidCallbacks = struct {
        fn onPasskey(_: [:0]const u8, _: ?*anyopaque) ?u32 {
            return 654321;
        }
        fn onConfirm(_: [:0]const u8, passkey: u32, _: ?*anyopaque) bool {
            return passkey == 654321;
        }
        fn onAuthorizeService(_: [:0]const u8, uuid: [:0]const u8, _: ?*anyopaque) bool {
            return std.mem.eql(u8, uuid, "0000180d-0000-1000-8000-00805f9b34fb");
        }
    };

    var agent = Agent.initWithCallbacks(
        &dummy_conn,
        "/org/zig_ble/agent",
        .keyboard_display,
        .{
            .request_passkey = ValidCallbacks.onPasskey,
            .request_confirmation = ValidCallbacks.onConfirm,
            .authorize_service = ValidCallbacks.onAuthorizeService,
        },
    );

    const valid_dev = "/org/bluez/hci0/dev_11_22_33_44_55_66";

    // Valid RequestPasskey -> method_return with 654321
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestPasskey,
            valid_dev,
            null,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.method_return, reply.fixed_header.msg_type);
    }

    // Valid RequestConfirmation with matching passkey -> method_return
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.RequestConfirmation,
            valid_dev,
            654321,
            null,
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.method_return, reply.fixed_header.msg_type);
    }

    // Valid AuthorizeService -> method_return
    {
        var req = try buildTestAgentCall(
            std.testing.allocator,
            "/org/zig_ble/agent",
            BlueZ.Agent1.interface_name,
            BlueZ.Agent1.Methods.AuthorizeService,
            valid_dev,
            null,
            "0000180d-0000-1000-8000-00805f9b34fb",
        );
        defer req.deinit();

        var reply = (try agent.handleRequest(&req)).?;
        defer reply.deinit();
        try std.testing.expectEqual(wire.MessageType.method_return, reply.fixed_header.msg_type);
    }
}
