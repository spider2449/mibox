"""Prepare a hash-pinned ARMv7 Docker development payload, without device access.

Run under WSL. QEMU version probes only establish executable compatibility on
the host kernel, never compatibility with the MiBox kernel.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

from docker_payload_elf import inspect_arm

VERSION = '24.0.9'
URL = f'https://download.docker.com/linux/static/stable/armhf/docker-{VERSION}.tgz'
SHA256 = '630150b66241a8e9aac29a8414b88cbeed94f39e306c5bac5f934f231639cc42'
BINARIES = {'ctr', 'docker', 'docker-proxy', 'runc', 'containerd',
            'docker-init', 'containerd-shim-runc-v2', 'dockerd'}


def prepare(root, output):
    if output.exists():
        raise ValueError('Choose a new output directory; existing payload is preserved')
    cache = root / 'target/docker-download'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'docker-{VERSION}.tgz'
    if not archive.exists():
        partial = archive.with_suffix('.partial')
        urllib.request.urlretrieve(URL, partial)
        partial.rename(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SHA256:
        raise ValueError('Docker archive SHA256 mismatch')
    # Validate every member before creating any executable. Do not use tar's
    # path handling or permit links/devices, duplicate entries or extra files.
    files = {}
    with tarfile.open(archive) as stream:
        for member in stream.getmembers():
            if member.name.rstrip('/') == 'docker' and member.isdir():
                continue
            if not member.isfile() or member.name not in {'docker/' + n for n in BINARIES}:
                raise ValueError('Unexpected archive member: ' + member.name)
            name = member.name.split('/')[1]
            if name in files or member.size > 150 * 1024 * 1024:
                raise ValueError('Duplicate or oversized binary')
            data = stream.extractfile(member).read()
            inspect_arm(data)
            files[name] = data
    if files.keys() != BINARIES:
        raise ValueError('Incomplete Docker binary set')
    emulator = shutil.which('qemu-arm-static')
    if not emulator:
        raise ValueError('qemu-arm-static required for host executable probes')
    output.mkdir(parents=True)
    bindir = output / 'bin'
    bindir.mkdir()
    inventory = {}
    for name, data in sorted(files.items()):
        path = bindir / name
        path.write_bytes(data)
        path.chmod(0o755)
        inventory[name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                               elf=inspect_arm(data))
    # All processes exit after printing a version. Never start a daemon on the host.
    probes = {}
    for name in ('docker', 'dockerd', 'containerd', 'runc', 'ctr', 'docker-init'):
        result = subprocess.run([emulator, str(bindir / name), '--version'],
                                capture_output=True, text=True, timeout=30)
        probes[name] = dict(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
    config = {
        'hosts': ['unix:///run/mibox-docker-test/docker.sock'],
        'data-root': '/run/mibox-docker-test/data',
        'exec-root': '/run/mibox-docker-test/exec',
        'pidfile': '/run/mibox-docker-test/dockerd.pid',
        'storage-driver': 'vfs',
        'exec-opts': ['native.cgroupdriver=cgroupfs'],
        'bridge': 'none', 'iptables': False, 'ip6tables': False,
        'ip-forward': False, 'ip-masq': False,
        'log-driver': 'json-file',
        'log-opts': {'max-size': '1m', 'max-file': '2'},
    }
    config_path = output / 'daemon-ram-test.json'
    config_path.write_text(json.dumps(config, indent=2) + '\n')
    result = subprocess.run([emulator, str(bindir / 'dockerd'), '--validate',
                             '--config-file', str(config_path)],
                            capture_output=True, text=True, timeout=30)
    probes['daemon_config_validation'] = dict(exit_code=result.returncode,
                                             stdout=result.stdout, stderr=result.stderr)
    report = dict(status='HOST_PAYLOAD_PREPARED', version=VERSION, source_url=URL,
                  ram_test_config=config,
                  ram_test_config_sha256=hashlib.sha256(config_path.read_bytes()).hexdigest(),
                  archive_sha256=digest,
                  pin_origin='First HTTPS download from download.docker.com; locally pinned, no publisher signature verified',
                  binaries=inventory, host_version_probes=probes,
                  qemu_version=subprocess.check_output([emulator, '--version'], text=True).splitlines()[0],
                  physical_validation=False, daemon_started=False,
                  device_accessed=False, production_ready=False)
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    evidence = root / 'artifacts/docker-runtime/2026-11-15'
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'docker-payload.json').write_text(json.dumps(report, indent=2) + '\n')
    if any(p['exit_code'] for p in probes.values()):
        raise RuntimeError('Host version probe failed; inspect manifest')
    if any(VERSION not in probes[n]['stdout'] for n in ('docker', 'dockerd')):
        raise RuntimeError('Unexpected Docker version output')
    print(json.dumps(dict(status=report['status'], archive_sha256=digest,
                          binary_count=len(files), physical_validation=False)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parents[1], args.output)
