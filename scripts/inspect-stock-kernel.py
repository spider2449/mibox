"""Inspect a stock legacy uImage or bounded embedded gzip streams offline."""
import argparse
import hashlib
import json
import lzma
import re
import struct
import zlib
from pathlib import Path


def main(root):
    source = root / 'phone-tools/extracted/2026-11-13/boot1/kernel.bin'
    data = source.read_bytes()
    candidates = []
    output = root / 'artifacts/platform/2026-11-13/kernel-inspection.json'
    container = None
    if data[:4] == bytes.fromhex('27051956'):
        magic, hcrc, timestamp, size, load, entry, dcrc, os_id, arch, kind, compression, name = struct.unpack_from('>7I4B32s', data)
        if size > len(data)-64:
            raise ValueError('uImage payload outside file')
        header = bytearray(data[:64])
        header[4:8] = bytes(4)
        payload = data[64:64+size]
        container = dict(format='U-Boot legacy uImage', payload_bytes=size,
                         timestamp=timestamp, load_address=load, entry_address=entry,
                         os=os_id, arch=arch, image_type=kind, compression=compression,
                         name=name.rstrip(b'\0').decode('ascii'),
                         header_crc_matches=zlib.crc32(header)==hcrc,
                         payload_crc_matches=zlib.crc32(payload)==dcrc)
        if not container['header_crc_matches'] or not container['payload_crc_matches']:
            raise ValueError('uImage CRC mismatch')
        if compression == 3:  # IH_COMP_LZMA in U-Boot include/image.h
            decoder = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE, memlimit=128*1024*1024)
            plain = decoder.decompress(payload, max_length=64*1024*1024+1)
            if not decoder.eof or len(plain) > 64*1024*1024 or decoder.unused_data:
                raise ValueError('invalid, excessive or trailing LZMA data')
            (source.parent / 'kernel-expanded.bin').write_bytes(plain)
            strings = [(m.start(), m.group().decode('ascii')) for m in re.finditer(rb'[\x20-\x7e]{6,}', plain)]
            candidates.append(dict(compression='lzma', payload_offset=64,
                expanded_bytes=len(plain), sha256=hashlib.sha256(plain).hexdigest(),
                linux_version_strings=[s for _, s in strings if 'Linux version ' in s],
                relevant_strings=[dict(offset=offset, text=text) for offset, text in strings
                    if any(word in text.lower() for word in ('watchdog', 'boot_monitor', 'boot_timer',
                            'android_usb', 'ttygs', 'console=', 'aml_reserved', 'panic='))],
                note='Compiled strings do not prove active devices, call paths or register semantics.'))
    for match in list(re.finditer(b'\x1f\x8b\x08', data))[:1000]:
        start = match.start()
        decoder = zlib.decompressobj(31)
        try:
            plain = decoder.decompress(data[start:], 64*1024*1024+1)
        except zlib.error:
            continue
        if not decoder.eof or len(plain) > 64*1024*1024:
            continue
        consumed = len(data)-start-len(decoder.unused_data)
        strings = [(m.start(), m.group().decode('ascii'))
                   for m in re.finditer(rb'[\x20-\x7e]{6,}', plain)]
        version = [s for _, s in strings if 'Linux version ' in s]
        record = dict(gzip_offset=start, gzip_bytes=consumed, expanded_bytes=len(plain),
                      sha256=hashlib.sha256(plain).hexdigest(), linux_version_strings=version)
        if version:
            (source.parent / 'kernel-expanded.bin').write_bytes(plain)
            record['relevant_strings'] = [dict(offset=offset, text=text) for offset, text in strings
                if any(word in text.lower() for word in ('watchdog', 'boot_monitor', 'boot_timer',
                       'android_usb', 'ttygs', 'console=', 'aml_reserved', 'panic='))]
            record['note'] = 'Compiled strings do not prove active devices, call paths or register semantics.'
        candidates.append(record)
    output.write_text(json.dumps({'source_sha256': hashlib.sha256(data).hexdigest(), 'container': container,
                                'streams': candidates}, indent=2), encoding='utf-8')
    print(f'{len(candidates)} decoded streams; report: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    main(parser.parse_args().root)
