//! Zig-BLE Example: BLE Terminal Scanner
//! Scans for nearby Bluetooth Low Energy devices with zero heap allocations.
//! Shows MAC addresses, RSSI signal indicators, device names, and advertised services.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("                 Zig-BLE Active Terminal Scanner                    \n", .{});
    std.debug.print("     Native, Zero-Allocation Bluetooth Low Energy Discovery        \n", .{});
    std.debug.print("====================================================================\n\n", .{});

    var conn = try Zig_BLE.Connection.initSystem();
    defer conn.deinit();

    // 1. Discover adapter
    var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse {
        std.debug.print("No Bluetooth adapter found on the system!\n", .{});
        return;
    };

    const adapter_info = adapter.getInfo() catch null;
    if (adapter_info) |info| {
        const mac_str = info.address.toString();
        std.debug.print("Active BLE adapter: {s} ({s}) [Powered={}]\n", .{
            adapter.getObjectPath(),
            &mac_str,
            info.powered,
        });
        if (!info.powered) {
            try adapter.setPowered(true);
            std.debug.print("   -> Adapter powered on.\n", .{});
        }
    } else {
        std.debug.print("Active BLE adapter: {s}\n", .{adapter.getObjectPath()});
    }

    // 2. Set discovery filter to BLE (Low Energy)
    std.debug.print("Setting discovery filter to 'le' (Active Scanning)...\n", .{});
    try adapter.setDiscoveryFilter(.{
        .transport = "le",
        .duplicate_data = false,
    });

    // Register signal matches for InterfacesAdded and PropertiesChanged
    try conn.addMatch("type='signal',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'");
    try conn.addMatch("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'");

    std.debug.print("Starting BLE scan (10 seconds)... Nearby devices will be detected:\n\n", .{});
    std.debug.print("  {s:<19} | {s:<18} | {s:<20} | {s}\n", .{ "MAC ADDRESS", "SIGNAL (RSSI)", "DEVICE NAME", "TYPE" });
    std.debug.print("  {s:-<19}-+-{s:-<18}-+-{s:-<20}-+-{s:-<15}\n", .{ "", "", "", "" });

    try adapter.startDiscovery();
    defer adapter.stopDiscovery() catch {};

    const ScanHandler = struct {
        seen_devices: *[64][17]u8,
        seen_count: *usize,

        pub fn onDevice(self: *@This(), dev_info: Zig_BLE.DeviceInfo) void {
            const dev_mac_str = dev_info.address.toString();

            var is_seen = false;
            for (self.seen_devices[0..self.seen_count.*]) |seen| {
                if (std.mem.eql(u8, &seen, &dev_mac_str)) {
                    is_seen = true;
                    break;
                }
            }

            if (!is_seen and self.seen_count.* < self.seen_devices.len) {
                @memcpy(self.seen_devices[self.seen_count.*][0..17], &dev_mac_str);
                self.seen_count.* += 1;

                const rssi_val = dev_info.rssi orelse -99;
                const bar = getRssiBar(rssi_val);
                const name = dev_info.getName() orelse dev_info.getAlias();
                const addr_type_str = dev_info.address_type.toString();

                std.debug.print("  {s:<19} | {s:<18} | {s:<20} | {s}\n", .{
                    &dev_mac_str,
                    bar,
                    name,
                    addr_type_str,
                });
            }
        }
    };

    var seen_devices: [64][17]u8 = undefined;
    var seen_count: usize = 0;

    var loop_iters: usize = 0;
    while (loop_iters < 50) : (loop_iters += 1) { // 50 * 200ms = 10 seconds
        _ = conn.pollSocket(200);
        while (conn.popMessage()) |msg| {
            defer msg.deinit();

            if (msg.getMessageType() != 4) continue; // DBUS_MESSAGE_TYPE_SIGNAL
            const member = msg.getMember() orelse continue;

            if (std.mem.eql(u8, member, "InterfacesAdded")) {
                var it = msg.iterator();
                if (it.getObjectPath()) |dev_path| {
                    _ = it.next();
                    var sh = ScanHandler{
                        .seen_devices = &seen_devices,
                        .seen_count = &seen_count,
                    };
                    Zig_BLE.bluez.parseInterfacesAdded(dev_path, &it, ScanHandler, &sh);
                }
            }
        }
    }

    std.debug.print("\nScan complete. {d} unique BLE devices discovered in range.\n\n", .{seen_count});
}

fn getRssiBar(rssi: i16) []const u8 {
    if (rssi >= -55) return "[====] -55dBm (Strong)";
    if (rssi >= -70) return "[===.] -70dBm (Good)  ";
    if (rssi >= -85) return "[==..] -85dBm (Fair)  ";
    return "[=...] Weak        ";
}
