"""Inspect IMGDIFF2 metadata only; never applies patches or accesses a device.

Format reference: AOSP bootable/recovery android-4.4.2_r1/applypatch/imgdiff.c.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect(path):
    data = path.read_bytes()
    if data[:8] != b"IMGDIFF2":
        raise ValueError("expected IMGDIFF2 magic")
    cursor = 8

    def take(fmt):
        nonlocal cursor
        size = struct.calcsize(fmt)
        if cursor + size > len(data):
            raise ValueError("truncated chunk metadata")
        values = struct.unpack_from(fmt, data, cursor)
        cursor += size
        return values

    count, = take('<I')
    if count > len(data) // 8:
        raise ValueError("unreasonable chunk count")
    chunks = []
    for index in range(count):
        kind, = take('<I')
        chunk = dict(index=index, type=kind)
        if kind in (0, 2):
            start, length, patch = take('<QQQ')
            chunk.update(source_start=start, source_length=length, patch_offset=patch)
            if kind == 2:
                expanded, target = take('<QQ')
                params = take('<iiiii')
                chunk.update(source_expanded_length=expanded,
                             target_expanded_length=target, zlib_parameters=params)
            if patch + 32 > len(data) or data[patch:patch+8] != b'BSDIFF40':
                raise ValueError("missing BSDIFF40 header at patch offset")
            # BSDIFF uses signed magnitude, not two's complement, for int64.
            def bsdint(offset):
                raw = data[offset:offset+8]
                value = int.from_bytes(raw, 'little') & ((1 << 63) - 1)
                return -value if raw[7] & 128 else value
            ctrl, diff, target_size = (bsdint(patch+n) for n in (8, 16, 24))
            if min(ctrl, diff, target_size) < 0 or patch+32+ctrl+diff > len(data):
                raise ValueError("invalid BSDIFF40 lengths")
            chunk.update(bsdiff_control_bytes=ctrl, bsdiff_diff_bytes=diff,
                         bsdiff_target_bytes=target_size)
        elif kind == 3:
            length, = take('<I')
            if cursor + length > len(data):
                raise ValueError("truncated raw chunk")
            chunk.update(raw_offset=cursor, raw_length=length,
                         raw_sha256=hashlib.sha256(data[cursor:cursor+length]).hexdigest())
            cursor += length
        else:
            raise ValueError(f"unsupported chunk type {kind}")
        chunks.append(chunk)
    for chunk in chunks:
        if chunk.get('patch_offset', len(data)) < cursor:
            raise ValueError("patch overlaps metadata")
    return dict(file=path.name, size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                format='IMGDIFF2', header_bytes=cursor, chunks=chunks,
                full_boot_image_available=False,
                note='Metadata only. Source boot and bonus resource may be required; no image reconstructed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('patch', type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.patch), indent=2))
