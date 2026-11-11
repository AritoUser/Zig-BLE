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
//!   ble-hardware-check <addr> --disconnect      disconnect and wait until the peer advertises
//!                                               again (a BlueZ peripheral does so only once the
//!                                               link is gone; a Windows one never stops)
//!   ble-hardware-check <addr> --multi <addr2> [<addr3> ...]
//!                                               hold connections to several devices at once;
//!                                               reads and subscribes on <addr> only
//!   ble-hardware-check <addr> --soak <minutes>  connect, read, subscribe, disconnect in a loop
//!   ble-hardware-check <addr> --service <uuid> --suite [rounds]
//!                                               every check that needs no prompt, against a peer
//!                                               running --peripheral: 10 rounds by default, then
//!                                               a table with the passed rounds per check.
//!                                               CHANGES values on the peer
//!   <addr> may be `auto` with --service: the device that advertises that service right now
//!   (a Windows peripheral changes its address every few minutes)
//!   ble-hardware-check <addr> --write <uuid> <hex> [--no-response]
//!                                               CHANGES the value of that characteristic
//!   ble-hardware-check <addr> --write-len <uuid> <bytes> [--no-response]
//!                                               the same with a counting pattern (long writes)
//!   ble-hardware-check <addr> --write-desc <char-uuid> <descriptor-uuid> <hex>
//!                                               CHANGES the value of that descriptor
//!   ble-hardware-check <addr> --pair            CHANGES the bond state of both devices
//!   ble-hardware-check <addr> --await-pair      subscribe and let the peripheral start the
//!                                               pairing (a Windows peer running --peripheral
//!                                               --secure does); CHANGES the bond state
//!   --io none|display|yesno|keyboard|keyboarddisplay
//!                                               before the mode or after --peripheral: this
//!                                               side's pairing capability (default keyboarddisplay)
//!   ble-hardware-check <addr> --unpair          removes the bond on this computer
//!   --answers <file>                            before the mode or after --peripheral: pairing
//!                                               prompts take their answers from the lines of
//!                                               this file instead of the terminal and wait up
//!                                               to 60 s for a script to append the next one
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
/// Room for one stalled attempt: Windows keeps such a link until its 30 s ATT timeout.
const connect_timeout_ms = 60_000;
const resubscribe_seconds = 15;
const disconnect_wait_seconds = 40;
const scan_for_seconds = 10;
const soak_hold_seconds = 10;
const default_peripheral_seconds = 300;

const usage =
    \\Usage: ble-hardware-check [<address>|auto [--service <uuid>] [--resubscribe | --soak <minutes>
    \\                           | --suite [rounds] | --disconnect
    \\                           | --multi <address> [<address> ...]
    \\                           | --write <uuid> <hex> [--no-response] | --write-len <uuid> <bytes>
    \\                           | --write-desc <char-uuid> <descriptor-uuid> <hex> | --pair | --await-pair | --unpair]]
    \\       ble-hardware-check --peripheral [seconds] [--secure] [--io <capability>]
    \\       --io none|display|yesno|keyboard|keyboarddisplay (before the mode)
    \\       --answers <file>: answers to the pairing prompts, one per line (before the mode)
    \\
;

const Action = union(enum) {
    inspect,
    resubscribe,
    disconnect,
    multi,
    soak: u32,
    suite: u32,
    write: struct { uuid: UUID, data: []const u8, with_response: bool },
    write_descriptor: struct { char: UUID, descriptor: UUID, data: []const u8 },
    pair,
    await_pair,
    unpair,
};

var native: Native = .{};
var queue: Queue = .{};
var io: std.Io = undefined;
var scan_filter: ble.ScanFilter = .{};
var filter_uuid: [1]UUID = undefined;
/// `--service`: scan for and use only this service.
var service_filter: ?UUID = null;
/// `--io`: what this side can show or enter when pairing; selects Just Works, Numeric
/// Comparison or Passkey Entry together with the other side's capability.
var io_capability: ble.IoCapability = .keyboard_display;
var daemon_restarted: std.atomic.Value(bool) = .init(false);
/// `--answers`: file the pairing prompts read their answers from, and how many lines are used up.
var answers_path: ?[]const u8 = null;
var answers_used: usize = 0;
/// `--multi`: the devices to hold connected next to the target.
var extra_targets: [7]ble.Address = undefined;
var extra_targets_len: usize = 0;
/// Address `auto`: look the device up by `service_filter` before every connection.
var auto_target = false;
/// `--suite`: do not print every notification.
var quiet = false;
/// Notifications of the test service's counter and indicate characteristics since the last reset.
var counter_seen: usize = 0;
var indicate_seen: usize = 0;
/// What the last `visitCharacteristics` found on the test service.
var visit: struct { indicate_cccd: bool = false, long_ok: bool = false } = .{};

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
            if (n.uuid.eql(counter_char)) counter_seen += 1;
            if (n.uuid.eql(indicate_char)) indicate_seen += 1;
            if (!quiet) print("  notification {f}: {x}", .{ n.uuid, n.value() });
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
fn scanFor(adapter: *ble.UnifiedAdapter, addr: ble.Address, seconds: u32) !void {
    const before = seen.reportsOf(addr);
    try queue.startScan(adapter, scan_filter);
    for (0..seconds * 10) |_| {
        _ = drain();
        if (seen.reportsOf(addr) > before) break;
        try adapter.processEvents(100);
    } else print("  {f} did not advertise within {d} s", .{ addr, seconds });
    try adapter.stopScan();
}

/// The address to connect to next. With a fixed address this waits until the device advertises
/// again; with `auto` it is a device that advertises `service_filter` right now, `fixed` if that
/// one is among them (a Windows peripheral advertises under two addresses at once).
fn locate(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address, seconds: u32) !ble.Address {
    if (!auto_target) {
        const addr = fixed orelse return error.InvalidArguments;
        try scanFor(adapter, addr, seconds);
        return addr;
    }
    var other: ?ble.Address = null;
    var other_since: usize = 0;
    const service = service_filter orelse return error.InvalidArguments;
    const before = seen.reports;
    const known = seen.len;
    try queue.startScan(adapter, scan_filter);
    defer adapter.stopScan() catch {};
    for (0..@max(seconds, 20) * 10) |tick| {
        _ = drain();
        for (seen.devices[0..seen.len], 0..) |*d, i| {
            // Only a device that reported during this scan: old addresses stay in the list.
            if (seen.reports[i] <= (if (i < known) before[i] else 0) or d.rssi == null) continue;
            for (d.getServiceUuids()) |uuid| {
                if (!uuid.eql(service)) continue;
                const wanted = fixed orelse return d.address;
                if (d.address.eql(wanted)) return wanted;
                if (other == null) {
                    other = d.address;
                    other_since = tick;
                }
            }
        }
        // The wanted address gets 5 s more once another one of the peer has shown up.
        if (other) |addr| {
            if (tick - other_since >= 50) return addr;
        }
        try adapter.processEvents(100);
    }
    if (other) |addr| return addr;
    print("  no device advertised {f} within {d} s", .{ service, @max(seconds, 20) });
    return error.DeviceNotFound;
}

fn isCountingPattern(value: []const u8) bool {
    for (value, 0..) |b, i| {
        if (b != @as(u8, @truncate(i))) return false;
    }
    return true;
}

/// Disconnects and frees the queue's subscription slots of that device.
fn drop(dev: *ble.UnifiedDevice) void {
    dev.disconnect() catch {};
    queue.releaseDevice(dev.address);
}

fn connect(adapter: *ble.UnifiedAdapter, addr: ble.Address) !ble.UnifiedDevice {
    print("\nConnecting to {f} ...", .{addr});
    const started = std.Io.Timestamp.now(io, .awake);
    var dev = try adapter.connect(addr, connect_timeout_ms);
    errdefer drop(&dev);
    const took_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    print("Connected after {d} ms, bond state: {t}", .{ took_ms, dev.getBondState() });
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
    var buf: [512]u8 = undefined;
    for (infos[0..n]) |info| {
        const sel = info.selector();
        var line_buf: [96]u8 = undefined;
        const value = if (dev.readCharacteristic(sel, &buf)) |len| blk: {
            if (info.uuid.eql(long_char)) visit.long_ok = len >= 200 and isCountingPattern(buf[0..len]);
            break :blk formatValue(&line_buf, "read", buf[0..len]);
        } else |err| @errorName(err);
        var subscribed_now = false;
        if (subscribe) {
            if (queue.subscribe(dev, sel)) |_| {
                subscribed += 1;
                subscribed_now = true;
            } else |err| {
                // Characteristics that cannot notify fail here; a full queue must not go unnoticed.
                if (err == error.PoolExhausted) print("  subscribing to {f} failed: {s}", .{ info.uuid, @errorName(err) });
            }
        }
        print("  {f} / {f} #{d}: {s}{s}", .{ info.service_uuid, info.uuid, info.instance, value, if (subscribed_now) ", subscribed" else "" });

        // A subscribed characteristic has a CCCD: 01 00 = notify, 02 00 = indicate.
        if (subscribed_now) {
            var cccd: [2]u8 = undefined;
            if (dev.readDescriptor(sel, UUID.from16(0x2902), &cccd)) |len| {
                if (info.uuid.eql(indicate_char)) visit.indicate_cccd = std.mem.eql(u8, cccd[0..len], &.{ 0x02, 0x00 });
                print("    CCCD: {x}", .{cccd[0..len]});
            } else |err| print("    CCCD: {s}", .{@errorName(err)});
        }
    }
    return subscribed;
}

/// "<label> <hex>" for short values, "<label> <n> bytes: <first 16 bytes>..." for long ones.
fn formatValue(out: []u8, label: []const u8, value: []const u8) []const u8 {
    if (value.len <= 32) return std.fmt.bufPrint(out, "{s} {x}", .{ label, value }) catch label;
    return std.fmt.bufPrint(out, "{s} {d} bytes: {x}...", .{ label, value.len, value[0..16] }) catch label;
}

const Inspection = struct {
    held: bool,
    /// Notifications and indications from the test service during the hold.
    counter: usize,
    indications: usize,
    indicate_cccd: bool,
    long_ok: bool,
};

fn checkDevice(adapter: *ble.UnifiedAdapter, addr: ble.Address) !Inspection {
    if (seen.reportsOf(addr) == 0) print("Note: {f} was not seen while scanning.", .{addr});
    visit = .{};

    var dev = try connect(adapter, addr);
    defer drop(&dev);

    if (dev.exchangeMtu(247)) |mtu| {
        print("MTU: {d}", .{mtu});
    } else |err| print("MTU: {s}", .{@errorName(err)});

    const subscribed = try visitCharacteristics(&dev, true);

    print("\nStaying connected for {d} s without GATT traffic ({d} subscriptions) ...", .{ idle_seconds, subscribed });
    counter_seen = 0;
    indicate_seen = 0;
    const notifications = try hold(adapter, idle_seconds);
    const held = dev.isConnected();
    print("After {d} s: connected = {}, {d} notifications", .{ idle_seconds, held, notifications });
    return .{
        .held = held,
        .counter = counter_seen,
        .indications = indicate_seen,
        .indicate_cccd = visit.indicate_cccd,
        .long_ok = visit.long_ok,
    };
}

fn checkResubscribe(adapter: *ble.UnifiedAdapter, addr: ble.Address) !bool {
    var dev = try connect(adapter, addr);
    dev.setAutoResubscribe(true);
    const subscribed = try visitCharacteristics(&dev, true);
    print("\nWaiting {d} s for notifications on {d} subscriptions ...", .{ resubscribe_seconds, subscribed });
    const first = try hold(adapter, resubscribe_seconds);

    try dev.disconnect();
    print("Disconnected, reconnecting without subscribing again.", .{});
    // A peripheral with one advertising set (BlueZ) advertises again once the old link is gone,
    // which Windows takes up to 20 s for; only then is this a new connection.
    const again_addr = try locate(adapter, addr, disconnect_wait_seconds);
    // Subscriptions belong to an address; under a new one the peer is another device.
    if (!again_addr.eql(addr)) {
        dev.setAutoResubscribe(false);
        queue.releaseDevice(addr);
        print("  {f} now advertises as {f}; the check needs the same address.", .{ addr, again_addr });
        return error.AddressChanged;
    }
    var again = try connect(adapter, again_addr);
    defer {
        again.setAutoResubscribe(false);
        drop(&again);
    }
    const active = try countActiveCccds(&again);
    const second = try hold(adapter, resubscribe_seconds);

    print("\nSubscriptions: {d} before the reconnect, {d} active on the peer after it.", .{ subscribed, active });
    print("Notifications: {d} before the reconnect, {d} after it.", .{ first, second });
    if (active < subscribed) print("FAILED: the subscriptions did not survive the reconnect.", .{});
    return subscribed > 0 and active >= subscribed and second > 0;
}

/// Connects to `addr` and to every `--multi` address, uses `addr` like the plain check and
/// passes when all of them are still connected after the hold and `addr` kept notifying.
/// The other devices are only connected and discovered: nothing is read or written there.
fn checkMulti(adapter: *ble.UnifiedAdapter, addr: ble.Address) !bool {
    var devices: [1 + extra_targets.len]ble.UnifiedDevice = undefined;
    var connected: usize = 0;
    defer for (devices[0..connected]) |*d| drop(d);

    devices[0] = try connect(adapter, addr);
    connected = 1;
    for (extra_targets[0..extra_targets_len]) |extra| {
        print("\nConnecting to {f} ...", .{extra});
        devices[connected] = try adapter.connect(extra, connect_timeout_ms);
        connected += 1;
        var infos: [64]ble.CharacteristicInfo = undefined;
        const n = try devices[connected - 1].getCharacteristics(&infos);
        print("Connected, {d} characteristics.", .{n});
    }

    const subscribed = try visitCharacteristics(&devices[0], true);
    print("\nHolding {d} connections for {d} s ({d} subscriptions on {f}) ...", .{ connected, idle_seconds, subscribed, addr });
    const notifications = try hold(adapter, idle_seconds);

    var all = true;
    for (devices[0..connected], 0..) |*d, i| {
        const up = d.isConnected();
        print("  {f}: connected = {}", .{ if (i == 0) addr else extra_targets[i - 1], up });
        all = all and up;
    }
    // The first device must still answer while the others are connected.
    var infos: [64]ble.CharacteristicInfo = undefined;
    const n = try devices[0].getCharacteristics(&infos);
    var buf: [512]u8 = undefined;
    const readable = n > 0 and if (devices[0].readCharacteristic(infos[0].selector(), &buf)) |_| true else |_| false;
    print("After {d} s: {d} notifications, {f} readable = {}", .{ idle_seconds, notifications, addr, readable });
    return all and readable and (subscribed == 0 or notifications > 0);
}

/// Uses a connection, disconnects and waits until the peer advertises again. A peripheral with a
/// single advertising set (BlueZ) stays silent while the link is up, so this shows that
/// `disconnect` really ended the link. A peer that advertises while connected passes trivially.
fn checkDisconnect(adapter: *ble.UnifiedAdapter, addr: ble.Address) !bool {
    var dev = try connect(adapter, addr);
    _ = try visitCharacteristics(&dev, true);
    _ = try hold(adapter, 3);

    const before = seen.reportsOf(addr);
    const started = std.Io.Timestamp.now(io, .awake);
    try dev.disconnect();
    queue.releaseDevice(addr);
    // A peer found by its service may come back under another address.
    if (auto_target) {
        const again = locate(adapter, addr, disconnect_wait_seconds) catch |err| {
            print("FAILED: the peer did not advertise after the disconnect ({s}); the link is probably still up.", .{@errorName(err)});
            return false;
        };
        const took_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        print("Disconnected: the peer advertises again as {f} after {d} ms.", .{ again, took_ms });
        return true;
    }
    try queue.startScan(adapter, scan_filter);
    defer adapter.stopScan() catch {};
    for (0..disconnect_wait_seconds * 10) |_| {
        _ = drain();
        if (seen.reportsOf(addr) > before) {
            const took_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
            print("Disconnected: {f} advertises again after {d} ms.", .{ addr, took_ms });
            return true;
        }
        try adapter.processEvents(100);
    }
    print("FAILED: {f} did not advertise within {d} s after the disconnect; the link is probably still up.", .{ addr, disconnect_wait_seconds });
    return false;
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
    try scanFor(adapter, addr, scan_for_seconds);
    var dev = try adapter.connect(addr, connect_timeout_ms);
    defer drop(&dev);
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

fn checkWrite(adapter: *ble.UnifiedAdapter, addr: ble.Address, uuid: UUID, data: []const u8, with_response: bool) !bool {
    var dev = try connect(adapter, addr);
    defer drop(&dev);

    var buf: [512]u8 = undefined;
    var line_buf: [96]u8 = undefined;
    if (dev.readCharacteristic(uuid, &buf)) |len| {
        print("{s}", .{formatValue(&line_buf, "Before:", buf[0..len])});
    } else |err| print("Before: {s}", .{@errorName(err)});

    try dev.writeCharacteristic(uuid, data, with_response);
    print("{s} ({s}).", .{ formatValue(&line_buf, "Wrote", data), if (with_response) "with response" else "without response" });

    // A write without response has no acknowledgement to wait for.
    if (!with_response) _ = try hold(adapter, 1);
    if (dev.readCharacteristic(uuid, &buf)) |len| {
        const same = std.mem.eql(u8, buf[0..len], data);
        print("{s} ({s})", .{ formatValue(&line_buf, "After: ", buf[0..len]), if (same) "matches" else "differs" });
        return same;
    } else |err| print("After:  {s}", .{@errorName(err)});
    return false;
}

fn checkWriteDescriptor(adapter: *ble.UnifiedAdapter, addr: ble.Address, char: UUID, descriptor: UUID, data: []const u8) !bool {
    var dev = try connect(adapter, addr);
    defer drop(&dev);

    var buf: [512]u8 = undefined;
    if (dev.readDescriptor(char, descriptor, &buf)) |len| {
        print("Before: {x}", .{buf[0..len]});
    } else |err| print("Before: {s}", .{@errorName(err)});

    try dev.writeDescriptor(char, descriptor, data);
    print("Wrote {x} to descriptor {f}.", .{ data, descriptor });

    if (dev.readDescriptor(char, descriptor, &buf)) |len| {
        const same = std.mem.eql(u8, buf[0..len], data);
        print("After:  {x} ({s})", .{ buf[0..len], if (same) "matches" else "differs" });
        return same;
    } else |err| print("After:  {s}", .{@errorName(err)});
    return false;
}

// ---- Suite ----------------------------------------------------------------------------------

const SuiteCheck = enum {
    hold,
    indications,
    long_read,
    write,
    write_no_response,
    long_write,
    long_write_no_response,
    descriptor_write,
    resubscribe,
    disconnect,

    fn label(self: SuiteCheck) []const u8 {
        return switch (self) {
            .hold => "connect, read, notifications, hold 30 s",
            .indications => "indications",
            .long_read => "read a long value (200+ bytes)",
            .write => "write with response",
            .write_no_response => "write without response",
            .long_write => "write 512 bytes with response",
            .long_write_no_response => "write 200 bytes without response",
            .descriptor_write => "write a descriptor",
            .resubscribe => "auto-resubscribe after a reconnect",
            .disconnect => "disconnect ends the link",
        };
    }
};
const suite_checks = std.enums.values(SuiteCheck);
const SuiteResults = [suite_checks.len]bool;

fn record(results: *SuiteResults, check: SuiteCheck, result: anyerror!bool) void {
    const passed = result catch |err| blk: {
        print("  error: {s}", .{@errorName(err)});
        break :blk false;
    };
    print("--> {s}: {s}", .{ check.label(), if (passed) "PASS" else "FAIL" });
    results[@intFromEnum(check)] = passed;
}

fn suiteWrite(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address, uuid: UUID, data: []const u8, with_response: bool) !bool {
    return checkWrite(adapter, try locate(adapter, fixed, scan_for_seconds), uuid, data, with_response);
}

fn suiteWriteDescriptor(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address, data: []const u8) !bool {
    return checkWriteDescriptor(adapter, try locate(adapter, fixed, scan_for_seconds), echo_char, echo_descriptor, data);
}

fn suiteResubscribe(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address) !bool {
    // A peer that changed its address in the middle of the check says nothing about it.
    for (0..2) |_| {
        return checkResubscribe(adapter, try locate(adapter, fixed, scan_for_seconds)) catch |err| switch (err) {
            error.AddressChanged => continue,
            else => |e| return e,
        };
    }
    return error.AddressChanged;
}

fn suiteDisconnect(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address) !bool {
    return checkDisconnect(adapter, try locate(adapter, fixed, scan_for_seconds));
}

fn suiteInspect(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address) !Inspection {
    return checkDevice(adapter, try locate(adapter, fixed, scan_for_seconds));
}

/// Runs every check that needs no prompt `rounds` times against a peer running `--peripheral`.
fn suite(adapter: *ble.UnifiedAdapter, fixed: ?ble.Address, rounds: u32) !void {
    quiet = true;
    var passed: [suite_checks.len]u32 = @splat(0);
    var pattern: [512]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i);

    for (1..rounds + 1) |round| {
        print("\n===== Round {d}/{d} =====", .{ round, rounds });
        var ok: SuiteResults = @splat(false);

        if (suiteInspect(adapter, fixed)) |r| {
            record(&ok, .hold, r.held and r.counter >= 20);
            record(&ok, .indications, r.indications >= 20 and r.indicate_cccd);
            record(&ok, .long_read, r.long_ok);
        } else |err| {
            for ([_]SuiteCheck{ .hold, .indications, .long_read }) |check| record(&ok, check, err);
        }
        _ = hold(adapter, 1) catch 0;

        // A value that differs every round, so a stale read cannot pass.
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, @intCast(round * 0x0101), .big);
        record(&ok, .write, suiteWrite(adapter, fixed, echo_char, &value, true));
        _ = hold(adapter, 1) catch 0;
        value[0] = 0xA5;
        record(&ok, .write_no_response, suiteWrite(adapter, fixed, echo_char, &value, false));
        _ = hold(adapter, 1) catch 0;
        record(&ok, .long_write, suiteWrite(adapter, fixed, long_char, &pattern, true));
        _ = hold(adapter, 1) catch 0;
        record(&ok, .long_write_no_response, suiteWrite(adapter, fixed, long_char, pattern[0..200], false));
        _ = hold(adapter, 1) catch 0;
        value[0] = 0x5A;
        record(&ok, .descriptor_write, suiteWriteDescriptor(adapter, fixed, &value));
        _ = hold(adapter, 1) catch 0;
        record(&ok, .resubscribe, suiteResubscribe(adapter, fixed));
        _ = hold(adapter, 1) catch 0;
        record(&ok, .disconnect, suiteDisconnect(adapter, fixed));
        _ = hold(adapter, 1) catch 0;

        for (ok, &passed) |one, *count| count.* += @intFromBool(one);
    }

    var all = true;
    print("\n{s: <42}  passed", .{"check"});
    for (suite_checks, passed) |check, count| {
        print("{s: <42}  {d}/{d}", .{ check.label(), count, rounds });
        if (count != rounds) all = false;
    }
    print("\nSuite ({s}): {s}", .{ adapter.getBackendName(), if (all) "PASSED" else "FAILED" });
    if (!all) return error.SuiteFailed;
}

// ---- Pairing prompts ------------------------------------------------------------------------

/// Reads one line from the terminal. Null on end of input: the prompt then counts as declined.
fn askLine(buf: []u8) ?[]const u8 {
    if (answers_path) |path| return answerFromFile(path, buf);
    var buffers = [_][]u8{buf};
    const n = std.Io.File.stdin().readStreaming(io, &buffers) catch return null;
    if (n == 0) return null;
    // Piped answers can arrive several lines at once; the first one answers this prompt.
    const line = std.mem.sliceTo(buf[0..n], '\n');
    return std.mem.trim(u8, line, " \t\r");
}

/// The next unused line of the answers file. A script appends the answer once it has seen the
/// prompt, so this waits up to 60 s for it.
fn answerFromFile(path: []const u8, buf: []u8) ?[]const u8 {
    var content: [1024]u8 = undefined;
    for (0..600) |_| {
        if (std.Io.Dir.cwd().readFile(io, path, &content)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            var index: usize = 0;
            while (lines.next()) |raw| : (index += 1) {
                // The last piece has no newline yet: it is still being written.
                if (lines.peek() == null) break;
                if (index < answers_used) continue;
                answers_used += 1;
                const line = std.mem.trim(u8, raw, " \t\r");
                const len = @min(line.len, buf.len);
                @memcpy(buf[0..len], line[0..len]);
                print("    (answer from file: {s})", .{buf[0..len]});
                return buf[0..len];
            }
        } else |_| {}
        io.sleep(.fromMilliseconds(100), .awake) catch return null;
    }
    print("    (no answer in {s} within 60 s)", .{path});
    return null;
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
        self.agent = ble.Agent.init(&self.conn, "/org/zig_ble/hardware_check_agent", agentCapability(io_capability));
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
    // BlueZ takes the capability from the agent registered above.
    dev.pair(io_capability) catch |err| {
        print("Pairing failed: {s}, bond state: {t}", .{ @errorName(err), dev.getBondState() });
        dev.disconnect() catch {};
        return err;
    };
    print("Paired, bond state: {t}", .{dev.getBondState()});
    _ = try visitCharacteristics(&dev, false);
    try dev.disconnect();

    print("\nReconnecting: the bond must survive this.", .{});
    try scanFor(adapter, addr, scan_for_seconds);
    var again = try connect(adapter, addr);
    defer drop(&again);
    _ = try visitCharacteristics(&again, false);
    print("\nBond state after the reconnect: {t}. Remove it with --unpair.", .{again.getBondState()});
}

/// The peripheral pairs: this side only subscribes, answers the prompts and then reads.
fn checkAwaitPair(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    quiet = true;
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
    defer drop(&dev);
    try queue.subscribe(&dev, counter_char);
    print("Subscribed to the counter; waiting for the peripheral to pair ...", .{});
    for (0..600) |_| {
        _ = drain();
        if (dev.getBondState() == .bonded) break;
        try adapter.processEvents(100);
    } else {
        print("Not paired within 60 s, bond state: {t}", .{dev.getBondState()});
        return error.PairingFailed;
    }
    print("Paired, bond state: {t}", .{dev.getBondState()});
    _ = try visitCharacteristics(&dev, false);
}

fn checkUnpair(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    var dev = try connect(adapter, addr);
    defer drop(&dev);
    try dev.unpair();
    print("Unpaired.", .{});
}

// ---- Peripheral -----------------------------------------------------------------------------

const test_service = UUID.parse("5a1e0001-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const echo_char = UUID.parse("5a1e0002-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const counter_char = UUID.parse("5a1e0003-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const protected_char = UUID.parse("5a1e0004-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const indicate_char = UUID.parse("5a1e0005-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const long_char = UUID.parse("5a1e0006-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;
const echo_descriptor = UUID.parse("5a1e0007-6f3b-4c52-9d27-1e8b7c4a2f10") catch unreachable;

var peripheral: ble.Peripheral = undefined;

fn onEchoWrite(_: *ble.ServerCharacteristic, data: []const u8, _: ?*anyopaque) void {
    print("  echo written: {x}", .{data});
}

fn onLongWrite(_: *ble.ServerCharacteristic, data: []const u8, _: ?*anyopaque) void {
    print("  long written: {d} bytes", .{data.len});
}

fn onDescriptorWrite(_: *ble.ServerDescriptor, data: []const u8, _: ?*anyopaque) void {
    print("  echo descriptor written: {x}", .{data});
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
    }, .{ .agent_capability = agentCapability(io_capability) });
    installAgentCallbacks(&peripheral.agent);

    const service = try peripheral.addService(test_service, true);
    const echo = try service.addCharacteristic(echo_char, .{ .read = true, .write = true, .write_without_response = true });
    echo.setValue("echo");
    echo.write_handler = onEchoWrite;
    const descriptor = try echo.addDescriptor(echo_descriptor, .{ .read = true, .write = true });
    descriptor.setValue("desc");
    descriptor.write_handler = onDescriptorWrite;
    const counter = try service.addCharacteristic(counter_char, .{ .read = true, .notify = true });
    counter.setValue(&.{ 0, 0, 0, 0 });
    counter.notify_handler = onCounterNotifyState;
    const indicate = try service.addCharacteristic(indicate_char, .{ .read = true, .indicate = true });
    indicate.setValue(&.{ 0, 0, 0, 0 });
    const long = try service.addCharacteristic(long_char, .{ .read = true, .write = true, .write_without_response = true });
    var long_value: [300]u8 = undefined;
    for (&long_value, 0..) |*b, i| b.* = @truncate(i);
    long.setValue(&long_value);
    long.write_handler = onLongWrite;
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
    print("  indicate  {f}  read, indicate (every second)", .{indicate_char});
    print("  long      {f}  read, write, write without response, 300 bytes", .{long_char});
    print("  echo desc {f}  read, write", .{echo_descriptor});
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
        indicate.notify(&conn, &bytes) catch |err| print("  indicate: {s}", .{@errorName(err)});
        const subs = counter.subscribers();
        if (subs.total != last_subs.total or subs.active != last_subs.active) {
            print("  counter subscribers: {d}, {d} connected", .{ subs.total, subs.active });
            // Windows: pair from here so the prompts reach this program, not a system dialog.
            if (builtin.os.tag == .windows and secure and subs.active > last_subs.active) {
                const callbacks: ble.PairingCallbacks = .{
                    .on_confirm = promptConfirm,
                    .on_request_passkey = promptPasskey,
                    .on_display_passkey = showPasskey,
                };
                if (counter.pairSubscribers(io_capability, callbacks, 30_000)) |n| {
                    print("  paired with {d} subscriber(s)", .{n});
                } else |err| print("  pairing with the subscriber failed: {s}", .{@errorName(err)});
            }
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

fn parseIoCapability(name: []const u8) !ble.IoCapability {
    if (std.mem.eql(u8, name, "none")) return .no_input_no_output;
    if (std.mem.eql(u8, name, "display")) return .display_only;
    if (std.mem.eql(u8, name, "yesno")) return .display_yes_no;
    if (std.mem.eql(u8, name, "keyboard")) return .keyboard_only;
    if (std.mem.eql(u8, name, "keyboarddisplay")) return .keyboard_display;
    return error.InvalidArguments;
}

fn agentCapability(cap: ble.IoCapability) @FieldType(ble.Agent, "capability") {
    return switch (cap) {
        .no_input_no_output => .no_input_no_output,
        .display_only => .display_only,
        .display_yes_no => .display_yes_no,
        .keyboard_only => .keyboard_only,
        .keyboard_display => .keyboard_display,
        _ => .keyboard_display,
    };
}

fn parseAction(args: anytype, hex_buf: []u8) !Action {
    var arg = args.next() orelse return .inspect;
    while (true) {
        if (std.mem.eql(u8, arg, "--service")) {
            service_filter = try UUID.parse(args.next() orelse return error.InvalidArguments);
        } else if (std.mem.eql(u8, arg, "--io")) {
            io_capability = try parseIoCapability(args.next() orelse return error.InvalidArguments);
        } else if (std.mem.eql(u8, arg, "--answers")) {
            answers_path = args.next() orelse return error.InvalidArguments;
        } else break;
        arg = args.next() orelse return .inspect;
    }
    if (std.mem.eql(u8, arg, "--resubscribe")) return .resubscribe;
    if (std.mem.eql(u8, arg, "--disconnect")) return .disconnect;
    if (std.mem.eql(u8, arg, "--multi")) {
        while (args.next()) |extra| {
            if (extra_targets_len == extra_targets.len) return error.InvalidArguments;
            extra_targets[extra_targets_len] = try ble.Address.parse(extra);
            extra_targets_len += 1;
        }
        if (extra_targets_len == 0) return error.InvalidArguments;
        return .multi;
    }
    if (std.mem.eql(u8, arg, "--pair")) return .pair;
    if (std.mem.eql(u8, arg, "--await-pair")) return .await_pair;
    if (std.mem.eql(u8, arg, "--unpair")) return .unpair;
    if (std.mem.eql(u8, arg, "--suite")) {
        return .{ .suite = if (args.next()) |n| try std.fmt.parseInt(u32, n, 10) else 10 };
    }
    if (std.mem.eql(u8, arg, "--soak")) {
        return .{ .soak = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArguments, 10) };
    }
    if (std.mem.eql(u8, arg, "--write-desc")) {
        const char = try UUID.parse(args.next() orelse return error.InvalidArguments);
        const descriptor = try UUID.parse(args.next() orelse return error.InvalidArguments);
        const data = try std.fmt.hexToBytes(hex_buf, args.next() orelse return error.InvalidArguments);
        return .{ .write_descriptor = .{ .char = char, .descriptor = descriptor, .data = data } };
    }
    if (std.mem.eql(u8, arg, "--write") or std.mem.eql(u8, arg, "--write-len")) {
        const uuid = try UUID.parse(args.next() orelse return error.InvalidArguments);
        const value = args.next() orelse return error.InvalidArguments;
        const data = if (std.mem.eql(u8, arg, "--write"))
            try std.fmt.hexToBytes(hex_buf, value)
        else blk: {
            // A counting pattern of the given length, to check long writes and reads.
            const len = try std.fmt.parseInt(usize, value, 10);
            if (len == 0 or len > hex_buf.len) return error.InvalidArguments;
            for (hex_buf[0..len], 0..) |*b, i| b.* = @truncate(i);
            break :blk hex_buf[0..len];
        };
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
    var hex_buf: [512]u8 = undefined;
    var action: Action = .inspect;
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "--peripheral")) {
            var seconds: u32 = default_peripheral_seconds;
            var secure = false;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--secure")) {
                    secure = true;
                } else if (std.mem.eql(u8, arg, "--io")) {
                    io_capability = try parseIoCapability(args.next() orelse return error.InvalidArguments);
                } else if (std.mem.eql(u8, arg, "--answers")) {
                    answers_path = args.next() orelse return error.InvalidArguments;
                } else seconds = try std.fmt.parseInt(u32, arg, 10);
            }
            return runPeripheral(seconds, secure);
        }
        if (std.mem.eql(u8, first, "auto")) {
            auto_target = true;
        } else target = ble.Address.parse(first) catch {
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

    // With --multi the other devices need not advertise the service.
    if (service_filter) |uuid| {
        filter_uuid = .{uuid};
        if (action != .multi) scan_filter.service_uuids = &filter_uuid;
    }
    try scan(&adapter);
    if (auto_target and service_filter == null) {
        print("`auto` needs --service <uuid>.", .{});
        return error.InvalidArguments;
    }
    if (action == .suite) return suite(&adapter, target, action.suite);
    const addr = if (auto_target) try locate(&adapter, null, scan_for_seconds) else target orelse return;
    switch (action) {
        .inspect => _ = try checkDevice(&adapter, addr),
        .resubscribe => _ = try checkResubscribe(&adapter, addr),
        .disconnect => _ = try checkDisconnect(&adapter, addr),
        .multi => if (!try checkMulti(&adapter, addr)) return error.CheckFailed,
        .soak => |minutes| try soak(&adapter, addr, minutes),
        .suite => unreachable,
        .write => |w| _ = try checkWrite(&adapter, addr, w.uuid, w.data, w.with_response),
        .write_descriptor => |w| _ = try checkWriteDescriptor(&adapter, addr, w.char, w.descriptor, w.data),
        .pair => try checkPair(&adapter, addr),
        .await_pair => try checkAwaitPair(&adapter, addr),
        .unpair => try checkUnpair(&adapter, addr),
    }
}
