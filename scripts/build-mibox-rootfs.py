"""Build an unflashed RAM rootfs candidate, not an Android boot image."""
import argparse
import base64
import gzip
import hashlib
import json
import ipaddress
import struct
from pathlib import Path


def public_keys(path):
    keys = []
    for line in path.read_bytes().splitlines():
        if not line.strip():
            continue
        token = line.split()[0]
        blob = base64.b64decode(token, validate=True)
        if len(blob) != 524:
            raise ValueError('expected an Android RSA-2048 public key, never a private key')
        words, inverse = struct.unpack_from('<II', blob)
        n = int.from_bytes(blob[8:264], 'little')
        rr = int.from_bytes(blob[264:520], 'little')
        exponent = struct.unpack_from('<I', blob, 520)[0]
        if (words != 64 or n.bit_length() != 2048 or not n & 1 or exponent not in (3, 65537)
                or inverse != (-pow(n, -1, 1 << 32)) & 0xffffffff or rr != (1 << 4096) % n):
            raise ValueError('invalid ADB RSA public-key structure')
        if token not in keys:
            keys.append(token)
    if not 1 <= len(keys) <= 16:
        raise ValueError('one to sixteen authorized public keys required')
    return b''.join(token + b' mibox-owner\n' for token in keys)


def arm_static(path):
    data = path.read_bytes()
    if len(data) < 52 or data[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 40:
        raise ValueError(f'expected ARM ELF32: {path.name}')
    start = struct.unpack_from('<I', data, 28)[0]
    stride, count = struct.unpack_from('<HH', data, 42)
    if stride < 32 or start + stride * count > len(data):
        raise ValueError('invalid ELF program headers')
    if any(struct.unpack_from('<I', data, start + stride * i)[0] in (2, 3) for i in range(count)):
        raise ValueError('RAM rootfs executables must not require a dynamic loader')
    return data


def build(root, key_path, destination, enable_usb_adb=False, hardware_helper=None, static_ipv4=None,
          release_directory=None, kernel_test_helper=None):
    config = json.loads((root / 'artifacts/platform/2026-11-14/kernel-config.json').read_text())
    for flag in ('CONFIG_BLK_DEV_INITRD', 'CONFIG_RD_GZIP', 'CONFIG_DEVTMPFS', 'CONFIG_TMPFS'):
        if config['selected'].get(flag) != 'y':
            raise ValueError(f'stock kernel prerequisite missing: {flag}')
    keys = public_keys(key_path)
    release = release_directory or root / 'target/armv7-unknown-linux-musleabihf/release'
    files = {'init': arm_static(release / 'mibox-init'),
             'bin/mibox': arm_static(release / 'mibox-userland'),
             'etc/os-release': (root / 'assets/rootfs/os-release').read_bytes(),
             'adb_keys': keys}
    if hardware_helper:
        files['sbin/mibox-hardware'] = arm_static(hardware_helper)
    if kernel_test_helper:
        if not release_directory or not enable_usb_adb or hardware_helper or static_ipv4:
            raise ValueError('kernel test needs isolated userspace, authenticated USB and no hardware/storage profile')
        files['sbin/mibox-kernel-selftest'] = arm_static(kernel_test_helper)
        files['etc/mibox-kernel-development'] = b'MIBOX_KERNEL_DEV_V1 8b1bb2b31a8e94b773a4b8ab907a0473a0951192 3.10.99-mibox-container-dev+\n'
        if files['etc/mibox-kernel-development'] not in files['init']:
            raise ValueError('init does not contain the explicit development-kernel feature marker')
    if static_ipv4:
        if not hardware_helper:
            raise ValueError('static IPv4 profile requires the explicit hardware helper')
        address,mask,gateway=static_ipv4
        interface=ipaddress.IPv4Interface(address+'/'+mask)
        router=ipaddress.IPv4Address(gateway)
        if (router not in interface.network or router==interface.ip or
                interface.ip in (interface.network.network_address,interface.network.broadcast_address)):
            raise ValueError('invalid static IPv4 subnet/address/gateway')
        files['etc/mibox-network-static']=(f'MIBOX_STATIC_IPV4_V1 {interface.ip} {interface.netmask} {router}\n').encode('ascii')
    if enable_usb_adb:
        files['etc/mibox-usb-adb.enabled'] = b'MIBOX_AUTHENTICATED_USB_ADB_V1\n'
    for source, target, expected in [
        ('sbin__adbd', 'sbin/adbd', 'f2a875f1f6230fde084264e2927d1dbf3bf95bcf5e494809814a488caf532afc'),
        ('sbin__sh', 'system/bin/sh', 'd44fd1bb1a8a84fe6ed0b4d850dd05d506aaf4fefdb54d24eb99690fb6583fc6'),
    ]:
        data = arm_static(root / 'phone-tools/runtime/2026-11-14/recovery-binaries' / source)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('stock console binary differs from verified recovery extraction')
        files[target] = data
    archive = bytearray()

    def entry(name, mode, payload=b'', major=0, minor=0):
        encoded = name.encode('ascii') + b'\0'
        fields = [1, mode, 0, 0, 1, 0, len(payload), 0, 0, major, minor, len(encoded), 0]
        archive.extend(b'070701' + ''.join(f'{v:08x}' for v in fields).encode('ascii'))
        archive.extend(encoded)
        archive.extend(bytes(-len(archive) % 4))
        archive.extend(payload)
        archive.extend(bytes(-len(archive) % 4))

    for directory in ('bin', 'dev', 'etc', 'proc', 'sbin', 'sys', 'system', 'system/bin', 'tmp'):
        entry(directory, 0o041777 if directory == 'tmp' else 0o040755)
    entry('dev/console', 0o020600, major=5, minor=1)
    entry('bin/sh', 0o120777, b'/system/bin/sh')
    for name, data in files.items():
        entry(name, 0o100444 if name in ('adb_keys', 'etc/os-release', 'etc/mibox-usb-adb.enabled', 'etc/mibox-network-static', 'etc/mibox-kernel-development') else 0o100755, data)
    entry('TRAILER!!!', 0)
    compressed = gzip.compress(archive, mtime=0)
    destination.mkdir(parents=True, exist_ok=True)
    image = destination / 'initramfs.NOT_READY.cpio.gz'
    image.write_bytes(compressed)
    report = dict(status='NOT_READY_FOR_HARDWARE_BOOT', format='gzip newc RAM rootfs, no boot header',
                  gzip_bytes=len(compressed), gzip_sha256=hashlib.sha256(compressed).hexdigest(),
                  cpio_sha256=hashlib.sha256(archive).hexdigest(),
                  files={name: dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest()) for name, data in files.items()},
                  authorized_public_key_count=len(keys.splitlines()), private_keys_included=False,
                  qemu_probe_included=False,
                  container_kernel_test=bool(kernel_test_helper),
                  release_directory=str(release),
                  required_opt_in='read-only /etc/mibox-usb-adb.enabled' if enable_usb_adb else 'mibox.usb_adb=1',
                  usb_adb_enabled_by_rootfs_marker=enable_usb_adb,
                  live_usb_reconfigured=False, partitions_written=False,
                  outstanding=['physical FunctionFS transport', 'loader image acceptance', 'verified software recovery'])
    (destination / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'files'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--adb-public-key', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--enable-usb-adb', action='store_true', help='explicitly opt in inside this RAM rootfs, avoiding unknown bootloader cmdline behavior')
    parser.add_argument('--hardware-helper', type=Path, help='explicitly include bounded root hardware-test helper')
    parser.add_argument('--release-directory', type=Path, help='isolated Rust release binaries')
    parser.add_argument('--kernel-test-helper', type=Path, help='private-namespace kernel diagnostic for the pinned development release')
    parser.add_argument('--static-ipv4',nargs=3,metavar=('ADDRESS','NETMASK','GATEWAY'),help='owner-confirmed RAM-only static test profile; no automatic network setup')
    args = parser.parse_args()
    build(args.root, args.adb_public_key, args.output, args.enable_usb_adb, args.hardware_helper,
          args.static_ipv4, args.release_directory, args.kernel_test_helper)
