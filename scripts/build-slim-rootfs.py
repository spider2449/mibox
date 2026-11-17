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
from pathlib import Path

SOURCE_SHA256 = '266bdba6eb6efd39580edc742855a37ede189bf4a8925483b03462e73c9612ed'
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


def build(root, output):
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
    assets = root / 'assets/rootfs'
    base_spec = importlib.util.spec_from_file_location('base', root / 'scripts/build-mibox-rootfs.py')
    base = importlib.util.module_from_spec(base_spec)
    base_spec.loader.exec_module(base)
    release_dir = root / 'target/armv7-unknown-linux-musleabihf/release'
    replaced = {}
    for name, binary in REPLACED_FROM_RELEASE.items():
        data = base.arm_static(release_dir / binary)
        if b'PERSIST-STOP' not in data:
            raise ValueError(f'{binary} lacks the PERSIST-STOP control request')
        replaced[name] = dict(failsafe_sha256=hashlib.sha256(entries[name][1]).hexdigest(),
                              sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
        entries[name] = (entries[name][0], data, 0, 0)
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
    report = dict(status='HOST_BUILT_NOT_PHYSICALLY_VALIDATED', profile='slim-a3',
                  source_rootfs_sha256=SOURCE_SHA256,
                  gzip_bytes=len(compressed), gzip_sha256=hashlib.sha256(compressed).hexdigest(),
                  cpio_bytes=len(archive), kept_unchanged=kept, replaced_from_release=replaced, removed=sorted(removed),
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
    args = parser.parse_args()
    build(args.root, args.output or args.root / 'target/mibox-rootfs-slim')
