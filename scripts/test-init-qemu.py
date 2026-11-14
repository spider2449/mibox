"""Boot the real ARM init as PID1 in QEMU, then exercise its console."""
import argparse
import json
import os
import re
import selectors
import subprocess
import time
from pathlib import Path


def main(root, timeout, request_usb_acm, test_stock_adb=False, test_stock_adb_guard=False, test_stock_adb_auth=False,
         request_usb_adb=False, initramfs=None, rootfs_usb_adb_marker=False, evidence=None, test_hardware=False):
    evidence = evidence or root / ('artifacts/qemu-mibox-rootfs' if request_usb_adb else
                       'artifacts/qemu-adb-auth' if test_stock_adb_auth else
                       'artifacts/qemu-adb-guard' if test_stock_adb_guard else
                       'artifacts/qemu-adb' if test_stock_adb else 'artifacts/qemu')
    evidence.mkdir(parents=True, exist_ok=True)
    if initramfs is None:
        initramfs = root / ('target/qemu-adb-auth' if test_stock_adb_auth else
                           'target/qemu-adb' if test_stock_adb else 'target/qemu') / 'initramfs.cpio.gz'
    command = ['qemu-system-arm', '-machine', 'virt', '-cpu', 'cortex-a15',
               '-m', '256', '-nic', 'none', '-display', 'none', '-monitor', 'none',
               '-serial', 'stdio', '-no-reboot',
               '-kernel', str(root / 'phone-tools/qemu/vmlinuz'),
               '-initrd', str(initramfs),
               '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0' +
               (' mibox.usb_acm=1' if request_usb_acm else '') +
               (' mibox.test_adb=1' if test_stock_adb and not test_stock_adb_guard else '') +
               (' mibox.test_adb_auth=1' if test_stock_adb_auth else '') +
               (' mibox.usb_adb=1' if request_usb_adb and not rootfs_usb_adb_marker else '')]
    signing_key = root / 'target/qemu-adb-test-key.pem'
    if test_stock_adb_auth and not signing_key.is_file():
        raise SystemExit('Build the authenticated QEMU initramfs first; dedicated test key absent')
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    log = bytearray()
    stage_buffer = bytearray()
    stages = [
        (None, rb'MIBOX_INIT_CONSOLE_READY.*?mibox> '),
        (b'help\n', rb'help \| info \| uptime.*?mibox> '),
        (b'info\n', rb'pid=1 arch=arm.*?mibox> '),
        (b'uptime\n', rb'[0-9]+\.[0-9]+ [0-9]+\.[0-9]+.*?mibox> '),
        (b'health\n', rb'MIBOX_HEALTH_SNAPSHOT_V1.*?boot_id=[0-9a-f-]{36}.*?uptime_seconds=[0-9]+\.[0-9]+.*?pid1=init.*?root_fstype=rootfs.*?mem_total_kib=[0-9]+.*?mem_free_kib=[0-9]+.*?mem_available_kib=[0-9]+.*?mibox> '),
        (b'os\n', rb'ID=mibox-custom.*?uid=0 euid=0.*?mibox> '),
        (b'files\n', rb'bin.*?dev.*?etc.*?proc.*?sys.*?tmp.*?mibox> '),
        (b'reaptest\n', rb'REAP_OK pid=[0-9]+.*?mibox> '),
        (b'unknown-command\n', rb'Unknown command; type help\..*?mibox> '),
        (b'x'*300+b'\n', rb'MIBOX_INIT_CONSOLE_READY.*?mibox> '),
        (b'info\n', rb'pid=1 arch=arm.*?mibox> '),
    ]
    if test_stock_adb:
        expected = (rb'QEMU-only probe:.*?USERSPACE_COMMAND_FAILED.*?mibox> '
                    if test_stock_adb_guard else
                    rb'MIBOX_QEMU_ADB_CONSOLE_OK[^\n]*authenticated=true.*?mibox> '
                    if test_stock_adb_auth else rb'MIBOX_QEMU_ADB_CONSOLE_OK.*?mibox> ')
        stages.insert(6, (b'adbprobe\n', expected))
    if test_hardware:
        stages.insert(6, (b'hardware-selftest\n', rb'MIBOX_HARDWARE_PARSER_TEST_OK.*?HARDWARE_DIAGNOSTIC_EXIT=0.*?mibox> '))
        stages.insert(7, (b'hardware-guard\n', rb'FAIL stock kernel guard:.*?HARDWARE_DIAGNOSTIC_EXIT=1.*?mibox> '))
    index = 0
    deadline = time.monotonic()+timeout
    failure = None
    signed_challenge = False
    try:
        while index < len(stages):
            if time.monotonic() > deadline:
                raise RuntimeError(f'timed out at stage {index}')
            events = selector.select(0.25)
            if not events and process.poll() is not None:
                raise RuntimeError(f'QEMU exited early: {process.returncode}')
            for key, _ in events:
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    raise RuntimeError('QEMU console closed')
                log.extend(block)
                stage_buffer.extend(block)
                if test_stock_adb_auth and not signed_challenge:
                    challenge = re.search(rb'ADB_AUTH_TOKEN_HEX=([0-9a-f]{40})', stage_buffer)
                    if challenge:
                        signature = subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(signing_key),
                                                    '-pkeyopt', 'rsa_padding_mode:pkcs1', '-pkeyopt', 'digest:sha1'],
                                                   input=bytes.fromhex(challenge[1].decode('ascii')),
                                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                   check=True, timeout=5).stdout
                        if len(signature) != 256:
                            raise RuntimeError('unexpected RSA signature size')
                        process.stdin.write(signature.hex().encode('ascii') + b'\n')
                        process.stdin.flush()
                        signed_challenge = True
                if test_stock_adb and not test_stock_adb_guard and stages[index][0] == b'adbprobe\n' and b'USERSPACE_COMMAND_FAILED' in stage_buffer:
                    raise RuntimeError('stock ADB probe failed; see console transcript')
                if re.search(stages[index][1], stage_buffer, re.DOTALL):
                    index += 1
                    stage_buffer.clear()
                    if index < len(stages):
                        process.stdin.write(stages[index][0])
                        process.stdin.flush()
        if b'pid=1 arch=arm' not in log:
            raise RuntimeError('PID1 execution not confirmed')
        if test_stock_adb and not test_stock_adb_guard and b'MIBOX_QEMU_ADB_HEALTH_OK exit=0 boot_id=matched' not in log:
            raise RuntimeError('standalone toolbox health over ADB not confirmed')
        if request_usb_acm and b'USB ACM unavailable:' not in log:
            raise RuntimeError('expected no-gadget fallback was not exercised')
        if request_usb_adb and (b'USB ADB board guard:' not in log or b'MIBOX_USB_ADB_SPAWNED' in log):
            raise RuntimeError('candidate rootfs must reject QEMU before USB ADB setup')
        if test_stock_adb_guard and (b'MIBOX_QEMU_PROPERTY_AREA_READY' in log or b'ADB_BANNER=' in log):
            raise RuntimeError('probe performed initialization without required test flag')
        if test_stock_adb_auth and (not signed_challenge or b'MIBOX_QEMU_ADB_BAD_SIGNATURE_REJECTED' not in log):
            raise RuntimeError('negative signature and authorized challenge response not confirmed')
    except Exception as error:
        failure = str(error)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        selector.close()
        (evidence / 'console.log').write_bytes(log)
        (evidence / 'result.json').write_text(json.dumps({
            'command': command, 'passed_stages': index, 'total_stages': len(stages),
            'failure': failure, 'scope': 'Generic ARM QEMU only, not MiBOX1S hardware.'
            , 'requested_usb_acm': request_usb_acm, 'tested_stock_adb': test_stock_adb,
            'tested_stock_adb_guard': test_stock_adb_guard,
            'tested_stock_adb_auth': test_stock_adb_auth, 'signed_test_challenge': signed_challenge
            , 'standalone_adb_health_verified': b'MIBOX_QEMU_ADB_HEALTH_OK exit=0 boot_id=matched' in log
            , 'requested_usb_adb': request_usb_adb, 'rootfs_usb_adb_marker': rootfs_usb_adb_marker
        }, indent=2), encoding='utf-8')
    if failure:
        raise SystemExit(failure)
    print(f'QEMU PID1 console test passed: {index}/{len(stages)} stages')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--timeout', type=int, default=45)
    parser.add_argument('--request-usb-acm', action='store_true',
                        help='exercise UART fallback when generic QEMU has no Android gadget')
    parser.add_argument('--test-stock-adb', action='store_true', help='test stock recovery adbd on isolated guest loopback')
    parser.add_argument('--test-stock-adb-guard', action='store_true', help='verify probe refuses initialization without its test boot flag')
    parser.add_argument('--test-stock-adb-auth', action='store_true', help='verify invalid signature rejection and dedicated-key authentication')
    parser.add_argument('--request-usb-adb', action='store_true', help='verify candidate rootfs rejects USB setup on QEMU')
    parser.add_argument('--initramfs', type=Path, help='explicit local RAM rootfs candidate')
    parser.add_argument('--evidence', type=Path, help='retain a separate run without replacing earlier evidence')
    parser.add_argument('--rootfs-usb-adb-marker', action='store_true', help='verify the rootfs opt-in marker without adding a kernel USB flag')
    parser.add_argument('--test-hardware', action='store_true', help='test hardware helper parser and wrong-kernel rejection; no hardware access')
    args = parser.parse_args()
    if sum((args.test_stock_adb, args.test_stock_adb_guard, args.test_stock_adb_auth)) > 1:
        parser.error('choose one ADB test mode')
    main(args.root, args.timeout, args.request_usb_acm,
         args.test_stock_adb or args.test_stock_adb_guard or args.test_stock_adb_auth,
         args.test_stock_adb_guard, args.test_stock_adb_auth,
         args.request_usb_adb or args.rootfs_usb_adb_marker, args.initramfs, args.rootfs_usb_adb_marker, args.evidence, args.test_hardware)
