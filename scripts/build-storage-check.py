"""Build the bounded ARM filesystem checker using the existing isolated sysroot."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', choices=['storage-check', 'framebuffer-handoff'], default='storage-check')
tool = parser.parse_args().tool
sysroot = root / 'target/hardware-cross/sysroot/usr/arm-linux-gnueabihf'
if not (sysroot / 'include/stdio.h').is_file():
    raise SystemExit('Prepare the existing sysroot with scripts/build-hardware-helper.py first')
destination = root / 'target' / tool
destination.mkdir(parents=True, exist_ok=True)
output = destination / tool
source = root / 'src/hardware' / (tool + '.c')
command = ['arm-linux-gnueabihf-gcc', '--sysroot=' + str(sysroot),
           '-isystem', str(sysroot / 'include'), '-L' + str(sysroot / 'lib'),
           '-B' + str(sysroot / 'lib') + '/', '-static', '-Os', '-Wall', '-Wextra', '-Werror',
           '-o', str(output), str(source)]
subprocess.run(command, check=True)
headers = subprocess.check_output(['arm-linux-gnueabihf-readelf', '-h', '-l', str(output)], text=True)
if 'INTERP' in headers or 'DYNAMIC' in headers or 'Machine:                           ARM' not in headers:
    raise RuntimeError('Expected static ARM ELF')
(destination / 'elf.txt').write_text(headers)
report = dict(command=command,
              compiler=subprocess.check_output(['arm-linux-gnueabihf-gcc', '--version'], text=True).splitlines()[0],
              source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              binary_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
              bytes=output.stat().st_size, static_arm_elf=True,
              packages={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in sorted((root / 'target/hardware-cross').glob('*.deb'))})
(destination / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
