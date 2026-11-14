"""Inventory exact saved pre-Android rescue evidence; no device operations."""
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def pinned(name, expected):
    data = (ROOT / f'phone-tools/backup/2026-11-13/{name}.img').read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f'{name} backup hash mismatch')
    return data


def main():
    env = pinned('env', 'e85c14d547bde485ded38f41050f197ba33dfe24cc543bec61f11eafea2f812a')
    loader = pinned('bootloader', 'a5fae79fe631cf557d06f6fda8bc5ae8bbf1eca5359f9f76b17bafaddd29068b')
    if struct.unpack_from('<I', env)[0] != zlib.crc32(env[4:32768]):
        raise ValueError('environment CRC mismatch')
    variables = {}
    for entry in env[4:32768].split(b'\0\0', 1)[0].split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            variables[key.decode('ascii')] = value.decode('ascii')
    names = ('preboot', 'bootcmd', 'storeboot', 'recovery', 'update', 'update_key',
             'switch_bootmode', 'usb_burning', 'storeargs', 'bootdelay', 'upgrade_step')
    commands = {name: variables.get(name, 'UNKNOWN') for name in names}
    offsets = {}
    for name in names:
        prefix = name.encode() + b'='
        start = env.find(b'\0' + prefix, 4, 32768)
        if start >= 0:
            offsets[name] = start + 1
        elif env[4:].startswith(prefix):
            offsets[name] = 4
    pattern = re.compile(rb'recovery|burn|update|bootm|irdetect|monitor_bt|U-Boot|aml_autoscript', re.I)
    strings = [{'offset': match.start(), 'text': match.group().decode('ascii')}
               for match in re.finditer(rb'[\x20-\x7e]{5,}', loader)
               if pattern.search(match.group())]
    signatures = {}
    for label, magic in [('gzip', b'\x1f\x8b\x08'), ('xz', b'\xfd7zXZ\x00'),
                         ('lz4_frame', b'\x04\x22\x4d\x18'), ('uimage', b'\x27\x05\x19\x56'),
                         ('fdt', b'\xd0\x0d\xfe\xed'), ('elf', b'\x7fELF')]:
        signatures[label] = [m.start() for m in re.finditer(re.escape(magic), loader)]
    report = {
        'scope': 'exact saved binaries; static evidence only',
        'commands': commands, 'environment_entry_file_offsets': offsets,
        'loader_matching_ascii_runs': strings, 'loader_magic_candidates': signatures,
        'loader_nonzero_blocks_64KiB': [
            {'offset': offset, 'nonzero_bytes': sum(b != 0 for b in loader[offset:offset+65536])}
            for offset in range(0, len(loader), 65536)],
        'findings': {
            'remote_conditions': 'update_key tests monitor_bt_cmdline and irdetect; either success runs recovery',
            'remote_key_values': 'UNKNOWN',
            'remote_cold_boot_tested': False,
            'failed_bootm_fallback': 'storeboot contains bootm;run recovery; only applies if execution returns',
            'hung_kernel_fallback': 'UNKNOWN; no evidence this script regains control',
            'loader_entry_without_android': 'UNKNOWN',
            'persistence_hazard': 'storeargs includes saveenv; preboot also has conditional defenv/saveenv',
            'signature_scan_limit': 'magic matches are candidates only; absence does not rule out compression or boot ROM entry',
        },
        'device_access': False, 'permanent_install': 'NOT READY',
    }
    output = ROOT / 'artifacts/restoration/2026-11-14/rescue-entry.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'matching_strings': strings, 'magic_candidates': signatures,
                      'findings': report['findings']}, indent=2))


if __name__ == '__main__':
    main()
