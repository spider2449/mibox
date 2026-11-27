set -eu
# S8: owner-approved 2026-11-27 ("yes" to "write Slim to boot"). One write, no retry.
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-s8-boot-write | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
IMG=614861f672f6ef24aa1e1a803cb6ec4ddcecb173683a978ed06cbc837af5ef24
CUR=ff4fa440044709b92652afea0306286534c9da2f57e41308d67459b97e800a56
TOOL=ee69569fb0360fd382c8f85588ec0bcc8bad8e7a7c2624c95a5dcac204b92719
SRC=target/mibox-boot-candidate-slim-kernel-dev13/boot1-custom.NOT_READY.img
BIN=target/armv7-unknown-linux-musleabihf/release/mibox-partwrite
echo "== local inputs"; sha256sum $BIN $SRC
test "$(sha256sum $SRC | cut -d' ' -f1)" = $IMG
test "$(sha256sum $BIN | cut -d' ' -f1)" = $TOOL
echo "== device"; ssh_ 'date -u; cat /proc/sys/kernel/random/boot_id; grep ^ID= /etc/os-release'
ssh_ 'cat > /proc/1/root/tmp/mibox-partwrite && chmod 700 /proc/1/root/tmp/mibox-partwrite' < $BIN
ssh_ 'cat > /proc/1/root/tmp/slim.img' < $SRC
up=$(ssh_ 'cd /proc/1/root/tmp && sha256sum mibox-partwrite slim.img'); echo "$up"
echo "$up" | grep -q "$TOOL  mibox-partwrite"; echo "$up" | grep -q "$IMG  slim.img"
pw="chroot /proc/1/root /tmp/mibox-partwrite --target boot --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $CUR"
echo "== dry run"; ssh_ "$pw --dry-run"
echo "== write"; ssh_ "$pw"
echo "== independent re-hash"; ssh_ 'sync; echo 3 > /proc/sys/vm/drop_caches; chroot /proc/1/root /bin/sh -s' < scripts/device/a3a-hash-boot-partitions.sh
echo "== kernel"; ssh_ 'dmesg | grep -iE "mmc|I/O error" | tail -5'
echo "== cleanup"; ssh_ 'rm -f /proc/1/root/tmp/mibox-partwrite /proc/1/root/tmp/slim.img; ls /dev/mibox-partwrite-* 2>&1 | head -1'
echo S8_WRITE_SEQUENCE_DONE
