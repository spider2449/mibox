#!/bin/sh
# A3a: read-only SHA256 of the boot and boot1 partitions (no writes).
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
for name in boot boot1; do
    dev=$(cat /sys/class/block/$name/dev)
    size=$(cat /sys/class/block/$name/size)
    test "$size" = 16384
    node=/dev/mibox-ro-$name
    rm -f "$node"
    mknod -m 400 "$node" b "${dev%%:*}" "${dev##*:}"
    test ! -L "$node" ; test -b "$node"
    echo "$name dev=$dev sectors=$size sha256=$(dd if="$node" bs=65536 2>/dev/null | sha256sum | cut -d' ' -f1)"
    rm -f "$node"
done
