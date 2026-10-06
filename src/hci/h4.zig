//! # HCI UART H4 Framing Engine
//!
//! Implements Bluetooth Core Specification Vol 4, Part A (HCI UART Transport Layer).
//! Provides a zero-allocation streaming parser and serializer for H4 packets:
//! - 0x01: HCI Command Packet
//! - 0x02: HCI ACL Data Packet
//! - 0x03: HCI Synchronous Data Packet (SCO)
//! - 0x04: HCI Event Packet
//! - 0x05: HCI ISO Data Packet

const std = @import("std");

/// Standard H4 packet indicator byte
pub const H4Type = enum(u8) {
    command = 0x01,
    acl_data = 0x02,
    sco_data = 0x03,
    event = 0x04,
    iso_data = 0x05,
    _,
};

/// Represents a parsed HCI packet view directly referencing the payload buffer.
pub const H4Packet = union(H4Type) {
    command: struct {
        opcode: u16,
        param_len: u8,
        params: []const u8,
    },
    acl_data: struct {
        handle: u16,
        pb_flag: u2, // Packet Boundary flag
        bc_flag: u2, // Broadcast flag
        data: []const u8,
    },
    sco_data: struct {
        handle: u16,
        data: []const u8,
    },
    event: struct {
        event_code: u8,
        param_len: u8,
        params: []const u8,
    },
    iso_data: struct {
        handle: u16,
        data: []const u8,
    },
};

/// Zero-allocation streaming parser for continuous UART byte streams.
pub const H4StreamParser = struct {
    pub const State = enum {
        waiting_type,
        reading_header,
        reading_payload,
    };

    state: State = .waiting_type,
    packet_type: ?H4Type = null,
    header_buf: [4]u8 = [_]u8{0} ** 4,
    header_bytes_read: usize = 0,
    expected_header_len: usize = 0,
    expected_payload_len: usize = 0,
    payload_bytes_read: usize = 0,

    pub fn init() H4StreamParser {
        return .{};
    }

    pub fn reset(self: *H4StreamParser) void {
        self.state = .waiting_type;
        self.packet_type = null;
        self.header_bytes_read = 0;
        self.expected_header_len = 0;
        self.expected_payload_len = 0;
        self.payload_bytes_read = 0;
    }

    /// Feeds incoming UART bytes. When a complete packet has been assembled into `payload_buf`,
    /// returns the parsed `H4Packet` and the count of bytes consumed from `src`.
    pub fn feed(
        self: *H4StreamParser,
        src: []const u8,
        payload_buf: []u8,
    ) !?struct { packet: H4Packet, bytes_consumed: usize } {
        var src_idx: usize = 0;

        while (src_idx < src.len) {
            switch (self.state) {
                .waiting_type => {
                    const raw_type = src[src_idx];
                    src_idx += 1;
                    const ptype: H4Type = @enumFromInt(raw_type);
                    switch (ptype) {
                        .command => {
                            self.packet_type = .command;
                            self.expected_header_len = 3; // Opcode (2) + Param Len (1)
                            self.state = .reading_header;
                            self.header_bytes_read = 0;
                        },
                        .acl_data => {
                            self.packet_type = .acl_data;
                            self.expected_header_len = 4; // Handle/Flags (2) + Data Len (2)
                            self.state = .reading_header;
                            self.header_bytes_read = 0;
                        },
                        .sco_data => {
                            self.packet_type = .sco_data;
                            self.expected_header_len = 3; // Handle (2) + Len (1)
                            self.state = .reading_header;
                            self.header_bytes_read = 0;
                        },
                        .event => {
                            self.packet_type = .event;
                            self.expected_header_len = 2; // Event Code (1) + Param Len (1)
                            self.state = .reading_header;
                            self.header_bytes_read = 0;
                        },
                        .iso_data => {
                            self.packet_type = .iso_data;
                            self.expected_header_len = 4; // Handle/Flags (2) + Len (2)
                            self.state = .reading_header;
                            self.header_bytes_read = 0;
                        },
                        _ => return error.InvalidH4Indicator,
                    }
                },
                .reading_header => {
                    const needed = self.expected_header_len - self.header_bytes_read;
                    const available = src.len - src_idx;
                    const chunk = @min(needed, available);
                    @memcpy(self.header_buf[self.header_bytes_read .. self.header_bytes_read + chunk], src[src_idx .. src_idx + chunk]);
                    self.header_bytes_read += chunk;
                    src_idx += chunk;

                    if (self.header_bytes_read == self.expected_header_len) {
                        switch (self.packet_type.?) {
                            .command => {
                                self.expected_payload_len = self.header_buf[2];
                            },
                            .acl_data => {
                                self.expected_payload_len = std.mem.readInt(u16, @ptrCast(self.header_buf[2..4]), .little);
                            },
                            .sco_data => {
                                self.expected_payload_len = self.header_buf[2];
                            },
                            .event => {
                                self.expected_payload_len = self.header_buf[1];
                            },
                            .iso_data => {
                                const raw_len = std.mem.readInt(u16, @ptrCast(self.header_buf[2..4]), .little);
                                self.expected_payload_len = raw_len & 0x3FFF;
                            },
                            _ => unreachable,
                        }

                        if (self.expected_payload_len > payload_buf.len) {
                            return error.PayloadBufferTooSmall;
                        }

                        self.payload_bytes_read = 0;
                        if (self.expected_payload_len == 0) {
                            // Immediate zero-length payload packet
                            const completed_packet = self.finalizePacket(payload_buf[0..0]);
                            self.reset();
                            return .{ .packet = completed_packet, .bytes_consumed = src_idx };
                        } else {
                            self.state = .reading_payload;
                        }
                    }
                },
                .reading_payload => {
                    const needed = self.expected_payload_len - self.payload_bytes_read;
                    const available = src.len - src_idx;
                    const chunk = @min(needed, available);
                    @memcpy(payload_buf[self.payload_bytes_read .. self.payload_bytes_read + chunk], src[src_idx .. src_idx + chunk]);
                    self.payload_bytes_read += chunk;
                    src_idx += chunk;

                    if (self.payload_bytes_read == self.expected_payload_len) {
                        const completed_packet = self.finalizePacket(payload_buf[0..self.expected_payload_len]);
                        self.reset();
                        return .{ .packet = completed_packet, .bytes_consumed = src_idx };
                    }
                },
            }
        }

        return null;
    }

    fn finalizePacket(self: *H4StreamParser, payload: []const u8) H4Packet {
        return switch (self.packet_type.?) {
            .command => .{
                .command = .{
                    .opcode = std.mem.readInt(u16, @ptrCast(self.header_buf[0..2]), .little),
                    .param_len = self.header_buf[2],
                    .params = payload,
                },
            },
            .acl_data => blk: {
                const handle_and_flags = std.mem.readInt(u16, @ptrCast(self.header_buf[0..2]), .little);
                break :blk .{
                    .acl_data = .{
                        .handle = handle_and_flags & 0x0FFF,
                        .pb_flag = @truncate((handle_and_flags >> 12) & 0x03),
                        .bc_flag = @truncate((handle_and_flags >> 14) & 0x03),
                        .data = payload,
                    },
                };
            },
            .sco_data => .{
                .sco_data = .{
                    .handle = std.mem.readInt(u16, @ptrCast(self.header_buf[0..2]), .little) & 0x0FFF,
                    .data = payload,
                },
            },
            .event => .{
                .event = .{
                    .event_code = self.header_buf[0],
                    .param_len = self.header_buf[1],
                    .params = payload,
                },
            },
            .iso_data => .{
                .iso_data = .{
                    .handle = std.mem.readInt(u16, @ptrCast(self.header_buf[0..2]), .little) & 0x0FFF,
                    .data = payload,
                },
            },
            _ => unreachable,
        };
    }
};

/// Encodes HCI packets into H4 stream bytes.
pub const H4Serializer = struct {
    /// Serializes an HCI Command into the output buffer with the 0x01 prefix.
    pub fn serializeCommand(out: []u8, opcode: u16, params: []const u8) !usize {
        const total = 1 + 3 + params.len;
        if (out.len < total) return error.BufferTooSmall;
        out[0] = @intFromEnum(H4Type.command);
        std.mem.writeInt(u16, @ptrCast(out[1..3]), opcode, .little);
        out[3] = @intCast(params.len);
        @memcpy(out[4 .. 4 + params.len], params);
        return total;
    }

    /// Serializes an HCI ACL Data packet into the output buffer with the 0x02 prefix.
    pub fn serializeAclData(out: []u8, handle: u16, pb_flag: u2, bc_flag: u2, payload: []const u8) !usize {
        const total = 1 + 4 + payload.len;
        if (out.len < total) return error.BufferTooSmall;
        out[0] = @intFromEnum(H4Type.acl_data);
        const handle_flags: u16 = (handle & 0x0FFF) | (@as(u16, pb_flag) << 12) | (@as(u16, bc_flag) << 14);
        std.mem.writeInt(u16, @ptrCast(out[1..3]), handle_flags, .little);
        std.mem.writeInt(u16, @ptrCast(out[3..5]), @intCast(payload.len), .little);
        @memcpy(out[5 .. 5 + payload.len], payload);
        return total;
    }

    /// Serializes an HCI Event packet into the output buffer with the 0x04 prefix.
    pub fn serializeEvent(out: []u8, event_code: u8, params: []const u8) !usize {
        const total = 1 + 2 + params.len;
        if (out.len < total) return error.BufferTooSmall;
        out[0] = @intFromEnum(H4Type.event);
        out[1] = event_code;
        out[2] = @intCast(params.len);
        @memcpy(out[3 .. 3 + params.len], params);
        return total;
    }
};

test "H4Serializer and H4StreamParser Command roundtrip" {
    var raw_out: [64]u8 = undefined;
    const cmd_params = [_]u8{ 0x01, 0x02, 0x03 };
    const serialized_len = try H4Serializer.serializeCommand(&raw_out, 0x0C03, &cmd_params);

    var parser = H4StreamParser.init();
    var payload_storage: [64]u8 = undefined;

    // Feed in two chunks to test streaming reassembly
    const chunk1 = raw_out[0..3];
    const chunk2 = raw_out[3..serialized_len];

    const res1 = try parser.feed(chunk1, &payload_storage);
    try std.testing.expect(res1 == null);

    const res2 = try parser.feed(chunk2, &payload_storage);
    try std.testing.expect(res2 != null);

    const pkt = res2.?.packet;
    try std.testing.expectEqual(H4Type.command, std.meta.activeTag(pkt));
    try std.testing.expectEqual(@as(u16, 0x0C03), pkt.command.opcode);
    try std.testing.expectEqual(@as(u8, 3), pkt.command.param_len);
    try std.testing.expectEqualSlices(u8, &cmd_params, pkt.command.params);
}

test "H4StreamParser ACL Data fragmentation" {
    var raw_out: [128]u8 = undefined;
    const acl_payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    const written = try H4Serializer.serializeAclData(&raw_out, 0x0040, 0b10, 0b00, &acl_payload);

    var parser = H4StreamParser.init();
    var payload_storage: [128]u8 = undefined;

    const res = try parser.feed(raw_out[0..written], &payload_storage);
    try std.testing.expect(res != null);

    const pkt = res.?.packet;
    try std.testing.expectEqual(H4Type.acl_data, std.meta.activeTag(pkt));
    try std.testing.expectEqual(@as(u16, 0x0040), pkt.acl_data.handle);
    try std.testing.expectEqual(@as(u2, 0b10), pkt.acl_data.pb_flag);
    try std.testing.expectEqualSlices(u8, &acl_payload, pkt.acl_data.data);
}
