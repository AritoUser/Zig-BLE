//! # HCI Three-Wire UART (H5) Transport Layer
//!
//! Strictly implements Bluetooth Core Specification v5.4, Vol 4, Part D
//! (Three-Wire UART Transport Layer / H5):
//! - SLIP byte stuffing (`0xC0` frame delimiter, `0xDB` escape sequences)
//! - 4-byte H5 packet header with 3-bit `seq`, 3-bit `ack`, `crc_present`, `reliable`,
//!   4-bit `pkt_type`, 12-bit `payload_len`, and 8-bit 2's-complement header checksum
//! - 16-bit CCITT-CRC data integrity check (polynomial `x^16 + x^12 + x^5 + 1`)
//! - Link establishment state machine (`SYNC` / `SYNC_RSP` / `CONFIG` / `CONFIG_RSP`)
//! - Sliding-window reliable delivery with sequence tracking, pure ACK generation,
//!   and retransmission queue.

const std = @import("std");

pub const H5Error = error{
    BufferTooSmall,
    InvalidSlipEscape,
    FrameTooShort,
    HeaderChecksumMismatch,
    PayloadLengthMismatch,
    CrcMismatch,
    WindowFull,
    LinkNotActive,
};

pub const SLIP_END: u8 = 0xC0;
pub const SLIP_ESC: u8 = 0xDB;
pub const SLIP_ESC_END: u8 = 0xDC;
pub const SLIP_ESC_ESC: u8 = 0xDD;
pub const SLIP_ESC_XON: u8 = 0xDE;
pub const SLIP_ESC_XOFF: u8 = 0xDF;

pub const H5PacketType = enum(u4) {
    ack = 0,
    hci_command = 1,
    acl_data = 2,
    sco_data = 3,
    hci_event = 4,
    iso_data = 5,
    vendor = 14,
    link_control = 15,
    _,
};

/// 4-byte H5 Packet Header (Bluetooth Core Spec Vol 4, Part D, Section 4).
pub const H5Header = struct {
    seq: u3 = 0,
    ack: u3 = 0,
    crc_present: bool = true,
    reliable: bool = true,
    pkt_type: H5PacketType = .hci_command,
    payload_len: u12 = 0,

    pub fn computeChecksum(b0: u8, b1: u8, b2: u8) u8 {
        return 0xFF -% (b0 +% b1 +% b2);
    }

    pub fn encode(self: H5Header) [4]u8 {
        const b0: u8 = @as(u8, self.seq) |
            (@as(u8, self.ack) << 3) |
            (if (self.crc_present) @as(u8, 0x40) else 0) |
            (if (self.reliable) @as(u8, 0x80) else 0);
        const b1: u8 = @as(u8, @intFromEnum(self.pkt_type)) |
            (@as(u8, @truncate(self.payload_len & 0x0F)) << 4);
        const b2: u8 = @truncate(self.payload_len >> 4);
        const b3: u8 = computeChecksum(b0, b1, b2);
        return .{ b0, b1, b2, b3 };
    }

    pub fn decode(raw: [4]u8) H5Error!H5Header {
        if ((raw[0] +% raw[1] +% raw[2] +% raw[3]) != 0xFF) {
            return H5Error.HeaderChecksumMismatch;
        }
        const payload_len: u12 = @as(u12, raw[1] >> 4) | (@as(u12, raw[2]) << 4);
        return H5Header{
            .seq = @truncate(raw[0] & 0x07),
            .ack = @truncate((raw[0] >> 3) & 0x07),
            .crc_present = (raw[0] & 0x40) != 0,
            .reliable = (raw[0] & 0x80) != 0,
            .pkt_type = @enumFromInt(@as(u4, @truncate(raw[1] & 0x0F))),
            .payload_len = payload_len,
        };
    }
};

/// Computes the 16-bit CCITT-CRC (reflected polynomial `0x8408`, initial value `0xFFFF`)
/// specified in Bluetooth Core Spec Vol 4, Part D, Section 6.
pub fn computeCrc16(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc ^= byte;
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            if ((crc & 0x0001) != 0) {
                crc = (crc >> 1) ^ 0x8408;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

/// Decoded H5 frame view referencing the caller-supplied unstuffed buffer.
pub const H5Frame = struct {
    header: H5Header,
    payload: []const u8,
};

/// Encodes an H5 header, payload, optional 16-bit CRC (big-endian per Vol 4, Part D, Section 6),
/// and SLIP framing (`0xC0 ... 0xC0`) into `out`.
pub fn encodeFrame(header: H5Header, payload: []const u8, out: []u8) H5Error!usize {
    var hdr = header;
    hdr.payload_len = @intCast(payload.len);
    const hdr_bytes = hdr.encode();

    var pos: usize = 0;
    if (pos >= out.len) return H5Error.BufferTooSmall;
    out[pos] = SLIP_END;
    pos += 1;

    for (hdr_bytes) |b| {
        pos = try appendSlipByte(out, pos, b);
    }
    for (payload) |b| {
        pos = try appendSlipByte(out, pos, b);
    }

    if (hdr.crc_present) {
        var crc: u16 = 0xFFFF;
        for (hdr_bytes) |b| crc = updateCrcByte(crc, b);
        for (payload) |b| crc = updateCrcByte(crc, b);
        // CRC-16 is transmitted big-endian (most significant byte first)
        pos = try appendSlipByte(out, pos, @truncate(crc >> 8));
        pos = try appendSlipByte(out, pos, @truncate(crc & 0xFF));
    }

    if (pos >= out.len) return H5Error.BufferTooSmall;
    out[pos] = SLIP_END;
    pos += 1;
    return pos;
}

fn updateCrcByte(crc_in: u16, byte: u8) u16 {
    var crc = crc_in ^ byte;
    var bit: u4 = 0;
    while (bit < 8) : (bit += 1) {
        if ((crc & 0x0001) != 0) {
            crc = (crc >> 1) ^ 0x8408;
        } else {
            crc >>= 1;
        }
    }
    return crc;
}

fn appendSlipByte(out: []u8, pos: usize, byte: u8) H5Error!usize {
    switch (byte) {
        SLIP_END => {
            if (pos + 2 > out.len) return H5Error.BufferTooSmall;
            out[pos] = SLIP_ESC;
            out[pos + 1] = SLIP_ESC_END;
            return pos + 2;
        },
        SLIP_ESC => {
            if (pos + 2 > out.len) return H5Error.BufferTooSmall;
            out[pos] = SLIP_ESC;
            out[pos + 1] = SLIP_ESC_ESC;
            return pos + 2;
        },
        else => {
            if (pos + 1 > out.len) return H5Error.BufferTooSmall;
            out[pos] = byte;
            return pos + 1;
        },
    }
}

/// Zero-allocation streaming SLIP deframer & H5 packet parser.
pub const H5StreamParser = struct {
    in_frame: bool = false,
    escaped: bool = false,
    unstuffed_len: usize = 0,

    pub fn init() H5StreamParser {
        return .{};
    }

    pub fn reset(self: *H5StreamParser) void {
        self.in_frame = false;
        self.escaped = false;
        self.unstuffed_len = 0;
    }

    /// Feeds incoming raw UART bytes into `scratch_buf`.
    /// When a complete SLIP frame (`0xC0 ... 0xC0`) is received, validates the H5 header checksum,
    /// payload length, and optional CCITT-CRC16, and returns the decoded `H5Frame` + bytes consumed.
    pub fn feed(
        self: *H5StreamParser,
        src: []const u8,
        scratch_buf: []u8,
    ) H5Error!?struct { frame: H5Frame, bytes_consumed: usize } {
        var idx: usize = 0;
        while (idx < src.len) {
            const b = src[idx];
            idx += 1;

            if (b == SLIP_END) {
                if (!self.in_frame or self.unstuffed_len == 0) {
                    // Start of frame or back-to-back 0xC0 sync delimiters
                    self.in_frame = true;
                    self.escaped = false;
                    self.unstuffed_len = 0;
                    continue;
                }

                // End of frame reached
                const total_len = self.unstuffed_len;
                self.reset();

                if (total_len < 4) return H5Error.FrameTooShort;
                const hdr = try H5Header.decode(scratch_buf[0..4].*);
                const expected_total: usize = 4 + @as(usize, hdr.payload_len) + (if (hdr.crc_present) @as(usize, 2) else 0);
                if (total_len != expected_total) return H5Error.PayloadLengthMismatch;

                const payload_slice = scratch_buf[4 .. 4 + hdr.payload_len];
                if (hdr.crc_present) {
                    const crc_calc = computeCrc16(scratch_buf[0 .. 4 + hdr.payload_len]);
                    const crc_rx = std.mem.readInt(u16, scratch_buf[4 + hdr.payload_len ..][0..2], .big);
                    if (crc_calc != crc_rx) return H5Error.CrcMismatch;
                }

                return .{
                    .frame = .{
                        .header = hdr,
                        .payload = payload_slice,
                    },
                    .bytes_consumed = idx,
                };
            }

            if (!self.in_frame) continue;

            if (self.escaped) {
                self.escaped = false;
                const unescaped: u8 = switch (b) {
                    SLIP_ESC_END => SLIP_END,
                    SLIP_ESC_ESC => SLIP_ESC,
                    SLIP_ESC_XON => 0x11,
                    SLIP_ESC_XOFF => 0x13,
                    else => return H5Error.InvalidSlipEscape,
                };
                if (self.unstuffed_len >= scratch_buf.len) return H5Error.BufferTooSmall;
                scratch_buf[self.unstuffed_len] = unescaped;
                self.unstuffed_len += 1;
            } else if (b == SLIP_ESC) {
                self.escaped = true;
            } else {
                if (self.unstuffed_len >= scratch_buf.len) return H5Error.BufferTooSmall;
                scratch_buf[self.unstuffed_len] = b;
                self.unstuffed_len += 1;
            }
        }
        return null;
    }
};

/// H5 Link Establishment & Reliable Sliding-Window Channel State Machine.
pub const H5Channel = struct {
    pub const LinkState = enum {
        uninitialized,
        initialized,
        active,
    };

    pub const ControlMsg = struct {
        pub const sync = [_]u8{ 0x01, 0x7E };
        pub const sync_rsp = [_]u8{ 0x02, 0x7D };
        pub const config = [_]u8{ 0x03, 0xFC, 0x14 }; // Window size = 4, CRC enabled
        pub const config_rsp = [_]u8{ 0x04, 0x7B, 0x14 };
    };

    pub const RetransmitSlot = struct {
        in_use: bool = false,
        seq: u3 = 0,
        pkt_type: H5PacketType = .hci_command,
        payload: [260]u8 = undefined,
        payload_len: usize = 0,
    };

    state: LinkState = .uninitialized,
    tx_seq: u3 = 0,
    expected_rx_seq: u3 = 0,
    unacked_count: u8 = 0,
    window_size: u8 = 4,
    use_crc: bool = true,
    window: [4]RetransmitSlot = @splat(.{}),

    pub fn init() H5Channel {
        return .{};
    }

    /// Encodes a link-control `SYNC` frame (`0x01 0x7E`) to initiate H5 link establishment.
    pub fn buildSyncFrame(self: *const H5Channel, out: []u8) H5Error!usize {
        _ = self;
        return encodeFrame(.{
            .seq = 0,
            .ack = 0,
            .crc_present = false,
            .reliable = false,
            .pkt_type = .link_control,
        }, &ControlMsg.sync, out);
    }

    /// Encodes a pure-ACK frame acknowledging all packets up to `self.expected_rx_seq`.
    pub fn buildAckFrame(self: *const H5Channel, out: []u8) H5Error!usize {
        return encodeFrame(.{
            .seq = 0,
            .ack = self.expected_rx_seq,
            .crc_present = self.use_crc,
            .reliable = false,
            .pkt_type = .ack,
        }, &[_]u8{}, out);
    }

    /// Queues and encodes a reliable H5 packet (`hci_command`, `acl_data`, `iso_data`).
    pub fn sendReliable(
        self: *H5Channel,
        pkt_type: H5PacketType,
        payload: []const u8,
        out: []u8,
    ) H5Error!usize {
        if (self.state != .active) return H5Error.LinkNotActive;
        if (self.unacked_count >= self.window_size) return H5Error.WindowFull;
        if (payload.len > 260) return H5Error.BufferTooSmall;

        const seq = self.tx_seq;
        for (&self.window) |*slot| {
            if (!slot.in_use) {
                slot.in_use = true;
                slot.seq = seq;
                slot.pkt_type = pkt_type;
                @memcpy(slot.payload[0..payload.len], payload);
                slot.payload_len = payload.len;
                break;
            }
        }
        self.tx_seq +%= 1;
        self.unacked_count += 1;

        return encodeFrame(.{
            .seq = seq,
            .ack = self.expected_rx_seq,
            .crc_present = self.use_crc,
            .reliable = true,
            .pkt_type = pkt_type,
        }, payload, out);
    }

    /// Processes an incoming decoded `H5Frame`:
    /// - Updates sliding window by retiring acknowledged TX frames (`frame.header.ack`)
    /// - Handles link-control (`SYNC`, `SYNC_RSP`, `CONFIG`, `CONFIG_RSP`) transitions
    /// - Verifies reliable sequence numbers (`frame.header.seq == expected_rx_seq`)
    /// - Optionally writes an immediate response frame (e.g. `SYNC_RSP`, `CONFIG_RSP`, or `ACK`) into `response_out`.
    pub fn onFrameReceived(
        self: *H5Channel,
        frame: H5Frame,
        response_out: []u8,
    ) H5Error!struct { response_len: usize, accepted_payload: ?[]const u8 } {
        // 1. Retire acknowledged frames when link is active
        if (self.state == .active) {
            self.retireAckedUpTo(frame.header.ack);
        }

        // 2. Link control packets (unreliable pkt_type == 15)
        if (frame.header.pkt_type == .link_control) {
            if (std.mem.eql(u8, frame.payload, &ControlMsg.sync)) {
                const n = try encodeFrame(.{
                    .seq = 0,
                    .ack = 0,
                    .crc_present = false,
                    .reliable = false,
                    .pkt_type = .link_control,
                }, &ControlMsg.sync_rsp, response_out);
                return .{ .response_len = n, .accepted_payload = null };
            }
            if (std.mem.eql(u8, frame.payload, &ControlMsg.sync_rsp)) {
                self.state = .initialized;
                const n = try encodeFrame(.{
                    .seq = 0,
                    .ack = 0,
                    .crc_present = false,
                    .reliable = false,
                    .pkt_type = .link_control,
                }, &ControlMsg.config, response_out);
                return .{ .response_len = n, .accepted_payload = null };
            }
            if (frame.payload.len >= 2 and std.mem.eql(u8, frame.payload[0..2], ControlMsg.config[0..2])) {
                if (self.state == .uninitialized) self.state = .initialized;
                const n = try encodeFrame(.{
                    .seq = 0,
                    .ack = 0,
                    .crc_present = false,
                    .reliable = false,
                    .pkt_type = .link_control,
                }, &ControlMsg.config_rsp, response_out);
                return .{ .response_len = n, .accepted_payload = null };
            }
            if (frame.payload.len >= 2 and std.mem.eql(u8, frame.payload[0..2], ControlMsg.config_rsp[0..2])) {
                self.state = .active;
                self.tx_seq = 0;
                self.expected_rx_seq = 0;
                return .{ .response_len = 0, .accepted_payload = null };
            }
            return .{ .response_len = 0, .accepted_payload = null };
        }

        // 3. Pure ACK packet
        if (frame.header.pkt_type == .ack) {
            return .{ .response_len = 0, .accepted_payload = null };
        }

        // 4. Reliable data packet
        if (frame.header.reliable) {
            if (frame.header.seq == self.expected_rx_seq) {
                self.expected_rx_seq +%= 1;
                const ack_len = try self.buildAckFrame(response_out);
                return .{ .response_len = ack_len, .accepted_payload = frame.payload };
            } else {
                // Out-of-order / duplicate reliable packet: re-send current expected_rx_seq ACK
                const ack_len = try self.buildAckFrame(response_out);
                return .{ .response_len = ack_len, .accepted_payload = null };
            }
        }

        return .{ .response_len = 0, .accepted_payload = frame.payload };
    }

    fn retireAckedUpTo(self: *H5Channel, ack: u3) void {
        // In H5, `ack` is the next sequence number expected by the peer.
        // Any in-flight slot whose `seq` precedes `ack` (modulo 8 within window) is acknowledged.
        for (&self.window) |*slot| {
            if (slot.in_use) {
                const dist: u3 = ack -% slot.seq;
                if (dist >= 1 and dist <= 4) {
                    slot.in_use = false;
                    if (self.unacked_count > 0) self.unacked_count -= 1;
                }
            }
        }
    }

    /// Re-encodes the oldest unacknowledged reliable packet for timeout retransmission.
    pub fn retransmitOldest(self: *const H5Channel, out: []u8) H5Error!?usize {
        for (&self.window) |*slot| {
            if (slot.in_use) {
                return try encodeFrame(.{
                    .seq = slot.seq,
                    .ack = self.expected_rx_seq,
                    .crc_present = self.use_crc,
                    .reliable = true,
                    .pkt_type = slot.pkt_type,
                }, slot.payload[0..slot.payload_len], out);
            }
        }
        return null;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "H5Header encode, checksum, and decode roundtrip" {
    const hdr = H5Header{
        .seq = 3,
        .ack = 5,
        .crc_present = true,
        .reliable = true,
        .pkt_type = .acl_data,
        .payload_len = 251,
    };
    const encoded = hdr.encode();
    try std.testing.expectEqual(@as(u8, 0xFF), encoded[0] +% encoded[1] +% encoded[2] +% encoded[3]);

    const decoded = try H5Header.decode(encoded);
    try std.testing.expectEqual(@as(u3, 3), decoded.seq);
    try std.testing.expectEqual(@as(u3, 5), decoded.ack);
    try std.testing.expect(decoded.crc_present);
    try std.testing.expect(decoded.reliable);
    try std.testing.expectEqual(H5PacketType.acl_data, decoded.pkt_type);
    try std.testing.expectEqual(@as(u12, 251), decoded.payload_len);

    // Corrupt header checksum
    var bad = encoded;
    bad[3] ^= 0x01;
    try std.testing.expectError(H5Error.HeaderChecksumMismatch, H5Header.decode(bad));
}

test "H5 SLIP byte stuffing, CRC-16, and streaming deframer" {
    // Payload containing SLIP special characters (0xC0, 0xDB)
    const payload = [_]u8{ 0x03, 0x0C, 0x00, SLIP_END, SLIP_ESC, 0x42 };
    var wire_buf: [64]u8 = undefined;
    const wire_len = try encodeFrame(.{
        .seq = 1,
        .ack = 2,
        .crc_present = true,
        .reliable = true,
        .pkt_type = .hci_command,
    }, &payload, &wire_buf);

    var parser = H5StreamParser.init();
    var scratch: [64]u8 = undefined;

    // Feed in 2 chunks to verify streaming state
    const half = wire_len / 2;
    try std.testing.expect((try parser.feed(wire_buf[0..half], &scratch)) == null);
    const res = (try parser.feed(wire_buf[half..wire_len], &scratch)).?;

    try std.testing.expectEqual(@as(u3, 1), res.frame.header.seq);
    try std.testing.expectEqual(@as(u3, 2), res.frame.header.ack);
    try std.testing.expectEqual(H5PacketType.hci_command, res.frame.header.pkt_type);
    try std.testing.expectEqualSlices(u8, &payload, res.frame.payload);
}

test "H5Channel link establishment, reliable sequence tracking, ACK retirement, and retransmission" {
    var host = H5Channel.init();
    var controller = H5Channel.init();
    var parser = H5StreamParser.init();
    var wire_buf: [128]u8 = undefined;
    var rsp_buf: [128]u8 = undefined;
    var scratch: [128]u8 = undefined;

    // 1. Host sends SYNC -> Controller replies SYNC_RSP
    const sync_len = try host.buildSyncFrame(&wire_buf);
    const sync_frame = (try parser.feed(wire_buf[0..sync_len], &scratch)).?.frame;
    const step1 = try controller.onFrameReceived(sync_frame, &rsp_buf);
    try std.testing.expect(step1.response_len > 0);

    // 2. Host receives SYNC_RSP -> transitions to initialized & sends CONFIG
    const sync_rsp_frame = (try parser.feed(rsp_buf[0..step1.response_len], &scratch)).?.frame;
    const step2 = try host.onFrameReceived(sync_rsp_frame, &wire_buf);
    try std.testing.expectEqual(H5Channel.LinkState.initialized, host.state);
    try std.testing.expect(step2.response_len > 0);

    // 3. Controller receives CONFIG -> replies CONFIG_RSP
    const cfg_frame = (try parser.feed(wire_buf[0..step2.response_len], &scratch)).?.frame;
    const step3 = try controller.onFrameReceived(cfg_frame, &rsp_buf);
    try std.testing.expect(step3.response_len > 0);

    // 4. Host receives CONFIG_RSP -> transitions to active!
    const cfg_rsp_frame = (try parser.feed(rsp_buf[0..step3.response_len], &scratch)).?.frame;
    _ = try host.onFrameReceived(cfg_rsp_frame, &wire_buf);
    controller.state = .active;
    try std.testing.expectEqual(H5Channel.LinkState.active, host.state);

    // 5. Host sends reliable HCI_Reset command (seq=0)
    const cmd_payload = [_]u8{ 0x03, 0x0C, 0x00 };
    const tx_len = try host.sendReliable(.hci_command, &cmd_payload, &wire_buf);
    try std.testing.expectEqual(@as(u8, 1), host.unacked_count);

    // Retransmit check before ACK
    const retx_len = (try host.retransmitOldest(&rsp_buf)).?;
    try std.testing.expectEqual(tx_len, retx_len);

    // Controller receives reliable frame (seq=0), accepts payload, and generates ACK (ack=1)
    const rx_cmd = (try parser.feed(wire_buf[0..tx_len], &scratch)).?.frame;
    const ctrl_rx = try controller.onFrameReceived(rx_cmd, &rsp_buf);
    try std.testing.expectEqualSlices(u8, &cmd_payload, ctrl_rx.accepted_payload.?);
    try std.testing.expect(ctrl_rx.response_len > 0);

    // Duplicate seq=0 is ignored by controller (accepted_payload == null)
    const dup_rx = try controller.onFrameReceived(rx_cmd, &rsp_buf);
    try std.testing.expect(dup_rx.accepted_payload == null);

    // Host processes ACK (ack=1) -> retires unacked slot!
    const ack_frame = (try parser.feed(rsp_buf[0..ctrl_rx.response_len], &scratch)).?.frame;
    _ = try host.onFrameReceived(ack_frame, &wire_buf);
    try std.testing.expectEqual(@as(u8, 0), host.unacked_count);
    try std.testing.expect((try host.retransmitOldest(&rsp_buf)) == null);
}

