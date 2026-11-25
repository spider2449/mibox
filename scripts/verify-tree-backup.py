#!/usr/bin/env python3
"""Compare tar archives with a device listing and device SHA256 list.

Usage: verify-tree-backup.py LISTING HASHES OUTPUT.json ARCHIVE...
LISTING lines (s2-tree-backup.sh list): type|mode|uid:gid|size|path.
HASHES lines (s2-tree-backup.sh hashes): sha256sum output for regular files.
Checks every path's type, mode, owner, size and regular-file content hash;
sockets are expected to be absent from tar. Writes a JSON manifest with the
archive SHA256s and the result.
"""
import hashlib
import json
import sys
import tarfile

TYPES = {'directory': tarfile.DIRTYPE, 'regular file': tarfile.REGTYPE,
         'regular empty file': tarfile.REGTYPE, 'symbolic link': tarfile.SYMTYPE,
         'character special file': tarfile.CHRTYPE, 'block special file': tarfile.BLKTYPE}


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main(listing, hashes, output, *archives):
    want_hash = {}
    for line in open(hashes, encoding='utf-8'):
        digest, path = line.rstrip('\n').split('  ', 1)
        want_hash[path] = digest
    expected = {}
    for line in open(listing, encoding='utf-8'):
        kind, mode, owner, size, path = line.rstrip('\n').split('|', 4)
        expected[path] = (kind, int(mode, 8), owner, int(size))
    found, problems, skipped, hashed = {}, [], [], 0
    for archive in archives:
        with tarfile.open(archive) as tar:
            for m in tar.getmembers():
                name = m.name.rstrip('/')
                found[name] = m
                if m.isfile():
                    digest = hashlib.sha256(tar.extractfile(m).read()).hexdigest()
                    if want_hash.pop(name, None) != digest:
                        problems.append((name, 'sha256 mismatch or not hashed on device'))
                    hashed += 1
    for path, (kind, mode, owner, size) in sorted(expected.items()):
        m = found.pop(path, None)
        if kind == 'socket':
            if m is not None:
                problems.append((path, 'socket present in tar'))
            skipped.append(path)
            continue
        if m is None:
            problems.append((path, 'missing'))
            continue
        want = TYPES.get(kind)
        got = tarfile.REGTYPE if m.type == tarfile.AREGTYPE else m.type
        if want is None or got != want:
            problems.append((path, f'type {kind} vs {m.type!r}'))
        if (m.mode & 0o7777) != mode and kind != 'symbolic link':
            problems.append((path, f'mode {oct(mode)} vs {oct(m.mode)}'))
        if f'{m.uid}:{m.gid}' != owner:
            problems.append((path, f'owner {owner} vs {m.uid}:{m.gid}'))
        if m.isfile() and m.size != size:
            problems.append((path, f'size {size} vs {m.size}'))
    problems += [(p, 'extra in tar') for p in sorted(found)]
    problems += [(p, 'hashed on device, not in tar') for p in sorted(want_hash)]
    result = dict(listing_entries=len(expected), files_hashed=hashed,
                  skipped_sockets=skipped,
                  archives={a: sha256(a) for a in archives},
                  problems=problems, status='PASS' if not problems else 'FAIL')
    with open(output, 'w') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    print(result['status'], len(expected), 'entries,', hashed, 'files hashed,',
          len(problems), 'problems')
    for p in problems[:20]:
        print(' ', p)
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
