"""Extract only fixed recovery configuration/scripts from an existing cpio backup."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

WANTED = {'init.rc', 'default.prop', 'etc/recovery.fstab', 'etc/fw_env.config',
          'sbin/open_mass_storage.sh', 'sbin/recovery.data.sh',
          'sbin/restore_system.sh', 'sbin/set_display_mode.sh'}


def inspect(root, output, binaries_output=None):
    source = root / 'phone-tools/extracted/2026-11-13/recovery/ramdisk.cpio'
    data = source.read_bytes()
    cursor = 0
    selected = {}
    binaries = {}
    binary_data = {}
    trailer = False
    for _ in range(10000):
        header = data[cursor:cursor + 110]
        if len(header) != 110 or header[:6] not in (b'070701', b'070702'):
            raise ValueError('invalid newc header')
        fields = [int(header[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name_end = cursor + 110 + namesize
        if namesize < 1 or name_end > len(data) or data[name_end - 1] != 0:
            raise ValueError('invalid newc name')
        name = data[cursor + 110:name_end - 1].decode('utf-8')
        start = (name_end + 3) // 4 * 4
        end = start + size
        if end > len(data):
            raise ValueError('invalid newc payload')
        if name == 'TRAILER!!!':
            trailer = True
            break
        name = name.removeprefix('./')
        if name in WANTED:
            if mode & 0o170000 != 0o100000 or name in selected:
                raise ValueError('unexpected type or duplicate allowlisted entry')
            payload = data[start:end]
            selected[name] = dict(bytes=size, mode=oct(mode),
                                  sha256=hashlib.sha256(payload).hexdigest(),
                                  text=payload.decode('utf-8'))
        if name in {'sbin/adbd', 'sbin/sh'}:
            payload = data[start:end]
            if mode & 0o170000 != 0o100000 or name in binaries or payload[:7] != b'\x7fELF\x01\x01\x01':
                raise ValueError('unexpected recovery binary type')
            phoff = struct.unpack_from('<I', payload, 28)[0]
            stride, count = struct.unpack_from('<HH', payload, 42)
            if stride < 32 or phoff + stride * count > len(payload):
                raise ValueError('invalid binary program headers')
            kinds = [struct.unpack_from('<I', payload, phoff + stride * i)[0] for i in range(count)]
            binaries[name] = dict(bytes=size, sha256=hashlib.sha256(payload).hexdigest(),
                                  machine=struct.unpack_from('<H', payload, 18)[0],
                                  interpreter_segment=3 in kinds, dynamic_segment=2 in kinds)
            binary_data[name] = payload
        cursor = (end + 3) // 4 * 4
    if not trailer or set(selected) != WANTED:
        raise ValueError('missing trailer or expected fixed entries')
    output.mkdir(parents=True, exist_ok=True)
    for name, entry in selected.items():
        # Only predefined names are ever used as output paths; no cpio path traversal.
        (output / name.replace('/', '__')).write_text(entry['text'], encoding='utf-8')
    if binaries_output is not None:
        if set(binaries) != {'sbin/adbd', 'sbin/sh'}:
            raise ValueError('expected recovery binaries absent')
        binaries_output.mkdir(parents=True, exist_ok=True)
        for name, payload in binary_data.items():
            (binaries_output / name.replace('/', '__')).write_bytes(payload)
    result = dict(source_sha256=hashlib.sha256(data).hexdigest(), entries=selected, binaries=binaries,
                  device_operations=False, files_executed=False)
    (output / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({name: value['sha256'] for name, value in selected.items()}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binaries-output', type=Path)
    args = parser.parse_args()
    inspect(args.root, args.output, args.binaries_output)
