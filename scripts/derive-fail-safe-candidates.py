"""Derive LOCAL fail-safe RAM candidates from the pinned Console rootfs.

Only the `init` entry changes; every other byte of the verified Console archive
is kept, so this needs no Alpine rebuild. Never uploads or writes a device.
Variants: failsafe (normal build) and fault-panic/usb/hang (MIBOX_FAULT builds,
RAM tests only, never flash). Run under WSL after building the init binaries.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path

PINNED_GZIP = 'ff1bed630868c0bdbcdfeed3b8c7466c84b3904b0a32ff90746e8e8e52aa51c3'
RELEASE = 'armv7-unknown-linux-musleabihf/release/mibox-init'
VARIANTS = {'failsafe': ('target', None), 'fault-panic': ('target/fault-panic', 'panic'),
            'fault-usb': ('target/fault-usb', 'usb'), 'fault-hang': ('target/fault-hang', 'hang')}


def replace_init(archive, init):
    out = bytearray()
    offset = 0
    replaced = old = None
    while True:
        if archive[offset:offset + 6] != b'070701':
            raise ValueError('not a newc archive')
        fields = [int(archive[offset + 6 + 8 * i:offset + 14 + 8 * i], 16) for i in range(13)]
        size, name_size = fields[6], fields[11]
        name_end = offset + 110 + name_size
        name = archive[offset + 110:name_end - 1].decode()
        data_start = name_end + (-name_end % 4)
        data_end = data_start + size
        next_offset = data_end + (-data_end % 4)
        if name == 'init':
            if replaced:
                raise ValueError('duplicate init entry')
            old = bytes(archive[data_start:data_end])
            fields[6] = len(init)
            header = b'070701' + ''.join(f'{f:08x}' for f in fields).encode()
            out += header + archive[offset + 110:name_end]
            out += bytes(-len(out) % 4)
            out += init
            out += bytes(-len(out) % 4)
            replaced = True
        else:
            out += archive[offset:next_offset]
        offset = next_offset
        if name == 'TRAILER!!!':
            out += archive[offset:]
            break
    if not replaced:
        raise ValueError('init entry absent')
    return bytes(out), old


def entries(archive):
    """Strict newc listing: name -> data. Raises on any framing error."""
    result = {}
    offset = 0
    while True:
        if archive[offset:offset + 6] != b'070701':
            raise ValueError(f'bad newc header at {offset}')
        fields = [int(archive[offset + 6 + 8 * i:offset + 14 + 8 * i], 16) for i in range(13)]
        name_end = offset + 110 + fields[11]
        name = archive[offset + 110:name_end - 1].decode()
        start = name_end + (-name_end % 4)
        end = start + fields[6]
        if end > len(archive):
            raise ValueError('entry extends past archive')
        if name == 'TRAILER!!!':
            return result
        if name in result:
            raise ValueError(f'duplicate entry {name}')
        result[name] = archive[start:end]
        offset = end + (-end % 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('variants', nargs='*', default=list(VARIANTS))
    args = parser.parse_args()
    root = args.root
    base = root / 'target/mibox-rootfs-console'
    metadata = json.loads((base / 'manifest.json').read_text())
    compressed = (base / 'initramfs.NOT_READY.cpio.gz').read_bytes()
    if hashlib.sha256(compressed).hexdigest() != PINNED_GZIP or metadata['gzip_sha256'] != PINNED_GZIP:
        raise ValueError('base rootfs is not the pinned Console rootfs')
    archive = gzip.decompress(compressed)
    spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('build-mibox-boot-candidate.py'))
    candidate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(candidate)
    summary = {}
    for variant in args.variants:
        directory, fault = VARIANTS[variant]
        init = (root / directory / RELEASE).read_bytes()
        updated, old = replace_init(archive, init)
        if hashlib.sha256(old).hexdigest() != metadata['files']['init']['sha256']:
            raise ValueError('pinned rootfs init does not match its manifest')
        before, after = entries(archive), entries(updated)
        if after.pop('init') != init or before.pop('init') != old or before != after:
            raise ValueError('derived archive differs outside init')
        if replace_init(updated, old)[0] != archive:
            raise ValueError('restoring the old init does not reproduce the pinned archive')
        output_gz = gzip.compress(updated, mtime=0)
        rootfs = root / f'target/mibox-rootfs-console-{variant}'
        rootfs.mkdir(parents=True, exist_ok=True)
        (rootfs / 'initramfs.NOT_READY.cpio.gz').write_bytes(output_gz)
        derived = dict(metadata)
        derived['files'] = dict(metadata['files'])
        derived['files']['init'] = dict(bytes=len(init), sha256=hashlib.sha256(init).hexdigest())
        derived.update(status='HOST_BUILT_NOT_PHYSICALLY_VALIDATED', gzip_bytes=len(output_gz),
                       gzip_sha256=hashlib.sha256(output_gz).hexdigest(),
                       derived_from_gzip_sha256=PINNED_GZIP, changed_entries=['init'],
                       injected_fault=fault, never_flash=fault is not None)
        (rootfs / 'manifest.json').write_text(json.dumps(derived, indent=2) + '\n')
        out = root / f'target/mibox-boot-candidate-console-{variant}'
        candidate.build(root, out, rootfs)
        report = json.loads((out / 'manifest.json').read_text())
        summary[variant] = dict(fault=fault, init_sha256=derived['files']['init']['sha256'],
                                rootfs_gzip_bytes=len(output_gz), rootfs_sha256=derived['gzip_sha256'],
                                image_sha256=report['sha256'], used_aligned_bytes=report['used_aligned_bytes'],
                                slack_bytes=report['bytes'] - report['used_aligned_bytes'])
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
