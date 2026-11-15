"""Prepare the pinned Alpine ARMv7 userspace on Linux storage (run as root).

Package signatures are checked by Alpine apk using the release's bundled keys.
The base archive is pinned below; resolved package versions are recorded.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path


def main(destination):
    if os.geteuid() != 0:
        raise SystemExit('Run under WSL as root for chroot and Unix ownership')
    if destination.exists():
        raise SystemExit('Choose a new empty destination; existing rootfs is preserved')
    if str(destination.resolve()).startswith('/mnt/'):
        raise SystemExit('Use Linux storage to preserve symlinks and Unix permissions')
    root = Path(__file__).resolve().parents[1]
    cache = root / 'target/console-download'
    cache.mkdir(parents=True, exist_ok=True)
    filename = 'alpine-minirootfs-3.22.8-armv7.tar.gz'
    archive = cache / filename
    url = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/armv7/' + filename
    if not archive.exists():
        urllib.request.urlretrieve(url, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != 'a641f002abf617db94379110ffa798e0ed9903dbcec2bb1caa79df1fc7af8e8c':
        raise SystemExit('Alpine archive SHA256 mismatch')
    destination.mkdir(parents=True)
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter='data')
    shutil.copyfile('/etc/resolv.conf', destination / 'etc/resolv.conf')
    subprocess.run(['chroot', str(destination), '/sbin/apk', 'add', '--no-cache', 'dropbear'], check=True)
    packages = subprocess.check_output(['chroot', str(destination), '/sbin/apk', 'info', '-v'], text=True)
    report = dict(base_url=url, base_sha256=digest, packages=packages.splitlines(),
                  signature_verification='apk default trusted release keys; no allow-untrusted',
                  arch='armv7', physical_validation=False)
    (cache / 'alpine-provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    main(parser.parse_args().destination)
