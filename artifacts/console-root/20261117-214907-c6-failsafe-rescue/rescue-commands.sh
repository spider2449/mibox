set -eu
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-c6-failsafe-rescue | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
echo "== context"; ssh_ 'grep ^ID= /etc/os-release; test -f /etc/mibox-persistent-root && echo PERSISTENT || echo RAM_ROOT; readlink /proc/self/root; grep -c ext4 /proc/mounts || true; ls /sbin/mibox-persistent-shell 2>&1 | head -1'
ssh_ 'cat > /tmp/mibox-partwrite && chmod 700 /tmp/mibox-partwrite' < target/armv7-unknown-linux-musleabihf/release/mibox-partwrite
ssh_ 'cat > /tmp/boot1.img' < phone-tools/backup/2026-11-13/boot1.img
ssh_ 'cat > /tmp/slim.img' < target/mibox-boot-candidate-slim/boot1-custom.NOT_READY.img
ssh_ 'cd /tmp && sha256sum mibox-partwrite boot1.img slim.img'
echo "== boot partitions as seen from FailSafe (read-only)"
ssh_ 'sh -s' < scripts/device/a3a-hash-boot-partitions.sh
echo "== restore-direction dry run: stock backup over installed Slim"
ssh_ '/tmp/mibox-partwrite --target boot1 --image /tmp/boot1.img --image-sha256 06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222 --expect-current-sha256 dd1e6756bbbc8b5b5f268ac3b79a11ded792a6c4ee7ad43318ab641de3b14f2e --dry-run; echo rc=$?'
ssh_ 'rm -f /tmp/mibox-partwrite /tmp/boot1.img /tmp/slim.img; ls /dev/mibox-partwrite-* 2>&1 | head -1'
