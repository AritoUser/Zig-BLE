#!/bin/sh
# Runs the BlueZ backend end-to-end test on a private D-Bus bus (no root, no bluetoothd).
#
#   zig build bluez-fake-e2e
#   scripts/run_bluez_fake_e2e.sh zig-out/bin/ble-bluez-fake-e2e
set -eu

binary=${1:-zig-out/bin/ble-bluez-fake-e2e}
socket=$(mktemp -u "${TMPDIR:-/tmp}/zig-ble-bus.XXXXXX")

dbus-daemon --session --nofork --nopidfile --address="unix:path=$socket" &
bus_pid=$!
trap 'kill "$bus_pid" 2>/dev/null || true; rm -f "$socket"' EXIT INT TERM

tries=0
while [ ! -S "$socket" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
        echo "dbus-daemon did not start" >&2
        exit 1
    fi
    sleep 0.1
done

DBUS_SYSTEM_BUS_ADDRESS="unix:path=$socket" timeout 60 "$binary"
