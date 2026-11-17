#!/bin/sh
# A2 restore rehearsal (WSL, no device). Extracts the S2 archives into a fresh
# directory on the Linux filesystem inside a user namespace (uid 0 mapped to
# the caller, so owner 0:0 is reproduced), then regenerates the device listing
# and SHA256 list in the same format and compares them with the S2 evidence.
# Device nodes cannot be created in a user namespace; they are reported, not
# failed. Usage: scripts/rehearse-tree-restore.sh [BACKUP_DIR] [S2_EVIDENCE_DIR]
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
backup=${1:-$repo/phone-tools/backup/2026-11-17-s2}
s2=${2:-$repo/artifacts/storage/s2-20261117}
ev=$repo/artifacts/storage/a2-restore-rehearsal-$(date +%Y%m%d-%H%M%S)
mkdir -p "$ev"
work=$(mktemp -d /tmp/mibox-restore-XXXXXX)
trap 'unshare -r rm -rf "$work"' EXIT
case "$(stat -f -c %T "$work")" in ext2/ext3|ext4|tmpfs|btrfs|xfs) ;; *) echo 'work dir must be on a Linux filesystem' >&2; exit 1 ;; esac
for a in mibox-console.tar local-tmp.tar; do sha256sum "$backup/$a"; done > "$ev/archive-sha256.txt"
unshare -r sh -eu -c '
cd "$1"
for a in mibox-console.tar local-tmp.tar; do
    tar --numeric-owner --same-permissions --same-owner -xf "$2/$a" 2>>"$3/extract-errors.txt" || true
done
for d in mibox-console local/tmp; do
    find "$d" -xdev | sort | while IFS= read -r p; do stat -c "%F|%a|%u:%g|%s|%n" "$p"; done
done > "$3/restored-listing.txt"
find mibox-console local/tmp -xdev -type f | sort | while IFS= read -r p; do sha256sum "$p"; done > "$3/restored-sha256.txt"
' sh "$work" "$backup" "$ev"
# Directory sizes depend on the filesystem's allocation history: compare without them.
# local/tmp holds Android owners (1000/2000) that a one-uid namespace cannot
# create; its owners were compared against the tar in S2, not here.
strip_dir_size() { awk -F'|' 'BEGIN{OFS="|"} $1=="directory"{$4="-"} $5 ~ /^local\/tmp/{$3="-"} {print}' "$1"; }
strip_dir_size "$s2/device-listing.txt" > "$ev/expected.cmp"
strip_dir_size "$ev/restored-listing.txt" > "$ev/restored.cmp"
diff "$ev/expected.cmp" "$ev/restored.cmp" > "$ev/listing-diff.txt" || true
diff "$s2/device-sha256.txt" "$ev/restored-sha256.txt" > "$ev/sha256-diff.txt" || true
rm -f "$ev/expected.cmp" "$ev/restored.cmp"
unexpected=$(grep '^[<>]' "$ev/listing-diff.txt" | grep -v \
    -e '^< character special file|[0-7]*|0:0|0|mibox-console/rootfs/tmp/mibox-audio-test/dev/' \
    -e '^< socket|' | wc -l)
echo "listing diff lines: $(grep -c '^[<>]' "$ev/listing-diff.txt" || true), unexpected: $unexpected"
echo "sha256 diff lines: $(grep -c '^[<>]' "$ev/sha256-diff.txt" || true)"
echo "extract errors: $(wc -l < "$ev/extract-errors.txt" 2>/dev/null || echo 0)"
if [ "$unexpected" -eq 0 ] && [ ! -s "$ev/sha256-diff.txt" ]; then
    echo A2_RESTORE_REHEARSAL_PASS | tee "$ev/status.txt"
else
    echo A2_RESTORE_REHEARSAL_FAIL | tee "$ev/status.txt"; exit 1
fi
echo "EVIDENCE $ev"
