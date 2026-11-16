"""QEMU-only test of the RAM PID1 startup fail-safe. Never touches the Mi Box.

Build the four init variants on Windows first (normal build plus faults):
  cargo build --release
  MIBOX_FAULT=panic CARGO_TARGET_DIR=target/fault-panic cargo build --release --bin mibox-init
  (likewise usb, hang and kpanic)
Then run under WSL: python3 scripts/test-fail-safe-qemu.py
Each case boots a generic ARM kernel with -no-reboot, so a guest restart exits QEMU.
"""
import argparse
import gzip
import hashlib
import json
import os
import selectors
import subprocess
import time
from pathlib import Path

RELEASE = 'armv7-unknown-linux-musleabihf/release'
# Guest panic= for the kernel-panic case (MiBOX itself reads kernel.panic=20).
KPANIC_TIMEOUT_S = 5
# case -> (target dir, expected restart reason or None, minimum seconds before restart)
CASES = {
    'normal': ('target', None, 0),
    'panic': ('target/fault-panic', 'panic', 0),
    'usb': ('target/fault-usb', 'usb-setup', 0),
    'hang': ('target/fault-hang', 'usb-setup-deadline', 60),
    # PID1 exits on purpose: no fail-safe marker, the kernel panic timeout restarts.
    'kpanic': ('target/fault-kpanic', 'kernel-panic', KPANIC_TIMEOUT_S),
}
# The normal case must outlive the 60 s setup deadline without restarting.
NORMAL_OBSERVE_S = 75


def initramfs(root, init):
    archive = bytearray()

    def entry(name, mode, data=b'', major=0, minor=0):
        name = name.encode('ascii') + b'\0'
        fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(name), 0]
        archive.extend(b'070701' + ''.join(f'{f:08x}' for f in fields).encode('ascii'))
        archive.extend(name)
        archive.extend(bytes(-len(archive) % 4))
        archive.extend(data)
        archive.extend(bytes(-len(archive) % 4))

    for directory in ('dev', 'proc', 'sys', 'bin', 'etc', 'tmp'):
        entry(directory, 0o040755)
    entry('dev/console', 0o020600, major=5, minor=1)
    entry('init', 0o100755, init)
    entry('bin/mibox', 0o100755, (root / 'target' / RELEASE / 'mibox-userland').read_bytes())
    entry('etc/os-release', 0o100444, (root / 'assets/rootfs/os-release').read_bytes())
    entry('TRAILER!!!', 0)
    return gzip.compress(archive, mtime=0)


def run_case(root, name, evidence):
    directory, reason, minimum = CASES[name]
    init = (root / directory / RELEASE / 'mibox-init').read_bytes()
    out = evidence / name
    out.mkdir(parents=True, exist_ok=True)
    image = root / 'target/qemu-fail-safe' / name / 'initramfs.cpio.gz'
    image.parent.mkdir(parents=True, exist_ok=True)
    image.write_bytes(initramfs(root, init))
    command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15', '-m', '256',
               '-nic', 'none', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
               '-no-reboot', '-kernel', str(root / 'phone-tools/qemu/vmlinuz'),
               '-initrd', str(image), '-append',
               f'console=ttyAMA0,115200 rdinit=/init panic={KPANIC_TIMEOUT_S if name == "kpanic" else 0}']
    started = time.monotonic()
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    log = bytearray()
    failure = None
    restart_after = None
    limit = NORMAL_OBSERVE_S if reason is None else minimum + 60
    try:
        while time.monotonic() - started < limit:
            for key, _ in selector.select(0.25):
                log.extend(os.read(key.fileobj.fileno(), 65536))
            if process.poll() is not None:
                log.extend(process.stdout.read())
                restart_after = time.monotonic() - started
                break
        marker = f'MIBOX_FAIL_SAFE_RESTART reason={reason}'.encode()
        if reason is None:
            if restart_after is not None or b'MIBOX_FAIL_SAFE_RESTART' in log:
                failure = 'normal init restarted'
            elif b'MIBOX_SETUP_READY' not in log or b'mibox> ' not in log:
                failure = 'normal init did not reach its console'
        elif restart_after is None:
            failure = 'guest did not restart'
        elif reason == 'kernel-panic':
            if (b'MIBOX_KERNEL_PANIC_TEST' not in log or b'Attempted to kill init' not in log
                    or b'MIBOX_FAIL_SAFE_RESTART' in log):
                failure = 'kernel panic from PID1 exit not observed'
            elif restart_after < minimum:
                failure = f'restarted after {restart_after:.1f} s, before the {minimum} s panic timeout'
        elif marker not in log or b'reboot: Restarting system' not in log:
            failure = 'restart reason or kernel restart line missing'
        elif restart_after < minimum:
            failure = f'restarted after {restart_after:.1f} s, before the {minimum} s deadline'
        elif b'MIBOX_SETUP_READY' in log:
            failure = 'fault case reported setup ready'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        selector.close()
    (out / 'console.log').write_bytes(log)
    result = dict(case=name, command=command, passed=failure is None, failure=failure,
                  expected_reason=reason, guest_exit_after_s=restart_after,
                  init_sha256=hashlib.sha256(init).hexdigest(),
                  initramfs_sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
                  kernel_sha256=hashlib.sha256((root / 'phone-tools/qemu/vmlinuz').read_bytes()).hexdigest(),
                  scope='Generic QEMU ARM only; no USB function, no preboot window, no MiBOX hardware.')
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'{name}: {"PASS" if failure is None else "FAIL " + failure}')
    return failure is None


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('cases', nargs='*', default=list(CASES))
    args = parser.parse_args()
    evidence = args.evidence or args.root / 'artifacts/qemu-fail-safe'
    results = [run_case(args.root, case, evidence) for case in args.cases]
    raise SystemExit(0 if all(results) else 1)
