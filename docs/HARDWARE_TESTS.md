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

## Tests

Spalten: **W** Windows, **L** Linux. `✅` bestanden, `⚠️` nur teilweise, Stand 2026-11-10.
Linux: BlueZ 5.82, Realtek-USB-Adapter; Gegenstelle der jeweils andere Rechner.

| # | Test | Befehl | Bestanden, wenn | W | L |
| :--- | :--- | :--- | :--- | :---: | :---: |
| 1 | Scan | `ble-hardware-check` | Geräte mit Name, Herstellerdaten und UUIDs erscheinen | ✅ | ✅ |
| 2 | Verbinden, Lesen, Notifications, MTU, 30 s halten | `… <addr> --service <uuid>` | `connected = true` nach 30 s, Notifications kommen | ✅ | ✅ |
| 3 | Service-Filter | `… <addr> --service <uuid>` | nur dieser Service wird gelistet und gescannt | ✅ | ✅ |
| 4 | Auto-Resubscribe | `… <addr> --service <uuid> --resubscribe` | CCCD der Gegenstelle nach dem Reconnect wieder `0100`, Notifications kommen | ✅ | ✅ |
| 5 | Schreiben mit Antwort | `… <addr> --write 5a1e0002-… 0102` | `After: 0102 (matches)` | ✅ | ✅ |
| 6 | Schreiben ohne Antwort | `… --write 5a1e0002-… 0304 --no-response` | `After: 0304 (matches)` | ✅ | ✅ |
| 7 | Pairing | `… <addr> --service <uuid> --pair` | Bond-Status `bonded`, auch nach dem Reconnect; protected liefert `paired` | ✅ | |
| 8 | Bond entfernen | `… <addr> --service <uuid> --unpair` | beim nächsten Verbinden `not_bonded`, Windows führt das Gerät nicht mehr | ✅ | |
| 9 | Peripheral: Client verbindet sich | `… --peripheral` | echo les- und schreibbar, counter zählt | ✅ | ✅ |
| 10 | Peripheral: Pairing | `… --peripheral --secure` | Windows koppelt den Abonnenten selbst (gleicher Code auf beiden Seiten), danach liefert protected `paired` | ✅ | ✅ |
| 11 | Langzeit: Scannen, Verbinden, Slots | `… <addr> --soak 240` | 0 Fehler, Handles steigen nicht (nur Windows zeigt sie) | | |
| 12 | Neustart von `bluetoothd` | während 11: `sudo systemctl restart bluetooth` | `Recovered.`, danach laufen die Zyklen weiter | – | |

Anmerkungen:

- **2, 5, 6 unter Windows:** gegen das Linux-Peripheral. Bis 2026-11-11 gelang der Verbindungsaufbau nur in etwa jedem zweiten Versuch; Ursache war der Linux-Kernel auf dem Testserver (A1). Mit dem `btusb`-Patch 20/20.
- **4 unter Linux:** 10/10 Runden gegen das Windows-Peripheral, nach jedem Reconnect CCCD wieder `0100` und 14–15 Notifications (2026-11-11, mit dem `btusb`-Patch).
- **4 unter Windows:** Bis 2026-11-11 trennte Windows vor dem Reconnect nicht wirklich (A4). Seit dem Fix wartet die Prüfung, bis das Peripheral wieder Advertising sendet; 10/10 im Sammellauf.
- **9 unter Windows:** Lesen, Schreiben und Notifications gehen, 10/10 Runden mit 28–29 Notifications in 30 s. Die früheren Hänger kamen vom Linux-Kernel, nicht von Windows (siehe A1/A2 in `V2_BLOCKERS.md`).
- **7, 8, 10:** Windows koppelte zweimal mit dem Linux-Peripheral, per Numeric Comparison; beide
  Seiten zeigten denselben Code, der Linux-Agent bestätigte. Passkey und Just Works sind noch
  offen, ebenso Linux als koppelnder Central (7 L).
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
- Die Kriterien verlangen einen zweiten vollständig grünen Lauf an einem anderen Tag.

Die Pairing-Prüfungen steuert `scripts/hardware_pairing.sh` von einem der beiden Rechner aus;
der zweite wird über ssh bedient. Die Abfragen beantwortet das Skript über `--answers`.

## Außerhalb der v2-Bedingung

Noch zu entscheiden: Raw HCI und UART (nie gegen einen echten Controller gelaufen, keine
ACL-Credits) sowie EATT (an kein Backend angebunden) bleiben als experimentell gekennzeichnet.
