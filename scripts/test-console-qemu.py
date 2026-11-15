"""Exercise the actual ARM console image using SSH and HTTPS apk in QEMU."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import lzma
import os
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def main(root, private_key, persistent=False):
    evidence = root / ('artifacts/console-ssh/qemu-persistence' if persistent else 'artifacts/console-ssh/qemu')
    evidence.mkdir(parents=True, exist_ok=True)
    results = []
    spec = importlib.util.spec_from_file_location('console_builder', root / 'scripts/build-console-rootfs.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    entries = builder.unpack(gzip.decompress((root / 'target/mibox-rootfs-console/initramfs.NOT_READY.cpio.gz').read_bytes()))
    installer_bytes = (root / 'target/console-download/qemu-netboot-initrd.gz').read_bytes()
    if hashlib.sha256(installer_bytes).hexdigest() != 'e7ca77e9dfd998ef8a6f5a39ae3bf7d8c6cfcbdc3c4f59b84077ace585928fbb':
        raise RuntimeError('QEMU installer initrd differs from pinned Debian checksum')
    installer = builder.unpack(gzip.decompress(installer_bytes))
    entries['qemu-modules'] = (0o040755, b'', 0, 0)
    modules = ['failover', 'net_failover', 'virtio_mmio', 'virtio_net']
    for module in modules:
        matches = [value[1] for name, value in installer.items() if name.endswith('/' + module + '.ko.xz')]
        if len(matches) != 1:
            raise RuntimeError('missing matching QEMU module: ' + module)
        entries['qemu-modules/' + module + '.ko'] = (0o100644, lzma.decompress(matches[0]), 0, 0)
    if persistent:
        kernel_tree = root / 'target/console-qemu-kernel/usr/lib/modules/6.12.107+deb13-armmp'
        module_files = {p.name.removesuffix('.ko.xz').replace('-', '_'): p for p in kernel_tree.rglob('*.ko.xz')}
        loaded = set(modules)
        def include(module):
            if module in loaded:
                return
            path = module_files[module]
            dependencies = subprocess.check_output(['modinfo', '-F', 'depends', str(path)], text=True).strip()
            for dependency in filter(None, dependencies.split(',')):
                include(dependency.replace('-', '_'))
            entries['qemu-modules/' + module + '.ko'] = (0o100644, lzma.decompress(path.read_bytes()), 0, 0)
            modules.append(module)
            loaded.add(module)
        include('virtio_blk')
        include('crc32c_generic')
        include('ext4')
    startup = entries['sbin/mibox-console-start'][1]
    startup = startup.replace(b'    ip link set eth0 up',
        ('    for module in ' + ' '.join(modules) + '; do insmod /qemu-modules/$module.ko; done\n    ip link set eth0 up').encode())
    entries['sbin/mibox-console-start'] = (0o100755, startup, 0, 0)
    fixture = root / 'target/mibox-console-qemu.cpio.gz'
    fixture.write_bytes(gzip.compress(builder.pack(entries), mtime=0))
    with tempfile.TemporaryDirectory(prefix='mibox-console-') as directory:
        work = Path(directory)
        key = work / 'owner-key'
        shutil.copyfile(private_key, key)
        key.chmod(0o600)
        with socket.socket() as port_socket:
            port_socket.bind(('127.0.0.1', 0))
            port = port_socket.getsockname()[1]
        command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15',
                   '-m', '256', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
                   '-no-reboot', '-kernel', str(root / 'phone-tools/qemu/vmlinuz'),
                   '-initrd', str(fixture),
                   '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0',
                   '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
                   '-device', 'virtio-net-device,netdev=net0']
        if persistent:
            disk = work / 'data.img'
            with disk.open('wb') as stream:
                stream.truncate(128 * 1024 * 1024)
            subprocess.run(['mkfs.ext4', '-q', '-F', str(disk)], check=True)
            command += ['-drive', f'file={disk},if=none,id=data,format=raw', '-device', 'virtio-blk-device,drive=data']
        log = open(evidence / 'serial.log', 'wb')
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        ssh = ['ssh', '-i', str(key), '-p', str(port), '-o', 'BatchMode=yes',
               '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new',
               '-o', f'UserKnownHostsFile={work / "known_hosts"}', '-o', 'ConnectTimeout=3']
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                probe = subprocess.run(ssh + ['root@127.0.0.1', 'echo MIBOX_SSH_OK'],
                                       capture_output=True, text=True, timeout=10)
                if probe.returncode == 0 and 'MIBOX_SSH_OK' in probe.stdout:
                    break
                if process.poll() is not None:
                    raise RuntimeError('QEMU exited before SSH was available')
                time.sleep(1)
            else:
                raise RuntimeError('SSH not ready: ' + probe.stderr)
            checks = [
                ('pty-diagnostics', [], 'ls -ld /dev/ptmx /dev/pts /dev/pts/ptmx; cat /proc/mounts; echo PTY_DIAGNOSTICS', 'PTY_DIAGNOSTICS'),
                ('identity', [], 'test "$(id -u)" = 0 && grep -q "ID=mibox-custom" /etc/os-release && uname -m', 'armv7l'),
                ('interactive-pty', ['-tt'], 'test -t 0 && test -t 1 && echo MIBOX_PTY_OK', 'MIBOX_PTY_OK'),
                ('dns', [], 'nslookup dl-cdn.alpinelinux.org', 'Address:'),
                ('package-install', [], 'apk update && apk add --no-cache nano && nano --version', 'GNU nano'),
            ]
            for name, options, script, expected in checks:
                master, slave = os.openpty()
                try:
                    result = subprocess.run(ssh + options + ['root@127.0.0.1', script], stdin=slave,
                                            capture_output=True, text=True, timeout=180)
                finally:
                    os.close(slave)
                    os.close(master)
                (evidence / f'{name}.txt').write_text(result.stdout + result.stderr)
                passed = result.returncode == 0 and expected in result.stdout
                results.append(dict(name=name, passed=passed, exit_code=result.returncode))
                if not passed:
                    raise RuntimeError(f'{name} failed: {result.stdout}{result.stderr}')
            denied = subprocess.run(['ssh', '-p', str(port), '-o', 'BatchMode=yes', '-o', 'IdentityAgent=none',
                                     '-o', 'IdentityFile=none', '-o', 'StrictHostKeyChecking=yes',
                                     '-o', f'UserKnownHostsFile={work / "known_hosts"}',
                                     'root@127.0.0.1', 'true'], capture_output=True, text=True, timeout=15)
            results.append(dict(name='unauthenticated-rejected', passed=denied.returncode == 255
                                and 'Permission denied' in denied.stderr, exit_code=denied.returncode))
            if not results[-1]['passed']:
                raise RuntimeError('unauthenticated rejection not established')
            if persistent:
                helper = (root / 'assets/rootfs/mibox-persistent-console').read_text().replace('\r\n', '\n')
                def remote(script, input_text=None):
                    result = subprocess.run(ssh + ['root@127.0.0.1', script], input=input_text,
                                            capture_output=True, text=True, timeout=180)
                    with (evidence / 'persistence.txt').open('a') as stream:
                        stream.write(result.stdout + result.stderr)
                    if result.returncode != 0:
                        raise RuntimeError('persistence check failed: ' + result.stdout + result.stderr)
                    return result.stdout
                def activate():
                    remote('cat > /sbin/mibox-persistent-console && chmod 755 /sbin/mibox-persistent-console', helper)
                    remote('/sbin/mibox-persistent-console start --qemu')
                activate()
                master, slave = os.openpty()
                try:
                    terminal = subprocess.run(ssh + ['-tt', 'root@127.0.0.1',
                        'test -t 0 && test -t 1 && test "$SHELL" = /bin/ash && test -f /etc/mibox-persistent-root && echo PERSISTENT_PTY_OK'],
                        stdin=slave, capture_output=True, text=True, timeout=30)
                finally:
                    os.close(master)
                    os.close(slave)
                if terminal.returncode != 0 or 'PERSISTENT_PTY_OK' not in terminal.stdout:
                    raise RuntimeError('persistent chroot PTY failed')
                remote('test -f /etc/mibox-persistent-root && apk add --no-cache curl coreutils && df -Pk / && echo MIBOX_PERSISTENCE_SENTINEL > /etc/mibox-console-test && curl --version')
                remote('chroot /proc/1/root /sbin/mibox-persistent-console stop --qemu')
                process.terminate()
                process.wait(timeout=10)
                log.close()
                log = open(evidence / 'serial-reboot.log', 'wb')
                (work / 'known_hosts').unlink()
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    probe = subprocess.run(ssh + ['root@127.0.0.1', 'echo READY'], capture_output=True, text=True, timeout=10)
                    if probe.returncode == 0:
                        break
                    time.sleep(1)
                else:
                    raise RuntimeError('second QEMU boot SSH failed')
                activate()
                retained = remote('grep -qx MIBOX_PERSISTENCE_SENTINEL /etc/mibox-console-test && apk info -e curl && curl --version && echo PERSISTENCE_REBOOT_OK')
                if 'PERSISTENCE_REBOOT_OK' not in retained:
                    raise RuntimeError('persistent package/config verification failed')
                remote('chroot /proc/1/root /sbin/mibox-persistent-console stop --qemu')
                results.append(dict(name='persistent-package-and-config-across-two-boots', passed=True, exit_code=0))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
            (evidence / 'result.json').write_text(json.dumps(dict(
                scope='QEMU generic ARM only; not stock 3.10.33 or physical MiBOX proof',
                physical_rootfs_sha256=hashlib.sha256((root / 'target/mibox-rootfs-console/initramfs.NOT_READY.cpio.gz').read_bytes()).hexdigest(),
                qemu_fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                checks=results, all_passed=len(results) == (7 if persistent else 6) and all(r['passed'] for r in results)), indent=2) + '\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--persistent', action='store_true')
    args = parser.parse_args()
    main(Path(__file__).resolve().parents[1], args.private_key, args.persistent)
