"""Derive the slim A3 RAM rootfs from the pinned FailSafe console rootfs.

Offline. Replaces PID1 and /bin/mibox with the current release build (PERSIST-STOP).
Keeps the FailSafe stock adbd and system/bin/sh,
busybox with its applet links, musl, ADB keys and network/identity files.
Removes package management (apk, OpenSSL, CA certificates), the RAM SSH server
and its libraries, and the on-demand hardware diagnostic. Adds the slim start
script and the built-in persistence helper; SSH then runs from the persistent
Alpine tree (plan A3/B1). Writes initramfs.NOT_READY.cpio.gz + manifest.json.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import posixpath
import stat
import tarfile
from pathlib import Path

SOURCE_SHA256 = '266bdba6eb6efd39580edc742855a37ede189bf4a8925483b03462e73c9612ed'
# B2 baseline: Alpine files the slim boot runs as root (dropbear, what it
# links, the musl loader, busybox as the root login shell) and the links that
# resolve to them. Hashes come from the committed S2 device evidence; link
# targets from the S2 backup archive, whose hash is pinned.
BASELINE_FILES = ['usr/sbin/dropbear', 'lib/ld-musl-armhf.so.1', 'usr/lib/libz.so.1.3.2',
                  'usr/lib/libutmps.so.0.1.3.1', 'usr/lib/libskarnet.so.2.14.4.0', 'bin/busybox']
BASELINE_LINKS = ['lib/libc.musl-armv7.so.1', 'usr/lib/libz.so.1', 'usr/lib/libutmps.so.0.1',
                  'usr/lib/libskarnet.so.2.14', 'bin/sh', 'bin/ash']
HANDOFF_SHA256 = 'b2b5bfb7319e2c14b8f3b47ef0355318d399083bd6284a75d2f4db413b531014'  # source b56e8073…
SPLASH_SHA256 = 'f8f95140a0c010a2fefd36e18a14028a331b7fab9e3ae917f7ff15640f5a5aac'   # build-splash-ppm.py (LSB-left glyphs)
FBSTATUS_SHA256 = '86e3e6a78f1fc823caa7ecbdcf361574f9133a443e4d5e97d74b293899299cb2'  # build-fbstatus.py
S2_SHA256 = 'artifacts/storage/s2-20261117/device-sha256.txt'


def base_arm_static(root, data):
    """Reuse build-mibox-rootfs.py's static ARM ELF check on bytes."""
    import tempfile
    spec = importlib.util.spec_from_file_location('base_check', root / 'scripts/build-mibox-rootfs.py')
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    with tempfile.NamedTemporaryFile() as tmp:
        tmp.write(data)
        tmp.flush()
        return base.arm_static(Path(tmp.name))
S2_TAR = 'phone-tools/backup/2026-11-17-s2/mibox-console.tar'
S2_TAR_SHA256 = '5d655f74e0ccc9af7d1b4b6169b8c5a9cf8bfbfed73d6768358e4d22e6b492ae'


def alpine_baseline(root):
    digests = {}
    for line in (root / S2_SHA256).read_text().splitlines():
        digest, path = line.split('  ', 1)
        digests[path.removeprefix('mibox-console/rootfs/')] = digest
    if hashlib.sha256((root / S2_TAR).read_bytes()).hexdigest() != S2_TAR_SHA256:
        raise ValueError('S2 backup archive hash mismatch')
    with tarfile.open(root / S2_TAR) as tar:
        members = {m.name.removeprefix('mibox-console/rootfs/'): m for m in tar.getmembers()}
        lines = ['# MIBOX_ALPINE_BASELINE_V1 from S2 2026-11-17 (sha256 or link target)']
        for path in BASELINE_FILES:
            data = tar.extractfile(members[path]).read()
            if hashlib.sha256(data).hexdigest() != digests[path]:
                raise ValueError(f'S2 archive and device hash differ: {path}')
            lines.append(f'file {digests[path]} {path}')
        for path in BASELINE_LINKS:
            member = members[path]
            if not member.issym():
                raise ValueError(f'not a symlink in S2: {path}')
            lines.append(f'link {member.linkname} {path}')
    return ('\n'.join(lines) + '\n').encode()
# init and bin/mibox come from the current release build (PERSIST-STOP, B5).
REPLACED_FROM_RELEASE = {'init': 'mibox-init', 'bin/mibox': 'mibox-userland'}
KEEP_UNCHANGED = ['sbin/adbd', 'system/bin/sh', 'bin/busybox',
                  'lib/ld-musl-armhf.so.1', 'adb_keys', 'etc/mibox-usb-adb.enabled',
                  'etc/mibox-network-static', 'etc/os-release']
REMOVE_FILES = {'sbin/apk', 'sbin/mibox-hardware', 'usr/sbin/dropbear', 'usr/bin/dropbearkey',
                'usr/bin/scanelf', 'usr/bin/ssl_client', 'root/.ssh/authorized_keys',
                'usr/lib/libcrypto.so.3', 'usr/lib/libssl.so.3', 'usr/lib/libapk.so.2.14.10',
                'usr/lib/libskarnet.so.2.14.4.0', 'usr/lib/libutmps.so.0.1.3.1',
                'usr/lib/libz.so.1.3.2'}
REMOVE_TREES = ('etc/ssl', 'etc/ssl1.1', 'etc/apk', 'lib/apk', 'usr/share/apk',
                'usr/lib/engines-3', 'usr/lib/ossl-modules')


def resolve(name, target):
    base = '' if target.startswith('/') else posixpath.dirname(name)
    return posixpath.normpath(posixpath.join('/', base, target)).lstrip('/')


def build(root, output, kernel_dev=False):
    if not output.resolve().is_relative_to((root / 'target').resolve()):
        raise ValueError('output must be under target')
    spec = importlib.util.spec_from_file_location('console', root / 'scripts/build-console-rootfs.py')
    console = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(console)
    source = (root / 'target/mibox-rootfs-console-failsafe/initramfs.NOT_READY.cpio.gz').read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError('FailSafe rootfs differs from the pinned physical image')
    entries = console.unpack(gzip.decompress(source))
    kept = {name: hashlib.sha256(entries[name][1]).hexdigest() for name in KEEP_UNCHANGED}
    removed = []
    for name in list(entries):
        if name in REMOVE_FILES or any(name == t or name.startswith(t + '/') for t in REMOVE_TREES):
            removed.append(name)
            del entries[name]
    missing = sorted(REMOVE_FILES - set(removed))
    if missing:
        raise ValueError(f'expected FailSafe files absent: {missing}')
    # Drop symlinks whose target no longer exists (e.g. libz.so.1); keep the rest.
    changed = True
    while changed:
        changed = False
        for name, (mode, payload, _, _) in list(entries.items()):
            if stat.S_ISLNK(mode):
                target = resolve(name, payload.decode())
                if target and target not in entries and target.split('/')[0] not in ('proc', 'run', 'dev', 'sys', 'tmp'):
                    removed.append(name)
                    del entries[name]
                    changed = True
    baseline = alpine_baseline(root)
    entries['etc/mibox-alpine-baseline'] = (0o100444, baseline, 0, 0)
    # A5: HDMI handoff helper (fbdev ioctls only, physically shown to make
    # video visible 2026-11-15) and the deterministic status splash.
    handoff = (root / 'target/hardware-helper/mibox-fbhandoff').read_bytes()
    splash = (root / 'target/splash/mibox-splash.ppm').read_bytes()
    if hashlib.sha256(handoff).hexdigest() != HANDOFF_SHA256:
        raise ValueError('fbhandoff differs from its build manifest pin')
    if hashlib.sha256(splash).hexdigest() != SPLASH_SHA256 or not splash.startswith(b'P6\n1280 1080\n255\n'):
        raise ValueError('splash differs from the pinned 1280x1080 PPM')
    entries['sbin/mibox-fbhandoff'] = (0o100700, base_arm_static(root, handoff), 0, 0)
    # Opaque RGBA for fb0's verified layout (R,G,B,A bytes); fbsplash wrote
    # alpha 0, which the OSD shows as transparent (black).
    pixels = splash[len(b'P6\n1280 1080\n255\n'):]
    if len(pixels) != 1280 * 1080 * 3:
        raise ValueError('splash pixel data size')
    rgba = bytearray(1280 * 1080 * 4)
    rgba[0::4], rgba[1::4], rgba[2::4] = pixels[0::3], pixels[1::3], pixels[2::3]
    rgba[3::4] = b'\xff' * (1280 * 1080)
    entries['etc/mibox-splash.rgba'] = (0o100644, bytes(rgba), 0, 0)
    # Live status screen drawn over the splash once a second (its only write
    # is fb0); the splash stays as the fallback if it cannot run.
    fbstatus = (root / 'target/fbstatus/mibox-fbstatus').read_bytes()
    if hashlib.sha256(fbstatus).hexdigest() != FBSTATUS_SHA256:
        raise ValueError('fbstatus differs from its build manifest pin')
    entries['sbin/mibox-fbstatus'] = (0o100700, base_arm_static(root, fbstatus), 0, 0)
    assets = root / 'assets/rootfs'
    base_spec = importlib.util.spec_from_file_location('base', root / 'scripts/build-mibox-rootfs.py')
    base = importlib.util.module_from_spec(base_spec)
    base_spec.loader.exec_module(base)
    # --kernel-dev: PID1 from the container-kernel-test feature build, which
    # also accepts the pinned 3.10.99 development kernel, plus its marker.
    release_dir = root / ('target/kernel-userspace/armv7-unknown-linux-musleabihf/release' if kernel_dev
                          else 'target/armv7-unknown-linux-musleabihf/release')
    replaced = {}
    for name, binary in REPLACED_FROM_RELEASE.items():
        data = base.arm_static(release_dir / binary)
        if b'PERSIST-STOP' not in data:
            raise ValueError(f'{binary} lacks the PERSIST-STOP control request')
        replaced[name] = dict(failsafe_sha256=hashlib.sha256(entries[name][1]).hexdigest(),
                              sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
        entries[name] = (entries[name][0], data, 0, 0)
    if kernel_dev:
        marker = b'MIBOX_KERNEL_DEV_V1 8b1bb2b31a8e94b773a4b8ab907a0473a0951192 3.10.99-mibox-container-dev+\n'
        if marker not in entries['init'][1]:
            raise ValueError('init lacks the container-kernel-test feature marker')
        entries['etc/mibox-kernel-development'] = (0o100444, marker, 0, 0)
    entries['sbin/mibox-console-start'] = (0o100755, (assets / 'mibox-slim-start').read_bytes().replace(b'\r\n', b'\n'), 0, 0)
    entries['sbin/mibox-persistent-console'] = (0o100755, (assets / 'mibox-persistent-console').read_bytes().replace(b'\r\n', b'\n'), 0, 0)
    for directory in ('etc/dropbear', 'mnt', 'run'):
        entries.setdefault(directory, (0o040755, b'', 0, 0))
    for name, digest in kept.items():
        if hashlib.sha256(entries[name][1]).hexdigest() != digest:
            raise ValueError(f'kept file changed: {name}')
    busybox_links = sum(1 for m, p, _, _ in entries.values() if stat.S_ISLNK(m) and p == b'/bin/busybox')
    archive = console.pack(entries)
    compressed = gzip.compress(archive, 9, mtime=0)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'initramfs.NOT_READY.cpio.gz').write_bytes(compressed)
    files = {name: dict(bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
             for name, (mode, payload, _, _) in entries.items() if stat.S_ISREG(mode)}
    report = dict(status='HOST_BUILT_NOT_PHYSICALLY_VALIDATED', profile='slim-a3-kernel-dev' if kernel_dev else 'slim-a3',
                  container_kernel_test=kernel_dev,
                  source_rootfs_sha256=SOURCE_SHA256,
                  gzip_bytes=len(compressed), gzip_sha256=hashlib.sha256(compressed).hexdigest(),
                  cpio_bytes=len(archive), kept_unchanged=kept, replaced_from_release=replaced, alpine_baseline_sha256=hashlib.sha256(baseline).hexdigest(), removed=sorted(removed),
                  busybox_applet_links=busybox_links,
                  ssh_server='persistent Alpine tree (/usr/sbin/dropbear) after data activation',
                  usb_adb_enabled_by_rootfs_marker=True, private_keys_included=False,
                  qemu_probe_included=False, ssh_server_host_key_included=False,
                  files=files)
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ('files', 'removed')}, indent=2))
    print('removed entries:', len(removed))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, default=None)
    parser.add_argument('--kernel-dev', action='store_true',
                        help='RAM-test variant for the 3.10.99 container kernel')
    args = parser.parse_args()
    default = 'target/mibox-rootfs-slim-kernel-dev' if args.kernel_dev else 'target/mibox-rootfs-slim'
    build(args.root, args.output or args.root / default, args.kernel_dev)
