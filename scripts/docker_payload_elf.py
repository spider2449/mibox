"""Validate static ARM ELF32 executables before Docker payload execution."""
import struct


def inspect_arm(data):
    if len(data) < 52 or data[:7] != b'\x7fELF\x01\x01\x01':
        raise ValueError('Expected little-endian ELF32')
    kind, machine, version = struct.unpack_from('<HHI', data, 16)
    if machine != 40 or kind not in (2, 3) or version != 1:
        raise ValueError('Expected ARM executable')
    start = struct.unpack_from('<I', data, 28)[0]
    stride, count = struct.unpack_from('<HH', data, 42)
    if not count or stride < 32 or start < 52 or start + stride * count > len(data):
        raise ValueError('Invalid ELF program headers')
    for i in range(count):
        kind, offset, _, _, size = struct.unpack_from('<IIIII', data, start + stride * i)
        if kind in (2, 3):
            raise ValueError('Dynamic linking is not allowed in this payload')
        if offset + size > len(data):
            raise ValueError('ELF segment exceeds file')
    return dict(class_bits=32, machine='ARM', endian='little', dynamic_loader=False)
