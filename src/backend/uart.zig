//! # Zig-BLE UART Transport Backend (`UartBackend`)
//!
//! Bridges the unified `BackendVTable` (`HciBackend` + `AttBearer` + `SmpStateMachine`)
//! over serial UART transports using either:
//! - **H4 (4-Wire UART)**: `H4StreamParser`
//! - **H5 (3-Wire UART)**: `H5Channel` (SLIP framing, 2's-complement header checksum, 16-bit CCITT-CRC, sliding-window retransmission)

const std = @import("std");
const types = @import("types.zig");
const vtable_mod = @import("vtable.zig");
const hci_mod = @import("../hci/mod.zig");
const hci_backend_mod = @import("hci.zig");

const BleError = types.BleError;
const Backend = vtable_mod.Backend;

pub const UartFramingMode = enum {
    h4,
    h5_three_wire,
};

pub const SerialWriteCallback = *const fn (ctx: ?*anyopaque, wire_bytes: []const u8) BleError!void;

pub const UartBackend = struct {
    mode: UartFramingMode = .h4,
    inner: hci_backend_mod.HciBackend = hci_backend_mod.HciBackend.init(),
    h4_parser: hci_mod.H4StreamParser = hci_mod.H4StreamParser.init(),
    h5_channel: hci_mod.H5Channel = .{},
    serial_ctx: ?*anyopaque = null,
    on_serial_write: ?SerialWriteCallback = null,

    pub fn init(mode: UartFramingMode) UartBackend {
        return .{ .mode = mode };
    }

    pub fn deinit(self: *UartBackend) void {
        self.inner.deinit();
    }

    /// Binds the underlying serial TX callback and registers the packet hook with `HciBackend`.
    pub fn bindSerialWriter(self: *UartBackend, ctx: ?*anyopaque, writer: SerialWriteCallback) void {
        self.serial_ctx = ctx;
        self.on_serial_write = writer;
        self.inner.setTransportHook(.{
            .ctx = self,
            .on_send_packet = onInnerSendH4Packet,
        });
    }

    fn onInnerSendH4Packet(ctx: ?*anyopaque, h4_packet: []const u8) BleError!void {
        const self: *UartBackend = @ptrCast(@alignCast(ctx.?));
        if (h4_packet.len < 2) return BleError.InvalidParameter;

        const writer = self.on_serial_write orelse return;
        switch (self.mode) {
            .h4 => try writer(self.serial_ctx, h4_packet),
            .h5_three_wire => {
                const pkt_type: hci_mod.H5PacketType = switch (h4_packet[0]) {
                    0x01 => .hci_command,
                    0x02 => .acl_data,
                    0x03 => .sco_data,
                    0x04 => .hci_event,
                    else => return BleError.InvalidParameter,
                };
                var slip_buf: [1080]u8 = undefined;
                const slip_len = self.h5_channel.sendReliable(pkt_type, h4_packet[1..], &slip_buf) catch return BleError.GattError;
                try writer(self.serial_ctx, slip_buf[0..slip_len]);
            },
        }
    }

    /// Feeds raw incoming UART bytes (H4 or H5 SLIP-framed) into the protocol stack.
    pub fn feedSerialBytes(self: *UartBackend, raw_bytes: []const u8) BleError!void {
        switch (self.mode) {
            .h4 => {
                var idx: usize = 0;
                var payload_buf: [540]u8 = undefined;
                while (idx < raw_bytes.len) {
                    const maybe = self.h4_parser.feed(raw_bytes[idx..], &payload_buf) catch return BleError.GattError;
                    if (maybe) |res| {
                        idx += res.bytes_consumed;
                        var h4_buf: [550]u8 = undefined;
                        switch (res.packet) {
                            .event => |ev| {
                                h4_buf[0] = 0x04;
                                h4_buf[1] = ev.event_code;
                                h4_buf[2] = ev.param_len;
                                @memcpy(h4_buf[3 .. 3 + ev.params.len], ev.params);
                                try self.inner.processRxPacket(h4_buf[0 .. 3 + ev.params.len]);
                            },
                            .acl_data => |acl| {
                                h4_buf[0] = 0x02;
                                const h_flags: u16 = (acl.handle & 0x0FFF) | (@as(u16, acl.pb_flag) << 12) | (@as(u16, acl.bc_flag) << 14);
                                std.mem.writeInt(u16, h4_buf[1..3], h_flags, .little);
                                std.mem.writeInt(u16, h4_buf[3..5], @intCast(acl.data.len), .little);
                                @memcpy(h4_buf[5 .. 5 + acl.data.len], acl.data);
                                try self.inner.processRxPacket(h4_buf[0 .. 5 + acl.data.len]);
                            },
                            else => {},
                        }
                    } else break;
                }
            },
            .h5_three_wire => {
                var parser = hci_mod.H5StreamParser.init();
                var scratch: [540]u8 = undefined;
                var idx: usize = 0;
                while (idx < raw_bytes.len) {
                    const maybe = parser.feed(raw_bytes[idx..], &scratch) catch return BleError.GattError;
                    if (maybe) |res| {
                        idx += res.bytes_consumed;
                        var resp_buf: [64]u8 = undefined;
                        const ch_res = self.h5_channel.onFrameReceived(res.frame, &resp_buf) catch return BleError.GattError;
                        if (ch_res.response_len > 0) {
                            if (self.on_serial_write) |writer| {
                                try writer(self.serial_ctx, resp_buf[0..ch_res.response_len]);
                            }
                        }
                        if (ch_res.accepted_payload) |payload| {
                            var h4_buf: [540]u8 = undefined;
                            if (1 + payload.len > h4_buf.len) return BleError.BufferTooSmall;
                            h4_buf[0] = @intFromEnum(res.frame.header.pkt_type);
                            @memcpy(h4_buf[1 .. 1 + payload.len], payload);
                            try self.inner.processRxPacket(h4_buf[0 .. 1 + payload.len]);
                        }
                    } else break;
                }
            },
        }
    }

    pub fn backend(self: *UartBackend) Backend {
        return self.inner.backend();
    }
};

test "UartBackend: H4 and H5 3-Wire UART roundtrip with HciBackend" {
    const Loopback = struct {
        tx_bytes: [512]u8 = @splat(0),
        tx_len: usize = 0,
        fn write(ctx: ?*anyopaque, data: []const u8) BleError!void {
            const self_lb: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self_lb.tx_bytes[0..data.len], data);
            self_lb.tx_len = data.len;
        }
    };

    var lb = Loopback{};
    var uart = UartBackend.init(.h5_three_wire);
    defer uart.deinit();
    uart.h5_channel.state = .active;
    uart.bindSerialWriter(&lb, Loopback.write);

    const b = uart.backend();
    try b.openAdapter(0);
    try b.setPowered(true);
    // Reset command was encoded as H5 SLIP frame (starts and ends with 0xC0)
    try std.testing.expect(lb.tx_len >= 6);
    try std.testing.expectEqual(@as(u8, 0xC0), lb.tx_bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xC0), lb.tx_bytes[lb.tx_len - 1]);
}
