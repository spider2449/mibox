"""Test the RAM PID1 control channel and actual normal restart in a diskless guest."""
import argparse
import hashlib
import json
import os
import selectors
import subprocess
import time
from pathlib import Path


def run(root, guard):
    evidence = root / 'artifacts/qemu-restart' / ('platform-guard' if guard else 'normal-restart')
    evidence.mkdir(parents=True, exist_ok=True)
    initramfs = root / 'target/qemu-restart/initramfs.cpio.gz'
    command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15',
               '-m', '256', '-nic', 'none', '-display', 'none', '-monitor', 'none',
               '-serial', 'stdio', '-no-reboot', '-kernel', str(root / 'phone-tools/qemu/vmlinuz'),
               '-initrd', str(initramfs), '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0 '
               + ('mibox.test_restart_guard=1' if guard else 'mibox.test_restart=1')]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    log = bytearray()
    sent = False
    failure = None
    observed_exit = None
    deadline = time.monotonic() + 60
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(0.25):
                block = os.read(key.fileobj.fileno(), 65536)
                if block:
                    log.extend(block)
                if not sent and b'MIBOX_RAM_CONTROL_READY' in log and b'mibox> ' in log:
                    process.stdin.write(b'restartprobe\n')
                    process.stdin.flush()
                    sent = True
            if guard and b'MIBOX_QEMU_RESTART_PLATFORM_GUARD_OK' in log and log.endswith(b'mibox> '):
                if b'Restarting system' in log or process.poll() is not None:
                    raise RuntimeError('platform guard rebooted the guest')
                break
            if not guard and process.poll() is not None:
                observed_exit = process.wait(timeout=5)
                # Drain bytes queued before process exit, including the kernel restart line.
                log.extend(process.stdout.read())
                if observed_exit != 0 or b'MIBOX_QEMU_RESTART_CHECKS_OK' not in log or b'reboot: Restarting system' not in log:
                    raise RuntimeError('guest exit did not establish the tested restart')
                break
        else:
            raise RuntimeError('QEMU restart test timed out')
    except Exception as error:
        failure = str(error)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        selector.close()
        (evidence / 'console.log').write_bytes(log)
        (evidence / 'result.json').write_text(json.dumps(dict(
            command=command, failure=failure, passed=failure is None,
            initramfs_sha256=hashlib.sha256(initramfs.read_bytes()).hexdigest(),
            kernel_sha256=hashlib.sha256((root / 'phone-tools/qemu/vmlinuz').read_bytes()).hexdigest(),
            platform_guard=guard, guest_exit_before_host_cleanup=observed_exit,
            scope='Generic QEMU ARM only; not physical MiBOX Android return.'), indent=2) + '\n')
    if failure:
        raise SystemExit(failure)
    print('QEMU restart test passed: ' + ('platform guard' if guard else 'UID2000 request and kernel restart'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    run(args.root, True)
    run(args.root, False)
