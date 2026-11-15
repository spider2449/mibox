"""Build a fixed ARM environment updater and a separate host-only fixture."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = ROOT / 'target/rescue-window'
    source = ROOT / 'src/hardware/rescue-env.c'
    sysroot = ROOT / 'target/hardware-cross/sysroot/usr/arm-linux-gnueabihf'
    common = ['-static', '-Os', '-Wall', '-Wextra', '-Werror', '-I', str(output), str(source)]
    fixture = ['gcc', '-DRESCUE_ENV_FIXTURE', *common, '-o', str(output / 'rescue-env-fixture')]
    arm = ['arm-linux-gnueabihf-gcc', '--sysroot=' + str(sysroot), '-isystem', str(sysroot/'include'),
           '-L' + str(sysroot/'lib'), '-B' + str(sysroot/'lib') + '/', *common, '-o', str(output/'rescue-env')]
    subprocess.run(fixture, check=True)
    subprocess.run(arm, check=True)
    elf = subprocess.check_output(['arm-linux-gnueabihf-readelf', '-h', '-l', str(output/'rescue-env')], text=True)
    if 'INTERP' in elf or 'DYNAMIC' in elf or 'Machine:                           ARM' not in elf:
        raise ValueError('expected static ARM ELF')
    (output / 'elf.txt').write_text(elf)
    report = dict(commands=[fixture, arm], source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  binary_sha256=hashlib.sha256((output/'rescue-env').read_bytes()).hexdigest(),
                  payload_header_sha256=hashlib.sha256((output/'rescue-env-payload.h').read_bytes()).hexdigest(),
                  bytes=(output/'rescue-env').stat().st_size, static_arm_elf=True,
                  device_access=False)
    (ROOT / 'artifacts/restoration/2026-11-15/rescue-env-build.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
