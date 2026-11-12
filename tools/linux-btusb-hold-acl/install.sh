#!/bin/sh
# Builds and installs btusb with the hold-unknown-ACL patch for the running kernel.
# Run as root on the Linux machine whose USB Bluetooth adapter shows the problem.
# Undo with ./uninstall.sh. A kernel update brings back the stock module.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
kver=$(uname -r)
# Upstream tag from the kernel release, e.g. 7.0.14-8-pve -> v7.0.14
tag="v$(echo "$kver" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
build=/lib/modules/$kver/build

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ -d "$build" ] || { echo "Kernel headers missing: $build (Proxmox: apt install proxmox-headers-$kver)" >&2; exit 1; }
for tool in make gcc patch curl; do
    command -v "$tool" >/dev/null || { echo "Missing $tool (apt install build-essential patch curl)" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/bluetooth"
echo "Fetching btusb for $tag ..."
for f in btusb.c btintel.h btbcm.h btrtl.h btmtk.h; do
    curl -fsSL -o "$work/$f" "$base/$f?h=$tag"
done

echo "Applying patch ..."
patch --dry-run -s -d "$work" -p3 < "$here/btusb-hold-unknown-acl.patch" >/dev/null ||
    { echo "Patch does not apply to $tag; nothing was changed." >&2; exit 1; }
patch -s -d "$work" -p3 < "$here/btusb-hold-unknown-acl.patch"

echo "Building ..."
echo "obj-m += btusb.o" > "$work/Makefile"
make -s -C "$build" M="$work" modules

install -D -m 644 "$work/btusb.ko" "/lib/modules/$kver/updates/btusb.ko"
depmod -a "$kver"

echo "Reloading btusb (Bluetooth restarts) ..."
modprobe -r btusb
modprobe btusb
echo "hold_unknown_acl_ms = $(cat /sys/module/btusb/parameters/hold_unknown_acl_ms)"
