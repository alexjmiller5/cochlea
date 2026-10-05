import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('ota', Path(__file__).with_name('ota-install.py'))


class OTATests(unittest.TestCase):
    def load(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        return module

    def test_port_selection_preserves_tcp_web_and_foreground_mappings(self):
        m = self.load()
        config = {'TCP': {'443': {'HTTPS': True}},
                  'Web': {'fixture.ts.net:8443': {'Handlers': {'/': {}}}},
                  'Foreground': {'session': {'TCP': {'10000': {'HTTPS': True}}}}}
        self.assertEqual(m.choose_port(config, None), 10001)
        for port in ('443', '8443', '10000', '0', '65536', 'invalid'):
            with self.subTest(port=port), self.assertRaises(ValueError):
                m.choose_port(config, port)
        self.assertEqual(m.choose_port(config, '10443'), 10443)
        self.assertEqual(config['TCP']['443'], {'HTTPS': True})

    def test_manifest_and_html_escape_metadata(self):
        import plistlib
        import tempfile
        m = self.load()
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            m.write_page(path, 'https://fixture.ts.net:10001', {
                'CFBundleIdentifier': 'com.example.app', 'CFBundleVersion': '7',
                'CFBundleShortVersionString': '1.2', 'CFBundleDisplayName': '<A & B>'})
            manifest = plistlib.loads((path / 'manifest.plist').read_bytes())
            self.assertEqual(manifest['items'][0]['metadata']['bundle-version'], '7')
            self.assertEqual(manifest['items'][0]['assets'][0]['url'], 'https://fixture.ts.net:10001/app.ipa')
            self.assertIn('&lt;A &amp; B&gt;', (path / 'index.html').read_text())

    def test_foreground_serve_failure_cleans_its_process_and_preserves_other_mappings(self):
        import plistlib
        import tempfile
        import zipfile
        from unittest.mock import Mock, patch
        m = self.load()
        config = {'TCP': {'443': {'HTTPS': True}, '8443': {'HTTPS': True}}}
        process = Mock()
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as root:
            ipa = Path(root) / 'Fixture.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': 'com.example.app', 'CFBundleVersion': '1'}))
            with patch.object(m, 'command', side_effect=[{'Self': {'DNSName': 'fixture.ts.net.'}}, config, config]) as command, \
                    patch.object(m.subprocess, 'Popen', return_value=process) as popen, \
                    patch.object(m.urllib.request, 'urlopen', side_effect=RuntimeError('readiness failed')):
                with self.assertRaisesRegex(RuntimeError, 'readiness failed'):
                    m.serve(ipa)
            args = popen.call_args.args[0]
            self.assertIn('--https=10000', args)
            self.assertIn('--bg=false', args)
            self.assertNotIn('--yes', args)
            self.assertEqual(popen.call_args.kwargs['stdin'], m.subprocess.DEVNULL)
            process.terminate.assert_called_once()
            process.wait.assert_called_once()
            self.assertEqual(command.call_count, 3)
            self.assertEqual(config['TCP'], {'443': {'HTTPS': True}, '8443': {'HTTPS': True}})
            self.assertTrue(ipa.is_file())
