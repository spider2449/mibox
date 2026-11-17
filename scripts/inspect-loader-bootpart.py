#!/usr/bin/env python3
"""C1: locate and disassemble the stock U-Boot `switch_bootpart` and
`modify_cmdline` command handlers (offline; no firmware code runs).

Uses the pinned expanded bootloader and the command-table base derivation of
inspect-loader-commands.py. For each handler, follows direct BL calls one level
deep, disassembles them, and resolves PC-relative literal loads that point at
printable strings, which shows which env variables / partition names the code
reads or writes. Output: artifacts/boot-selection/2026-11-17/.
"""
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'phone-tools/runtime/2026-11-14/bootloader-ucl/bootloader-expanded.bin'
SHA256 = '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2'
BASE = 0x8f800000
# Position-independent string base: handlers compute `add rX, pc, lit` = 0x8f8abe6c
# and address strings as base + signed literal (verified in switch_bootpart).
STRING_BASE = 0x8f8abe6c
OUT = ROOT / 'artifacts/boot-selection/2026-11-17'


def cstring(data, offset):
    if not 0 <= offset < len(data):
        return None
    end = data.find(b'\0', offset, offset + 200)
    if end <= offset:
        return None
    s = data[offset:end]
    if all(32 <= b < 127 or b in (9, 10) for b in s) and len(s) >= 2:
        return s.decode()
    return None


def registration(data, label):
    needle = label.encode() + b'\0'
    offsets, position = set(), 0
    while (position := data.find(needle, position)) >= 0:
        offsets.add(position)
        position += 1
    matches = []
    for at in range(0, len(data) - 24, 4):
        w = struct.unpack_from('<6I', data, at)
        if w[0] - BASE in offsets and 0 < w[1] <= 64 and w[2] in (0, 1) and 0 <= w[3] - BASE < len(data):
            matches.append(dict(table_offset=at, max_args=w[1], repeatable=w[2],
                                function=w[3], usage=cstring(data, w[4] - BASE),
                                help=cstring(data, w[5] - BASE)))
    if len(matches) != 1:
        raise ValueError(f'{label}: {len(matches)} registrations')
    return matches[0]


def function_end(data, start, limit=0x800):
    # Stop after a return (pop {...,pc} / bx lr) that is followed by the
    # literal pool or another push; bounded by limit.
    for at in range(start, start + limit, 4):
        w = struct.unpack_from('<I', data, at)[0]
        if (w & 0x0fff8000) == 0x08bd8000 or w == 0xe12fff1e:
            nxt = struct.unpack_from('<I', data, at + 4)[0]
            if (nxt & 0xffff0000) == 0xe92d0000 or (nxt >> 24) not in range(0xe0, 0xf0):
                # include literal pool words that follow
                end = at + 4
                while end < start + limit and (struct.unpack_from('<I', data, end)[0] & 0xffff0000) != 0xe92d0000:
                    end += 4
                return end
    return start + limit


def analyse(data, address, name, depth=0, seen=None):
    seen = seen if seen is not None else {}
    if address in seen or len(seen) > 40:
        return seen
    start = address - BASE
    end = function_end(data, start)
    dis = subprocess.run(['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm',
                          f'--adjust-vma={BASE:#x}', f'--start-address={address:#x}',
                          f'--stop-address={BASE + end:#x}', str(SOURCE)],
                         capture_output=True, text=True, check=True).stdout
    strings, calls = [], []
    for line in dis.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*)', line)
        if not m:
            continue
        at, word, op, args = int(m.group(1), 16), int(m.group(2), 16), m.group(3), m.group(4)
        lit = re.search(r'\[pc, #(-?\d+)\]', args)
        if op.startswith('ldr') and lit:
            target = at + 8 + int(lit.group(1))
            if 0 <= target - BASE < len(data) - 4:
                value = struct.unpack_from('<I', data, target - BASE)[0]
                s = cstring(data, value - BASE)
                if s:
                    strings.append(dict(at=hex(at), literal=hex(value), string=s))
        if op in ('bl', 'blx') or (op.startswith('bl') and len(op) <= 4 and op not in ('ble', 'bls', 'blt')):
            t = re.match(r'(?:0x)?([0-9a-f]+)', args)
            if t:
                calls.append(int(t.group(1), 16))
    for at in range(start, end, 4):
        word = struct.unpack_from('<I', data, at)[0]
        if (word >> 24) in range(0xe0, 0xf0):
            continue
        value = struct.unpack_from('<i', data, at)[0]
        text = cstring(data, ((STRING_BASE + value) & 0xffffffff) - BASE)
        if text:
            strings.append(dict(at=hex(BASE + at), literal=hex(word), string=text, via='string_base'))
    seen[address] = dict(name=name, depth=depth, start=hex(address), end=hex(BASE + end),
                         strings=strings, calls=[hex(c) for c in calls], disassembly=dis)
    if depth < 1:
        for c in sorted(c for c in set(calls) if 0 <= c - BASE < len(data) - 4):
            analyse(data, c, f'{name}->call_{c:#x}', depth + 1, seen)
    return seen


def main():
    data = SOURCE.read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('expanded loader hash mismatch')
    if struct.unpack_from('<I', data, 0x40)[0] != BASE:
        raise ValueError('vector literal does not match base')
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    for label in ('switch_bootpart', 'modify_cmdline'):
        reg = registration(data, label)
        functions = analyse(data, reg['function'], label)
        (OUT / f'{label}-disassembly.txt').write_text(
            '\n\n'.join(f"### {f['name']} {f['start']}-{f['end']}\n{f['disassembly']}" for f in functions.values()))
        report[label] = dict(registration={k: (hex(v) if isinstance(v, int) and k == 'function' else v)
                                           for k, v in reg.items()},
                             functions=[{k: v for k, v in f.items() if k != 'disassembly'} for f in functions.values()])
        print(f'== {label} @ {reg["function"]:#x} usage={reg["usage"]!r}')
        for f in functions.values():
            if f['strings']:
                print(f"  {f['name']} {f['start']}: " + ' | '.join(s['string'].replace('\n', '\\n') for s in f['strings']))
    (OUT / 'loader-bootpart.json').write_text(json.dumps(dict(source_sha256=SHA256, link_base=hex(BASE),
                                                              commands=report), indent=2) + '\n')


if __name__ == '__main__':
    main()
