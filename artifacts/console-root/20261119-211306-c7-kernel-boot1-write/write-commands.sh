set -eu
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-c7-kernel-boot1-write | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
IMG=bccbad4ff8e7e104de544537ddc1d89ea07fced3c34645b92ae74ac6e0268b4a
CUR=955ea3e8a36f5f13b69dd09476a7c03d763d825024323bc92fd6e507799e4c66
TOOL=e4750d65206780f16a44a957188a87a591d24f1dbdfe16ba8acb0c2d9707d1ec
echo "== local inputs"; sha256sum target/armv7-unknown-linux-musleabihf/release/mibox-partwrite target/mibox-boot-candidate-slim-kernel-dev7/boot1-custom.NOT_READY.img
test "$(sha256sum target/mibox-boot-candidate-slim-kernel-dev7/boot1-custom.NOT_READY.img | cut -d' ' -f1)" = $IMG
test "$(sha256sum target/armv7-unknown-linux-musleabihf/release/mibox-partwrite | cut -d' ' -f1)" = $TOOL
echo "== device"; ssh_ 'date -u; cat /proc/sys/kernel/random/boot_id; grep ^ID= /etc/os-release'
ssh_ 'cat > /proc/1/root/tmp/mibox-partwrite && chmod 700 /proc/1/root/tmp/mibox-partwrite' < target/armv7-unknown-linux-musleabihf/release/mibox-partwrite
ssh_ 'cat > /proc/1/root/tmp/slim.img' < target/mibox-boot-candidate-slim-kernel-dev7/boot1-custom.NOT_READY.img
up=$(ssh_ 'cd /proc/1/root/tmp && sha256sum mibox-partwrite slim.img'); echo "$up"
echo "$up" | grep -q "$TOOL  mibox-partwrite"; echo "$up" | grep -q "$IMG  slim.img"
echo "== step 3: dry run"
ssh_ "chroot /proc/1/root /tmp/mibox-partwrite --target boot1 --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $CUR --dry-run"
echo "== step 4: write"
ssh_ "chroot /proc/1/root /tmp/mibox-partwrite --target boot1 --image /tmp/slim.img --image-sha256 $IMG --expect-current-sha256 $CUR"
echo "== step 5: independent re-hash"
ssh_ 'sync; echo 3 > /proc/sys/vm/drop_caches; chroot /proc/1/root /bin/sh -s' < scripts/device/a3a-hash-boot-partitions.sh
echo "== cleanup"
ssh_ 'rm -f /proc/1/root/tmp/mibox-partwrite /proc/1/root/tmp/slim.img; ls /dev/mibox-partwrite-* 2>&1 | head -1'
echo C7_SEQUENCE_DONE
