"""Prepare signature-checked Alpine ARMv7 FFmpeg tools on host Linux storage."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--repack-only', action='store_true', help='Repack an already prepared root without package changes')
args = parser.parse_args()
destination = args.destination.resolve()
root = Path(__file__).resolve().parents[1]
if os.geteuid() != 0:
    raise SystemExit('Run as WSL root for isolated chroot package preparation')
if destination.exists() and not args.repack_only:
    raise SystemExit('Destination already exists; preserve it and inspect before reuse')
if str(destination).startswith('/mnt/'):
    raise SystemExit('Use Linux storage for rootfs symlink and permission semantics')
archive = root / 'target/console-download/alpine-minirootfs-3.22.8-armv7.tar.gz'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != 'a641f002abf617db94379110ffa798e0ed9903dbcec2bb1caa79df1fc7af8e8c':
    raise SystemExit('Base archive hash mismatch')
evidence = root / 'artifacts/hardware-validation/media-tools'
evidence.mkdir(parents=True, exist_ok=True)
if not args.repack_only:
    destination.mkdir(parents=True)
    # This pinned rootfs intentionally includes absolute BusyBox symlinks.
    subprocess.run(['tar', '-xzf', str(archive), '-C', str(destination)], check=True)
    shutil.copyfile('/etc/resolv.conf', destination / 'etc/resolv.conf')
    command = ['chroot', str(destination), '/sbin/apk', 'add', '--no-cache', 'ffmpeg']
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    (evidence / 'prepare.txt').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit('Package preparation failed; see retained output')
packages = subprocess.check_output(['chroot', str(destination), '/sbin/apk', 'info', '-v'], text=True)
version = subprocess.check_output(['chroot', str(destination), '/usr/bin/ffmpeg', '-version'], text=True)
subprocess.run(['qemu-arm-static', str(destination / 'lib/ld-musl-armhf.so.1'), '--library-path',
                ':'.join(str(destination / p) for p in ['usr/lib/pulseaudio', 'usr/lib', 'lib']),
                str(destination / 'usr/bin/ffmpeg'), '-version'], check=True, capture_output=True)
output = root / 'target/hardware-media/armv7-media-tools.tar.gz'
members = []
for directory in ['lib', 'usr/lib']:
    members.extend(p for p in (destination / directory).rglob('*') if '.so' in p.name and (p.is_file() or p.is_symlink()))
members.extend(destination / p for p in ['usr/bin/ffmpeg', 'usr/bin/ffprobe'])
with tarfile.open(output, 'w:gz') as stream:
    for path in sorted(members):
        stream.add(path, arcname=str(path.relative_to(destination)), recursive=False)
report = dict(base_sha256=digest, packages=packages.splitlines(), version=version,
              verification='apk default trusted Alpine release keys; no allow-untrusted',
              archive=str(output), archive_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
              archive_bytes=output.stat().st_size, expanded_file_bytes=sum(p.stat().st_size for p in members if not p.is_symlink()),
              files={str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in members if not p.is_symlink()}, physical_execution='NOT_TESTED')
(evidence / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k not in ['files', 'version', 'packages']}, indent=2))
