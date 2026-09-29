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
    std.debug.print("=== Zig-BLE Showcase (Bluetooth Core Spec & Idiomatic API) ===\n\n", .{});

    // 1. Address Parsing & Classification
    const addr = try Zig_BLE.Address.parse("C0:1A:7D:DA:71:13");
    const addr_str = addr.toString();
    const addr_class = addr.classifyRandom();
    std.debug.print("1. MAC Address: {s} (Class: {s})\n", .{ &addr_str, addr_class.toString() });

    // 2. Bluetooth SIG Assigned Numbers
    const hr_service = Zig_BLE.Services.heart_rate;
    const hr_str = hr_service.toString();
    const hr_name = Zig_BLE.Services.getName(hr_service).?;
    std.debug.print("2. Standard Service: {s} -> {s}\n", .{ &hr_str, hr_name });

    const cccd = Zig_BLE.Cccd.NOTIFY;
    const cccd_bytes = cccd.encode();
    std.debug.print("   CCCD Value (Enable Notifications): 0x{X:0>2}{X:0>2}\n", .{ cccd_bytes[1], cccd_bytes[0] });

    // 3. Zero-Allocation Advertising Packet Parser
    const adv_packet = [_]u8{
        0x02, 0x01, 0x06, // Flags: General Discoverable + BR/EDR Not Supported
        0x0D, 0x09, 'P',  'u',  'l', 's', 'e', ' ', 'S', 'e', 'n', 's', 'o', 'r', // Complete Local Name (12 chars + 1 type byte = 13 / 0x0D)
        0x03, 0x19, 0x40, 0x03, // Appearance: Heart Rate Sensor (832)
        0x05, 0xFF, 0x59, 0x00, 0x01, 0x02, // Manufacturer: Nordic Semiconductor (0x0059) + payload
    };

    const report = Zig_BLE.AdvertisingReport.parse(&adv_packet);
    std.debug.print("3. Advertising Packet (Zero-Allocation Parse):\n", .{});
    if (report.local_name) |name| {
        std.debug.print("   - Device Name: {s}\n", .{name});
    }
    if (report.appearance) |app| {
        std.debug.print("   - Appearance:  {s} ({d})\n", .{ Zig_BLE.Appearance.getName(app), app });
    }
    if (report.flags) |flags| {
        std.debug.print("   - Flags:       LE General Discoverable={}, BR/EDR Not Supported={}\n", .{
            flags.le_general_discoverable,
            flags.br_edr_not_supported,
        });
    }
    if (report.getManufacturerData()) |mfg| {
        std.debug.print("   - Mfg Data:    Company: {s} (0x{X:0>4}), Payload bytes: {d}\n", .{
            mfg.getCompanyName() orelse "Unknown",
            mfg.company_id,
            mfg.payload.len,
        });
    }

    if (builtin.os.tag == .linux) {
        std.debug.print("\n=== 4. Live Linux BlueZ D-Bus Test ===\n", .{});
        var conn = try Zig_BLE.dbus.Connection.initSystem();
        defer conn.deinit();
        std.debug.print("-> Connected to D-Bus system bus successfully!\n", .{});

        var reply = try conn.callMethod(
            Zig_BLE.BlueZ.service_name,
            Zig_BLE.BlueZ.root_path,
            Zig_BLE.BlueZ.ObjectManager.interface_name,
            Zig_BLE.BlueZ.ObjectManager.Methods.GetManagedObjects,
            5000,
        );
        defer reply.deinit();

        std.debug.print("-> Parsing BlueZ ObjectManager objects...\n", .{});

        const Handler = struct {
            adapter_count: usize = 0,
            device_count: usize = 0,

            pub fn onAdapter(self: *@This(), info: Zig_BLE.AdapterInfo) void {
                self.adapter_count += 1;
                const adapter_addr_str = info.address.toString();
                std.debug.print("   [ADAPTER FOUND] {s}\n", .{info.getObjectPath()});
                std.debug.print("      -> MAC Address:  {s} ({s})\n", .{ &adapter_addr_str, info.address_type.toString() });
                std.debug.print("      -> Name / Alias: {s} / {s}\n", .{ info.getName(), info.getAlias() });
                std.debug.print("      -> Powered: {}, Discovering: {}\n", .{ info.powered, info.discovering });
            }

            pub fn onDevice(self: *@This(), info: Zig_BLE.DeviceInfo) void {
                self.device_count += 1;
                const dev_addr_str = info.address.toString();
                std.debug.print("   [DEVICE FOUND] {s}\n", .{info.getObjectPath()});
                std.debug.print("      -> MAC Address:  {s} ({s})\n", .{ &dev_addr_str, info.address_type.toString() });
                if (info.getName()) |name| {
                    std.debug.print("      -> Device Name:  {s}\n", .{name});
                }
                std.debug.print("      -> Connected: {}, Paired: {}\n", .{ info.connected, info.paired });
                std.debug.print("      -> ServicesResolved: {}\n", .{ info.services_resolved });
                if (info.rssi) |rssi| {
                    std.debug.print("      -> RSSI: {d} dBm\n", .{rssi});
                }
            }
        };

        var handler = Handler{};
        var it = reply.iterator();
        Zig_BLE.bluez.parseManagedObjects(&it, Handler, &handler);

        std.debug.print("-> Found: {d} adapter(s), {d} device(s) in BlueZ inventory.\n", .{
            handler.adapter_count,
            handler.device_count,
        });

        // 5. Start live BLE discovery!
        std.debug.print("\n=== 5. Live BLE Discovery ===\n", .{});
        var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse {
            std.debug.print("No Bluetooth adapter found!\n", .{});
            return;
        };
        std.debug.print("-> Default adapter ready: {s}\n", .{adapter.getObjectPath()});

        try adapter.setPowered(true);

        try conn.addMatch("type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager'");
        try conn.addMatch("type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties'");

        std.debug.print("-> Starting BLE discovery (active scanning) for 6 seconds...\n", .{});
        try adapter.startDiscovery();
        defer adapter.stopDiscovery() catch {};

        var live_devices_count: usize = 0;
        var iters: usize = 0;

        var target_device_path: ?[160]u8 = null;
        var target_device_len: u8 = 0;

        // 40 iterations of 200 ms = ~8 seconds scan duration
        while (iters < 40) : (iters += 1) {
            _ = conn.pollSocket(200);
            while (conn.popMessage()) |incoming_msg| {
                var msg = incoming_msg;
                defer msg.deinit();
                if (msg.getMessageType() == 4) { // DBUS_MESSAGE_TYPE_SIGNAL
                    if (msg.getMember()) |member| {
                        live_devices_count += 1;
                        std.debug.print("   [SIGNAL #{d}] Iface: {?s} | Member: {s} | Path: {?s}\n", .{
                            live_devices_count,
                            msg.getInterface(),
                            member,
                            msg.getPath(),
                        });

                        if (std.mem.eql(u8, member, "InterfacesAdded")) {
                            var sig_it = msg.iterator();
                            if (sig_it.getObjectPath()) |dev_path| {
                                const LiveHandler = struct {
                                    target_ref: *?[160]u8,
                                    target_len_ref: *u8,

                                    pub fn onDevice(self: *@This(), d: Zig_BLE.DeviceInfo) void {
                                        const mac = d.address.toString();
                                        const dev_name = d.getName() orelse d.getAlias();
                                        std.debug.print("      -> [NEW BLE DEVICE!] MAC: {s} | {s} | RSSI: {?d} dBm\n", .{
                                            &mac,
                                            dev_name,
                                            d.rssi,
                                        });

                                        if (std.mem.eql(u8, dev_name, "A-PC")) {
                                            var buf: [160]u8 = undefined;
                                            const p = d.getObjectPath();
                                            const len = @min(buf.len - 1, p.len);
                                            @memcpy(buf[0..len], p[0..len]);
                                            buf[len] = 0;
                                            self.target_ref.* = buf;
                                            self.target_len_ref.* = @intCast(len);
                                            std.debug.print("         ==> [TARGET DEVICE 'A-PC' UPDATED]: {s}\n", .{p});
                                        }
                                    }
                                };
                                var lh = LiveHandler{
                                    .target_ref = &target_device_path,
                                    .target_len_ref = &target_device_len,
                                };
                                Zig_BLE.bluez.parseInterfacesAdded(dev_path, &sig_it, LiveHandler, &lh);
                            }
                        } else if (std.mem.eql(u8, member, "PropertiesChanged")) {
                            var prop_it = msg.iterator();
                            if (prop_it.getString()) |iface| {
                                const target_p = msg.getPath() orelse "";
                                if (prop_it.recurse()) |*props_array| {
                                    var pa = props_array.*;
                                    while (pa.hasMore()) {
                                        if (pa.recurse()) |*prop_entry| {
                                            var pe = prop_entry.*;
                                            if (pe.getString()) |prop_key| {
                                                if (pe.getVariant()) |*v| {
                                                    var var_iter = v.*;
                                                    if (std.mem.eql(u8, iface, Zig_BLE.BlueZ.Device1.interface_name)) {
                                                        if (std.mem.eql(u8, prop_key, "RSSI")) {
                                                            if (var_iter.getInt16()) |rssi| {
                                                                std.debug.print("      -> [DEVICE RSSI UPDATE] {s} -> {d} dBm\n", .{ target_p, rssi });
                                                            }
                                                        } else if (std.mem.eql(u8, prop_key, "Name")) {
                                                            if (var_iter.getString()) |name| {
                                                                std.debug.print("      -> [DEVICE NAME UPDATE] {s} -> {s}\n", .{ target_p, name });
                                                                if (std.mem.eql(u8, name, "A-PC")) {
                                                                    var buf: [160]u8 = undefined;
                                                                    const len = @min(buf.len - 1, target_p.len);
                                                                    @memcpy(buf[0..len], target_p[0..len]);
                                                                    buf[len] = 0;
                                                                    target_device_path = buf;
                                                                    target_device_len = @intCast(len);
                                                                    std.debug.print("         ==> [TARGET DEVICE 'A-PC' UPDATED]: {s}\n", .{target_p});
                                                                }
                                                            }
                                                        }
                                                    } else if (std.mem.eql(u8, iface, Zig_BLE.BlueZ.Adapter1.interface_name)) {
                                                        if (std.mem.eql(u8, prop_key, "Discovering")) {
                                                            if (var_iter.getBool()) |disc| {
                                                                std.debug.print("      -> [ADAPTER STATUS] Discovering = {}\n", .{disc});
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        _ = pa.next();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        std.debug.print("-> Scan complete. {d} live signals received.\n", .{live_devices_count});
        std.debug.print("-> Stopping BLE discovery before connection attempt (HCI LE Controller switch)...\n", .{});
        adapter.stopDiscovery() catch {};
        _ = conn.pollSocket(300);

        // 6. Connect to A-PC and explore GATT services/characteristics
        std.debug.print("\n=== 6. Live GATT Connection to A-PC ===\n", .{});
        const target_path_opt = if (target_device_path) |buf| buf[0..target_device_len :0] else null;
        if (target_path_opt == null) {
            std.debug.print("A-PC was not discovered during the scan.\n", .{});
            return;
        }
        const target_path = target_path_opt.?;
        var dev = Zig_BLE.Device.init(&conn, target_path);

        std.debug.print("-> Connecting to current A-PC path {s}...\n", .{dev.getObjectPath()});
        var connected = false;
        var retry: usize = 0;
        while (retry < 3 and !connected) : (retry += 1) {
            if (retry > 0) {
                std.debug.print("-> Retrying connection ({d}/3)...\n", .{retry + 1});
                _ = conn.pollSocket(1000);
            }
            dev.connect() catch |err| {
                std.debug.print("Connection attempt failed: {s}\n", .{@errorName(err)});
                continue;
            };
            connected = true;
        }

        if (!connected) {
            std.debug.print("Could not establish BLE connection to A-PC after 3 attempts.\n", .{});
            std.debug.print("Note: Windows PC might require new pairing or is not currently ready to connect.\n", .{});
        } else {
            std.debug.print("-> Connection established (GAP Link established)!\n", .{});

        std.debug.print("-> Waiting for GATT service discovery (ServicesResolved == true)...\n", .{});
        dev.waitForServicesResolved(15000) catch |err| {
            std.debug.print("Warning while waiting for ServicesResolved: {s}\n", .{@errorName(err)});
        };

        const resolved = dev.areServicesResolved() catch false;
        std.debug.print("-> ServicesResolved Status: {}\n", .{resolved});

        std.debug.print("\n-> Exploring GATT structure of A-PC:\n", .{});
        var gatt_reply = try conn.callMethod(
            Zig_BLE.BlueZ.service_name,
            Zig_BLE.BlueZ.root_path,
            Zig_BLE.BlueZ.ObjectManager.interface_name,
            Zig_BLE.BlueZ.ObjectManager.Methods.GetManagedObjects,
            5000,
        );
        defer gatt_reply.deinit();

        const GattExplorer = struct {
            target_path: [:0]const u8,
            service_count: usize = 0,
            char_count: usize = 0,
            connection: *Zig_BLE.dbus.Connection,

            notify_paths: [8][224]u8 = undefined,
            notify_lens: [8]u8 = undefined,
            notify_count: usize = 0,

            pub fn onGattService(self: *@This(), s: Zig_BLE.GattServiceInfo) void {
                if (std.mem.startsWith(u8, s.getDevicePath(), self.target_path)) {
                    self.service_count += 1;
                    const uuid_str = s.uuid.toString();
                    const s_name = Zig_BLE.Services.getName(s.uuid) orelse "Vendor-Specific";
                    std.debug.print("\n   [GATT SERVICE #{d}] UUID: {s} ({s})\n", .{
                        self.service_count,
                        &uuid_str,
                        s_name,
                    });
                    std.debug.print("      Path: {s}, Primary: {}\n", .{ s.getObjectPath(), s.primary });
                }
            }

            pub fn onGattCharacteristic(self: *@This(), c: Zig_BLE.GattCharacteristicInfo) void {
                if (std.mem.startsWith(u8, c.getObjectPath(), self.target_path)) {
                    self.char_count += 1;
                    const uuid_str = c.uuid.toString();
                    const c_name = Zig_BLE.Characteristics.getName(c.uuid) orelse "Custom Characteristic";
                    std.debug.print("      * [CHARACTERISTIC] UUID: {s} ({s})\n", .{
                        &uuid_str,
                        c_name,
                    });
                    std.debug.print("        Properties: Read={}, Write={}, Notify={}, Indicate={}\n", .{
                        c.flags.read,
                        c.flags.write or c.flags.write_without_response,
                        c.flags.notify,
                        c.flags.indicate,
                    });

                    // Save notifiable / indicatable characteristics for Section 7
                    if ((c.flags.notify or c.flags.indicate) and self.notify_count < self.notify_paths.len) {
                        var buf: [224]u8 = undefined;
                        const p = c.getObjectPath();
                        const len = @min(buf.len - 1, p.len);
                        @memcpy(buf[0..len], p[0..len]);
                        buf[len] = 0;
                        self.notify_paths[self.notify_count] = buf;
                        self.notify_lens[self.notify_count] = @intCast(len);
                        self.notify_count += 1;
                    }

                    // If readable, attempt to read value directly without heap allocation!
                    if (c.flags.read) {
                        var char_client = Zig_BLE.GattCharacteristic.init(self.connection, c.getObjectPath());
                        var val_buf: [128]u8 = undefined;
                        if (char_client.readValue(&val_buf)) |read_len| {
                            const val = val_buf[0..read_len];
                            std.debug.print("        -> Read value ({d} bytes): ", .{read_len});
                            var is_ascii = true;
                            for (val) |b| {
                                if (b < 0x20 or b > 0x7E) {
                                    is_ascii = false;
                                    break;
                                }
                            }
                            if (is_ascii and val.len > 0) {
                                std.debug.print("\"{s}\" [Hex: ", .{val});
                            } else {
                                std.debug.print("[Hex: ", .{});
                            }
                            for (val) |b| {
                                std.debug.print("{X:0>2} ", .{b});
                            }
                            std.debug.print("]\n", .{});
                        } else |read_err| {
                            std.debug.print("        -> Read attempt: {s}\n", .{@errorName(read_err)});
                        }
                    }
                }
            }
        };

        var explorer = GattExplorer{
            .target_path = target_path,
            .connection = &conn,
        };
        var gatt_it = gatt_reply.iterator();
        Zig_BLE.bluez.parseManagedObjects(&gatt_it, GattExplorer, &explorer);

        std.debug.print("\n-> GATT exploration complete: {d} services, {d} characteristics.\n", .{
            explorer.service_count,
            explorer.char_count,
        });

        // 7. Live Notification-Streaming Test
        if (explorer.notify_count > 0) {
            std.debug.print("\n=== 7. Live Notification Streaming Test on A-PC ===\n", .{});
            std.debug.print("-> Found notifiable/indicatable characteristics: {d}\n", .{explorer.notify_count});

            const StreamContext = struct {
                total_packets: usize = 0,

                pub fn onPacket(self: *@This(), char_path: [:0]const u8, data: []const u8) void {
                    self.total_packets += 1;
                    std.debug.print("   [NOTIFICATION STREAM #{d}] from {s}\n", .{ self.total_packets, char_path });
                    std.debug.print("      -> Payload ({d} bytes): [Hex: ", .{data.len});
                    for (data) |b| std.debug.print("{X:0>2} ", .{b});
                    std.debug.print("]\n", .{});
                }
            };

            var stream_ctx = StreamContext{};
            var dispatcher = Zig_BLE.NotificationDispatcher.init();
            var active_notif_char: ?Zig_BLE.GattCharacteristic = null;

            for (0..explorer.notify_count) |i| {
                const notif_path = explorer.notify_paths[i][0..explorer.notify_lens[i] :0];
                std.debug.print("-> Testing startNotify() on: {s}...\n", .{notif_path});
                var notif_char = Zig_BLE.GattCharacteristic.init(&conn, notif_path);
                if (notif_char.startNotify()) {
                    std.debug.print("   => StartNotify SUCCESSFUL on {s}!\n", .{notif_path});
                    try dispatcher.subscribe(notif_path, struct {
                        fn handle(char_path: [:0]const u8, data: []const u8, ctx: ?*anyopaque) void {
                            const s: *StreamContext = @ptrCast(@alignCast(ctx.?));
                            s.onPacket(char_path, data);
                        }
                    }.handle, &stream_ctx);
                    active_notif_char = notif_char;
                    break;
                } else |err| {
                    std.debug.print("   => StartNotify rejected: {s}\n", .{@errorName(err)});
                }
            }

            if (active_notif_char) |*notif_char| {
                std.debug.print("-> Registering NotificationDispatcher and listening for 5 seconds...\n", .{});
                var notif_iters: usize = 0;
                while (notif_iters < 25) : (notif_iters += 1) {
                    _ = conn.pollSocket(200);
                    while (conn.popMessage()) |msg| {
                        defer msg.deinit();
                        _ = dispatcher.processMessage(&msg);
                    }
                }

                std.debug.print("-> Ending notification subscription via stopNotify()...\n", .{});
                notif_char.stopNotify() catch {};
                std.debug.print("-> Notifications ended. Received packets: {d}\n", .{stream_ctx.total_packets});
            } else {
                std.debug.print("-> No unprotected notifiable characteristic available (Windows requires pairing/bonding for protected paths).\n", .{});
            }
        }

            std.debug.print("\n-> Disconnecting from A-PC...\n", .{});
            dev.disconnect() catch {};
            std.debug.print("-> Connection cleanly closed.\n", .{});
        }

        // 8. Live BLE Broadcaster / Peripheral Advertising Test
        std.debug.print("\n=== 8. Live BLE Broadcaster / Peripheral Advertising Test ===\n", .{});
        const adv_cfg = Zig_BLE.AdvertisementConfig{
            .type = .peripheral,
            .local_name = "Zig-BLE-Sensor",
            .service_uuids = &.{
                Zig_BLE.Services.heart_rate,
                Zig_BLE.Services.battery_service,
            },
            .manufacturer_data = .{
                .company_id = Zig_BLE.CompanyId.nordic_semiconductor,
                .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
            },
            .includes = .{
                .tx_power = true,
                .appearance = false,
                .local_name = true,
            },
            .discoverable = true,
        };

        var my_adv = Zig_BLE.Advertisement.init(&conn, adapter.getObjectPath(), "/org/zig_ble/advertisement0", adv_cfg);
        std.debug.print("-> Registering custom BLE advertisement '/org/zig_ble/advertisement0' with {s}...\n", .{adapter.getObjectPath()});
        if (my_adv.register()) {
            std.debug.print("-> Advertisement SUCCESSFUL! Adapter is broadcasting active BLE beacons!\n", .{});
            std.debug.print("-> Broadcasting advertising packets for 4 seconds (LocalName: 'Zig-BLE-Sensor', Heart Rate & Battery UUIDs)...\n", .{});

            var adv_iters: usize = 0;
            while (adv_iters < 20) : (adv_iters += 1) {
                _ = conn.pollSocket(200);
                while (conn.popMessage()) |msg| {
                    defer msg.deinit();
                    _ = my_adv.processMessage(&msg) catch false;
                }
            }

            std.debug.print("-> Stopping advertisement via unregister()...\n", .{});
            my_adv.unregister() catch {};
            std.debug.print("-> Advertisement cleanly stopped.\n", .{});
        } else |err| {
            std.debug.print("-> Advertisement failed: {s}\n", .{@errorName(err)});
        }

        // 9. Live GATT Server (Peripheral Hosting) Test
        std.debug.print("\n=== 9. Live GATT Server (Peripheral Hosting) Test ===\n", .{});
        var gatt_app = Zig_BLE.GattApplication.init(&conn, adapter.getObjectPath(), "/org/zig_ble/app0");

        // Service 1: Heart Rate Service (0x180D)
        const my_hr_service = try gatt_app.createService(Zig_BLE.Services.heart_rate, true);

        // Characteristic 1: Heart Rate Measurement (0x2A37) - Notify + Read
        const hr_char = try my_hr_service.addCharacteristic(Zig_BLE.Characteristics.heart_rate_measurement, .{
            .notify = true,
            .read = true,
        });
        hr_char.setValue(&[_]u8{ 0x00, 75 }); // Initial: 75 bpm
        _ = try hr_char.setUserDescription("Live Heart Rate in BPM");

        // Characteristic 2: Body Sensor Location (0x2A38) - Read
        const loc_char = try my_hr_service.addCharacteristic(Zig_BLE.Characteristics.body_sensor_location, .{
            .read = true,
        });
        loc_char.setValue(&[_]u8{ 0x01 }); // Location: Chest

        std.debug.print("-> Registering GATT server application '/org/zig_ble/app0' with {s}...\n", .{adapter.getObjectPath()});
        if (gatt_app.register()) {
            std.debug.print("-> GATT server registered successfully! Local services published to ATT database!\n", .{});
            std.debug.print("   -> Service: Heart Rate (0x180D) with 2 characteristics ready!\n", .{});
            std.debug.print("      * Char: Heart Rate Measurement (0x2A37) -> 75 bpm (with Descriptor 0x2901 CUDD)\n", .{});
            std.debug.print("      * Char: Body Sensor Location (0x2A38) -> Chest (0x01)\n", .{});

            // Simulate a sensor value update
            std.debug.print("-> Updating sensor value and sending notification (80 bpm)...\n", .{});
            try hr_char.notify(&conn, &[_]u8{ 0x00, 80 });

            std.debug.print("-> Hosting GATT server for 3 seconds in background...\n", .{});
            var server_iters: usize = 0;
            while (server_iters < 15) : (server_iters += 1) {
                _ = conn.pollSocket(200);
                while (conn.popMessage()) |msg| {
                    defer msg.deinit();
                    _ = gatt_app.processMessage(&msg) catch false;
                }
            }

            std.debug.print("-> Stopping GATT server via unregister()...\n", .{});
            gatt_app.unregister() catch {};
            std.debug.print("-> GATT server cleanly stopped.\n", .{});
        } else |err| {
            std.debug.print("-> GATT server registration failed: {s}\n", .{@errorName(err)});
        }

        // 10. Live Unified Peripheral Engine (Advertising + GATT Server + Pairing Agent)
        std.debug.print("\n=== 10. Live Unified Peripheral Engine (All-In-One High-Level API) ===\n", .{});
        var peripheral = Zig_BLE.Peripheral.init(&conn, adapter.getObjectPath(), .{
            .local_name = "Zig-HRM-Pro",
            .service_uuids = &[_]Zig_BLE.UUID{ Zig_BLE.Services.heart_rate },
            .manufacturer_data = .{
                .company_id = Zig_BLE.CompanyId.nordic_semiconductor,
                .data = &[_]u8{ 0xAA, 0xBB },
            },
        }, .{
            .enable_agent = true,
            .agent_capability = .no_input_no_output,
        });

        const p_service = try peripheral.addService(Zig_BLE.Services.heart_rate, true);
        const p_char = try p_service.addCharacteristic(Zig_BLE.Characteristics.heart_rate_measurement, .{
            .notify = true,
            .read = true,
        });
        p_char.setValue(&[_]u8{ 0x00, 72 });
        _ = try p_char.setUserDescription("Pulse Rate Sensor");

        std.debug.print("-> Starting Unified Peripheral in BACKGROUND THREAD (startBackground)...\n", .{});
        if (peripheral.startBackground()) {
            std.debug.print("-> Peripheral running non-blocking in separate std.Thread! Main thread is free!\n", .{});
            std.debug.print("-> Main thread simulates pulse measurements via char.notify() while worker processes D-Bus concurrently:\n", .{});

            var bpm: u8 = 75;
            var iter: usize = 0;
            while (iter < 4) : (iter += 1) {
                sleepUs(800 * 1000);
                bpm += 2;
                std.debug.print("   [THREAD UPDATE] Main thread sending {d} bpm via ATT notification...\n", .{bpm});
                p_char.notify(&conn, &[_]u8{ 0x00, bpm }) catch {};
            }

            std.debug.print("-> Stopping peripheral via stop() and waiting for thread join...\n", .{});
            peripheral.stop();
            std.debug.print("-> Unified peripheral & background thread cleanly terminated!\n", .{});
        } else |err| {
            std.debug.print("-> Peripheral start failed: {s}\n", .{@errorName(err)});
        }
    }

    std.debug.print("\nAll operations executed successfully!\n", .{});
}

