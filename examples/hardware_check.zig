//! # Hardware check for the native backends (Windows WinRT, Linux BlueZ)
//!
//! Build it with `zig build hardware-check` and start `zig-out/bin/ble-hardware-check` directly:
//! pairing prompts read from the terminal.
//!
//!   ble-hardware-check                          scan only (listens)
//!   ble-hardware-check <addr>                   connect, read everything, subscribe (a CCCD
//!                                               write that ends with the connection), hold 30 s
//!   ble-hardware-check <addr> --service <uuid> [mode]
//!                                               any mode below, limited to one service
//!   ble-hardware-check <addr> --resubscribe     auto-resubscribe across a reconnect
//!   ble-hardware-check <addr> --soak <minutes>  connect, read, subscribe, disconnect in a loop
//!   ble-hardware-check <addr> --write <uuid> <hex> [--no-response]
//!                                               CHANGES the value of that characteristic
//!   ble-hardware-check <addr> --pair            CHANGES the bond state of both devices
//!   ble-hardware-check <addr> --unpair          removes the bond on this computer
//!   ble-hardware-check --peripheral [seconds] [--secure]
//!                                               run a GATT server with a test service;
//!                                               --secure adds a characteristic that needs pairing
//!
//! Without `--write` or `--pair` no characteristic value is written and no bond is created.
//! Use these two only with devices of your own whose state you may change, e.g. a second
//! computer running `--peripheral` or a phone running a GATT server.

const std = @import("std");
const builtin = @import("builtin");
const ble = @import("Zig_BLE");

const UUID = ble.UUID;
const Native = switch (builtin.os.tag) {
    .windows => ble.WindowsBackend,
    .linux => ble.BluezBackend,
    else => @compileError("hardware_check needs the Windows or Linux backend"),
};

const Queue = ble.EventQueue(.{ .capacity = 256 });
const scan_seconds = 15;
const idle_seconds = 30;
const resubscribe_seconds = 15;
const soak_hold_seconds = 10;
const default_peripheral_seconds = 300;

const usage =
    \\Usage: ble-hardware-check [<address> [--service <uuid>] [--resubscribe | --soak <minutes>
    \\                           | --write <uuid> <hex> [--no-response] | --pair | --unpair]]
    \\       ble-hardware-check --peripheral [seconds] [--secure]
    \\
;

const Action = union(enum) {
    inspect,
    resubscribe,
    soak: u32,
    write: struct { uuid: UUID, data: []const u8, with_response: bool },
    pair,
    unpair,
};

var native: Native = .{};
var queue: Queue = .{};
var io: std.Io = undefined;
var scan_filter: ble.ScanFilter = .{};
var filter_uuid: [1]UUID = undefined;
/// `--service`: scan for and use only this service.
var service_filter: ?UUID = null;
var daemon_restarted: std.atomic.Value(bool) = .init(false);

const Seen = struct {
    devices: [128]ble.DiscoveredDevice = undefined,
    reports: [128]usize = @splat(0),
    len: usize = 0,

    fn update(self: *Seen, dev: *const ble.DiscoveredDevice) void {
        for (self.devices[0..self.len], 0..) |*d, i| {
            if (d.address.eql(dev.address)) {
                d.* = dev.*;
                self.reports[i] += 1;
                return;
            }
        }
        if (self.len == self.devices.len) return;
        self.devices[self.len] = dev.*;
        self.reports[self.len] = 1;
        self.len += 1;
    }

    fn reportsOf(self: *const Seen, addr: ble.Address) usize {
        for (self.devices[0..self.len], self.reports[0..self.len]) |*d, reports| {
            if (d.address.eql(addr)) return reports;
        }
        return 0;
    }
};

var seen: Seen = .{};

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Handles queued events and returns the number of notifications among them.
fn drain() usize {
    var notifications: usize = 0;
    while (queue.next()) |event| switch (event) {
        .device_discovered => |*d| seen.update(d),
        .notification => |*n| {
            notifications += 1;
            print("  notification {f}: {x}", .{ n.uuid, n.value() });
        },
        .connection => |c| switch (c) {
            .connected => print("  event: connected", .{}),
            .disconnected => |d| print("  event: disconnected, reason {?x}", .{d.reason_code}),
            .parameters_updated => {},
        },
    };
    return notifications;
}

/// Delivers events for `seconds` and returns the number of notifications.
fn hold(adapter: *ble.UnifiedAdapter, seconds: u32) !usize {
    var notifications: usize = 0;
    for (0..seconds * 10) |_| {
        notifications += drain();
        try adapter.processEvents(100);
    }
    return notifications + drain();
}

fn scan(adapter: *ble.UnifiedAdapter) !void {
    print("Scanning for {d} s ...", .{scan_seconds});
    try queue.startScan(adapter, scan_filter);
    _ = try hold(adapter, scan_seconds);
    try adapter.stopScan();
    _ = drain();

    var named: usize = 0;
    var with_mfg: usize = 0;
    var with_uuids: usize = 0;
    var random: usize = 0;
    var with_tx: usize = 0;
    print("\n{s: <17}  {s: <6}  {s: >4}  {s: >7}  {s: <6}  {s: <5}  name", .{ "address", "type", "rssi", "reports", "mfg", "uuids" });
    for (seen.devices[0..seen.len], seen.reports[0..seen.len]) |*d, reports| {
        if (d.getName() != null) named += 1;
        if (d.company_id != null) with_mfg += 1;
        if (d.service_uuids_len > 0) with_uuids += 1;
        if (d.address_type != .public) random += 1;
        if (d.tx_power != null) with_tx += 1;
        const addr = d.address.toString();
        var mfg_buf: [6]u8 = undefined;
        const mfg = if (d.company_id) |c| std.fmt.bufPrint(&mfg_buf, "0x{X:0>4}", .{c}) catch "?" else "-";
        print("{s}  {s: <6}  {d: >4}  {d: >7}  {s: <6}  {d: >5}  {s}", .{
            &addr,
            if (d.address_type == .public) "public" else "random",
            d.rssi orelse 0,
            reports,
            mfg,
            d.service_uuids_len,
            d.getName() orelse "",
        });
    }
    print("\nScan: {d} devices, {d} with name, {d} with manufacturer data, {d} with service UUIDs, {d} with TX power, {d} random addresses, {d} events dropped", .{
        seen.len, named, with_mfg, with_uuids, with_tx, random, queue.dropped,
    });
}

/// Scans until `addr` advertises again. BlueZ forgets unconnected devices after a while,
/// so it needs this before every reconnect.
fn scanFor(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    const before = seen.reportsOf(addr);
    try queue.startScan(adapter, scan_filter);
    for (0..100) |_| {
        _ = drain();
        if (seen.reportsOf(addr) > before) break;
        try adapter.processEvents(100);
    } else print("  {f} did not advertise within 10 s", .{addr});
    try adapter.stopScan();
}

fn connect(adapter: *ble.UnifiedAdapter, addr: ble.Address) !ble.UnifiedDevice {
    print("\nConnecting to {f} ...", .{addr});
    var dev = try adapter.connect(addr, 30_000);
    errdefer dev.disconnect() catch {};
    print("Connected, bond state: {t}", .{dev.getBondState()});
    if (service_filter) |uuid| try dev.discoverServicesFiltered(&.{uuid});
    return dev;
}

/// Reads every characteristic and optionally subscribes to the notifying ones.
/// Returns the number of subscriptions.
fn visitCharacteristics(dev: *ble.UnifiedDevice, subscribe: bool) !usize {
    var infos: [64]ble.CharacteristicInfo = undefined;
    const n = try dev.getCharacteristics(&infos);
    print("\n{d} characteristics:", .{n});

    var subscribed: usize = 0;
    var descriptor_checked = false;
    var buf: [64]u8 = undefined;
    for (infos[0..n]) |info| {
        const sel = info.selector();
        var line_buf: [96]u8 = undefined;
        const value = if (dev.readCharacteristic(sel, &buf)) |len|
            std.fmt.bufPrint(&line_buf, "read {x}", .{buf[0..len]}) catch "read ok"
        else |err|
            @errorName(err);
        var sub: []const u8 = "";
        if (subscribe) {
            if (queue.subscribe(dev, sel)) |_| {
                subscribed += 1;
                sub = ", subscribed";
            } else |_| {}
        }
        print("  {f} / {f} #{d}: {s}{s}", .{ info.service_uuid, info.uuid, info.instance, value, sub });

        // A subscribed characteristic has a CCCD: 01 00 = notify, 02 00 = indicate.
        if (subscribed > 0 and !descriptor_checked) {
            descriptor_checked = true;
            var cccd: [2]u8 = undefined;
            if (dev.readDescriptor(sel, UUID.from16(0x2902), &cccd)) |len| {
                print("  CCCD of {f}: {x}", .{ info.uuid, cccd[0..len] });
            } else |err| print("  CCCD of {f}: {s}", .{ info.uuid, @errorName(err) });
        }
    }
    return subscribed;
}

fn checkDevice(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    if (seen.reportsOf(addr) == 0) print("Note: {f} was not seen while scanning.", .{addr});

    var dev = try connect(adapter, addr);
    defer dev.disconnect() catch {};

    if (dev.exchangeMtu(247)) |mtu| {
        print("MTU: {d}", .{mtu});
    } else |err| print("MTU: {s}", .{@errorName(err)});

    const subscribed = try visitCharacteristics(&dev, true);

    print("\nStaying connected for {d} s without GATT traffic ({d} subscriptions) ...", .{ idle_seconds, subscribed });
    const notifications = try hold(adapter, idle_seconds);
    print("After {d} s: connected = {}, {d} notifications", .{ idle_seconds, dev.isConnected(), notifications });
}

fn checkResubscribe(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    var dev = try connect(adapter, addr);
    dev.setAutoResubscribe(true);
    const subscribed = try visitCharacteristics(&dev, true);
    print("\nWaiting {d} s for notifications on {d} subscriptions ...", .{ resubscribe_seconds, subscribed });
    const first = try hold(adapter, resubscribe_seconds);

    try dev.disconnect();
    print("Disconnected, reconnecting without subscribing again.", .{});
    try scanFor(adapter, addr);
    var again = try connect(adapter, addr);
    defer {
        again.setAutoResubscribe(false);
        again.disconnect() catch {};
    }
    const active = try countActiveCccds(&again);
    const second = try hold(adapter, resubscribe_seconds);

    print("\nSubscriptions: {d} before the reconnect, {d} active on the peer after it.", .{ subscribed, active });
    print("Notifications: {d} before the reconnect, {d} after it.", .{ first, second });
    if (active < subscribed) print("FAILED: the subscriptions did not survive the reconnect.", .{});
}

/// Reads the CCCD of every characteristic that has one: the peer's own record of who
/// subscribed, independent of whether notifications get through.
fn countActiveCccds(dev: *ble.UnifiedDevice) !usize {
    var infos: [64]ble.CharacteristicInfo = undefined;
    const n = try dev.getCharacteristics(&infos);
    var active: usize = 0;
    for (infos[0..n]) |info| {
        var cccd: [2]u8 = undefined;
        const len = dev.readDescriptor(info.selector(), UUID.from16(0x2902), &cccd) catch continue;
        print("  CCCD of {f} after the reconnect: {x}", .{ info.uuid, cccd[0..len] });
        if (len > 0 and cccd[0] & 0x03 != 0) active += 1;
    }
    return active;
}

/// Open handles of this process. Rising values over a soak run mean a handle leak.
fn handleCount() ?u32 {
    if (builtin.os.tag != .windows) return null;
    const kernel32 = struct {
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
        extern "kernel32" fn GetProcessHandleCount(process: std.os.windows.HANDLE, count: *u32) callconv(.winapi) c_int;
    };
    var count: u32 = 0;
    if (kernel32.GetProcessHandleCount(kernel32.GetCurrentProcess(), &count) == 0) return null;
    return count;
}

fn soakCycle(adapter: *ble.UnifiedAdapter, addr: ble.Address) !usize {
    try scanFor(adapter, addr);
    var dev = try adapter.connect(addr, 30_000);
    defer dev.disconnect() catch {};
    if (service_filter) |uuid| try dev.discoverServicesFiltered(&.{uuid});
    _ = try visitCharacteristics(&dev, true);
    const notifications = try hold(adapter, soak_hold_seconds);
    if (!dev.isConnected()) return error.ConnectionLost;
    return notifications;
}

fn soak(adapter: *ble.UnifiedAdapter, addr: ble.Address, minutes: u32) !void {
    const start = std.Io.Timestamp.now(io, .awake);
    const end_seconds = @as(i64, minutes) * 60;
    var cycles: usize = 0;
    var failures: usize = 0;
    var notifications: usize = 0;
    const handles_at_start = handleCount();

    print("Soak test for {d} min. On Linux, `sudo systemctl restart bluetooth` during the run tests the recovery.", .{minutes});
    while (start.durationTo(std.Io.Timestamp.now(io, .awake)).toSeconds() < end_seconds) {
        cycles += 1;
        if (soakCycle(adapter, addr)) |count| {
            notifications += count;
        } else |err| {
            failures += 1;
            print("Cycle {d} failed: {s}", .{ cycles, @errorName(err) });
            _ = try hold(adapter, 2);
        }
        if (builtin.os.tag == .linux and daemon_restarted.swap(false, .acq_rel)) {
            print("bluetoothd restarted, recovering ...", .{});
            if (native.recoverAfterDaemonRestart()) |_| {
                print("Recovered.", .{});
            } else |err| print("Recovery failed: {s}", .{@errorName(err)});
        }
        print("Cycle {d}: {d} failed, {d} notifications, handles {?d}, {d} events dropped", .{ cycles, failures, notifications, handleCount(), queue.dropped });
    }
    print("\nSoak: {d} cycles, {d} failed, {d} notifications, handles {?d} -> {?d}, {d} events dropped", .{
        cycles, failures, notifications, handles_at_start, handleCount(), queue.dropped,
    });
}

fn checkWrite(adapter: *ble.UnifiedAdapter, addr: ble.Address, uuid: UUID, data: []const u8, with_response: bool) !void {
    var dev = try connect(adapter, addr);
    defer dev.disconnect() catch {};

    var buf: [247]u8 = undefined;
    if (dev.readCharacteristic(uuid, &buf)) |len| {
        print("Before: {x}", .{buf[0..len]});
    } else |err| print("Before: {s}", .{@errorName(err)});

    try dev.writeCharacteristic(uuid, data, with_response);
    print("Wrote {x} ({s}).", .{ data, if (with_response) "with response" else "without response" });

    // A write without response has no acknowledgement to wait for.
    if (!with_response) _ = try hold(adapter, 1);
    if (dev.readCharacteristic(uuid, &buf)) |len| {
        const same = std.mem.eql(u8, buf[0..len], data);
        print("After:  {x} ({s})", .{ buf[0..len], if (same) "matches" else "differs" });
    } else |err| print("After:  {s}", .{@errorName(err)});
}

// ---- Pairing prompts ------------------------------------------------------------------------

/// Reads one line from the terminal. Null on end of input: the prompt then counts as declined.
fn askLine(buf: []u8) ?[]const u8 {
    var buffers = [_][]u8{buf};
    const n = std.Io.File.stdin().readStreaming(io, &buffers) catch return null;
    if (n == 0) return null;
    // Piped answers can arrive several lines at once; the first one answers this prompt.
    const line = std.mem.sliceTo(buf[0..n], '\n');
    return std.mem.trim(u8, line, " \t\r");
}

fn askYesNo() bool {
    var buf: [16]u8 = undefined;
    const answer = askLine(&buf) orelse return false;
    return std.ascii.eqlIgnoreCase(answer, "y");
}

fn promptConfirm(value: ?u32, _: ?*anyopaque) bool {
    if (value) |number| {
        print(">>> Does the other device show {d:0>6}? [y/N]", .{number});
    } else print(">>> Pair without a code (Just Works)? [y/N]", .{});
    return askYesNo();
}

fn promptPasskey(_: ?*anyopaque) ?u32 {
    print(">>> Enter the 6-digit code shown on the other device:", .{});
    var buf: [16]u8 = undefined;
    const line = askLine(&buf) orelse return null;
    return std.fmt.parseInt(u32, line, 10) catch null;
}

fn showPasskey(passkey: u32, _: ?*anyopaque) void {
    print(">>> Enter {d:0>6} on the other device.", .{passkey});
}

const agent_callbacks = struct {
    fn requestPasskey(_: [:0]const u8, user_data: ?*anyopaque) ?u32 {
        return promptPasskey(user_data);
    }
    fn requestConfirmation(_: [:0]const u8, passkey: u32, user_data: ?*anyopaque) bool {
        return promptConfirm(passkey, user_data);
    }
    fn requestAuthorization(_: [:0]const u8, user_data: ?*anyopaque) bool {
        return promptConfirm(null, user_data);
    }
    fn authorizeService(_: [:0]const u8, uuid: [:0]const u8, _: ?*anyopaque) bool {
        print(">>> Allow access to service {s}? [y/N]", .{uuid});
        return askYesNo();
    }
    fn displayPasskey(_: [:0]const u8, passkey: u32, user_data: ?*anyopaque) void {
        showPasskey(passkey, user_data);
    }
    fn displayPinCode(_: [:0]const u8, pin: [:0]const u8, _: ?*anyopaque) void {
        print(">>> Enter {s} on the other device.", .{pin});
    }
};

fn installAgentCallbacks(agent: *ble.Agent) void {
    agent.setCallbacks(.{
        .request_passkey = agent_callbacks.requestPasskey,
        .request_confirmation = agent_callbacks.requestConfirmation,
        .request_authorization = agent_callbacks.requestAuthorization,
        .authorize_service = agent_callbacks.authorizeService,
        .display_passkey = agent_callbacks.displayPasskey,
        .display_pin_code = agent_callbacks.displayPinCode,
    });
}

/// BlueZ asks an agent during `Device1.Pair`, which blocks the backend's connection. The agent
/// therefore needs its own connection and thread.
const PairingAgent = struct {
    conn: ble.Connection = undefined,
    agent: ble.Agent = undefined,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = .init(false),

    fn start(self: *PairingAgent) !void {
        self.conn = try ble.Connection.initSystem();
        errdefer self.conn.deinit();
        self.agent = ble.Agent.init(&self.conn, "/org/zig_ble/hardware_check_agent", .keyboard_display);
        installAgentCallbacks(&self.agent);
        try self.agent.register();
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn worker(self: *PairingAgent) void {
        while (!self.should_stop.load(.acquire)) {
            _ = self.conn.pollSocket(50);
            while (self.conn.popMessage()) |msg| {
                defer msg.deinit();
                _ = self.agent.processMessage(&msg) catch |err| {
                    print("Agent error: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn stop(self: *PairingAgent) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.agent.unregister() catch |err| print("Agent unregister: {s}", .{@errorName(err)});
        self.conn.deinit();
    }
};

var pairing_agent: PairingAgent = .{};

fn checkPair(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    if (builtin.os.tag == .linux) {
        try pairing_agent.start();
    } else {
        native.setPairingCallbacks(.{
            .on_confirm = promptConfirm,
            .on_request_passkey = promptPasskey,
            .on_display_passkey = showPasskey,
        });
    }
    defer if (builtin.os.tag == .linux) pairing_agent.stop();

    var dev = try connect(adapter, addr);
    print("Pairing ...", .{});
    dev.pair(.keyboard_display) catch |err| {
        print("Pairing failed: {s}, bond state: {t}", .{ @errorName(err), dev.getBondState() });
        dev.disconnect() catch {};
        return err;
    };
    print("Paired, bond state: {t}", .{dev.getBondState()});
    _ = try visitCharacteristics(&dev, false);
    try dev.disconnect();

    print("\nReconnecting: the bond must survive this.", .{});
    try scanFor(adapter, addr);
    var again = try connect(adapter, addr);
    defer again.disconnect() catch {};
    _ = try visitCharacteristics(&again, false);
    print("\nBond state after the reconnect: {t}. Remove it with --unpair.", .{again.getBondState()});
}

fn checkUnpair(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    var dev = try connect(adapter, addr);
    defer dev.disconnect() catch {};
    try dev.unpair();
    print("Unpaired.", .{});
}

// ---- Peripheral -----------------------------------------------------------------------------

const test_service = UUID.parse("5a1e0001-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const echo_char = UUID.parse("5a1e0002-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const counter_char = UUID.parse("5a1e0003-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const protected_char = UUID.parse("5a1e0004-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;

var peripheral: ble.Peripheral = undefined;

fn onEchoWrite(_: *ble.ServerCharacteristic, data: []const u8, _: ?*anyopaque) void {
    print("  echo written: {x}", .{data});
}

fn onCounterNotifyState(_: *ble.ServerCharacteristic, enabled: bool, _: ?*anyopaque) void {
    print("  counter notifications {s}", .{if (enabled) "enabled" else "disabled"});
}

fn runPeripheral(seconds: u32, secure: bool) !void {
    var conn: ble.Connection = if (builtin.os.tag == .linux) try ble.Connection.initSystem() else .{};
    defer conn.deinit();

    var adapter_path: [:0]const u8 = "/";
    if (builtin.os.tag == .linux) {
        const adapter = (try ble.Adapter.findDefault(&conn)) orelse return error.AdapterNotFound;
        adapter_path = adapter.getObjectPath();
    }

    peripheral = ble.Peripheral.init(&conn, adapter_path, .{
        .local_name = "Zig-BLE-Check",
        .service_uuids = &.{test_service},
        .includes = .{ .tx_power = false },
        // WinRT advertises the service itself; its publisher needs some content of its own.
        .manufacturer_data = if (builtin.os.tag == .windows) .{ .company_id = 0xFFFF, .data = &.{0x5A} } else null,
    }, .{ .agent_capability = .keyboard_display });
    installAgentCallbacks(&peripheral.agent);

    const service = try peripheral.addService(test_service, true);
    const echo = try service.addCharacteristic(echo_char, .{ .read = true, .write = true, .write_without_response = true });
    echo.setValue("echo");
    echo.write_handler = onEchoWrite;
    const counter = try service.addCharacteristic(counter_char, .{ .read = true, .notify = true });
    counter.setValue(&.{ 0, 0, 0, 0 });
    counter.notify_handler = onCounterNotifyState;
    // Reading it makes the central pair first. BlueZ starts that on its own, so the plain checks
    // run without it.
    if (secure) {
        const protected = try service.addCharacteristic(protected_char, .{ .encrypt_read = true });
        protected.setValue("paired");
    }

    try peripheral.startBackground();
    defer peripheral.stop();

    print("Advertising as Zig-BLE-Check for {d} s.", .{seconds});
    print("  service   {f}", .{test_service});
    print("  echo      {f}  read, write, write without response", .{echo_char});
    print("  counter   {f}  read, notify (every second)", .{counter_char});
    if (secure) print("  protected {f}  read needs pairing", .{protected_char});

    var count: u32 = 0;
    var last_subs: ble.ServerCharacteristic.Subscribers = .{ .total = 0, .active = 0 };
    for (0..seconds) |_| {
        try io.sleep(.fromSeconds(1), .awake);
        count += 1;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, count, .little);
        const sent_at = std.Io.Timestamp.now(io, .awake);
        counter.notify(&conn, &bytes) catch |err| print("  notify: {s}", .{@errorName(err)});
        const took_ms = sent_at.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        if (took_ms > 500) print("  notify took {d} ms", .{took_ms});
        const subs = counter.subscribers();
        if (subs.total != last_subs.total or subs.active != last_subs.active) {
            print("  counter subscribers: {d}, {d} connected", .{ subs.total, subs.active });
            last_subs = subs;
        }
        if (count % 10 == 0) print("  {d} s, echo = {x}", .{ count, echo.getValue() });
    }
    print("Stopping.", .{});
}

// ---- Main -----------------------------------------------------------------------------------

fn onDaemonRestart(_: ?*anyopaque) void {
    daemon_restarted.store(true, .release);
}

fn parseAction(args: anytype, hex_buf: []u8) !Action {
    var arg = args.next() orelse return .inspect;
    if (std.mem.eql(u8, arg, "--service")) {
        service_filter = try UUID.parse(args.next() orelse return error.InvalidArguments);
        arg = args.next() orelse return .inspect;
    }
    if (std.mem.eql(u8, arg, "--resubscribe")) return .resubscribe;
    if (std.mem.eql(u8, arg, "--pair")) return .pair;
    if (std.mem.eql(u8, arg, "--unpair")) return .unpair;
    if (std.mem.eql(u8, arg, "--soak")) {
        return .{ .soak = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArguments, 10) };
    }
    if (std.mem.eql(u8, arg, "--write")) {
        const uuid = try UUID.parse(args.next() orelse return error.InvalidArguments);
        const data = try std.fmt.hexToBytes(hex_buf, args.next() orelse return error.InvalidArguments);
        var with_response = true;
        if (args.next()) |flag| {
            if (!std.mem.eql(u8, flag, "--no-response")) return error.InvalidArguments;
            with_response = false;
        }
        return .{ .write = .{ .uuid = uuid, .data = data, .with_response = with_response } };
    }
    return error.InvalidArguments;
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var target: ?ble.Address = null;
    var hex_buf: [244]u8 = undefined;
    var action: Action = .inspect;
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "--peripheral")) {
            var seconds: u32 = default_peripheral_seconds;
            var secure = false;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--secure")) {
                    secure = true;
                } else seconds = try std.fmt.parseInt(u32, arg, 10);
            }
            return runPeripheral(seconds, secure);
        }
        target = ble.Address.parse(first) catch {
            std.debug.print(usage, .{});
            return error.InvalidArguments;
        };
        action = parseAction(&args, &hex_buf) catch |err| {
            std.debug.print(usage, .{});
            return err;
        };
    }

    const backend = native.asBackend();
    try backend.openAdapter(0);
    defer native.deinit();
    native.setConnectionEventCallback(Queue.onConnectionEvent, &queue);
    if (builtin.os.tag == .linux) native.setDaemonRestartCallback(onDaemonRestart, null);

    var adapter = ble.UnifiedAdapter.init(backend);
    print("Backend: {s}, powered: {}", .{ adapter.getBackendName(), try adapter.isPowered() });

    if (service_filter) |uuid| {
        filter_uuid = .{uuid};
        scan_filter.service_uuids = &filter_uuid;
    }
    try scan(&adapter);
    const addr = target orelse return;
    switch (action) {
        .inspect => try checkDevice(&adapter, addr),
        .resubscribe => try checkResubscribe(&adapter, addr),
        .soak => |minutes| try soak(&adapter, addr, minutes),
        .write => |w| try checkWrite(&adapter, addr, w.uuid, w.data, w.with_response),
        .pair => try checkPair(&adapter, addr),
        .unpair => try checkUnpair(&adapter, addr),
    }
}
