# Offene Punkte bis v2.0.0

v2.0.0 erscheint erst, wenn alles hier erledigt ist. Was nur manchmal funktioniert, gilt als
nicht erledigt. Stand: 2026-11-10. Die Testbefehle stehen in [`HARDWARE_TESTS.md`](HARDWARE_TESTS.md).

## Release-Kriterien

Ein Punkt ist erst erledigt, wenn:

1. sein Test auf Windows und Linux **10 von 10 Mal** grün läuft,
2. die ganze Checkliste an **zwei verschiedenen Tagen** komplett grün war,
3. README, CHANGELOG und Checkliste kein ✅ ohne belegten Lauf enthalten.

## A. Fehler (heute rot)

| # | Problem | Beobachtet | Erledigt, wenn |
| :--- | :--- | :--- | :--- |
| A1 | ✅ **Gelöst 2026-11-11** (Umgebung, nicht Zig-BLE). Windows verband sich zum Linux-Peripheral nur in etwa jedem zweiten Versuch: Der Realtek-USB-Adapter liefert die erste ATT-Anfrage von Windows 2–3 ms vor `LE Connection Complete`, der Kernel verwarf sie (per `btmon` belegt, 8/8 Verbindungen; `force_poll_sync` reicht bei `CONFIG_HZ=1000` nicht). Behoben mit dem `btusb`-Patch in `tools/linux-btusb-hold-acl/`. Danach 10/10 mit WinRT direkt und 20/20 mit Zig-BLE, Connect in 2–8,3 s. Zusätzlich verbindet das Windows-Backend nach einem hängenden ersten Versuch neu. | 2026-11-10, gegen BlueZ 5.82 | 10/10 Connects; Ursache bekannt — erfüllt, Wiederholung an einem zweiten Tag offen |
| A2 | ✅ **Gelöst 2026-11-11**, gleiche Ursache wie A1: Das erste ATT-Paket von Windows ging im Linux-Kernel verloren, danach hingen alle weiteren Sendungen von Windows. Mit dem `btusb`-Patch: 10/10 Runden mit 28–29 Notifications in 30 s und gehaltener Verbindung, dazu 10/10 Resubscribe-Runden (20 Verbindungen zum selben Peripheral), kein verzögertes Notify. | 2026-11-10, BlueZ-Central | 10/10 Läufe mit allen Notifications — erfüllt, Wiederholung an einem zweiten Tag offen |
| A3 | ✅ **Gelöst 2026-11-11.** Pairing, das der Client startet, nimmt Windows selbst an oder zeigt seinen Dialog; die Anwendung erfährt nichts. Neu: `ServerCharacteristic.pairSubscribers(io_cap, callbacks)` koppelt die verbundenen Abonnenten von Windows aus, die Abfrage kommt über `PairingCallbacks`. 10/10 Runden am Stück gegen einen BlueZ-Central: Numeric Comparison mit gleichem Code auf beiden Seiten, danach `protected` lesbar. | 2026-11-11 | Pairing mit Windows als Peripheral ist über `PairingCallbacks` steuerbar und 10/10 getestet — erfüllt, Wiederholung an einem zweiten Tag offen |

## B. Nie auf Hardware getestet

| # | Funktion | Windows | Linux |
| :--- | :--- | :---: | :---: |
| B1 | Pairing als Central (`--pair`) | ✅ | offen |
| B2 | Pairing per Passkey und Just Works | offen | offen |
| B3 | Erneutes Koppeln, nachdem eine Seite die Kopplung vergessen hat | offen | offen |
| B4 | Auto-Resubscribe mit ankommenden Notifications | ✅ | ✅ 10/10 |
| B5 | Langzeittest 8 h (`--soak 480`), keine Fehler, keine steigenden Handles | offen | offen |
| B6 | Neustart von `bluetoothd` während der Verbindung | – | offen (braucht Root) |
| B7 | Gerät verlässt die Reichweite und kommt zurück | offen | offen |
| B8 | Indications (bisher nur Notifications) | offen | offen |
| B9 | Lange Werte über der MTU (Long Read, Long Write) | offen | offen |
| B10 | Mehrere Geräte gleichzeitig verbunden | offen | offen |
| B11 | Descriptor schreiben (außer CCCD) | offen | offen |
| B12 | Windows: `MaintainConnection` an und aus im Vergleich, Slot-Wiederverwendung über viele Verbindungen | offen | – |
| B13 | Geräte mit wechselnder Random-Adresse (RPA) nach dem Koppeln wiederfinden. Beobachtet 2026-11-11: Nach dem Koppeln entfernt BlueZ das Objekt unter der RPA und führt das Gerät unter seiner Identitätsadresse weiter; ein `BluezBackend`-Handle auf das alte Objekt veraltet dabei vermutlich. Prüfen und beheben. | offen | offen |

## C. Test-Infrastruktur

| # | Punkt | Erledigt, wenn |
| :--- | :--- | :--- |
| C1 | Hardware-Tests als ein Skript, das alle Läufe nacheinander ausführt und zählt | ein Befehl liefert die Tabelle aus `HARDWARE_TESTS.md` mit „10/10“ je Zeile |
| C2 | Eine Gegenstelle, die zuverlässig Notifications, Indications und Pairing kann (z. B. Handy mit nRF Connect oder ein nRF52) | Tests hängen nicht mehr vom Windows-Peripheral ab |
| C3 | README-Beispiele in der CI kompilieren (Readiness #36) | CI baut den Code aus dem README |
| C4 | Linux-CI gegen virtuellen Controller (Readiness #27) | CI testet BlueZ mit `btvirt` oder `hci_vhci` |

## D. Release-Vorbereitung

| # | Punkt |
| :--- | :--- |
| D1 | Branch `test/hardware-linux-pairing` als PR nach `main`, CI grün |
| D2 | Release Notes von v1.3.0 bis v1.3.2 korrigieren: Windows konnte dort weder scannen noch GATT nutzen |
| D3 | CHANGELOG-Abschnitt „Unreleased“ als 2.0.0 abschließen, Breaking Changes vollständig aufführen |

## E. Zu entscheiden

| # | Frage | Folge |
| :--- | :--- | :--- |
| E1 | Gehören Raw HCI und UART zu v2? (Readiness #15, 16, 18, 19) | ja: ACL-Credits, Peripheral-Rolle, Tests gegen einen echten Controller; nein: bleiben als experimentell markiert |
| E2 | Gehört EATT zu v2? (Readiness #21) | ja: an ein Backend anbinden und testen; nein: bleibt Baustein ohne Backend |
| E3 | Ist macOS für v2 ausgeschlossen? | heute so festgelegt, `MacosBackend` liefert `NotSupported` |
