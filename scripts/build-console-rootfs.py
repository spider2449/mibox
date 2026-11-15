"""Combine a prepared Alpine ARMv7 tree and custom PID1 into a RAM-only candidate.

Run under WSL. The Alpine tree must be prepared on Linux storage, not NTFS.
No host private SSH key is read. Server host keys are generated at runtime.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import stat
from pathlib import Path


def unpack(data):
    entries = {}
    offset = 0
    while True:
        if data[offset:offset + 6] != b'070701':
            raise ValueError('invalid newc archive')
        fields = [int(data[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        start = offset + 110
        name = data[start:start + fields[11] - 1].decode('utf-8')
        start = (start + fields[11] + 3) & ~3
        payload = data[start:start + fields[6]]
        offset = (start + fields[6] + 3) & ~3
        if name == 'TRAILER!!!':
            return entries
        entries[name] = (fields[1], payload, fields[9], fields[10])


def pack(entries):
    archive = bytearray()
    for index, (name, (mode, payload, major, minor)) in enumerate(
            [*sorted(entries.items(), key=lambda item: (item[0].count('/'), item[0])),
             ('TRAILER!!!', (0, b'', 0, 0))], 1):
        name = name.encode('utf-8') + b'\0'
        fields = [index, mode, 0, 0, 1, 0, len(payload), 0, 0, major, minor, len(name), 0]
        archive.extend(b'070701' + ''.join(f'{v:08x}' for v in fields).encode())
        archive.extend(name)
        archive.extend(bytes(-len(archive) % 4))
        archive.extend(payload)
        archive.extend(bytes(-len(archive) % 4))
    return archive


def build(root, alpine, public_key, adb_key, output):
    if not output.resolve().is_relative_to((root / 'target').resolve()):
        raise ValueError('output must be under target')
    key = public_key.read_text().strip()
    if not key.startswith('ssh-ed25519 ') or len(key.split()) < 2 or '\n' in key:
        raise ValueError('one OpenSSH Ed25519 public key required')
    spec = importlib.util.spec_from_file_location('base', root / 'scripts/build-mibox-rootfs.py')
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    base.build(root, adb_key, output / 'base', True,
               root / 'target/hardware-helper/mibox-hardware',
               ('192.168.1.222', '255.255.255.0', '192.168.1.1'))
    entries = {}
    for directory, dirs, files in os.walk(alpine, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            relative = path.relative_to(alpine).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                payload = os.readlink(path).encode()
            elif stat.S_ISREG(mode):
                payload = path.read_bytes()
            elif stat.S_ISDIR(mode):
                payload = b''
            else:
                raise ValueError(f'unsupported Alpine entry: {relative}')
            entries[relative] = (mode, payload, 0, 0)
    entries.pop('etc/dropbear/dropbear_ed25519_host_key', None)
    entries.pop('etc/dropbear/dropbear_ed25519_host_key.pub', None)
    for required in ('bin/busybox', 'sbin/apk', 'usr/sbin/dropbear'):
        if required not in entries:
            raise ValueError(f'missing console component: {required}')
    original = unpack(gzip.decompress((output / 'base/initramfs.NOT_READY.cpio.gz').read_bytes()))
    # Preserve Alpine's shell and writable package configuration; keep our
    # identity, PID1, USB transport and normal-return control infrastructure.
    original.pop('bin/sh')
    entries.update(original)
    entries['root'] = (0o040700, b'', 0, 0)
    entries['root/.ssh'] = (0o040700, b'', 0, 0)
    entries['root/.ssh/authorized_keys'] = (0o100600, (key + '\n').encode(), 0, 0)
    entries['etc/resolv.conf'] = (0o100644, b'nameserver 1.1.1.1\nnameserver 9.9.9.9\n', 0, 0)
    for source, destination in [('mibox-console-start', 'sbin/mibox-console-start'),
                                ('mibox-udhcpc', 'etc/mibox-udhcpc')]:
        entries[destination] = (0o100755, (root / 'assets/rootfs' / source).read_bytes().replace(b'\r\n', b'\n'), 0, 0)
    archive = pack(entries)
    compressed = gzip.compress(archive, mtime=0)
    (output / 'initramfs.NOT_READY.cpio.gz').write_bytes(compressed)
    report = dict(status='HOST_BUILT_NOT_PHYSICALLY_VALIDATED',
                  gzip_bytes=len(compressed), gzip_sha256=hashlib.sha256(compressed).hexdigest(),
                  alpine_version=(alpine / 'etc/alpine-release').read_text().strip(),
                  usb_adb_enabled_by_rootfs_marker=True,
                  private_keys_included=False, ssh_server_host_key_included=False,
                  owner_private_keys_included=False, qemu_probe_included=False,
                  ssh_password_authentication=False, package_persistence='RAM_ONLY',
                  files={name: dict(bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
                         for name, (mode, payload, _, _) in entries.items() if stat.S_ISREG(mode)})
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'files'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--alpine-root', type=Path, required=True)
    parser.add_argument('--ssh-public-key', type=Path, required=True)
    parser.add_argument('--adb-public-key', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.root, args.alpine_root, args.ssh_public_key, args.adb_public_key, args.output)
