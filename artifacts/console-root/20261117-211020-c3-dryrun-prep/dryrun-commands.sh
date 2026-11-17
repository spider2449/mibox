set -eu
repo=$(wslpath -u "F:/coding/otherPrj/mibox"); cd "$repo"
keysrc=$(wslpath -u "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')")/.ssh/mibox-console
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cp "$keysrc" $tmp/key; chmod 600 $tmp/key
ev=$(ls -d artifacts/console-root/*-c3-dryrun-prep | tail -1)
ssh_() { ssh -i $tmp/key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$ev/known_hosts -o ConnectTimeout=10 root@192.168.1.222 "$@"; }
ssh_ 'cat > /proc/1/root/tmp/mibox-partwrite && chmod 700 /proc/1/root/tmp/mibox-partwrite' < target/armv7-unknown-linux-musleabihf/release/mibox-partwrite
ssh_ 'cat > /proc/1/root/tmp/slim.img' < target/mibox-boot-candidate-slim/boot1-custom.NOT_READY.img
ssh_ 'cd /proc/1/root/tmp && sha256sum mibox-partwrite slim.img'
echo "== dry run against real boot1 (read-only)"
ssh_ 'chroot /proc/1/root /tmp/mibox-partwrite --target boot1 --image /tmp/slim.img --image-sha256 87daa0d3e6836a4bff422fb7d1ab6d6ca8643317dd13b188555205a696e08e28 --expect-current-sha256 06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222 --dry-run; echo rc=$?'
echo "== wrong expected current is refused"
ssh_ 'chroot /proc/1/root /tmp/mibox-partwrite --target boot1 --image /tmp/slim.img --image-sha256 87daa0d3e6836a4bff422fb7d1ab6d6ca8643317dd13b188555205a696e08e28 --expect-current-sha256 0000000000000000000000000000000000000000000000000000000000000000 --dry-run; echo rc=$?'
echo "== boot (not allowed) is refused"
ssh_ 'chroot /proc/1/root /tmp/mibox-partwrite --target boot --image /tmp/slim.img --image-sha256 87daa0d3e6836a4bff422fb7d1ab6d6ca8643317dd13b188555205a696e08e28 --expect-current-sha256 06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222 --dry-run; echo rc=$?'
ssh_ 'rm -f /proc/1/root/tmp/mibox-partwrite /proc/1/root/tmp/slim.img; ls /dev/mibox-partwrite-* 2>&1 | head -1'
