"""WSL: read the exact physical environment through USB-authenticated SSH."""
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STAMP = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')


def main():
    evidence = ROOT / 'artifacts/restoration/2026-11-15' / ('environment-' + STAMP)
    evidence.mkdir(parents=True)
    backup = ROOT / 'phone-tools/backup' / ('rescue-window-' + STAMP)
    backup.mkdir(parents=True)
    proof = dict(device_access=True, partition_write=False, backup_verified=False)
    adb = str(ROOT / 'phone-tools/platform-tools/adb.exe')

    def usb(command):
        result = subprocess.run([adb, '-s', '248243005297', 'shell', command],
                                capture_output=True, timeout=10, check=True)
        return result.stdout.decode().replace('\r', '').strip()

    try:
        if 'ID=mibox-custom' not in usb('cat /etc/os-release').splitlines():
            raise ValueError('custom RAM OS required')
        boot_id = usb('cat /proc/sys/kernel/random/boot_id')
        if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', boot_id):
            raise ValueError('invalid USB boot identity')
        public = usb('cat /etc/dropbear/dropbear_ed25519_host_key.pub').split()
        if len(public) < 2 or public[0] != 'ssh-ed25519':
            raise ValueError('USB-authenticated public host key unavailable')
        known = evidence / 'known_hosts'
        known.write_text('192.168.1.222 ' + ' '.join(public[:2]) + '\n')
        with tempfile.TemporaryDirectory(prefix='mibox-env-key-') as name:
            key = Path(name) / 'key'
            shutil.copyfile('/mnt/c/Users/morefunfun/.ssh/mibox-console', key)
            key.chmod(0o600)
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=8', 'root@192.168.1.222', 'sh -s']
            # The unique node lives in the outer PID1 RAM root, not the data chroot.
            node = '/proc/1/root/tmp/mibox-env-read-' + STAMP
            script = r'''
set -eux
test "$(id -u)" = 0
tr -d '\r' < /proc/1/root/etc/os-release | grep -qx ID=mibox-custom
test "$(cat /proc/sys/kernel/random/boot_id)" = @BOOT@
test "$(cat /sys/class/block/env/dev)" = 179:3
test "$(cat /sys/class/block/env/size)" = 8192
test "$(cat /sys/class/block/env/ro)" = 0
test "$(busybox stat -f -c %t /proc/1/root/tmp)" = 858458f6
test ! -e @NODE@
trap 'rm -f @NODE@' EXIT
busybox mknod -m 400 @NODE@ b 179 3
test "$(busybox stat -c %t:%T @NODE@)" = b3:3
test -z "$(awk '$3 == "179:3" {print}' /proc/self/mountinfo)"
echo ENV_SHA256_BEFORE >&2
sha256sum @NODE@ >&2
dd if=@NODE@ bs=65536 count=64
echo ENV_SHA256_AFTER >&2
sha256sum @NODE@ >&2
test "$(cat /proc/sys/kernel/random/boot_id)" = @BOOT@
echo ENV_READ_COMPLETE >&2
'''.replace('@BOOT@', boot_id).replace('@NODE@', node)
            result = subprocess.run(ssh, input=script.encode(), capture_output=True, timeout=90)
        (evidence / 'read-command.sh').write_text(script)
        (evidence / 'read-stderr.txt').write_bytes(result.stderr)
        if result.returncode or len(result.stdout) != 4194304:
            raise RuntimeError(f'bounded env read failed: exit={result.returncode}, bytes={len(result.stdout)}')
        transcript = result.stderr.decode()
        hashes = re.findall(r'(?m)^([0-9a-f]{64})\s+' + re.escape(node) + r'$', transcript)
        digest = hashlib.sha256(result.stdout).hexdigest()
        if hashes != [digest, digest] or 'ENV_READ_COMPLETE' not in transcript:
            raise ValueError('device before/after and host hashes do not agree')
        if usb('cat /proc/sys/kernel/random/boot_id') != boot_id:
            raise ValueError('boot identity changed after backup')
        destination = backup / 'env.img'
        destination.write_bytes(result.stdout)
        proof.update(backup_verified=True, boot_id=boot_id, bytes=len(result.stdout), sha256=digest,
                     device='179:3', sectors=8192, backup=str(destination),
                     private_key_retained=False, temporary_node_removed=True)
        print(json.dumps(proof, indent=2))
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')


if __name__ == '__main__':
    main()
