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
| 4 | Auto-Resubscribe | `… <addr> --service <uuid> --resubscribe` | CCCD der Gegenstelle nach dem Reconnect wieder `0100`, Notifications kommen | ✅ | ⚠️ |
| 5 | Schreiben mit Antwort | `… <addr> --write 5a1e0002-… 0102` | `After: 0102 (matches)` | ✅ | ✅ |
| 6 | Schreiben ohne Antwort | `… --write 5a1e0002-… 0304 --no-response` | `After: 0304 (matches)` | ✅ | ✅ |
| 7 | Pairing | `… <addr> --service <uuid> --pair` | Bond-Status `bonded`, auch nach dem Reconnect; protected liefert `paired` | ✅ | |
| 8 | Bond entfernen | `… <addr> --service <uuid> --unpair` | beim nächsten Verbinden `not_bonded`, Windows führt das Gerät nicht mehr | ✅ | |
| 9 | Peripheral: Client verbindet sich | `… --peripheral` | echo les- und schreibbar, counter zählt | ⚠️ | ✅ |
| 10 | Peripheral: Pairing | `… --peripheral --secure` | protected fordert Pairing an und liefert `paired` | | ✅ |
| 11 | Langzeit: Scannen, Verbinden, Slots | `… <addr> --soak 240` | 0 Fehler, Handles steigen nicht (nur Windows zeigt sie) | | |
| 12 | Neustart von `bluetoothd` | während 11: `sudo systemctl restart bluetooth` | `Recovered.`, danach laufen die Zyklen weiter | – | |

Anmerkungen:

- **2, 5, 6 unter Windows:** gegen das Linux-Peripheral. Der Verbindungsaufbau von Windows zum
  Linux-Peripheral gelang nur in etwa der Hälfte der Versuche: Die Funkverbindung steht, aber
  Windows' GATT-Discovery antwortet nicht innerhalb von 30 s. Gegen Fitnessband und Tracker trat
  das nicht auf.
- **4 unter Linux:** Das Backend richtet das Abo nach dem Reconnect wieder ein (CCCD der
  Gegenstelle `0100`). Notifications kamen danach nicht an, weil das Windows-Peripheral sie nicht
  sendet (siehe 9). Gegen eine verlässliche Gegenstelle noch einmal prüfen.
- **9 unter Windows:** Lesen und Schreiben gehen. Notifications an den BlueZ-Client blieben in
  den meisten Läufen hängen (`NotifyValueAsync` ohne Abschluss nach 5 s), danach brach die
  Verbindung ab, auch mit genau einem verbundenen Abonnenten. In einem von etwa fünf Läufen kamen
  alle Notifications an.
- **7, 8, 10:** Windows koppelte zweimal mit dem Linux-Peripheral, per Numeric Comparison; beide
  Seiten zeigten denselben Code, der Linux-Agent bestätigte. Passkey und Just Works sind noch
  offen, ebenso Linux als koppelnder Central (7 L).
- **8 unter Windows:** Eine LE-Kopplung mit einem Dual-Mode-Gerät legt auch eine Classic-Kopplung
  an. `unpair` entfernt jetzt beide (vorher blieb die Classic-Hälfte, und Windows versuchte weiter,
  das Gerät über Classic zu erreichen). Die Gegenstelle behält ihre Schlüssel; unter BlueZ
  entfernt `Adapter1.RemoveDevice` sie.
- **12** braucht Root auf dem Rechner mit `bluetoothd`.

## Außerhalb der v2-Bedingung

Noch zu entscheiden: Raw HCI und UART (nie gegen einen echten Controller gelaufen, keine
ACL-Credits) sowie EATT (an kein Backend angebunden) bleiben als experimentell gekennzeichnet.
