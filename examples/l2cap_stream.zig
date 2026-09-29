//! Zig-BLE Example: L2CAP Connection-Oriented Channels (CoC) Streamer
//! Demonstrates direct high-speed point-to-point binary transport over Linux AF_BLUETOOTH sockets.
//! Bypasses GATT and ATT MTU limits to achieve maximum over-the-air throughput.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");
const builtin = @import("builtin");

fn getMilliTimestamp() i64 {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    } else {
        return 0;
    }
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("     Zig-BLE L2CAP Connection-Oriented Channels (CoC) Streamer      \n", .{});
    std.debug.print("      Direct Kernel AF_BLUETOOTH Sockets with Credit-Based Flow     \n", .{});
    std.debug.print("====================================================================\n\n", .{});

    if (builtin.os.tag != .linux) {
        std.debug.print("L2CAP CoC sockets require Linux AF_BLUETOOTH kernel support.\n", .{});
        std.debug.print("On Windows/macOS, Zig-BLE provides cross-platform compilation mocks.\n", .{});
        std.debug.print("Verifying L2capSocket compilation and types:\n", .{});
        const mac = try Zig_BLE.Address.parse("00:11:22:33:44:55");
        std.debug.print("Parsed MAC: {s}\n", .{&mac.toString()});
        const res = Zig_BLE.L2capSocket.connectLe(mac, 0x1001, .public);
        std.debug.print("L2capSocket.connectLe() returned expected: {!}\n\n", .{res});
        return;
    }

    // Parse command line arguments: <peer_mac> [psm]
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // skip exe name

    const peer_str = args.next() orelse {
        std.debug.print("Usage: zig build run-l2cap -- <PEER_MAC_ADDRESS> [PSM_HEX]\n", .{});
        std.debug.print("Example: zig build run-l2cap -- AA:BB:CC:DD:EE:FF 1001\n\n", .{});
        std.debug.print("No target specified. Demonstrating mock socket connection:\n", .{});
        const mock_mac = try Zig_BLE.Address.parse("12:34:56:78:9A:BC");
        std.debug.print("Testing connection attempt to mock MAC: {s} (PSM: 0x1001)...\n", .{&mock_mac.toString()});
        const result = Zig_BLE.L2capSocket.connectLe(mock_mac, 0x1001, .public);
        std.debug.print("Kernel connection result: {!}\n", .{result});
        return;
    };

    const peer_mac = Zig_BLE.Address.parse(peer_str) catch |err| {
        std.debug.print("Invalid peer MAC address '{s}': {}\n", .{ peer_str, err });
        return;
    };

    const psm_str = args.next() orelse "1001";
    const psm = std.fmt.parseInt(u16, psm_str, 16) catch 0x1001;

    std.debug.print("Connecting L2CAP CoC channel to {s} (PSM: 0x{X:0>4})...\n", .{
        &peer_mac.toString(),
        psm,
    });

    var socket = Zig_BLE.L2capSocket.connectLe(peer_mac, psm, .public) catch |err| {
        std.debug.print("Failed to establish L2CAP channel: {}\n", .{err});
        return;
    };
    defer socket.close();

    std.debug.print("Channel established! Commencing streaming throughput test...\n\n", .{});

    var tx_buffer: [1024]u8 = undefined;
    @memset(&tx_buffer, 0xAA);

    var total_bytes: usize = 0;
    const start_time = getMilliTimestamp();

    for (0..100) |_| {
        const n = socket.write(&tx_buffer) catch |err| {
            std.debug.print("\nStream write error: {}\n", .{err});
            break;
        };
        total_bytes += n;
    }

    const elapsed_ms = getMilliTimestamp() - start_time;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const kb_sec = (@as(f64, @floatFromInt(total_bytes)) / 1024.0) / @max(elapsed_s, 0.001);

    std.debug.print("Transferred {d} bytes in {d} ms ({d:.2} KB/s)\n", .{
        total_bytes,
        elapsed_ms,
        kb_sec,
    });
}
