//! # L2CAP ACL Packet Reassembly Engine
//!
//! Implements Bluetooth Core Specification Vol 3, Part A (L2CAP).
//! Reassembles fragmented ACL Data packets (with Packet Boundary flags
//! PB_FIRST_FLUSH (0b10) and PB_CONTINUING (0b01)) into full L2CAP frames
//! (e.g. ATT PDUs or SMP frames) with zero dynamic allocation.

const std = @import("std");

/// Fixed L2CAP Channel Identifiers (CIDs)
pub const CID = struct {
    pub const NULL: u16 = 0x0000;
    pub const L2CAP_SIGNALING: u16 = 0x0001;
    pub const CONNECTIONLESS: u16 = 0x0002;
    pub const AMP_MANAGER: u16 = 0x0003;
    pub const ATT: u16 = 0x0004;
    pub const LE_SIGNALING: u16 = 0x0005;
    pub const SMP: u16 = 0x0006;
    pub const SMP_BREDR: u16 = 0x0007;
};

/// Packet Boundary (PB) flags from HCI ACL Data header
pub const PbFlag = struct {
    pub const FIRST_FLUSHABLE: u2 = 0b00;
    pub const CONTINUING: u2 = 0b01;
    pub const FIRST_NON_FLUSHABLE: u2 = 0b10;
    pub const COMPLETE_L2CAP: u2 = 0b11;
};

/// A fully reassembled L2CAP Basic Information Frame (B-Frame)
pub const L2capFrame = struct {
    conn_handle: u16,
    length: u16,
    cid: u16,
    payload: []const u8,
};

/// Zero-allocation, streaming ACL reassembler for a connection link.
pub fn AclReassembler(comptime max_frame_len: usize) type {
    return struct {
        const Self = @This();

        rx_buffer: [max_frame_len]u8 = undefined,
        active_handle: ?u16 = null,
        expected_len: u16 = 0,
        cid: u16 = 0,
        accumulated: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.active_handle = null;
            self.expected_len = 0;
            self.cid = 0;
            self.accumulated = 0;
        }

        /// Processes an incoming ACL packet fragment.
        /// If the packet is complete or this fragment completes an ongoing L2CAP frame,
        /// returns the finished `L2capFrame`.
        pub fn processFragment(
            self: *Self,
            handle: u16,
            pb_flag: u2,
            data: []const u8,
        ) !?L2capFrame {
            switch (pb_flag) {
                PbFlag.FIRST_NON_FLUSHABLE, PbFlag.FIRST_FLUSHABLE => {
                    // First fragment must contain at least the 4-byte L2CAP header: Length (2) + CID (2)
                    if (data.len < 4) return error.MalformedL2capHeader;

                    const l2cap_len = std.mem.readInt(u16, @ptrCast(data[0..2]), .little);
                    const l2cap_cid = std.mem.readInt(u16, @ptrCast(data[2..4]), .little);

                    if (l2cap_len > max_frame_len) {
                        return error.L2capFrameTooLarge;
                    }

                    self.active_handle = handle;
                    self.expected_len = l2cap_len;
                    self.cid = l2cap_cid;
                    self.accumulated = 0;

                    const payload_chunk = data[4..];
                    const to_copy = @min(payload_chunk.len, l2cap_len);
                    @memcpy(self.rx_buffer[0..to_copy], payload_chunk[0..to_copy]);
                    self.accumulated = to_copy;

                    if (self.accumulated == self.expected_len) {
                        // Single-packet L2CAP frame (common case when MTU <= 27 bytes)
                        const completed = L2capFrame{
                            .conn_handle = handle,
                            .length = self.expected_len,
                            .cid = self.cid,
                            .payload = self.rx_buffer[0..self.accumulated],
                        };
                        self.reset();
                        return completed;
                    }

                    return null; // Waiting for continuation fragments
                },

                PbFlag.CONTINUING => {
                    if (self.active_handle == null or self.active_handle.? != handle) {
                        return error.UnexpectedContinuationFragment;
                    }

                    if (self.accumulated + data.len > self.expected_len) {
                        return error.L2capLengthOverflow;
                    }

                    @memcpy(self.rx_buffer[self.accumulated .. self.accumulated + data.len], data);
                    self.accumulated += data.len;

                    if (self.accumulated == self.expected_len) {
                        const completed = L2capFrame{
                            .conn_handle = handle,
                            .length = self.expected_len,
                            .cid = self.cid,
                            .payload = self.rx_buffer[0..self.accumulated],
                        };
                        self.reset();
                        return completed;
                    }

                    return null;
                },

                else => return error.InvalidPacketBoundaryFlag,
            }
        }
    };
}

test "AclReassembler single packet frame" {
    var reassembler = AclReassembler(512).init();

    // L2CAP ATT Read Response: Len = 3, CID = 0x0004 (ATT), Payload = [0x0B, 0x12, 0x34]
    const raw_acl = [_]u8{
        0x03, 0x00, // L2CAP Length: 3
        0x04, 0x00, // CID: 0x0004 (ATT)
        0x0B, 0x12, 0x34, // ATT Read Response opcode + value
    };

    const result = try reassembler.processFragment(0x0040, PbFlag.FIRST_NON_FLUSHABLE, &raw_acl);
    try std.testing.expect(result != null);

    const frame = result.?;
    try std.testing.expectEqual(@as(u16, 0x0040), frame.conn_handle);
    try std.testing.expectEqual(@as(u16, CID.ATT), frame.cid);
    try std.testing.expectEqual(@as(u16, 3), frame.length);
    try std.testing.expectEqualSlices(u8, raw_acl[4..], frame.payload);
}

test "AclReassembler multi-fragment packet reassembly" {
    var reassembler = AclReassembler(512).init();

    // 10-byte L2CAP frame split into fragment 1 (header + 4 bytes) and fragment 2 (6 bytes)
    const frag1 = [_]u8{
        0x0A, 0x00, // Total L2CAP Length: 10
        0x04, 0x00, // CID: 0x0004
        0x01, 0x02, 0x03, 0x04, // First 4 bytes
    };
    const frag2 = [_]u8{
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, // Remaining 6 bytes
    };

    // First fragment
    const res1 = try reassembler.processFragment(0x0042, PbFlag.FIRST_NON_FLUSHABLE, &frag1);
    try std.testing.expect(res1 == null);

    // Second fragment
    const res2 = try reassembler.processFragment(0x0042, PbFlag.CONTINUING, &frag2);
    try std.testing.expect(res2 != null);

    const frame = res2.?;
    try std.testing.expectEqual(@as(u16, 0x0042), frame.conn_handle);
    try std.testing.expectEqual(@as(u16, CID.ATT), frame.cid);
    try std.testing.expectEqual(@as(u16, 10), frame.length);
    const expected = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqualSlices(u8, &expected, frame.payload);
}
