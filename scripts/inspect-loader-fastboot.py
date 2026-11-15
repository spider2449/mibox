"""Check exact stock loader for fastboot evidence without device access."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2'


def inspect(data, addresses):
    if hashlib.sha256(data).hexdigest() != EXPECTED:
        raise ValueError('expanded loader hash mismatch')
    if addresses['source_sha256'] != EXPECTED:
        raise ValueError('command address report hash mismatch')
    base = addresses['derived_link_base']
    if struct.unpack_from('<I', data, 0x40)[0] != base:
        raise ValueError('command base differs from independent vector literal')

    def cstring(pointer):
        at = pointer - base
        if not 0 <= at < len(data):
            return None
        end = data.find(b'\0', at, min(at + 256, len(data)))
        if end < 0:
            return None
        value = data[at:end]
        if not value or any(b < 32 or b > 126 for b in value):
            return None
        return value.decode('ascii')

    candidates = []
    for at in range(0, len(data) - 24 + 1, 4):
        name, argc, repeat, function, usage, help_pointer = struct.unpack_from('<6I', data, at)
        label = cstring(name)
        if (label and len(label) <= 40 and 0 < argc <= 64 and repeat in (0, 1)
                and 0 <= function - base < len(data) and cstring(usage)):
            candidates.append(dict(name=label, table_offset=at,
                                   function_link_address=function, usage=cstring(usage)))
    # Corroborate discovery against every previously resolved exact command.
    for command in addresses['commands']:
        if not any(c['table_offset'] == command['table_offset']
                   and c['name'] == command['name']
                   and c['function_link_address'] == command['function_address']
                   for c in candidates):
            raise ValueError('command scan did not reproduce ' + command['name'])

    hits = {}
    lower = data.lower()
    for token in (b'fastboot', b'getvar:', b'download:', b'flash:', b'bootloader',
                  b'usb_burning', b'usb_burner_reboot'):
        found = []
        start = 0
        while (at := lower.find(token, start)) >= 0:
            found.append(dict(offset=at, context=data[max(0, at - 24):at + 96]
                              .decode('ascii', errors='backslashreplace')))
            start = at + 1
        hits[token.decode()] = found
    return dict(source_sha256=EXPECTED, derived_link_base=base,
                command_candidates=candidates, string_hits=hits,
                fastboot_command_candidates=[c for c in candidates if 'fastboot' in c['name'].lower()],
                device_access=False, reboot_requested=False, flash_command_sent=False,
                conclusion='Fastboot support and independent entry require positive evidence; '
                           'negative strings or candidate-table scan alone cannot prove absence.',
                independent_rescue='NOT VERIFIED')


def main():
    data = (ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin').read_bytes()
    addresses = json.loads((ROOT / 'artifacts/restoration/2026-11-14/loader-command-addresses.json').read_text())
    result = inspect(data, addresses)
    output = ROOT / 'artifacts/restoration/2026-11-15/loader-fastboot-audit.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(commands=len(result['command_candidates']),
                          fastboot_commands=result['fastboot_command_candidates'],
                          string_hit_counts={k: len(v) for k, v in result['string_hits'].items()},
                          report=str(output)), indent=2))


if __name__ == '__main__':
    main()
