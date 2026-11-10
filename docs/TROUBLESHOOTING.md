# Troubleshooting & Platform Notes

Platform behavior that is not obvious from the API, and what to do about it. Sorted by
backend. Error names refer to `BleError`.

## All platforms

**Callbacks and threads**
- **BlueZ:** scan results, notifications and connection events are delivered only from
  `UnifiedAdapter.processEvents(timeout_ms)`, on the thread that calls it. Call it
  regularly, e.g. `while (running) try adapter.processEvents(100);`.
- **Windows:** callbacks run on WinRT thread-pool threads, possibly while your main thread
  is inside a backend call. `processEvents` only waits there, so the same loop works on
  both platforms.
- Callbacks may call back into the backend, but should return quickly. For a single-threaded
  design, use `EventQueue`: it copies every event into a queue that you drain with `next()` /
  `wait()`.

**Several characteristics with the same UUID**
- HID devices expose one Report characteristic (0x2A4D) per report, and some devices have
  two Battery services. A plain UUID selects the first match.
- Use `getCharacteristics()` to list all characteristics, and a `CharacteristicSelector`
  (`.{ .uuid = ..., .service = ..., .instance = n }`) to address the others.

**Disconnect reason**
- `ConnectionEvent.disconnected.reason_code` is the HCI reason (0x08 timeout, 0x13 remote,
  0x16 local, 0x05 authentication).
- It is `null` when the platform does not report it: always on Windows, and on BlueZ before
  5.71 or when BlueZ sends `Connected = false` before its `Disconnected` signal.

## Linux (BlueZ)

**`DeviceNotFound` on connect**
- BlueZ only connects to devices it has seen. Scan first (until the device shows up in the
  scan callback), then connect.
- A device seen in an earlier session may still be known to BlueZ, but random addresses
  change.

**Connect takes long or returns `ConnectionTimeout`**
- `connect` returns only after BlueZ reports `ServicesResolved`, i.e. after GATT discovery.
  Both steps share the timeout (`TimeoutConfig.connect_ms` or the `timeout_ms` argument).
- Devices with large GATT databases need more than the default 10 s on the first connection;
  later connections use BlueZ's cache.

**Permission errors (`PermissionDenied`, `IoError` on D-Bus calls)**
- The user must be allowed to talk to `org.bluez` on the system bus. On most distributions
  that means being in the `bluetooth` group or running inside an active local session
  (polkit).
- Services under systemd need the `bluetooth` group in `SupplementaryGroups=`.

**No scan results**
- Check that `processEvents` is called.
- Check that the adapter is powered (`bluetoothctl power on`) and not blocked
  (`rfkill list`).
- `ScanFilter.min_rssi` and `service_uuids` are applied to the merged advertisement data.
  A device that puts its service UUID only in the scan response is reported once the scan
  response has arrived.

**A read or write takes long, returns `Timeout`, and the device disconnects**
- BlueZ answers "insufficient authentication" or "insufficient encryption" from the device by
  pairing on its own, then repeats the request. Without an agent that can answer, this runs into
  a timeout and the link drops.
- Pair first (`pair`, with a registered `Agent`), or leave protected characteristics alone.
  BlueZ may create a bond while doing this, so do not probe devices you do not want bonded.

**`bluetoothd` restarts**
- All connections are reported as disconnected.
- Register `setDaemonRestartCallback` and call `recoverAfterDaemonRestart`, then scan and
  connect again.

## Windows (WinRT)

**Connection drops after a few seconds of inactivity**
- Windows has no explicit connect. The link belongs to the GATT sessions that want it.
- Zig-BLE opens a `GattSession` with `MaintainConnection = true` on connect. If the device
  offers no session, a warning is logged and Windows may close an idle link. Reading or
  subscribing re-establishes it.

**A device disconnects after a few seconds, although others stay connected**
- Some devices may end connections from anything but their paired owner; a tracker tag
  disconnected this way in testing, while a fitness band stayed connected. Tags can also
  rotate their random address often, so scan again right before connecting.

**HID devices (keyboards, mice, gamepads): characteristics missing**
- Windows reserves the HID service (0x1812) for its own driver and denies applications
  access.
- Discovery logs a warning and skips that service. All other services of the device remain
  usable.

**Discovery is slow**
- By default every connect reads the services over the air (`Uncached`).
- Set `backend.use_cached_services = true` to use Windows' GATT cache. It is much faster,
  but can return stale services after a firmware update of the peripheral.

**Devices with random addresses are not found**
- Scan before connecting. The backend remembers each device's address type from the scan
  and uses it to resolve random addresses, which `FromBluetoothAddressAsync` alone does
  unreliably.

**Advertisement fields are missing or appear late**
- Windows reports advertisement and scan response separately. The backend merges them per
  device, so name, UUIDs and manufacturer data can appear in a later callback for the same
  device.
- Only the first manufacturer data entry is kept.

**Peripheral role: notifications stall**
- Against a BlueZ central, `NotifyValueAsync` often did not complete within 5 s and the link
  dropped afterwards, even with a single connected subscriber; reads and writes worked. The
  cause is not known yet. `ServerCharacteristic.notify` returns the timeout.

**Removing a bond with a dual-mode device**
- Pairing over LE with a device that also speaks Classic Bluetooth creates a Classic bond as well
  (cross-transport key derivation). `unpair` removes both.
- The other device keeps its keys. Remove the bond there too before pairing again.

**Pairing prompts**
- `pair` uses `DeviceInformationCustomPairing` and asks through `PairingCallbacks`. Without
  callbacks, only Just Works pairing succeeds.

## macOS

There is no CoreBluetooth backend yet: `MacosBackend` returns `NotSupported`. The protocol
toolkit (parsers, crypto, profiles, PCAP) works on macOS.

## Raw HCI / UART

These backends are experimental and do not work against real controllers yet (see the
platform table in the README).
