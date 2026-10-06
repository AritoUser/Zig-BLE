//! # Real Hardware Windows Bluetooth Scanner
//!
//! Scans for real Bluetooth Low Energy and Classic devices using the
//! native pure-Zig WindowsBackend directly on your PC hardware.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

pub fn main() !void {
    std.debug.print("=================================================================\n", .{});
    std.debug.print("   Zig-BLE: Live Hardware Bluetooth Scanner (Windows Native)     \n", .{});
    std.debug.print("=================================================================\n\n", .{});

    var win_backend = Zig_BLE.WindowsBackend.init();
    defer win_backend.deinit();

    var adapter = Zig_BLE.UnifiedAdapter.init(win_backend.asBackend());
    try adapter.setPowered(true);

    if (win_backend.radio) |r| {
        if (r.getInfo()) |info| {
            const addr_str = info.address.toString();
            std.debug.print("[LOCAL CONTROLLER]\n", .{});
            std.debug.print("  * Hardware MAC:    {s}\n", .{&addr_str});
            std.debug.print("  * Friendly Name:   {s}\n", .{info.getName()});
            std.debug.print("  * Manufacturer ID: 0x{X:0>4}\n", .{info.manufacturer});
            std.debug.print("  * Powered:         {}\n\n", .{try adapter.isPowered()});
        }
    }

    std.debug.print("[LIVE INQUIRY DISCOVERY]\n", .{});
    std.debug.print("Scanning for active Bluetooth devices in range...\n\n", .{});

    const ScannerState = struct {
        count: usize = 0,

        fn onDiscovered(device: *const Zig_BLE.DiscoveredDevice, udata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(udata));
            self.count += 1;
            const addr_str = device.address.toString();

            std.debug.print("  [{d: >2}] MAC: {s} | Name: \"{s}\"\n", .{
                self.count,
                &addr_str,
                device.getName() orelse "(Unnamed Device)",
            });
        }
    };

    var state = ScannerState{};
    try adapter.startScan(.{}, ScannerState.onDiscovered, &state);

    std.debug.print("\n-----------------------------------------------------------------\n", .{});
    std.debug.print("Scan complete! Discovered {d} real device(s) on your hardware.\n", .{state.count});
    std.debug.print("=================================================================\n", .{});
}
