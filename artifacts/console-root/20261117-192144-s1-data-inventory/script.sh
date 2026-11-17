#!/bin/sh
# S1 storage inventory. Read-only: mounts data with ro,noload (no journal
# replay), reports usage, then unmounts. Run on the pinned RAM console.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
grep -q '^ID=mibox-custom$' /etc/os-release
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
test "$(cat /sys/class/block/data/dev)" = 179:11
test "$(cat /sys/class/block/data/size)" = 5168640
device=/dev/mibox-data
if [ ! -e "$device" ]; then mknod -m 600 "$device" b 179 11; fi
test ! -L "$device" && test -b "$device"
test "$(stat -c '%t:%T' "$device")" = b3:b
if awk '$3 == "179:11"' /proc/self/mountinfo | grep -q .; then
    echo 'Data is already mounted; refusing' >&2
    exit 1
fi
mnt=/mnt/s1-data-ro
mkdir -p "$mnt"
test ! -L "$mnt"
blkid "$device"
mount -t ext4 -o ro,noload,nosuid,nodev,noexec "$device" "$mnt"
trap 'umount "$mnt"' EXIT
echo '== mount'; awk '$3 == "179:11"' /proc/self/mountinfo
echo '== df'; df -k "$mnt"; df -i "$mnt" 2>/dev/null || true
echo '== top level (KiB)'; du -xsk "$mnt"/* "$mnt"/.[!.]* 2>/dev/null | sort -rn
for d in app app-asec app-lib app-private dalvik-cache data media mibox-console \
         local system misc user property lost+found; do
    if [ -d "$mnt/$d" ]; then
        echo "== $d children (KiB, top 15)"
        du -xsk "$mnt/$d"/* "$mnt/$d"/.[!.]* 2>/dev/null | sort -rn | head -15
    fi
done
if [ -d "$mnt/mibox-console/rootfs" ]; then
    echo '== alpine rootfs (KiB, top 15)'
    du -xsk "$mnt/mibox-console/rootfs"/* 2>/dev/null | sort -rn | head -15
    echo '== alpine files'; find "$mnt/mibox-console" -xdev | wc -l
fi
echo '== largest files (top 25, KiB)'
find "$mnt" -xdev -type f -size +4096k -exec du -k {} + 2>/dev/null | sort -rn | head -25
echo S1_INVENTORY_DONE
