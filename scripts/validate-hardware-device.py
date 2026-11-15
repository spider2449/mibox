"""Collect bounded physical inventory over USB-authenticated SSH (run in WSL)."""
import argparse
import base64
import csv
import datetime
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path

from console_ssh import trusted_public_key


INVENTORY = r'''
set -eu
test -f /etc/mibox-persistent-root
test "$(cat /proc/sys/kernel/osrelease)" = 3.10.33
echo '=== identity ==='
cat /proc/1/root/etc/os-release
cat /proc/sys/kernel/random/boot_id
uname -a
cat /proc/cmdline
echo '=== device tree ==='
for f in model compatible; do
  if test -f /proc/device-tree/$f; then tr '\000' '\n' < /proc/device-tree/$f; fi
done
echo '=== mounts ==='
cat /proc/mounts
cat /proc/self/mountinfo
echo '=== storage ==='
df -Pk / /proc/1/root/tmp
stat -f / /proc/1/root/tmp
readlink -f /root
cat /proc/partitions
cat /sys/class/block/data/dev /sys/class/block/data/size
echo '=== persistent sentinels ==='
sha256sum /usr/bin/less /usr/bin/nano /usr/bin/curl /lib/apk/db/installed /etc/mibox-console-persistence-test
echo '=== memory CPU IO ==='
cat /proc/meminfo /proc/cpuinfo /proc/diskstats
echo '=== routes ==='
ip addr
ip route
ip rule
echo '=== thermal and frequency ==='
for d in /sys/class/thermal/thermal_zone* /sys/class/hwmon/hwmon* /sys/devices/system/cpu/cpu*/cpufreq; do
  test -d "$d" || continue
  echo "PATH=$d"
  for f in "$d"/type "$d"/temp "$d"/name "$d"/temp*_input "$d"/temp*_label "$d"/temp*_crit "$d"/trip_point_* "$d"/scaling_* "$d"/cpuinfo_*; do
    test -f "$f" && test -r "$f" || continue
    echo "FILE=$f"
    cat "$f" || echo READ_FAILED
  done
done
echo '=== USB ==='
for d in /sys/bus/usb/devices/*; do
  test -d "$d" || continue
  echo "PATH=$d"
  for f in idVendor idProduct manufacturer product serial speed busnum devnum bMaxPower; do
    if test -r "$d/$f"; then echo "FILE=$f"; cat "$d/$f"; fi
  done
done
cat /proc/bus/input/devices
echo '=== decoder and output nodes ==='
ls -l /dev/am* /dev/video* /dev/fb* /dev/snd /dev/rtc* /dev/input 2>/dev/null || :
for f in /sys/class/graphics/fb*/virtual_size /sys/class/graphics/fb*/bits_per_pixel /sys/class/graphics/fb*/stride; do
  if test -r "$f"; then echo "FILE=$f"; cat "$f"; fi
done
cat /proc/modules
echo '=== available programs ==='
for program in python3 ffmpeg ffprobe aplay strace timeout sha256sum; do command -v "$program" || :; done
echo '=== suspend inventory; no suspend requested ==='
for f in /sys/power/state /sys/power/wakeup_count /proc/acpi/wakeup /sys/class/rtc/rtc*/name /sys/class/rtc/rtc*/wakealarm /sys/kernel/debug/wakeup_sources; do
  if test -r "$f"; then echo "FILE=$f"; timeout -k 1 2 cat "$f" || echo READ_FAILED_OR_TIMED_OUT; fi
done
for f in /sys/devices/platform/*/power/wakeup; do
  if test -r "$f"; then echo "FILE=$f"; cat "$f"; fi
done
echo INVENTORY_COMPLETE
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--storage-helper', type=Path, help='Run the bounded compiled storage helper after inventory')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    evidence = root / 'artifacts/hardware-validation' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S') / 'baseline'
    evidence.mkdir(parents=True)
    records = []
    proof = dict(physical=True, inventory_complete=False, evidence=str(evidence))

    def run(name, command, timeout=30, input_text=None):
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, input=input_text)
        except subprocess.TimeoutExpired as error:
            (evidence / (name + '.txt')).write_bytes((error.stdout or b'') + (error.stderr or b''))
            records.append(dict(name=name, started=started, timeout=True, output_complete=False))
            raise
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        records.append(dict(name=name, started=started, ended=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                            exit_code=result.returncode, output_complete=True))
        if result.returncode:
            raise RuntimeError(f'{name}: exit {result.returncode}; see retained output')
        return result.stdout.replace('\r', '').strip()

    try:
        usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
        public = trusted_public_key(root, args.private_key, run)
        known = evidence / 'known_hosts'
        known.write_text('192.168.1.222 ' + ' '.join(public) + '\n')
        boot_id = run('usb-boot-id', usb + ['cat /proc/sys/kernel/random/boot_id'])
        with tempfile.TemporaryDirectory(prefix='mibox-inventory-') as directory:
            import shutil
            key = Path(directory) / 'key'
            shutil.copyfile(args.private_key, key)
            key.chmod(0o600)
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5',
                   '-o', 'ServerAliveCountMax=3', 'root@192.168.1.222']
            actual = run('ssh-boot-id', ssh + ['cat /proc/sys/kernel/random/boot_id'])
            if actual != boot_id:
                raise RuntimeError('USB/SSH boot identity mismatch')
            output = run('inventory', ssh + ['timeout 45 sh -s'], timeout=55, input_text=INVENTORY)
            run('kernel-before', ssh + ['dmesg'], timeout=30)
            proof.update(boot_id=boot_id, inventory_complete=output.endswith('INVENTORY_COMPLETE'),
                         inventory_script_sha256=hashlib.sha256(INVENTORY.encode()).hexdigest(),
                         limitations=['Baseline is inventory; optional bounded storage is reported separately; no suspend or stress',
                                      'Sensor units, safe limits, decoder ABI and wake reliability require assessment'])
            if not proof['inventory_complete']:
                raise RuntimeError('inventory completion marker missing')
            metrics = []
            snapshot = r'''set -eu
cat /proc/sys/kernel/random/boot_id
cat /proc/uptime /proc/loadavg
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached):' /proc/meminfo
echo PROCESSES=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
for f in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  if test -r "$f"; then echo "METRIC=$f"; cat "$f"; fi
done
cat /proc/diskstats
'''
            for number in range(6):
                started = time.monotonic()
                sampled = datetime.datetime.now(datetime.timezone.utc).isoformat()
                text = run(f'metric-{number:02}', ssh + ['timeout 8 sh -s'], timeout=12, input_text=snapshot)
                lines = text.splitlines()
                if not lines or lines[0] != boot_id:
                    raise RuntimeError('boot identity changed during baseline monitoring')
                memory = {}
                for line in lines:
                    if ':' in line and line.split(':', 1)[0] in ['MemTotal', 'MemFree', 'MemAvailable', 'Buffers', 'Cached']:
                        name, value = line.split(':', 1)
                        memory[name] = value.strip().split()[0]
                metrics.append(dict(host_utc=sampled, boot_id=boot_id, uptime_seconds=lines[1].split()[0],
                                    load1=lines[2].split()[0], MemAvailable_kib=memory.get('MemAvailable', 'UNKNOWN'),
                                    MemFree_kib=memory.get('MemFree', 'UNKNOWN'), Buffers_kib=memory.get('Buffers', 'UNKNOWN'),
                                    Cached_kib=memory.get('Cached', 'UNKNOWN')))
                if number < 5:
                    time.sleep(max(0, 5 - (time.monotonic() - started)))
            with (evidence / 'metrics.csv').open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=list(metrics[0]))
                writer.writeheader()
                writer.writerows(metrics)
            proof['baseline_monitor'] = dict(samples=len(metrics), requested_interval_seconds=5,
                                             full_15_minute_idle='NOT_TESTED')
            if args.storage_helper:
                helper = args.storage_helper.read_bytes()
                digest = hashlib.sha256(helper).hexdigest()
                token = evidence.parent.name
                remote_helper = '/proc/1/root/tmp/mibox-storage-check-' + token
                test_directory = '/root/mibox-hardware-test-' + token
                sentinels = 'sha256sum /usr/bin/less /usr/bin/nano /usr/bin/curl /lib/apk/db/installed /etc/mibox-console-persistence-test'
                before = run('sentinels-before', ssh + [sentinels])
                # Require the known data device, ext filesystem, and RAM helper location.
                guard = ('set -eu; test -f /etc/mibox-persistent-root; '
                         'test "$(cat /sys/class/block/data/dev)" = 179:11; '
                         'test "$(cat /sys/class/block/data/size)" = 5168640; '
                         'test "$(stat -c %d /root)" = 45835; '
                         'test "$(stat -f -c %t /root)" = ef53; '
                         'case "$(stat -f -c %t /proc/1/root/tmp)" in 1021994|858458f6) ;; *) exit 1;; esac; '
                         f'test ! -e {remote_helper}; test ! -e {test_directory}; '
                         'df -Pk /; readlink -f /root; cat /proc/mounts')
                run('storage-guard', ssh + [guard])
                proof['storage'] = dict(helper_sha256=digest, directory=test_directory, status='STARTED')
                try:
                    run('helper-upload', ssh + [f'umask 077; set -C; base64 -d > {remote_helper}'],
                        input_text=base64.b64encode(helper).decode())
                    actual_hash = run('helper-hash', ssh + [f'sha256sum {remote_helper}']).split()[0]
                    if actual_hash != digest:
                        raise RuntimeError('uploaded helper hash mismatch')
                    run('helper-executable', ssh + [f'chmod 700 {remote_helper}'])
                    output = run('storage-short', ssh + [f'timeout -s TERM -k 5 180 {remote_helper} {test_directory}'], timeout=200)
                    proof['storage']['status'] = 'PASS' if 'STORAGE_SHORT_PASS' in output and output.count('PASS round=') == 30 else 'FAIL'
                    if proof['storage']['status'] != 'PASS':
                        raise RuntimeError('storage completion records missing')
                finally:
                    # Exact names only. Never recurse into an unexpected directory.
                    cleanup = (f'set -eu; rm -f {remote_helper}; '
                               f'if test -d {test_directory}; then '
                               f'rm -f {test_directory}/writing {test_directory}/reading; rmdir {test_directory}; fi; '
                               f'test ! -e {test_directory}; test ! -e {remote_helper}; df -Pk /')
                    run('storage-cleanup', ssh + [cleanup])
                after = run('sentinels-after', ssh + [sentinels])
                proof['storage']['existing_sentinels_unchanged'] = before == after
                run('kernel-after-storage', ssh + ['dmesg'])
                if before != after:
                    raise RuntimeError('existing sentinel hashes changed')
                proof['storage']['limitations'] = ['Cached reads; physical media reads not isolated',
                    'No reboot durability test, forced short-write injection or interrupted-writer test',
                    'No sudden power-loss test']
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'inventory.sh').write_text(INVENTORY)
        (evidence / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
        (evidence / 'baseline.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    main()
