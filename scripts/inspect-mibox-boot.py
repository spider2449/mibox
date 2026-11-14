"""Inspect a candidate image offline without repacking it or accessing a device."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

EXPECTED_SIZE = 4433609
EXPECTED_SHA1 = '2dafa19e539ef3a5a674d3f13ff6df9ab483220f'


def inspect(path):
    data = path.read_bytes()
    result = dict(file=path.name, bytes=len(data),
                  sha256=hashlib.sha256(data).hexdigest(),
                  expected_prefix_bytes=EXPECTED_SIZE,
                  expected_prefix_sha1=EXPECTED_SHA1)
    prefix_hash = (hashlib.sha1(data[:EXPECTED_SIZE]).hexdigest()
                   if len(data) >= EXPECTED_SIZE else None)
    result.update(actual_prefix_sha1=prefix_hash,
                  matches_installed_script=prefix_hash == EXPECTED_SHA1)
    if data[:8] != b'ANDROID!':
        result.update(format='UNKNOWN', layout_validated=False,
                      reason='No Android boot magic at offset 0; vendor wrapping remains possible.')
        return result
    if len(data) < 1632:
        raise ValueError('truncated Android header')
    fields = struct.unpack_from('<10I', data, 8)
    kernel, ka, ramdisk, ra, second, sa, tags, page, dt, unused = fields
    if page < 1632 or page > 1048576 or page & (page-1):
        raise ValueError('unsupported page size')
    if dt or unused:
        result.update(format='ANDROID!', layout_validated=False,
                      reason='Nonzero DT/header-version/reserved fields require version-specific analysis.')
        return result
    sections = []
    offset = page
    for name, size in [('kernel', kernel), ('ramdisk', ramdisk), ('second', second)]:
        end = offset + size
        if end > len(data):
            raise ValueError(f'{name} extends beyond file')
        sections.append(dict(name=name, start=offset, size=size, end=end,
                             sha256=hashlib.sha256(data[offset:end]).hexdigest()))
        offset = (end+page-1)//page*page
    result.update(format='Android v0-compatible (limited parser)',
                  layout_validated=True, page_size=page, sections=sections,
                  declared_load_addresses=dict(kernel=ka, ramdisk=ra, second=sa, tags=tags),
                  aligned_end=offset, tail_bytes=max(0, len(data)-offset),
                  complete_final_page=len(data) >= offset,
                  bootloader_acceptance='UNKNOWN', signature_verified=False)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    args = parser.parse_args()
    try:
        report = inspect(args.image)
    except (OSError, ValueError, struct.error) as error:
        parser.exit(2, f'Cannot inspect: {error}\n')
    print(json.dumps(report, indent=2))
    # Inspection is useful even when the vendor format is unknown, but callers
    # must not interpret that as a successful match for this installed build.
    raise SystemExit(0 if report['matches_installed_script'] else 1)
