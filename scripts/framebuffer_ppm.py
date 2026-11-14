"""Convert the bounded helper's exact P6 format to PNG using the standard library."""
import argparse
import re
import struct
import zlib
from pathlib import Path


def png_from_ppm(data, expect_color_bars=False):
    match = re.match(rb'P6\n([1-9][0-9]{0,3}) ([1-9][0-9]{0,3})\n255\n', data)
    if not match:
        raise ValueError('Unsupported capture header')
    width, height = map(int, match.groups())
    if width > 4096 or height > 2160 or len(data) != match.end() + width * height * 3:
        raise ValueError('Capture dimensions or payload size invalid')
    pixels = data[match.end():]
    if expect_color_bars:
        colors = (b'\xff\xff\xff', b'\xff\xff\0', b'\0\xff\xff', b'\0\xff\0',
                  b'\xff\0\xff', b'\xff\0\0', b'\0\0\xff', b'\0\0\0')
        if width < 8:
            raise ValueError('Eight color bars require at least eight pixels')
        row = b''.join(colors[x * 8 // width] for x in range(width))
        if any(pixels[y * width * 3:(y + 1) * width * 3] != row for y in range(height)):
            raise ValueError('Framebuffer pixels do not match the eight color bars')
    raw = b''.join(b'\0' + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))

    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))

    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--expect-color-bars', action='store_true')
    args = parser.parse_args()
    with args.source.open('rb') as stream:
        data = stream.read(4096 * 2160 * 3 + 65)
    args.destination.write_bytes(png_from_ppm(data, args.expect_color_bars))
