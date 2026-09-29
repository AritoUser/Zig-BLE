//! HCI Socket Filter configuration (struct hci_filter in Linux Bluetooth subsystem).
//! Controls kernel-level packet demultiplexing to minimize context switches.

const std = @import("std");
const constants = @import("constants.zig");

/// Linux kernel struct hci_filter representation
pub const HciFilter = extern struct {
    type_mask: u32 = 0,
    event_mask: [2]u32 = [_]u32{ 0, 0 },
    opcode: u16 = 0,

    /// Creates an empty filter rejecting all packets.
    pub fn initEmpty() HciFilter {
        return .{
            .type_mask = 0,
            .event_mask = [_]u32{ 0, 0 },
            .opcode = 0,
        };
    }

    /// Sets the filter to accept all packet types and all standard events.
    pub fn initAll() HciFilter {
        return .{
            .type_mask = 0xFFFFFFFF,
            .event_mask = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF },
            .opcode = 0,
        };
    }

    /// Creates a filter tailored for Bluetooth Low Energy scanning.
    /// Only allows HCI_EVENT_PKT with EVT_LE_META_EVENT and EVT_CMD_COMPLETE.
    pub fn initLeScan() HciFilter {
        var f = initEmpty();
        f.setPacketType(.event);
        f.setEvent(constants.EventCode.command_complete);
        f.setEvent(constants.EventCode.command_status);
        f.setEvent(constants.EventCode.le_meta_event);
        return f;
    }

    /// Enables filtering for a specific HCI packet type (Command, ACL, Event, etc.)
    pub fn setPacketType(self: *HciFilter, ptype: constants.PacketType) void {
        const bit: u5 = @truncate(@intFromEnum(ptype));
        self.type_mask |= @as(u32, 1) << bit;
    }

    /// Clears filtering for a specific HCI packet type.
    pub fn clearPacketType(self: *HciFilter, ptype: constants.PacketType) void {
        const bit: u5 = @truncate(@intFromEnum(ptype));
        self.type_mask &= ~(@as(u32, 1) << bit);
    }

    /// Enables filtering for an HCI event code (0x01 .. 0x3F).
    pub fn setEvent(self: *HciFilter, evt: u8) void {
        if (evt == 0 or evt > 63) return;
        const idx: usize = if (evt >= 32) 1 else 0;
        const bit: u5 = @truncate(evt % 32);
        self.event_mask[idx] |= @as(u32, 1) << bit;
    }

    /// Clears filtering for an HCI event code.
    pub fn clearEvent(self: *HciFilter, evt: u8) void {
        if (evt == 0 or evt > 63) return;
        const idx: usize = if (evt >= 32) 1 else 0;
        const bit: u5 = @truncate(evt % 32);
        self.event_mask[idx] &= ~(@as(u32, 1) << bit);
    }
};

test "HciFilter bit manipulation" {
    var f = HciFilter.initEmpty();
    f.setPacketType(.event);
    try std.testing.expect((f.type_mask & (@as(u32, 1) << 4)) != 0);

    f.setEvent(constants.EventCode.le_meta_event); // 0x3E = 62
    // 62 >= 32 -> idx 1, bit 30
    try std.testing.expect((f.event_mask[1] & (@as(u32, 1) << 30)) != 0);

    f.clearEvent(constants.EventCode.le_meta_event);
    try std.testing.expectEqual(@as(u32, 0), f.event_mask[1]);
}
