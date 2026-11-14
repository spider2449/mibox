"""Inventory stock FDT, environment and boot tails offline; never creates images."""
import argparse
import collections
import hashlib
import json
import math
import struct
import zlib
from pathlib import Path
from stock_formats import cells, fdt


def describe(value):
    result = {'hex': value.hex()}
    if len(value) % 4 == 0:
        result['cells'] = cells(value)
    if value.endswith(b'\0') and any(32 <= byte < 127 for byte in value) and all(byte in (0, 9, 10, 13) or 32 <= byte < 127 for byte in value):
        result['strings'] = value[:-1].decode('ascii').split('\0')
    return result


def main(root):
    evidence = root / 'artifacts/platform/2026-11-13'
    evidence.mkdir(parents=True, exist_ok=True)
    backup = root / 'phone-tools/backup/2026-11-13'
    blob = (root / 'phone-tools/extracted/2026-11-13/boot1/second.bin').read_bytes()
    tree = fdt(blob)
    report = {key: value for key, value in tree.items() if key != 'nodes'}
    report['sha256'] = hashlib.sha256(blob).hexdigest()
    report['nodes'] = {path: {name: describe(raw) for name, raw in props.items()}
                       for path, props in tree['nodes'].items()}
    (evidence / 'stock-dtb.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

    env = (backup / 'env.img').read_bytes()
    crc_matches = []
    for size in (16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304):
        if size <= len(env) and struct.unpack_from('<I', env)[0] == zlib.crc32(env[4:size]):
            crc_matches.append(size)
    # Report only boot-related variables; retain the full original env privately.
    selected = {}
    for entry in env[4:].split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            try:
                key, value = key.decode('ascii'), value.decode('ascii')
            except UnicodeDecodeError:
                continue
            if key in {'bootcmd', 'bootdelay', 'loadaddr', 'storeboot', 'recovery',
                       'update', 'upgrade_step', 'preboot', 'bootfromnand', 'bootfromsd'}:
                selected[key] = value
    (evidence / 'boot-environment.json').write_text(json.dumps({
        'crc32_matching_total_sizes': crc_matches, 'variables': selected,
        'note': 'Static environment, not an executed boot trace.'}, indent=2), encoding='utf-8')

    tails = {}
    for name in ('boot', 'boot1', 'recovery'):
        data = (backup / (name + '.img')).read_bytes()
        fields = struct.unpack_from('<10I', data, 8)
        page = fields[7]
        offset = page
        for size in (fields[0], fields[2], fields[4]):
            last_end = offset + size
            offset = (last_end + page - 1) // page * page
        tail = data[last_end:]
        tails[name] = {'last_section_end': last_end, 'aligned_end': offset,
                       'bytes_after_last_section': len(tail),
                       'nonzero_bytes_after_last_section': sum(byte != 0 for byte in tail),
                       'signature_verification': 'NOT PERFORMED',
                       'loader_acceptance': 'UNKNOWN'}
    (evidence / 'image-tails.json').write_text(json.dumps(tails, indent=2), encoding='utf-8')
    loader = (backup / 'bootloader.img').read_bytes()
    counts = collections.Counter(loader)
    entropy = -sum((count / len(loader)) * math.log2(count / len(loader)) for count in counts.values())
    (evidence / 'bootloader-summary.json').write_text(json.dumps({
        'sha256': hashlib.sha256(loader).hexdigest(), 'bytes': len(loader),
        'first_64_bytes_hex': loader[:64].hex(), 'entropy_bits_per_byte': entropy,
        'u_boot_string_offsets': [i for i in range(len(loader)) if loader.startswith(b'U-Boot', i)],
        'note': 'String absence and entropy do not prove encryption or secure boot.'}, indent=2), encoding='utf-8')
    print(f"FDT parsed: {len(tree['nodes'])} nodes; evidence: {evidence}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    main(parser.parse_args().root)
