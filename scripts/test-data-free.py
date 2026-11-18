#!/usr/bin/env python3
"""Host test for the S4 Alpine data free-space monitor and its login hook.

Runs assets/alpine/usr/local/bin/mibox-data-free with a stub `stat` (as in
test-apk-guard.py) and sources the profile.d hook from a login-like shell to
check it never ends the session. Run under a POSIX sh (WSL).
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MONITOR = ROOT / 'assets/alpine/usr/local/bin/mibox-data-free'
HOOK = ROOT / 'assets/alpine/etc/profile.d/90mibox-data-free.sh'


def text(path):
    return path.read_text().replace('\r\n', '\n')


def main():
    monitor, hook = text(MONITOR), text(HOOK)
    helper = text(ROOT / 'assets/rootfs/mibox-persistent-console')
    floors = set(re.findall(r'^floor_kib=(\d+)$', monitor, re.M)) | set(re.findall(r'^floor_kib=(\d+)$', helper, re.M))
    failures = [] if floors == {'262144'} else [f'floor values disagree: {floors}']
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / 'bin').mkdir()
        # Stub `stat -f -c '%a %S' /`: FAKE_AVAIL in KiB (multiple of 4), or
        # non-numeric to simulate an unreadable filesystem.
        (work / 'bin/stat').write_text('#!/bin/sh\ncase "$FAKE_AVAIL" in *[!0-9]*) exit 1;; esac\n'
                                       'echo "$((FAKE_AVAIL / 4)) 4096"\n')
        (work / 'bin/stat').chmod(0o755)
        script = work / 'mibox-data-free'
        script.write_text(monitor)
        script.chmod(0o755)
        env_base = dict(os.environ, PATH=f'{work}/bin:/usr/bin:/bin')
        cases = [
            # name, KiB, args, exit, stdout must contain, stdout must be empty
            ('ok', '2098616', [], 0, 'STATE=OK', False),
            ('ok quiet is silent', '2098616', ['-q'], 0, None, True),
            ('low at 2x floor - 4', '524284', [], 1, 'STATE=LOW', False),
            ('ok exactly at 2x floor', '524288', [], 0, 'STATE=OK', False),
            ('low quiet notice', '400000', ['-q'], 1, 'NOTICE: data has 390 MiB free', False),
            ('below floor', '262140', [], 2, 'STATE=BELOW_FLOOR', False),
            ('exactly at floor is low, not below', '262144', [], 1, 'STATE=LOW', False),
            ('below floor quiet warning', '1000', ['-q'], 2, 'below the 256 MiB floor', False),
            ('unreadable', 'n/a', [], 3, 'STATE=UNKNOWN', False),
            ('unreadable quiet prints no machine line', 'n/a', ['-q'], 3, None, True),
        ]
        for name, avail, args, code, needle, empty in cases:
            r = subprocess.run(['sh', str(script), *args], env=dict(env_base, FAKE_AVAIL=avail),
                               capture_output=True, text=True, timeout=10)
            ok = r.returncode == code and (needle is None or needle in r.stdout) and (not empty or r.stdout == '')
            print('PASS' if ok else 'FAIL', name, f'exit={r.returncode}', repr(r.stdout.strip()))
            if not ok:
                failures.append(name)
        # The hook calls the absolute path; point it at the copy under test.
        hook_copy = work / 'hook.sh'
        hook_copy.write_text(hook.replace('/usr/local/bin/mibox-data-free', str(script)))
        for name, avail, needle in (('hook below floor', '1000', 'WARNING'), ('hook ok silent', '2098616', None),
                                    ('hook unreadable', 'n/a', None)):
            r = subprocess.run(['sh', '-c', f'set -e; . {hook_copy}; echo SESSION_CONTINUES'],
                               env=dict(env_base, FAKE_AVAIL=avail), capture_output=True, text=True, timeout=10)
            lines = r.stdout.strip().splitlines()
            ok = (r.returncode == 0 and lines[-1:] == ['SESSION_CONTINUES']
                  and (needle in r.stdout if needle else len(lines) == 1))
            print('PASS' if ok else 'FAIL', name, repr(r.stdout.strip()))
            if not ok:
                failures.append(name)
        (work / 'h2.sh').write_text(hook.replace('/usr/local/bin/mibox-data-free', str(work / 'nonexistent')))
        r = subprocess.run(['sh', '-c', f'set -e; . {work}/h2.sh; echo GO'],
                           env=env_base, capture_output=True, text=True, timeout=10)
        ok = r.returncode == 0 and r.stdout.strip() == 'GO'
        print('PASS' if ok else 'FAIL', 'hook with monitor missing is silent', repr(r.stdout.strip()))
        if not ok:
            failures.append('hook with monitor missing')
    print('DATA_FREE_TEST', 'FAIL ' + ', '.join(failures) if failures else 'PASS')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
