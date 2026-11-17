#!/usr/bin/env python3
"""Host test for the S4 apk free-space guard embedded in the persistence helper.

Extracts the APKGUARD heredoc from assets/rootfs/mibox-persistent-console and
runs it with stub `df` and `/sbin/apk` replacements (the guard's absolute
/sbin/apk path is rewritten to the stub). Run under a POSIX sh (WSL).
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    helper = (ROOT / 'assets/rootfs/mibox-persistent-console').read_text().replace('\r\n', '\n')
    match = re.search(r"<<'APKGUARD'\n(.*?)\nAPKGUARD\n", helper, re.S)
    assert match, 'APKGUARD block missing'
    guard = match.group(1) + '\n'
    floors = set(re.findall(r'^floor_kib=(\d+)$', helper, re.M))
    floors |= set(re.findall(r'^floor_kib=(\d+)$', guard, re.M))
    assert floors == {'262144'}, f'floor values disagree: {floors}'
    assert 'PATH=/usr/local/sbin:' in helper, 'persistent shell PATH must prefer the guard'
    failures = []
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'bin').mkdir()
        apk_log = work / 'apk.log'
        (work / 'bin/apk').write_text(f'#!/bin/sh\necho "$@" >> {apk_log}\n')
        # Stub `stat -f -c '%a %S' /`: available blocks of 4096 bytes. FAKE_AVAIL
        # is in KiB and a multiple of 4, or non-numeric to simulate failure.
        (work / 'bin/stat').write_text('#!/bin/sh\ncase "$FAKE_AVAIL" in *[!0-9]*) exit 1;; esac\n'
                                       'echo "$((FAKE_AVAIL / 4)) 4096"\n')
        script = work / 'guard'
        script.write_text(guard.replace('exec /sbin/apk', f'exec {work}/bin/apk'))
        for name in ('apk', 'stat', 'guard'):
            (work / ('bin/' + name if name != 'guard' else name)).chmod(0o755)
        cases = [
            ('add allowed above floor', '262144', ['--no-cache', 'add', 'coreutils'], 0, True),
            ('add refused below floor', '262140', ['add', 'coreutils'], 75, False),
            ('upgrade refused below floor', '1000', ['-U', 'upgrade'], 75, False),
            ('update refused below floor', '1000', ['update'], 75, False),
            ('info passes below floor', '1000', ['info', '-e', 'dropbear'], 0, True),
            ('del passes below floor (frees space)', '1000', ['del', 'curl'], 0, True),
            ('unreadable free space refuses', 'n/a', ['add', 'x'], 75, False),
            ('add after -X value refused below floor', '1000', ['-X', 'http://r/x', 'add', 'y'], 75, False),
            ('add after --repository=v refused', '1000', ['--repository=http://r', 'add', 'y'], 75, False),
            ('cache clean passes below floor', '1000', ['cache', 'clean'], 0, True),
            ('no args passes through', '1000', [], 0, True),
        ]
        for name, avail, args, code, should_call in cases:
            if apk_log.exists():
                apk_log.unlink()
            env = dict(os.environ, PATH=f'{work}/bin:/usr/bin:/bin', FAKE_AVAIL=avail)
            result = subprocess.run(['sh', str(script), *args], env=env,
                                    capture_output=True, text=True, timeout=10)
            called = apk_log.exists()
            ok = result.returncode == code and called == should_call
            print(('PASS' if ok else 'FAIL'), name, result.returncode, result.stderr.strip())
            if not ok:
                failures.append(name)
    print('APK_GUARD_TEST', 'FAIL' if failures else 'PASS')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
