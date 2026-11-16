"""Derive LOCAL fail-safe RAM candidates from the pinned Console rootfs.

Only `init` (and, for the loader variant, `bin/mibox`) changes; every other byte
of the verified Console archive is kept, so this needs no Alpine rebuild. Never uploads or writes a device.
Variants: failsafe (normal build) and fault-panic/usb/hang/kpanic (MIBOX_FAULT builds,
RAM tests only, never flash) and loader (feature loader-restart: init plus
bin/mibox, adds the PID1 LOADER request). Run under WSL after building the init binaries.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path

PINNED_GZIP = 'ff1bed630868c0bdbcdfeed3b8c7466c84b3904b0a32ff90746e8e8e52aa51c3'
RELEASE = 'armv7-unknown-linux-musleabihf/release'
# rootfs entry -> binary name under RELEASE
BINARIES = {'init': 'mibox-init', 'bin/mibox': 'mibox-userland'}
VARIANTS = {'failsafe': ('target', None), 'fault-panic': ('target/fault-panic', 'panic'),
            'fault-usb': ('target/fault-usb', 'usb'), 'fault-hang': ('target/fault-hang', 'hang'),
            'fault-kpanic': ('target/fault-kpanic', 'kpanic'),
            'loader': ('target/loader-restart', None)}
# Entries each variant replaces; all others must stay byte-identical.
CHANGED = {'loader': ('init', 'bin/mibox')}


def replace_entry(archive, target, init):
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
        if name == target:
            if replaced:
                raise ValueError(f'duplicate {target} entry')
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
        raise ValueError(f'{target} entry absent')
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
        changed = CHANGED.get(variant, ('init',))
        updated = archive
        replacements = {}
        for name in changed:
            data = (root / directory / RELEASE / BINARIES[name]).read_bytes()
            updated, old = replace_entry(updated, name, data)
            if hashlib.sha256(old).hexdigest() != metadata['files'][name]['sha256']:
                raise ValueError(f'pinned rootfs {name} does not match its manifest')
            replacements[name] = (data, old)
        before, after = entries(archive), entries(updated)
        for name, (data, old) in replacements.items():
            if after.pop(name) != data or before.pop(name) != old:
                raise ValueError(f'derived {name} entry is wrong')
        if before != after:
            raise ValueError('derived archive differs outside the replaced entries')
        restored = updated
        for name, (_, old) in replacements.items():
            restored = replace_entry(restored, name, old)[0]
        if restored != archive:
            raise ValueError('restoring the old entries does not reproduce the pinned archive')
        output_gz = gzip.compress(updated, mtime=0)
        rootfs = root / f'target/mibox-rootfs-console-{variant}'
        rootfs.mkdir(parents=True, exist_ok=True)
        (rootfs / 'initramfs.NOT_READY.cpio.gz').write_bytes(output_gz)
        derived = dict(metadata)
        derived['files'] = dict(metadata['files'])
        for name, (data, _) in replacements.items():
            derived['files'][name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        derived.update(status='HOST_BUILT_NOT_PHYSICALLY_VALIDATED', gzip_bytes=len(output_gz),
                       gzip_sha256=hashlib.sha256(output_gz).hexdigest(),
                       derived_from_gzip_sha256=PINNED_GZIP, changed_entries=list(changed),
                       injected_fault=fault, never_flash=fault is not None)
        (rootfs / 'manifest.json').write_text(json.dumps(derived, indent=2) + '\n')
        out = root / f'target/mibox-boot-candidate-console-{variant}'
        candidate.build(root, out, rootfs)
        report = json.loads((out / 'manifest.json').read_text())
        summary[variant] = dict(fault=fault, init_sha256=derived['files']['init']['sha256'],
                                userland_sha256=derived['files']['bin/mibox']['sha256'],
                                rootfs_gzip_bytes=len(output_gz), rootfs_sha256=derived['gzip_sha256'],
                                image_sha256=report['sha256'], used_aligned_bytes=report['used_aligned_bytes'],
                                slack_bytes=report['bytes'] - report['used_aligned_bytes'])
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
