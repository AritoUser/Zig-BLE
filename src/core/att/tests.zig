//! # ATT Engine Unit Tests & State Machine Tests
const std = @import("std");
const core_types = @import("../types.zig");
const UUID = core_types.UUID;
const gatt = @import("../gatt.zig");
const att = @import("../att.zig");

const AttOpcode = att.AttOpcode;
const AttErrorCode = att.AttErrorCode;
const AttError = att.AttError;
const AttPdu = att.AttPdu;
const AttBearer = att.AttBearer;
const BearerState = att.BearerState;
const AttServerAttribute = att.AttServerAttribute;
const ServiceDiscoveryClient = att.ServiceDiscoveryClient;
const LongReadClient = att.LongReadClient;
const QueuedWriteClient = att.QueuedWriteClient;
const ErrorResponse = att.ErrorResponse;
const ExchangeMtuRequest = att.ExchangeMtuRequest;
const HandleValueNotification = att.HandleValueNotification;
const WriteCommand = att.WriteCommand;
const PrepareWriteRequest = att.PrepareWriteRequest;
const SignedWriteCommand = att.SignedWriteCommand;

test "ATT: ErrorResponse encode and decode" {
    const err = ErrorResponse{
        .request_opcode = @intFromEnum(AttOpcode.read_req),
        .handle = 0x0024,
        .error_code = .read_not_permitted,
    };
    var buf: [16]u8 = undefined;
    const len = try err.encode(&buf);
    try std.testing.expectEqual(@as(usize, 5), len);

    const parsed = try AttPdu.parse(buf[0..len]);
    try std.testing.expectEqual(err.request_opcode, parsed.error_rsp.request_opcode);
    try std.testing.expectEqual(err.handle, parsed.error_rsp.handle);
    try std.testing.expectEqual(err.error_code, parsed.error_rsp.error_code);
}

test "ATT: Exchange MTU roundtrip" {
    const req = ExchangeMtuRequest{ .client_rx_mtu = 512 };
    var buf: [8]u8 = undefined;
    const len = try req.encode(&buf);

    const parsed = try AttPdu.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 512), parsed.exchange_mtu_req.client_rx_mtu);
}

test "ATT: ReadByGroupTypeResponse Service Discovery Iterator" {
    // Construct ReadByGroupTypeResponse with 2 services (UUID16: 0x1800 GAP, 0x180D Heart Rate)
    // Opcode = 0x11, Length = 6 (start handle: 2B, end handle: 2B, UUID16: 2B)
    const raw_rsp = [_]u8{
        0x11, 0x06,
        0x01, 0x00, 0x07, 0x00, 0x00, 0x18, // Service 1: 0x0001..0x0007 -> 0x1800
        0x10, 0x00, 0x15, 0x00, 0x0D, 0x18, // Service 2: 0x0010..0x0015 -> 0x180D
    };

    const parsed = try AttPdu.parse(&raw_rsp);
    var it = parsed.read_by_group_type_rsp.iterator();

    const s1 = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0001), s1.start_handle);
    try std.testing.expectEqual(@as(u16, 0x0007), s1.end_handle);
    try std.testing.expectEqual(UUID.from16(0x1800), s1.uuid);

    const s2 = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0010), s2.start_handle);
    try std.testing.expectEqual(@as(u16, 0x0015), s2.end_handle);
    try std.testing.expectEqual(UUID.from16(0x180D), s2.uuid);

    try std.testing.expect(it.next() == null);
}

test "ATT: HandleValueNotification encode and decode" {
    const ntf = HandleValueNotification{
        .handle = 0x0012,
        .value = &[_]u8{ 0x00, 0x48 }, // 72 bpm
    };
    var buf: [32]u8 = undefined;
    const len = try ntf.encode(&buf);

    const parsed = try AttPdu.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 0x0012), parsed.handle_value_ntf.handle);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x48 }, parsed.handle_value_ntf.value);
}

test "ATT: FindInformationResponse iterator" {
    // 0x05 (opcode), 0x01 (format: 16-bit UUID)
    // Item 1: handle 0x0010, UUID 0x2803 (Characteristic)
    // Item 2: handle 0x0011, UUID 0x2A37 (Heart Rate Measurement)
    const raw = [_]u8{
        0x05, 0x01,
        0x10, 0x00,
        0x03, 0x28,
        0x11, 0x00,
        0x37, 0x2A,
    };
    const parsed = try AttPdu.parse(&raw);
    var it = parsed.find_info_rsp.iterator();

    const item1 = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0010), item1.handle);
    try std.testing.expectEqual(UUID.from16(0x2803), item1.uuid);

    const item2 = it.next().?;
    try std.testing.expectEqual(@as(u16, 0x0011), item2.handle);
    try std.testing.expectEqual(UUID.from16(0x2A37), item2.uuid);

    try std.testing.expect(it.next() == null);
}

test "ATT: ReadByTypeResponse Characteristic Declaration iterator" {
    // 0x09 (opcode), length = 7 (handle: 2B, prop: 1B, val_handle: 2B, uuid16: 2B)
    const raw = [_]u8{
        0x09, 0x07,
        0x0002, 0x00, 0x10, 0x03, 0x00, 0x00, 0x2A, // handle=2, prop=notify(0x10), val_handle=3, uuid=0x2A00
    };
    const parsed = try AttPdu.parse(&raw);
    var it = parsed.read_by_type_rsp.iterator();

    const elem = it.next().?;
    try std.testing.expectEqual(@as(u16, 2), elem.handle);
    try std.testing.expectEqual(@as(usize, 5), elem.value.len);
    try std.testing.expectEqual(@as(u8, 0x10), elem.value[0]); // notify property
}

test "ATT: WriteCommand and PrepareWrite roundtrip" {
    const cmd = WriteCommand{
        .handle = 0x0042,
        .value = "Hello BLE",
    };
    var buf: [64]u8 = undefined;
    const len = try cmd.encode(&buf);

    const parsed = try AttPdu.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 0x0042), parsed.write_cmd.handle);
    try std.testing.expectEqualStrings("Hello BLE", parsed.write_cmd.value);

    const prep = PrepareWriteRequest{
        .handle = 0x0043,
        .offset = 18,
        .part_value = "Long write payload chunk",
    };
    const prep_len = try prep.encode(&buf);
    const parsed_prep = try AttPdu.parse(buf[0..prep_len]);
    try std.testing.expectEqual(@as(u16, 0x0043), parsed_prep.prepare_write_req.handle);
    try std.testing.expectEqual(@as(u16, 18), parsed_prep.prepare_write_req.offset);
    try std.testing.expectEqualStrings("Long write payload chunk", parsed_prep.prepare_write_req.part_value);
}

test "ATT: SignedWriteCommand encode and decode roundtrip" {
    const sw = SignedWriteCommand{
        .handle = 0x0055,
        .value = "AuthPayload",
        .signature = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    };
    var buf: [64]u8 = undefined;
    const len = try sw.encode(&buf);

    const parsed = try AttPdu.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 0x0055), parsed.signed_write_cmd.handle);
    try std.testing.expectEqualStrings("AuthPayload", parsed.signed_write_cmd.value);
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, parsed.signed_write_cmd.signature);
}



test "ATT State Machine: Request-Response correlation, duplicate response, and 30s timeout" {
    var client = AttBearer{};
    var server = AttBearer{};
    var tx_buf: [64]u8 = undefined;
    var rsp_buf: [64]u8 = undefined;

    // 1. Exchange MTU Request (Client -> Server -> Client)
    const req_len = try client.beginRequest(.{ .exchange_mtu_req = .{ .client_rx_mtu = 247 } }, 1000, &tx_buf);
    try std.testing.expectEqual(BearerState.waiting_response, client.state);

    // Concurrent request while waiting must fail with TransactionInProgress
    try std.testing.expectError(AttError.TransactionInProgress, client.beginRequest(.{ .read_req = .{ .handle = 0x0001 } }, 1005, &tx_buf));

    var empty_db: [0]AttServerAttribute = .{};
    const rsp_len = try server.handleServerRx(tx_buf[0..req_len], &empty_db, &rsp_buf);
    const ev = try client.handleClientRx(rsp_buf[0..rsp_len], null);
    try std.testing.expectEqual(@as(u16, 247), client.mtu);
    try std.testing.expectEqual(@as(u16, 247), server.mtu);
    try std.testing.expect(ev == .response);

    // 2. Duplicate response when idle must be rejected
    try std.testing.expectError(AttError.UnexpectedResponse, client.handleClientRx(rsp_buf[0..rsp_len], null));

    // 3. 30-second Transaction Timeout
    _ = try client.beginRequest(.{ .read_req = .{ .handle = 0x0010 } }, 5000, &tx_buf);
    try client.checkTimeout(34_999);
    try std.testing.expectError(AttError.TransactionTimeout, client.checkTimeout(35_000));
    try std.testing.expectEqual(BearerState.timed_out, client.state);
    try std.testing.expectError(AttError.BearerTimedOut, client.beginRequest(.{ .read_req = .{ .handle = 0x0010 } }, 35_001, &tx_buf));
}

test "ATT State Machine: Server ReadBlob and Queued Write (PrepareWrite + ExecuteWrite)" {
    var client = AttBearer{};
    var server = AttBearer{};
    client.mtu = 23;
    server.mtu = 23;

    var storage: [64]u8 = @splat(0);
    @memcpy(storage[0..30], "0123456789ABCDEFGHIJKLMNOPQRST");
    var db = [_]AttServerAttribute{
        .{
            .handle = 0x0010,
            .uuid = UUID.from16(0x2A37),
            .permissions = .{ .readable = true, .writable = true },
            .value = &storage,
            .value_len = 30,
        },
    };

    var req_buf: [64]u8 = undefined;
    var rsp_buf: [64]u8 = undefined;
    var read_out: [64]u8 = undefined;

    // Long Read via LongReadClient
    var long_reader = LongReadClient{ .handle = 0x0010 };
    while (long_reader.nextRequest()) |req_pdu| {
        const req_len = try client.beginRequest(req_pdu, 100, &req_buf);
        const rsp_len = try server.handleServerRx(req_buf[0..req_len], &db, &rsp_buf);
        const ev = try client.handleClientRx(rsp_buf[0..rsp_len], null);
        switch (ev.response) {
            .read_rsp => |r| try long_reader.onChunkReceived(r.value, client.mtu, &read_out),
            .read_blob_rsp => |r| try long_reader.onChunkReceived(r.part_value, client.mtu, &read_out),
            else => unreachable,
        }
    }
    try std.testing.expectEqualStrings("0123456789ABCDEFGHIJKLMNOPQRST", read_out[0..long_reader.offset]);

    // Queued Write via QueuedWriteClient
    const new_payload = "ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210";
    var q_writer = QueuedWriteClient{ .handle = 0x0010, .payload = new_payload };
    while (q_writer.nextRequest(client.mtu)) |req_pdu| {
        const req_len = try client.beginRequest(req_pdu, 200, &req_buf);
        const rsp_len = try server.handleServerRx(req_buf[0..req_len], &db, &rsp_buf);
        _ = try client.handleClientRx(rsp_buf[0..rsp_len], null);
    }
    try std.testing.expectEqualStrings(new_payload, db[0].value[0..db[0].value_len]);
}
