# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.1] - 2026-10-07

### Patch Milestone: Cross-Platform CI Stabilization & Roadmap Expansion
This maintenance and patch release resolves cross-compilation errors across multi-platform CI matrix runners (Linux Native, macOS ARM64, and Windows 11), fixes POSIX timestamping and BlueZ property handling, and introduces the comprehensive technical master blueprint for Zig-BLE v1.1.0 through v2.0.0.

---

### Fixed

* **macOS ARM64 Cross-Compilation ABI (`src/backend/windows/bindings.zig`)**:
  * Resolved LLVM backend rejection of the `.winapi` calling convention (`aarch64_aapcs_win`) when compiling Windows backend declarations on Darwin / aarch64 runners.
  * Replaced unconditional `callconv(.winapi)` with OS-conditional `callconv(winapi_cc)` (`if (builtin.os.tag == .windows) .winapi else .c`).
* **Cross-Platform PCAP Timestamping (`src/tooling/pcap.zig`)**:
  * Unified high-resolution packet capture timestamp retrieval across operating systems.
  * Replaced direct Windows WinAPI calls under non-Windows targets with cross-platform branches (`std.posix.clock_gettime` / Linux syscalls vs. `QueryPerformanceCounter` on Windows).
* **BlueZ Wire Backend Property Method Call (`src/backend/bluez/mod.zig`)**:
  * Corrected invalid method helper invocation by leveraging `Connection.createMethodCall(BlueZ.Properties.Methods.Set)` with standardized signature `ssv`.
  * Utilized null-terminated formatting (`bufPrintZ`) for D-Bus object device paths.
* **Backend Test Isolation (`src/backend/mod.zig`)**:
  * Enclosed platform-specific backend test references under conditional compile-time guards (`if (builtin.os.tag == .linux)` and `if (builtin.os.tag == .windows)`), preventing compilation failures on unsupported target OS runners.
* **Documentation Formatting (`README.md`)**:
  * Corrected GAP Device Name formatting in quickstart examples.

---

### Added

* **Technical Master Roadmap & Architectural Blueprint (`docs/BLE_ROADMAP_AND_EXTENSIONS.md`)**:
  * Expanded 630+ line deep-dive technical blueprint with memory layouts, packet formats, and state machines covering:
    * **v1.1.0**: Dynamic MTU & PHY Auto-Tuner, Enhanced ATT (EATT / L2CAP CoC multiplexing), Connection Subrating (BT 5.3).
    * **v1.2.0**: Standardized Fitness & Medical GATT Profiles (FTMS Fitness Machine, CPP Cycling Power, Pulse Oximeter SpO2).
    * **v1.3.0 & v1.4.0**: Native macOS CoreBluetooth backend, Android NDK backend, and Direction Finding (AoA / AoD BT 5.1).
    * **v2.0.0**: LE Audio Host Stack (ISO Channels, LC3 codec interface, BAP, CAP, Auracast Broadcast Audio), Periodic Advertising with Responses (PAwR BT 5.4), and Bluetooth 6.0 Channel Sounding (PBR / RTT cm-accurate distance measurement).

---

### Verified

* **100% Green CI Matrix**: Verified all GitHub Actions matrix jobs passing across:
  * Ubuntu latest (Linux Native tests & compilation)
  * macOS latest (Darwin ARM64 cross-platform checks)
  * Windows latest (Windows 11 native WinRT/Win32 tests)
* **Unit & E2E Test Suite**: All 145/145 tests pass with 0 errors, 0 memory leaks, and 0 warnings.

---

## [1.0.0] - 2026-10-06

### Major Milestone: Production Release
This release marks the official production stabilization of **Zig-BLE**, transforming the library from an embedded Linux D-Bus client into a comprehensive, multi-platform, zero-allocation Bluetooth Low Energy protocol engine and systems library for Zig 0.16.0+.

The release has been physically verified over the 2.4 GHz air interface against an active smartphone (Samsung Galaxy S25 Ultra) across 8 GATT services and 38 characteristics with 96.8% read success rate and 57.1 ms average air interface latency.

---

### Added

#### Architectural Pillar 1: Pluggable Backend HAL (`src/backend/vtable.zig`, `src/backend/adapter.zig`)
* **`BackendVTable`**: Abstract interface decoupling application logic from OS-specific Bluetooth implementations:
  * Adapter management (`openAdapter`, `closeAdapter`, `setPowered`, `startScan`, `stopScan`).
  * GAP Link lifecycle (`connectDevice`, `disconnectDevice`).
  * GATT Client operations (`discoverServices`, `readCharacteristic`, `writeCharacteristic`, `subscribeNotifications`, `unsubscribeNotifications`).
* **`UnifiedAdapter`**: Polymorphic adapter wrapper exposing idiomatic Zig ergonomics over any HAL implementation.
* **`DiscoveredDevice`**: Unified representation of scanned BLE peripherals across Windows, Linux, and Bare-Metal.

#### Architectural Pillar 2: Tier-1 Native OS Support (Windows 11 & Linux)
* **Windows 11 Native Backend (`src/backend/windows/`)**:
  * Direct WinRT COM ABI bindings (`Windows.Devices.Bluetooth`, `IBluetoothLEDevice`, `IGattCharacteristic`) without external C/C++ runtimes.
  * Native Win32 Bluetooth API bindings (`bthprops.cpl`, `BluetoothApis.dll`).
  * Solved Windows 11 legacy `bthledevice` symlink inactivity (`ERROR_FILE_NOT_FOUND` / code 2) via modern WinRT activation.
* **Linux Pure-Zig D-Bus Wire Backend (`src/dbus/wire/`)**:
  * Communicates directly over `/var/run/dbus/system_bus_socket` using native POSIX system calls (`std.posix`).
  * Eliminates `libdbus-1`, `glib`, `GDBus`, and C runtime dependencies entirely (0 byte `libc`).
  * Support for `SCM_RIGHTS` ancillary file descriptor handover for high-bandwidth pipe streaming.

#### Architectural Pillar 3: Pure-Zig Bare-Metal Host-Stack (`src/hci/h4.zig`, `src/l2cap/acl_reassembler.zig`)
* **H4 Framing Engine (`H4StreamParser`, `H4Serializer`)**:
  * Streaming state machine parser for serial UART byte streams (Command `0x01`, ACL `0x02`, SCO `0x03`, Event `0x04`, ISO `0x05`).
  * Zero-allocation slice ingestion with sliding buffer windows.
* **Zero-Allocation ACL Reassembler (`AclReassembler`)**:
  * Fixed-capacity multi-fragment L2CAP reassembly engine handling `PB_FIRST_FLUSH` (`0b10`) and `PB_CONTINUING` (`0b01`) boundary flags.
  * Rejects oversized frames (`error.L2capFrameTooLarge`) and handles connection drops deterministically.

#### Architectural Pillar 4: Complete GATT Engine & Long Transfers (`src/core/transfers.zig`)
* **GATT Long Writes**:
  * `LongWriteIterator`: Automatically slices oversized payloads into negotiated ATT MTU chunks via `PrepareWriteRequest` PDUs.
* **Server-Side Prepare Queue**:
  * `ServerPrepareWriteQueue`: Fixed-capacity buffer tracking queued attribute writes with handle isolation and atomic `ExecuteWriteRequest` (commit `0x01` / discard `0x00`).
* **GATT Long Reads**:
  * `LongReadReassembler`: Sequentially issues `ReadBlobRequest` PDUs with progressive byte offsets until the target attribute is fully retrieved.

#### Architectural Pillar 5: Security Manager & Persistent KeyStore (`src/storage/bond_store.zig`)
* **`MemoryBondStore(N)`**:
  * Storage for Long Term Keys (LTK AES-128), Identity Resolving Keys (IRK), EDIV, Rand, and pairing flags.
  * CCCD state persistence across link disconnections and reboot cycles.
* **Binary NVS Storage (`NvsStorage`)**:
  * Portable binary format with magic header `ZBGR` (`0x5247425A`), format versioning, and full CRC32 data integrity validation.

#### Architectural Pillar 6: Virtual Mock Controller & E2E CI Harness (`src/backend/mock/adapter.zig`)
* **Deterministic Headless CI Mock**:
  * Emulates Bluetooth Controller and Link Layer behavior in RAM with zero OS dependencies.
  * 146 unit, E2E, and edge-case tests validating boundary conditions, stream interruptions, and packet malformations without physical radio hardware.

#### Architectural Pillar 7: Developer Tooling & Wireshark PCAP Exporter (`src/tooling/pcap.zig`)
* **`PcapWriter`**:
  * Generates standard Libpcap captures with link-layer type `DLT_BLUETOOTH_HCI_H4` (`187`).
  * Enables zero-overhead protocol inspection of HCI, L2CAP, and ATT packets directly in Wireshark.

---

### Optimized

* **D-Bus Wire Protocol Header Serialization (`Message.finalize`)**:
  * Replaced repeated heap reallocations with an inline, zero-allocation L1 stack formatting cursor (`appendFieldRaw`, `appendFieldUint32Raw`, `appendFieldSignatureRaw`).
  * Pre-sized output buffer capacity in a single pass.
  * **Latency**: Reduced from **61.65 ns** to **2.82 ns** (**21.8x faster**).
  * **Throughput**: Increased from **16.22 Mop/s** to **354.63 Mop/s**.
  * **Hot-path heap allocations**: **0 Bytes**.

---

### Changed

* **`build.zig.zon`**: Bumped version from `0.3.1` to `1.0.0`.
* **Root Namespace Exports (`src/root.zig`)**: Consolidated unified access to `backend`, `storage`, `tooling`, `core`, `crypto`, `hci`, `l2cap`, and `profiles`.
* **Benchmark Suite (`examples/benchmark.zig`)**: Expanded to 15 comprehensive protocol targets covering all Bluetooth Core Spec v5.4/v6.0 hot-paths.
* **Code Formatting**: Fully standardized the entire repository with `zig fmt`.

---

### Verified

* **Unit & Edge-Case Tests**: 146 / 146 passing (`zig build test`).
* **Live Hardware Verification**: Intel Bluetooth Adapter $\to$ Samsung Galaxy S25 Ultra over-the-air (`zig build run-v1-live`).
* **Cross-Compilation**: Native AMD64 Windows and cross-compilation to `x86_64-linux` with zero C compiler required.
* **HTML Documentation**: Fully builds via `zig build docs` with searchable type declarations.
