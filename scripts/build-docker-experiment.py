"""Build a small RAM boot rootfs and separately hash-pinned offline engine payload.

Preserves ContainerKernel2's init, userland, kernel guard and selftest. Uses
PID1's existing immutable console-start hook; no new privileged command API.
"""
import gzip
import argparse
import hashlib
import importlib.util
import io
import json
import subprocess
import tarfile
from pathlib import Path
from docker_payload_elf import inspect_arm

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as stream:
        directories = {'dev', 'proc', 'sys', 'run', 'tmp', 'root', 'etc', 'usr', 'sbin'}
        for name in files:
            directories.update(str(p) for p in Path(name).parents if str(p) != '.')
        for name in sorted(directories, key=lambda n: (n.count('/'), n)):
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o1777 if name == 'tmp' else 0o755
            stream.addfile(info)
        for name, (data, mode, link) in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.mode = mode
            if link:
                info.type = tarfile.SYMTYPE
                info.linkname = link
            else:
                info.size = len(data)
            stream.addfile(info, None if link else io.BytesIO(data))
    return output.getvalue()


def main(rootfs):
    alpine = Path('/home/morefunfun/.cache/mibox-console-root')
    engine = Path('/home/morefunfun/.cache/mibox-docker-24.0.9-ram-test')
    out = ROOT / 'target/mibox-docker-experiment'
    out.mkdir(parents=True, exist_ok=True)
    busybox = (alpine / 'bin/busybox').read_bytes()
    loader = (alpine / 'lib/ld-musl-armhf.so.1').read_bytes()
    if digest(busybox) != '750e37d6f1ade60d65e3a87e4287afcb50e7ca2a6e440b28282c5bebcd3b088e' or digest(loader) != '20729cec964a7ab5cc4be6d3817ef23129cf61e7159fd501527f5d1aa8b0717b':
        raise ValueError('Previously tested Alpine BusyBox/musl changed')
    applets = subprocess.check_output(['qemu-arm-static', str(alpine / 'lib/ld-musl-armhf.so.1'),
        '--library-path', str(alpine / 'lib'), str(alpine / 'bin/busybox'), '--list'], text=True).splitlines()
    minimal = {'bin/busybox': (busybox, 0o755, None),
               'lib/ld-musl-armhf.so.1': (loader, 0o755, None),
               'lib/libc.musl-armv7.so.1': (b'', 0o777, 'ld-musl-armhf.so.1')}
    for applet in applets:
        if applet != 'busybox':
            minimal['bin/' + applet] = (b'', 0o777, 'busybox')
    files = dict(minimal)
    provenance = json.loads((engine / 'manifest.json').read_text())
    for name, record in provenance['binaries'].items():
        data = (engine / 'bin' / name).read_bytes()
        if digest(data) != record['sha256']:
            raise ValueError('Engine payload changed: ' + name)
        files['usr/local/bin/' + name] = (data, 0o755, None)
    config = (engine / 'daemon-ram-test.json').read_bytes()
    if digest(config) != provenance['ram_test_config_sha256']:
        raise ValueError('Daemon configuration changed')
    files['etc/docker/daemon.json'] = (config, 0o600, None)
    # Local test image uses the same pinned Alpine BusyBox and musl binaries.
    image = archive(minimal)
    files['opt/test-rootfs.tar'] = (image, 0o600, None)
    script = (ROOT / 'assets/rootfs/mibox-docker-experiment').read_bytes().replace(b'\r\n', b'\n')
    files['sbin/mibox-docker-experiment'] = (script, 0o755, None)
    payload = gzip.compress(archive(files), compresslevel=6, mtime=0)
    (out / 'payload.tar.gz').write_bytes(payload)
    spec = importlib.util.spec_from_file_location('cpio', ROOT / 'scripts/build-console-rootfs.py')
    cpio = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cpio)
    base = ROOT / 'target/mibox-rootfs-kernel2'
    entries = cpio.unpack(gzip.decompress((base / 'initramfs.NOT_READY.cpio.gz').read_bytes()))
    for directory in ('lib', 'run', 'docker-tools'):
        entries[directory] = (0o040755, b'', 0, 0)
    entries['bin/busybox'] = (0o100755, busybox, 0, 0)
    sandbox = (out / 'mibox-docker-sandbox').read_bytes()
    inspect_arm(sandbox)
    if b'linux,dummy-virt' in sandbox or b'arm,vexpress' in sandbox or b'AMLOGIC,8726_MX' not in sandbox:
        raise ValueError('Board payload must not contain QEMU sandbox bypass')
    entries['sbin/mibox-docker-sandbox'] = (0o100755, sandbox, 0, 0)
    entries['lib/ld-musl-armhf.so.1'] = (0o100755, loader, 0, 0)
    entries['lib/libc.musl-armv7.so.1'] = (0o120777, b'ld-musl-armhf.so.1', 0, 0)
    for applet in applets:
        entries['docker-tools/' + applet] = (0o120777, b'/bin/busybox', 0, 0)
    # Copy into root-owned RAM storage before hashing; the public upload path
    # is never extracted or executed directly. Only the exact built archive runs.
    bootstrap = '''#!/bin/sh
exec /bin/busybox sh /sbin/mibox-docker-bootstrap
'''
    worker = '''#!/bin/sh
set -eu
export PATH=/docker-tools:/bin:/sbin:/system/bin
exec > /tmp/mibox-docker-experiment.log 2>&1
test "$(id -u)" = 0
test "$(cat /proc/sys/kernel/osrelease)" = 3.10.99
grep -aq 'AMLOGIC,8726_MX' /proc/device-tree/compatible
grep -qx 'MIBOX_KERNEL_DEV_V1 8b1bb2b31a8e94b773a4b8ab907a0473a0951192 3.10.99-mibox-container-dev+' /etc/mibox-kernel-development
mkdir -m 700 /run/mibox-docker-stage
echo MIBOX_DOCKER_WAITING_FOR_PAYLOAD
n=0
until test -f /tmp/mibox-docker-payload.ready; do
    test "$n" -lt 900
    sleep 1
    n=$((n + 1))
done
cp /tmp/mibox-docker-payload.ready /run/mibox-docker-stage/payload.tar.gz
echo 'PAYLOAD_HASH  /run/mibox-docker-stage/payload.tar.gz' | sha256sum -c -
mkdir -m 700 /run/mibox-docker-stage/root
set +e
/sbin/mibox-docker-sandbox
result=$?
set -e
rm /run/mibox-docker-stage/payload.tar.gz
echo "MIBOX_DOCKER_EXPERIMENT_EXIT=$result"
# The PID namespace destroys remaining children and the private mounts vanish.
echo MIBOX_DOCKER_BOOTSTRAP_DONE
exit "$result"
'''.replace('PAYLOAD_HASH', digest(payload))
    entries['sbin/mibox-console-start'] = (0o100755, bootstrap.encode(), 0, 0)
    entries['sbin/mibox-docker-bootstrap'] = (0o100755, worker.encode(), 0, 0)
    raw_cpio = cpio.pack(entries)
    packed = gzip.compress(raw_cpio, compresslevel=6, mtime=0)
    if not rootfs.resolve().is_relative_to((ROOT / 'target').resolve()):
        raise ValueError('Rootfs output must remain under target')
    rootfs.mkdir(exist_ok=True)
    (rootfs / 'initramfs.NOT_READY.cpio.gz').write_bytes(packed)
    manifest = json.loads((base / 'manifest.json').read_text())
    manifest.update(gzip_bytes=len(packed), gzip_sha256=digest(packed), cpio_sha256=digest(raw_cpio),
                    files={name: dict(bytes=len(value[1]), sha256=digest(value[1]))
                           for name, value in entries.items() if value[0] & 0o170000 == 0o100000},
                    docker_experiment=True,
                    payload_sha256=digest(payload), payload_bytes=len(payload))
    (rootfs / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    report = dict(payload_sha256=digest(payload), payload_bytes=len(payload),
                  offline_image_tar_sha256=digest(image), busybox_sha256=digest(busybox),
                  musl_sha256=digest(loader), rootfs_sha256=digest(packed),
                  daemon_config_sha256=digest(config), physical_validation=False,
                  sandbox_sha256=digest(sandbox),
                  init_unchanged=entries['init'][1] == cpio.unpack(gzip.decompress(
                      (base / 'initramfs.NOT_READY.cpio.gz').read_bytes()))['init'][1],
                  storage='RAM_ONLY', network='PRIVATE_NAMESPACE_LOOPBACK_ONLY')
    (out / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs-output', type=Path, default=ROOT / 'target/mibox-rootfs-docker')
    main(parser.parse_args().rootfs_output)
