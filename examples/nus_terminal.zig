//! Zig-BLE Example: Nordic UART Service (NUS) Serial Terminal
//! Hosts a BLE Serial Console conforming to the Nordic UART Service specification (128-bit UUIDs).
//! Connect using 'Serial Bluetooth Terminal' or 'nRF Connect' to send and receive text with automatic MTU chunking.

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================\n", .{});
    std.debug.print("        Zig-BLE Nordic UART Service (NUS) Serial Terminal           \n", .{});
    std.debug.print("   Bidirectional BLE Serial Streaming with Zero-Allocation Chunking \n", .{});
    std.debug.print("====================================================================\n\n", .{});

    // Demonstrate PacketChunker on all platforms
    std.debug.print("1. PacketChunker Demonstration (Payload Slicing across 20-Byte BLE MTUs):\n", .{});
    const sample_message = "Zig-BLE v0.2.0: High-performance BLE stack with Nordic UART and L2CAP streaming!";
    var chunker = Zig_BLE.NordicUart.PacketChunker.init(sample_message, 20);
    var chunk_idx: usize = 1;
    while (chunker.next()) |chunk| {
        std.debug.print("   [Chunk {d} | {d} bytes] \"{s}\"\n", .{ chunk_idx, chunk.len, chunk });
        chunk_idx += 1;
    }
    std.debug.print("\n", .{});

    if (builtin.os.tag != .linux) {
        std.debug.print("Live NUS GATT peripheral hosting requires Linux BlueZ.\n", .{});
        std.debug.print("Compile and run on Linux to broadcast the live NUS terminal.\n", .{});
        return;
    }

    var conn = try Zig_BLE.Connection.initSystem();
    defer conn.deinit();

    var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse {
        std.debug.print("No Bluetooth adapter found on the system!\n", .{});
        return;
    };

    const adapter_info = adapter.getInfo() catch null;
    if (adapter_info) |info| {
        const mac = info.address.toString();
        std.debug.print("Active BLE Adapter: {s} ({s}) [Powered={}]\n\n", .{
            adapter.getObjectPath(),
            &mac,
            info.powered,
        });
        if (!info.powered) {
            try adapter.setPowered(true);
        }
    }

    // 2. Setup Peripheral hosting the Nordic UART Service
    var peripheral = Zig_BLE.Peripheral.init(&conn, adapter.getObjectPath(), .{
        .local_name = "Zig-NUS-Console",
        .service_uuids = &[_]Zig_BLE.UUID{Zig_BLE.NordicUart.service_uuid},
        .discoverable = true,
    }, .{
        .enable_agent = true,
        .agent_capability = .no_input_no_output,
    });

    const nus_service = try peripheral.addService(Zig_BLE.NordicUart.service_uuid, true);

    // TX Characteristic (Notify): Sends data from Peripheral to Central
    const tx_char = try nus_service.addCharacteristic(Zig_BLE.NordicUart.tx_uuid, .{
        .notify = true,
    });
    _ = try tx_char.setUserDescription("NUS TX (Notifications to Client)");

    // RX Characteristic (Write): Receives data from Central to Peripheral
    const rx_char = try nus_service.addCharacteristic(Zig_BLE.NordicUart.rx_uuid, .{
        .write = true,
        .write_without_response = true,
    });
    _ = try rx_char.setUserDescription("NUS RX (Write from Client)");

    // Define RX callback
    const RxHandler = struct {
        tx: *Zig_BLE.ServerCharacteristic,
        c: *Zig_BLE.Connection,

        pub fn onWrite(self: *@This(), data: []const u8) void {
            std.debug.print("[NUS RX Received {d} bytes]: \"{s}\"\n", .{ data.len, data });

            // Echo response back over TX with chunking
            const reply = "ECHO: ";
            self.tx.notify(self.c, reply) catch {};
            var reply_chunker = Zig_BLE.NordicUart.PacketChunker.init(data, 20);
            while (reply_chunker.next()) |slice| {
                self.tx.notify(self.c, slice) catch {};
            }
        }
    };

    var rx_handler = RxHandler{
        .tx = tx_char,
        .c = &conn,
    };

    rx_char.user_data = &rx_handler;
    rx_char.write_handler = struct {
        fn handle(ch: *Zig_BLE.ServerCharacteristic, data: []const u8, user_data: ?*anyopaque) void {
            _ = ch;
            if (user_data) |ud| {
                const h: *RxHandler = @ptrCast(@alignCast(ud));
                h.onWrite(data);
            }
        }
    }.handle;

    // Start background event loop
    try peripheral.startBackground();
    defer peripheral.stop();

    const s_uuid = Zig_BLE.NordicUart.service_uuid.toString();
    std.debug.print(">>> Nordic UART Console is ONLINE and Advertising! <<<\n", .{});
    std.debug.print("Connect from your phone (e.g. 'Serial Bluetooth Terminal' app):\n", .{});
    std.debug.print("  * Service UUID: {s}\n", .{&s_uuid});
    std.debug.print("  * Any text sent to RX will be echoed back on TX.\n", .{});
    std.debug.print("Press Ctrl+C to terminate.\n\n", .{});

    var count: usize = 0;
    while (count < 60) : (count += 1) {
        _ = conn.pollSocket(1000);
    }
}
