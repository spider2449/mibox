"""Compare pinned IR bit assembly; report candidate transforms, not button guesses."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]


def main():
    loader = (ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin').read_bytes()
    kernel = (ROOT / 'phone-tools/extracted/2026-11-13/boot1/kernel-expanded.bin').read_bytes()
    if hashlib.sha256(loader).hexdigest() != '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2':
        raise ValueError('loader hash mismatch')
    if hashlib.sha256(kernel).hexdigest() != 'fe6332d34fc87b758f5a6a9894c40e9e17d13a9cb586ce0aaca79103c73dfc96':
        raise ValueError('kernel hash mismatch')

    def lw(at):
        if not 0 <= at <= len(loader) - 4:
            raise ValueError('loader word outside file; BSS is not file content')
        return struct.unpack_from('<I', loader, at)[0]

    def kw(address):
        at = address - 0xc0008000
        if not 0 <= at <= len(kernel) - 4:
            raise ValueError('kernel word outside pinned load segment')
        return struct.unpack_from('<I', kernel, at)[0]

    for at, expected in {0x70614: 0x81811410, 0x70658: 0xe0634004,
                         0x706c0: 0x000001c0}.items():
        if lw(at) != expected:
            raise ValueError('loader audited bit-assembly mismatch')
    for at, expected in {0xc03f3a90: 0xe3530008, 0xc03f3c28: 0xe353000a,
                         0xc03f3d28: 0xe1a01223, 0xc03f3d34: 0xe6ff9071}.items():
        if kw(at) != expected:
            raise ValueError('kernel audited bit-assembly mismatch')
    base = 0x8f800000  # Corroborate using prior registration report and vector literal.
    addresses = json.loads((ROOT / 'artifacts/restoration/2026-11-14/loader-command-addresses.json').read_text())
    if addresses['derived_link_base'] != base or lw(0x40) != base:
        raise ValueError('loader link-base mismatch')
    got = 0x70570 + lw(0x706a4)
    start_pointer = lw(got + lw(0x706c0))
    step_pointer = lw(got + lw(0x706b8))
    start = lw(start_pointer - base)
    step = lw(step_pointer - base)
    if (start, step) != (20, 2):
        raise ValueError('unexpected loader symbol positions')
    target = lw(0x706bc)
    anchor = kw(0xc03f3fd0)
    entries = [struct.unpack('<II', kernel[anchor + 0x54 + i * 8 - 0xc0008000:
                                          anchor + 0x54 + i * 8 + 8 - 0xc0008000]) for i in range(29)]

    def checksum(identifier):
        return ((identifier >> 12) ^ (identifier >> 8) ^ (identifier >> 4) ^ identifier) & 15

    candidate = target >> 2
    identifier = (candidate >> 4) & 0xffff
    candidate_valid = (candidate & 15) == checksum(identifier)
    if not candidate_valid:
        raise ValueError('reported candidate checksum no longer holds')
    modeled = [{'identifier': code, 'linux_keycode': key,
                'kernel_word_with_checksum': (code << 4) | checksum(code),
                'loader_candidate_with_trailing_zero': ((code << 4) | checksum(code)) << 2}
               for code, key in entries]
    timing_values = []
    current = 0
    for at in (0x704c8, 0x704dc, 0x704e4, 0x704ec, 0x704f4,
               0x704fc, 0x70504, 0x7050c, 0x70514, 0x7051c):
        instruction = lw(at)
        operation = instruction & 0x0ffff000
        if instruction & 0x0ff0f000 == 0x03000000:  # MOVW r0, imm16
            current = ((instruction >> 4) & 0xf000) | (instruction & 0xfff)
        else:
            rotate = ((instruction >> 8) & 15) * 2
            immediate = instruction & 255
            immediate = ((immediate >> rotate) | (immediate << (32 - rotate))) & 0xffffffff if rotate else immediate
            if operation == 0x03a00000:  # MOV r0, immediate
                current = immediate
            elif operation == 0x02800000:  # ADD r0, r0, immediate
                current += immediate
            else:
                raise ValueError('unexpected timing initializer instruction')
        timing_values.append(current)
    report = {
        'loader_sha256': hashlib.sha256(loader).hexdigest(), 'kernel_sha256': hashlib.sha256(kernel).hexdigest(),
        'loader_start_shift': start, 'loader_shift_step': step,
        'loader_nonnegative_symbol_positions': list(range(start, -1, -step)),
        'kernel_symbol_count': 10, 'loader_target': target,
        'loader_initial_timing_pairs': [timing_values[i:i+2] for i in range(0, 10, 2)],
        'timing_units': 'UNKNOWN in this audit; do not treat loader raw counters as kernel nanoseconds',
        'candidate_transform': {
            'expression': 'kernel_word = loader_word >> 2; assumes identical symbol interpretation and one extra trailing loader symbol',
            'candidate_kernel_word': candidate, 'candidate_identifier': identifier,
            'checksum_nibble': candidate & 15, 'computed_checksum': checksum(identifier),
            'checksum_matches': candidate_valid, 'discarded_trailing_symbol': target & 3,
            'matching_kernel_table_entries': [{'identifier': code, 'linux_keycode': key} for code, key in entries if code == identifier],
            'status': 'CANDIDATE ONLY; no captured waveform or demonstrated decoder equivalence',
        },
        'modeled_known_table': modeled,
        'matching_modeled_loader_targets': [entry for entry in modeled if entry['loader_candidate_with_trailing_zero'] == target],
        'physical_recovery_button': 'UNKNOWN', 'button_chord': 'UNKNOWN',
        'device_access': False, 'reboot_requested': False,
    }
    output = ROOT / 'artifacts/remote-input/kernel-ir-map/decoder-comparison.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report['candidate_transform'], indent=2))


if __name__ == '__main__':
    main()
