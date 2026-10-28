# Production Readiness Checklist

Stand: 2026-10-28 (Basis: v1.2.0 + nicht committete Änderungen, nach Code-Review)

Diese Liste sammelt alle Punkte, die Zig-BLE von einem Protokoll-Toolkit zu einer
produktionsreifen BLE-Bibliothek machen. Sortiert nach Priorität:

- **P0** – Blocker vor jedem produktiven Einsatz
- **P1** – fehlende Kernfunktionen
- **P2** – Qualität und Absicherung

## Status-Zusammenfassung

- **Erledigt:** P0 weitgehend, Windows-/BlueZ-Punkte aus P1, die meisten Diagnose- und Release-Punkte.
- **Implementiert, aber nicht auf Hardware verifiziert:** Windows-Pairing, -Peripheral-Rolle, -MTU-Abfrage und -Verbindungsabbruch (Punkte 6, 9–11). Erst nach einem Test mit echtem Gerät als verifiziert betrachten.
- **Offen:** Raw-HCI/UART-Backend, ATT/SMP über Raw-L2CAP, EATT-Anbindung (15, 16, 18, 19, 21), Hardware- und vHCI-Tests (26, 27), Langzeittests (30), README-Beispieltests (36).
- Tests: `zig build test` läuft unter Windows (238 Tests); die Test-Binaries für Linux (gnu, musl) und macOS kompilieren, ausgeführt werden sie erst in der CI.

---

## P0 – Blocker

### Sicherheit

- [x] **1. RNG-Fallback reparieren** ([`src/crypto/toolbox.zig`](../src/crypto/toolbox.zig), `getRandom3Bytes`)
  - [x] Rückgabewerte von `getrandom` und `SystemFunction036` prüfen
  - [x] PRNG mit festem Seed entfernen, stattdessen `std.crypto.random` oder einen Fehler zurückgeben
  - [x] Prüfen, dass `prand` nicht nur aus Nullen bzw. Einsen besteht (Core Spec, Vol 6, Part B, 1.3.2.2)
- [x] **2. Krypto gegen offizielle Testvektoren prüfen**: `f4`, `f5`, `f6`, `g2`, `h6`, `h7`, `ah`, `c1`, `s1` gegen Core Spec, Vol 3, Part H, Appendix D
- [x] **3. Bond-Speicher härten** ([`src/storage/bond_store.zig`](../src/storage/bond_store.zig))
  - [x] LTK und IRK nicht im Klartext speichern (DPAPI unter Windows, Dateirechte 0600 unter Linux, optional Verschlüsselung) — *Windows: DPAPI. Linux: `saveToFile`/`loadFromFile` verlangen einen eigenen Schlüssel (`initWithKey` oder `initWithKeyFile`, Schlüsseldatei mit zufälligem Inhalt und Rechten 0600); der Standard-Schlüssel wird für Dateien unter Linux nicht mehr verwendet. Dateien aus v1.2.x werden mit `error.LegacyFormat` erkannt und lassen sich einmalig mit `deserializeLegacy` importieren. Der Schutz unter Linux beruht weiter auf den Dateirechten (Schlüssel und Daten liegen beim selben Benutzer); TPM oder Secret Service sind nicht angebunden.*
  - [x] Integritätsprüfung per MAC statt nur über das Magic `ZBGR`
  - [x] Atomares Speichern (Temp-Datei schreiben, dann umbenennen)
- [x] **4. Pairing-Agent** ([`src/agent.zig`](../src/agent.zig)): Security-Review, Tests, dass nicht behandelte Anfragen immer abgelehnt werden, Tests mit böswilligen D-Bus-Nachrichten

### Korrektheit

- [x] **5. Verschluckte Fehler beseitigen**: alle `catch {}` in den Backends durch Weiterreichen des Fehlers oder mindestens Logging ersetzen
  - [x] `src/backend/bluez/mod.zig` (Discovery, `addCharacteristic`)
  - [x] `src/backend/windows/mod.zig` (`addService`, CCCD-Write)
- [x] **6. Falsche Rückgabewerte korrigieren**
  - [x] `exchangeMtu` muss auf beiden Backends die tatsächlich ausgehandelte MTU liefern (WinRT `GattSession.MaxPduSize`, BlueZ `MTU`-Property), nicht den gewünschten Wert — *nicht auf Hardware verifiziert*
  - [x] `getBondState` auf Windows echt abfragen (`DeviceInformation.Pairing.IsPaired`) statt immer `.not_bonded`
- [x] **7. Ehrliche Fehler**: Funktionen, die nichts tun, liefern `NotSupported` statt vorgetäuschten Erfolg

### Ehrlichkeit und Doku

- [x] **8. README überarbeiten**
  - [x] Feature-Matrix pro Plattform mit den Stufen „implementiert“, „nur Parser“, „geplant“
  - [x] EATT und SMP ehrlich dokumentieren (README: experimentelle Zustandsmaschinen, Einschränkungen benannt)
  - [x] Testzahl und Version vereinheitlichen (v1.2.0)
  - [x] Marketing-Zahlen („1.7 Billion Ops/s“, „100% zero heap“) entfernen oder mit reproduzierbarem Benchmark belegen

---

## P1 – Fehlende Kernfunktionen

### Windows-Backend

- [x] **9. Pairing/Unpairing** über `DeviceInformationCustomPairing` mit Callbacks für Passkey und Numeric Comparison — *nicht auf Hardware verifiziert*
- [x] **10. Peripheral-Rolle**: GATT-Server per `GattServiceProvider`, Advertising per `BluetoothLEAdvertisementPublisher` — *nicht auf Hardware verifiziert*
- [x] **11. Verbindungsabbrüche erkennen** (`ConnectionStatusChanged`), Reconnect-Callback, Aufräumen der Abonnements — *nicht auf Hardware verifiziert*
- [x] **12. Pool-Größen konfigurierbar** (`[8]` Geräte, `[64]` Characteristics, `[16]` Services); bei vollem Pool ein klarer Fehler

### BlueZ-Backend

- [x] **13. Echte MTU, `Disconnected`-Signalbehandlung, Wiederaufnahme nach Neustart von bluetoothd**
- [x] **14. Berechtigungen im GATT-Server**: `encrypt-read/write`, `authenticated-*`, `secure-*`, `authorize`

### Raw-HCI / Bare-Metal (fertigbauen oder als experimentell kennzeichnen)

- [ ] **15. HCI-Backend und UART-Backend** in der HAL ([`src/backend/`](../src/backend/)) — *Gerüst vorhanden, im README als experimentell gekennzeichnet. Offen: `connectDevice` wartet nicht auf LE Connection Complete und erfindet das Connection-Handle; `readCharacteristic` gibt den Puffer des vorigen Reads zurück, ohne auf die Antwort zu warten; Discovery wartet nicht; `timeout_ms` wird ignoriert.*
- [ ] **16. Verbindungsmanagement**: LE (Extended) Create Connection, Disconnect, Connection Update, Data Length — *HCI-Befehle und -Events vorhanden; das Backend verarbeitet LE Connection Complete noch nicht.*
- [x] **17. ACL-Flusskontrolle** über `Number of Completed Packets` und die Puffergröße des Controllers — *als Baustein (`AclFlowController`), nicht mit Hardware getestet*
- [ ] **18. ATT-Client und -Server über L2CAP CID 0x0004** als Zustandsmaschine mit 30-s-Transaktions-Timeout — *`AttBearer` mit Timeout-Prüfung vorhanden; das HCI-Backend ruft die Timeout-Prüfung nie auf und wartet nicht auf Antworten.*
- [ ] **19. SMP-Zustandsmaschine**: Legacy Pairing und LE Secure Connections (ECDH P-256), Schlüsselverteilung, Start der Verschlüsselung — *Just Works funktioniert im Test. Offen: Bestätigung durch den Nutzer bei Numeric Comparison (sonst kein MITM-Schutz), SC Passkey Entry (20 Runden), vollständige Methodenwahl nach IO-Capabilities, Schlüsselverteilung, Start der Link-Verschlüsselung im Backend.*
- [x] **20. H5-Transport** (3-Wire UART) implementieren oder aus der Doku streichen — *Framing und Link-Aufbau implementiert, nicht mit Hardware getestet*
- [ ] **21. EATT auf L2CAP-CoC aufsetzen**: Credits, Segmentierung über MPS, Fehlerbehandlung pro Bearer ([`src/core/eatt.zig`](../src/core/eatt.zig)) — *Credits und Segmentierung im Bearer vorhanden; noch an kein Backend angebunden.*

### API

- [x] **22. Konkrete Fehlermengen** pro Funktion statt `anyerror` (derzeit 86 Stellen, u. a. die gesamte `BackendVTable`)
- [x] **23. Nebenläufigkeitsmodell** dokumentieren und durchsetzen
  - [x] Welche Callbacks laufen in welchem Thread?
  - [x] Ist die API thread-sicher?
  - [x] Mutex oder Message-Queue in `src/event_loop.zig` und `src/backend/windows/bindings.zig`
- [x] **24. Konfigurierbare Timeouts** für alle blockierenden Operationen (Connect, Read, Write, Discovery); nichts darf endlos hängen — *Windows/BlueZ; das experimentelle HCI-Backend ignoriert `timeout_ms`*
- [x] **25. Lifecycle**: sicheres `deinit` in jedem Zustand; nach `deinit` feuert kein Callback mehr

---

## P2 – Qualität und Absicherung

### Tests

- [ ] **26. Hardware-in-the-Loop-Tests** (z. B. nRF52 oder ESP32 als Gegenstelle, Self-hosted CI-Runner) — *Offen. `scripts/hil_runner.zig` testet nur gegen das Mock-Backend und läuft jetzt als `zig build run-mock-e2e`.*
- [ ] **27. Linux-CI gegen virtuelles HCI** (`btvirt` / `hci_vhci`), ohne Hardware — *Offen. Der bisherige CI-Job führte nur die Unit-Tests erneut aus und wurde entfernt.*
- [x] **28. Coverage-fähiges Fuzzing** (`zig build --fuzz`) für die Parser von ATT, SMP, L2CAP-Signaling, HCI-Events und H4
- [x] **29. Tests der Zustandsmaschinen**: Verbindungsabbruch mitten in einer Transaktion, doppelte Responses, unerwartete Opcodes
- [ ] **30. Langzeit-Stresstests** über viele Stunden (Scannen, Verbinden, Notifications) mit Prüfung auf Speicherlecks (`GeneralPurposeAllocator`) und Handle-Lecks unter Windows — *Teilweise: 1.050 Zyklen gegen das Mock-Backend mit Leck- und Handle-Prüfung (Sekunden, keine Hardware). Offen: Langzeittest mit echten Geräten.*

### Diagnose

- [x] **31. Einheitliches Logging** über `std.log` mit eigenem Scope statt `std.debug.print` (`src/gatt_server.zig`, `src/main.zig`)
- [x] **32. PCAP-Export** an die Windows- und BlueZ-Backends anbinden, soweit möglich

### Release-Prozess

- [x] **33. Semver mit festgelegter öffentlicher API**; interne Module nicht über `src/root.zig` nach außen sichtbar machen
- [x] **34. Releases über Git-Tags**, CHANGELOG passend zu den Tags, Kompatibilität mit `zig fetch`
- [x] **35. `SECURITY.md`** mit einem Meldeweg für Sicherheitslücken
- [ ] **36. README-Beispiele in der CI kompilieren**, damit sie nicht veralten — *`tests/test_readme_examples.zig` enthält eigenen Mock-Code, nicht die Beispiele aus dem README. Offen: die README-Beispiele selbst kompilieren.*
- [x] **37. macOS**: CoreBluetooth-Backend bauen oder ausdrücklich „nicht unterstützt“ dokumentieren (derzeit wird nur der Kern getestet) — *„nicht unterstützt“ dokumentiert; Tests laufen in der CI auch unter macOS*
