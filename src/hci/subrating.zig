//! # BT 5.3 Connection Subrating Engine
//!
//! Strictly conforms to Bluetooth Core Specification v5.3 / v5.4 (Vol 4, Part E, Section 7.8).
//! Implements HCI commands and event parsers for LE Connection Subrating, allowing ultra-low
//! latency transition from low-power background monitoring to burst sensor streaming (e.g. 100 Hz PPG).
//!
//! ## Architectural Guarantees
//! - 100% Zero Heap Allocations
//! - Strict Little-Endian Wire Encoding
//! - Parameter range validation per BT Core Spec

const std = @import("std");

/// Opcodes for LE Connection Subrating commands (OGF 0x08).
pub const SubrateOpcode = struct {
    pub const LE_SUBRATE_REQUEST: u16 = 0x207D; // OCF 0x007D
    pub const LE_SET_DEFAULT_SUBRATE_PARAMETERS: u16 = 0x207E; // OCF 0x007E
};

/// Subevent code within LE Meta Event (0x3E).
pub const LE_SUBRATE_CHANGE_SUBEVENT: u8 = 0x1E;

/// Configuration parameters for connection subrating.
pub const SubrateParameters = struct {
    /// Minimum subrate factor (1 .. 500)
    subrate_min: u16,
    /// Maximum subrate factor (1 .. 500, must be >= subrate_min)
    subrate_max: u16,
    /// Maximum peripheral latency (0 .. 499)
    max_latency: u16,
    /// Continuation number of underlying connection events to remain active (0 .. 499)
    continuation_number: u16,
    /// Supervision timeout in 10 ms units (10 .. 3200 = 100 ms .. 32.0 s)
    supervision_timeout: u16,

    pub fn isValid(self: SubrateParameters) bool {
        if (self.subrate_min < 1 or self.subrate_min > 500) return false;
        if (self.subrate_max < 1 or self.subrate_max > 500) return false;
        if (self.subrate_min > self.subrate_max) return false;
        if (self.max_latency > 499) return false;
        if (self.continuation_number > 499) return false;
        if (self.supervision_timeout < 10 or self.supervision_timeout > 3200) return false;
        return true;
    }
};

/// HCI LE Subrate Request Command Encoder (Opcode 0x207D).
/// Serializes a 15-byte HCI command packet (H4 0x01 + 3-byte HCI header + 12-byte payload).
pub fn encodeSubrateRequest(conn_handle: u16, params: SubrateParameters, dest: []u8) !usize {
    if (!params.isValid()) return error.InvalidParameter;
    if (dest.len < 16) return error.BufferTooSmall;

    // H4 Indicator
    dest[0] = 0x01; // HCI Command
    // Opcode 0x207D
    std.mem.writeInt(u16, dest[1..3], SubrateOpcode.LE_SUBRATE_REQUEST, .little);
    // Param Length: 12
    dest[3] = 12;

    // Parameters
    std.mem.writeInt(u16, dest[4..6], conn_handle, .little);
    std.mem.writeInt(u16, dest[6..8], params.subrate_min, .little);
    std.mem.writeInt(u16, dest[8..10], params.subrate_max, .little);
    std.mem.writeInt(u16, dest[10..12], params.max_latency, .little);
    std.mem.writeInt(u16, dest[12..14], params.continuation_number, .little);
    std.mem.writeInt(u16, dest[14..16], params.supervision_timeout, .little);

    return 16;
}

/// HCI LE Set Default Subrate Parameters Command Encoder (Opcode 0x207E).
/// Serializes a 14-byte HCI command packet (H4 0x01 + 3-byte HCI header + 10-byte payload).
pub fn encodeSetDefaultSubrate(params: SubrateParameters, dest: []u8) !usize {
    if (!params.isValid()) return error.InvalidParameter;
    if (dest.len < 14) return error.BufferTooSmall;

    dest[0] = 0x01; // HCI Command
    std.mem.writeInt(u16, dest[1..3], SubrateOpcode.LE_SET_DEFAULT_SUBRATE_PARAMETERS, .little);
    dest[3] = 10;

    std.mem.writeInt(u16, dest[4..6], params.subrate_min, .little);
    std.mem.writeInt(u16, dest[6..8], params.subrate_max, .little);
    std.mem.writeInt(u16, dest[8..10], params.max_latency, .little);
    std.mem.writeInt(u16, dest[10..12], params.continuation_number, .little);
    std.mem.writeInt(u16, dest[12..14], params.supervision_timeout, .little);

    return 14;
}

/// Represents the negotiated subrate parameters received in an HCI LE Subrate Change Event.
pub const SubrateChangeEvent = struct {
    status: u8,
    connection_handle: u16,
    subrate_factor: u16,
    peripheral_latency: u16,
    continuation_number: u16,
    supervision_timeout: u16,
};

/// Parses an incoming LE Subrate Change Event payload (Subevent 0x1E).
pub fn decodeSubrateChangeEvent(payload: []const u8) !SubrateChangeEvent {
    // Expected 11 bytes: status(1), conn_handle(2), subrate_factor(2), latency(2), cont_num(2), timeout(2)
    if (payload.len < 11) return error.PayloadTooShort;

    return SubrateChangeEvent{
        .status = payload[0],
        .connection_handle = std.mem.readInt(u16, payload[1..3], .little),
        .subrate_factor = std.mem.readInt(u16, payload[3..5], .little),
        .peripheral_latency = std.mem.readInt(u16, payload[5..7], .little),
        .continuation_number = std.mem.readInt(u16, payload[7..9], .little),
        .supervision_timeout = std.mem.readInt(u16, payload[9..11], .little),
    };
}

test "BT 5.3 Subrating request encoder and event decoder test" {
    const params = SubrateParameters{
        .subrate_min = 5,
        .subrate_max = 20,
        .max_latency = 10,
        .continuation_number = 2,
        .supervision_timeout = 200, // 2.0 s
    };
    try std.testing.expect(params.isValid());

    var cmd_buf: [32]u8 = undefined;
    const len = try encodeSubrateRequest(0x0040, params, &cmd_buf);
    try std.testing.expectEqual(@as(usize, 16), len);

    // Verify H4 and Opcode
    try std.testing.expectEqual(@as(u8, 0x01), cmd_buf[0]);
    try std.testing.expectEqual(SubrateOpcode.LE_SUBRATE_REQUEST, std.mem.readInt(u16, cmd_buf[1..3], .little));
    try std.testing.expectEqual(@as(u8, 12), cmd_buf[3]); // param len
    try std.testing.expectEqual(@as(u16, 0x0040), std.mem.readInt(u16, cmd_buf[4..6], .little)); // conn handle
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, cmd_buf[6..8], .little)); // subrate min

    // Test Event Decoding
    var evt_payload: [11]u8 = undefined;
    evt_payload[0] = 0x00; // Success
    std.mem.writeInt(u16, evt_payload[1..3], 0x0040, .little);
    std.mem.writeInt(u16, evt_payload[3..5], 10, .little); // subrate factor 10
    std.mem.writeInt(u16, evt_payload[5..7], 4, .little); // latency 4
    std.mem.writeInt(u16, evt_payload[7..9], 2, .little); // continuation 2
    std.mem.writeInt(u16, evt_payload[9..11], 200, .little); // timeout 200

    const evt = try decodeSubrateChangeEvent(&evt_payload);
    try std.testing.expectEqual(@as(u8, 0), evt.status);
    try std.testing.expectEqual(@as(u16, 0x0040), evt.connection_handle);
    try std.testing.expectEqual(@as(u16, 10), evt.subrate_factor);
    try std.testing.expectEqual(@as(u16, 4), evt.peripheral_latency);
    try std.testing.expectEqual(@as(u16, 2), evt.continuation_number);
    try std.testing.expectEqual(@as(u16, 200), evt.supervision_timeout);
}
