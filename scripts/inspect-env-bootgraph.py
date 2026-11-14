"""Trace only boot-related run references in the verified saved environment."""
import argparse
import hashlib
import json
import re
import struct
import zlib
from pathlib import Path


def inspect(path):
    data = path.read_bytes()
    size = 32768
    if len(data) < size or struct.unpack_from('<I', data)[0] != zlib.crc32(data[4:size]):
        raise ValueError('saved environment CRC32 mismatch')
    variables = {}
    for entry in data[4:size].split(b'\0\0', 1)[0].split(b'\0'):
        if b'=' in entry:
            key, value = entry.split(b'=', 1)
            variables[key.decode('ascii')] = value.decode('ascii')
    pending = ['bootcmd', 'preboot', 'storeboot', 'recovery', 'update']
    commands = {}
    references = []
    while pending:
        name = pending.pop(0)
        if name in commands:
            continue
        value = variables.get(name)
        commands[name] = value if value is not None else 'UNKNOWN: not defined in saved environment'
        if value is None:
            continue
        for match in re.finditer(r'(?:^|[;\s])run\s+([a-zA-Z_][a-zA-Z0-9_]*)', value):
            target = match[1]
            references.append(dict(source=name, target=target, offset=match.start()))
            if target not in commands:
                pending.append(target)
    return dict(source_sha256=hashlib.sha256(data).hexdigest(), crc32_total_bytes=size,
                commands=commands, first_run_argument_references=references,
                note='Static saved env, not executed bootloader trace; first run argument only.',
                environment_writes=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('environment', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.environment)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result['commands'], indent=2))
