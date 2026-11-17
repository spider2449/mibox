"""QEMU test of the slim A3 image with automatic Alpine activation (A3/B1/B4/B5).

Generic ARM QEMU only; not proof for the stock 3.10.33 kernel or the MiBOX.
Fixture differences from the physical rootfs: the USB ADB marker is removed
(QEMU has no UDC; the FailSafe PID1 would otherwise restart) and the start
script loads QEMU virtio/ext4 modules. The data disk is built from the S2
backup of the real Alpine tree, so SSH uses its real persistent host key.

Cases: two boots with the tree (strict host key, persistence, stop/unmount,
clean fsck), no data disk, and an empty ext4 disk (tree never created).
Run under WSL: python3 scripts/test-slim-qemu.py --private-key KEY
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import lzma
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKUP = ROOT / 'phone-tools/backup/2026-11-17-s2/mibox-console.tar'
BACKUP_SHA256 = '5d655f74e0ccc9af7d1b4b6169b8c5a9cf8bfbfed73d6768358e4d22e6b492ae'
MODULES = ['failover', 'net_failover', 'virtio_mmio', 'virtio_net']


def fixture(work):
    spec = importlib.util.spec_from_file_location('console', ROOT / 'scripts/build-console-rootfs.py')
    console = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(console)
    slim = (ROOT / 'target/mibox-rootfs-slim/initramfs.NOT_READY.cpio.gz').read_bytes()
    entries = console.unpack(gzip.decompress(slim))
    del entries['etc/mibox-usb-adb.enabled']
    installer = console.unpack(gzip.decompress((ROOT / 'target/console-download/qemu-netboot-initrd.gz').read_bytes()))
    entries['qemu-modules'] = (0o040755, b'', 0, 0)
    modules = list(MODULES)
    for module in MODULES:
        matches = [v[1] for n, v in installer.items() if n.endswith('/' + module + '.ko.xz')]
        if len(matches) != 1:
            raise RuntimeError('missing QEMU module ' + module)
        entries['qemu-modules/' + module + '.ko'] = (0o100644, lzma.decompress(matches[0]), 0, 0)
    tree = ROOT / 'target/console-qemu-kernel/usr/lib/modules/6.12.107+deb13-armmp'
    files = {p.name.removesuffix('.ko.xz').replace('-', '_'): p for p in tree.rglob('*.ko.xz')}

    def include(module):
        if module in modules:
            return
        path = files[module]
        depends = subprocess.check_output(['modinfo', '-F', 'depends', str(path)], text=True).strip()
        for dependency in filter(None, depends.split(',')):
            include(dependency.replace('-', '_'))
        entries['qemu-modules/' + module + '.ko'] = (0o100644, lzma.decompress(path.read_bytes()), 0, 0)
        modules.append(module)
    for module in ('virtio_blk', 'crc32c_generic', 'ext4'):
        include(module)
    start = entries['sbin/mibox-console-start'][1]
    marker = b'    ip link set eth0 up'
    if start.count(marker) < 1:
        raise RuntimeError('start script layout changed')
    start = start.replace(marker, ('    for module in ' + ' '.join(modules) +
                                   '; do insmod /qemu-modules/$module.ko; done\n').encode() + marker, 1)
    entries['sbin/mibox-console-start'] = (0o100755, start, 0, 0)
    path = work / 'slim-qemu.cpio.gz'
    path.write_bytes(gzip.compress(console.pack(entries), mtime=0))
    return path, hashlib.sha256(slim).hexdigest()


def disk_from_tree(work, name):
    if hashlib.sha256(BACKUP.read_bytes()).hexdigest() != BACKUP_SHA256:
        raise RuntimeError('S2 backup hash mismatch')
    image = work / name
    stage = work / 'stage'
    # Inside a user namespace uid 0 maps to the caller: tar restores 0:0 and
    # mkfs.ext4 -d records it. Device nodes in the leftover test dir fail (ok).
    subprocess.run(['unshare', '-r', 'sh', '-c',
                    f'mkdir -p {stage} && tar --numeric-owner -xpf {BACKUP} -C {stage} 2>/dev/null; '
                    f'mkfs.ext4 -q -F -d {stage} {image} 256M'], check=True)
    subprocess.run(['unshare', '-r', 'rm', '-rf', str(stage)], check=True)
    pub = subprocess.run(['debugfs', '-R', 'cat /mibox-console/rootfs/etc/dropbear/dropbear_ed25519_host_key.pub',
                          str(image)], capture_output=True, text=True, check=True).stdout.split()
    return image, pub[:2]


def boot(command, log_path):
    log = open(log_path, 'wb')
    return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT), log


def stop_qemu(process, log):
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()


def wait_serial(path, text, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if text in path.read_bytes().decode('utf-8', 'replace'):
            return True
        time.sleep(1)
    return False


def main(private_key):
    evidence = ROOT / 'artifacts/slim-qemu' / time.strftime('%Y%m%d-%H%M%S')
    evidence.mkdir(parents=True)
    results = []

    def record(name, passed, detail=''):
        results.append(dict(name=name, passed=bool(passed), detail=detail))
        print(('PASS' if passed else 'FAIL'), name, detail)

    with tempfile.TemporaryDirectory(prefix='mibox-slim-') as directory:
        work = Path(directory)
        initrd, slim_sha = fixture(work)
        key = work / 'key'
        shutil.copyfile(private_key, key)
        key.chmod(0o600)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        base = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15', '-m', '256',
                '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-no-reboot',
                '-kernel', str(ROOT / 'phone-tools/qemu/vmlinuz'), '-initrd', str(initrd),
                '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0 mibox.test_restart=1',
                '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
                '-device', 'virtio-net-device,netdev=net0']

        def with_disk(image):
            return base + ['-drive', f'file={image},if=none,id=data,format=raw',
                           '-device', 'virtio-blk-device,drive=data']

        image, host_key = disk_from_tree(work, 'data.img')
        known = work / 'known_hosts'
        known.write_text(f'[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n')
        ssh = ['ssh', '-i', str(key), '-p', str(port), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
               '-o', 'ConnectTimeout=3', 'root@127.0.0.1']

        def remote(script, timeout=60):
            return subprocess.run(ssh + [script], capture_output=True, text=True, timeout=timeout)

        def wait_ssh(process, seconds=120):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    return False
                if remote('echo READY', 15).stdout.strip() == 'READY':
                    return True
                time.sleep(2)
            return False

        for boot_index in (1, 2):
            # Boot 1: root stop from SSH. Boot 2: B5 through PID1 as uid 2000.
            serial = evidence / f'serial-tree-boot{boot_index}.log'
            process, log = boot(with_disk(image), serial)
            try:
                record(f'boot{boot_index}-ssh-strict-persistent-host-key', wait_ssh(process))
                if not results[-1]['passed']:
                    break
                r = remote('test -f /etc/mibox-persistent-root && grep -q "^ID=mibox-custom$" /etc/os-release '
                           '&& test "$(id -u)" = 0 && test -x /usr/local/sbin/apk && echo IN_ALPINE')
                record(f'boot{boot_index}-session-in-alpine-with-apk-guard', 'IN_ALPINE' in r.stdout, r.stderr.strip())
                r = remote('cat /proc/1/root/etc/dropbear/dropbear_ed25519_host_key.pub')
                record(f'boot{boot_index}-ram-copy-of-public-key', r.stdout.split()[:2] == host_key)
                r = remote('grep " /mnt/mibox-data " /proc/1/mountinfo')
                record(f'boot{boot_index}-data-mounted', ' - ext4 /dev/vda ' in r.stdout, r.stdout.strip())
                if boot_index == 1:
                    r = remote('echo SLIM_SENTINEL > /root/slim-sentinel && sync && echo WROTE')
                    record('boot1-write-sentinel', 'WROTE' in r.stdout)
                else:
                    r = remote('cat /root/slim-sentinel')
                    record('boot2-sentinel-retained', r.stdout.strip() == 'SLIM_SENTINEL')
                if boot_index == 1:
                    # Root stop from inside an Alpine SSH session: the session is killed.
                    r = remote('exec chroot /proc/1/root /sbin/mibox-persistent-console stop --qemu', 90)
                    stopped = wait_serial(serial, 'MIBOX_PERSISTENT_CONSOLE_STOPPED', 30)
                    record('boot1-stop-from-own-session', stopped, f'ssh exit {r.returncode}')
                    time.sleep(3)
                    r = remote('true', 10)
                    record('boot1-ssh-gone-after-stop', r.returncode == 255)
                else:
                    # B5 via PID1 as uid 2000 (USB ADB's uid), with a RAM root so
                    # the client survives the stop killing this SSH session.
                    as_adb = 'chroot --userspec=2000:2000 /proc/1/root /bin/mibox'
                    boot_id = remote('cat /proc/sys/kernel/random/boot_id').stdout.strip()
                    r = remote(f'{as_adb} reboot-android --check')
                    record('boot2-check-refused-while-data-mounted', r.returncode != 0, r.stderr.strip()[-120:])
                    r = remote(f'{as_adb} reboot-android --boot-id {boot_id}')
                    record('boot2-restart-refused-while-data-mounted', r.returncode != 0 and process.poll() is None)
                    r = remote(f'{as_adb} persist-stop --boot-id 00000000-0000-0000-0000-000000000000')
                    record('boot2-persist-stop-stale-boot-id-refused', r.returncode != 0
                           and 'MIBOX_PERSIST_STOP_REQUESTED' not in serial.read_text(errors='replace'))
                    # One uid-2000 shell with a RAM root runs both requests; it
                    # outlives this SSH session, which the stop kills.
                    remote('exec chroot --userspec=2000:2000 /proc/1/root /bin/sh -c '
                           f'"mibox persist-stop --boot-id {boot_id} > /tmp/persist-stop.out 2>&1 && '
                           f'mibox reboot-android --boot-id {boot_id} >> /tmp/persist-stop.out 2>&1"', 120)
                    try:
                        process.wait(timeout=120)
                        exited = True
                    except subprocess.TimeoutExpired:
                        exited = False
                    text = serial.read_text(errors='replace')
                    record('boot2-persist-stop-via-pid1-as-uid2000', 'MIBOX_PERSIST_STOP_EXIT=0' in text
                           and 'MIBOX_PERSISTENT_CONSOLE_STOPPED' in text)
                    record('boot2-restart-accepted-after-stop', exited and 'MIBOX_NORMAL_RESTART_REQUESTED' in text)
            finally:
                stop_qemu(process, log)
            fsck = subprocess.run(['e2fsck', '-fn', str(image)], capture_output=True, text=True)
            (evidence / f'fsck-boot{boot_index}.txt').write_text(fsck.stdout + fsck.stderr)
            record(f'boot{boot_index}-filesystem-clean-after-stop', fsck.returncode == 0)

        serial = evidence / 'serial-no-disk.log'
        process, log = boot(base, serial)
        try:
            unavailable = wait_serial(serial, 'MIBOX_PERSISTENT_UNAVAILABLE', 120)
            record('no-disk-stays-ram-only', unavailable)
            record('no-disk-pid1-console-alive', 'MIBOX_INIT_CONSOLE_READY' in serial.read_text(errors='replace'))
            record('no-disk-no-ssh', remote('true', 10).returncode == 255)
        finally:
            stop_qemu(process, log)

        empty = work / 'empty.img'
        subprocess.run(['mkfs.ext4', '-q', '-F', str(empty), '64M'], check=True)
        serial = evidence / 'serial-empty-disk.log'
        process, log = boot(with_disk(empty), serial)
        try:
            unavailable = wait_serial(serial, 'MIBOX_PERSISTENT_UNAVAILABLE', 120)
            record('empty-disk-stays-ram-only', unavailable)
            record('empty-disk-boot-failed-marker', 'MIBOX_PERSISTENT_BOOT_FAILED' in serial.read_text(errors='replace'))
            record('empty-disk-no-ssh', remote('true', 10).returncode == 255)
        finally:
            stop_qemu(process, log)
        listing = subprocess.run(['debugfs', '-R', 'ls /', str(empty)], capture_output=True, text=True).stdout
        record('empty-disk-tree-not-created', 'mibox-console' not in listing, listing.strip())
        fsck = subprocess.run(['e2fsck', '-fn', str(empty)], capture_output=True, text=True)
        record('empty-disk-unmounted-clean', fsck.returncode == 0)

    passed = all(r['passed'] for r in results)
    (evidence / 'result.json').write_text(json.dumps(dict(
        scope='Generic ARM QEMU (Debian 6.12) only; not stock 3.10.33 or physical MiBOX proof',
        fixture_differences=['USB ADB marker removed (no UDC in QEMU)', 'QEMU virtio/ext4 modules loaded by start script'],
        slim_rootfs_sha256=slim_sha, data_disk_source=f'S2 backup {BACKUP_SHA256}',
        checks=results, all_passed=passed), indent=2) + '\n')
    print('SLIM_QEMU', 'PASS' if passed else 'FAIL', evidence)
    return 0 if passed else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    raise SystemExit(main(parser.parse_args().private_key))
