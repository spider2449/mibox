set -eu
# S8 preparation: read-only. No command here writes a partition.
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-s8-boot-dryrun | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
IMG=614861f672f6ef24aa1e1a803cb6ec4ddcecb173683a978ed06cbc837af5ef24
BOOT=ff4fa440044709b92652afea0306286534c9da2f57e41308d67459b97e800a56
TOOL=ee69569fb0360fd382c8f85588ec0bcc8bad8e7a7c2624c95a5dcac204b92719
SRC=target/mibox-boot-candidate-slim-kernel-dev13/boot1-custom.NOT_READY.img
BIN=target/armv7-unknown-linux-musleabihf/release/mibox-partwrite
echo "== local inputs"; sha256sum $BIN $SRC phone-tools/backup/2026-11-13/boot.img
test "$(sha256sum $SRC | cut -d' ' -f1)" = $IMG
test "$(sha256sum $BIN | cut -d' ' -f1)" = $TOOL
test "$(sha256sum phone-tools/backup/2026-11-13/boot.img | cut -d' ' -f1)" = $BOOT
echo "== device"; ssh_ 'date -u; cat /proc/sys/kernel/random/boot_id; grep ^ID= /etc/os-release; for n in boot boot1 recovery env; do echo "$n $(cat /sys/class/block/$n/dev) ro=$(cat /sys/class/block/$n/ro)"; done'
echo "== partition hashes (read-only)"; ssh_ 'sync; echo 3 > /proc/sys/vm/drop_caches; chroot /proc/1/root /bin/sh -s' < scripts/device/a3a-hash-boot-partitions.sh
ssh_ 'cat > /proc/1/root/tmp/mibox-partwrite && chmod 700 /proc/1/root/tmp/mibox-partwrite' < $BIN
ssh_ 'cat > /proc/1/root/tmp/slim.img' < $SRC
up=$(ssh_ 'cd /proc/1/root/tmp && sha256sum mibox-partwrite slim.img'); echo "$up"
echo "$up" | grep -q "$TOOL  mibox-partwrite"; echo "$up" | grep -q "$IMG  slim.img"
pw="chroot /proc/1/root /tmp/mibox-partwrite"
echo "== dry run: boot <- Dev13 (expect-current = stock boot)"
ssh_ "$pw --target boot --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $BOOT --dry-run"
echo "== refusal: boot with wrong expect-current (must fail)"
! ssh_ "$pw --target boot --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $IMG --dry-run"
echo "== refusal: recovery not allowed (must fail)"
! ssh_ "$pw --target recovery --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $BOOT --dry-run"
echo "== boot1 already holds Dev13 (dry run)"
ssh_ "$pw --target boot1 --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $IMG --dry-run"
echo "== hashes again (unchanged?)"; ssh_ 'sync; echo 3 > /proc/sys/vm/drop_caches; chroot /proc/1/root /bin/sh -s' < scripts/device/a3a-hash-boot-partitions.sh
echo "== cleanup"; ssh_ 'rm -f /proc/1/root/tmp/mibox-partwrite /proc/1/root/tmp/slim.img; ls /dev/mibox-partwrite-* 2>&1 | head -1'
echo S8_DRYRUN_DONE
