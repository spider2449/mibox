#!/bin/sh
# S2 backup. Read-only on device: mounts data ro,noload and writes to stdout.
#   s2-tree-backup.sh list         -> per-file "type mode uid:gid size path" listing on stdout
#   s2-tree-backup.sh hashes       -> sha256sum of every regular file
#   s2-tree-backup.sh tar <subdir>  -> tar of <subdir> (relative to data root) on stdout
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
grep -q '^ID=mibox-custom$' /etc/os-release
test "$(cat /sys/class/block/data/dev)" = 179:11
test "$(cat /sys/class/block/data/size)" = 5168640
device=/dev/mibox-data
if [ ! -e "$device" ]; then mknod -m 600 "$device" b 179 11; fi
test ! -L "$device" ; test -b "$device"
test "$(stat -c '%t:%T' "$device")" = b3:b
if awk '$3 == "179:11"' /proc/self/mountinfo | grep -q .; then
    echo 'Data is already mounted; refusing' >&2
    exit 1
fi
mnt=/mnt/s2-data-ro
mkdir -p "$mnt"
mount -t ext4 -o ro,noload,nosuid,nodev,noexec "$device" "$mnt"
trap 'cd /; umount "$mnt"' EXIT
cd "$mnt"
case "$1" in
list)
    for d in mibox-console local/tmp; do
        find "$d" -xdev | sort | while IFS= read -r p; do
            stat -c '%F|%a|%u:%g|%s|%n' "$p"
        done
    done ;;
hashes)
    find mibox-console local/tmp -xdev -type f | sort | while IFS= read -r p; do
        sha256sum "$p"
    done ;;
tar)
    case "$2" in mibox-console|local/tmp) ;; *) echo 'subdir not allowed' >&2; exit 1 ;; esac
    tar -cf - "$2" ;;
*) echo usage >&2; exit 1 ;;
esac
