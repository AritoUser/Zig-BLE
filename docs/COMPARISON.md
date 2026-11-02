# Vergleich mit anderen BLE-Bibliotheken

Stand: 2026-10-29, Basis v1.3.2

Verglichen wurden Zig-BLE und zehn verbreitete BLE-Projekte. Ziel ist herauszufinden,
was Zig-BLE noch fehlt und welche Fehler die anderen schon gelöst haben. Der Code der
Vorbilder wurde dort gelesen, wo es um konkrete Techniken geht (bleak: WinRT- und
BlueZ-Backend).

**Kurzfazit**

- Bei Parsern, Krypto, Profilen und Werkzeugen (PCAP, Fuzzing, Bond-Speicher) ist Zig-BLE
  breiter aufgestellt als die meisten Desktop-Bibliotheken.
- Die Backends (WinRT, BlueZ) haben dagegen Lücken, die die Vorbilder längst geschlossen
  haben. Beim Vergleich sind auch mehrere echte Fehler aufgefallen (Abschnitt 1).
- Der wichtigste Fund: Das BlueZ-Backend liefert über die `UnifiedAdapter`-API weder
  Scan-Ergebnisse noch Notifications, weil niemand die D-Bus-Signale abholt.

---

## 1. Gefundene Fehler im eigenen Code

Alle Punkte wurden im Code nachgeprüft.

### Kritisch

**F1. BlueZ: Scan-Callback und Notifications kommen nie an** — ✅ behoben (unveröffentlicht, nicht auf Hardware verifiziert)
- [`src/backend/bluez/mod.zig`](../src/backend/bluez/mod.zig)
- `startScan` speichert `active_scan_cb` (Zeile 420), aber kein Code ruft ihn je auf.
- `processSignalWireMessage` (Zeile 143) wertet nur Verbindungsabbrüche, Notifications
  und Daemon-Neustarts aus. Aufgerufen wird es nur in den Tests, das Backend selbst liest
  nie Signale vom D-Bus-Socket.
- Folgen über `UnifiedAdapter`:
  - Ein Scan findet keine Geräte.
  - Notifications kommen nicht an.
  - Verbindungsabbrüche werden nicht erkannt.
  - `InterfacesAdded` (neue Geräte) wird überhaupt nicht ausgewertet.
- Das README markiert Scannen und Notifications unter BlueZ als ✅. Die Hardware-Tests
  liefen wahrscheinlich über die Low-Level-API (`src/main.zig`, `Device`, `Adapter`) und
  nicht über das Backend.
- Vorbild bleak (`bluezdbus/manager.py`): eine zentrale Nachrichtenschleife (`_parse_msg`)
  wertet `InterfacesAdded`, `InterfacesRemoved` und `PropertiesChanged` aus und hält einen
  Spiegel des BlueZ-Objektbaums.
- Lösung:
  - Eine `poll(timeout_ms)`- bzw. `processEvents()`-Methode im Backend oder ein Thread, der
    die Verbindung liest.
  - Dazu die Auswertung von `InterfacesAdded` und von `PropertiesChanged` an `Device1`
    (RSSI, ManufacturerData, ServiceData, Name), die dann `active_scan_cb` aufruft.

**F2. Nur ein Notification-Abo pro Gerät** — ✅ behoben (unveröffentlicht)
- Windows: `dev.notify_cb` in [`gatt.zig:258`](../src/backend/windows/gatt.zig).
  BlueZ: `dev_slot.notify_cb` in [`mod.zig:686`](../src/backend/bluez/mod.zig).
- Jedes `subscribe` überschreibt Callback und `user_data` des Geräts.
- Wer z. B. Herzfrequenz und Akkustand abonniert, bekommt beide Werte mit dem zuletzt
  gesetzten Callback.
- Ein `unsubscribe` auf eine Characteristic setzt `notify_cb = null` und beendet damit
  *alle* Abos des Geräts.
- Unter BlueZ ist es noch enger: `dispatchNotificationForPath` (Zeile 282) leitet nur
  `subscribed_uuid` weiter, also immer nur die zuletzt abonnierte Characteristic.
- Alle Vorbilder speichern den Callback pro Characteristic:
  - btleplug: ein Notification-Stream mit UUID
  - SimpleBLE: `notify(service, characteristic, callback)`
  - tinygo: `characteristic.EnableNotifications(cb)`
- Lösung: `cb` und `user_data` in `WinCharacteristicSlot` bzw. `BluezCharacteristicSlot`
  verschieben.

**F3. Characteristics mit gleicher UUID überschreiben sich** — ✅ behoben (unveröffentlicht)
- Windows: [`device.zig:80`](../src/backend/windows/device.zig).
  BlueZ: [`context.zig:64`](../src/backend/bluez/context.zig).
- `addCharacteristic` sucht zuerst nach der UUID und ersetzt einen vorhandenen Eintrag.
- Das betrifft:
  - HID over GATT: Jeder Report hat die UUID 0x2A4D, nur der letzte bleibt übrig.
  - Geräte mit mehreren Battery-Services.
  - Herstellerdienste, die dieselbe Characteristic-UUID in mehreren Services verwenden.
- Weil die API nur eine Characteristic-UUID annimmt (`readCharacteristic(uuid, buf)`),
  sind solche Characteristics auch grundsätzlich nicht eindeutig ansprechbar.
- Die Vorbilder lösen das so:
  - btleplug: `Characteristic { uuid, service_uuid, properties, descriptors }`
  - SimpleBLE: immer `(service_uuid, characteristic_uuid)`
  - Kable: `characteristicOf(service, characteristic)`
- Lösung: Slots nicht deduplizieren, Service-UUID mitspeichern und in der API einen Handle
  oder das Paar `(service, characteristic)` anbieten. Die alte Variante mit nur einer UUID
  kann bleiben und den ersten Treffer liefern.

### Hoch

**F4. Windows: Verbindung wird nicht gehalten** — ✅ behoben (unveröffentlicht, nicht auf Hardware verifiziert)
- Es wird kein `GattSession` mit `MaintainConnection = true` angelegt.
- Ohne diese Einstellung trennt Windows die Verbindung nach kurzer Inaktivität von selbst.
  Unter Windows gibt es kein explizites „Connect“, die Verbindung gehört der GATT-Session.
- bleak (`winrt/client.py`, ca. Zeile 350–380):
  - holt `GattSession.FromDeviceIdAsync`
  - setzt `maintain_connection = True`
  - wartet auf `SessionStatus == Active`
  - beobachtet `MaxPduSizeChanged`
- Lösung: genauso vorgehen. Das ersetzt auch die MTU-Abfrage über den Umweg
  `IGattDeviceService3.Session`.

**F5. Windows: Herstellerdaten, Service-Daten, TX-Power und Adresstyp fehlen beim Scan** — ✅ behoben bis auf Service-Daten (unveröffentlicht, nicht auf Hardware verifiziert)
- [`scan.zig:18`](../src/backend/windows/scan.zig) liest nur Name, RSSI und Service-UUIDs.
- `get_ManufacturerData` und `get_DataSections` sind in den Bindings deklariert, werden aber
  nicht benutzt. `DiscoveredDevice.mfg_buffer` bleibt auf echten Backends immer leer.
- Damit funktionieren unter Windows weder Beacons noch die eigenen Profile `beacon.zig`
  und Eddystone.
- Außerdem kombiniert Windows Advertisement und Scan Response nicht. Der Name steht oft nur
  in der Scan Response, deshalb meldet der Callback dasselbe Gerät mal mit, mal ohne Namen.
- bleak (`winrt/scanner.py`, Zeile 136–147) merkt sich pro Adresse das Paar
  (Advertisement, Scan Response) und meldet beide zusammengeführt.
- Lösung: die Datenabschnitte (`DataSections`) roh einsammeln und mit dem eigenen
  `core/advertising.zig`-Parser auswerten. Dann gelten auf allen Plattformen dieselben
  Regeln.

**F6. BlueZ: `connect` wartet nicht und ignoriert den Timeout** — ✅ behoben (unveröffentlicht, nicht auf Hardware verifiziert)
- [`mod.zig:476`](../src/backend/bluez/mod.zig): `_ = timeout_ms;`.
- `Device1.Connect` kehrt zurück, bevor BlueZ die Services aufgelöst hat
  (`ServicesResolved`). Ein direkt folgendes `discoverServices` findet dann oft nichts.
- Weil die Discovery bei `characteristics_len == 0` jedes Mal neu startet, läuft danach
  jeder Read erneut durch `GetManagedObjects`.
- `Device.waitForServicesResolved` gibt es schon in [`src/device.zig`](../src/device.zig),
  das Backend nutzt es nur nicht.
- bleak (`_wait_for_services_discovery`) wartet nach jedem Connect auf
  `ServicesResolved = true`.
- Lösung: nach `connect()` mit dem übergebenen Timeout auf `ServicesResolved` warten.
  Kennt BlueZ das Gerät nicht (es wurde vorher nicht gescannt), `DeviceNotFound` statt
  `ConnectionFailed` zurückgeben.

**F7. Spinlock wird über lange blockierende Aufrufe gehalten** — ✅ behoben: blockierender Mutex. Der Haupt-Mutex wird weiter über Awaits gehalten; andere Aufrufe warten dann, verbrauchen aber keine CPU.
- `SyncMutex` ([`types.zig:214`](../src/backend/types.zig)) ist ein reiner Spinlock.
- Gehalten wird er während:
  - `FromBluetoothAddressAsync` (Windows connect, bis zu 10 s)
  - CCCD-Writes
  - allen D-Bus-Aufrufen unter BlueZ (Connect: bis zu 25 s)
- Jeder andere Thread, der in dieser Zeit z. B. `isConnected` aufruft, dreht mit 100 % CPU.
- Der Doc-Kommentar in `bluez/mod.zig:7` behauptet `std.Thread.Mutex`, das stimmt nicht.
- Lösung: einen blockierenden Mutex verwenden und vor langen Awaits entsperren (wie es
  `ensureServicesDiscovered` schon tut).

### Mittel

**F8. Windows: Scan-Callback und Verbindungsstatus ohne Lock** — ✅ behoben (eigener `state_mutex`)
- `handleWatcherReceived` und `handleConnectionStatusTransition` laufen auf WinRT-Threads.
- Beide lesen bzw. schreiben `active_scan_cb`, `rssi` und `is_connected`, ohne den Mutex
  zu halten.
- Wird währenddessen `stopScan` oder `disconnect` aufgerufen, ist das ein Data Race.

**F9. Windows: immer `Uncached`-Discovery** — ✅ Option `use_cached_services`; Standard bleibt `Uncached`
- [`gatt.zig:36`](../src/backend/windows/gatt.zig).
- Jeder Connect erzwingt eine komplette GATT-Discovery über Funk, das kostet je nach Gerät
  1–5 s.
- bleak nutzt standardmäßig den Cache und lädt neu, wenn das Gerät „Service Changed“ meldet.
- Lösung: eine Option `use_cached_services` in `TimeoutConfig` bzw. einer neuen
  `ConnectOptions`.

**F10. Windows: Discovery-Fehler einzelner Services werden verschluckt** — ✅ behoben (Warnung mit Service und Fehler)
- [`gatt.zig:84`](../src/backend/windows/gatt.zig) `catch null`.
- Schlägt `GetCharacteristicsAsync` für einen Service fehl, fehlen dessen Characteristics
  einfach, ohne Fehler und ohne Log. Das widerspricht Punkt 5 der Production-Readiness-Liste.

**F11. `reason_code` beim Trennen ist erfunden** — ✅ behoben (`?u8`, BlueZ-Grund aus `Device1.Disconnected`)
- Windows meldet immer `0x08`, BlueZ `0x13` oder `0x08`.
- BlueZ liefert seit 5.71 das Signal `Device1.Disconnected(reason, message)` mit dem echten
  Grund.
- Lösung: den echten Grund durchreichen oder ein `?u8` liefern.

**F12. Windows: Adresstyp wird beim Connect ignoriert** — ✅ behoben (Adresstyp aus dem Scan)
- `FromBluetoothAddressAsync` ([`mod.zig:348`](../src/backend/windows/mod.zig)) kennt den
  Adresstyp nicht.
- bleak verwendet `FromBluetoothAddressWithBluetoothAddressTypeAsync`, wenn der Typ aus dem
  Scan bekannt ist. Das ist zuverlässiger bei Geräten mit Random Address.

---

## 2. Die Projekte im Einzelnen

### btleplug (Rust): das direkte Vorbild

| | btleplug | Zig-BLE |
|---|---|---|
| Plattformen | Windows, macOS, iOS, Linux, Android | Windows, Linux (macOS ❌) |
| Ereignisse | ein Event-Stream (`DeviceDiscovered`, `DeviceUpdated`, `Connected`, `Disconnected`, `ManufacturerDataAdvertisement`, `ServiceDataAdvertisement`, `ServicesAdvertisement`) | einzelne Callbacks pro Thema |
| Characteristic | Struktur mit Service-UUID, Properties und Descriptors | nur UUID |
| Descriptors | lesen und schreiben | ❌ |
| Gerätezustand | `Peripheral::properties()` (Name, RSSI, TX-Power, Hersteller- und Service-Daten) | `DiscoveredDevice`, nur im Scan-Callback |

**Was wir übernehmen sollten**
- Eine Characteristic-Struktur statt nackter UUID (löst F3).
- Ein einziges Ereignismodell (`union(enum)` in Zig) statt mehrerer Callback-Setter. Damit
  sieht die API auf allen Plattformen gleich aus, und eine Pull-API (`nextEvent()`) wird
  möglich, die sich gut mit Zig-Eventloops verträgt.
- Getrennte Ereignisse für „neues Gerät“ und „Gerät aktualisiert“.
- Properties und Descriptors abfragbar machen (z. B. für die User Description 0x2901 und
  den Presentation Format 0x2904).

### bleak (Python): das am meisten genutzte

- Größte Stärke ist die Dokumentation von Plattformeigenheiten: eine Seite pro Backend,
  Troubleshooting, bekannte Fehlercodes. Für Zig-BLE fehlt so eine Seite ganz.
- Technische Lehren: F1, F4, F5, F6 und F9 oben stammen direkt aus bleaks Code.
- Weitere Punkte:
  - `BleakScanner.find_device_by_address(addr, timeout)` und `find_device_by_filter(...)`
    sind sehr häufig gebrauchte Hilfsfunktionen.
  - `pair()` mit `protection_level` unter Windows.
  - Passives Scannen unter BlueZ über `AdvertisementMonitor1` (Zig-BLE kann unter BlueZ
    nur aktiv scannen).
  - Bei `org.bluez.Error.InProgress` gibt bleak einen verständlichen Hinweis aus, dass
    gerade eine andere Verbindung aufgebaut wird.

### SimpleBLE (C++)

- Aufbau in Schichten (SimpleDBus → SimpleBluez → SimpleBLE) wie Zig-BLE
  (`dbus/wire` → `bluez` → `backend/bluez`).
- **Zwei API-Varianten:** eine mit Exceptions und eine `safe`-Variante, die nie wirft.
  Für Zig nicht nötig, Error Unions decken das ab.
- **C-API und Bindings** (Python, Rust, Java). Zig-BLE könnte mit wenig Aufwand eine C-API
  exportieren (`export fn`). Das würde die Bibliothek auch außerhalb von Zig nutzbar machen,
  z. B. als kleinere Alternative zu SimpleBLE.
- Callbacks pro Peripheral: `set_callback_on_connected/disconnected`.
- Achtung Lizenz: Business Source License 1.1. Nur Ideen übernehmen, keinen Code.

### tinygo/bluetooth (Go): Desktop und Embedded mit einer API

- Dieselbe API läuft auf Windows, Linux, macOS *und* Mikrocontrollern (nRF SoftDevice,
  HCI über UART für ESP32 und Pico W).
- Für Zig-BLE das wichtigste strategische Vorbild: Zig wird stark für Embedded genutzt.
  Ein Standard muss dort laufen, und genau hier ist Zig-BLE noch 🚧 (HCI/UART-Backend).
- Kleine, pragmatische API:
  - `adapter.Scan(cb)`
  - `adapter.Connect(addr, params)`
  - `device.DiscoverServices(filter_uuids)` mit Filter
  - `char.EnableNotifications(cb)`
  - `char.GetMTU()`
- **Discovery mit UUID-Filter** spart auf langsamen Geräten viel Zeit. Zig-BLE entdeckt
  immer alles.
- `ConnectionParams` beim Connect (Intervall, Timeout).

### Kable (Kotlin): Zustand und Wiederverbinden

- Der Gerätezustand ist eine beobachtbare Zustandsmaschine:
  `Connecting → Connected → Disconnecting → Disconnected(status)`.
- **`observe()` überlebt Reconnects:** Nach einem Wiederverbinden werden Abos automatisch
  neu eingerichtet.
- Zig-BLE löscht beim Trennen alle Abos (`clearSubscriptions`). Nutzer müssen dann selbst
  neu abonnieren und bekommen nur einen `reconnect_cb` (Windows) bzw. gar nichts (BlueZ).
- **Übernehmen:**
  - einen `ConnectionState`-Enum, den man jederzeit abfragen kann
  - optionales automatisches Neu-Abonnieren nach einem Reconnect

### BlueR (Rust, offiziell von BlueZ)

- Die Referenz für korrektes BlueZ: Discovery-Events als Stream, GATT-Server,
  `AdvertisementMonitor`, L2CAP- und RFCOMM-Sockets.
- Notifications nutzen bevorzugt `AcquireNotify` (Dateideskriptor statt
  D-Bus-Nachricht pro Wert). Zig-BLE hat `acquireNotifyFd` schon, nutzt es aber nicht für
  normale `subscribe`-Aufrufe. Das wäre deutlich schneller und würde F1 bei Notifications
  teilweise umgehen.
- `Device1.Disconnected`-Signal mit echtem Grund (siehe F11).
- Bevor Zig-BLE das BlueZ-Backend als ✅ führt, lohnt sich ein genauer Abgleich der
  D-Bus-Nutzung mit BlueR.

### TrouBLE (Rust, Embassy): Host-Stack ohne Heap

- Der Host-Stack, der Zig-BLEs Embedded-Teil am ähnlichsten ist:
  - kein Heap
  - Controller über ein Trait (`bt-hci`) austauschbar
  - läuft auf nRF, ESP32, Pico W, STM32WB, UART-HCI und Linux-HCI-Sockets
- **Ein Runner, keine Callbacks:** Der Host läuft als eigene Task, Verbindungen und
  GATT-Ereignisse werden über Kanäle abgeholt. Damit ist die Frage „wer wartet auf die
  Antwort?“ sauber gelöst, also genau das, woran Zig-BLEs HCI-Backend scheitert (Punkte
  15, 16, 18 der Production-Readiness-Liste).
- **Paket-Pool** mit fester Größe für ACL- und L2CAP-Puffer statt fester Arrays pro Gerät.
- **GATT-Server per Makro:** Services werden deklarativ definiert. In Zig ginge das per
  `comptime` noch eleganter.
- **BSWorld** ([XiaoMi/bsworld](https://github.com/XiaoMi/bsworld)): deterministische
  Funksimulation für Tests ohne Hardware.

### Bumble (Python, Google): das Testwerkzeug

- Ein kompletter BLE-Stack in Python, der als **virtueller Controller und virtuelles
  Gegenüber** arbeiten kann. Er unterstützt HCI über TCP, UDP, USB, Serial und Linux
  `vhci`.
- **Für Zig-BLE der größte Hebel:**
  - Linux-CI: Über `vhci` erscheint Bumble als echter Bluetooth-Adapter. BlueZ und damit
    das BlueZ-Backend (inklusive F1, F2, F6) lassen sich in GitHub Actions ohne Hardware
    testen.
  - HCI- und UART-Backend: Bumble spricht H4 über TCP oder einen Pseudo-TTY. Damit lassen
    sich `HciBackend` und `UartBackend` gegen einen echten Stack testen, ATT, SMP und
    Pairing eingeschlossen.
- Erledigt die offenen Punkte 26 und 27 der Production-Readiness-Liste (Hardware- und
  vHCI-Tests).

### NimBLE, BTstack, Zephyr (C): die ausgereiften Stacks

- Nachschlagewerk für Randfälle im SMP und ATT:
  - Methodenwahl nach IO-Capabilities
  - Schlüsselverteilung
  - Passkey-Entry mit 20 Runden
  - Fehlerbehandlung bei parallelen ATT-Requests
- Zephyr nutzt **BabbleSim** für Funksimulation in der CI und **auto-pts** für die
  automatisierten Qualifikationstests der Bluetooth SIG. Langfristig ist das der Weg zu
  einem qualifizierbaren Stack.
- Lizenzen: NimBLE und Zephyr unter Apache-2.0 (Ideen und mit Hinweis auch Code nutzbar),
  BTstack kommerziell (nur lesen).

### Zig-Projekte

- **ble-scanner** (Zig, Windows und Linux):
  - dekodiert iBeacon, Eddystone, Apple Continuity, Google Fast Pair, Microsoft Swift Pair
    und Xiaomi
  - enthält die über 4.000 SIG-Firmen-IDs
  - Übernehmen: ein optionales Modul `profiles/vendor_adv.zig` und eine komplette
    Company-ID-Tabelle (Zig-BLE hat in `assigned_numbers.zig` nur einen Teil). Am besten
    aus dem offiziellen SIG-YAML-Repository zur Build-Zeit erzeugen.
- **zble** (seit 2023 aufgegeben), **blueZig**, **btproxy**: keine Konkurrenz, nichts zu
  übernehmen.

---

## 3. Was Zig-BLE schon besser macht

- **Keine C-Abhängigkeit unter Linux.** Bleak braucht `dbus-fast`, btleplug `dbus-rs`
  (libdbus), SimpleBLE libdbus.
- **Protokoll-Werkzeugkasten ohne Backend** (Parser, Krypto mit offiziellen Testvektoren,
  PCAP-Writer, 15 SIG-Profile). Das hat keine der Desktop-Bibliotheken.
- **Bond-Speicher mit Verschlüsselung und MAC.** Desktop-Bibliotheken überlassen das dem
  Betriebssystem.
- **Fuzzing** von Advertising-Parser und D-Bus-Wire. Bei den Vorbildern selten.
- **Mock-Backend** für Anwendertests. Hat sonst nur SimpleBLE.

---

## 4. Prioritätenliste

| Prio | Aufgabe | Herkunft |
|---|---|---|
| 1 | BlueZ-Signale abholen: Scan-Ergebnisse, Notifications, Verbindungsabbrüche (F1) | bleak, BlueR |
| 2 | Notifications pro Characteristic statt pro Gerät (F2) | alle |
| 3 | Characteristics mit Service-UUID speichern, keine Deduplizierung, API mit `(service, characteristic)` (F3) | btleplug, SimpleBLE, Kable |
| 4 | Windows `GattSession` + `MaintainConnection` (F4) | bleak |
| 5 | Windows: Hersteller- und Service-Daten, Scan Response zusammenführen (F5) | bleak |
| 6 | BlueZ: auf `ServicesResolved` warten, Timeout beachten (F6) | bleak |
| 7 | Blockierender Mutex statt Spinlock, nicht über Awaits halten (F7, F8) | – |
| 8 | Bumble als virtueller Controller in der Linux-CI — *offen; als Zwischenschritt testet `tests/bluez_fake_e2e.zig` das Backend gegen ein simuliertes `org.bluez`* | Bumble |
| 9 | Ein einheitliches Event-Modell (`union(enum)`) mit `nextEvent()` — ✅ `EventQueue` | btleplug, TrouBLE |
| 10 | `ConnectionState` und automatisches Neu-Abonnieren nach Reconnect — *offen* | Kable |
| 11 | Descriptors lesen/schreiben, Discovery mit UUID-Filter, Cache-Option (F9) — ✅ Descriptors und Cache-Option; UUID-Filter offen | btleplug, tinygo, bleak |
| 12 | HCI-Backend nach dem Runner-Modell von TrouBLE fertigbauen — *offen* | TrouBLE, tinygo |
| 13 | Plattform- und Troubleshooting-Doku — ✅ [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | bleak |
| 14 | C-API für Nutzung aus anderen Sprachen — *offen* | SimpleBLE |
| 15 | Vendor-Advertising-Decoder und vollständige Company-ID-Tabelle — ✅ Swift Pair, Fast Pair; Company-ID-Tabelle offen | ble-scanner |
| 16 | macOS-Backend (CoreBluetooth) — *offen* | btleplug, bleak, SimpleBLE |

Die Punkte 1 bis 7 sind Fehler bzw. Lücken in Funktionen, die das README heute schon als
verfügbar führt. Sie sollten vor neuen Funktionen kommen. Bis F1 behoben ist, sollte die
BlueZ-Spalte im README für Scannen, Notifications und Verbindungsabbrüche nicht ✅ zeigen.

## Quellen

- btleplug: <https://github.com/deviceplug/btleplug>
- bleak: <https://github.com/hbldh/bleak> (`bleak/backends/winrt/client.py`, `winrt/scanner.py`, `bluezdbus/manager.py`)
- SimpleBLE: <https://github.com/simpleble/simpleble>
- tinygo bluetooth: <https://github.com/tinygo-org/bluetooth>
- Kable: <https://github.com/JuulLabs/kable>
- BlueR: <https://github.com/bluez/bluer>
- TrouBLE: <https://github.com/embassy-rs/trouble>
- Bumble: <https://github.com/google/bumble>
- NimBLE: <https://github.com/apache/mynewt-nimble> · BTstack: <https://github.com/bluekitchen/btstack> · Zephyr: <https://github.com/zephyrproject-rtos/zephyr>
- ble-scanner: <https://github.com/SavchukSergey/ble-scanner>
