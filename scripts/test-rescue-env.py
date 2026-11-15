"""Exercise fixed updater failures on disposable regular files only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('payload', ROOT/'scripts/prepare-rescue-window.py')
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)
ORIGINAL = (ROOT/'phone-tools/backup/2026-11-13/env.img').read_bytes()
PATCHED, _ = payload.prepare(ORIGINAL)
TOOL = ROOT/'target/rescue-window/rescue-env-fixture'
RESULTS = []


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mibox-env-fixture-')
        self.target = Path(self.temp.name)/'env.img'
        self.target.write_bytes(ORIGINAL)

    def tearDown(self):
        self.temp.cleanup()

    def run_tool(self, action, success, inject=None):
        environment = os.environ.copy()
        environment.pop('MIBOX_ENV_TEST_INTERRUPT', None)
        environment.pop('MIBOX_ENV_TEST_CORRUPT', None)
        if inject:
            environment[inject] = '1'
        result = subprocess.run([str(TOOL), action, str(self.target)], capture_output=True,
                                text=True, timeout=10, env=environment)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        RESULTS.append(dict(case=self.id().split('.')[-1], action=action,
                            exit_code=result.returncode, expected_success=success,
                            output=result.stdout.strip(), error=result.stderr.strip()))

    def test_complete_install_remove(self):
        self.run_tool('--check', True)
        self.run_tool('--install', True)
        self.assertEqual(self.target.read_bytes(), PATCHED)
        self.run_tool('--remove', True)
        self.assertEqual(self.target.read_bytes(), ORIGINAL)

    def test_repeat_install_rejected(self):
        self.target.write_bytes(PATCHED)
        self.run_tool('--install', False)
        self.assertEqual(self.target.read_bytes(), PATCHED)

    def test_wrong_prefix(self):
        bad = b'BAD!'+ORIGINAL[4:]
        self.target.write_bytes(bad)
        self.run_tool('--install', False)
        self.assertEqual(self.target.read_bytes(), bad)

    def test_wrong_tail(self):
        bad = ORIGINAL[:-1]+bytes([ORIGINAL[-1]^1])
        self.target.write_bytes(bad)
        self.run_tool('--install', False)
        self.assertEqual(self.target.read_bytes(), bad)

    def test_wrong_size(self):
        for size in (32768, 4194303, 4194305):
            with self.target.open('wb') as stream:
                stream.truncate(size)
            before = self.target.read_bytes()
            self.run_tool('--install', False)
            self.assertEqual(self.target.read_bytes(), before)

    def test_symlink_rejected(self):
        other = self.target.with_name('other.img')
        self.target.rename(other)
        self.target.symlink_to(other)
        self.run_tool('--install', False)
        self.assertEqual(other.read_bytes(), ORIGINAL)

    def test_interruption_and_explicit_recovery(self):
        self.run_tool('--install', False, 'MIBOX_ENV_TEST_INTERRUPT')
        partial = self.target.read_bytes()
        self.assertNotEqual(partial, ORIGINAL)
        self.assertNotEqual(partial, PATCHED)
        self.assertEqual(partial[32768:], ORIGINAL[32768:])
        self.run_tool('--recover-original', True)
        self.assertEqual(self.target.read_bytes(), ORIGINAL)

    def test_corrupted_readback(self):
        self.run_tool('--install', False, 'MIBOX_ENV_TEST_CORRUPT')
        self.assertNotEqual(self.target.read_bytes(), PATCHED)

    def test_recovery_rejects_unrelated_damage(self):
        bad = bytearray(ORIGINAL)
        bad[100] = next(b for b in range(256) if b not in (ORIGINAL[100], PATCHED[100]))
        self.target.write_bytes(bad)
        self.run_tool('--recover-original', False)
        self.assertEqual(self.target.read_bytes(), bad)

    def test_payload_semantics_and_crc(self):
        original, changed = payload.parse(ORIGINAL), payload.parse(PATCHED)
        self.assertEqual([k for k in original if original[k] != changed[k]], [b'preboot'])
        self.assertEqual(changed[b'preboot'], b'update 10000;'+original[b'preboot'])
        self.assertEqual(PATCHED[32768:], ORIGINAL[32768:])
        self.assertEqual(len(PATCHED), len(ORIGINAL))
        with self.assertRaises(ValueError):
            payload.parse(b'BAD!'+ORIGINAL[4:])
        with self.assertRaises(ValueError):
            payload.prepare(PATCHED)


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = dict(scope='Disposable host regular-file fixture; no devices', device_access=False,
                  tests=result.testsRun, passed=result.wasSuccessful(), cases=RESULTS,
                  updater_source_sha256=hashlib.sha256((ROOT/'src/hardware/rescue-env.c').read_bytes()).hexdigest(),
                  fixture_sha256=hashlib.sha256(TOOL.read_bytes()).hexdigest(),
                  source_sha256=hashlib.sha256(ORIGINAL).hexdigest(),
                  patched_sha256=hashlib.sha256(PATCHED).hexdigest())
    (ROOT/'artifacts/restoration/2026-11-15/rescue-env-host-tests.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if result.wasSuccessful() else 1)
