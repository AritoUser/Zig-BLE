//! Zig-BLE Example: Standalone Heart Rate Peripheral Simulator
//! Emits Bluetooth LE Advertising packets and hosts standard GATT Heart Rate Service (0x180D).
//! Can be discovered and connected to by smartphones (e.g., nRF Connect) or other BLE Centrals.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

const builtin = @import("builtin");

fn sleepUs(usec: u64) void {
    if (builtin.os.tag == .linux) {
        const ts: std.os.linux.timespec = .{
            .sec = @intCast(usec / 1_000_000),
            .nsec = @intCast((usec % 1_000_000) * 1000),
        };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("           Zig-BLE Heart Rate Peripheral Simulator (0x180D)         \n", .{});
    std.debug.print("   Connectable with Smartphones (nRF Connect, BLE Scanner, etc.)   \n", .{});
    std.debug.print("====================================================================\n\n", .{});

    var conn = try Zig_BLE.Connection.initSystem();
    defer conn.deinit();

    // 1. Discover adapter
    var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse {
        std.debug.print("No Bluetooth adapter found!\n", .{});
        return;
    };

    const adapter_info = adapter.getInfo() catch null;
    if (adapter_info) |info| {
        const mac_str = info.address.toString();
        std.debug.print("Broadcasting adapter: {s} ({s})\n\n", .{ adapter.getObjectPath(), &mac_str });
        if (!info.powered) {
            try adapter.setPowered(true);
        }
    } else {
        std.debug.print("Broadcasting adapter: {s}\n\n", .{adapter.getObjectPath()});
    }

    // 2. Configure peripheral
    var peripheral = Zig_BLE.Peripheral.init(&conn, adapter.getObjectPath(), .{
        .local_name = "Zig-HRM-Sensor",
        .appearance = Zig_BLE.Appearance.generic_heart_rate_sensor,
        .service_uuids = &[_]Zig_BLE.UUID{Zig_BLE.Services.heart_rate},
        .manufacturer_data = .{
            .company_id = Zig_BLE.CompanyId.nordic_semiconductor,
            .data = &[_]u8{ 0xBE, 0xEF },
        },
    }, .{
        .enable_agent = true,
        .agent_capability = .no_input_no_output,
    });

    // 3. Configure Heart Rate Service (0x180D)
    const hr_service = try peripheral.addService(Zig_BLE.Services.heart_rate, true);

    // Characteristic: Heart Rate Measurement (0x2A37)
    const hr_char = try hr_service.addCharacteristic(Zig_BLE.Characteristics.heart_rate_measurement, .{
        .notify = true,
        .read = true,
    });
    hr_char.setValue(&[_]u8{ 0x00, 72 }); // Initial: 72 bpm
    _ = try hr_char.setUserDescription("Heart Rate in BPM");

    // Characteristic: Body Sensor Location (0x2A38)
    const loc_char = try hr_service.addCharacteristic(Zig_BLE.Characteristics.body_sensor_location, .{
        .read = true,
    });
    loc_char.setValue(&[_]u8{0x01}); // Location: Chest

    // 4. Start in background
    std.debug.print("[+] Starting BLE advertising & GATT server in background...\n", .{});
    try peripheral.startBackground();
    std.debug.print("   -> Device discoverable as 'Zig-HRM-Sensor'!\n", .{});
    std.debug.print("   -> Open the 'nRF Connect' app on your smartphone to connect!\n\n", .{});

    // 5. Heart rate simulation in main thread (12 seconds)
    const pulse_values = [_]u8{ 72, 73, 75, 78, 80, 82, 81, 79, 76, 74, 73, 72 };
    for (pulse_values, 0..) |bpm, i| {
        sleepUs(1000 * 1000); // 1 second delay
        std.debug.print("   [{d:>2}/12] Heart rate: {d} bpm -> Sending ATT Handle Value Notification...\n", .{ i + 1, bpm });
        hr_char.notify(&conn, &[_]u8{ 0x00, bpm }) catch {};
    }

    std.debug.print("\n[*] Simulation ended. Stopping peripheral...\n", .{});
    peripheral.stop();
    std.debug.print("Cleanly shut down and all resources released.\n\n", .{});
}
