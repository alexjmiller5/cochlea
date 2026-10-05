import importlib.util
import plistlib
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('sign_ios', Path(__file__).with_name('sign-ios.py'))


def load():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


def profile():
    return {'UUID': 'fixture-profile', 'TeamIdentifier': ['TESTTEAM'],
            'ApplicationIdentifierPrefix': ['TESTTEAM'],
            'ExpirationDate': datetime.now() + timedelta(days=30),
            'ProvisionedDevices': ['synthetic-device'], 'DeveloperCertificates': [b'certificate'],
            'Entitlements': {'application-identifier': 'TESTTEAM.com.example.*',
                             'com.apple.developer.team-identifier': 'TESTTEAM',
                             'get-task-allow': False}}


class SigningTests(unittest.TestCase):
    def test_ad_hoc_profile_matches_bundle_and_selected_device(self):
        m = load()
        self.assertEqual(m.validate_profile(profile(), 'com.example.App', 'synthetic-device'),
                         ('TESTTEAM', 'fixture-profile'))

    def test_rejects_wrong_bundle_device_development_expired_and_enterprise(self):
        m = load()
        cases = [('bundle', 'net.other.App', 'synthetic-device'),
                 ('device', 'com.example.App', 'another-device')]
        for _, bundle, device in cases:
            with self.subTest(bundle=bundle, device=device), self.assertRaises(ValueError):
                m.validate_profile(profile(), bundle, device)
        for change in [{'ProvisionedDevices': []}, {'ProvisionsAllDevices': True},
                       {'ExpirationDate': datetime.now() - timedelta(days=1)},
                       {'DeveloperCertificates': []}, {'UUID': '../escape'}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                m.validate_profile(profile() | change, 'com.example.App', None)
        p = profile()
        p['Entitlements']['get-task-allow'] = True
        with self.assertRaises(ValueError):
            m.validate_profile(p, 'com.example.App', None)

    def test_selects_only_private_identity_authorized_by_profile(self):
        m = load()
        import hashlib
        fingerprint = hashlib.sha1(b'certificate').hexdigest().upper()
        with patch.object(m, 'run', return_value=f'1) {fingerprint} "Apple Distribution: Fixture"'.encode()):
            self.assertEqual(m.identity_for_profile(Path('keychain'), profile()), fingerprint)
        with patch.object(m, 'run', return_value=b'1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Other"'):
            with self.assertRaises(ValueError):
                m.identity_for_profile(Path('keychain'), profile())

    def test_cleanup_restores_keychains_and_preserves_existing_profile(self):
        m = load()
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            return b'"original.keychain-db"\n' if args[:2] == ('security', 'list-keychains') and '-s' not in args else b''
        with tempfile.TemporaryDirectory() as root, patch.object(m, 'run', side_effect=command):
            profiles = Path(root) / 'profiles'
            profiles.mkdir()
            with self.assertRaisesRegex(RuntimeError, 'archive failed'):
                with m.signing_material(b'p12', 'password', b'profile', 'fixture-profile', profiles):
                    self.assertTrue((profiles / 'fixture-profile.mobileprovision').exists())
                    raise RuntimeError('archive failed')
            self.assertFalse((profiles / 'fixture-profile.mobileprovision').exists())
            self.assertTrue(any(c[:2] == ('security', 'delete-keychain') for c in calls))
            self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', 'original.keychain-db'), calls)
            existing = profiles / 'fixture-profile.mobileprovision'
            existing.write_bytes(b'existing')
            with self.assertRaises(FileExistsError):
                with m.signing_material(b'p12', 'password', b'profile', 'fixture-profile', profiles):
                    pass
            self.assertEqual(existing.read_bytes(), b'existing')

    def test_export_verifies_embedded_profile_certificate_entitlements_and_signature(self):
        m = load()
        import hashlib
        p = profile()
        fingerprint = hashlib.sha1(b'certificate').hexdigest().upper()
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Fixture.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.App'}))
            (app / 'embedded.mobileprovision').write_bytes(b'cms')
            entitlements = dict(p['Entitlements'], **{'application-identifier': 'TESTTEAM.com.example.App'})
            calls = []
            def command(*args, **kwargs):
                calls.append(args)
                if args[:2] == ('security', 'cms'):
                    return plistlib.dumps(p)
                if '--entitlements' in args:
                    return plistlib.dumps(entitlements)
                for arg in args:
                    if str(arg).startswith('--extract-certificates='):
                        Path(str(arg).split('=', 1)[1] + '0').write_bytes(b'certificate')
                return b''
            with patch.object(m, 'run', side_effect=command):
                m.verify_app(app, 'com.example.App', 'TESTTEAM', fingerprint, 'synthetic-device')
                self.assertTrue(any(c[:2] == ('codesign', '--verify') for c in calls))
                with self.assertRaises(ValueError):
                    m.verify_app(app, 'com.example.App', 'TESTTEAM', fingerprint, 'synthetic-device', 'wrong-uuid')
                with self.assertRaises(ValueError):
                    m.verify_app(app, 'com.example.App', 'TESTTEAM', fingerprint, 'unregistered-device')
                entitlements['keychain-access-groups'] = ['OTHERTEAM.private']
                with self.assertRaises(ValueError):
                    m.verify_app(app, 'com.example.App', 'TESTTEAM', fingerprint, 'synthetic-device')
                del entitlements['keychain-access-groups']
                entitlements['get-task-allow'] = True
                with self.assertRaises(ValueError):
                    m.verify_app(app, 'com.example.App', 'TESTTEAM', fingerprint, 'synthetic-device')


    def test_import_failure_still_restores_and_deletes_keychain(self):
        m = load()
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('security', 'import'):
                raise RuntimeError('import failed')
            return b'"original.keychain-db"' if args[:2] == ('security', 'list-keychains') and '-s' not in args else b''
        with tempfile.TemporaryDirectory() as root, patch.object(m, 'run', side_effect=command):
            with self.assertRaises(RuntimeError):
                with m.signing_material(b'p12', 'password', b'profile', 'fixture-profile', Path(root)):
                    self.fail('Must not reach signing')
            self.assertTrue(any(c[:2] == ('security', 'delete-keychain') for c in calls))
            self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', 'original.keychain-db'), calls)



    def test_full_wildcard_and_authorized_private_keychain_group(self):
        m = load()
        p = profile()
        p['Entitlements']['application-identifier'] = 'TESTTEAM.*'
        p['Entitlements']['keychain-access-groups'] = ['TESTTEAM.*']
        self.assertEqual(m.validate_profile(p, 'com.example.App', 'synthetic-device'),
                         ('TESTTEAM', 'fixture-profile'))
        m.validate_entitlements({'keychain-access-groups': ['TESTTEAM.com.example.App.private']}, p['Entitlements'])
        for signed in [{'keychain-access-groups': ['OTHERTEAM.private']},
                       {'keychain-access-groups': ['TESTTEAM.*']},
                       {'unexpected-capability': True}]:
            with self.subTest(signed=signed), self.assertRaises(ValueError):
                m.validate_entitlements(signed, p['Entitlements'])

    def test_actual_codesign_certificate_extraction_syntax(self):
        import sys
        if sys.platform != 'darwin':
            self.skipTest('Requires the system codesign tool')
        m = load()
        with tempfile.TemporaryDirectory() as root:
            certificate = m.extract_certificate(Path('/usr/bin/true'), Path(root) / 'leaf')
            self.assertGreater(len(certificate), 100)


class ExtensionTests(unittest.TestCase):
    def test_pair_requires_same_team_certificate_and_shared_device(self):
        m = load()
        app, extension = profile(), profile()
        m.validate_pair(app, extension, 'com.example.App', None)
        extension['ProvisionedDevices'] = ['different-device']
        with self.assertRaises(ValueError):
            m.validate_pair(app, extension, 'com.example.App', None)
        extension = profile()
        extension['DeveloperCertificates'] = [b'other-certificate']
        with self.assertRaises(ValueError):
            m.validate_pair(app, extension, 'com.example.App', None)
        extension = profile()
        extension['TeamIdentifier'] = ['OTHERTEAM']
        extension['Entitlements']['com.apple.developer.team-identifier'] = 'OTHERTEAM'
        with self.assertRaises(ValueError):
            m.validate_pair(app, extension, 'com.example.App', None)

    def test_extension_profile_is_cleaned_up_on_failure_without_overwriting(self):
        m = load()
        with tempfile.TemporaryDirectory() as root:
            profiles = Path(root)
            with self.assertRaises(RuntimeError):
                with m.installed_profile(b'extension', 'extension-profile', profiles):
                    self.assertEqual((profiles / 'extension-profile.mobileprovision').read_bytes(), b'extension')
                    raise RuntimeError('archive failed')
            self.assertFalse(list(profiles.iterdir()))
            existing = profiles / 'extension-profile.mobileprovision'
            existing.write_bytes(b'keep')
            with self.assertRaises(FileExistsError):
                with m.installed_profile(b'extension', 'extension-profile', profiles):
                    pass
            self.assertEqual(existing.read_bytes(), b'keep')

    def test_archive_export_and_verification_cover_both_bundles(self):
        import base64
        import hashlib
        import json
        import os
        import zipfile
        m = load()
        app_profile, extension = profile(), profile()
        extension['UUID'] = 'extension-profile'
        calls, options = [], {}
        fingerprint = hashlib.sha1(b'certificate').hexdigest().upper()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def command(*args, **kwargs):
                calls.append(args)
                if '-showBuildSettings' in args:
                    return json.dumps([{'buildSettings': {'WRAPPER_EXTENSION': 'app',
                                        'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.App'}}]).encode()
                if args[:2] == ('security', 'cms'):
                    return plistlib.dumps(extension if 'extension' in Path(args[-1]).name else app_profile)
                if args[:2] == ('security', 'find-identity'):
                    return f'1) {fingerprint} "Apple Distribution: Fixture"'.encode()
                if '-exportArchive' in args:
                    options.update(plistlib.loads(Path(args[args.index('-exportOptionsPlist') + 1]).read_bytes()))
                    exported = Path(args[args.index('-exportPath') + 1])
                    exported.mkdir()
                    with zipfile.ZipFile(exported / 'Fixture.ipa', 'w') as ipa:
                        ipa.writestr('Payload/Fixture.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'com.example.App'}))
                        ipa.writestr('Payload/Fixture.app/PlugIns/Activity.appex/Info.plist', b'fixture')
                if args[0] == 'ditto':
                    with zipfile.ZipFile(args[-2]) as ipa:
                        ipa.extractall(args[-1])
                return b''
            env = {'IOS_CERTIFICATE_P12_BASE64': base64.b64encode(b'p12').decode(),
                   'IOS_CERTIFICATE_PASSWORD': 'fixture-password',
                   'IOS_PROFILE_BASE64': base64.b64encode(b'app-profile').decode(),
                   'IOS_ACTIVITY_PROFILE_BASE64': base64.b64encode(b'extension-profile').decode()}
            with patch.dict(os.environ, env), patch.object(m, 'run', side_effect=command), \
                    patch.object(m.Path, 'home', return_value=root), patch.object(m, 'verify_app') as verify:
                m.build('Fixture.xcodeproj', 'Fixture', root / 'output')
            self.assertTrue((root / 'output/Cochlea.ipa').is_file())
            self.assertEqual(options['provisioningProfiles'],
                             {'com.example.App': 'fixture-profile', 'com.example.App.activity': 'extension-profile'})
            archive = next(c for c in calls if 'archive' in c)
            self.assertIn('IOS_APP_PROFILE=fixture-profile', archive)
            self.assertIn('IOS_ACTIVITY_PROFILE=extension-profile', archive)
            self.assertEqual([c.args[1] for c in verify.call_args_list],
                             ['com.example.App', 'com.example.App.activity'])
            self.assertFalse(list(root.rglob('*.mobileprovision')))

if __name__ == '__main__':
    unittest.main()
