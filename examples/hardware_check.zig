//! # Hardware check for the native backends (Windows WinRT, Linux BlueZ)
//!
//! Scanning only listens. With a device address the program also connects to that device,
//! reads its readable characteristics and subscribes to its notifying ones (a CCCD write that
//! ends with the connection); it never writes characteristic values and does not pair.
//!
//!   zig build run-hardware-check
//!   zig build run-hardware-check -- AA:BB:CC:11:22:33

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

var native: Native = .{};
var queue: Queue = .{};

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

fn scan(adapter: *ble.UnifiedAdapter) !void {
    print("Scanning for {d} s ...", .{scan_seconds});
    try queue.startScan(adapter, .{});
    for (0..scan_seconds * 10) |_| {
        _ = drain();
        try adapter.processEvents(100);
    }
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

fn checkDevice(adapter: *ble.UnifiedAdapter, addr: ble.Address) !void {
    var known = false;
    for (seen.devices[0..seen.len]) |*d| {
        if (d.address.eql(addr)) known = true;
    }
    if (!known) print("Note: {f} was not seen while scanning.", .{addr});

    print("\nConnecting to {f} ...", .{addr});
    var dev = try adapter.connect(addr, 30_000);
    defer dev.disconnect() catch {};
    print("Connected.", .{});

    if (dev.exchangeMtu(247)) |mtu| {
        print("MTU: {d}", .{mtu});
    } else |err| print("MTU: {s}", .{@errorName(err)});

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
        if (queue.subscribe(&dev, sel)) |_| {
            subscribed += 1;
            sub = ", subscribed";
        } else |_| {}
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

    print("\nStaying connected for {d} s without GATT traffic ({d} subscriptions) ...", .{ idle_seconds, subscribed });
    var notifications: usize = 0;
    for (0..idle_seconds * 10) |_| {
        notifications += drain();
        try adapter.processEvents(100);
    }
    notifications += drain();
    print("After {d} s: connected = {}, {d} notifications", .{ idle_seconds, dev.isConnected(), notifications });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const target = if (args.next()) |arg| try ble.Address.parse(arg) else null;

    const backend = native.asBackend();
    try backend.openAdapter(0);
    defer native.deinit();
    native.setConnectionEventCallback(Queue.onConnectionEvent, &queue);

    var adapter = ble.UnifiedAdapter.init(backend);
    print("Backend: {s}, powered: {}", .{ adapter.getBackendName(), try adapter.isPowered() });

    try scan(&adapter);
    if (target) |addr| try checkDevice(&adapter, addr);
}
