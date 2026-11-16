"""Build a deterministic QEMU-only initramfs, not a Mi Box boot image."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--with-stock-adb', action='store_true', help='QEMU-only stock adbd compatibility rootfs')
parser.add_argument('--with-stock-adb-auth', action='store_true', help='include only a dedicated QEMU public key')
parser.add_argument('--with-restart-probe', action='store_true', help='include QEMU-only RAM restart integration probe')
parser.add_argument('--loader-restart', action='store_true', help='restart probe with init/userland from target/loader-restart (feature loader-restart)')
args = parser.parse_args()
if args.loader_restart:
    args.with_restart_probe = True
release = root / ('target/loader-restart' if args.loader_restart else 'target') / 'armv7-unknown-linux-musleabihf/release'
if args.with_stock_adb_auth:
    args.with_stock_adb = True
binary = release / 'mibox-init'
destination = root / ('target/qemu-loader-restart' if args.loader_restart else 'target/qemu-restart' if args.with_restart_probe else 'target/qemu-adb-auth' if args.with_stock_adb_auth else
                      'target/qemu-adb' if args.with_stock_adb else 'target/qemu')
destination.mkdir(parents=True, exist_ok=True)
archive = bytearray()


def entry(name, mode, data=b'', major=0, minor=0):
    name = name.encode('ascii') + b'\0'
    fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(name), 0]
    archive.extend(b'070701' + ''.join(f'{field:08x}' for field in fields).encode('ascii'))
    archive.extend(name)
    archive.extend(bytes(-len(archive) % 4))
    archive.extend(data)
    archive.extend(bytes(-len(archive) % 4))


for directory in ('dev', 'proc', 'sys', 'bin', 'etc', 'tmp'):
    entry(directory, 0o040755)
entry('dev/console', 0o020600, major=5, minor=1)
payload = binary.read_bytes()
entry('init', 0o100755, payload)
toolbox = (release / 'mibox-userland').read_bytes()
identity = (root / 'assets/rootfs/os-release').read_bytes()
entry('bin/mibox', 0o100755, toolbox)
entry('etc/os-release', 0o100444, identity)
stock_hashes = {}
if args.with_restart_probe:
    probe = (root / 'target/armv7-unknown-linux-musleabihf/release/mibox-restart-probe').read_bytes()
    entry('bin/mibox-restart-probe', 0o100755, probe)
    stock_hashes['bin/mibox-restart-probe'] = hashlib.sha256(probe).hexdigest()
if args.with_stock_adb:
    for directory in ('sbin', 'system', 'system/bin'):
        entry(directory, 0o040755)
    for source, target, expected in [
        ('sbin__adbd', 'sbin/adbd', 'f2a875f1f6230fde084264e2927d1dbf3bf95bcf5e494809814a488caf532afc'),
        ('sbin__sh', 'system/bin/sh', 'd44fd1bb1a8a84fe6ed0b4d850dd05d506aaf4fefdb54d24eb99690fb6583fc6'),
    ]:
        content = (root / 'phone-tools/runtime/2026-11-14/recovery-binaries' / source).read_bytes()
        if hashlib.sha256(content).hexdigest() != expected:
            raise ValueError('stock recovery binary differs from pinned extraction')
        stock_hashes[target] = expected
        entry(target, 0o100755, content)
    probe = (root / 'target/armv7-unknown-linux-musleabihf/release/mibox-adb-probe').read_bytes()
    stock_hashes['bin/mibox-adb-probe'] = hashlib.sha256(probe).hexdigest()
    entry('bin/mibox-adb-probe', 0o100755, probe)
    if args.with_stock_adb_auth:
        from qemu_adb_key import ensure_key
        _, public = ensure_key(root)
        entry('adb_keys', 0o100444, public)
        stock_hashes['adb_keys'] = hashlib.sha256(public).hexdigest()
entry('TRAILER!!!', 0)
compressed = gzip.compress(archive, mtime=0)
(destination / 'initramfs.cpio.gz').write_bytes(compressed)
(destination / 'initramfs-provenance.json').write_text(json.dumps({
    'init_sha256': hashlib.sha256(payload).hexdigest(),
    'userland_sha256': hashlib.sha256(toolbox).hexdigest(),
    'os_release_sha256': hashlib.sha256(identity).hexdigest(),
    'optional_stock_adb_test_files': stock_hashes,
    'cpio_sha256': hashlib.sha256(archive).hexdigest(),
    'gzip_sha256': hashlib.sha256(compressed).hexdigest(),
    'purpose': 'QEMU generic ARM test only; no stock images used or modified.'
}, indent=2), encoding='utf-8')
print(f'QEMU initramfs: {len(compressed)} bytes')
