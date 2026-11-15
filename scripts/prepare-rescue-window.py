"""Prepare a fixed preboot USB window from the exact backed-up environment."""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
SIZE = 32768
FULL_SIZE = 4194304
ORIGINAL_HASH = 'e85c14d547bde485ded38f41050f197ba33dfe24cc543bec61f11eafea2f812a'
PREFIX = b'update 10000;'


def parse(data):
    if len(data) != FULL_SIZE:
        raise ValueError('exact 4 MiB environment required')
    if struct.unpack_from('<I', data)[0] != zlib.crc32(data[4:SIZE]):
        raise ValueError('environment CRC mismatch')
    body, padding = data[4:SIZE].split(b'\0\0', 1)
    if any(padding):
        raise ValueError('nonzero environment padding')
    result = {}
    for entry in body.split(b'\0'):
        name, value = entry.split(b'=', 1)
        name.decode('ascii'); value.decode('ascii')
        if not name or name in result:
            raise ValueError('empty or duplicate variable')
        result[name] = value
    return result


def prepare(data):
    if hashlib.sha256(data).hexdigest() != ORIGINAL_HASH:
        raise ValueError('source environment hash mismatch')
    variables = parse(data)
    if variables[b'upgrade_step'] != b'0' or variables[b'usb_burning'] != b'update 1000':
        raise ValueError('unexpected startup configuration')
    before = variables[b'preboot']
    if not before.startswith(b'echo preboot...;') or PREFIX in before:
        raise ValueError('unexpected preboot command')
    variables[b'preboot'] = PREFIX + before
    body = b'\0'.join(k + b'=' + v for k, v in variables.items()) + b'\0\0'
    if len(body) > SIZE - 4:
        raise ValueError('environment overflow')
    body = body.ljust(SIZE - 4, b'\0')
    patched = struct.pack('<I', zlib.crc32(body)) + body + data[SIZE:]
    changed = [k.decode() for k, v in parse(data).items() if parse(patched)[k] != v]
    if changed != ['preboot'] or patched[SIZE:] != data[SIZE:]:
        raise ValueError('unexpected change outside preboot')
    return patched, before


def main():
    original = (ROOT / 'phone-tools/backup/2026-11-13/env.img').read_bytes()
    patched, before = prepare(original)
    output = ROOT / 'target/rescue-window'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'env-window.img').write_bytes(patched)
    # Embed exact before/after bytes; helper accepts no user-selected payload.
    with (output / 'rescue-env-payload.h').open('w') as stream:
        for name, value in [('original_env', original), ('window_env', patched[:SIZE])]:
            stream.write('static const unsigned char ' + name + '[] = {\n')
            for at in range(0, len(value), 32):
                stream.write(','.join(f'0x{b:02x}' for b in value[at:at+32]) + ',\n')
            stream.write('};\n')
    report = dict(source_sha256=ORIGINAL_HASH, patched_sha256=hashlib.sha256(patched).hexdigest(),
                  bytes=len(patched), write_region=dict(offset=0, bytes=SIZE),
                  changed_variables=['preboot'], before=before.decode(), after=(PREFIX+before).decode(),
                  bootloader_image_changed=False, device_access=False, installed=False,
                  expected_window_duration='UNKNOWN until physical measurement',
                  original_tail_nonzero_bytes=sum(b != 0 for b in original[SIZE:]))
    evidence = ROOT / 'artifacts/restoration/2026-11-15'
    (evidence / 'rescue-window-payload.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
