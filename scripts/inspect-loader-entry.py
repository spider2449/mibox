"""Audit exact loader reboot-mode and USB wait branches offline."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin'
    data = source.read_bytes()
    expected = '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2'
    addresses = json.loads((ROOT / 'artifacts/restoration/2026-11-14/loader-command-addresses.json').read_text())
    if hashlib.sha256(data).hexdigest() != expected or addresses['source_sha256'] != expected:
        raise ValueError('expanded image/report hash mismatch')
    base = addresses['derived_link_base']

    def word(at):
        if not 0 <= at <= len(data) - 4:
            raise ValueError('word outside expanded image')
        return struct.unpack_from('<I', data, at)[0]

    def text(address):
        at = address - base
        end = data.find(b'\0', at, at + 256) if 0 <= at < len(data) else -1
        if end < 0:
            raise ValueError('string outside expanded image')
        return data[at:end].decode('ascii')

    def relative(register, literal):
        return (register + word(literal)) & 0xffffffff

    checked = {
        0x164e0: 0xe5935004, 0x16504: 0xe1550003,
        0x51710: 0xe5930f04, 0x51714: 0xe3500001,
        0x51718: 0x93a00000, 0x5171c: 0x83a00001,
        0x5172c: 0xe5930f04, 0x51730: 0xe3500001,
        0x51734: 0x13a00000, 0x51738: 0x03a00001,
        0x5b048: 0x059f201c, 0x5b050: 0x15835450,
        0x5b054: 0x05832450, 0x5bbb0: 0xe3500000,
        0x5bbc4: 0xe1500003, 0x5bbc8: 0x9a000007,
    }
    for at, instruction in checked.items():
        if word(at) != instruction:
            raise ValueError(f'audited instruction mismatch at {at:#x}')
    register = base + 0x164f4 + word(0x1659c)
    modes = []
    for reason_literal, name_literal in [(0x165a4, 0x165b4), (0x165a0, 0x165b8),
                                          (0x165a8, 0x165bc), (0x165ac, 0x165c0)]:
        modes.append({'reason': word(reason_literal), 'mode': text(relative(register, name_literal))})
    report = {
        'source_sha256': expected, 'derived_link_base': base,
        'reboot_mode_property': text(relative(register, 0x165b0)), 'reason_mapping': modes,
        'default_mode': text(relative(register, 0x165c4)),
        'startup_override': {
            'observed_read_address': word(0x51724) + 0xf04,
            'helpers': [base + 0x5170c, base + 0x51728],
            'condition': 'first helper accepts unsigned value >1; second accepts value ==1; either selects update',
            'selected_mode': text(relative(register, 0x165bc)),
            'cold_start_control_mechanism': 'UNKNOWN',
            'runtime_value': 'UNKNOWN',
        },
        'usb_wait': {
            'update_handler': next(c['function_address'] for c in addresses['commands'] if c['name'] == 'update'),
            'initialization': base + 0x5b004, 'poll': base + 0x5bb98,
            'zero_argument_default_threshold': word(0x5b06c),
            'nonzero_argument': 'stored directly as threshold',
            'guard': 'timeout comparison skipped when timeout-state word is zero',
            'expiration': 'unsigned timer result strictly greater than threshold; timeout poll returns 2',
            'timer_units': 'UNKNOWN in this bounded audit',
            'safety': 'Distinct handler from sdc_burn; this bounded trace is not a no-storage-write proof for all callees or host requests.',
        },
        'ir_physical_button': 'UNKNOWN', 'device_access': False,
        'register_writes_performed_by_analysis': False, 'permanent_install': 'NOT READY',
    }
    output = ROOT / 'artifacts/restoration/2026-11-14/loader-entry-branches.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    for label, start, end in [('usb-wait-helpers', 0x5bb98, 0x5bcc8),
                              ('usb-timeout-init', 0x5b004, 0x5b0a0),
                              ('startup-state-helpers', 0x5170c, 0x51744)]:
        result = subprocess.run(['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm',
                                 f'--adjust-vma={base:#x}', f'--start-address={base + start:#x}',
                                 f'--stop-address={base + end:#x}', str(source)],
                                capture_output=True, text=True, check=True)
        (output.parent / f'loader-{label}-disassembly.txt').write_text(result.stdout, encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
