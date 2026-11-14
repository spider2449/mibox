"""Inspect stock recovery menu/input evidence without executing firmware."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]


def main():
    image = (ROOT / 'phone-tools/backup/2026-11-13/recovery.img').read_bytes()
    if hashlib.sha256(image).hexdigest() != 'fc96df8c21e8c4904b193cc9605f3a07933fb7847d5ccead758f48e392ef2589':
        raise ValueError('stock recovery hash mismatch')
    if image[:8] != b'ANDROID!':
        raise ValueError('Android header missing')
    kernel_size, _, ramdisk_size = struct.unpack_from('<III', image, 8)
    page = struct.unpack_from('<I', image, 36)[0]
    if page != 2048:
        raise ValueError('unexpected page size')
    start = page + (kernel_size + page - 1) // page * page
    if start + ramdisk_size > len(image):
        raise ValueError('ramdisk outside image')
    data = gzip.decompress(image[start:start + ramdisk_size])
    cursor = 0
    binary = None
    input_files = []
    keymap = None
    trailer = False
    for _ in range(10000):
        header = data[cursor:cursor + 110]
        if len(header) != 110 or header[:6] != b'070701':
            raise ValueError('invalid cpio header')
        fields = [int(header[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        end_name = cursor + 110 + namesize
        if namesize < 1 or end_name > len(data) or data[end_name - 1] != 0:
            raise ValueError('invalid cpio name')
        name = data[cursor + 110:end_name - 1].decode().removeprefix('./')
        begin = (end_name + 3) // 4 * 4
        end = begin + size
        if end > len(data):
            raise ValueError('cpio payload outside archive')
        if name == 'TRAILER!!!':
            trailer = True
            break
        if re.search(r'remote|keylayout|\.kl$|\.kcm$|recovery.*\.(conf|rc)$', name, re.I):
            input_files.append({'name': name, 'bytes': size, 'mode': oct(mode)})
        if name == 'sbin/recovery':
            if binary is not None or mode & 0o170000 != 0o100000:
                raise ValueError('unexpected recovery entry')
            binary = data[begin:end]
        if name == 'etc/recovery.kl':
            if keymap is not None or mode & 0o170000 != 0o100000:
                raise ValueError('unexpected recovery keymap entry')
            keymap = data[begin:end].decode('ascii')
        cursor = (end + 3) // 4 * 4
    if not trailer or binary is None:
        raise ValueError('missing recovery or cpio trailer')
    if binary[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', binary, 18)[0] != 40:
        raise ValueError('expected ARM ELF32')
    shoff = struct.unpack_from('<I', binary, 32)[0]
    stride, count, string_index = struct.unpack_from('<HHH', binary, 46)
    if stride < 40 or shoff + stride * count > len(binary) or string_index >= count:
        raise ValueError('invalid section headers')
    sections = [struct.unpack_from('<10I', binary, shoff + i * stride) for i in range(count)]
    table = sections[string_index]
    if table[4] + table[5] > len(binary):
        raise ValueError('section string table out of bounds')
    section_names = binary[table[4]:table[4] + table[5]]
    section_report = []
    for section in sections:
        name_end = section_names.find(b'\0', section[0])
        if section[0] >= len(section_names) or name_end < 0:
            raise ValueError('invalid section name')
        section_report.append({'name': section_names[section[0]:name_end].decode('ascii'),
                               'type': section[1], 'address': section[3],
                               'file_offset': section[4], 'bytes': section[5]})
    mapping = {}
    if keymap is not None:
        for line in keymap.splitlines():
            line = line.split('#', 1)[0].strip()
            if line:
                kind, *codes = line.split()
                if kind in mapping:
                    raise ValueError('duplicate keymap row')
                mapping[kind] = [int(code) for code in codes]
    pattern = re.compile(rb'adb|sideload|reboot|wipe|factory|remote|key|recovery|usb|volume|power|bluetooth', re.I)
    strings = [{'file_offset': m.start(), 'text': m.group().decode('ascii')}
               for m in re.finditer(rb'[\x20-\x7e]{5,}', binary) if pattern.search(m.group())]
    # Fixed private output path, never a path taken from the archive.
    destination = ROOT / 'phone-tools/runtime/2026-11-14/recovery-interface/recovery.elf'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(binary)
    report = {'source_sha256': hashlib.sha256(image).hexdigest(),
              'cpio_sha256': hashlib.sha256(data).hexdigest(),
              'recovery_sha256': hashlib.sha256(binary).hexdigest(), 'bytes': len(binary),
              'input_related_archive_entries': input_files, 'matching_strings': strings,
              'recovery_keymap_text': keymap,
              'recovery_keymap_rows': mapping,
              'elf_sections': section_report,
              'elf_has_symbol_table': any(s[1] in (2, 11) for s in sections),
              'files_executed': False, 'device_access': False,
              'limit': 'String presence is not proof of reachable UI, input mapping, ADB startup or bootloader keys.'}
    output = ROOT / 'artifacts/restoration/2026-11-14/recovery-interface.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'sha256': report['recovery_sha256'], 'bytes': len(binary),
                      'matching_strings': len(strings), 'input_files': input_files}, indent=2))


if __name__ == '__main__':
    main()
