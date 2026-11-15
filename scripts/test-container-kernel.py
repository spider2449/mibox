"""Regression checks for the offline container readiness gate."""
import runpy
import tempfile
import unittest
from pathlib import Path

CHECKER = runpy.run_path(str(Path(__file__).with_name('check-container-kernel.py')))


class ContainerKernelGate(unittest.TestCase):
    def audit_text(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            path.write_text(text, encoding='utf-8')
            return CHECKER['audit'](path)

    def test_missing_and_module_values_remain_unknown(self):
        report = self.audit_text('CONFIG_NAMESPACES=m\n# CONFIG_VETH is not set\n')
        checks = {item['key']: item for item in report['checks']}
        self.assertEqual(checks['CONFIG_NAMESPACES']['status'], 'UNKNOWN')
        self.assertEqual(checks['CONFIG_VETH']['value'], 'n')
        self.assertEqual(checks['CONFIG_VETH']['line'], 2)
        self.assertEqual(checks['CONFIG_PID_NS']['value'], 'UNKNOWN')
        self.assertIsNone(checks['CONFIG_PID_NS']['line'])
        self.assertEqual(report['config_gate'], 'NOT READY')

    def test_config_pass_never_claims_physical_readiness(self):
        text = ''.join(f'CONFIG_{name}=y\n'
                       for names in CHECKER['GROUPS'].values() for name in names)
        report = self.audit_text(text)
        self.assertEqual(report['config_gate'], 'PASS')
        self.assertEqual(report['runtime_readiness'], 'NOT READY')
        self.assertFalse(report['physical_validation'])

    def test_empty_or_conflicting_input_is_rejected(self):
        for text in ['', 'not a config\n',
                     'CONFIG_NAMESPACES=y\n# CONFIG_NAMESPACES is not set\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.audit_text(text)

    def test_legacy_profile_does_not_pass_pi2_requirements(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            text = ''.join(f'CONFIG_{name}=y\n' for names in CHECKER['LEGACY_GROUPS'].values()
                           for name in names)
            path.write_text(text)
            self.assertEqual(CHECKER['audit'](path, 'legacy-vfs')['config_gate'], 'PASS')
            self.assertEqual(CHECKER['audit'](path, 'pi2-os')['config_gate'], 'NOT READY')
            self.assertEqual(CHECKER['audit'](path, 'legacy-vfs')['runtime_readiness'], 'NOT READY')

    def test_recovered_config_has_namespace_blocker(self):
        root = Path(__file__).resolve().parents[1]
        report = CHECKER['audit'](root / 'artifacts/platform/2026-11-14/stock-kernel.config')
        namespace = next(c for c in report['checks'] if c['key'] == 'CONFIG_NAMESPACES')
        self.assertEqual(namespace['status'], 'BLOCKED')
        self.assertEqual(report['config_gate'], 'NOT READY')
        self.assertEqual(report['config_sha256'],
                         'bd2a94b6aa84afda30661c3a4b41f9759fcc6734ee32daf8335882ba6b43c918')


if __name__ == '__main__':
    unittest.main()
