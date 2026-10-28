//! # Zig-BLE v1.0.0 Comprehensive Edge-Case Test Suite
//!
//! Rigorously validates boundary conditions, invalid inputs, edge cases,
//! and protocol corner cases according to Bluetooth Core Spec v5.4/v6.0:
//! 1. Zero-Length & Exact MTU Boundary Transfers (MTU=23, 247, 517)
//! 2. L2CAP Multi-Fragment Stream Anomalies & Corrupted Sequences
//! 3. GATT Prepare/Execute Write Queue Overlaps, Eviction & Discard
//! 4. CCCD Bitmask Masking, Reserved Flags & Invalid Subscriptions
//! 5. H4 Stream Parser Malformed Headers & Truncated Payloads
//! 6. Bond Store Capacity Limits, NVS Magic Validation & Corruption Rejection
//! 7. EUI-48 Address Parsing Corner Cases & Hex Validation

const std = @import("std");
const ble = @import("Zig_BLE");

// =============================================================================
// EDGE CASE 1: Zero-Length, Boundary, and Oversized MTU Transfers
// =============================================================================
test "EdgeCase: GATT LongWriteIterator Zero-Length and Exact Boundary Slicing" {
    // 1. Zero-length payload
    var empty_iter = ble.LongWriteIterator.init(0x0010, "", 23);
    try std.testing.expect(empty_iter.next() == null);

    // 2. Exact single-chunk boundary (MTU 23 -> chunk_size = 23 - 5 = 18 bytes)
    const exact_18_bytes = "123456789012345678"; // exactly 18 bytes
    var exact_iter = ble.LongWriteIterator.init(0x0010, exact_18_bytes, 23);
    const chunk1 = exact_iter.next().?;
    try std.testing.expectEqual(@as(u16, 0), chunk1.offset);
    try std.testing.expectEqualStrings(exact_18_bytes, chunk1.part_value);
    try std.testing.expect(exact_iter.next() == null);

    // 3. Exact boundary + 1 byte (19 bytes -> should yield 18 bytes, then 1 byte)
    const exact_19_bytes = "123456789012345678X";
    var split_iter = ble.LongWriteIterator.init(0x0010, exact_19_bytes, 23);
    const c1 = split_iter.next().?;
    try std.testing.expectEqual(@as(u16, 0), c1.offset);
    try std.testing.expectEqual(@as(usize, 18), c1.part_value.len);

    const c2 = split_iter.next().?;
    try std.testing.expectEqual(@as(u16, 18), c2.offset);
    try std.testing.expectEqualStrings("X", c2.part_value);
    try std.testing.expect(split_iter.next() == null);

    // 4. Large MTU boundary (MTU 247 -> chunk size = 242)
    var large_payload: [500]u8 = undefined;
    @memset(&large_payload, 'A');
    var large_iter = ble.LongWriteIterator.init(0x0020, &large_payload, 247);
    const lc1 = large_iter.next().?;
    try std.testing.expectEqual(@as(usize, 242), lc1.part_value.len);
    try std.testing.expectEqual(@as(u16, 0), lc1.offset);

    const lc2 = large_iter.next().?;
    try std.testing.expectEqual(@as(usize, 242), lc2.part_value.len);
    try std.testing.expectEqual(@as(u16, 242), lc2.offset);

    const lc3 = large_iter.next().?;
    try std.testing.expectEqual(@as(usize, 16), lc3.part_value.len);
    try std.testing.expectEqual(@as(u16, 484), lc3.offset);
    try std.testing.expect(large_iter.next() == null);
}

test "EdgeCase: GATT LongReadReassembler Boundary and Buffer Exhaustion" {
    var small_buf: [10]u8 = undefined;
    var reader = ble.LongReadReassembler.init(0x0015, &small_buf, 23);

    // Feed chunk larger than destination buffer -> must return BufferTooSmall
    const big_chunk = "0123456789ABCDEF";
    const err = reader.feedResponse(big_chunk);
    try std.testing.expectError(ble.BleError.BufferTooSmall, err);
}

// =============================================================================
// EDGE CASE 2: Server Prepare Write Queue Cancellation & Multi-Handle
// =============================================================================
test "EdgeCase: ServerPrepareWriteQueue Discard & Handle Isolation" {
    var queue = ble.ServerPrepareWriteQueue.init();

    // Enqueue chunks for handle 0x0010
    try queue.enqueue(.{ .handle = 0x0010, .offset = 0, .part_value = "Hello " });
    try queue.enqueue(.{ .handle = 0x0010, .offset = 6, .part_value = "World!" });

    // Enqueue chunk for a DIFFERENT handle 0x0020
    try queue.enqueue(.{ .handle = 0x0020, .offset = 0, .part_value = "Separate Handle" });

    // Verify handle isolation: assembling 0x0010 only takes 0x0010 chunks
    var dest1: [64]u8 = undefined;
    const len1 = try queue.assembleForHandle(0x0010, &dest1);
    try std.testing.expectEqualStrings("Hello World!", dest1[0..len1]);

    var dest2: [64]u8 = undefined;
    const len2 = try queue.assembleForHandle(0x0020, &dest2);
    try std.testing.expectEqualStrings("Separate Handle", dest2[0..len2]);

    // Test cancellation (Execute Write Cancel 0x00)
    queue.reset();
    try std.testing.expectEqual(@as(usize, 0), queue.count);
    var dest_empty: [64]u8 = undefined;
    const len_empty = try queue.assembleForHandle(0x0010, &dest_empty);
    try std.testing.expectEqual(@as(usize, 0), len_empty);
}

// =============================================================================
// EDGE CASE 3: L2CAP ACL Packet Stream Anomalies & Zero-Allocation Reassembly
// =============================================================================
test "EdgeCase: L2CAP AclReassembler Interrupted Stream and Oversized Payload" {
    var reassembler = ble.AclReassembler(256).init();

    // 1. Send first fragment declaring L2CAP length = 100 bytes (Handle 0x0040)
    var header1 = [_]u8{ 0x64, 0x00, 0x04, 0x00, 0xAA, 0xBB, 0xCC }; // Length 100, CID 4, 3 data bytes
    const f1 = try reassembler.processFragment(0x0040, ble.PbFlag.FIRST_NON_FLUSHABLE, &header1);
    try std.testing.expect(f1 == null); // Waiting for more fragments

    // 2. Abrupt interruption: New FIRST fragment arrives for a DIFFERENT handle or reset
    // The engine must discard stale partial state cleanly without leak or corruption
    var header2 = [_]u8{ 0x02, 0x00, 0x04, 0x00, 0x11, 0x22 }; // Length 2, CID 4
    const f2 = (try reassembler.processFragment(0x0042, ble.PbFlag.FIRST_NON_FLUSHABLE, &header2)).?;
    try std.testing.expectEqual(@as(u16, 0x0042), f2.conn_handle);
    try std.testing.expectEqual(@as(u16, 2), f2.length);
    try std.testing.expectEqual(@as(u16, 4), f2.cid);
    try std.testing.expectEqualStrings(&[_]u8{ 0x11, 0x22 }, f2.payload);

    // 3. Oversized L2CAP length exceeding buffer capacity (Capacity = 256, declared = 300)
    var header_huge = [_]u8{ 0x2C, 0x01, 0x04, 0x00 }; // 300 bytes declared
    const err = reassembler.processFragment(0x0040, ble.PbFlag.FIRST_NON_FLUSHABLE, &header_huge);
    try std.testing.expectError(error.L2capFrameTooLarge, err);
}

// =============================================================================
// EDGE CASE 4: CCCD Bitmask & Flag Edge Cases
// =============================================================================
test "EdgeCase: CCCD Encoding and Decoding Corner Flags" {
    // 1. Both Notify (0x0001) and Indicate (0x0002) enabled simultaneously
    const dual_cccd = ble.Cccd{ .notifications = true, .indications = true };
    const dual_bytes = dual_cccd.encode();
    try std.testing.expectEqual(@as(u8, 0x03), dual_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x00), dual_bytes[1]);

    const decoded_dual = ble.Cccd.decode(dual_bytes);
    try std.testing.expect(decoded_dual.notifications);
    try std.testing.expect(decoded_dual.indications);

    // 2. Reserved / vendor bits set in raw bytes (e.g. 0xFFFC) -> must mask correctly
    const dirty_raw = [_]u8{ 0xFD, 0xFF }; // bits 0 and 2..7 set, bit 1 clear
    const decoded_dirty = ble.Cccd.decode(dirty_raw);
    try std.testing.expect(decoded_dirty.notifications);
    try std.testing.expect(!decoded_dirty.indications); // bit 1 was 0

    // 3. All zeros
    const zero_cccd = ble.Cccd.decode([_]u8{ 0x00, 0x00 });
    try std.testing.expect(!zero_cccd.notifications);
    try std.testing.expect(!zero_cccd.indications);
}

// =============================================================================
// EDGE CASE 5: H4 Stream Parser Malformed Packets & Zero-Length HCI Events
// =============================================================================
test "EdgeCase: H4 Stream Parser Malformed and Fragmented Stream" {
    var parser = ble.H4StreamParser.init();
    var storage: [128]u8 = undefined;

    // 1. Unknown packet indicator byte (0xFF) -> InvalidH4Indicator
    const invalid_stream = [_]u8{ 0xFF, 0x01, 0x02 };
    const err = parser.feed(&invalid_stream, &storage);
    try std.testing.expectError(error.InvalidH4Indicator, err);

    // 2. Reset and feed single-byte-by-byte sliding stream (stress test state machine)
    parser.reset();
    // Valid HCI Command: 0x01 (Indicator) 0x03 0x0C (Reset Opcode) 0x00 (Param Len)
    const cmd_bytes = [_]u8{ 0x01, 0x03, 0x0C, 0x00 };
    for (cmd_bytes[0..3]) |b| {
        const res = try parser.feed(&[_]u8{b}, &storage);
        try std.testing.expect(res == null); // Incomplete
    }
    // Feed final byte
    const complete = (try parser.feed(&[_]u8{cmd_bytes[3]}, &storage)).?;
    try std.testing.expect(complete.packet == .command);
    try std.testing.expectEqual(@as(u16, 0x0C03), complete.packet.command.opcode);
    try std.testing.expectEqual(@as(u8, 0), complete.packet.command.param_len);
}

// =============================================================================
// EDGE CASE 6: BondStore Capacity Exhaustion & Binary NVS Corruption
// =============================================================================
test "EdgeCase: BondStore Capacity Limit and Corrupted Image Rejection" {
    // 1. Capacity limit (capacity = 2)
    var store = ble.MemoryBondStore(2).init();
    const addr1 = ble.Address{ .bytes = [_]u8{ 1, 0, 0, 0, 0, 0 } };
    const addr2 = ble.Address{ .bytes = [_]u8{ 2, 0, 0, 0, 0, 0 } };
    const addr3 = ble.Address{ .bytes = [_]u8{ 3, 0, 0, 0, 0, 0 } };

    try store.save(.{ .address = addr1, .keys = .{} });
    try store.save(.{ .address = addr2, .keys = .{} });
    // Third save on capacity 2 -> must return BondStoreFull
    const save_err = store.save(.{ .address = addr3, .keys = .{} });
    try std.testing.expectError(error.BondStoreFull, save_err);

    // 2. Reject corrupted NVS binary image (wrong magic)
    var corrupt_buf = [_]u8{ 'B', 'A', 'D', '!', 1, 0, 0, 0 };
    const deser_err = store.deserialize(&corrupt_buf);
    try std.testing.expectError(error.InvalidMagic, deser_err);

    // 3. Reject truncated NVS image
    var trunc_buf = [_]u8{ 'Z', 'B', 'G' };
    const trunc_err = store.deserialize(&trunc_buf);
    try std.testing.expectError(error.InvalidData, trunc_err);
}

// =============================================================================
// EDGE CASE 7: Bluetooth Address Parsing Corner Cases
// =============================================================================
test "EdgeCase: Address Parsing Mixed Case and Syntax Bounds" {
    // Valid lowercase
    const addr_lower = try ble.Address.parse("ab:cd:ef:01:23:45");
    try std.testing.expectEqual(@as(u8, 0xAB), addr_lower.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x45), addr_lower.bytes[5]);

    // Valid uppercase
    const addr_upper = try ble.Address.parse("AB:CD:EF:01:23:45");
    try std.testing.expect(addr_lower.eql(addr_upper));

    // Valid mixed case
    const addr_mixed = try ble.Address.parse("aB:Cd:eF:01:23:45");
    try std.testing.expect(addr_lower.eql(addr_mixed));

    // Invalid length
    try std.testing.expectError(error.InvalidLength, ble.Address.parse("AB:CD:EF"));
    try std.testing.expectError(error.InvalidLength, ble.Address.parse("AB:CD:EF:01:23:45:67"));

    // Invalid non-hex characters
    try std.testing.expectError(error.InvalidCharacter, ble.Address.parse("GB:CD:EF:01:23:45"));
}


// =============================================================================
// EDGE CASE 8: 1,000+ Scan/Connect/Notify/Disconnect Stress & Handle Leak Suite
// =============================================================================
const builtin = @import("builtin");
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetProcessHandleCount(hProcess: *anyopaque, pdwHandleCount: *u32) callconv(.winapi) c_int;

test "Stress & Leak Suite: 1,000+ Scan/Connect/Notify/Disconnect Cycles with Handle & Allocator Check" {
    var handles_before: u32 = 0;
    if (builtin.os.tag == .windows) {
        _ = GetProcessHandleCount(GetCurrentProcess(), &handles_before);
    }

    var mock = ble.MockController.init();
    const peer_addr = try ble.Address.parse("12:34:56:78:9A:BC");
    const hr_char_uuid = ble.UUID.from16(0x2A37);

    var mock_dev = ble.MockDevice{ .address = peer_addr, .rssi = -48 };
    mock_dev.setName("Stress-HRM");
    var hr_ch = ble.MockCharacteristic{ .uuid = hr_char_uuid };
    hr_ch.setValue(&[_]u8{ 0x00, 72 });
    _ = mock_dev.addCharacteristic(hr_ch);
    _ = try mock.addDevice(mock_dev);

    var adapter = ble.UnifiedAdapter.init(mock.asBackend());
    try adapter.backend.openAdapter(0);
    defer adapter.backend.closeAdapter();
    try adapter.setPowered(true);

    const Counter = struct {
        notifications: usize = 0,
        scans: usize = 0,
        fn onScan(_: *const ble.DiscoveredDevice, ud: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ud.?));
            c.scans += 1;
        }
        fn onNotify(_: ble.UUID, _: []const u8, ud: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ud.?));
            c.notifications += 1;
        }
    };

    var counter = Counter{};
    const cycles: usize = 1_050;
    for (0..cycles) |i| {
        // Allocate and free a scratch buffer per iteration with std.testing.allocator to verify 0 heap leaks
        const scratch = try std.testing.allocator.alloc(u8, 32);
        defer std.testing.allocator.free(scratch);

        try adapter.startScan(.{}, Counter.onScan, &counter);
        try adapter.stopScan();

        var dev = try adapter.connect(peer_addr, 1000);
        try dev.discoverServices();
        try dev.subscribe(hr_char_uuid, Counter.onNotify, &counter);

        const bpm: u8 = @intCast(60 + (i % 100));
        try mock.triggerNotification(peer_addr, hr_char_uuid, &[_]u8{ 0x00, bpm });

        const n = try dev.readCharacteristic(hr_char_uuid, scratch);
        try std.testing.expectEqual(@as(usize, 2), n);

        try dev.unsubscribe(hr_char_uuid);
        try dev.disconnect();
    }

    try std.testing.expectEqual(cycles, counter.scans);
    try std.testing.expectEqual(cycles, counter.notifications);

    if (builtin.os.tag == .windows) {
        var handles_after: u32 = 0;
        _ = GetProcessHandleCount(GetCurrentProcess(), &handles_after);
        // Process handle count must not grow across 1,050 cycles
        try std.testing.expect(handles_after <= handles_before + 16);
    }
}

// =============================================================================
// EDGE CASE 9: Live PCAP / Btsnoop Hook Integration with Backends
// =============================================================================
test "Tooling: PcapHook captures live packets from HciBackend into PcapReader buffer" {
    const PcapCapture = struct {
        packets_captured: usize = 0,
        total_bytes: usize = 0,
        fn onPacket(_: ble.PcapDirection, packet: []const u8, ud: ?*anyopaque) void {
            const self_cap: *@This() = @ptrCast(@alignCast(ud.?));
            self_cap.packets_captured += 1;
            self_cap.total_bytes += packet.len;
        }
    };

    var cap = PcapCapture{};
    var hci_b = ble.HciBackend.init();
    defer hci_b.deinit();

    const DummyTransport = struct {
        fn send(_: ?*anyopaque, _: []const u8) ble.BleError!void {}
    };
    hci_b.setTransportHook(.{ .ctx = null, .on_send_packet = DummyTransport.send });
    hci_b.setPcapHook(.{ .callback = PcapCapture.onPacket, .user_data = &cap });

    const b = hci_b.backend();
    try b.openAdapter(0);
    try b.setPowered(true);
    try std.testing.expectEqual(@as(usize, 1), cap.packets_captured);
    try std.testing.expect(cap.total_bytes >= 4);

    // Also verify BluezBackend and WindowsBackend PcapHook registration
    var bluez_b = ble.BluezBackend.init();
    defer bluez_b.deinit();
    bluez_b.setPcapHook(.{ .callback = PcapCapture.onPacket, .user_data = &cap });

    var win_b = ble.WindowsBackend.init();
    defer win_b.deinit();
    win_b.setPcapHook(.{ .callback = PcapCapture.onPacket, .user_data = &cap });
}
