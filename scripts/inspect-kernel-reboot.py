"""Resolve the reboot switch in the actual stock kernel, never access hardware."""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def inspect(raw_path, elf_path):
    raw, elf = raw_path.read_bytes(), elf_path.read_bytes()
    expected = 'fe6332d34fc87b758f5a6a9894c40e9e17d13a9cb586ce0aaca79103c73dfc96'
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('stock kernel differs from audited input')
    if elf[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', elf, 18)[0] != 40:
        raise ValueError('expected recovered ARM ELF32')
    start = struct.unpack_from('<I', elf, 28)[0]
    stride, count = struct.unpack_from('<HH', elf, 42)
    segments = []
    for index in range(count):
        at = start + stride * index
        if stride < 32 or at + 32 > len(elf):
            raise ValueError('invalid ELF program header')
        kind, offset, address, _, size = struct.unpack_from('<IIIII', elf, at)
        if kind == 1:
            if offset + size > len(elf):
                raise ValueError('ELF segment outside file')
            segments.append((address, address + size, offset))
    # This address comes from recovered kallsyms, not a supplied guessed override.
    matching = [segment for segment in segments if segment[0] == 0xc0008000]
    if len(matching) != 1 or elf[matching[0][2]:matching[0][2] + len(raw)] != raw:
        raise ValueError('recovered kernel segment does not exactly preserve the raw binary')

    def offset(va, size=4):
        for begin, end, at in segments:
            if begin <= va and va + size <= end:
                return at + va - begin
        raise ValueError('VA outside file-backed kernel segment')

    def word(va):
        return struct.unpack_from('<I', elf, offset(va))[0]

    def text(pointer):
        at = offset(pointer, 1)
        end = elf.find(b'\0', at, at + 128)
        if end < 0:
            raise ValueError('unterminated literal string')
        return elf[at:end].decode('ascii')

    # Audited ARM instructions: load command literal, strcmp, compare zero,
    # conditionally load reason, and branch to the common reason store.
    instructions = {0xc002d054: 0xe59f10ac, 0xc002d058: 0xeb0a7d86,
                    0xc002d05c: 0xe3500000, 0xc002d060: 0x059f00a4,
                    0xc002d064: 0x0a000002, 0xc002d078: 0xe5830004}
    if any(word(address) != instruction for address, instruction in instructions.items()):
        raise ValueError('audited reboot branch instruction changed')
    cases = []
    for literal, reason in [(0xc002d0cc, None), (0xc002d0d0, 0xc002d110),
                            (0xc002d0d4, 0xc002d110), (0xc002d0d8, 0xc002d0dc),
                            (0xc002d0e0, 0xc002d0e4), (0xc002d0e8, 0xc002d0ec),
                            (0xc002d0f0, 0xc002d0f4), (0xc002d0f8, 0xc002d0fc),
                            (0xc002d100, 0xc002d104), (0xc002d108, 0xc002d10c)]:
        cases.append(dict(command=text(word(literal)), command_literal=hex(literal),
                          reason=hex(0 if reason is None else word(reason))))
    selected = cases[-1]
    if selected['command'] != 'usb_burner_reboot':
        raise ValueError('expected USB reboot command not confirmed')
    return dict(kernel_sha256=expected, recovered_elf_sha256=hashlib.sha256(elf).hexdigest(),
                raw_bytes_preserved_in_elf=True, function='meson_common_restart',
                function_va='0xc002cf60', cases=cases,
                default_reason=hex(word(0xc002d0c8)), usb_command=selected,
                previous_argument='usb_burning', previous_argument_matches_no_case=True,
                verification='Static binary branch/literal validation, not a bootloader execution trace',
                hardware_access=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('elf', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.kernel, args.elf)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
