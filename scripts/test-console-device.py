"""Verify SSH, PTY and package installation on the running physical RAM system.

Run in WSL with the Windows owner's SSH key. Host key trust comes from the
authenticated USB ADB connection, never an unauthenticated network key scan.
Leaves the console running; does not reboot, flash or mount persistent storage.
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from console_ssh import trusted_public_key


def main(root, private_key):
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    evidence = root / 'artifacts/console-ssh' / ('device-' + stamp)
    evidence.mkdir(parents=True)
    adb = str(root / 'phone-tools/platform-tools/adb.exe')
    records = []
    manifest = json.loads((root / 'target/mibox-rootfs-console/manifest.json').read_text())

    def run(name, command, timeout=30, expected_exit=0, pty=False):
        master, slave = os.openpty()
        try:
            result = subprocess.run(command, stdin=slave if pty else subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=timeout)
        finally:
            os.close(master)
            os.close(slave)
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        record = dict(name=name, exit_code=result.returncode, passed=result.returncode == expected_exit)
        records.append(record)
        if not record['passed']:
            raise RuntimeError(f'{name} failed: {result.stdout}{result.stderr}')
        return result.stdout.replace('\r', '').strip()

    proof = dict(scope='physical MiBOX1S, temporary RAM userspace', checks=records,
                 all_passed=False, flash_command_sent=False, persistent_storage_mounted=False,
                 rootfs_sha256=manifest['gzip_sha256'])
    try:
        usb = [adb, '-s', '248243005297', 'shell']
        release = run('usb-identity', usb + ['cat /etc/os-release'])
        if 'ID=mibox-custom' not in release.splitlines():
            raise RuntimeError('custom RAM system required')
        boot_id = run('usb-boot-id', usb + ['cat /proc/sys/kernel/random/boot_id'])
        proof['boot_id'] = boot_id
        fields = trusted_public_key(root, private_key, run)
        with tempfile.TemporaryDirectory(prefix='mibox-ssh-') as directory:
            work = Path(directory)
            key = work / 'owner-key'
            shutil.copyfile(private_key, key)
            key.chmod(0o600)
            known = work / 'known_hosts'
            known.write_text('192.168.1.222 ' + ' '.join(fields[:2]) + '\n')
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=10']
            def remote(name, script, pty=False, timeout=30):
                return run(name, ssh + (['-tt'] if pty else []) + ['root@192.168.1.222', script], timeout, pty=pty)
            observed = remote('ssh-identity', 'id; uname -r; cat /proc/sys/kernel/random/boot_id; cat /proc/mounts')
            if boot_id not in observed or '3.10.33' not in observed or 'uid=0(root)' not in observed:
                raise RuntimeError('SSH and USB boot/kernel/root identity mismatch')
            if '/dev/block/' in observed or '/dev/mmcblk' in observed:
                raise RuntimeError('unexpected block filesystem mount')
            utc = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            remote('clock-from-host', "date -u -s '" + utc + "'")
            for index, path in enumerate(['/init', '/bin/mibox', '/bin/busybox', '/sbin/apk', '/usr/sbin/dropbear']):
                digest = remote('binary-' + str(index), 'sha256sum ' + path).split()[0]
                if digest != manifest['files'][path.lstrip('/')]['sha256']:
                    raise RuntimeError('physical executable provenance mismatch: ' + path)
            if 'MIBOX_PTY_OK' not in remote('interactive-pty', 'test -t 0 && test -t 1 && tty && echo MIBOX_PTY_OK', pty=True):
                raise RuntimeError('interactive PTY missing')
            remote('dns', 'nslookup dl-cdn.alpinelinux.org', timeout=60)
            installed = remote('package-install', 'apk update && apk add --no-cache nano curl && nano --version && curl --version', timeout=180)
            if 'GNU nano' not in installed or 'curl ' not in installed:
                raise RuntimeError('installed programs did not execute')
            remote('https', 'curl --fail --max-time 30 -I https://dl-cdn.alpinelinux.org/alpine/v3.22/main/armv7/APKINDEX.tar.gz', timeout=40)
            run('unauthenticated-rejected', ['ssh', '-o', 'BatchMode=yes', '-o', 'IdentityAgent=none',
                '-o', 'IdentityFile=none', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                '-o', 'ConnectTimeout=10', 'root@192.168.1.222', 'true'], expected_exit=255)
            if 'Permission denied' not in (evidence / 'unauthenticated-rejected.txt').read_text():
                raise RuntimeError('authentication rejection not established')
            ready = remote('restart-readiness', '/bin/mibox reboot-android --check')
            if ready != 'MIBOX_RESTART_READY boot_id=' + boot_id:
                raise RuntimeError('software return is not ready')
            if remote('final-boot-id', 'cat /proc/sys/kernel/random/boot_id') != boot_id:
                raise RuntimeError('boot identity changed during testing')
        proof['all_passed'] = True
        print('PHYSICAL_CONSOLE_PASS: ' + str(evidence))
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    args = parser.parse_args()
    main(Path(__file__).resolve().parents[1], args.private_key)
