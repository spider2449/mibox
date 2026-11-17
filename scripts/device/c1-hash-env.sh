#!/bin/sh
# C1: read-only SHA256 of the env partition (no writes).
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
dev=$(cat /sys/class/block/env/dev)
size=$(cat /sys/class/block/env/size)
test "$size" = 8192
node=/dev/mibox-ro-env
rm -f "$node"
mknod -m 400 "$node" b "${dev%%:*}" "${dev##*:}"
test ! -L "$node" ; test -b "$node"
echo "env dev=$dev sectors=$size sha256=$(dd if="$node" bs=65536 2>/dev/null | sha256sum | cut -d' ' -f1)"
echo "bootsystem/storeboot: $(dd if="$node" bs=32768 count=1 2>/dev/null | tr '\0' '\n' | grep -e '^bootsystem=' -e '^storeboot=' | tr '\n' ' ')"
rm -f "$node"
