"""C3 rehearsal: mibox-partwrite against a real virtio block device in QEMU.

Generic ARM QEMU only. Reuses the slim QEMU fixture (Alpine data disk from the
S2 backup for SSH). A second 8 MiB disk `vdb` starts as a copy of the stock
boot1 backup; `mibox.test_partwrite=1` lets the tool target it. Cases:
refusals (platform target, wrong current hash, wrong image hash, oversized
image), dry run, write of the Slim candidate with readback, independent busybox
re-hash, restore of the boot1 backup, and host-side hashes of the disk file.
Run under WSL: python3 scripts/test-partwrite-qemu.py --private-key KEY
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOT1 = ROOT / 'phone-tools/backup/2026-11-13/boot1.img'
BOOT1_SHA = '06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222'
SLIM = ROOT / 'target/mibox-boot-candidate-slim/boot1-custom.NOT_READY.img'
TOOL = ROOT / 'target/armv7-unknown-linux-musleabihf/release/mibox-partwrite'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(private_key):
    spec = importlib.util.spec_from_file_location('slim', ROOT / 'scripts/test-slim-qemu.py')
    slim = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(slim)
    if sha(BOOT1) != BOOT1_SHA:
        raise RuntimeError('boot1 backup hash mismatch')
    slim_sha, tool_sha = sha(SLIM), sha(TOOL)
    evidence = ROOT / 'artifacts/partwrite-qemu' / time.strftime('%Y%m%d-%H%M%S')
    evidence.mkdir(parents=True)
    results = []

    def record(name, passed, detail=''):
        results.append(dict(name=name, passed=bool(passed), detail=detail[-300:]))
        print(('PASS' if passed else 'FAIL'), name, detail[-160:])

    with tempfile.TemporaryDirectory(prefix='mibox-partwrite-') as directory:
        work = Path(directory)
        initrd, _ = slim.fixture(work)
        data, host_key = slim.disk_from_tree(work, 'data.img')
        vdb = work / 'boot1-copy.img'
        shutil.copyfile(BOOT1, vdb)
        key = work / 'key'
        shutil.copyfile(private_key, key)
        key.chmod(0o600)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15', '-m', '256',
                   '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-no-reboot',
                   '-kernel', str(ROOT / 'phone-tools/qemu/vmlinuz'), '-initrd', str(initrd),
                   '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0 mibox.test_partwrite=1',
                   '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
                   '-device', 'virtio-net-device,netdev=net0',
                   # virt enumerates virtio-mmio devices in reverse: the last one becomes vda.
                   '-drive', f'file={vdb},if=none,id=boot1,format=raw', '-device', 'virtio-blk-device,drive=boot1',
                   '-drive', f'file={data},if=none,id=data,format=raw', '-device', 'virtio-blk-device,drive=data']
        known = work / 'known_hosts'
        known.write_text(f'[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n')
        ssh = ['ssh', '-i', str(key), '-p', str(port), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
               '-o', 'ConnectTimeout=3', 'root@127.0.0.1']

        def remote(script, stdin=None, timeout=120):
            r = subprocess.run(ssh + [script], input=stdin, capture_output=True, timeout=timeout)
            out = r.stdout.decode(errors='replace') + r.stderr.decode(errors='replace')
            with (evidence / 'session.txt').open('a') as f:
                f.write(f'$ {script}\n{out}rc={r.returncode}\n\n')
            return r.returncode, out

        serial = evidence / 'serial.log'
        process, log = slim.boot(command, serial)
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline and remote('echo READY', timeout=15)[1].strip() != 'READY':
                time.sleep(2)
            record('ssh-ready', remote('echo READY')[1].strip() == 'READY')
            # Upload into RAM (/proc/1/root/tmp) and run with a RAM root.
            for name, path in (('mibox-partwrite', TOOL), ('slim.img', SLIM), ('boot1.img', BOOT1)):
                rc, _ = remote(f'cat > /proc/1/root/tmp/{name}', stdin=path.read_bytes())
                if rc != 0:
                    raise RuntimeError('upload failed: ' + name)
            remote('chmod 700 /proc/1/root/tmp/mibox-partwrite')
            rc, out = remote(f'cd /proc/1/root/tmp && sha256sum mibox-partwrite slim.img boot1.img')
            record('uploads-hash-match', all(h in out for h in (tool_sha, slim_sha, BOOT1_SHA)))
            pw = 'chroot /proc/1/root /tmp/mibox-partwrite'
            bogus = '0' * 64
            rc, out = remote(f'{pw} --target boot1 --image /tmp/slim.img --image-sha256 {slim_sha} --expect-current-sha256 {BOOT1_SHA}')
            record('refuses-boot1-on-qemu', rc != 0 and 'not allowed' in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/slim.img --image-sha256 {slim_sha} --expect-current-sha256 {bogus}')
            record('refuses-wrong-current-hash', rc != 0 and 'differs from --expect-current' in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/slim.img --image-sha256 {bogus} --expect-current-sha256 {BOOT1_SHA}')
            record('refuses-wrong-image-hash', rc != 0 and 'image SHA256 differs' in out, out)
            remote('cat /proc/1/root/tmp/slim.img /proc/1/root/tmp/slim.img > /proc/1/root/tmp/double.img')
            rc, out = remote(f'{pw} --target vdb --image /tmp/double.img --image-sha256 {slim_sha} --expect-current-sha256 {BOOT1_SHA}')
            record('refuses-oversized-image', rc != 0 and 'expected 8388608' in out, out)
            rc, out = remote('rm /proc/1/root/tmp/double.img; dd if=/dev/vdb bs=65536 2>/dev/null | sha256sum')
            record('vdb-unchanged-after-refusals', BOOT1_SHA in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/slim.img --image-sha256 {slim_sha} --expect-current-sha256 {BOOT1_SHA} --dry-run')
            record('dry-run-verifies-current', rc == 0 and 'DryRunVerified' in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/slim.img --image-sha256 {slim_sha} --expect-current-sha256 {BOOT1_SHA}')
            record('write-slim-with-readback', rc == 0 and 'Written' in out and f'READBACK_VERIFIED={slim_sha}' in out, out)
            rc, out = remote('echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/vdb bs=65536 2>/dev/null | sha256sum')
            record('independent-rehash-after-write', slim_sha in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/slim.img --image-sha256 {slim_sha} --expect-current-sha256 {BOOT1_SHA}')
            record('second-write-reports-already-installed', rc == 0 and 'AlreadyInstalled' in out, out)
            rc, out = remote(f'{pw} --target vdb --image /tmp/boot1.img --image-sha256 {BOOT1_SHA} --expect-current-sha256 {slim_sha}')
            record('restore-boot1-with-readback', rc == 0 and 'Written' in out and f'READBACK_VERIFIED={BOOT1_SHA}' in out, out)
            rc, out = remote('echo 3 > /proc/sys/vm/drop_caches; dd if=/dev/vdb bs=65536 2>/dev/null | sha256sum; ls /dev/mibox-partwrite-* 2>&1')
            record('independent-rehash-after-restore', BOOT1_SHA in out and 'No such file' in out, out)
            remote('exec chroot /proc/1/root /sbin/mibox-persistent-console stop --qemu', timeout=60)
        finally:
            slim.stop_qemu(process, log)
        record('host-file-equals-boot1-after-restore', sha(vdb) == BOOT1_SHA, sha(vdb))
    passed = all(r['passed'] for r in results)
    (evidence / 'result.json').write_text(json.dumps(dict(
        scope='Generic ARM QEMU virtio block device; not MiBOX eMMC write proof',
        tool_sha256=tool_sha, slim_sha256=slim_sha, boot1_sha256=BOOT1_SHA,
        checks=results, all_passed=passed), indent=2) + '\n')
    print('PARTWRITE_QEMU', 'PASS' if passed else 'FAIL', evidence)
    return 0 if passed else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    raise SystemExit(main(parser.parse_args().private_key))
