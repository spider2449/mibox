"""Resolve audited ARM Thumb literal references in this box's update library.

Reference sites come from objdump switchBootSystem at VA 0xb090. This is a
read-only static report, not a command to switch systems or set properties.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect(path):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != 'd6cb8f1b0822f6c578b888cb92c85a6837e245587c69d96d604542357a497d45':
        raise ValueError('library differs from audited device binary; refuse fixed offsets')
    if data[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 40:
        raise ValueError('expected ARM ELF32 little endian')
    offset = struct.unpack_from('<I', data, 28)[0]
    stride, count = struct.unpack_from('<HH', data, 42)
    segments = []
    for i in range(count):
        header = offset + i * stride
        if stride < 32 or header + 32 > len(data):
            raise ValueError('invalid program header')
        kind, start, va, _, size = struct.unpack_from('<IIIII', data, header)
        if kind == 1:
            if start + size > len(data):
                raise ValueError('load segment out of bounds')
            segments.append((va, va + size, start))

    def file_offset(va, size=1):
        for begin, end, start in segments:
            if begin <= va and va + size <= end:
                return start + va - begin
        raise ValueError(f'VA outside file-backed segment: {va:#x}')

    entries = []
    for name, literal, pc in [
        ('default numeric value', 0xb178, 0xb0ac),
        ('slot property prefix', 0xb17c, 0xb0d0),
        ('slot property suffix', 0xb180, 0xb0d2),
        ('slot property format', 0xb184, 0xb0d6),
        ('property_get name', 0xb188, 0xb0e8),
        ('conditional property_set value', 0xb18c, 0xb10c),
        ('second default numeric value', 0xb190, 0xb11a),
        ('final property_set name 1', 0xb19c, 0xb14a),
        ('final property_set name 2', 0xb1a0, 0xb154),
        ('final property_set value 2', 0xb1a4, 0xb156),
    ]:
        displacement = struct.unpack_from('<i', data, file_offset(literal, 4))[0]
        target = (pc + displacement) & 0xffffffff
        start = file_offset(target)
        end = data.find(b'\0', start, start + 256)
        if end < 0:
            raise ValueError('unterminated referenced string')
        entries.append(dict(role=name, literal_va=hex(literal), pc=hex(pc),
                            target_va=hex(target), text=data[start:end].decode('ascii')))
    return dict(source_sha256=hashlib.sha256(data).hexdigest(),
                function_va='0xb090', references=entries,
                verification='Audited literal sites, not control-flow emulation',
                property_writes_executed=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.library)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
