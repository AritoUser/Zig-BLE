# Zig-BLE

A high-performance, allocation-conscious, native Bluetooth Low Energy (BLE) library for **Zig 0.16.0+**, strictly adhering to the **Bluetooth Core Specification (v5.4 / v6.0)** and the Linux **BlueZ D-Bus APIs**.

Supports both **Central (Client)** and **Peripheral (Server & Broadcaster)** roles with a zero-allocation domain model, non-blocking event loops, and thread-safe background workers.

[![CI](https://github.com/AritoUser/Zig-BLE/actions/workflows/ci.yml/badge.svg)](https://github.com/AritoUser/Zig-BLE/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/AritoUser/Zig-BLE)](https://github.com/AritoUser/Zig-BLE/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![White Paper](https://img.shields.io/badge/White%20Paper-Architecture%20%26%20Design-orange.svg)](docs/WHITEPAPER.md)
[![Protocol Manual](https://img.shields.io/badge/Manual-Architecture%20%26%20Protocol-blueviolet.svg)](docs/ARCHITECTURE_AND_PROTOCOL_MANUAL.md)

> 📖 **Engineering Documentation:**
> * [**Technical White Paper**](docs/WHITEPAPER.md): Deep-dive into the zero-allocation D-Bus Wire Protocol engine, bi-endian decoding, SCM_RIGHTS pipe streaming, and microsecond benchmarks.
> * [**Architecture & Protocol Manual**](docs/ARCHITECTURE_AND_PROTOCOL_MANUAL.md): Systems reference covering memory layout, lock-free SPSC ring buffers, unaligned trap prevention, GATT finite state machines, and byte-level packet specifications.
> * **Interactive HTML API Reference**: Run `zig build docs` to generate searchable, type-safe API documentation in `zig-out/docs/`.

---

## Features

- **Zero-Allocation Critical Paths**: Bounded buffers, stack allocations, and fixed-capacity structures. No dynamic heap allocations during packet parsing, discovery streaming, or notification dispatching.
- **Pre-Built GATT Standard Profiles (`src/profiles/`)**:
  - **Heart Rate Service (HRP v1.0)**: Flags, 8-bit & 16-bit BPM, Sensor Contact status, Energy Expended, RR-intervals.
  - **Battery Service (BAS v1.0)**: Standard percentage (0–100%) encoder and decoder.
  - **Environmental Sensing (ESS v1.0)**: Temperature (0.01 °C fixed-point), Humidity (0.01 %), Pressure (0.1 Pa).
  - **Nordic UART Service (NUS)**: Standard 128-bit RX/TX UUIDs with zero-alloc `PacketChunker` for automatic payload slicing across BLE MTU bounds.
  - **Apple iBeacon & Google Eddystone**: Complete 23-byte Apple iBeacon builder (Proximity UUID, Major, Minor, Measured Power) and Eddystone frames (UID, URL with scheme compression, TLM telemetry).
- **Bluetooth 5.0+ Extended Advertising & LE Coded PHY (Long Range)**:
  - Secondary advertising channels (`.one_m`, `.two_m`, `.coded`), primary PHY (`.le_1m`, `.le_coded`), dynamic interval controls, and direct BlueZ `LEAdvertisingManager1` property exports.
- **L2CAP Connection-Oriented Channels (CoC) (`src/l2cap/`)**:
  - Direct Linux kernel streaming socket over `AF_BLUETOOTH` / `BTPROTO_L2CAP` (`L2capSocket`, `sockaddr_l2`) bypassing ATT/GATT protocol overhead for maximum point-to-point throughput.
- **Bluetooth Core Spec 5.4/6.0 Native Types**:
  - Full 16-bit, 32-bit, and 128-bit Little-Endian `UUID` support with canonical string formatting and parse verification.
  - Standard EUI-48 `Address` handling with automatic classification (Public, Random Static, Resolvable Private, Non-Resolvable Private).
  - Bluetooth SIG Assigned Numbers registry for Services (`heart_rate`, `battery_service`, `environmental_sensing`, `current_time`, `nordic_uart`), Characteristics, Descriptors, and Company Identifiers.
  - Zero-copy Advertising Packet Parser (`AdvertisingReport`, `AdIterator`) for AD types (`Flags`, `LocalName`, `Appearance`, `ManufacturerData`, `ServiceUUIDs`).
- **Complete Central (GATT Client) Role**:
  - Adapter enumeration, power management, and discovery filters.
  - Real-time active LE scanning with live RSSI streaming and Device Discovery events.
  - GATT Tree exploration (Primary Services, Characteristics, Descriptors).
  - Characteristic Read, Write, and CCCD-based Notification/Indication subscriptions with zero-allocation callback dispatchers.
- **Complete Peripheral (Server & Broadcaster) Role**:
  - BLE Advertising via BlueZ `LEAdvertisingManager1` (Local Name, Appearance, Service UUIDs, Manufacturer Data, TX Power).
  - Full GATT Server via BlueZ `GattManager1` (Services, Characteristics with Read/Write/Notify flags, `0x2901` Characteristic User Description Descriptors).
  - Built-in Pairing Agent (`Agent1`) with `"NoInputNoOutput"` auto-accept to handle secure connections effortlessly without permission errors.
  - Unified `Peripheral` engine with background event loop (`peripheral.startBackground()`) running in a dedicated `std.Thread`.
- **Cross-Platform Pure Core**: The `src/core/` domain model is 100% pure Zig with zero external dependencies and compiles for all platforms (Windows, macOS, Linux, bare metal / embedded).

---

## Installation

Add `zig_ble` to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/AritoUser/Zig-BLE.git
```

Or for local development:

```zig
// build.zig.zon
.{
    .name = .my_app,
    .version = "0.2.0",
    .dependencies = .{
        .zig_ble = .{
            .path = "path/to/Zig-BLE",
        },
    },
}
```

In your `build.zig`:

```zig
const zig_ble = b.dependency("zig_ble", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("Zig_BLE", zig_ble.module("Zig_BLE"));
```

> **Pure Zig Native Transport (0 C-Dependencies):**
> Zig-BLE communicates directly with `/var/run/dbus/system_bus_socket` via native Linux Unix Domain Sockets and its own built-in D-Bus Wire Protocol implementation.
> **No `libdbus-1-dev` and no `libc` required!** Seamless cross-compilation out of the box (e.g. `zig build -Dtarget=aarch64-linux` for Raspberry Pi).
>
> *(Optional fallback: pass `-Dlink-dbus=true` if you wish to link against the legacy C `libdbus-1` library).*

---

## Quickstart

### 1. Central: Scan for BLE Devices

Discover nearby Bluetooth Low Energy devices in real-time with 0% CPU kernel sleep:

```zig
const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

pub fn main() !void {
    var conn = try Zig_BLE.Connection.initSystem();
    defer conn.deinit();

    var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse return error.NoAdapter;
    try adapter.setPowered(true);

    try conn.addMatch("type='signal',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'");

    try adapter.startDiscovery();
    defer adapter.stopDiscovery() catch {};

    std.debug.print("Scanning for BLE devices...\n", .{});
    var count: usize = 0;
    while (count < 25) : (count += 1) {
        _ = conn.pollSocket(200); // 200ms kernel poll sleep (0% CPU)
        while (conn.popMessage()) |msg| {
            defer msg.deinit();
            if (msg.getMessageType() == 4) { // Signal
                var it = msg.iterator();
                if (it.getObjectPath()) |path| {
                    _ = it.next();
                    const Handler = struct {
                        pub fn onDevice(d: Zig_BLE.DeviceInfo) void {
                            const mac = d.address.toString();
                            std.debug.print("Found: {s} | {s} | RSSI: {?d} dBm\n", .{
                                &mac, d.getName() orelse d.getAlias(), d.rssi,
                            });
                        }
                    };
                    Zig_BLE.bluez.parseInterfacesAdded(path, &it, Handler, {});
                }
            }
        }
    }
}
```

---

### 2. High-Throughput ATT Streaming via Native Unix-FD (`GattStream`)

Bypass `dbus-daemon` and `PropertiesChanged` dictionary overhead entirely by streaming raw ATT packets over a direct kernel socket:

```zig
var char = Zig_BLE.GattCharacteristic.init(&conn, "/org/bluez/hci0/dev_XX/service0020/char0021");

// Acquire native Unix domain socket from BlueZ
var stream = try char.acquireNotify();
defer stream.deinit(); // Automatically stops notification and closes FD

std.debug.print("Direct ATT stream established (MTU: {d})\n", .{stream.mtu});

var buf: [512]u8 = undefined;
while (true) {
    const n = try stream.read(&buf);
    std.debug.print("Received ATT packet: {d} bytes (0 D-Bus overhead)\n", .{n});
}
```

---

### 3. Peripheral: Host a Heart Rate Sensor in 25 Lines

Broadcast advertisements and host standard GATT services in the background:

```zig
const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

pub fn main() !void {
    var conn = try Zig_BLE.Connection.initSystem();
    defer conn.deinit();

    var adapter = (try Zig_BLE.Adapter.findDefault(&conn)) orelse return error.NoAdapter;
    try adapter.setPowered(true);

    // Configure Peripheral (Advertisement + Pairing Agent)
    var peripheral = Zig_BLE.Peripheral.init(&conn, adapter.getObjectPath(), .{
        .local_name = "Zig-HRM-Sensor",
        .appearance = Zig_BLE.Appearance.generic_heart_rate_sensor,
        .service_uuids = &[_]Zig_BLE.UUID{ Zig_BLE.Services.heart_rate },
    }, .{
        .enable_agent = true,
        .agent_capability = .no_input_no_output,
    });

    // Add Heart Rate Service (0x180D) and Measurement Characteristic (0x2A37)
    const hr_service = try peripheral.addService(Zig_BLE.Services.heart_rate, true);
    const hr_char = try hr_service.addCharacteristic(Zig_BLE.Characteristics.heart_rate_measurement, .{
        .notify = true,
        .read = true,
    });
    hr_char.setValue(&[_]u8{ 0x00, 72 }); // Initial 72 BPM

    // Launch background event loop (non-blocking in std.Thread)
    try peripheral.startBackground();
    defer peripheral.stop();

    // Send notifications from main thread
    for (0..10) |_| {
        _ = conn.pollSocket(1000); // 1s wait
        try hr_char.notify(&conn, &[_]u8{ 0x00, 75 });
    }
}
```

---

### 4. Apple iBeacon & Google Eddystone Advertising

Broadcast proximity beacons or telemetry in a few lines of Zig:

```zig
const Zig_BLE = @import("Zig_BLE");

// 1. Build an Apple iBeacon payload (23 bytes manufacturer data)
const beacon_payload = try Zig_BLE.Beacon.AppleIBeacon.build(
    "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0", // Proximity UUID
    1001, // Major
    2002, // Minor
    -59,  // Measured RSSI at 1 meter
);

// 2. Build a Google Eddystone-URL payload (Compressed URL scheme)
const eddystone_url = try Zig_BLE.Beacon.EddystoneUrl.encode(
    "https://github.com/AritoUser/Zig-BLE",
    -20, // Calibrated TX Power at 0m
);
```

---

### 5. High-Throughput L2CAP Connection-Oriented Channels (CoC)

Establish direct point-to-point streaming over native Linux `AF_BLUETOOTH` sockets bypassing ATT/GATT MTU boundaries:

```zig
const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

pub fn main() !void {
    const peer_mac = try Zig_BLE.Address.parse("AA:BB:CC:DD:EE:FF");
    const psm: u16 = 0x1001; // Custom dynamic L2CAP PSM

    // Connect direct kernel L2CAP channel
    var sock = try Zig_BLE.L2capSocket.connect(peer_mac, psm);
    defer sock.close();

    // Stream high-throughput binary payload
    const data = "High-speed telemetry packet over L2CAP CoC";
    _ = try sock.write(data);

    var rx_buf: [1024]u8 = undefined;
    const n = try sock.read(&rx_buf);
    std.debug.print("Received {d} bytes via L2CAP\n", .{n});
}
```

---

### 6. Nordic UART Service (NUS) with MTU Chunking

Auto-slice large payloads across negotiated BLE MTUs without dynamic memory allocations:

```zig
const Zig_BLE = @import("Zig_BLE");

var chunker = Zig_BLE.NordicUart.PacketChunker.init("Command: AT+CONFIG=RESET; SENSOR=ON;\n", 20); // 20B MTU
while (chunker.next()) |chunk| {
    // Send each slice over NUS TX characteristic
    _ = chunk;
}
```

---

## Standalone Examples

The repository includes ready-to-run CLI examples:

### Terminal BLE Scanner
Scans the 2.4 GHz spectrum for BLE devices, decoding MAC addresses, RSSI signal levels, and device names.
```sh
zig build run-scanner
```

### Heart Rate Peripheral Simulator
Emits BLE beacons and hosts standard GATT Heart Rate Service `0x180D`. Open **nRF Connect** or any BLE scanner app on your smartphone to connect and stream live pulse measurements.
```sh
zig build run-heart-rate
```

### High-Performance Microbenchmark Suite
Measures raw packet parsing throughput, nanosecond latency, and proves zero dynamic allocations:
```sh
zig build bench
# or
zig build run-bench
```

---

## Architecture & Codebase Layout

```
Zig-BLE/
├── build.zig               # Package configuration & example build targets
├── build.zig.zon           # Package manifest (v0.2.0)
├── examples/
│   ├── scanner.zig         # Interactive terminal BLE scanner
│   ├── heart_rate_peripheral.zig # Standalone HRM GATT server
│   └── benchmark.zig       # Microbenchmark suite (zig build bench)
└── src/
    ├── root.zig            # Unified public API export
    ├── core/               # Pure Zig, zero external dependencies
    │   ├── types.zig       # UUID (16/32/128-bit LE), Address (EUI-48), AddressType
    │   ├── assigned_numbers.zig # Bluetooth SIG Services, Characteristics, Descriptors, Companies
    │   ├── gatt.zig        # CCCD bitmasks, GATT Permissions & Status Codes
    │   └── advertising.zig # Zero-copy AD packet parser (AdIterator, Extended Adv)
    ├── profiles/           # Pre-built GATT Standard Profiles
    │   ├── heart_rate.zig  # Heart Rate Service (HRP v1.0) encoder/decoder
    │   ├── battery.zig     # Battery Service (BAS v1.0) parser/encoder
    │   ├── environmental.zig # Environmental Sensing (ESS v1.0 fixed-point)
    │   ├── nordic_uart.zig # Nordic UART Service (NUS) & PacketChunker
    │   └── beacon.zig      # Apple iBeacon & Google Eddystone (UID/URL/TLM)
    ├── l2cap/              # L2CAP Connection-Oriented Channels (CoC)
    │   └── socket.zig      # AF_BLUETOOTH direct kernel socket stream
    ├── bluez/              # BlueZ D-Bus definitions & ObjectManager parser
    ├── dbus/               # Pure-Zig D-Bus Wire Protocol engine (zero C dependencies)
    │   └── wire/           # Socket, Auth, Header, Buffer, Reader, Writer, Message, Connection
    ├── adapter.zig         # Adapter discovery & power management
    ├── device.zig          # Remote BLE device representation
    ├── gatt_client.zig     # GATT service/characteristic exploration & notifications
    ├── advertising.zig     # LEAdvertisingManager1 D-Bus object export
    ├── gatt_server.zig     # GattManager1 GATT service, characteristic & descriptor tree
    ├── agent.zig           # BlueZ Agent1 pairing handler (Just Works auto-accept)
    ├── event_loop.zig      # Non-blocking D-Bus event loop
    └── peripheral.zig      # Unified background peripheral engine
```

---

## Performance & Microbenchmarks

Tested natively in Linux ReleaseFast mode (using single-pass 32-byte SIMD `@Vector`, `@shuffle`, `@select`, and zero heap allocations):

```
=========================================================================================
                       Zig-BLE High-Performance Microbenchmark Suite                    
                   Bluetooth Core Spec v5.4/v6.0 - Zero Dynamic Allocations             
=========================================================================================
Benchmark Target                           | Iterations | Total Time |    Latency |   Throughput
-------------------------------------------+------------+------------+------------+--------------
AdvertisingReport.parse (Full Packet)      |    2000000 |   17.08 ms |    8.54 ns |   117.08 Mop/s
AdIterator.next (TLV Element Walk)         |    5000000 |   29.54 ms |    5.91 ns |   169.25 Mop/s
UUID.parse (128-bit Canonical SIMD)        |    2000000 |   31.92 ms |   15.96 ns |    62.66 Mop/s
UUID.parse (128-bit Flat 32-char SIMD)     |    2000000 |   27.65 ms |   13.83 ns |    72.33 Mop/s
AdStructure.asServiceData16 (Zero-Copy)    |    5000000 |    7.52 ms |    1.50 ns |   665.23 Mop/s
UUID.toString (128-bit to Canonical)       |    2000000 |    3.46 ms |    1.73 ns |   577.56 Mop/s
Address.parse + classifyRandom             |    3000000 |    4.04 ms |    1.35 ns |   741.95 Mop/s
Cccd.encode + Cccd.decode                  |   10000000 |   13.57 ms |    1.36 ns |   736.74 Mop/s
AssignedNumbers (Service Registry)         |    5000000 |    4.03 ms |    0.81 ns |  1239.95 Mop/s
D-Bus Wire Message.finalize (Stack/Zero-Alloc)| 2000000 |  199.73 ms |   99.86 ns |    10.01 Mop/s
D-Bus Wire MessageIter (Zero-Copy)         |    3000000 |   11.00 ms |    3.67 ns |   272.81 Mop/s
=========================================================================================
Guarantees Verified:
  [x] Heap Allocations during packet parse / iteration: 0 Bytes
  [x] Memory Safety: Bounded stack arrays, zero pointer escapes
  [x] Wire Endianness: Strict Little-Endian for all over-the-air multi-byte types
  [x] Vector Acceleration: Branchless SIMD hex parsing via Zig @Vector intrinsics
  [x] BLE Throughput Headroom: Handles millions of packets/sec (BLE PHY is ~2k pkts/sec)
  [x] Native D-Bus Wire Engine: 100% Pure Zig, SCM_RIGHTS FD passing, sub-4ns zero-copy iteration
=========================================================================================
```

---

## Running the Unit Tests

All modules include comprehensive unit tests verifying Little-Endian bit-packing, zero-copy packet parsing, SIMD validation, D-Bus Wire protocol serialization/deserialization, 25,000-iteration continuous fuzzing, and type conversions:

```sh
zig build test --summary all
```

Output:
```
Build Summary: 5/5 steps succeeded; 54/54 tests passed
test success
+- run test 54 pass (54 total) 96ms MaxRSS:5M
+- run test success 5ms MaxRSS:4M
```

---

## Fuzz-Testing Suites

Zig-BLE includes two dedicated fuzz-testing engines for continuous memory safety and bounds validation:

### 1. BLE Advertising Parser Fuzzer
Targets `AdIterator.next()` and `AdvertisingReport.parse()` against corrupted length fields, truncated records, duplicate headers, invalid UTF-8 local names, and Extended Advertising PDUs up to 1650 octets:

```sh
# Run 500,000 iterations with PRNG mutation engine
zig build fuzz
```

### 2. Pure-Zig D-Bus Wire Protocol Fuzzer
Targets `FixedHeader.decode()`, `HeaderFields.parse()`, container recursion, and `MessageIter` zero-copy primitive decoding against arbitrarily mutated D-Bus frames:

```sh
# Run 200,000 iterations with PRNG mutation engine
zig build fuzz-dbus
```

Output:
```
=========================================================================================
Fuzzing Summary & Safety Guarantees:
  [x] Total Iterations:       200000 completed
  [x] Maximum Frame Size:     2048 bytes
  [x] Total Wall Time:        637.56 ms (Average rate: 0.31 Mop/s)
  [x] Memory Safety:          0 Panics, 0 Out-of-Bounds accesses, 0 Hangs
  [x] Heap Allocations:       0 Bytes (100% stack/zero-copy)
=========================================================================================
```

---

## Documentation (Autodoc)

Generate the interactive HTML API documentation using Zig's built-in doc generator:

```sh
zig build docs
```

The output will be placed in `zig-out/docs/index.html`.

---

## License

This project is licensed under the [MIT License](LICENSE).

