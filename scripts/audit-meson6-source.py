"""Compare the pinned Meson6 BSP's memory algorithm and DT literals to stock."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from stock_formats import cells, fdt

ROOT = Path(__file__).resolve().parents[1]
PIN = '8b1bb2b31a8e94b773a4b8ab907a0473a0951192'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(source, output):
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise ValueError('memory model is only reviewed for the pinned BSP')
    blob = ROOT / 'phone-tools/extracted/2026-11-13/boot1/second.bin'
    if digest(blob) != '24b30f1aafe26845839966721b3c083cb3ed49280178276b6114df6d725cb95c':
        raise ValueError('unexpected stock DTB')
    nodes = fdt(blob.read_bytes())['nodes']
    code_path = source / 'drivers/of/fdt.c'
    code = code_path.read_text()
    board_path = source / 'arch/arm/mach-meson6/board-meson6-common.c'
    # Fail closed if the source stops expressing the algorithm reviewed here.
    statements = [
        'early_init_dt_add_memory_arch(phys_offset,MEM_BLOCK1_SIZE);',
        'early_init_dt_add_memory_arch(aml_reserved_end,aml_reserved_start-aml_reserved_end);',
        'aml_reserved_end = get_reserve_end();',
        'current_addr_from_low+aml_reserved_start+EARLY_RESERVED_MEM_SIZE-1',
        'early_init_dt_add_memory_arch(aml_reserved_end+1,FIRMWARE_ADDR-aml_reserved_end-1);',
        'early_init_dt_add_memory_arch(FIRMWARE_ADDR+0x100000, phys_offset+total-(FIRMWARE_ADDR+0x100000)-high_reserve_size);',
    ]
    for statement in statements:
        if statement not in code:
            raise ValueError('review required: changed memory algorithm')
    def macro(name):
        match = re.search(r'^#define\s+' + name + r'\s+(0x[0-9a-fA-F]+)\s*$', code, re.M)
        if not match:
            raise ValueError(f'missing simple macro {name}')
        return int(match[1], 16)
    memory = nodes['/memory']
    def number(key):
        value = cells(memory[key])
        if len(value) != 1:
            raise ValueError('requires the original single-cell memory layout')
        return value[0]
    base, total = number('phys_offset'), number('linux,total-memory')
    start, original_end = number('aml_reserved_start'), number('aml_reserved_end')
    low = high = 0
    reserves = []
    for node, properties in nodes.items():
        if 'reserve-memory' not in properties:
            continue
        if len(node.rsplit('/', 1)[-1]) > 14:
            raise ValueError('vendor reservation name exceeds reviewed bounds')
        is_low = (properties.get('reserve-iomap') == b'true\0' or
                  properties.get('mem-usable') == b'false\0')
        for size in cells(properties['reserve-memory']):
            if not size:
                continue
            offset = low if is_low else high
            if is_low:
                low += size
            else:
                high += size
            reserves.append(dict(node=node, size=size, from_low=is_low, offset=offset))
    # CONFIG_MESON_TRUSTZONE=n in the recovered stock configuration. This model
    # must not be used with a TrustZone-enabled replacement configuration.
    stock = ROOT / 'artifacts/platform/2026-11-14/stock-kernel.config'
    if '# CONFIG_MESON_TRUSTZONE is not set' not in stock.read_text():
        raise ValueError('unreviewed TrustZone memory reservation')
    end = start + macro('DSP_MEM_SIZE') + low - 1
    firmware = macro('FIRMWARE_ADDR')
    if high or end >= firmware:
        raise ValueError('unreviewed high-memory reservation or firmware overlap')
    predicted = [(base, base + macro('MEM_BLOCK1_SIZE') - 1, 'System RAM'),
                 (original_end, start - 1, 'System RAM'),
                 (start, end, 'Video RAM'),
                 (end + 1, firmware - 1, 'System RAM'),
                 (firmware + 0x100000, base + total - 1, 'System RAM')]
    # Merge adjacent System RAM entries as Linux's iomem resource reporting does.
    merged = []
    for first, last, kind in sorted(predicted):
        if last < first:
            raise ValueError('invalid predicted memory bank')
        if merged and merged[-1][1] + 1 == first and merged[-1][2] == kind:
            merged[-1] = (merged[-1][0], last, kind)
        else:
            merged.append((first, last, kind))
    iomem = ROOT / 'phone-tools/runtime/2026-11-13/iomem.txt'
    observed = [(int(a, 16), int(b, 16), kind) for a, b, kind in re.findall(
        r'^([0-9a-fA-F]+)-([0-9a-fA-F]+) : (System RAM|Video RAM)\s*$', iomem.read_text(), re.M)]
    literals = {}
    for node, properties in nodes.items():
        for compatible in properties.get('compatible', b'').split(b'\0'):
            if compatible:
                literals.setdefault(compatible.decode('ascii'), dict(nodes=[], source_hits=[]))['nodes'].append(node)
    for top in ['arch/arm/mach-meson6', 'arch/arm/plat-meson', 'drivers', 'sound']:
        for path in (source / top).rglob('*.c'):
            text = path.read_text(errors='replace')
            for literal, info in literals.items():
                quoted = '"' + literal + '"'
                if quoted in text:
                    for i, line in enumerate(text.splitlines(), 1):
                        if quoted in line:
                            info['source_hits'].append(dict(path=str(path.relative_to(source)), line=i))
    report = dict(source_commit=revision, dtb_sha256=digest(blob), memory_source_sha256=digest(code_path),
                  board_source_sha256=digest(board_path), iomem_sha256=digest(iomem),
                  assumptions=['Pinned source algorithm; CONFIG_ARCH_MESON6=y and CONFIG_MESON_TRUSTZONE=n.',
                               'Unmodified stock DTB; no bootloader fixup changes.',
                               'Source literal hits are leads, not driver-probe or hardware validation.'],
                  low_reservation_bytes=low, dsp_reservation_bytes=macro('DSP_MEM_SIZE'),
                  reservations=reserves,
                  predicted_iomem=[dict(start=hex(a), end=hex(b), kind=k) for a, b, k in merged],
                  observed_iomem=[dict(start=hex(a), end=hex(b), kind=k) for a, b, k in observed],
                  memory_model_matches_captured_iomem=merged == observed,
                  compatible_literal_inventory=literals,
                  board_boot='UNKNOWN', boot_readiness='NOT READY', physical_validation=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ['source_commit', 'low_reservation_bytes',
                                           'memory_model_matches_captured_iomem', 'boot_readiness']}, indent=2))
    if merged != observed:
        raise ValueError('source memory model does not match the captured stock iomem')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/kernel-meson6/2026-11-15/source-audit.json')
    args = parser.parse_args()
    audit(args.source, args.output)
