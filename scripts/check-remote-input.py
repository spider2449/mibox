"""Capture a bounded IR evdev stream without injecting keys or changing mappings."""
import argparse
import datetime
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

from console_ssh import trusted_public_key

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--private-key', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
evidence = root / 'artifacts/hardware-validation' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S') / 'remote-input'
evidence.mkdir(parents=True)

def run(name, command, timeout=30):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(name + ': exit ' + str(result.returncode))
    return result.stdout.replace('\r', '').strip()

usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
public = trusted_public_key(root, args.private_key, run)
boot = run('usb-boot-id', usb + ['cat /proc/sys/kernel/random/boot_id'])
known = evidence / 'known_hosts'
known.write_text('192.168.1.222 ' + ' '.join(public) + '\n')
with tempfile.TemporaryDirectory(prefix='mibox-input-key-') as directory:
    key = Path(directory) / 'key'
    shutil.copyfile(args.private_key, key)
    key.chmod(0o600)
    ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
           '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
           '-o', 'ConnectTimeout=10', 'root@192.168.1.222']
    if run('ssh-boot-id', ssh + ['cat /proc/sys/kernel/random/boot_id']) != boot:
        raise RuntimeError('USB/SSH boot mismatch')
    run('guard', ssh + ['set -eu; test "$(uname -m)" = armv7l; test "$(cat /proc/sys/kernel/osrelease)" = 3.10.33; test "$(cat /sys/class/input/event0/device/name)" = ir_meson6; cat /proc/bus/input/devices'])
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    print('IR capture active for 60 seconds', flush=True)
    result = subprocess.run(ssh + ['timeout -s TERM -k 2 60 /bin/busybox dd if=/dev/input/event0 bs=16 count=128'],
                            capture_output=True, timeout=70)
    (evidence / 'events.bin').write_bytes(result.stdout)
    (evidence / 'stderr.txt').write_bytes(result.stderr)
    events = []
    if len(result.stdout) % 16:
        raise RuntimeError('Unexpected ARM32 input_event byte count')
    for seconds, micros, kind, code, value in struct.iter_unpack('<iiHHi', result.stdout):
        events.append(dict(seconds=seconds, microseconds=micros, type=kind, code=code, value=value))
    keys = [event for event in events if event['type'] == 1]
    proof = dict(boot_id=boot, started=started, exit_code=result.returncode,
                 capture_ended_by_deadline=result.returncode == 124,
                 capture_complete=result.returncode in [0, 124], key_events=keys, events=events,
                 status='OBSERVED' if keys else 'NOT_OBSERVED',
                 limitation='Awake input evidence only; suspend wake capability is not established')
    (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(dict(status=proof['status'], key_event_count=len(keys),
                          evidence=str(evidence), capture_complete=proof['capture_complete']), indent=2))
