"""Extract bounded Android-v0-compatible sections and selected init config offline."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import struct
from pathlib import Path

spec = importlib.util.spec_from_file_location('boot_inspector', Path(__file__).with_name('inspect-mibox-boot.py'))
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


def extract(image, destination):
    report = inspector.inspect(image)
    if not report.get('layout_validated'):
        raise ValueError('unsupported layout; no sections extracted')
    data = image.read_bytes()
    destination.mkdir(parents=True, exist_ok=False)
    sha = hashlib.sha1()
    for section in report['sections']:
        payload = data[section['start']:section['end']]
        (destination / (section['name'] + '.bin')).write_bytes(payload)
        sha.update(payload)
        sha.update(struct.pack('<I', len(payload)))
        if section['name'] == 'second' and payload[:4] == bytes.fromhex('d00dfeed'):
            total, = struct.unpack_from('>I', payload, 4)
            report['second_fdt'] = dict(total_bytes=total, section_bytes=len(payload),
                                        fits_section=40 <= total <= len(payload))
    report['android_id_sha1'] = data[576:596].hex()
    report['computed_android_id_sha1'] = sha.hexdigest()
    report['android_id_matches'] = sha.digest() == data[576:596]
    ramdisk = next(s for s in report['sections'] if s['name'] == 'ramdisk')
    with gzip.GzipFile(fileobj=io.BytesIO(data[ramdisk['start']:ramdisk['end']])) as compressed:
        cpio = compressed.read(64 * 1024 * 1024 + 1)
    if len(cpio) > 64 * 1024 * 1024:
        raise ValueError('ramdisk exceeds inspection limit')
    (destination / 'ramdisk.cpio').write_bytes(cpio)
    wanted = {'default.prop', 'fstab.amlogic', 'init.rc', 'init.amlogic.rc',
              'init.amlogic.board.rc', 'init.amlogic.usb.rc', 'ueventd.amlogic.rc'}
    offset = 0
    entries = []
    trailer_found = False
    while offset + 110 <= len(cpio) and len(entries) < 10000:
        header = cpio[offset:offset+110]
        if header[:6] not in (b'070701', b'070702'):
            raise ValueError(f'unsupported cpio header at {offset}')
        fields = [int(header[6+n*8:14+n*8], 16) for n in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        start = offset + 110
        name_end = start + namesize
        if namesize < 1 or name_end > len(cpio) or cpio[name_end-1] != 0:
            raise ValueError('invalid cpio name')
        name = cpio[start:name_end-1].decode('utf-8', errors='strict')
        payload_start = (name_end+3)//4*4
        end = payload_start + size
        if end > len(cpio):
            raise ValueError('truncated cpio payload')
        if name == 'TRAILER!!!':
            trailer_found = True
            break
        entries.append(dict(name=name, mode=oct(mode), size=size))
        normalized = name.removeprefix('./')
        if normalized in wanted and mode & 0o170000 == 0o100000:
            (destination / normalized).write_bytes(cpio[payload_start:end])
        offset = (end+3)//4*4
    if not trailer_found:
        raise ValueError('cpio trailer absent or entry limit exceeded')
    report['ramdisk_cpio_bytes'] = len(cpio)
    report['cpio_entries'] = entries
    report['source_path'] = str(image)
    (destination / 'layout.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    return {k: v for k, v in report.items() if k not in ('cpio_entries', 'sections')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(json.dumps(extract(args.image, args.destination), indent=2))
