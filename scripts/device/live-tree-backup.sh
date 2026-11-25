#!/bin/sh
# Live backup of the persistent Alpine tree and local/tmp from the running
# Slim system (SSH into Alpine), for the power-loss test (plan C5a). Read-only
# on data: the shared file list is kept in /run (tmpfs). -xdev stops at the
# tree's pseudo-filesystem mounts (dev, proc, sys, run, cgroup); Docker's
# vfs layer store and tmp are skipped (images are re-pullable). Files that
# change while the backup runs (logs, Docker state) are reported by the
# verifier, not hidden.
#   live-tree-backup.sh prep    -> build /run/mibox-backup.list, print its count
#   live-tree-backup.sh list    -> "type|mode|uid:gid|size|path" for each entry
#   live-tree-backup.sh hashes  -> sha256sum of each regular file
#   live-tree-backup.sh tar     -> tar of the listed entries on stdout
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
test "$(id -u)" = 0
data=/proc/1/root/mnt/mibox-data
list=/run/mibox-backup.list
test "$(stat -c %d "$data")" = "$(stat -c %d "$data/mibox-console/rootfs")"
cd "$data"
case "${1:-}" in
prep)
    find mibox-console local/tmp -xdev \
        \( -path mibox-console/rootfs/var/lib/docker/vfs -o -path mibox-console/rootfs/var/lib/docker/tmp \) -prune \
        -o -print | sort > "$list"
    wc -l < "$list" ;;
list)
    while IFS= read -r p; do stat -c '%F|%a|%u:%g|%s|%n' "$p" 2>/dev/null || true; done < "$list" ;;
hashes)
    while IFS= read -r p; do [ -f "$p" ] && [ ! -L "$p" ] && sha256sum "$p"; done < "$list" || true ;;
tar)
    tar -cf - --no-recursion -T "$list" ;;
*) echo 'usage: live-tree-backup.sh prep|list|hashes|tar' >&2; exit 2 ;;
esac
