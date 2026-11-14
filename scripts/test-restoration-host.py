"""Rehearse backup restoration on disposable host files; never opens a device."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'phone-tools/backup/2026-11-13/boot1.img'
SIZE = 8388608
HASH = '06d9eb7e4c93ff97bcaff7dc0f4d274ddd8a51efe8bd3639bca2cc31f8314222'
BLOCK = 65536


def digest(stream):
    stream.seek(0)
    result = hashlib.sha256()
    while chunk := stream.read(BLOCK):
        result.update(chunk)
    return result.hexdigest()


def rehearse(source, target, sandbox, identity='disposable-boot1',
             expected_hash=HASH, interrupt_after=None, corrupt=False):
    """Host-file model only; identity is a fixture, not physical target proof."""
    sandbox = sandbox.resolve(strict=True)
    if target.is_symlink() or target.resolve(strict=True).parent != sandbox:
        raise ValueError('target outside disposable sandbox')
    if identity != 'disposable-boot1':
        raise ValueError('target identity mismatch')
    if os.path.samefile(source, target):
        raise ValueError('source aliases target')
    # Keep handles open throughout validation, copy, flush and readback.
    with source.open('rb') as src, target.open('r+b', buffering=0) as dst:
        for stream in (src, dst):
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError('regular host files required')
            if os.fstat(stream.fileno()).st_size != SIZE:
                raise ValueError('size mismatch')
        if digest(src) != expected_hash:
            raise ValueError('source hash mismatch')
        src.seek(0)
        written = 0
        while chunk := src.read(BLOCK):
            view = memoryview(chunk)
            while view:
                count = dst.write(view)
                if not count:
                    raise OSError('short write without progress')
                view = view[count:]
            written += len(chunk)
            if interrupt_after is not None and written >= interrupt_after:
                raise InterruptedError('injected interruption; target is partial')
        dst.flush()
        os.fsync(dst.fileno())
        if corrupt:
            dst.seek(0)
            dst.write(b'BAD!')
            os.fsync(dst.fileno())
        if os.fstat(dst.fileno()).st_size != SIZE or digest(dst) != expected_hash:
            raise ValueError('readback mismatch')
        return {'bytes': written, 'sha256': expected_hash, 'readback_match': True}


def main():
    results = []
    with tempfile.TemporaryDirectory(prefix='mibox-restore-rehearsal-') as name:
        sandbox = Path(name)
        target = sandbox / 'disposable.img'

        def reset(size=SIZE):
            with target.open('wb') as stream:
                stream.truncate(size)

        reset()
        result = rehearse(SOURCE, target, sandbox)
        results.append({'case': 'complete-copy-flush-readback', 'pass': True, **result})

        def rejected(label, error, *, size=SIZE, source=SOURCE, **kwargs):
            reset(size)
            before = target.read_bytes()
            try:
                rehearse(source, target, sandbox, **kwargs)
            except error as exc:
                unchanged = target.read_bytes() == before
                partial = label in ('interruption', 'corrupted-readback')
                if unchanged == partial:
                    raise AssertionError(f'{label}: unexpected target mutation state')
                results.append({'case': label, 'pass': True,
                                'rejected': str(exc), 'target_unchanged': unchanged,
                                'restore_success': False})
            else:
                raise AssertionError(f'{label}: unexpectedly accepted')

        rejected('wrong-identity', ValueError, identity='bootloader')
        rejected('short-target', ValueError, size=SIZE - 1)
        rejected('oversized-target', ValueError, size=SIZE + 1)
        rejected('wrong-source-hash', ValueError, expected_hash='0' * 64)
        rejected('source-target-alias', ValueError, source=target)
        short_source = sandbox / 'short-source.img'
        short_source.write_bytes(b'short')
        rejected('short-source', ValueError, source=short_source)
        nested = sandbox / 'nested'
        nested.mkdir()
        before = target.read_bytes()
        try:
            rehearse(SOURCE, target, nested)
        except ValueError as exc:
            assert target.read_bytes() == before
            results.append({'case': 'outside-sandbox', 'pass': True,
                            'rejected': str(exc), 'target_unchanged': True})
        else:
            raise AssertionError('outside sandbox unexpectedly accepted')
        rejected('interruption', InterruptedError, interrupt_after=BLOCK)
        rejected('corrupted-readback', ValueError, corrupt=True)
        # A fresh full copy can repair the disposable corrupted target.
        result = rehearse(SOURCE, target, sandbox)
        results.append({'case': 'full-retry-after-failure', 'pass': True, **result})

    report = {'scope': 'disposable host regular files only', 'device_access': False,
              'physical_restoration_tested': False, 'permanent_install': 'NOT READY',
              'cases': results, 'passed': len(results)}
    output = ROOT / 'artifacts/restoration/2026-11-14/host-rehearsal.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'HOST_REHEARSAL_PASS: {len(results)} cases; physical restoration NOT TESTED')


if __name__ == '__main__':
    main()
