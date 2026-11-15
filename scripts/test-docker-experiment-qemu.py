"""Full-system ARM smoke test of the offline Docker workload, not board proof."""
import gzip
import argparse
import datetime
import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main(legacy=False, rootfs=ROOT / 'target/mibox-rootfs-docker'):
    spec = importlib.util.spec_from_file_location('cpio', ROOT / 'scripts/build-console-rootfs.py')
    cpio = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cpio)
    payload = ROOT / 'target/mibox-docker-experiment/payload.tar.gz'
    payload_data = payload.read_bytes()
    entries = cpio.unpack(gzip.decompress((rootfs / 'initramfs.NOT_READY.cpio.gz').read_bytes()))
    entries['run/mibox-docker-stage'] = (0o040700, b'', 0, 0)
    entries['run/mibox-docker-stage/root'] = (0o040700, b'', 0, 0)
    entries['run/mibox-docker-stage/payload.tar.gz'] = (0o100600, payload_data, 0, 0)
    qemu_helper = ROOT / ('target/mibox-docker-experiment/mibox-docker-sandbox-qemu-legacy' if legacy else 'target/mibox-docker-experiment/mibox-docker-sandbox-qemu')
    helper_data = qemu_helper.read_bytes()
    entries['sbin/mibox-docker-sandbox-qemu'] = (0o100755, helper_data, 0, 0)
    init = b'''#!/bin/sh
export PATH=/docker-tools:/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
/sbin/mibox-docker-sandbox-qemu
result=$?
echo "QEMU_DOCKER_EXIT=$result"
poweroff -f
'''
    entries['init'] = (0o100755, init, 0, 0)
    entries['dev/console'] = (0o020600, b'', 5, 1)
    fixture = ROOT / 'target/mibox-docker-experiment/qemu.cpio.gz'
    fixture.write_bytes(gzip.compress(cpio.pack(entries), compresslevel=1, mtime=0))
    evidence = ROOT / 'artifacts/docker-runtime' / (('qemu-legacy-' if legacy else 'qemu-offline-') + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    evidence.mkdir(parents=True, exist_ok=True)
    kernel = ROOT / ('target/docker-qemu-legacy/zImage' if legacy else 'target/docker-qemu-kernel/vmlinuz')
    kernel_hash = hashlib.sha256(kernel.read_bytes()).hexdigest()
    if not legacy and kernel_hash != '1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4':
        raise ValueError('Debian bookworm QEMU kernel SHA256 mismatch')
    command = ['qemu-system-arm', '-machine', 'vexpress-a9' if legacy else 'virt', '-cpu', 'cortex-a9' if legacy else 'cortex-a15',
               '-m', '1024', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
               '-no-reboot', '-kernel', str(kernel),
               '-initrd', str(fixture), '-append', 'console=ttyAMA0,115200 rdinit=/init panic=0',
               '-nic', 'none']
    if legacy:
        command += ['-dtb', str(ROOT / 'target/docker-qemu-legacy/vexpress-v2p-ca9.dtb'),
                    '-audiodev', 'none,id=noaudio', '-global', 'pl041.audiodev=noaudio']
    timed_out = False
    with (evidence / 'serial.log').open('wb') as log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=240)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            process.wait()
    serial = (evidence / 'serial.log').read_text(errors='replace')
    passed = not timed_out and 'QEMU_DOCKER_EXIT=0' in serial and 'MIBOX_DOCKER_OFFLINE_TEST_PASS' in serial
    report = dict(passed=passed, timed_out=timed_out, qemu_exit=process.returncode,
                  payload_sha256=hashlib.sha256(payload_data).hexdigest(),
                  kernel_sha256=kernel_hash,
                  sandbox_qemu_sha256=hashlib.sha256(helper_data).hexdigest(),
                  fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                  kernel_profile='generic-vexpress-3.10' if legacy else 'debian-virt-6.1',
                  physical_validation=False)
    if legacy:
        report.update(dtb_sha256=hashlib.sha256((ROOT / 'target/docker-qemu-legacy/vexpress-v2p-ca9.dtb').read_bytes()).hexdigest(),
                      config_sha256=hashlib.sha256((ROOT / 'target/docker-qemu-legacy/resolved.config').read_bytes()).hexdigest(),
                      source_archive_sha256='3849ea8119517f605f9d53c57dd6c539af8d584c2f1d9031f4f56283af3409a5')
    (evidence / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy', action='store_true')
    parser.add_argument('--rootfs', type=Path, default=ROOT / 'target/mibox-rootfs-docker')
    args = parser.parse_args()
    main(args.legacy, args.rootfs)
