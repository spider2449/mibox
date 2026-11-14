"""Create a LOCAL NOT-READY boot candidate. Never uploads or writes a device."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import struct
from pathlib import Path


def build(root, output):
    if not output.resolve().is_relative_to((root / 'target').resolve()):
        raise ValueError('candidate output must remain under this workspace target directory')
    source = root / 'phone-tools/backup/2026-11-13/boot1.img'
    data = source.read_bytes()
    expected = '06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222'
    if hashlib.sha256(data).hexdigest() != expected or len(data) != 8388608:
        raise ValueError('stock boot1 differs from verified full backup')
    spec = importlib.util.spec_from_file_location('stock_inspector', Path(__file__).with_name('inspect-mibox-boot.py'))
    inspector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inspector)
    stock = inspector.inspect(source)
    if not stock['layout_validated'] or not stock['matches_installed_script']:
        raise ValueError('stock image bounds/pinned prefix invalid')
    page = stock['page_size']
    sections = {part['name']: data[part['start']:part['end']] for part in stock['sections']}

    def android_id(parts):
        digest = hashlib.sha1()
        for name in ('kernel', 'ramdisk', 'second'):
            digest.update(parts[name])
            digest.update(struct.pack('<I', len(parts[name])))
        return digest.digest()

    if data[576:596] != android_id(sections) or any(data[596:608]):
        raise ValueError('stock Android image ID not understood')
    if any(data[stock['sections'][-1]['end']:]):
        raise ValueError('unknown nonzero stock trailer; refuse repack')
    rootfs_dir = root / 'target/mibox-rootfs'
    metadata = json.loads((rootfs_dir / 'manifest.json').read_text())
    ramdisk = (rootfs_dir / 'initramfs.NOT_READY.cpio.gz').read_bytes()
    if hashlib.sha256(ramdisk).hexdigest() != metadata['gzip_sha256']:
        raise ValueError('rootfs does not match provenance')
    if not metadata.get('usb_adb_enabled_by_rootfs_marker') or metadata.get('private_keys_included') or metadata.get('qemu_probe_included'):
        raise ValueError('candidate must have explicit authenticated USB opt-in and exclude test/private files')
    with gzip.GzipFile(fileobj=io.BytesIO(ramdisk)) as stream:
        archive = stream.read(64 * 1024 * 1024 + 1)
    if len(archive) > 64 * 1024 * 1024 or archive[:6] != b'070701':
        raise ValueError('rootfs is not a bounded newc gzip archive')
    sections['ramdisk'] = ramdisk
    header = bytearray(data[:page])
    struct.pack_into('<I', header, 16, len(ramdisk))
    identifier = android_id(sections)
    header[576:608] = identifier + bytes(12)
    candidate = bytearray(header)
    for name in ('kernel', 'ramdisk', 'second'):
        candidate.extend(sections[name])
        candidate.extend(bytes(-len(candidate) % page))
    used = len(candidate)
    if used > len(data):
        raise ValueError('candidate exceeds original boot partition size')
    candidate.extend(bytes(len(data) - len(candidate)))
    output.mkdir(parents=True, exist_ok=True)
    image = output / 'boot1-custom.NOT_READY.img'
    image.write_bytes(candidate)
    parsed = inspector.inspect(image)
    if not parsed['layout_validated'] or parsed['declared_load_addresses'] != stock['declared_load_addresses']:
        raise ValueError('independent candidate layout inspection failed')
    for part in parsed['sections']:
        if part['sha256'] != hashlib.sha256(sections[part['name']]).hexdigest():
            raise ValueError('candidate section readback mismatch')
    report = dict(status='NOT_READY_TO_BOOT_OR_FLASH', image=image.name, bytes=len(candidate),
                  sha256=hashlib.sha256(candidate).hexdigest(), used_aligned_bytes=used,
                  source_boot1_sha256=expected, rootfs_sha256=metadata['gzip_sha256'],
                  android_id_sha1=identifier.hex(), stock_kernel_and_dtb_unchanged=True,
                  header_cmdline_and_addresses_unchanged=True,
                  changed_header_fields=['ramdisk_size', 'Android image ID'],
                  rootfs_usb_adb_opt_in='read-only rootfs marker, not dependent on header cmdline',
                  signed=False, loader_acceptance='UNKNOWN', physical_usb_console='UNTESTED',
                  software_recovery='UNVERIFIED', uploaded=False, flashed=False,
                  sections=parsed['sections'])
    (output / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (output / 'independent-inspection.json').write_text(json.dumps(parsed, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: value for key, value in report.items() if key != 'sections'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.root, args.output)
