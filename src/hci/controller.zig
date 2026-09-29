//! High-level Zero-Daemon BLE Controller based on Raw HCI Sockets.
//! Provides turnkey scanning and advertising directly over Linux AF_BLUETOOTH.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const filter_mod = @import("filter.zig");
const HciFilter = filter_mod.HciFilter;
const socket_mod = @import("socket.zig");
const HciSocket = socket_mod.HciSocket;
const HciError = socket_mod.HciError;
const commands_mod = @import("commands.zig");
const Commands = commands_mod.Commands;
const events_mod = @import("events.zig");
const HciEvent = events_mod.HciEvent;
const HciAdvertisingReport = events_mod.HciAdvertisingReport;
const types = @import("../core/types.zig");
const Address = types.Address;

pub const HciScanConfig = struct {
    scan_type: commands_mod.ScanType = .active,
    /// Interval in units of 0.625 ms (default 0x0010 = 10 ms)
    interval: u16 = 0x0010,
    /// Window in units of 0.625 ms (default 0x0010 = 10 ms)
    window: u16 = 0x0010,
    own_addr_type: commands_mod.AddressType = .public,
    filter_duplicates: bool = true,
};

pub const HciController = struct {
    sock: HciSocket,
    is_scanning: bool = false,

    /// Opens the specified HCI device (e.g. hci0 -> 0) and initializes the controller.
    pub fn open(device_index: u16) HciError!HciController {
        var sock = try HciSocket.open(device_index, constants.HCI_CHANNEL_RAW);
        errdefer sock.close();

        return HciController{
            .sock = sock,
            .is_scanning = false,
        };
    }

    /// Releases the HCI socket.
    pub fn close(self: *HciController) void {
        if (self.is_scanning) {
            _ = self.stopScan() catch {};
        }
        self.sock.close();
    }

    /// Reads the hardware Bluetooth MAC address (BD_ADDR) of this controller.
    pub fn readBdAddr(self: *HciController) !Address {
        if (builtin.os.tag != .linux) return Address{ .bytes = [_]u8{0} ** 6 };

        const cmd = Commands.readBdAddr();
        try self.sock.send(&cmd);

        var buf: [256]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            if (self.sock.poll(100) == 0) continue;
            const n = try self.sock.readPacket(&buf);
            if (n == 0) continue;

            const evt = HciEvent.parse(buf[0..n]) catch continue;
            switch (evt) {
                .command_complete => |cc| {
                    if (cc.opcode == constants.Opcode.read_bd_addr and cc.return_params.len >= 6) {
                        const p = cc.return_params;
                        // Return parameters: [status: 1B] [BD_ADDR: 6B LE]
                        // Note: If status byte is present at index 0:
                        const offset: usize = if (cc.return_params.len >= 7) 1 else 0;
                        return Address{
                            .bytes = [6]u8{
                                p[offset + 5],
                                p[offset + 4],
                                p[offset + 3],
                                p[offset + 2],
                                p[offset + 1],
                                p[offset + 0],
                            },
                        };
                    }
                },
                else => {},
            }
        }
        return HciError.Timeout;
    }

    /// Configures socket filtering and begins Bluetooth Low Energy scanning.
    pub fn startScan(self: *HciController, config: HciScanConfig) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        // 1. Install kernel-level packet filter for LE Meta events and Command Complete
        const filter = HciFilter.initLeScan();
        try self.sock.setFilter(filter);

        // 2. Set LE Event Mask (all LE events enabled)
        const mask_cmd = Commands.leSetEventMask(0x000000000000001F);
        try self.sock.send(&mask_cmd);

        // 3. Set Scan Parameters
        const param_cmd = Commands.leSetScanParameters(
            config.scan_type,
            config.interval,
            config.window,
            config.own_addr_type,
            .accept_all,
        );
        try self.sock.send(&param_cmd);

        // 4. Enable Scanning
        const enable_cmd = Commands.leSetScanEnable(true, config.filter_duplicates);
        try self.sock.send(&enable_cmd);

        self.is_scanning = true;
    }

    /// Stops BLE scanning.
    pub fn stopScan(self: *HciController) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;
        if (!self.is_scanning) return;

        const disable_cmd = Commands.leSetScanEnable(false, false);
        try self.sock.send(&disable_cmd);
        self.is_scanning = false;
    }

    /// Reads and parses the next advertising report.
    /// Returns null if no packet arrived within `timeout_ms`.
    pub fn readReport(self: *HciController, buf: []u8, timeout_ms: c_int) !?HciAdvertisingReport {
        if (builtin.os.tag != .linux) return null;

        if (self.sock.poll(timeout_ms) == 0) return null;
        const n = try self.sock.readPacket(buf);
        if (n == 0) return null;

        const evt = HciEvent.parse(buf[0..n]) catch return null;
        switch (evt) {
            .le_advertising_report => |mut_it| {
                var it = mut_it;
                return it.next();
            },
            else => return null,
        }
    }
};

test "HciController: non-linux mock check" {
    if (builtin.os.tag != .linux) {
        try std.testing.expectError(HciError.NotSupported, HciController.open(0));
    }
}
