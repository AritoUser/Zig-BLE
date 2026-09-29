//! Zig-BLE Example: Zero-Daemon Raw HCI Scanner
//! Communicates directly with the Bluetooth Controller via Linux AF_BLUETOOTH and BTPROTO_HCI.
//! Operates completely independent of BlueZ bluetoothd, D-Bus, and systemd.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("               Zig-BLE Zero-Daemon Raw HCI Scanner                  \n", .{});
    std.debug.print("       Direct AF_BLUETOOTH HCI Sockets (No D-Bus, No bluetoothd)    \n", .{});
    std.debug.print("====================================================================\n\n", .{});

    if (builtin.os.tag != .linux) {
        std.debug.print("Direct Raw HCI sockets require Linux AF_BLUETOOTH kernel support.\n", .{});
        std.debug.print("On Windows/macOS, Zig-BLE provides cross-platform compilation mocks.\n", .{});
        std.debug.print("Verifying HciController compilation and types:\n", .{});
        const rst = Zig_BLE.hci.Commands.reset();
        std.debug.print("HCI_Reset command frame: {X:0>2} {X:0>2} {X:0>2} {X:0>2}\n", .{
            rst[0], rst[1], rst[2], rst[3],
        });
        const scan_cmd = Zig_BLE.hci.Commands.leSetScanEnable(true, true);
        std.debug.print("HCI_LE_Set_Scan_Enable:  {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}\n\n", .{
            scan_cmd[0], scan_cmd[1], scan_cmd[2], scan_cmd[3], scan_cmd[4], scan_cmd[5],
        });
        return;
    }

    // 1. Open HCI Controller (hci0 -> device 0)
    std.debug.print("[+] Opening raw HCI socket to hci0 (AF_BLUETOOTH, BTPROTO_HCI)...\n", .{});
    var controller = Zig_BLE.hci.HciController.open(0) catch |err| {
        std.debug.print("Failed to open hci0: {}\n", .{err});
        std.debug.print("Note: Raw HCI access requires root privileges (CAP_NET_RAW / CAP_NET_ADMIN).\n", .{});
        return;
    };
    defer controller.close();

    // 2. Read local controller MAC address
    if (controller.readBdAddr()) |mac| {
        std.debug.print("   -> Controller BD_ADDR: {s}\n", .{&mac.toString()});
    } else |_| {
        std.debug.print("   -> Controller online.\n", .{});
    }

    // 3. Start Active LE Scan
    std.debug.print("[+] Enabling Active LE Scanning with duplicate filtering...\n\n", .{});
    try controller.startScan(.{
        .scan_type = .active,
        .interval = 0x0010, // 10 ms
        .window = 0x0010, // 10 ms
        .filter_duplicates = true,
    });
    defer controller.stopScan() catch {};

    std.debug.print("  {s:<19} | {s:<12} | {s:<10} | {s}\n", .{ "MAC ADDRESS", "RSSI", "TYPE", "PAYLOAD / NAME" });
    std.debug.print("  {s:-<19}-+-{s:-<12}-+-{s:-<10}-+-{s:-<30}\n", .{ "", "", "", "" });

    var packet_buf: [1024]u8 = undefined;
    var seen_devices: [64][17]u8 = undefined;
    var seen_count: usize = 0;

    var tick: usize = 0;
    while (tick < 100) : (tick += 1) {
        if (try controller.readReport(&packet_buf, 100)) |report| {
            const mac_str = report.address.toString();

            // Check if seen before
            var already_seen = false;
            for (seen_devices[0..seen_count]) |seen| {
                if (std.mem.eql(u8, &seen, &mac_str)) {
                    already_seen = true;
                    break;
                }
            }

            if (!already_seen and seen_count < seen_devices.len) {
                seen_devices[seen_count] = mac_str;
                seen_count += 1;

                // Zero-allocation parse of advertising structures using core.AdIterator
                var dev_name: ?[]const u8 = null;
                var it = Zig_BLE.core.AdIterator.init(report.data);
                while (it.next()) |structure| {
                    if (structure.ad_type == .complete_local_name or structure.ad_type == .shortened_local_name) {
                        dev_name = structure.data;
                    }
                }

                const type_str = if (report.isScanResponse()) "SCAN_RSP" else if (report.isConnectable()) "ADV_IND" else "NON_CONN";

                if (dev_name) |name| {
                    std.debug.print("  {s} | {d:>4} dBm    | {s:<10} | {s}\n", .{
                        &mac_str,
                        report.rssi,
                        type_str,
                        name,
                    });
                } else {
                    std.debug.print("  {s} | {d:>4} dBm    | {s:<10} | <{d} bytes data>\n", .{
                        &mac_str,
                        report.rssi,
                        type_str,
                        report.data.len,
                    });
                }
            }
        }
    }

    std.debug.print("\n[*] Scan finished. Total unique devices discovered: {d}\n\n", .{seen_count});
}
