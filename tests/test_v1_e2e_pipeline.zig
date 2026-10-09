//! # Zig-BLE v1.0.0 Full End-to-End Pipeline Integration Test
//!
//! Validates the complete Bluetooth Low Energy stack across all v1.0.0 pillars:
//! 1. GAP Central Scanning & Peripheral Discovery
//! 2. Link Establishment & Disconnect Handling
//! 3. GATT Service & Characteristic Exploration
//! 4. Long Write Fragmentation (Prepare/Execute Write)
//! 5. Long Read Reassembly (ReadBlob)
//! 6. CCCD Subscription & Live Notification Streaming
//! 7. SMP Bonding & Persistent KeyStore (MemoryBondStore & binary serialization)
//! 8. Wireshark PCAP Packet Capturing (DLT_BLUETOOTH_HCI_H4)
//!
//! 100% deterministic, zero OS dependencies, runs in headless CI environments.

const std = @import("std");
const ble = @import("Zig_BLE");

test "Full v1.0.0 BLE Stack End-to-End Pipeline Integration" {
    // =========================================================================
    // 1. Setup Virtual Mock Controller & Peripheral Device
    // =========================================================================
    var mock = ble.backend.mock.MockController.init();
    const mock_backend = mock.asBackend();

    const dev_mac = ble.Address{ .bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 } };
    var peripheral = ble.backend.mock.MockDevice{
        .address = dev_mac,
        .rssi = -42,
    };
    peripheral.setName("Zig-BLE-v1-Device");

    // Characteristic: Heart Rate Measurement (0x2A37)
    var hr_char = ble.backend.mock.MockCharacteristic{
        .uuid = ble.UUID.from16(0x2A37),
        .can_read = true,
        .can_write = true,
        .can_notify = true,
    };
    hr_char.setValue(&[_]u8{ 0x00, 68 }); // Initial 68 bpm
    _ = peripheral.addCharacteristic(hr_char);

    // Characteristic: Long Data Transfer (0xFFE1)
    const long_char_uuid = ble.UUID.from16(0xFFE1);
    const long_char = ble.backend.mock.MockCharacteristic{
        .uuid = long_char_uuid,
        .can_read = true,
        .can_write = true,
        .can_notify = false,
    };
    _ = peripheral.addCharacteristic(long_char);

    _ = try mock.addDevice(peripheral);

    // Open adapter
    try mock_backend.openAdapter(0);
    try std.testing.expect(try mock_backend.isPowered());

    // =========================================================================
    // 2. GAP Scanning & Discovery Phase
    // =========================================================================
    const DiscoveryContext = struct {
        discovered: bool = false,
        found_address: ?ble.Address = null,

        fn onScan(device: *const ble.backend.DiscoveredDevice, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.discovered = true;
            self.found_address = device.address;
        }
    };

    var disc_ctx = DiscoveryContext{};
    try mock_backend.startScan(.{}, DiscoveryContext.onScan, &disc_ctx);
    try std.testing.expect(disc_ctx.discovered);
    try std.testing.expect(disc_ctx.found_address.?.eql(dev_mac));
    try mock_backend.stopScan();

    // =========================================================================
    // 3. Link Establishment & GATT Exploration Phase
    // =========================================================================
    const dev_handle = try mock_backend.connectDevice(dev_mac, 2000);
    try std.testing.expect(mock_backend.isDeviceConnected(dev_handle));
    try mock_backend.discoverServices(dev_handle);

    // Read initial Heart Rate
    var read_buf: [32]u8 = undefined;
    const read_len = try mock_backend.readCharacteristic(dev_handle, ble.UUID.from16(0x2A37), &read_buf);
    try std.testing.expectEqual(@as(usize, 2), read_len);
    try std.testing.expectEqual(@as(u8, 68), read_buf[1]);

    // =========================================================================
    // 4. GATT Long Write Engine (Prepare/Execute Write Chunker & Server Queue)
    // =========================================================================
    const test_long_data = "Zig-BLE v1.0.0 High-Performance Zero-Allocation Embedded Bluetooth Protocol Engine!".*;
    var chunker = ble.LongWriteIterator.init(0x002A, &test_long_data, 23); // MTU 23 -> slices into 18-byte chunks
    var server_queue = ble.ServerPrepareWriteQueue.init();

    var chunk_count: usize = 0;
    while (chunker.next()) |chunk| {
        try server_queue.enqueue(chunk);
        chunk_count += 1;
    }
    try std.testing.expect(chunk_count >= 4);

    var assembled_dest: [128]u8 = undefined;
    const assembled_len = try server_queue.assembleForHandle(0x002A, &assembled_dest);
    try std.testing.expectEqualStrings(&test_long_data, assembled_dest[0..assembled_len]);

    // =========================================================================
    // 5. GATT Long Read Engine (ReadBlob Reassembler)
    // =========================================================================
    var long_read_buf: [128]u8 = undefined;
    var long_reader = ble.LongReadReassembler.init(0x002A, &long_read_buf, 23);

    var read_offset: usize = 0;
    while (read_offset < test_long_data.len) {
        const remaining = test_long_data.len - read_offset;
        const chunk_len = @min(remaining, 22);
        const chunk = test_long_data[read_offset .. read_offset + chunk_len];
        read_offset += chunk_len;
        const done = try long_reader.feedResponse(chunk);
        if (read_offset == test_long_data.len) {
            try std.testing.expect(done);
        } else {
            try std.testing.expect(!done);
        }
    }
    try std.testing.expectEqualStrings(&test_long_data, long_reader.getAssembled());

    // =========================================================================
    // 6. CCCD Subscription & Notification Streaming Phase
    // =========================================================================
    const StreamContext = struct {
        received_bpm: u8 = 0,
        notify_count: usize = 0,

        fn onNotify(uuid: ble.UUID, data: []const u8, ctx: ?*anyopaque) void {
            _ = uuid;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.notify_count += 1;
            if (data.len >= 2) self.received_bpm = data[1];
        }
    };

    var stream_ctx = StreamContext{};
    try mock_backend.subscribeNotifications(
        dev_handle,
        ble.UUID.from16(0x2A37),
        StreamContext.onNotify,
        &stream_ctx,
    );

    // Trigger simulated notifications
    try mock.triggerNotification(dev_mac, ble.UUID.from16(0x2A37), &[_]u8{ 0x00, 75 });
    try std.testing.expectEqual(@as(u8, 75), stream_ctx.received_bpm);
    try std.testing.expectEqual(@as(usize, 1), stream_ctx.notify_count);

    try mock.triggerNotification(dev_mac, ble.UUID.from16(0x2A37), &[_]u8{ 0x00, 82 });
    try std.testing.expectEqual(@as(u8, 82), stream_ctx.received_bpm);
    try std.testing.expectEqual(@as(usize, 2), stream_ctx.notify_count);

    // =========================================================================
    // 7. Security Manager & Bond Store Persistence Phase
    // =========================================================================
    var bond_mem = ble.MemoryBondStore(8).init();
    const bond_store = bond_mem.asBondStore();

    var bond_rec = ble.BondRecord{
        .address = dev_mac,
        .address_type = .random,
        .keys = .{
            .ltk = @splat(0x5A),
            .rand = 0xDEADBEEF12345678,
            .ediv = 0x99AA,
            .authenticated = true,
            .irk = @splat(0x88),
        },
    };
    bond_rec.setCccd(0x002A, 0x0001); // Notify subscribed
    try bond_store.saveBond(bond_rec);

    // Serialize bond store to binary buffer (simulating non-volatile disk/flash storage)
    var nvs_flash: [256]u8 = undefined;
    const nvs_len = try bond_mem.serialize(&nvs_flash);
    try std.testing.expect(nvs_len > 8);

    // Disconnect device
    try mock_backend.disconnectDevice(dev_handle);
    try std.testing.expect(!mock_backend.isDeviceConnected(dev_handle));

    // Restore from NVS buffer on fresh boot
    var restored_store = ble.MemoryBondStore(8).init();
    try restored_store.deserialize(nvs_flash[0..nvs_len]);
    const restored_bond = restored_store.load(dev_mac).?;
    try std.testing.expectEqual(@as(u8, 0x5A), restored_bond.keys.ltk[0]);
    try std.testing.expect(restored_bond.keys.authenticated);
    try std.testing.expectEqual(@as(u16, 0x0001), restored_bond.getCccd(0x002A));

    // =========================================================================
    // 8. Wireshark PCAP Packet Exporter Verification
    // =========================================================================
    var pcap_storage: [512]u8 = undefined;
    var buf_writer = ble.pcap.BufferWriter.init(&pcap_storage);
    var pcap_writer = ble.pcap.PcapWriter(@TypeOf(&buf_writer)).init(&buf_writer);

    try pcap_writer.writeHeader();
    try pcap_writer.writeAttPdu(0x0040, 0x0004, &[_]u8{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 }); // ReadByTypeReq
    try pcap_writer.writeAttPdu(0x0040, 0x0004, &[_]u8{ 0x09, 0x06, 0x02, 0x00, 0x10, 0x00, 0x37, 0x2A }); // ReadByTypeRsp

    const written_pcap = buf_writer.getWritten();
    try std.testing.expect(written_pcap.len >= 24 + 16 * 2);
    // Verify PCAP magic 0xA1B2C3D4 (little endian: D4 C3 B2 A1)
    try std.testing.expectEqual(@as(u8, 0xD4), written_pcap[0]);
    try std.testing.expectEqual(@as(u8, 0xC3), written_pcap[1]);
    try std.testing.expectEqual(@as(u8, 0xB2), written_pcap[2]);
    try std.testing.expectEqual(@as(u8, 0xA1), written_pcap[3]);
}
