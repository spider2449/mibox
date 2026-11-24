"""Host test of assets/rootfs/mibox-netwatch (plan item 9, 2026-11-21).

Runs the watcher with the Slim image's own ARM busybox (via qemu-arm binfmt)
inside an unprivileged user + network + mount namespace with a dummy eth0 and
a private sysfs. A dummy link has carrier whenever it is up; real PHY timing
is not covered. Cases:
  initial      address and default route present, watcher changes nothing
  down-up      link down drops the default route; after up the route returns
  admin-down   while down the watcher leaves the link down and adds nothing
  addr-lost    a flushed address and route are both restored
  foreign      an existing default route (other gateway) is left alone
Run under WSL: python3 scripts/test-netwatch.py
"""
import gzip
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INITRAMFS = ROOT / 'target/mibox-rootfs-slim-kernel-dev/initramfs.NOT_READY.cpio.gz'
APPLETS = ['sh', 'ip', 'grep', 'cat', 'sleep', 'mount', 'echo']

SCENARIO = r'''
set -u
mount -t sysfs sysfs /sys
ip link set lo up
ip link add eth0 type dummy
ip link set eth0 up
ip addr add 192.168.1.222/24 dev eth0
ip route add default via 192.168.1.1
defroute() { ip -4 route | grep '^default ' || true; }
wait_for() {  # wait_for SECONDS COMMAND...: poll until the command succeeds
    n=$(($1 * 10)); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
    return 1
}
has_route() { [ -n "$(defroute)" ]; }
has_addr() { ip -4 addr show dev eth0 | grep -q ' inet 192.168.1.222/24 '; }
sh "$WATCH" eth0 192.168.1.222/24 192.168.1.1 1 > "$LOG" 2>&1 &
watcher=$!
sleep 2.5
echo "initial route=[$(defroute)]"
ip link set eth0 down
echo "after-down route=[$(defroute)]"
ip link set eth0 up
if wait_for 5 has_route; then echo "down-up route=[$(defroute)]"; else echo "down-up route=MISSING"; fi
ip link set eth0 down
sleep 2.5
echo "admin-down route=[$(defroute)] state=$(cat /sys/class/net/eth0/operstate)"
ip link set eth0 up
wait_for 5 has_route || true
ip addr flush dev eth0
if wait_for 5 has_addr && wait_for 5 has_route; then
    echo "addr-lost addr=ok route=[$(defroute)]"
else
    echo "addr-lost FAILED"
fi
ip route del default
ip route add default via 192.168.1.254
sleep 2.5
echo "foreign route=[$(defroute)]"
kill "$watcher"
'''


def main():
    spec = importlib.util.spec_from_file_location('console', ROOT / 'scripts/build-console-rootfs.py')
    console = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(console)
    entries = console.unpack(gzip.decompress(INITRAMFS.read_bytes()))
    results = {}
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        bindir = work / 'bin'
        bindir.mkdir()
        busybox = bindir / 'busybox'
        busybox.write_bytes(entries['bin/busybox'][1])
        busybox.chmod(0o755)
        for applet in APPLETS:
            (bindir / applet).symlink_to('busybox')
        watch = work / 'mibox-netwatch'
        watch.write_bytes((ROOT / 'assets/rootfs/mibox-netwatch').read_bytes().replace(b'\r\n', b'\n'))
        log = work / 'watch.log'
        (work / 'lib').mkdir()
        (work / 'lib/ld-musl-armhf.so.1').write_bytes(entries['lib/ld-musl-armhf.so.1'][1])
        env = dict(PATH=str(bindir), WATCH=str(watch), LOG=str(log), QEMU_LD_PREFIX=str(work))
        out = subprocess.run(['/usr/bin/unshare', '-rnm', str(bindir / 'sh'), '-c', SCENARIO],
                             env=env, capture_output=True, text=True, timeout=120)
        lines = dict(line.split(' ', 1) for line in out.stdout.splitlines() if ' ' in line)
        expected = '[default via 192.168.1.1 dev eth0 ]'
        checks = {
            'initial': lines.get('initial') == 'route=' + expected,
            'down-drops-route': lines.get('after-down') == 'route=[]',
            'down-up': lines.get('down-up') == 'route=' + expected,
            'admin-down': lines.get('admin-down', '').startswith('route=[] state=down'),
            'addr-lost': lines.get('addr-lost') == 'addr=ok route=' + expected,
            'foreign': lines.get('foreign') == 'route=[default via 192.168.1.254 dev eth0 ]',
        }
        restored = log.read_text().splitlines() if log.exists() else []
        results = dict(exit_code=out.returncode, checks=checks, stdout=out.stdout.splitlines(),
                       stderr=out.stderr.splitlines(), watcher_log=restored,
                       busybox_sha256=__import__('hashlib').sha256(entries['bin/busybox'][1]).hexdigest())
    passed = out.returncode == 0 and all(checks.values())
    results['status'] = 'PASS' if passed else 'FAIL'
    print(json.dumps(results, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
