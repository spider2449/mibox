"""Audit candidate pre-OS USB rescue-window behavior in the pinned loader."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2'


def main():
    source = ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin'
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED:
        raise ValueError('loader hash mismatch')
    addresses = json.loads((ROOT / 'artifacts/restoration/2026-11-14/loader-command-addresses.json').read_text())
    if addresses['source_sha256'] != EXPECTED:
        raise ValueError('address report hash mismatch')
    base = addresses['derived_link_base']

    def word(at):
        return struct.unpack_from('<I', data, at)[0]

    checks = {0x524: 0xe3a04ffa, 0x528: 0xe0000094,
              0x530: 0xe1a01004, 0x4ec: 0xe5933954, 0x4f0: 0xe0600003,
              0x5af30: 0xe3a01000, 0x5af4c: 0xe7871002,
              0x5b01c: 0xe7840006, 0x5b044: 0xe7840002,
              0x5bbb0: 0xe3500000, 0x5bbc4: 0xe1500003,
              0x5bbc8: 0x9a000007, 0x5bbe4: 0xe3a00002,
              0x5bca4: 0xe3500000, 0x5bca8: 0x0afffffc,
              0x5bcac: 0xe3a00000, 0x5bcb0: 0xe8bd80f8}
    for at, expected in checks.items():
        if word(at) != expected:
            raise ValueError(f'instruction mismatch: {at:#x}')
    # PIC additions use the actual ADD instruction's PC (= address + 8).
    init_state = base + 0x5b018 + 8 + word(0x5b064) + word(0x5b068)
    poll_state = base + 0x5bba4 + 8 + word(0x5bbf4) + word(0x5bbf8)
    identify_state = base + 0x5ade8 + 8 + word(0x5afec) + word(0x5aff0)
    if not init_state == poll_state == identify_state:
        raise ValueError('timeout init/poll/identify do not address the same state')
    timer_register = word(0x4f8) + 0x954
    report = dict(source_sha256=EXPECTED, derived_link_base=base,
        checked_instructions={hex(k): hex(v) for k, v in checks.items()},
        timeout_state_link_address=hex(init_state),
        timer=dict(counter_register=hex(timer_register),
                   expression='unsigned(counter - 1000 * argument) / 1000',
                   counter_frequency='UNKNOWN: not measured on this device',
                   physical_window_duration='UNKNOWN'),
        cancellation=dict(request='vendor identify 0x20',
                          instruction_link_address=hex(base + 0x5af4c),
                          effect='stores zero to the same timeout state; poll then skips deadline',
                          limit='This proves one cancellation path; not an exhaustive handler audit.'),
        return_path='timeout poll returns 2; USB loop exits on nonzero and returns 0 to its caller',
        proposed_location='A pre-OS USB window must run before the main bootm transfers control.',
        proposed_setting_installed=False, device_access=False,
        limitations=['Bootloader and saved environment must remain readable and valid.',
                     'Connected Windows enumeration may hold the loader; physical timeout/exit untested.',
                     'No modified environment image or persistent write command supplied.',
                     'This audit does not prove power-loss-safe installation or physical repair.'],
        independent_rescue='NOT VERIFIED')
    output = ROOT / 'artifacts/restoration/2026-11-15'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'usb-rescue-window-audit.json').write_text(json.dumps(report, indent=2) + '\n')
    for label, start, end in [('timer', 0x4e8, 0x53c), ('identify-cancels-timeout', 0x5af2c, 0x5af64)]:
        result = subprocess.run(['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm',
            f'--adjust-vma={base:#x}', f'--start-address={base+start:#x}',
            f'--stop-address={base+end:#x}', str(source)], capture_output=True, text=True, check=True)
        (output / f'loader-{label}.txt').write_text(result.stdout)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
