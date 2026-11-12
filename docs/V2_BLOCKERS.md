# Offene Punkte bis v2.0.0

v2.0.0 erscheint erst, wenn alles hier erledigt ist. Was nur manchmal funktioniert, gilt als
nicht erledigt. Stand: 2026-11-11. Die Testbefehle stehen in [`HARDWARE_TESTS.md`](HARDWARE_TESTS.md).

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
| A4 | ✅ **Gelöst 2026-11-11.** Windows trennte nach `disconnect` nicht, solange auf der Gegenstelle ein Indication-Abo aktiv war: Die Verbindung blieb über Minuten stehen, auch nach Prozessende, und ein „Reconnect“ lief über die alte Verbindung (damit war auch der Auto-Resubscribe-Test unter Windows nie eine echte Neuverbindung). Mit WinRT direkt nachgestellt, also Windows-Verhalten. `disconnect` und `deinit` melden die Abos jetzt vorher auf der Gegenstelle ab; danach sendet das Linux-Peripheral 3–20 s später wieder Advertising. | 2026-11-11, gegen BlueZ-Peripheral | 10/10 im Sammellauf („disconnect ends the link“) — erfüllt, Wiederholung an einem zweiten Tag offen |
| A5 | ✅ **Gelöst 2026-11-11.** BlueZ-Backend: Jedes zweite Characteristic-Flag wurde überlesen. Schreiben ohne Antwort an ein Windows-Peripheral scheiterte dadurch mit `NotSupported`, seit das Backend die Eigenschaft prüft. | 2026-11-11, gegen Windows-Peripheral | 10/10 im Sammellauf — erfüllt, Wiederholung an einem zweiten Tag offen |
| A6 | **Offen, einmal beobachtet.** Linux-Central: ein `Device1.Connect` zum Windows-Peripheral lief in den 60-s-Timeout, 1 von 179 Verbindungen in zwei Sammelläufen; der nächste Versuch zur selben Adresse gelang. Im Wiederholungslauf mit `btmon` nicht mehr aufgetreten, Ursache daher unbekannt. | 2026-11-11 | Ursache bekannt oder in zwei weiteren Sammelläufen nicht mehr aufgetreten |
| A7 | ✅ **Gelöst 2026-11-11.** Windows konnte nicht per Just Works koppeln: `pair(.no_input_no_output)` verlangte MITM-Schutz, BlueZ lehnte mit „Authentication requirements“ ab (per `btmon` belegt). Windows fordert dafür jetzt nur Verschlüsselung. | 2026-11-11, gegen BlueZ-Peripheral | 10/10 — erfüllt, Wiederholung an einem zweiten Tag offen |
| A8 | **Offen, einmal beobachtet.** Windows-Central: Nach fünf Runden Koppeln und Entkoppeln desselben Geräts meldete `PairAsync` für einige Minuten `OperationAlreadyInProgress` (Status 15), drei Runden in Folge; danach ging es ohne Zutun wieder. In den 40 Runden danach nicht mehr aufgetreten. Ursache unbekannt, vermutlich ein Vorgang, den Windows nach dem Entkoppeln noch offen hatte. | 2026-11-11 | Ursache bekannt oder das Backend wartet den Zustand ab; 10/10 an zwei Tagen |
| A9 | **Offen.** Linux-Central koppelt mit dem Windows-Peripheral (das Peripheral startet das Pairing): 4 von 40 Runden scheiterten, je zwei direkt hintereinander (Numeric Comparison Runde 8 und 9, Passkey Runde 7 und 8). Per `btmon` für die Passkey-Runde belegt: Der SMP-Austausch läuft bis zum DHKey Check durch, Linux sendet `LE Start Encryption`, darauf kommt keine Antwort mehr und die Verbindung endet nach 9,8 s mit `Connection Timeout`; auch die nächste Verbindung brach so ab. Das liegt unterhalb von Zig-BLE (Controller oder Funk), die Ursache ist aber nicht geklärt. | 2026-11-11 | Ursache bekannt; 10/10 je Methode an zwei Tagen |

## B. Nie auf Hardware getestet

| # | Funktion | Windows | Linux |
| :--- | :--- | :---: | :---: |
| B1 | Pairing als Central (`--pair`), Numeric Comparison, Bond hält über einen Reconnect. Windows: 10/10 mit `scripts/hardware_pairing.sh`, jede Runde mit frischem Bond und gleichem Code auf beiden Seiten. Linux: Koppeln klappt, der Reconnect danach scheitert (B13). | ✅ 10/10 | teilweise |
| B2 | Pairing per Just Works und per Passkey (Central tippt / Peripheral tippt). Windows als Central mit Reconnect: je 10/10. Linux als Central gegen das Windows-Peripheral: Just Works 10/10, Passkey (Peripheral tippt) 10/10, Passkey (Central tippt) 8/10 und Numeric Comparison 8/10, siehe A9. | ✅ je 10/10 | teilweise (A9) |
| B3 | Erneutes Koppeln, nachdem eine Seite die Kopplung vergessen hat. Jede Runde des Pairing-Skripts entfernt den Bond auf beiden Seiten; der Fall „nur eine Seite vergisst“ ist noch nicht gezielt geprüft. | offen | offen |
| B4 | Auto-Resubscribe mit ankommenden Notifications. Seit A4 ist der Reconnect unter Windows eine echte Neuverbindung: CCCDs danach wieder `0100`/`0200`, Notifications kommen. | ✅ 10/10 | ✅ 10/10 |
| B5 | Langzeittest 8 h (`--soak 480`), keine Fehler, keine steigenden Handles | offen | offen |
| B6 | Neustart von `bluetoothd` während der Verbindung | – | offen (braucht Root) |
| B7 | Gerät verlässt die Reichweite und kommt zurück | offen | offen |
| B8 | Indications, als Central empfangen und als Peripheral gesendet (CCCD `0200`, mindestens 20 in 30 s) | ✅ 10/10 | ✅ 10/10 |
| B9 | Lange Werte: 300 und 200 Byte lesen, 512 Byte mit und 200 Byte ohne Antwort schreiben, in beiden Rollen. Beide Seiten handeln MTU 517 aus, die Werte passen also in ein Paket; Read Blob und Prepare Write laufen erst bei kleinerer MTU und dann im Stack des Betriebssystems. Ein Lauf mit kleiner MTU (z. B. Gegenstelle mit MTU 23) steht aus. | ✅ 10/10 bei MTU 517 | ✅ 10/10 bei MTU 517 |
| B10 | Mehrere Geräte gleichzeitig verbunden. Prüfmodus `--multi` ist da, noch kein Lauf. | offen | offen |
| B11 | Descriptor schreiben (außer CCCD), als Central und als Peripheral (Windows legt eigene Descriptors jetzt an) | ✅ 10/10 | ✅ 10/10 |
| B12 | Windows: `MaintainConnection` an und aus im Vergleich, Slot-Wiederverwendung über viele Verbindungen | offen | – |
| B13 | Gerät nach dem Koppeln wiederfinden (Linux, 2026-11-11). (1) BlueZ behält das Objekt unter der alten Zufallsadresse und ändert nur `Address`: `connect` sucht das Objekt jetzt über `Address` — behoben, auf Hardware belegt. (2) Ein Dual-Mode-Gerät ist durch CTKD auch über BR/EDR gekoppelt und `Device1.Connect` wählte BR/EDR: Das Backend setzt `PreferredBearer = "le"` (nur mit `Experimental = true` in BlueZ) — wirkt, auf Hardware belegt. (3) Der LE-Connect zum gekoppelten PC scheitert trotzdem: Der Kernel kennt den IRK und hat die aktuelle Zufallsadresse aufgelöst, verbindet aber über die Auflösungsliste des Controllers mit der Identitätsadresse, und der Realtek-Controller findet das Gerät nicht (per `btmon` belegt). Kernel/Controller, nicht Zig-BLE; offen, ob ein anderer Adapter das kann. | offen | (1)(2) ✅, (3) offen |

## C. Test-Infrastruktur

| # | Punkt | Erledigt, wenn |
| :--- | :--- | :--- |
| C1 | Teilweise: `ble-hardware-check <addr\|auto> --service <uuid> --suite` fährt alle Prüfungen ohne Abfrage 10-mal und druckt die Tabelle; `scripts/hardware_pairing.sh` steuert beide Rechner für die Pairing-Prüfungen (noch kein Lauf). Offen: Soak, `bluetoothd`-Neustart und mehrere Geräte im selben Lauf. | ein Befehl liefert die Tabelle aus `HARDWARE_TESTS.md` mit „10/10“ je Zeile |
| C2 | Eine Gegenstelle, die zuverlässig Notifications, Indications und Pairing kann (z. B. Handy mit nRF Connect oder ein nRF52) | Tests hängen nicht mehr vom Windows-Peripheral ab |
| C3 | ✅ README-Beispiele in der CI kompilieren (Readiness #36): `zig build check-readme`, lokal für Windows und Linux grün (2026-11-11). Der erste CI-Lauf steht mit dem PR (D1) aus. | CI baut den Code aus dem README |
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
