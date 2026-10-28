//! # Zig-BLE Mock End-to-End Smoke Test (`zig build run-mock-e2e`)
//!
//! Runs the full `UnifiedAdapter` flow against the in-memory `MockController`.
//! No radio and no Bluetooth controller are involved, so this is not a hardware-in-the-loop
//! test; it verifies that the public API sequence works end to end:
//! 1. Adapter Power-Up & Advertising Scan
//! 2. Connection & ATT MTU Negotiation
//! 3. Pairing & Bond State
//! 4. GATT Service Discovery, Characteristic Read, Write, and Notification Streaming
//! 5. Clean Disconnection & Reconnection

const std = @import("std");
const ble = @import("Zig_BLE");

pub fn main() !void {
    std.debug.print("=== Zig-BLE Mock End-to-End Smoke Test (no radio) ===\n", .{});

    var mock = ble.MockController.init();
    const target_addr = try ble.Address.parse("AA:BB:CC:11:22:33");
    const hr_uuid = ble.UUID.from16(0x2A37);

    var dev = ble.MockDevice{ .address = target_addr, .rssi = -45 };
    dev.setName("Zig-BLE-HiL-Target");
    var ch = ble.MockCharacteristic{ .uuid = hr_uuid };
    ch.setValue(&[_]u8{ 0x00, 72 });
    _ = dev.addCharacteristic(ch);
    _ = try mock.addDevice(dev);

    var adapter = ble.UnifiedAdapter.init(mock.asBackend());
    try adapter.backend.openAdapter(0);
    defer adapter.backend.closeAdapter();
    try adapter.setPowered(true);

    // Step 1: Scan
    const ScanCtx = struct {
        found: bool = false,
        fn cb(d: *const ble.DiscoveredDevice, ud: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (d.getName()) |n| {
                if (std.mem.eql(u8, n, "Zig-BLE-HiL-Target")) self.found = true;
            }
        }
    };
    var scan_ctx = ScanCtx{};
    try adapter.startScan(.{}, ScanCtx.cb, &scan_ctx);
    try adapter.stopScan();
    if (!scan_ctx.found) return error.HilTargetNotFound;
    std.debug.print("[PASS] 1. Advertising Scan & Target Discovery\n", .{});

    // Step 2: Connect & MTU Exchange
    var conn_dev = try adapter.connect(target_addr, 5000);
    defer conn_dev.disconnect() catch {};
    const negotiated_mtu = try conn_dev.exchangeMtu(247);
    if (negotiated_mtu != 247) return error.HilMtuMismatch;
    std.debug.print("[PASS] 2. Connection & ATT MTU Negotiation ({d} bytes)\n", .{negotiated_mtu});

    // Step 3: SMP Pairing & Bonding
    try conn_dev.pair(.display_yes_no);
    if (conn_dev.getBondState() != .bonded) return error.HilBondingFailed;
    std.debug.print("[PASS] 3. SMP Pairing & Bond State Verification\n", .{});

    // Step 4: GATT Discovery, Read, Write & Notifications
    try conn_dev.discoverServices();
    var buf: [32]u8 = undefined;
    const n = try conn_dev.readCharacteristic(hr_uuid, &buf);
    if (n != 2 or buf[1] != 72) return error.HilGattReadMismatch;

    try conn_dev.writeCharacteristic(hr_uuid, &[_]u8{ 0x00, 84 }, true);

    const NotifyCtx = struct {
        last_bpm: u8 = 0,
        fn cb(_: ble.UUID, data: []const u8, ud: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (data.len >= 2) self.last_bpm = data[1];
        }
    };
    var notify_ctx = NotifyCtx{};
    try conn_dev.subscribe(hr_uuid, NotifyCtx.cb, &notify_ctx);
    try mock.triggerNotification(target_addr, hr_uuid, &[_]u8{ 0x00, 91 });
    if (notify_ctx.last_bpm != 91) return error.HilNotificationMismatch;
    try conn_dev.unsubscribe(hr_uuid);
    std.debug.print("[PASS] 4. GATT Read, Write & Notification Streaming\n", .{});

    // Step 5: Disconnect & Reconnect
    try conn_dev.disconnect();
    var reconn_dev = try adapter.connect(target_addr, 5000);
    try reconn_dev.disconnect();
    std.debug.print("[PASS] 5. Clean Disconnect & Reconnect Cycle\n", .{});
    std.debug.print("=== All Mock End-to-End Checks Passed! ===\n", .{});
}

