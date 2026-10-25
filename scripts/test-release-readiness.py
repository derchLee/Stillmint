#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check-release-readiness.py')
spec = importlib.util.spec_from_file_location('preflight', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseReadinessTests(unittest.TestCase):
    def test_missing_config_never_passes(self):
        result = module.audit({})
        self.assertEqual(result['decision'], 'BLOCKED')
        self.assertFalse(result['configurationPassed'])

    def test_explicit_null_owner_template_returns_json_report_not_traceback(self):
        result = module.audit({'teamID': None, 'reviewContactEmail': None})
        self.assertEqual(result['decision'], 'BLOCKED')
        self.assertFalse(result['configurationPassed'])

    def test_placeholders_and_nonpublic_urls_rejected(self):
        for value in ['https://YOUR-DOMAIN.example/privacy', 'https://example.com/privacy', 'https://www.example.org/support', 'http://real.com', 'https://localhost/a', 'https://127.0.0.1/a', 'https://support.invalid/a', 'https://user:pass@real.com/a', 'https://real.com/#fake']:
            self.assertFalse(module.public_https(value), value)

    def test_unresolved_owner_markers_never_count_as_real_information(self):
        for value in ['TBD', 'TBD — individual developer legal name', 'OWNER_INPUT', 'owner input required']:
            self.assertTrue(module.placeholder(value), value)

    def test_missing_app_and_external_evidence_cannot_be_approved(self):
        result = module.audit({'bundleID': 'com.samplebrand.photos', 'teamID': 'ABCDEFGHIJ'})
        self.assertEqual(result['decision'], 'BLOCKED')
        self.assertTrue(any(c['id'] == 'artifact.readable' and c['status'] == 'BLOCKED' for c in result['checks']))
        self.assertTrue(all(c['status'] == 'BLOCKED' for c in result['checks'] if c['id'].startswith('external.')))

    def test_cli_dryrun_missing_values_exits_nonzero(self):
        with tempfile.TemporaryDirectory(prefix='stillmint-preflight-test-') as folder:
            config = Path(folder) / 'config.json'
            config.write_text('{}')
            completed = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config)], capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn('"uploadsPerformed": false', completed.stdout)

    def test_malformed_json_exits_nonzero(self):
        with tempfile.TemporaryDirectory(prefix='stillmint-preflight-test-') as folder:
            config = Path(folder) / 'config.json'
            config.write_text('invalid')
            completed = subprocess.run([sys.executable, str(SCRIPT), '--config', str(config)], capture_output=True, text=True)
            self.assertEqual(completed.returncode, 2)


if __name__ == '__main__':
    unittest.main()
