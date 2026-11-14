"""Read-only comparison of recovery tail and the installed script's target prefix."""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path
from stock_formats import fdt


def inspect(root):
    backup = root / 'phone-tools/backup/2026-11-13'
    data = (backup / 'recovery.img').read_bytes()
    if data[:8] != b'ANDROID!':
        raise ValueError('missing Android header')
    fields = struct.unpack_from('<10I', data, 8)
    page = fields[7]
    if page not in (2048, 4096, 8192):
        raise ValueError('unexpected page size')
    cursor = page
    for size in (fields[0], fields[2], fields[4]):
        end = cursor + size
        if end > len(data):
            raise ValueError('section outside image')
        cursor = (end + page - 1) // page * page
    # Independently acquired install-recovery.sh specifies this exact length/hash.
    prefix_end = 6794846
    expected_sha1 = 'e94825710e912cc47f09dee1be17fb43d1fc564d'
    actual_sha1 = hashlib.sha1(data[:prefix_end]).hexdigest()
    if actual_sha1 != expected_sha1 or end > prefix_end:
        raise ValueError('recovery prefix does not match installed stock target')
    positions = [i for i in range(end, len(data)) if data[i]]
    spans = []
    for position in positions:
        if not spans or position - spans[-1][1] > 64:
            spans.append([position, position + 1])
        else:
            spans[-1][1] = position + 1
    reports = []
    for start, stop in spans:
        fragment = data[start:stop]
        matches = []
        # A sufficiently long exact sequence is evidence; a short magic is not.
        if len(fragment) >= 256:
            anchor = fragment[:256]
            for name in ('boot', 'boot1', 'bootloader', 'logo', 'reserved'):
                other = (backup / (name + '.img')).read_bytes()
                at = other.find(anchor)
                if at >= 0:
                    same = 0
                    for left, right in zip(fragment, other[at:]):
                        if left != right:
                            break
                        same += 1
                    matches.append(dict(image=name, offset=at, exact_prefix_bytes=same))
        reports.append(dict(start=start, end_exclusive=stop, bytes=len(fragment),
                            sha256=hashlib.sha256(fragment).hexdigest(),
                            first_32_hex=fragment[:32].hex(), matches=matches))
    embedded_trees = []
    position = prefix_end
    while True:
        position = data.find(bytes.fromhex('d00dfeed'), position)
        if position < 0:
            break
        if position + 40 <= len(data):
            size = struct.unpack_from('>I', data, position + 4)[0]
            if 40 <= size <= len(data) - position:
                blob = data[position:position + size]
                try:
                    tree = fdt(blob)
                except (ValueError, KeyError, struct.error):
                    pass
                else:
                    reference = root / 'phone-tools/extracted/2026-11-13/recovery/second.bin'
                    embedded_trees.append(dict(offset=position, bytes=size,
                                               sha256=hashlib.sha256(blob).hexdigest(),
                                               nodes=len(tree['nodes']),
                                               matches_declared_recovery_dtb=blob == reference.read_bytes()))
        position += 1
    return dict(source_sha256=hashlib.sha256(data).hexdigest(),
                declared_section_end=end, aligned_end=cursor,
                installed_script_target_prefix_bytes=prefix_end,
                target_prefix_sha1=actual_sha1,
                nonzero_between_section_and_prefix=sum(bool(v) for v in data[end:prefix_end]),
                nonzero_after_prefix=sum(bool(v) for v in data[prefix_end:]),
                nonzero_spans_gap_threshold=64, spans=reports,
                validated_fdt_after_prefix=embedded_trees,
                tail_printable_strings=[m.group().decode('ascii') for m in
                                        re.finditer(rb'[ -~]{16,}', data[end:])][:40],
                classification='UNKNOWN; byte position is not signature verification',
                loader_acceptance='UNKNOWN')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k not in ('spans', 'tail_printable_strings')}, indent=2))
