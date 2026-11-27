#!/bin/sh
# S7: remove the remaining Android files from data (owner-approved 2026-11-27,
# Android no longer kept). Runs in the running Slim system (SSH into Alpine);
# data stays mounted and is reached through PID1's root. Fixed list; keeps
# mibox-console (the Alpine tree) and lost+found.
#   s7-reclaim-android-rest.sh hashes -> sha256sum of every regular file in the list
#   s7-reclaim-android-rest.sh tar    -> tar of the list on stdout
#   s7-reclaim-android-rest.sh delete DELETE-ANDROID-REST
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
test "$(cat /sys/class/block/data/dev)" = 179:11
data=/proc/1/root/mnt/mibox-data
test "$(stat -c %d "$data")" = "$(stat -c %d "$data/mibox-console/rootfs")"
test -d "$data/mibox-console/rootfs/etc"
cd "$data"
list='.layout_version app app-asec app-lib app-private backup bugreports
dalvik-cache data dontpanic drm duokancache local log media mediadrm misc
property resource-cache security ssh system tmp user'
present() { for p in $list; do if [ -e "$p" ] || [ -L "$p" ]; then echo "$p"; fi; done; }
case "${1:-}" in
hashes)
    present | while IFS= read -r p; do find "$p" -xdev -type f; done | sort | while IFS= read -r f; do sha256sum "$f"; done ;;
tar)
    tar -cf - $(present) ;;
delete)
    test "${2:-}" = DELETE-ANDROID-REST
    echo '== before'; df -k .
    for p in $(present); do rm -rf -- "./$p" && echo "deleted $p"; done
    sync
    echo '== after'; df -k .
    echo '== top level'; ls -la
    echo '== kernel'; dmesg | grep -i -e ext4 -e 'I/O error' | tail -5
    echo S7_DONE ;;
*) echo 'usage: s7-reclaim-android-rest.sh hashes|tar|delete DELETE-ANDROID-REST' >&2; exit 2 ;;
esac
