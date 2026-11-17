#!/usr/bin/env python3
"""A3a: revalidate the boot/boot1 partition backups offline (independent parser).

For each backup: size and SHA256 against the 2026-11-13 manifest; Android v0
header fields; recomputed Android image ID; legacy uImage kernel header with
header and data CRC32; FDT magic/totalsize of `second`; gzip ramdisk with a
newc cpio trailer; and classification of every byte outside the sections
(header slack, inter-section padding, tail) as ZERO or NONZERO with offsets.
Also compares kernel/DTB bytes across boot, boot1 and given candidate images.
Writes artifacts/boot-evidence/2026-11-17/a3a-boot-backups.json. Exit 1 on any
failure or any NONZERO region (packaging must then be refused).
"""
import gzip
import hashlib
import json
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKUP = ROOT / 'phone-tools/backup/2026-11-13'
MANIFEST = ROOT / 'artifacts/boot-evidence/2026-11-13/verified-backups.json'
PARTITION = 8388608


def region(data, start, end, name):
    chunk = data[start:end]
    nonzero = [i for i, b in enumerate(chunk) if b]
    return dict(name=name, start=start, end=end, bytes=end - start,
                classification='ZERO' if not nonzero else 'NONZERO',
                nonzero_bytes=len(nonzero),
                first_nonzero=start + nonzero[0] if nonzero else None,
                last_nonzero=start + nonzero[-1] if nonzero else None)


def check(cond, problems, message):
    if not cond:
        problems.append(message)


def analyse(path, expected_sha=None):
    data = path.read_bytes()
    problems = []
    sha = hashlib.sha256(data).hexdigest()
    check(len(data) == PARTITION, problems, f'size {len(data)} != {PARTITION}')
    if expected_sha:
        check(sha == expected_sha, problems, 'SHA256 differs from verified manifest')
    check(data[:8] == b'ANDROID!', problems, 'no ANDROID! magic')
    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr,
     tags_addr, page, dt_size, _unused) = struct.unpack_from('<10I', data, 8)
    name = data[48:64].rstrip(b'\0').decode('ascii', 'replace')
    cmdline = data[64:576].split(b'\0')[0].decode('ascii', 'replace')
    image_id = data[576:608]
    check(page == 2048, problems, f'page size {page}')
    check(dt_size == 0, problems, f'dt_size {dt_size} (v0 expects 0)')
    sections, offset = {}, page
    for sname, size in (('kernel', kernel_size), ('ramdisk', ramdisk_size), ('second', second_size)):
        sections[sname] = dict(start=offset, size=size, end=offset + size)
        offset += size + (-size % page)
    aligned_end = offset
    check(aligned_end <= PARTITION, problems, 'sections exceed partition')
    parts = {n: data[s['start']:s['end']] for n, s in sections.items()}
    digest = hashlib.sha1()
    for n in ('kernel', 'ramdisk', 'second'):
        digest.update(parts[n])
        digest.update(struct.pack('<I', len(parts[n])))
    check(image_id[:20] == digest.digest() and not any(image_id[20:]), problems,
          'Android image ID does not match sections')
    # Legacy uImage kernel.
    k = parts['kernel']
    magic, hcrc, _time, dsize, load, entry, dcrc, os_, arch, itype, comp = struct.unpack_from('>7I4B', k, 0)
    header = bytearray(k[:64])
    header[4:8] = b'\0\0\0\0'
    uimage = dict(magic=hex(magic), load=hex(load), entry=hex(entry), data_size=dsize,
                  name=k[32:64].rstrip(b'\0').decode('ascii', 'replace'),
                  os=os_, arch=arch, type=itype, compression=comp,
                  header_crc_ok=zlib.crc32(bytes(header)) & 0xffffffff == hcrc,
                  data_crc_ok=zlib.crc32(k[64:64 + dsize]) & 0xffffffff == dcrc,
                  trailing_bytes_after_data=len(k) - 64 - dsize)
    check(magic == 0x27051956, problems, 'kernel is not a legacy uImage')
    check(uimage['header_crc_ok'] and uimage['data_crc_ok'], problems, 'uImage CRC mismatch')
    check(uimage['trailing_bytes_after_data'] == 0, problems, 'bytes after uImage data inside kernel section')
    # FDT.
    s = parts['second']
    fdt_magic, fdt_total = struct.unpack_from('>II', s, 0)
    check(fdt_magic == 0xd00dfeed and fdt_total == len(s), problems, 'second is not an exact FDT')
    # Ramdisk.
    r = parts['ramdisk']
    check(r[:2] == b'\x1f\x8b', problems, 'ramdisk not gzip')
    raw = gzip.decompress(r)
    check(b'TRAILER!!!' in raw[-512:], problems, 'cpio trailer missing')
    # Bytes outside sections.
    regions = [region(data, 608, page, 'header slack after image ID')]
    for n, sec in sections.items():
        pad_end = sec['end'] + (-sec['size'] % page)
        regions.append(region(data, sec['end'], pad_end, f'{n} page padding'))
    regions.append(region(data, aligned_end, PARTITION, 'tail after last section'))
    for r_ in regions:
        check(r_['classification'] == 'ZERO', problems, f"{r_['name']} has {r_['nonzero_bytes']} nonzero bytes")
    return dict(file=str(path.relative_to(ROOT)).replace('\\', '/'), bytes=len(data), sha256=sha,
                header=dict(name=name, cmdline=cmdline, page_size=page, kernel_addr=hex(kernel_addr),
                            ramdisk_addr=hex(ramdisk_addr), second_addr=hex(second_addr),
                            tags_addr=hex(tags_addr)),
                sections={n: dict(sec, sha256=hashlib.sha256(parts[n]).hexdigest()) for n, sec in sections.items()},
                aligned_end=aligned_end, uimage=uimage,
                fdt=dict(magic=hex(fdt_magic), totalsize=fdt_total),
                ramdisk=dict(gzip_bytes=len(r), cpio_bytes=len(raw)),
                regions=regions, problems=problems, status='PASS' if not problems else 'FAIL')


def main(candidates):
    manifest = {e['File']: e for e in json.loads(MANIFEST.read_text(encoding='utf-8-sig'))}
    reports = {n: analyse(BACKUP / n, manifest[n]['SHA256']) for n in ('boot.img', 'boot1.img')}
    for c in candidates:
        reports[c] = analyse(ROOT / c)
    stock = reports['boot1.img']['sections']
    comparison = {name: dict(kernel_equal_boot1=r['sections']['kernel']['sha256'] == stock['kernel']['sha256'],
                             dtb_equal_boot1=r['sections']['second']['sha256'] == stock['second']['sha256'],
                             header_addresses_equal_boot1=r['header'] == reports['boot1.img']['header'])
                  for name, r in reports.items()}
    failed = [n for n in ('boot.img', 'boot1.img') if reports[n]['status'] != 'PASS']
    failed += [n for n in candidates if reports[n]['status'] != 'PASS' or not all(comparison[n].values())]
    out = ROOT / 'artifacts/boot-evidence/2026-11-17/a3a-boot-backups.json'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dict(reports=reports, comparison_with_boot1=comparison,
                                   status='PASS' if not failed else 'FAIL', failed=failed), indent=2) + '\n')
    for n, r in reports.items():
        print(f"{n}: {r['status']} sha256 {r['sha256'][:16]} end {r['aligned_end']} "
              f"regions {[x['classification'] for x in r['regions']]} {r['problems']}")
        print(f"   {comparison[n]}")
    print('A3A', 'PASS' if not failed else 'FAIL', out)
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
