//! # Zig-BLE v1.1.0 Comprehensive Feature & Integration Tests
//!
//! Validates all core deliverables of milestone v1.1.0:
//! 1. ATT MTU Exchange (negotiation of MTU up to 517 bytes)
//! 2. Security Manager Pairing, Bonding lifecycle, and granular ATT error mappings
//! 3. High-level L2CAP Connection-Oriented Channels (CoC) streaming API
//! 4. Wireshark PCAP Reader and Android BTSNOOP HCI Reader
//! 5. BT 5.2 Enhanced ATT (EATT) Multi-Bearer Multiplexer
//! 6. BT 5.3 Connection Subrating Command Encoder and Event Decoder

const std = @import("std");
const ble = @import("Zig_BLE");

test "v1.1.0: ATT MTU Exchange on MockBackend and UnifiedDevice" {
    var mock = ble.MockController.init();
    var adapter = ble.UnifiedAdapter.init(mock.asBackend());

    const addr = ble.Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    var dev = ble.MockDevice{ .address = addr };
    dev.setName("Whoop_4_HighThroughput");
    _ = try mock.addDevice(dev);

    try adapter.setPowered(true);
    var connected_dev = try adapter.connect(addr, 1000);
    defer connected_dev.disconnect() catch {};

    // Initial default MTU is 23
    try std.testing.expectEqual(@as(u16, 23), mock.devices[0].mtu);

    // Request Whoop High-Throughput MTU (247 bytes)
    const negotiated = try connected_dev.exchangeMtu(247);
    try std.testing.expectEqual(@as(u16, 247), negotiated);
    try std.testing.expectEqual(@as(u16, 247), mock.devices[0].mtu);

    // Request maximum GATT MTU (517 bytes)
    const negotiated_max = try connected_dev.exchangeMtu(517);
    try std.testing.expectEqual(@as(u16, 517), negotiated_max);
    try std.testing.expectEqual(@as(u16, 517), mock.devices[0].mtu);
}

test "v1.1.0: Security, Bonding & Granular ATT Error Mapping" {
    var mock = ble.MockController.init();
    var adapter = ble.UnifiedAdapter.init(mock.asBackend());

    const addr = ble.Address{ .bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33 } };
    var dev = ble.MockDevice{ .address = addr };
    dev.setName("SecureSensor");
    _ = try mock.addDevice(dev);

    try adapter.setPowered(true);
    var connected_dev = try adapter.connect(addr, 1000);
    defer connected_dev.disconnect() catch {};

    // Verify initial bond state is .not_bonded
    try std.testing.expectEqual(ble.BondState.not_bonded, connected_dev.getBondState());

    // Execute pairing
    try connected_dev.pair(.display_yes_no);
    try std.testing.expectEqual(ble.BondState.bonded, connected_dev.getBondState());

    // Execute unpair
    try connected_dev.unpair();
    try std.testing.expectEqual(ble.BondState.not_bonded, connected_dev.getBondState());

    // Test Granular ATT Error Code Mapping
    try std.testing.expectEqual(error.InsufficientAuthentication, ble.AttErrorCode.insufficient_authentication.toError());
    try std.testing.expectEqual(error.InsufficientEncryption, ble.AttErrorCode.insufficient_encryption.toError());
    try std.testing.expectEqual(error.ValueNotAllowed, ble.AttErrorCode.value_not_allowed.toError());
    try std.testing.expectEqual(error.CccdImproperlyConfigured, ble.AttErrorCode.toError(@enumFromInt(0xFD)));
}

test "v1.1.0: High-Level L2CAP CoC Streaming (Galaxy Watch watch-wire PSM 0x1001)" {
    var chan_client: ble.l2cap.MockChannel = .{};
    var chan_server: ble.l2cap.MockChannel = .{};
    var stream_pair = ble.l2cap.createMockStreamPair(&chan_client, &chan_server, 672, 251);

    // Verify MTU and MPS configuration
    try std.testing.expectEqual(@as(u16, 672), stream_pair.client.getMtu());
    try std.testing.expectEqual(@as(u16, 251), stream_pair.client.getMps());

    // 100 Hz Raw Sensor Telemetry payload
    const sensor_chunk = [_]u8{0x5A} ** 128;
    const written = try stream_pair.client.write(&sensor_chunk);
    try std.testing.expectEqual(@as(usize, 128), written);

    var rx_buffer: [256]u8 = undefined;
    const read_bytes = try stream_pair.server.read(&rx_buffer);
    try std.testing.expectEqual(@as(usize, 128), read_bytes);
    try std.testing.expectEqualSlices(u8, &sensor_chunk, rx_buffer[0..read_bytes]);

    // Test channel closure
    stream_pair.server.close();
    try std.testing.expectError(error.ConnectionClosed, stream_pair.client.write("more"));
}

test "v1.1.0: PCAP and BTSNOOP Trace Readers" {
    // 1. PCAP Reader test
    var pcap_buf: [512]u8 = undefined;
    var writer = ble.pcap.BufferWriter.init(&pcap_buf);
    var pcap_writer = ble.pcap.PcapWriter(*ble.pcap.BufferWriter).init(&writer);
    try pcap_writer.writeHeader();

    const acl_payload = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try pcap_writer.writePacketWithTimestamp(.acl_data, &acl_payload, 50, 100);

    var pcap_reader = try ble.PcapReader.init(writer.getWritten());
    const pkt = (try pcap_reader.next()).?;
    try std.testing.expectEqual(@as(u32, 50), pkt.sec);
    try std.testing.expectEqual(@as(u32, 100), pkt.usec);
    try std.testing.expectEqual(@as(u8, 0x02), pkt.data[0]); // ACL indicator
    try std.testing.expectEqualSlices(u8, &acl_payload, pkt.data[1..]);

    // 2. BTSNOOP Reader test
    var btsnoop_buf: [64]u8 = undefined;
    @memcpy(btsnoop_buf[0..8], "btsnoop\x00");
    std.mem.writeInt(u32, btsnoop_buf[8..12], 1, .big);
    std.mem.writeInt(u32, btsnoop_buf[12..16], 1002, .big); // HCI UART

    const offset = 16;
    std.mem.writeInt(u32, btsnoop_buf[offset .. offset + 4], 3, .big);
    std.mem.writeInt(u32, btsnoop_buf[offset + 4 .. offset + 8], 3, .big);
    std.mem.writeInt(u32, btsnoop_buf[offset + 8 .. offset + 12], 0, .big); // Sent
    std.mem.writeInt(u32, btsnoop_buf[offset + 12 .. offset + 16], 0, .big);
    std.mem.writeInt(u64, btsnoop_buf[offset + 16 .. offset + 24], 999999, .big);
    @memcpy(btsnoop_buf[offset + 24 .. offset + 27], &[_]u8{ 0x01, 0x03, 0x0C }); // HCI Reset Cmd

    var btsnoop_reader = try ble.BtsnoopReader.init(btsnoop_buf[0 .. offset + 27]);
    const bts_pkt = (try btsnoop_reader.next()).?;
    try std.testing.expect(!bts_pkt.is_received);
    try std.testing.expectEqual(@as(u64, 999999), bts_pkt.timestamp_us);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x03, 0x0C }, bts_pkt.data);
}

test "v1.1.0: BT 5.2 Enhanced ATT (EATT) Concurrency" {
    var mux = ble.EattMultiplexer(8).init();

    // Add 3 parallel channels
    try mux.addBearer(0x0040, 517, 251);
    try mux.addBearer(0x0041, 517, 251);
    try mux.addBearer(0x0042, 517, 251);
    try std.testing.expectEqual(@as(usize, 3), mux.getActiveCount());

    // Acquire 2 channels for parallel operations
    const bearer_read = mux.acquireBearerForRequest().?;
    const bearer_write = mux.acquireBearerForRequest().?;
    try std.testing.expect(bearer_read.cid != bearer_write.cid);
    try std.testing.expect(bearer_read.in_flight);
    try std.testing.expect(bearer_write.in_flight);

    // Notifications can still proceed on the 3rd idle bearer without blocking!
    const notif_bearer = mux.selectBearerForNotification().?;
    try std.testing.expect(notif_bearer.cid != 0);

    // Release bearers
    try std.testing.expect(mux.releaseBearer(bearer_read.cid));
    try std.testing.expect(mux.releaseBearer(bearer_write.cid));
}

test "v1.1.0: BT 5.3 Connection Subrating HCI Command & Event" {
    const params = ble.SubrateParameters{
        .subrate_min = 2,
        .subrate_max = 50,
        .max_latency = 5,
        .continuation_number = 1,
        .supervision_timeout = 400, // 4.0 s
    };
    try std.testing.expect(params.isValid());

    var cmd_buf: [32]u8 = undefined;
    const len = try ble.encodeSubrateRequest(0x0020, params, &cmd_buf);
    try std.testing.expectEqual(@as(usize, 16), len);
    try std.testing.expectEqual(@as(u8, 0x01), cmd_buf[0]); // HCI Command Indicator

    // Event payload
    var evt_payload: [11]u8 = undefined;
    evt_payload[0] = 0x00; // Success
    std.mem.writeInt(u16, evt_payload[1..3], 0x0020, .little);
    std.mem.writeInt(u16, evt_payload[3..5], 25, .little); // Negotiated factor 25
    std.mem.writeInt(u16, evt_payload[5..7], 5, .little);
    std.mem.writeInt(u16, evt_payload[7..9], 1, .little);
    std.mem.writeInt(u16, evt_payload[9..11], 400, .little);

    const event = try ble.decodeSubrateChangeEvent(&evt_payload);
    try std.testing.expectEqual(@as(u8, 0), event.status);
    try std.testing.expectEqual(@as(u16, 0x0020), event.connection_handle);
    try std.testing.expectEqual(@as(u16, 25), event.subrate_factor);
}
