#!/usr/bin/env python3
"""S5 boot image budget: sections, slack and initramfs components per candidate.

Offline and read-only. For every target/mibox-boot-candidate-*/boot1-custom.NOT_READY.img
(or the images given), parses the Android v0 header, records kernel / ramdisk /
second (DTB) sizes, the page-aligned end and the slack to the 8 MiB partition,
then unpacks the gzip newc ramdisk and groups its files into components.

Per-component compressed sizes are standalone gzip -9 estimates of that
component's file contents (sum of per-file streams); they do not add up exactly
to the real ramdisk, which is one stream including cpio headers. The real
ramdisk size and a full gzip -9 recompression are reported separately.
"""
import argparse
import gzip
import hashlib
import json
import struct
import zlib
from pathlib import Path

PARTITION = 8388608


def sections(data):
    if data[:8] != b'ANDROID!':
        raise ValueError('no Android boot magic')
    kernel, _, ramdisk, _, second, _, _, page = struct.unpack_from('<8I', data, 8)
    out, offset = {}, page
    for name, size in (('kernel', kernel), ('ramdisk', ramdisk), ('second', second)):
        out[name] = dict(start=offset, size=size)
        offset += size + (-size % page)
    return page, out, offset


def cpio_newc(blob):
    entries, pos = [], 0
    while True:
        if blob[pos:pos + 6] not in (b'070701', b'070702'):
            raise ValueError(f'bad cpio magic at {pos}')
        fields = [int(blob[pos + 6 + 8 * i:pos + 14 + 8 * i], 16) for i in range(13)]
        mode, filesize, namesize = fields[1], fields[6], fields[11]
        name_start = pos + 110
        name = blob[name_start:name_start + namesize - 1].decode('utf-8', 'replace')
        data_start = name_start + namesize + (-(110 + namesize) % 4)
        end = data_start + filesize + (-filesize % 4)
        if name == 'TRAILER!!!':
            return entries
        entries.append((name.lstrip('./'), mode, blob[data_start:data_start + filesize], blob[pos:end]))
        pos = end


TRAILER = b'070701' + b'0' * 8 * 11 + b'0000000B' + b'0' * 8 + b'TRAILER!!!\0' + b'\0' * 3

# Slim RAM sets for A3, projected from the pinned FailSafe ramdisk. Directories,
# device nodes, small /etc files and all symlinks are kept; regular files are
# kept only if listed (or under a listed directory prefix ending in '/').
PROFILE_BASE = ['init', 'bin/mibox', 'sbin/adbd', 'bin/busybox', 'lib/ld-musl-armhf.so.1',
                'adb_keys', 'etc/']
PROFILES = {
    'failsafe_as_built': None,
    'a3_min_ram_shell_via_busybox': PROFILE_BASE,
    'a3_min_plus_system_bin_sh': PROFILE_BASE + ['system/bin/sh'],
    'a3_min_plus_hardware': PROFILE_BASE + ['sbin/mibox-hardware'],
    'a3_min_plus_hardware_and_ram_ssh': PROFILE_BASE + [
        'sbin/mibox-hardware', 'usr/sbin/dropbear', 'usr/bin/dropbearkey',
        'usr/lib/libz.so', 'usr/lib/libutmps.so', 'usr/lib/libskarnet.so'],
}


def project(entries, keep):
    out = bytearray()
    for name, mode, payload, record in entries:
        regular = mode & 0o170000 == 0o100000
        if regular and keep is not None and not any(
                name == k or (k.endswith('/') and name.startswith(k)) or
                (k.endswith('.so') and name.startswith(k)) for k in keep):
            continue
        if name.startswith('etc/ssl') and keep is not None and 'etc/ssl/' not in keep:
            continue
        out += record
    out += TRAILER
    out += bytes(-len(out) % 512)
    return len(out), len(gzip.compress(bytes(out), 9, mtime=0))


def component(name):
    parts = name.split('/')
    if len(parts) == 1:
        return name
    if parts[0] in ('lib', 'usr') and len(parts) > 2 and parts[1] == 'lib':
        return '/'.join(parts[:3])
    if parts[0] in ('bin', 'sbin', 'usr') and len(parts) >= 2:
        return '/'.join(parts[:3] if parts[0] == 'usr' else parts[:2])
    return '/'.join(parts[:2])


def inspect(image):
    data = image.read_bytes()
    page, secs, end = sections(data)
    for name, s in secs.items():
        s['sha256'] = hashlib.sha256(data[s['start']:s['start'] + s['size']]).hexdigest()
    rd = data[secs['ramdisk']['start']:secs['ramdisk']['start'] + secs['ramdisk']['size']]
    if rd[:2] != b'\x1f\x8b':
        raise ValueError('ramdisk is not gzip')
    raw = gzip.decompress(rd)
    groups, symlinks, files = {}, 0, 0
    entries = cpio_newc(raw)
    for name, mode, payload, _ in entries:
        kind = mode & 0o170000
        if kind == 0o120000:
            symlinks += 1
            continue
        if kind != 0o100000:
            continue
        files += 1
        g = groups.setdefault(component(name), dict(files=0, bytes=0, gzip9_estimate=0))
        g['files'] += 1
        g['bytes'] += len(payload)
        g['gzip9_estimate'] += len(gzip.compress(payload, 9, mtime=0)) - 18
    tail = data[end:]
    aligned = {n: s['size'] + (-s['size'] % page) for n, s in secs.items()}
    projections = None
    if image.parent.name == 'mibox-boot-candidate-console-failsafe':
        projections = {}
        for label, keep in PROFILES.items():
            raw_bytes, gz = project(entries, keep)
            projections[label] = dict(cpio_bytes=raw_bytes, gzip9_bytes=gz,
                                      slack_with_this_kernel_and_dtb=PARTITION - page - aligned['kernel']
                                      - aligned['second'] - gz - (-gz % page))
    return dict(
        ramdisk_capacity_bytes=PARTITION - page - aligned['kernel'] - aligned['second'],
        slim_projections=projections,
        image=str(image).replace('\\', '/'), bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
        page_size=page, sections=secs, aligned_end=end, slack_bytes=PARTITION - end,
        tail_all_zero=not any(tail),
        ramdisk=dict(compressed_bytes=len(rd), uncompressed_bytes=len(raw),
                     regular_files=files, symlinks=symlinks,
                     gzip9_recompressed_bytes=len(gzip.compress(raw, 9, mtime=0)),
                     zlib_level=rd[8] if len(rd) > 8 else None),
        components=dict(sorted(groups.items(), key=lambda kv: -kv[1]['gzip9_estimate'])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument('images', nargs='*', type=Path)
    parser.add_argument('--output', type=Path,
                        default=root / 'artifacts/boot-budget/2026-11-17/boot-budget.json')
    args = parser.parse_args()
    images = args.images or sorted(root.glob('target/mibox-boot-candidate-*/boot1-custom.NOT_READY.img'))
    reports = []
    for image in images:
        r = inspect(image)
        r['image'] = str(image.resolve().relative_to(root)).replace('\\', '/')
        reports.append(r)
        s = r['sections']
        print(f"{image.parent.name:45} kernel {s['kernel']['size']:8} ramdisk {s['ramdisk']['size']:8} "
              f"dtb {s['second']['size']:6} end {r['aligned_end']:8} slack {r['slack_bytes']:7}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(partition_bytes=PARTITION, candidates=reports), indent=2) + '\n')
    print('WROTE', args.output)


if __name__ == '__main__':
    main()
