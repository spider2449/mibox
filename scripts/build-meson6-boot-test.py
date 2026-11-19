"""Package the pinned development kernel for a RAM-only experiment; no device I/O."""
import argparse
import hashlib
import importlib.util
import json
import lzma
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(destination, rootfs=None, kernel_evidence='2026-11-15'):
    if not destination.resolve().is_relative_to((ROOT / 'target').resolve()):
        raise ValueError('output must stay within workspace target')
    evidence = ROOT / 'artifacts/kernel-meson6/2026-11-15'
    report = json.loads((ROOT / 'artifacts/kernel-meson6' / kernel_evidence / 'containers-v1/build.json').read_text())
    if not all(report.get(k) for k in ['build_complete', 'elf_arm32', 'compressed_payload_matches_image']):
        raise ValueError('kernel build has not passed artifact validation')
    if not json.loads((evidence / 'source-audit.json').read_text())['memory_model_matches_captured_iomem']:
        raise ValueError('memory model mismatch')
    config_path = ROOT / 'target/kernel-meson6/containers-v1/resolved.config'
    config = config_path.read_bytes()
    if digest(config) != report['config_sha256']:
        raise ValueError('resolved config hash mismatch')
    for required in [b'CONFIG_NAMESPACES=y\n', b'CONFIG_USER_NS=y\n', b'CONFIG_VETH=y\n',
                     b'CONFIG_SECCOMP_FILTER=y\n', b'# CONFIG_MTD is not set\n']:
        if required not in config:
            raise ValueError('kernel configuration gate did not pass')
    raw = (ROOT / 'target/kernel-meson6/containers-v1/Image').read_bytes()
    if digest(raw) != report['artifacts']['Image']['sha256']:
        raise ValueError('Image differs from build manifest')
    stock_path = ROOT / 'phone-tools/backup/2026-11-13/boot1.img'
    stock = stock_path.read_bytes()
    if digest(stock) != '06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222':
        raise ValueError('stock template differs from verified backup')
    spec = importlib.util.spec_from_file_location('boot_inspector', ROOT / 'scripts/inspect-mibox-boot.py')
    inspector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inspector)
    layout = inspector.inspect(stock_path)
    if not layout['layout_validated'] or not layout['matches_installed_script']:
        raise ValueError('stock template layout is not validated')
    sections = {s['name']: stock[s['start']:s['end']] for s in layout['sections']}
    if any(stock[layout['sections'][-1]['end']:]):
        raise ValueError('unclassified stock trailer')
    old_kernel = sections['kernel']
    if old_kernel[:4] != bytes.fromhex('27051956') or old_kernel[28:32] != bytes([5, 2, 2, 3]):
        raise ValueError('stock kernel is not ARM/Linux/LZMA legacy uImage')
    load, entry = struct.unpack_from('>II', old_kernel, 16)
    if load != 0x80008000 or entry != load or load + len(raw) > 0x82000000:
        raise ValueError('kernel load range is not within the reviewed low RAM window')
    properties = old_kernel[64]
    dictionary, = struct.unpack_from('<I', old_kernel, 65)
    if properties != 93 or dictionary != 8388608:
        raise ValueError('unreviewed stock LZMA properties')
    payload = lzma.compress(raw, format=lzma.FORMAT_ALONE, filters=[dict(
        id=lzma.FILTER_LZMA1, dict_size=dictionary, lc=3, lp=0, pb=2,
        mode=lzma.MODE_NORMAL, nice_len=128, mf=lzma.MF_BT4)])
    if payload[:13] != old_kernel[64:77]:
        raise ValueError('LZMA properties/size convention differ from the accepted stock kernel')
    header = bytearray(old_kernel[:64])
    struct.pack_into('>III', header, 4, 0, 0, len(payload))
    struct.pack_into('>I', header, 24, zlib.crc32(payload))
    header[32:64] = b'Linux-3.10.99-mibox-container-dev'[:32].ljust(32, b'\0')
    struct.pack_into('>I', header, 4, zlib.crc32(header))
    kernel = bytes(header) + payload
    verify_header = bytearray(kernel[:64])
    crc, = struct.unpack_from('>I', verify_header, 4)
    verify_header[4:8] = bytes(4)
    if crc != zlib.crc32(verify_header) or lzma.decompress(kernel[64:]) != raw:
        raise ValueError('uImage roundtrip failed')
    rootfs = rootfs or ROOT / 'target/mibox-rootfs-kernel'
    rootfs_report = json.loads((rootfs / 'manifest.json').read_text())
    ramdisk = (rootfs / 'initramfs.NOT_READY.cpio.gz').read_bytes()
    if digest(ramdisk) != rootfs_report['gzip_sha256'] or not rootfs_report.get('container_kernel_test'):
        raise ValueError('dedicated kernel-test rootfs required')
    if rootfs_report['private_keys_included'] or rootfs_report['qemu_probe_included'] or not rootfs_report['usb_adb_enabled_by_rootfs_marker']:
        raise ValueError('rootfs console/key gate failed')
    dtb = sections['second']
    if digest(dtb) != '24b30f1aafe26845839966721b3c083cb3ed49280178276b6114df6d725cb95c':
        raise ValueError('must retain the exact stock DTB')
    sections.update(kernel=kernel, ramdisk=ramdisk)
    page = layout['page_size']
    outer = bytearray(stock[:page])
    struct.pack_into('<I', outer, 8, len(kernel))
    struct.pack_into('<I', outer, 16, len(ramdisk))
    sha1 = hashlib.sha1()
    for name in ['kernel', 'ramdisk', 'second']:
        sha1.update(sections[name])
        sha1.update(struct.pack('<I', len(sections[name])))
    outer[576:608] = sha1.digest() + bytes(12)
    image = bytearray(outer)
    for name in ['kernel', 'ramdisk', 'second']:
        image.extend(sections[name])
        image.extend(bytes(-len(image) % page))
    used = len(image)
    if used > 8388608:
        raise ValueError('candidate exceeds the verified RAM transfer window')
    image.extend(bytes(8388608 - used))
    destination.mkdir(parents=True, exist_ok=True)
    image_path = destination / 'boot1-custom.NOT_READY.img'
    image_path.write_bytes(image)
    parsed = inspector.inspect(image_path)
    if not parsed['layout_validated'] or parsed['declared_load_addresses'] != layout['declared_load_addresses']:
        raise ValueError('independent Android image inspection failed')
    for section in parsed['sections']:
        if section['sha256'] != digest(sections[section['name']]):
            raise ValueError('independent section hash mismatch')
    metadata = dict(status='EXPERIMENTAL_RAM_TEST_ONLY', image_sha256=digest(image), image_bytes=len(image),
                    used_bytes=used, kernel_release='3.10.99', kernel_build_tag='3.10.99-mibox-container-dev+',
                    kernel_Image_sha256=digest(raw), uimage_sha256=digest(kernel), uimage_bytes=len(kernel),
                    uimage_load=hex(load), uimage_entry=hex(entry), uimage_timestamp=0,
                    lzma_dictionary_bytes=dictionary, lzma_header_matches_stock=True,
                    stock_dtb_sha256=digest(dtb), stock_dtb_unchanged=True,
                    rootfs=rootfs_report, build_config_sha256=report['config_sha256'],
                    source_commit=report['source_commit'], patches=report['patches'],
                    boot_acceptance='UNKNOWN', software_return='UNKNOWN', physical_validation=False,
                    uploaded=False, flashed=False, sections=parsed['sections'])
    (destination / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (destination / 'kernel.NOT_READY.uImage').write_bytes(kernel)
    (destination / 'independent-inspection.json').write_text(json.dumps(parsed, indent=2) + '\n')
    print(json.dumps({k: metadata[k] for k in ['status', 'image_sha256', 'image_bytes', 'used_bytes',
                                             'uimage_bytes', 'kernel_release']}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'target/mibox-boot-candidate-kernel')
    parser.add_argument('--rootfs', type=Path)
    parser.add_argument('--kernel-evidence', default='2026-11-15',
                        help='artifacts/kernel-meson6/<name>/containers-v1/build.json to pin')
    args = parser.parse_args()
    build(args.output, args.rootfs, args.kernel_evidence)
