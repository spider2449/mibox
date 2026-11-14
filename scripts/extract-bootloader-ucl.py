"""Decode exact saved loader's uclpack stream with bounded safe NRV decoding.

Format reference: https://github.com/rockbox/rockbox/blob/master/tools/ucl/uclpack.c
Requires the privately unpacked Ubuntu noble libucl1 1.03+repack-6 amd64 package.
"""
import ctypes
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_HASH = '2117fbffff0638da71bf6a741dd05e7f54f405d3070a1e5b940135260f642390'


def main():
    backup = ROOT / 'phone-tools/backup/2026-11-13/bootloader.img'
    data = backup.read_bytes()
    if hashlib.sha256(data).hexdigest() != 'a5fae79fe631cf557d06f6fda8bc5ae8bbf1eca5359f9f76b17bafaddd29068b':
        raise ValueError('bootloader hash mismatch')
    ref = ROOT / 'phone-tools/source-reference'
    package = ref / 'libucl1_1.03+repack-6_amd64.deb'
    if hashlib.sha256(package.read_bytes()).hexdigest() != PACKAGE_HASH:
        raise ValueError('decoder package hash mismatch')
    libraries = list((ref / 'ucl-runtime').glob('**/libucl.so.1.0.0'))
    if len(libraries) != 1:
        raise ValueError('expected one unpacked UCL library')
    library = libraries[0]
    if hashlib.sha256(library.read_bytes()).hexdigest() != 'e095277fd56a3a07441ebeace274d2d7a83e6cf275eac9aeebf172433b75783a':
        raise ValueError('unpacked decoder library hash mismatch')
    decoder = ctypes.CDLL(str(library)).ucl_nrv2d_decompress_safe_8
    decoder.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p,
                        ctypes.POINTER(ctypes.c_uint), ctypes.c_void_p]
    decoder.restype = ctypes.c_int
    base = 0x8000
    cursor = base

    def take(count):
        nonlocal cursor
        if count < 0 or cursor + count > len(data):
            raise ValueError('container exceeds backup')
        result = data[cursor:cursor + count]
        cursor += count
        return result

    def word():
        return struct.unpack('>I', take(4))[0]

    if take(8) != b'\x00\xe9UCL\xff\x01\x1a':
        raise ValueError('UCL magic mismatch')
    flags = word()
    method, level = take(2)
    block_size = word()
    if flags != 1 or method != 0x2d or not 0 <= level <= 10 or not 1024 <= block_size <= 8388608:
        raise ValueError('unexpected UCL container settings')
    expanded = bytearray()
    blocks = []
    for _ in range(128):
        out_size = word()
        if out_size == 0:
            break
        in_size = word()
        if not 0 < in_size <= out_size <= block_size or len(expanded) + out_size > 16777216:
            raise ValueError('invalid block limits')
        offset = cursor
        payload = take(in_size)
        if in_size == out_size:
            output = payload
        else:
            source = ctypes.create_string_buffer(payload)
            destination = ctypes.create_string_buffer(out_size)
            actual = ctypes.c_uint(out_size)
            status = decoder(source, in_size, destination, ctypes.byref(actual), None)
            if status != 0 or actual.value != out_size:
                raise ValueError(f'UCL decode failed: {status}, output {actual.value}')
            output = destination.raw
        expanded.extend(output)
        blocks.append({'file_offset': offset, 'compressed_bytes': in_size, 'expanded_bytes': out_size})
    else:
        raise ValueError('container block limit exceeded')
    checksum = word()
    if checksum != zlib.adler32(expanded):
        raise ValueError('expanded Adler32 mismatch')
    private = ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl'
    private.mkdir(parents=True, exist_ok=True)
    (private / 'bootloader-expanded.bin').write_bytes(expanded)
    keywords = re.compile(rb'U-Boot|irdetect|monitor_bt|recovery|burn|update_key|keycode|key_code|press.*key|remote|reboot_mode', re.I)
    strings = [{'expanded_file_offset': m.start(), 'text': m.group().decode('ascii')}
               for m in re.finditer(rb'[\x20-\x7e]{5,}', expanded) if keywords.search(m.group())]
    report = {'source_sha256': hashlib.sha256(data).hexdigest(), 'container_offset': base,
              'container_end': cursor, 'flags': flags, 'method': method, 'level': level,
              'block_size': block_size, 'blocks': blocks, 'adler32_match': True,
              'adler32': f'{checksum:08x}', 'expanded_bytes': len(expanded),
              'expanded_sha256': hashlib.sha256(expanded).hexdigest(),
              'decoder_package_sha256': PACKAGE_HASH,
              'decoder_library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
              'matching_strings': strings, 'firmware_executed': False, 'device_access': False,
              'execution_base': 'UNKNOWN', 'cold_start_keys': 'UNKNOWN'}
    output = ROOT / 'artifacts/restoration/2026-11-14/bootloader-ucl.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ('expanded_bytes', 'expanded_sha256', 'adler32_match', 'matching_strings')}, indent=2))


if __name__ == '__main__':
    main()
