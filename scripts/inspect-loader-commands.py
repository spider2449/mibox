"""Derive exact loader command addresses from string/table consistency."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin'
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2':
        raise ValueError('expanded loader hash mismatch')
    name = data.index(b'irdetect\0')
    usage = data.index(b'Detect IR Key to start recovery system\0')
    candidates = []
    for at in range(0, len(data) - 24, 4):
        pointer, argc, repeat, function, help_pointer, _ = struct.unpack_from('<6I', data, at)
        base = pointer - name
        if (help_pointer - pointer == usage - name and 0 < argc <= 64 and repeat in (0, 1)
                and base > 0 and base % 4096 == 0 and 0 <= function - base < len(data)):
            candidates.append((base, at))
    if len(candidates) != 1:
        raise ValueError('ambiguous command-derived base')
    base, ir_table = candidates[0]
    # Independent vector-area self-address literal corroborates table-derived base.
    if struct.unpack_from('<I', data, 0x40)[0] != base:
        raise ValueError('vector literal does not corroborate base')
    commands = []
    for label in ('irdetect', 'monitor_bt_cmdline', 'saveenv', 'update', 'get_rebootmode', 'sdc_burn'):
        needle = label.encode() + b'\0'
        offsets = set()
        position = 0
        while (position := data.find(needle, position)) >= 0:
            # C string pooling can point at a suffix of a longer string.
            offsets.add(position)
            position += 1
        matches = []
        for at in range(0, len(data) - 24, 4):
            words = struct.unpack_from('<6I', data, at)
            if (words[0] - base in offsets and 0 < words[1] <= 64 and words[2] in (0, 1)
                    and 0 <= words[3] - base < len(data)):
                matches.append({'name': label, 'table_offset': at, 'words': list(words),
                                'function_address': words[3], 'function_file_offset': words[3] - base})
        if len(matches) != 1:
            raise ValueError(f'ambiguous command registration: {label}, {len(matches)} matches')
        commands.extend(matches)
    report = {'source_sha256': hashlib.sha256(data).hexdigest(), 'derived_link_base': base,
              'derivation': 'irdetect name/usage pointer difference and command fields; corroborated by vector-area literal at file 0x40',
              'commands': commands, 'device_access': False,
              'limit': 'Link addresses derived statically; actual runtime relocation and hardware behavior remain unobserved.'}
    def word(at):
        return struct.unpack_from('<I', data, at)[0]

    def call_target(at):
        instruction = word(at)
        if instruction >> 24 != 0xeb:
            raise ValueError('expected unconditional ARM BL')
        displacement = instruction & 0xffffff
        if displacement & 0x800000:
            displacement -= 0x1000000
        return base + at + 8 + displacement * 4

    for at, expected in {0x70644: 0xe59f0070, 0x7064c: 0xe1510000,
                         0x70650: 0x13a00000, 0x70654: 0x03a00001,
                         0x7070c: 0xe3a00000, 0x70728: 0xe3a00001}.items():
        if word(at) != expected:
            raise ValueError('IR audited instruction mismatch')
    bt_save = call_target(0xdbdc)
    command_save = call_target(0x154b4)
    if bt_save != command_save:
        raise ValueError('BT and saveenv do not share save backend')
    report['audited_paths'] = {
        'ir_assembled_value': word(0x706bc),
        'ir_equality_result': 1,
        'irdetect_command_on_detection': 0,
        'irdetect_command_without_detection': 1,
        'ir_value_limit': 'Internal assembled IR value, not a Linux keycode or proven physical remote button.',
        'bt_success_call_address': base + 0xdbdc,
        'saveenv_backend_call_address': base + 0x154b4,
        'shared_environment_save_backend': bt_save,
        'bt_persistence_limit': 'Success branch invokes the same backend as saveenv; no physical execution or persistence result observed.',
    }
    output = ROOT / 'artifacts/restoration/2026-11-14/loader-command-addresses.json'
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    # Retain disassembly of the IR handler and preceding helpers, and BT handler.
    for command in commands:
        if command['name'] == 'saveenv':
            continue
        function = command['function_address']
        begin = function - {'irdetect': 0x24c, 'monitor_bt_cmdline': 0x260}.get(command['name'], 0)
        end = function + (0x44 if command['name'] == 'irdetect' else 0x500)
        result = subprocess.run(['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm',
                                 f'--adjust-vma={base:#x}', f'--start-address={begin:#x}',
                                 f'--stop-address={end:#x}', str(source)],
                                check=True, capture_output=True, text=True)
        (output.parent / f"loader-{command['name']}-disassembly.txt").write_text(result.stdout, encoding='utf-8')
    result = subprocess.run(['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm',
                             f'--adjust-vma={base:#x}', f'--start-address={base + 0x15490:#x}',
                             f'--stop-address={base + 0x154d0:#x}', str(source)],
                            check=True, capture_output=True, text=True)
    (output.parent / 'loader-saveenv-disassembly.txt').write_text(result.stdout, encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
