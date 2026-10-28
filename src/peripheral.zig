//! Zig-BLE Unified Peripheral: Combines BLE advertising, GATT server, and pairing agent
//! into a turnkey, highly efficient, zero-allocation peripheral abstraction.
//! Supports both Linux (BlueZ D-Bus) and Windows (WinRT GattServiceProvider + BluetoothLEAdvertisementPublisher).

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/mod.zig");
const UUID = core.UUID;
const log = std.log.scoped(.zig_ble);

const wire = @import("dbus/wire/mod.zig");
const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else wire.NonLinuxConnection;
const Message = if (builtin.os.tag == .linux) dbus.Message else wire.Message;

const advertising = @import("advertising.zig");
pub const AdvertisementConfig = advertising.AdvertisementConfig;
pub const Advertisement = advertising.Advertisement;

const gatt_server = @import("gatt_server.zig");
pub const GattApplication = gatt_server.GattApplication;
pub const ServerService = gatt_server.ServerService;
pub const ServerCharacteristic = gatt_server.ServerCharacteristic;
pub const ServerCharacteristicFlags = gatt_server.ServerCharacteristicFlags;
pub const ServerDescriptor = gatt_server.ServerDescriptor;
pub const ServerDescriptorFlags = gatt_server.ServerDescriptorFlags;

const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;
pub const AgentCapability = agent_mod.AgentCapability;

pub const PeripheralOptions = struct {
    enable_agent: bool = true,
    agent_capability: AgentCapability = .no_input_no_output,
    app_path: [:0]const u8 = "/org/zig_ble/app0",
    adv_path: [:0]const u8 = "/org/zig_ble/advertisement0",
    agent_path: [:0]const u8 = "/org/zig_ble/agent",
};

pub const Peripheral = struct {
    conn: *Connection,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,

    advertisement: Advertisement,
    gatt_app: GattApplication,
    agent: Agent,
    enable_agent: bool,
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        conn: *Connection,
        adapter_path: [:0]const u8,
        adv_config: AdvertisementConfig,
        options: PeripheralOptions,
    ) Peripheral {
        var p = Peripheral{
            .conn = conn,
            .advertisement = Advertisement.init(conn, adapter_path, options.adv_path, adv_config),
            .gatt_app = GattApplication.init(conn, adapter_path, options.app_path),
            .agent = Agent.init(conn, options.agent_path, options.agent_capability),
            .enable_agent = options.enable_agent,
            .is_running = std.atomic.Value(bool).init(false),
            .thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        const len = @min(p.adapter_path.len - 1, adapter_path.len);
        @memcpy(p.adapter_path[0..len], adapter_path[0..len]);
        p.adapter_path[len] = 0;
        p.adapter_path_len = @intCast(len);

        return p;
    }

    pub fn addService(self: *Peripheral, uuid: UUID, primary: bool) !*ServerService {
        return self.gatt_app.createService(uuid, primary);
    }

    /// Starts all peripheral components:
    /// 1. Registers GATT server application (services & characteristics in BlueZ or WinRT ATT database)
    /// 2. Registers BLE advertisement (controller transmits beacons over the air)
    /// 3. Registers pairing agent (on Linux BlueZ)
    pub fn start(self: *Peripheral) !void {
        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.NotSupported;

        // 1. Register GATT server
        try self.gatt_app.register();

        // 2. Start BLE advertisement
        self.advertisement.register() catch |err| {
            self.gatt_app.unregister() catch |unreg_err| {
                log.warn("Peripheral rollback gatt_app.unregister failed: {s}", .{@errorName(unreg_err)});
            };
            return err;
        };

        // 3. Start pairing agent (if enabled on Linux)
        if (builtin.os.tag == .linux and self.enable_agent) {
            self.agent.register() catch |err| {
                log.warn("Peripheral agent.register failed: {s}", .{@errorName(err)});
            };
        }

        self.is_running.store(true, .release);
    }

    fn threadWorker(self: *Peripheral) void {
        while (!self.should_stop.load(.acquire)) {
            self.step(50) catch |err| {
                log.warn("Peripheral worker step error: {s}", .{@errorName(err)});
            };
        }
    }

    /// Starts the peripheral synchronously (GATT + Adv + Agent) and offloads the event loop
    /// to a dedicated background worker thread (std.Thread).
    /// The main thread remains completely unblocked!
    pub fn startBackground(self: *Peripheral) !void {
        try self.start();
        self.should_stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadWorker, .{self});
    }

    /// Runs a single D-Bus / WinRT event loop step (timeout in milliseconds).
    /// Processes incoming client requests (read, write, notify, pairing, advertising).
    pub fn step(self: *Peripheral, timeout_ms: i32) !void {
        if (!self.is_running.load(.acquire)) return;

        if (builtin.os.tag == .windows) {
            // WinRT GATT & Advertising events are dispatched on the MTA thread pool via COM handlers.
            std.atomic.spinLoopHint();
            return;
        }
        if (builtin.os.tag != .linux) return error.NotSupported;

        _ = self.conn.pollSocket(timeout_ms);
        while (self.conn.popMessage()) |msg| {
            defer msg.deinit();

            // 1. Forward to GATT server
            const gatt_handled = self.gatt_app.processMessage(&msg) catch |err| blk: {
                log.warn("Peripheral gatt_app.processMessage error: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (gatt_handled) continue;

            // 2. Forward to advertisement
            const adv_handled = self.advertisement.processMessage(&msg) catch |err| blk: {
                log.warn("Peripheral advertisement.processMessage error: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (adv_handled) continue;

            // 3. Forward to agent
            if (self.enable_agent) {
                const agent_handled = self.agent.processMessage(&msg) catch |err| blk: {
                    log.warn("Peripheral agent.processMessage error: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (agent_handled) continue;
            }
        }
    }

    /// Gracefully shuts down the peripheral, stops the background thread, and releases all BlueZ / WinRT resources.
    pub fn stop(self: *Peripheral) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        if (builtin.os.tag != .linux and builtin.os.tag != .windows) return;
        if (!self.is_running.load(.acquire)) return;

        if (builtin.os.tag == .linux and self.enable_agent) {
            self.agent.unregister() catch |err| {
                log.warn("Peripheral agent.unregister error: {s}", .{@errorName(err)});
            };
        }
        self.advertisement.unregister() catch |err| {
            log.warn("Peripheral advertisement.unregister error: {s}", .{@errorName(err)});
        };
        self.gatt_app.unregister() catch |err| {
            log.warn("Peripheral gatt_app.unregister error: {s}", .{@errorName(err)});
        };

        self.is_running.store(false, .release);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Peripheral: initialization with config" {
    var dummy_conn: Connection = if (builtin.os.tag == .linux) .{
        .allocator = std.testing.allocator,
        .socket = .{ .fd = -1 },
        .incoming_queue = .{},
    } else .{};
    var p = Peripheral.init(&dummy_conn, "/org/bluez/hci0", .{
        .local_name = "Test-Device",
    }, .{});
    try std.testing.expectEqualStrings("/org/bluez/hci0", p.adapter_path[0..p.adapter_path_len]);
    try std.testing.expect(!p.is_running.load(.acquire));

    const svc = try p.addService(UUID.from16(0x180D), true);
    const ch = try svc.addCharacteristic(UUID.from16(0x2A37), .{ .read = true, .notify = true });
    ch.setValue(&[_]u8{ 0x00, 72 });
    try std.testing.expectEqual(@as(usize, 2), ch.getValue().len);
}
