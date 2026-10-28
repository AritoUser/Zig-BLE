//! # Zig-BLE Coverage-Guided Fuzzing Suite (`std.testing.fuzz`)
//!
//! Provides native `std.testing.fuzz` targets and deterministic corpus regression tests for:
//! 1. Advertising TLV & Extended Advertising Parser (`AdIterator`, `AdvertisingReport`)
//! 2. Attribute Protocol (ATT) PDUs & Bearer State Machine (`AttPdu.parse`, `AttBearer`)
//! 3. Security Manager Protocol (SMP) PDUs & State Machine (`SmpPdu.parse`, `SmpStateMachine`)
//! 4. L2CAP LE Signaling, ACL Reassembly & EATT K-Frames (`L2capSignalingPdu`, `AclReassembler`, `EattBearer`)
//! 5. Pure-Zig D-Bus Wire Protocol Demarshaling (`FixedHeader`, `HeaderFields`, `MessageIter`)
//! 6. HCI Event Parser, H4 UART Stream Parser & H5 3-Wire SLIP Deframer (`parseEvent`, `H4StreamParser`, `H5StreamParser`)

const std = @import("std");
const core = @import("core/mod.zig");
const crypto = @import("crypto/mod.zig");
const l2cap = @import("l2cap/mod.zig");
const hci = @import("hci/mod.zig");
const wire = @import("dbus/wire/mod.zig");

/// Fuzz target 1: BLE Advertising & Scan Response parser (`AdIterator` + `AdvertisingReport`).
pub fn fuzzAdvertising(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var it = core.AdIterator.init(input);
    var steps: usize = 0;
    while (it.next()) |elem| {
        steps += 1;
        if (steps > input.len + 1) unreachable;
        _ = elem.asFlags();
        _ = elem.asLocalName();
        _ = elem.asValidLocalName();
        _ = elem.asTxPower();
        _ = elem.asAppearance();
        _ = elem.asManufacturerData();
        _ = elem.asServiceData16();
        _ = elem.asServiceData32();
        _ = elem.asServiceData128();
    }
    const report = core.AdvertisingReport.parse(input);
    _ = report.getValidLocalName();
    _ = report.getManufacturerData();
}

/// Fuzz target 2: ATT PDU parser & Client/Server Bearer State Machine.
pub fn fuzzAtt(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    if (core.AttPdu.parse(input)) |pdu| {
        var out: [520]u8 = undefined;
        _ = pdu.serialize(&out) catch {};
    } else |_| {}

    var server = core.AttBearer{};
    var storage: [32]u8 = @splat(0);
    var db = [_]core.AttServerAttribute{
        .{
            .handle = 0x0001,
            .uuid = core.UUID.from16(0x2A37),
            .permissions = .{ .readable = true, .writable = true },
            .value = &storage,
            .value_len = 16,
        },
    };
    var rsp_buf: [520]u8 = undefined;
    _ = server.handleServerRx(input, &db, &rsp_buf) catch {};
}

/// Fuzz target 3: SMP PDU parser & State Machine.
pub fn fuzzSmp(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    if (crypto.SmpPdu.parse(input)) |pdu| {
        var out: [128]u8 = undefined;
        _ = pdu.serialize(&out) catch {};
    } else |_| {}

    const addr_a = core.Address{ .bytes = .{ 1, 2, 3, 4, 5, 6 } };
    const addr_b = core.Address{ .bytes = .{ 6, 5, 4, 3, 2, 1 } };
    var sm = crypto.SmpStateMachine.init(.responder, addr_a, .public, addr_b, .public);
    var out_buf: [128]u8 = undefined;
    _ = sm.handlePdu(input, 100, &out_buf) catch {};
}

/// Fuzz target 4: L2CAP Signaling, ACL Reassembler & EATT K-Frame Reassembly.
pub fn fuzzL2capAndEatt(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    if (l2cap.L2capSignalingPdu.parse(input)) |sig| {
        var out: [128]u8 = undefined;
        _ = sig.serialize(&out) catch {};
    } else |_| {}

    var reassembler = l2cap.AclReassembler(256).init();
    if (input.len >= 4) {
        _ = reassembler.processFragment(0x0040, l2cap.PbFlag.FIRST_NON_FLUSHABLE, input) catch {};
    }

    var bearer = core.EattBearer{
        .cid = 0x0040,
        .mtu = 247,
        .mps = 64,
        .remote_credits = 8,
        .local_credits = 8,
    };
    _ = bearer.feedKFrame(input) catch {};
}

/// Fuzz target 5: Pure-Zig D-Bus Wire Protocol Demarshaling.
pub fn fuzzDbusWire(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    if (input.len < 16) return;
    const fixed = wire.FixedHeader.decode(input[0..16]) catch return;
    const fields = wire.HeaderFields.parse(input, fixed.fields_len) catch return;
    const body_offset = wire.header.calcBodyOffset(fixed.fields_len);
    if (input.len > body_offset) {
        const body_slice = input[body_offset..];
        const sig = fields.signature orelse "";
        var iter = wire.MessageIter.init(body_slice, 0, body_slice.len, sig);
        var steps: usize = 0;
        while (iter.hasMore() and steps < 64) : (steps += 1) {
            _ = iter.getString();
            _ = iter.getUInt32();
            _ = iter.next();
        }
    }
}

/// Fuzz target 6: HCI Events, H4 Stream Parser & H5 3-Wire SLIP Deframer.
pub fn fuzzHciAndUart(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    _ = hci.HciEvent.parse(input) catch {};

    var h4_parser = hci.H4StreamParser.init();
    var h4_storage: [260]u8 = undefined;
    _ = h4_parser.feed(input, &h4_storage) catch {};

    var h5_parser = hci.H5StreamParser.init();
    var h5_scratch: [540]u8 = undefined;
    _ = h5_parser.feed(input, &h5_scratch) catch {};
}

test "fuzz: Advertising TLV and Extended Advertising parser" {
    try std.testing.fuzz({}, fuzzAdvertising, .{});
}

test "fuzz: ATT PDU parser and Bearer state machine" {
    try std.testing.fuzz({}, fuzzAtt, .{});
}

test "fuzz: SMP PDU parser and State Machine" {
    try std.testing.fuzz({}, fuzzSmp, .{});
}

test "fuzz: L2CAP Signaling, ACL Reassembler and EATT K-Frame reassembly" {
    try std.testing.fuzz({}, fuzzL2capAndEatt, .{});
}

test "fuzz: Pure-Zig D-Bus Wire Demarshaling" {
    try std.testing.fuzz({}, fuzzDbusWire, .{});
}

test "fuzz: HCI Events, H4 Stream Parser and H5 3-Wire UART" {
    try std.testing.fuzz({}, fuzzHciAndUart, .{});
}
