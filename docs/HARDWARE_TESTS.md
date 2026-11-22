# Hardware-Tests vor v2.0.0

v2.0.0 erscheint erst, wenn die Punkte hier unter Windows und Linux auf echter Hardware
bestanden sind. macOS ist ausgenommen. Tests gegen Mock oder simuliertes BlueZ zählen nicht.

## Vorbereitung

```bash
zig build hardware-check
```

Starte danach `zig-out/bin/ble-hardware-check` direkt (unter Windows mit `.exe`), denn die
Pairing-Abfragen lesen vom Terminal. Linux braucht Zugriff auf BlueZ über den System-Bus und
einen Adapter. Ein LXC-Container ohne `AF_BLUETOOTH` genügt, wenn er den `org.bluez` des Hosts
erreicht; `bluetoothctl show` zeigt dann den Controller.

Eine Ausgabe ohne die Adresse des Geräts lässt sich gefahrlos teilen.

## Gegenstellen

`--write` und `--pair` verändern das Gerät. Nimm dafür nur eigene Geräte, deren Zustand sich
ändern darf, am besten:

- den anderen Rechner mit `ble-hardware-check --peripheral`, oder
- ein Handy mit einem GATT-Server, z. B. in nRF Connect.

Unter Linux koppelt BlueZ von sich aus, sobald ein Zugriff mit fehlender Authentifizierung
abgelehnt wird. Prüfe fremde oder fest gekoppelte Geräte daher nicht unter Linux, und schränke
Tests mit `--service <uuid>` auf den Test-Service ein.

Der Peripheral-Modus bietet diese Characteristics an:

| Name | UUID | Eigenschaften |
| :--- | :--- | :--- |
| echo | `5a1e0002-6f3b-4c52-9d27-1e8b7c4a2f10` | Lesen, Schreiben, Schreiben ohne Antwort |
| counter | `5a1e0003-6f3b-4c52-9d27-1e8b7c4a2f10` | Lesen, Notify jede Sekunde |
| protected | `5a1e0004-6f3b-4c52-9d27-1e8b7c4a2f10` | Lesen nur nach Pairing, nur mit `--secure` |
| indicate | `5a1e0005-6f3b-4c52-9d27-1e8b7c4a2f10` | Lesen, Indication jede Sekunde |
| long | `5a1e0006-6f3b-4c52-9d27-1e8b7c4a2f10` | Lesen (300 Byte), Schreiben, Schreiben ohne Antwort |
| echo-Descriptor | `5a1e0007-6f3b-4c52-9d27-1e8b7c4a2f10` | Descriptor an echo: Lesen, Schreiben |

Weitere Modi neben denen in der Tabelle unten: `--write-len <uuid> <bytes>` schreibt einen
langen Wert, `--write-desc <char-uuid> <descriptor-uuid> <hex>` einen Descriptor,
`--disconnect` prüft, ob die Verbindung wirklich endet, `--idle <s>` hält sie ohne Abo im
Leerlauf und prüft danach, ob sie noch steht (mit `--no-maintain` vor dem Modus ohne
`MaintainConnection`, B12), `--multi <addr> <addr> …` verbindet
mehrere Geräte gleichzeitig (B10), `--io <capability>` setzt die IO-Fähigkeit fürs Pairing und
`--answers <datei>` beantwortet die Pairing-Abfragen aus einer Datei. `ble-hardware-check`
ohne Argumente druckt die vollständige Übersicht.

## Tests

Spalten: **W** Windows, **L** Linux. `✅` bestanden, `⚠️` nur teilweise, Stand 2026-11-21.
Linux: BlueZ 5.82, Realtek-USB-Adapter; Gegenstelle der jeweils andere Rechner.

| # | Test | Befehl | Bestanden, wenn | W | L |
| :--- | :--- | :--- | :--- | :---: | :---: |
| 1 | Scan | `ble-hardware-check` | Geräte mit Name, Herstellerdaten und UUIDs erscheinen | ✅ | ✅ |
| 2 | Verbinden, Lesen, Notifications, MTU, 30 s halten | `… <addr> --service <uuid>` | `connected = true` nach 30 s, Notifications kommen | ✅ | ✅ |
| 3 | Service-Filter | `… <addr> --service <uuid>` | nur dieser Service wird gelistet und gescannt | ✅ | ✅ |
| 4 | Auto-Resubscribe | `… <addr> --service <uuid> --resubscribe` | CCCD der Gegenstelle nach dem Reconnect wieder `0100`, Notifications kommen | ✅ | ✅ |
| 5 | Schreiben mit Antwort | `… <addr> --write 5a1e0002-… 0102` | `After: 0102 (matches)` | ✅ | ✅ |
| 6 | Schreiben ohne Antwort | `… --write 5a1e0002-… 0304 --no-response` | `After: 0304 (matches)` | ✅ | ✅ |
| 7 | Pairing | `… <addr> --service <uuid> --pair` | Bond-Status `bonded`, auch nach dem Reconnect; protected liefert `paired` | ✅ | ✅ |
| 8 | Bond entfernen | `… <addr> --unpair` (`removeBond`, ohne Verbindung) | beim nächsten Verbinden `not_bonded`, Windows führt das Gerät nicht mehr | ✅ | ✅ |
| 9 | Peripheral: Client verbindet sich | `… --peripheral` | echo les- und schreibbar, counter zählt | ✅ | ✅ |
| 10 | Peripheral: Pairing | `… --peripheral --secure` | Windows koppelt den Abonnenten selbst (gleicher Code auf beiden Seiten), danach liefert protected `paired` | ✅ | ✅ |
| 11 | Langzeit: Scannen, Verbinden, Slots | `… <addr> --soak 480` | Kein Absturz, jede Fehlrunde erholt sich im nächsten Zyklus, Speicher und Handles steigen nicht (V2_BLOCKERS B5) | ✅ | ✅ |
| 12 | Neustart von `bluetoothd` | während 11: `sudo systemctl restart bluetooth` | `Recovered.`, danach laufen die Zyklen weiter | – | |

Anmerkungen:

- **2, 5, 6 unter Windows:** gegen das Linux-Peripheral. Bis 2026-11-11 gelang der Verbindungsaufbau nur in etwa jedem zweiten Versuch; Ursache war der Linux-Kernel auf dem Testserver (A1). Mit dem `btusb`-Patch 20/20.
- **4 unter Linux:** 10/10 Runden gegen das Windows-Peripheral, nach jedem Reconnect CCCD wieder `0100` und 14–15 Notifications (2026-11-11, mit dem `btusb`-Patch).
- **4 unter Windows:** Bis 2026-11-11 trennte Windows vor dem Reconnect nicht wirklich (A4). Seit dem Fix wartet die Prüfung, bis das Peripheral wieder Advertising sendet; 10/10 im Sammellauf.
- **9 unter Windows:** Lesen, Schreiben und Notifications gehen, 10/10 Runden mit 28–29 Notifications in 30 s. Die früheren Hänger kamen vom Linux-Kernel, nicht von Windows (siehe A1/A2 in `V2_BLOCKERS.md`).
- **7, 8, 10:** Alle vier Pairing-Methoden laufen für W 10/10 an zwei Tagen (siehe Pairing).
  **7 L:** Linux koppelt als Central, alle vier Methoden 10/10 an zwei Tagen; der Reconnect danach
  scheitert am Kernel (B13 (3b)) und zählt als bekannte Einschränkung nicht (entschieden
  2026-11-21). **8 L** ist nicht eigens geprüft; die Pairing-Läufe entfernen den Bond
  unter Linux über `Adapter1.RemoveDevice`.
- **11:** gemessen mit `scripts/hardware_soak.sh`, siehe Langzeittest.
- **8 unter Windows:** Eine LE-Kopplung mit einem Dual-Mode-Gerät legt auch eine Classic-Kopplung
  an. `unpair` entfernt jetzt beide (vorher blieb die Classic-Hälfte, und Windows versuchte weiter,
  das Gerät über Classic zu erreichen). Die Gegenstelle behält ihre Schlüssel; unter BlueZ
  entfernt `Adapter1.RemoveDevice` sie.
- **12** braucht Root auf dem Rechner mit `bluetoothd`.

## Sammellauf

Ein Rechner läuft als Peripheral, der andere fährt alle Prüfungen ohne Abfrage zehnmal:

```bash
ble-hardware-check --peripheral 20000                       # Gegenstelle
ble-hardware-check <addr> --service 5a1e0001-6f3b-4c52-9d27-1e8b7c4a2f10 --suite
```

Ein Windows-Peripheral wechselt seine Adresse alle paar Minuten; nimm dafür `auto` statt der
Adresse. Am Ende steht je Prüfung, wie viele Runden bestanden sind, und der Exit-Code ist nur
bei „10/10“ überall 0. Stand 2026-11-11 (Tag 1), W = Windows als Central gegen das
Linux-Peripheral, L = Linux als Central gegen das Windows-Peripheral:

| Prüfung | W | L |
| :--- | :---: | :---: |
| Verbinden, Lesen, Notifications, 30 s halten | 10/10 | 10/10 |
| Indications | 10/10 | 10/10 |
| Langen Wert lesen (200+ Byte) | 10/10 | 10/10 |
| Schreiben mit Antwort | 10/10 | 10/10 |
| Schreiben ohne Antwort | 10/10 | 10/10 |
| 512 Byte mit Antwort schreiben | 10/10 | 10/10 |
| 200 Byte ohne Antwort schreiben | 10/10 | 10/10 |
| Descriptor schreiben | 10/10 | 10/10 |
| Auto-Resubscribe nach Reconnect | 10/10 | 10/10 |
| Disconnect beendet die Verbindung | 10/10 | 10/10 (ohne Aussage, siehe unten) |

- **Disconnect:** Ein BlueZ-Peripheral sendet erst wieder Advertising, wenn die Verbindung weg
  ist; daran misst die Prüfung. Windows brauchte dafür 3–20 s. Ein Windows-Peripheral sendet
  immer, die Prüfung sagt dort nichts aus; BlueZ trennt ohnehin ausdrücklich.
- **L:** Im ersten Lauf lief eine von 89 Verbindungen in den Timeout (A6 in `V2_BLOCKERS.md`),
  im Wiederholungslauf keine von 90. Gewertet ist der Wiederholungslauf.
- **Tag 2 (2026-11-12/13):** beide Richtungen wiederholt, alle zehn Prüfungen wieder 10/10, kein
  Verbindungsfehler in beiden Läufen. Damit ist der Sammellauf an zwei Tagen grün.
- **2026-11-15, W nach der Umstellung der WinRT-Handler auf Heap-Objekte** (Notifications,
  Verbindungsstatus, Scan): alle zehn Prüfungen 10/10, kein Absturz (Build mit `-Dcrash-dumps`).
- **2026-11-21/22, beide Richtungen mit dem Stand von PR #7** (Heap-Handler, A11-Fix, `630b82f`):
  W und L alle zehn Prüfungen 10/10, kein Verbindungs-Timeout. Damit ist der Sammellauf an einem
  dritten Tag grün, nach A6 der zweite weitere Lauf ohne Timeout.

## Pairing

`scripts/hardware_pairing.sh` steuert beide Rechner von einem aus, der zweite wird über ssh
bedient. Es beantwortet die Abfragen über `--answers` wie ein Mensch: Einen Code bestätigt es
nur, wenn beide Seiten denselben zeigen, und den Passkey der einen Seite tippt es auf der
anderen ein. Nach jeder Runde entfernt es den Bond auf beiden Seiten.

```bash
PEER_SSH="ssh user@linux-host" PEER_BIN=/home/user/ble-hardware-check \
LOCAL_BIN=zig-out/bin/ble-hardware-check.exe PERIPHERAL_ADDR=<addr> \
  scripts/hardware_pairing.sh local numeric 10              # dieser Rechner ist Central
  scripts/hardware_pairing.sh peer numeric 10 peripheral    # der andere ist Central
```

Stand 2026-11-11 (Tag 1). W = Windows als Central koppelt mit `--pair` und verbindet danach neu
(„bonded“ muss bleiben, protected lesbar sein). L = Linux als Central abonniert nur
(`--await-pair`), das Windows-Peripheral startet das Pairing; ohne Reconnect, weil der Linux-Kernel
den gekoppelten PC unter seiner Identitätsadresse sucht (B13 (3b); die Teile in Zig-BLE sind
behoben).

| Methode | W | L |
| :--- | :---: | :---: |
| Numeric Comparison | 10/10 | 8/10 |
| Just Works | 10/10 | 10/10 |
| Passkey, Central tippt | 10/10 | 8/10 |
| Passkey, Peripheral tippt | 10/10 | 10/10 |

- **L, 8/10:** In den vier Runden endete die Verbindung beim Start der Verschlüsselung mit einem
  Timeout (A9 in `V2_BLOCKERS.md`).
- **Tag 2 (2026-11-13):** W bei allen vier Methoden 10/10. L: Just Works 10/10, Passkey (Central
  tippt) 10/10, Numeric Comparison 9/10, Passkey (Peripheral tippt) 9/10; die zwei Fehlrunden
  endeten nach der Bestätigung auf beiden Seiten mit `PairingFailed` (A9). Pairing ist für W an
  zwei Tagen grün, für L nicht.
- **2026-11-14, mit Neuversuch:** A9 ist ein Verbindungsverlust zwischen den Controllern beim Start
  der Verschlüsselung (MIC Failure im Intel-Adapter). Zig-BLE meldet ihn als `PairingInterrupted`
  und koppelt über eine neue Verbindung noch einmal; `--await-pair` verbindet sich dafür neu, das
  Skript zeigt das als `retries=`. L: alle vier Methoden 10/10, drei Runden mit einem Neuversuch.
  W: alle vier Methoden 10/10 ohne Neuversuch. Der zweite Tag mit diesem Stand steht aus.
- **2026-11-14, Wiederholung mit dem Scan-Fix (B13):** L 39/40: Numeric Comparison, Just Works und
  Passkey (Central tippt) je 10/10 mit je einem Neuversuch, Passkey (Peripheral tippt) 9/10; die
  Fehlrunde scheiterte schon an `StartNotify` vor dem Pairing (A10). Gleicher Tag, zählt nicht als
  zweiter Tag.
- **2026-11-16, zweiter Tag:** L und W bei allen vier Methoden 10/10 (80/80), kein Neuversuch nach
  einem Verbindungsverlust, kein `StartNotify`-Fehler (A10). Pairing ist damit für W und L an zwei
  Tagen grün.
- **2026-11-16, zweiter Lauf (für A10):** L bei allen Methoden 10/10, W 39/40. Wieder kein
  `StartNotify`-Fehler, A10 ist damit erledigt. Die W-Fehlrunde (Passkey, Peripheral tippt, Runde 9)
  scheiterte vor dem Pairing an der Discovery mit `PoolExhausted` (A11).
- **2026-11-16, W mit Diagnose (A11):** 37/40 (Numeric 10/10, die anderen drei je 9/10). Alle drei
  Fehlrunden sind A11: Der Windows-Cache lieferte 13 veraltete Kopien des Testdienstes.
- **2026-11-16, W mit A11-Fix:** erster Lauf 39/40 (Numeric, Just Works, Passkey/Central je 10/10,
  Passkey/Peripheral 9/10: die erste Discovery fand den Testdienst nicht, inzwischen abgefangen).
  Der zweite Lauf ist ungültig: Der USB-Adapter des Linux-Rechners meldete sich mitten im Lauf neu
  an und hieß danach `hci1`. Der Befehl in `PERIPHERAL_FORGET` und `forget_test_bond.sh` nennen
  `hci0` fest, und `ble-hardware-check` öffnete als Central fest Adapter 0; es nimmt jetzt den
  ersten Adapter, den BlueZ meldet. Nach so einem Neustart des Adapters beide Skripte prüfen.
- **2026-11-17, W mit A11-Fix, Nachweis:** zwei Läufe hintereinander, alle vier Methoden in beiden
  10/10 (80/80), kein Neuversuch nach einem Verbindungsverlust. A11 ist damit erledigt. Der Befehl in
  `PERIPHERAL_FORGET` entfernte den Bond dabei auf jedem Adapter, der den Peer kennt, nicht fest
  unter `hci0`.
- Bleibt nach einer Runde ein Bond auf nur einer Seite stehen, scheitern alle folgenden Runden
  schon am Verbindungsaufbau (B3). Das Skript wiederholt `PERIPHERAL_FORGET` deshalb und meldet,
  wenn es scheitert.
- **W:** In einem früheren Lauf meldete Windows nach fünf Runden für einige Minuten
  `OperationAlreadyInProgress` (A8); gewertet ist der Wiederholungslauf.
- `--unpair` entfernte den Bond früher über eine Verbindung, die zum gekoppelten PC unter Linux
  nicht mehr zustande kommt; dafür gab es `CENTRAL_FORGET`. Seit 2026-11-22 nimmt `--unpair`
  `UnifiedAdapter.removeBond` und verbindet nicht mehr.

### Erneutes Koppeln, nachdem eine Seite vergessen hat (B3)

Mit `STALE=central|peripheral` entfernt das Skript nach jeder Runde nur den Bond der anderen Seite,
jede weitere Runde beginnt also mit einem Bond, den die Gegenstelle nicht mehr hat. `STALE_FORGET`
ist der Befehl, mit dem die Seite mit dem alten Bond ihn vor der Runde entfernt, so wie es eine
Anwendung tut (`ble-hardware-check <addr der Gegenstelle> --unpair`, also `removeBond`).

```bash
STALE=peripheral STALE_FORGET="/home/user/ble-hardware-check <addr des PCs> --unpair" \
  scripts/hardware_pairing.sh local numeric 10
```

- **Ohne Eingriff** (2026-11-22, je von Hand, `btmon` auf dem Host):
  - Windows-Central behält: Windows startet beim Verbinden die Verschlüsselung mit dem alten
    Schlüssel, BlueZ antwortet `LTK Request Neg Reply`, Windows trennt und versucht es immer
    wieder; Zig-BLE meldet `ConnectionFailed`.
  - Linux-Peripheral behält: BlueZ schickt einen Security Request, Windows koppelt darauf selbst,
    ohne die Anwendung zu fragen, und bestätigt nie; nach 30 s trennt BlueZ. `--pair` kollidiert
    damit: 1/10 (`STALE=peripheral` ohne `STALE_FORGET`).
  - Linux-Central behält: `Device1.Connect` scheitert (`ConnectionFailed`).
  - Windows-Peripheral behält: Windows schickt einen Security Request, Linux koppelt neu, Windows
    gibt das Pairing an seinen eigenen Dialog und bestätigt nie; nach 30 s ist die Verbindung weg.
    `pairSubscribers` hält den alten Bond für gültig und meldet sofort „paired“.
- **Mit `removeBond` auf der Seite, die den Bond behalten hat** (2026-11-22/23, Numeric
  Comparison): W-Central, Peripheral behält 10/10; W-Central behält 10/10; L-Central behält 10/10;
  L-Central, Windows-Peripheral behält 10/10. Kein Neuversuch nach einem Verbindungsverlust,
  `removeBond` gelang vor jeder Runde ohne Verbindung.

## Langzeittest

`scripts/hardware_soak.sh` startet auf einem Rechner das Peripheral und auf dem anderen
`--soak <minuten>`: scannen, verbinden, lesen, abonnieren, 10 s halten, trennen, immer wieder.
Alle 10 Minuten hält es Speicher und Handles (Windows) oder fds (Linux) beider Prozesse fest.

```bash
PEER_SSH="ssh user@linux-host" PEER_BIN=/home/user/ble-hardware-check \
LOCAL_BIN=zig-out/bin/ble-hardware-check.exe PERIPHERAL_ADDR=<addr> \
  scripts/hardware_soak.sh local 480 zig-out/soak    # dieser Rechner ist Central
  scripts/hardware_soak.sh peer 480 zig-out/soak     # der andere ist Central (PERIPHERAL_ADDR=auto)
```

Logs: `central.log`, `peripheral.log`, `monitor.log` im angegebenen Ordner.

- **2026-11-16/17, B5 Linux-Central, 8 h:** 1841 Zyklen, 5 Fehlrunden, alle im nächsten Zyklus
  erholt; Speicher und fds flach. Ein Soak von 3 h mit `btmon` auf dem Host (703 Zyklen, 2
  Fehlrunden) zeigt beide Male `Connection Timeout (0x08)` vom Controller, also einen Funkabbruch.
  Der Soak schreibt pro Zyklus Zeit und Adresse (`<unix-zeit> connect <addr>`), damit eine
  Fehlrunde im Mitschnitt zu finden ist, und nach dem Abonnieren die Dauer bis zur nutzbaren
  Verbindung (`ready in <ms> ms: connect …, discover …, read and subscribe …`). Aus einer Nacht
  ergibt sich so die Verteilung der Verbindungszeiten, ohne eigenen Messlauf.
- **2026-11-17/18, B5 Windows-Central, 8 h, Commit `cd6efff`:** 1167 Zyklen, 0 Fehlrunden, 25920
  Notifications, 0 Events verworfen. Handles 238 bis 247 flach, Working Set ab etwa 4 h konstant
  um 19,6 MB; das Linux-Peripheral blieb bei 7,1 bis 7,2 MB und 4 fds.
- **2026-11-18, erste Messung `ready`** (je 3 min): Windows-Central bis zur nutzbaren Verbindung
  3,3 bis 6,8 s (`connect` mit voller Discovery 2,9 bis 6,3 s, gefilterte Discovery 2 bis 3 ms,
  Lesen und Abonnieren etwa 0,4 s); Linux-Central 2,3 bis 3,2 s (`connect` 1,3 bis 1,9 s,
  Discovery 1 ms, Lesen und Abonnieren etwa 1 s).

## Außerhalb der v2-Bedingung

Entschieden (E1–E3 in `V2_BLOCKERS.md`): Raw HCI und UART (nie gegen einen echten Controller
gelaufen, keine ACL-Credits) sowie EATT (an kein Backend angebunden) bleiben in v2 als
experimentell gekennzeichnet. macOS gehört nicht zu v2.
