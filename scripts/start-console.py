"""Boot the pinned RAM console if needed, then activate its persistent userspace.

WSL host launcher. SSH host identity is pinned from authenticated USB ADB.
Only the server's public key is retained in evidence; the owner key stays local.
"""
import argparse
import datetime
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from console_ssh import trusted_public_key


def main(root, private_key, boot_if_needed, stop=False):
    evidence = root / 'artifacts/console-ssh' / ('launcher-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    evidence.mkdir(parents=True)
    adb = str(root / 'phone-tools/platform-tools/adb.exe')
    records = []
    def run(name, command, timeout=30, input_text=None):
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, input=input_text)
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        records.append(dict(name=name, exit_code=result.returncode))
        if result.returncode != 0:
            raise RuntimeError(name + ': ' + result.stdout + result.stderr)
        return result.stdout.replace('\r', '').strip()
    proof = dict(checks=records, persistent_ready=False, stopped=False)
    try:
        usb = [adb, '-s', '248243005297', 'shell']
        identity = run('usb-identity', usb + ['cat /etc/os-release'])
        if 'ID=mibox-custom' not in identity.splitlines():
            if not boot_if_needed or stop:
                raise RuntimeError('custom console not running; use -Boot to start it')
            fingerprint = run('android-fingerprint', usb + ['getprop ro.build.fingerprint'])
            if fingerprint != 'Xiaomi/casablanca_icntv/casablanca:4.4.2/KOT49H/2876:user/release-keys':
                raise RuntimeError('unexpected Android identity')
            script = run('boot-script-path', ['wslpath', '-w', str(root / 'scripts/ram-boot.ps1')])
            # Inherit stdout for the existing bounded transfer progress notices.
            subprocess.run(['powershell.exe', '-NoProfile', '-File', script, '-Action', 'Boot',
                            '-Candidate', 'Console', '-ControlTimeoutMilliseconds', '10000'], check=True, timeout=3900)
            identity = run('usb-identity-after-boot', usb + ['cat /etc/os-release'])
            if 'ID=mibox-custom' not in identity.splitlines():
                raise RuntimeError('custom identity missing after boot')
        public = trusted_public_key(root, private_key, run)
        known = evidence / 'known_hosts'
        known.write_text('192.168.1.222 ' + ' '.join(public[:2]) + '\n')
        with tempfile.TemporaryDirectory(prefix='mibox-owner-') as directory:
            key = Path(directory) / 'key'
            shutil.copyfile(private_key, key)
            key.chmod(0o600)
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=10', 'root@192.168.1.222']
            if stop:
                run('persistent-stop', ssh + ['chroot /proc/1/root /sbin/mibox-persistent-console stop'], timeout=60)
                proof['stopped'] = True
            else:
                utc = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
                run('clock-from-host', ssh + ["date -u -s '" + utc + "'"])
                state = run('persistent-state', ssh + ['if test -f /etc/mibox-persistent-root; then echo PERSISTENT; else echo RAM; fi'])
                if state != 'PERSISTENT':
                    helper = (root / 'assets/rootfs/mibox-persistent-console').read_text().replace('\r\n', '\n')
                    run('upload-persistent-helper', ssh + ['cat > /sbin/mibox-persistent-console && chmod 755 /sbin/mibox-persistent-console'], input_text=helper)
                    run('data-inspection', ssh + ['cat /sys/class/block/data/dev /sys/class/block/data/size; cat /proc/mounts'])
                    run('persistent-start', ssh + ['/sbin/mibox-persistent-console start'], timeout=120)
                # GNU df handles this vendor kernel's chroot mount paths; the
                # BusyBox df applet follows an inaccessible outer mount path.
                run('persistent-coreutils', ssh + ['apk info -e coreutils >/dev/null 2>&1 || apk add --no-cache coreutils'], timeout=180)
                run('persistent-ready', ssh + ['test -f /etc/mibox-persistent-root && apk --version && df -Pk /'])
                proof['persistent_ready'] = True
        windows_known = run('known-hosts-path', ['wslpath', '-w', str(known)])
        (root / 'target/console-known-hosts-path.txt').write_text(windows_known + '\n')
        print(('PERSISTENT_CONSOLE_STOPPED' if stop else 'PERSISTENT_CONSOLE_READY') + ': ' + str(evidence))
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--boot-if-needed', action='store_true')
    parser.add_argument('--stop', action='store_true')
    args = parser.parse_args()
    main(Path(__file__).resolve().parents[1], args.private_key, args.boot_if_needed, args.stop)
