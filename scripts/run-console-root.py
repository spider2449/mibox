#!/usr/bin/env python3
"""Run a local shell script as root on the pinned RAM console over SSH.

Reuses the launcher's USB-authenticated host-key bootstrap. Evidence goes to
artifacts/console-root/<timestamp>-<name>/. Usage (inside WSL):
  python3 scripts/run-console-root.py --private-key KEY --name NAME SCRIPT
"""
import argparse
import datetime
import json
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from console_ssh import trusted_public_key  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--private-key', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument("--arg", action="append", default=[])
    parser.add_argument('script')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    evidence = root / 'artifacts/console-root' / (stamp + '-' + args.name)
    evidence.mkdir(parents=True)
    script = Path(args.script).read_text()
    shutil.copyfile(args.script, evidence / 'script.sh')
    records = []

    def run(name, command, timeout=30, input_text=None):
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=timeout, input=input_text)
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        records.append(dict(name=name, exit_code=result.returncode))
        if result.returncode != 0:
            raise RuntimeError(name + ': ' + result.stdout + result.stderr)
        return result.stdout.replace('\r', '').strip()

    usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
    if 'ID=mibox-custom' not in run('usb-identity', usb + ['cat /etc/os-release']).splitlines():
        raise SystemExit('custom console not running')
    public = trusted_public_key(root, args.private_key, run)
    known = evidence / 'known_hosts'
    known.write_text('192.168.1.222 ' + ' '.join(public[:2]) + '\n')
    with tempfile.TemporaryDirectory(prefix='mibox-owner-') as directory:
        key = Path(directory) / 'key'
        shutil.copyfile(args.private_key, key)
        key.chmod(0o600)
        ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
               '-o', 'ConnectTimeout=10', 'root@192.168.1.222', 'sh -s ' + ' '.join(shlex.quote(a) for a in args.arg)]
        result = subprocess.run(ssh, capture_output=True, text=True,
                                timeout=args.timeout, input=script)
    (evidence / 'output.txt').write_text(result.stdout + result.stderr)
    records.append(dict(name='script', exit_code=result.returncode))
    (evidence / 'result.json').write_text(json.dumps(dict(checks=records), indent=2) + '\n')
    sys.stdout.write(result.stdout + result.stderr)
    print('EVIDENCE', evidence)
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())
