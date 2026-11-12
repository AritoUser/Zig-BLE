#!/bin/sh
# Removes the patched btusb installed by install.sh and loads the stock module again.
set -eu

kver=$(uname -r)
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

rm -f "/lib/modules/$kver/updates/btusb.ko"
depmod -a "$kver"
modprobe -r btusb
modprobe btusb
if [ -e /sys/module/btusb/parameters/hold_unknown_acl_ms ]; then
    echo "The patched module is still loaded." >&2
    exit 1
fi
echo "Stock btusb loaded."
