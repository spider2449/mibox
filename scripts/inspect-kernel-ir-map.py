"""Extract the exact MiBOX IR table from a byte-preserving recovered ELF."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    raw = (ROOT / 'phone-tools/extracted/2026-11-13/boot1/kernel-expanded.bin').read_bytes()
    source = ROOT / 'target/kernel-analysis/stock-kernel.elf'
    elf = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != 'fe6332d34fc87b758f5a6a9894c40e9e17d13a9cb586ce0aaca79103c73dfc96':
        raise ValueError('expanded stock kernel hash mismatch')
    if hashlib.sha256(elf).hexdigest() != 'efd752307251b9ec1279f5d8c586d8f6696d6cd9ada150ef9952eb7c497be16d':
        raise ValueError('recovered ELF hash mismatch')
    phoff = struct.unpack_from('<I', elf, 28)[0]
    stride, count = struct.unpack_from('<HH', elf, 42)
    segments = []
    for index in range(count):
        at = phoff + index * stride
        if stride < 32 or at + 32 > len(elf):
            raise ValueError('invalid program header')
        kind, offset, address, _, size = struct.unpack_from('<IIIII', elf, at)
        if kind == 1:
            if offset + size > len(elf):
                raise ValueError('load segment outside ELF')
            segments.append((address, address + size, offset))

    def payload(address, size):
        matches = [(begin, end, offset) for begin, end, offset in segments if begin <= address and address + size <= end]
        if len(matches) != 1:
            raise ValueError('ambiguous or absent file-backed address')
        begin, _, offset = matches[0]
        return elf[offset + address - begin:offset + address - begin + size]

    if payload(0xc0008000, len(raw)) != raw:
        raise ValueError('ELF does not preserve raw kernel')

    def word(address):
        return struct.unpack('<I', payload(address, 4))[0]

    for address, expected in {
            0xc03f3d28: 0xe1a01223, 0xc03f3d34: 0xe6ff9071,
            0xc03f3de0: 0xe59f21e8, 0xc03f3de8: 0xe2820054,
            0xc03f3dec: 0xe7900183, 0xc03f3df0: 0xe1500009,
            0xc03f3df8: 0x05924058, 0xc03f3e04: 0xe353001d}.items():
        if word(address) != expected:
            raise ValueError(f'IR instruction mismatch at {address:#x}')
    anchor = word(0xc03f3fd0)
    table = anchor + 0x54
    entries = []
    for index in range(29):
        identifier, key = struct.unpack('<II', payload(table + index * 8, 8))
        entries.append({'index': index, 'identifier': identifier, 'linux_keycode': key})
    output = ROOT / 'artifacts/remote-input/kernel-ir-map'
    output.mkdir(parents=True, exist_ok=True)
    report = {'kernel_sha256': hashlib.sha256(raw).hexdigest(), 'elf_sha256': hashlib.sha256(elf).hexdigest(),
              'raw_bytes_preserved': True, 'table_address': table, 'entry_count': 29,
              'identifier_expression': '(kernel_assembled_word >> 4) & 0xffff',
              'entries': entries, 'device_access': False,
              'limit': 'Kernel table extraction only; loader format equivalence and owner physical button mapping require separate evidence.'}
    (output / 'map.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    result = subprocess.run(['arm-linux-gnueabihf-objdump', '-d', '--start-address=0xc03f3758',
                             '--stop-address=0xc03f3fec', str(source)],
                            capture_output=True, text=True, check=True)
    (output / 'ir-fiq-disassembly.txt').write_text(result.stdout, encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
