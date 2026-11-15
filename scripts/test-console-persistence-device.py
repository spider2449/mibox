"""Record and verify installed software/configuration across real device boots."""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from console_ssh import trusted_public_key


def main(root, private_key, baseline):
    evidence = root / 'artifacts/console-ssh' / ('persistence-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    evidence.mkdir(parents=True)
    proof = dict(phase='verify' if baseline else 'record', passed=False)
    def run(name, command, timeout=30, pty=False):
        master, slave = os.openpty()
        try:
            result = subprocess.run(command, stdin=slave if pty else subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=timeout)
        finally:
            os.close(master)
            os.close(slave)
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            raise RuntimeError(name + ': ' + result.stdout + result.stderr)
        return result.stdout.replace('\r', '').strip()
    try:
        usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
        public = trusted_public_key(root, private_key, run)
        boot_id = run('usb-boot-id', usb + ['cat /proc/sys/kernel/random/boot_id'])
        proof['boot_id'] = boot_id
        with tempfile.TemporaryDirectory(prefix='mibox-persistence-') as directory:
            work = Path(directory)
            key = work / 'key'
            shutil.copyfile(private_key, key)
            key.chmod(0o600)
            known = work / 'known_hosts'
            known.write_text('192.168.1.222 ' + ' '.join(public[:2]) + '\n')
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=10', 'root@192.168.1.222']
            def remote(name, script, timeout=30):
                return run(name, ssh + [script], timeout)
            remote('persistent-root', 'test -f /etc/mibox-persistent-root && df -Pk / && cat /proc/sys/kernel/random/boot_id')
            terminal = run('persistent-pty', ssh[:-1] + ['-tt', ssh[-1],
                'test -t 0 && test -t 1 && test "$SHELL" = /bin/ash && test -f /etc/mibox-persistent-root && echo PERSISTENT_PTY_OK'], pty=True)
            if 'PERSISTENT_PTY_OK' not in terminal:
                raise RuntimeError('persistent terminal verification failed')
            if baseline:
                original = json.loads(baseline.read_text())
                if not original['passed'] or original['phase'] != 'record' or original['boot_id'] == boot_id:
                    raise RuntimeError('a passing baseline and different actual boot are required')
                proof['baseline'] = str(baseline)
                proof['token'] = original['token']
            else:
                proof['token'] = str(uuid.uuid4())
                remote('persistent-install', 'apk add --no-cache less && less --version', 180)
                remote('write-config', 'test ! -e /etc/mibox-console-persistence-test && printf "%s\\n" ' + proof['token'] + ' > /etc/mibox-console-persistence-test && sync')
            proof['hashes'] = remote('persistent-hashes', 'sha256sum /usr/bin/less /usr/bin/nano /usr/bin/curl /lib/apk/db/installed /etc/mibox-console-persistence-test')
            token = remote('read-config', 'cat /etc/mibox-console-persistence-test')
            if token != proof['token']:
                raise RuntimeError('configuration token did not survive')
            if baseline and proof['hashes'] != original['hashes']:
                raise RuntimeError('package executable/database/configuration hashes changed')
            remote('installed-programs', 'less --version && nano --version && curl --version')
        proof['passed'] = True
        print('PHYSICAL_PERSISTENCE_' + proof['phase'].upper() + '_PASS: ' + str(evidence))
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    main(Path(__file__).resolve().parents[1], args.private_key, args.baseline)
