"""Host-only framebuffer conversion fixtures under ASan/UBSan; no device access."""
import hashlib
import json
import subprocess
import struct
import zlib
from pathlib import Path
from framebuffer_ppm import png_from_ppm

root = Path(__file__).resolve().parents[1]
evidence = root / 'artifacts/framebuffer-capture/local'
evidence.mkdir(parents=True, exist_ok=True)
binary = root / 'target/hardware-helper/capture-asan'
binary.parent.mkdir(parents=True, exist_ok=True)
command = ['gcc', '-fsanitize=address,undefined', '-g', '-Wall', '-Wextra', '-Werror',
           '-D_FILE_OFFSET_BITS=64', '-o', str(binary),
           str(root / 'src/hardware/test-capture.c')]
subprocess.run(command, check=True, timeout=30)
result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
sources = ['src/hardware/test-capture.c', 'src/hardware/framebuffer-capture.h',
           'src/hardware/mibox-hardware.c']
report = dict(scope='Synthetic host framebuffer data; no physical screenshot or HDMI claim',
              command=command, exit_code=result.returncode, stdout=result.stdout,
              stderr=result.stderr, sources={p: hashlib.sha256((root / p).read_bytes()).hexdigest()
                                             for p in sources})
(evidence / 'capture-sanitizers.json').write_text(json.dumps(report, indent=2) + '\n')
print(result.stdout, end='')
if result.returncode:
    raise SystemExit(result.stderr or result.returncode)

payload = b'\x01\x02\x03\xff\x00\x7f'
png = png_from_ppm(b'P6\n2 1\n255\n' + payload)
assert png[:8] == b'\x89PNG\r\n\x1a\n'
chunks = {}
at = 8
while at < len(png):
    size = struct.unpack_from('>I', png, at)[0]
    kind, body = png[at+4:at+8], png[at+8:at+8+size]
    assert struct.unpack_from('>I', png, at+8+size)[0] == zlib.crc32(kind + body)
    chunks[kind] = body
    at += 12 + size
assert struct.unpack('>IIBBBBB', chunks[b'IHDR']) == (2, 1, 8, 2, 0, 0, 0)
assert zlib.decompress(chunks[b'IDAT']) == b'\0' + payload
for invalid in (b'', b'P6\n2 1\n255\n', b'P6\n4097 1\n255\n',
                b'P6\n1 2161\n255\n', b'P6\n1 1\n255\n1234'):
    try:
        png_from_ppm(invalid)
    except ValueError:
        continue
    raise AssertionError('Invalid PPM accepted')
bars = [bytes(c) for c in ((255,255,255),(255,255,0),(0,255,255),(0,255,0),
                         (255,0,255),(255,0,0),(0,0,255),(0,0,0))]
row = b''.join(bars[x * 8 // 17] for x in range(17))
pattern = b'P6\n17 2\n255\n' + row * 2
png_from_ppm(pattern, expect_color_bars=True)
for invalid in (pattern[:-1] + b'\x01', b'P6\n8 1\n255\n' + bytes([128]) * 24,
                b'P6\n1 1\n255\n123'):
    try:
        png_from_ppm(invalid, expect_color_bars=True)
    except ValueError:
        continue
    raise AssertionError('Invalid color bars accepted')
report['png_conversion'] = 'PASS: dimensions, RGB bytes, CRCs, invalid inputs, exact color bars and corruption rejection'
report['converter_sha256'] = hashlib.sha256((root / 'scripts/framebuffer_ppm.py').read_bytes()).hexdigest()
(evidence / 'capture-sanitizers.json').write_text(json.dumps(report, indent=2) + '\n')
print('capture png_conversion=PASS')
