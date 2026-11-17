#!/bin/sh
# S3: delete owner-approved (2026-11-17) Android payload on data. Fixed list.
# Keeps system, misc (ADB keys), property, ssh, local/tmp, mibox-console and
# data/com.android.providers.settings (adb_enabled) for Android's ADB path.
# Usage: s3-reclaim-android.sh DELETE-ANDROID-PAYLOAD
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "${1:-}" = DELETE-ANDROID-PAYLOAD
test "$(id -u)" = 0
grep -q '^ID=mibox-custom$' /etc/os-release
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
test "$(cat /sys/class/block/data/dev)" = 179:11
test "$(cat /sys/class/block/data/size)" = 5168640
test "$(cat /sys/class/block/data/ro)" = 0
device=/dev/mibox-data
if [ ! -e "$device" ]; then mknod -m 600 "$device" b 179 11; fi
test ! -L "$device" ; test -b "$device"
test "$(stat -c '%t:%T' "$device")" = b3:b
if awk '$3 == "179:11"' /proc/self/mountinfo | grep -q .; then
    echo 'Data is already mounted; refusing' >&2
    exit 1
fi
blkid "$device" | grep -q 'UUID="57f8f4bc-abf4-655f-bf67-946fc0f9f25b" TYPE="ext4"'
mnt=/mnt/s3-data
mkdir -p "$mnt"
mount -t ext4 -o nosuid,nodev,noexec "$device" "$mnt"
trap 'cd /; sync; umount "$mnt" && echo UNMOUNTED' EXIT
cd "$mnt"
test -d mibox-console/rootfs ; test -d system ; test -d misc/adb ; test -d property
echo '== before'; df -k "$mnt"
dirs='app app-lib dalvik-cache media log anr tombstones dontpanic diagnosis duokancache'
files='spdif.mkv autovideo.mov test.mkv'
for p in $dirs; do
    if [ -e "$p" ]; then test -d "$p" ; test ! -L "$p"; fi
done
for p in $files; do
    if [ -e "$p" ]; then test -f "$p" ; test ! -L "$p"; fi
done
test -d data ; test ! -L data
for p in $dirs $files; do
    if [ -e "$p" ]; then rm -rf -- "./$p" && echo "deleted $p"; else echo "absent $p"; fi
done
# Android recreates empty top-level dirs it needs; recreate none here.
for p in data/* data/.[!.]*; do
    [ -e "$p" ] || continue
    case "$p" in data/com.android.providers.settings) echo "kept $p"; continue ;; esac
    rm -rf -- "./$p"
done
echo 'deleted data/* except com.android.providers.settings'
sync
echo '== after'; df -k "$mnt"
echo '== top level (KiB)'; du -xsk ./* ./.[!.]* 2>/dev/null | sort -rn
echo '== kernel'; dmesg | grep -i -e ext4 -e mmcblk0p11 -e 'I/O error' | tail -10
echo S3_DONE
