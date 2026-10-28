//! # Zig-BLE README Code Examples Compilation & Execution Test
//!
//! Compiles and runs all canonical code snippets from `README.md` in CI so any
//! public API drift is caught immediately during `zig build test`.

const std = @import("std");
const ble = @import("Zig_BLE");

test "README Example 1: Cross-Platform UnifiedAdapter & GATT Client (Central Role)" {
    var mock = ble.MockController.init();
    const sensor_addr = try ble.Address.parse("AA:BB:CC:11:22:33");
    const hr_uuid = ble.UUID.from16(0x2A37);

    var sensor = ble.MockDevice{ .address = sensor_addr, .rssi = -52 };
    sensor.setName("Polar H10");
    var hr_char = ble.MockCharacteristic{ .uuid = hr_uuid };
    hr_char.setValue(&[_]u8{ 0x00, 74 });
    _ = sensor.addCharacteristic(hr_char);
    _ = try mock.addDevice(sensor);

    var adapter = ble.UnifiedAdapter.init(mock.asBackend());
    try adapter.backend.openAdapter(0);
    defer adapter.backend.closeAdapter();
    try adapter.setPowered(true);

    var device = try adapter.connect(sensor_addr, 5000);
    defer device.disconnect() catch {};

    try device.discoverServices();
    const mtu = try device.exchangeMtu(247);
    try std.testing.expectEqual(@as(u16, 247), mtu);

    var buf: [32]u8 = undefined;
    const len = try device.readCharacteristic(hr_uuid, &buf);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(@as(u8, 74), buf[1]);
}

test "README Example 2: Zero-Allocation Advertising Packet Parser" {
    const raw_adv = [_]u8{
        0x02, 0x01, 0x06, // Flags: LE General Discoverable + BR/EDR Not Supported
        0x08, 0x09, 'Z', 'i', 'g', '-', 'B', 'L', 'E', // Complete Local Name
        0x03, 0x03, 0x0D, 0x18, // 16-bit Service UUID: Heart Rate (0x180D)
    };

    const report = ble.AdvertisingReport.parse(&raw_adv);
    try std.testing.expectEqualStrings("Zig-BLE", report.getValidLocalName().?);
    try std.testing.expect(report.flags.?.le_general_discoverable);
}

test "README Example 3: Authenticated & Encrypted BondStore (AES-128-CTR + AES-CMAC)" {
    var store = ble.MemoryBondStore(8).init();
    defer store.deinit();
    store.setEncryptionKey(.{
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    });

    const peer = try ble.Address.parse("C0:1A:7D:DA:71:13");
    try store.save(.{
        .address = peer,
        .address_type = .random,
        .keys = .{
            .ltk = @splat(0xAA),
            .irk = @splat(0xBB),
            .authenticated = true,
        },
    });

    var blob: [512]u8 = undefined;
    const written = try store.serialize(&blob);

    var restored = ble.MemoryBondStore(8).init();
    defer restored.deinit();
    restored.setEncryptionKey(.{
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    });
    try restored.deserialize(blob[0..written]);
    const rec = restored.load(peer).?;
    try std.testing.expect(rec.keys.authenticated);
    try std.testing.expectEqual(@as(u8, 0xAA), rec.keys.ltk[0]);
}

test "README Example 4: GATT Server & Peripheral Security Flags" {
    var conn: ble.Connection = undefined;
    var app = ble.GattApplication.init(&conn, "/org/bluez/hci0", "/com/zigble/app");
    const svc = try app.createService(ble.UUID.from16(0x180D), true);
    const char = try svc.addCharacteristic(
        ble.UUID.from16(0x2A37),
        .{
            .read = true,
            .notify = true,
            .encrypt_authenticated_read = true,
        },
    );
    char.setValue(&[_]u8{ 0x00, 75 });
    try std.testing.expectEqual(@as(usize, 1), app.service_count);
    try std.testing.expectEqual(@as(i32, 3), char.flags.toWinRtReadProtection());
}
