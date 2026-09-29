//! # Nordic Semiconductor UART Service (NUS)
//!
//! Provides a bi-directional wireless UART / serial bridge over BLE.
//!
//! ## UUIDs
//! - Service UUID: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
//! - RX Characteristic (Client -> Peripheral, Write / Write Without Response):
//!   `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
//! - TX Characteristic (Peripheral -> Client, Notify):
//!   `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

const std = @import("std");
const types = @import("../core/types.zig");
const UUID = types.UUID;

pub const NordicUart = struct {
    pub const service_uuid_str = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
    pub const rx_uuid_str = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
    pub const tx_uuid_str = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

    pub const SERVICE_UUID = UUID.parse(service_uuid_str) catch unreachable;
    pub const RX_UUID = UUID.parse(rx_uuid_str) catch unreachable;
    pub const TX_UUID = UUID.parse(tx_uuid_str) catch unreachable;

    // Aliases
    pub const service_uuid = SERVICE_UUID;
    pub const rx_uuid = RX_UUID;
    pub const tx_uuid = TX_UUID;

    /// Default ATT MTU payload capacity (23 bytes MTU - 3 bytes ATT opcode & handle).
    pub const default_chunk_size: usize = 20;

    /// Iterator that slices a large transmission buffer into MTU-safe chunks.
    pub const PacketChunker = struct {
        data: []const u8,
        chunk_size: usize,
        offset: usize = 0,

        pub fn init(data: []const u8, chunk_size: usize) PacketChunker {
            return .{
                .data = data,
                .chunk_size = if (chunk_size == 0) default_chunk_size else chunk_size,
            };
        }

        pub fn next(self: *PacketChunker) ?[]const u8 {
            if (self.offset >= self.data.len) return null;
            const end = @min(self.offset + self.chunk_size, self.data.len);
            const slice = self.data[self.offset..end];
            self.offset = end;
            return slice;
        }

        pub fn reset(self: *PacketChunker) void {
            self.offset = 0;
        }
    };
};

// ============================================================================
// Unit Tests
// ============================================================================

test "NordicUart: UUID parsing and chunker" {
    try std.testing.expect(NordicUart.SERVICE_UUID.is128Bit());
    try std.testing.expect(NordicUart.RX_UUID.is128Bit());
    try std.testing.expect(NordicUart.TX_UUID.is128Bit());

    const message = "AT+COMMAND=SEND_TELEMETRY_SAMPLE_DATA_STREAM\r\n"; // 46 bytes
    var chunker = NordicUart.PacketChunker.init(message, 20);

    const chunk1 = chunker.next().?;
    try std.testing.expectEqual(@as(usize, 20), chunk1.len);
    try std.testing.expectEqualStrings("AT+COMMAND=SEND_TELE", chunk1);

    const chunk2 = chunker.next().?;
    try std.testing.expectEqual(@as(usize, 20), chunk2.len);
    try std.testing.expectEqualStrings("METRY_SAMPLE_DATA_ST", chunk2);

    const chunk3 = chunker.next().?;
    try std.testing.expectEqual(@as(usize, 6), chunk3.len);
    try std.testing.expectEqualStrings("REAM\r\n", chunk3);

    try std.testing.expect(chunker.next() == null);
}
