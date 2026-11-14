"""Build the bounded ARM hardware helper with an isolated Ubuntu cross sysroot."""
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
work = root / 'target/hardware-cross'
work.mkdir(parents=True, exist_ok=True)
packages = ['libc6-dev-armhf-cross', 'libc6-armhf-cross', 'linux-libc-dev-armhf-cross']
if not list(work.glob('*.deb')):
    subprocess.run(['apt-get', 'download', *packages], cwd=work, check=True)
if not (work / 'sysroot/usr/arm-linux-gnueabihf/include/stdio.h').exists():
    for package in sorted(work.glob('*.deb')):
        subprocess.run(['dpkg-deb', '-x', str(package), str(work / 'sysroot')], check=True)
sysroot = work / 'sysroot/usr/arm-linux-gnueabihf'
destination = root / 'target/hardware-helper'
destination.mkdir(parents=True, exist_ok=True)
output = destination / 'mibox-hardware'
command = ['arm-linux-gnueabihf-gcc', '--sysroot=' + str(sysroot),
           '-isystem', str(sysroot / 'include'), '-L' + str(sysroot / 'lib'),
           '-B' + str(sysroot / 'lib') + '/', '-static', '-Os', '-Wall', '-Wextra', '-Werror',
           '-Wno-misleading-indentation',
           '-D_FILE_OFFSET_BITS=64', '-o', str(output), str(root / 'src/hardware/mibox-hardware.c'), '-lm']
subprocess.run(command, check=True)
subprocess.run(['arm-linux-gnueabihf-strip', str(output)], check=True)
headers = subprocess.run(['arm-linux-gnueabihf-readelf', '-h', '-l', str(output)],
                         capture_output=True, text=True, check=True).stdout
if 'INTERP' in headers or 'DYNAMIC' in headers or 'Machine:                           ARM' not in headers:
    raise RuntimeError('helper must be static ARM ELF')
(destination / 'elf.txt').write_text(headers)
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
report = dict(command=command, compiler=subprocess.check_output(
    ['arm-linux-gnueabihf-gcc', '--version'], text=True).splitlines()[0],
    source_sha256=digest(root / 'src/hardware/mibox-hardware.c'),
    capture_header_sha256=digest(root / 'src/hardware/framebuffer-capture.h'),
    binary_sha256=digest(output), bytes=output.stat().st_size,
    packages={p.name: digest(p) for p in sorted(work.glob('*.deb'))},
    static_arm_elf=True, physical_validation=False)
(destination / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
