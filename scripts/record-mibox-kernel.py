"""Record pinned Meson6 development build provenance without claiming board boot."""
import argparse
import hashlib
import json
import lzma
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA = '8b1bb2b31a8e94b773a4b8ab907a0473a0951192'
TOOLCHAIN_SHA = '111258a10e017f067b27e6cfcea7619d753f3309'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def config(path):
    values = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r'(CONFIG_\w+)=(.*)', line)
        disabled = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
        if match:
            values[match[1]] = match[2]
        elif disabled:
            values[disabled[1]] = 'n'
    return values


def record(work, profile, configure_only):
    source, compiler = work / 'vendor-source', work / 'toolchain'
    output = work / ('build-' + profile)
    exported = ROOT / 'target/kernel-meson6' / profile
    evidence = ROOT / 'artifacts/kernel-meson6/2026-11-15' / profile
    evidence.mkdir(parents=True, exist_ok=True)
    revision = command('git', '-C', str(source), 'rev-parse', 'HEAD')
    compiler_revision = command('git', '-C', str(compiler), 'rev-parse', 'HEAD')
    if revision != SOURCE_SHA or compiler_revision != TOOLCHAIN_SHA:
        raise ValueError('unexpected source or compiler revision')
    patches = sorted((ROOT / 'kernel/patches').glob('*.patch'))
    source_diff = subprocess.check_output(['git', '-C', str(source), 'diff',
                                            '--no-ext-diff', '--binary', '--abbrev=8'])
    if not patches or source_diff != b''.join(p.read_bytes() for p in patches):
        raise ValueError('unrecorded kernel source modifications')
    expected_diff_sha = os.environ.get('MIBOX_KERNEL_SOURCE_DIFF_SHA256')
    if not configure_only:
        expected_diff_sha = (output / 'build-source.sha256').read_text().strip()
        expected_config_sha = (output / 'build-config.sha256').read_text().split()[0]
        if sha(output / '.config') != expected_config_sha:
            raise ValueError('kernel configuration changed while building')
    if expected_diff_sha and hashlib.sha256(source_diff).hexdigest() != expected_diff_sha:
        raise ValueError('kernel source changed while the build was running')
    resolved = config(output / '.config')
    stock_path = ROOT / 'artifacts/platform/2026-11-14/stock-kernel.config'
    stock = config(stock_path)
    fragment_path = ROOT / 'kernel/meson6-containers-v1.config'
    bsp_fragment_path = ROOT / 'kernel/meson6-bsp-build.config'
    requested = config(bsp_fragment_path)
    if profile == 'containers-v1':
        requested.update(config(fragment_path))
    failures = {k: dict(requested=v, actual=resolved.get(k, 'UNKNOWN'))
                for k, v in requested.items() if resolved.get(k) != v}
    required_board = ['CONFIG_ARCH_MESON6', 'CONFIG_MACH_MESON6_COMMON_BOARD',
                      'CONFIG_BLK_DEV_INITRD', 'CONFIG_RD_GZIP', 'CONFIG_OF',
                      'CONFIG_SMP', 'CONFIG_USB_G_ANDROID']
    board_config_failures = {k: resolved.get(k, 'UNKNOWN') for k in required_board
                             if resolved.get(k) != 'y'}
    changes = {k: dict(stock=stock.get(k, 'UNKNOWN'), resolved=resolved.get(k, 'UNKNOWN'))
               for k in sorted(set(stock) | set(resolved))
               if stock.get(k) != resolved.get(k)}
    report = dict(schema=1, profile=profile, source_repository='https://github.com/codesnake/linux-amlogic',
                  source_commit=revision, source_path=str(source), source_clean=False,
                  patches={str(p.relative_to(ROOT)): sha(p) for p in patches},
                  source_diff_sha256=hashlib.sha256(source_diff).hexdigest(),
                  build_script_sha256=sha(ROOT / 'scripts/build-mibox-kernel.sh'),
                  recorder_sha256=sha(Path(__file__)),
                  host_compiler_version=command('gcc', '--version').splitlines()[0],
                  host_compiler_extra_flags=['-fcommon'],
                  linker_version=command(str(compiler / 'bin/arm-linux-androideabi-ld.bfd'), '--version').splitlines()[0],
                  compiler_repository='https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9',
                  compiler_commit=compiler_revision,
                  compiler_version=command(str(compiler / 'bin/arm-linux-androideabi-gcc'), '--version').splitlines()[0],
                  stock_config_sha256=sha(stock_path), config_sha256=sha(output / '.config'),
                  bsp_fragment_sha256=sha(bsp_fragment_path),
                  fragment_sha256=sha(fragment_path) if profile == 'containers-v1' else None,
                  requested_config_failures=failures, board_config_failures=board_config_failures,
                  config_changes=changes, build_complete=False,
                  board_boot='UNKNOWN', physical_validation=False, boot_readiness='NOT READY',
                  pi2_os_native_engine_readiness='NOT READY',
                  limitations=['No cgroup v2, overlayfs or pids controller in this pinned BSP.',
                               'Only legacy cgroup-v1/VFS engine research is possible with this profile.',
                               'Source is a Meson6 reference BSP, not the recovered Xiaomi commit.',
                               'No boot image packaging or device deployment is performed.'])
    shutil.copyfile(output / '.config', evidence / 'resolved.config')
    (evidence / 'configuration.json').write_text(json.dumps(report, indent=2) + '\n')
    if failures or board_config_failures:
        raise ValueError(f'configuration failed: requested={failures}, board={board_config_failures}')
    if configure_only:
        (evidence / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'{profile}: configuration accepted; {len(changes)} differences from recovered stock config')
        return
    uts = (output / 'include/generated/utsrelease.h').read_text()
    runtime_release = re.search(r'^#define UTS_RELEASE "([^"]+)"$', uts, re.M)
    full_release = re.search(r'^#define UTS_RELEASE_FULL "([^"]+)"$', uts, re.M)
    if not runtime_release or not full_release:
        raise ValueError('missing BSP runtime/full release definitions')
    report['runtime_release'] = runtime_release[1]
    report['full_build_release'] = full_release[1]
    paths = {'zImage': output / 'arch/arm/boot/zImage',
             'Image': output / 'arch/arm/boot/Image', 'vmlinux': output / 'vmlinux',
             'System.map': output / 'System.map'}
    elf = paths['vmlinux'].read_bytes()
    if elf[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<H', elf, 18)[0] != 40:
        raise ValueError('vmlinux is not a little-endian ARM32 ELF')
    zimage = paths['zImage'].read_bytes()
    if struct.unpack_from('<I', zimage, 0x24)[0] != 0x016f2818:
        raise ValueError('zImage magic does not match ARM boot protocol')
    piggy_path = output / 'arch/arm/boot/compressed/piggy.lzma'
    piggy = piggy_path.read_bytes()
    decoder = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
    expanded = decoder.decompress(piggy, max_length=64 * 1024 * 1024)
    if not decoder.eof or expanded != paths['Image'].read_bytes():
        raise ValueError('LZMA payload does not decompress to the built Image')
    if decoder.unused_data not in (b'', struct.pack('<I', len(expanded))):
        raise ValueError('unexpected data after LZMA stream')
    if zimage.count(piggy) != 1:
        raise ValueError('zImage does not contain exactly one complete built LZMA payload')
    banner = re.search(rb'Linux version [^\x00\n]+', elf)
    if not banner:
        raise ValueError('kernel banner not found')
    headers = command(str(compiler / 'bin/arm-linux-androideabi-readelf'), '-h', '-l', str(paths['vmlinux']))
    report.update(build_complete=True, kernel_banner=banner[0].decode(),
                  elf_arm32=True, zimage_magic_valid=True,
                  compressed_payload_matches_image=True,
                  compressed_payload_sha256=sha(piggy_path),
                  compressed_payload_offset_in_zimage=zimage.index(piggy),
                  artifacts={name: dict(path=str(path), bytes=path.stat().st_size, sha256=sha(path))
                             for name, path in paths.items()})
    for name in ['zImage', 'Image', 'System.map']:
        shutil.copyfile(paths[name], exported / name)
        if sha(exported / name) != sha(paths[name]):
            raise ValueError(f'export hash mismatch: {name}')
    (evidence / 'elf.txt').write_text(headers + '\n')
    log = exported / 'build.log'
    warning_lines = [line for line in log.read_text(errors='replace').splitlines()
                     if 'warning:' in line.lower() or 'WARNING:' in line]
    report['build_log_sha256'] = sha(log)
    report['warning_lines'] = warning_lines
    (evidence / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ['profile', 'build_complete', 'kernel_banner',
                                            'boot_readiness', 'physical_validation']}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--profile', choices=['baseline', 'containers-v1'], required=True)
    parser.add_argument('--configure-only', action='store_true')
    args = parser.parse_args()
    record(args.work, args.profile, args.configure_only)
