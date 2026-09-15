#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
import json
import io
import os
from pathlib import Path
import runpy
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
release = runpy.run_path(str(ROOT/'scripts/build-release'))
EXPECTED = {'bundleName': 'org.thunderbird.harmony.dev', 'versionName': '0.1.11',
            'versionCode': 100011, 'vendor': 'D-Mail contributors'}


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='dmail-release-test-')
        self.root = Path(self.scratch.name)
        self.addCleanup(self.scratch.cleanup)

    def generate(self, public):
        scripts = self.root/'scripts'; scripts.mkdir(exist_ok=True)
        shutil.copy2(ROOT/'scripts/generate-google-oauth-registration', scripts/'generate-google-oauth-registration')
        output = self.root/'.tools/generated/LocalGoogleOAuth.swift'
        subprocess.run(['python3', str(scripts/'generate-google-oauth-registration'), '--output', str(output)],
                       env={**os.environ, 'DMAIL_PUBLIC_RELEASE': '1' if public else '0'}, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return output

    def test_public_build_never_reads_local_registration(self):
        private = self.root/'.tools/oauth/google-desktop.json'; private.parent.mkdir(parents=True)
        private.write_text('deliberately invalid JSON: public build must not read this')
        output = self.generate(True)
        self.assertEqual(output.read_text(), release['NIL_REGISTRATION'])
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(private.read_text(), 'deliberately invalid JSON: public build must not read this')

    def test_ordinary_device_build_retains_local_registration(self):
        private = self.root/'.tools/oauth/google-desktop.json'; private.parent.mkdir(parents=True)
        private.write_text(json.dumps({'installed': {
            'client_id': '883149639454-r1c1m28d0tatqkcn2b55qes9aossu5p6.apps.googleusercontent.com',
            'client_secret': 'synthetic-local-only', 'token_uri': 'https://oauth2.googleapis.com/token'}}))
        self.assertIn('synthetic-local-only', self.generate(False).read_text())

    def hap(self, *, debug=False, machine=183, secret=b''):
        path = self.root/'synthetic.hap'
        metadata = {**EXPECTED, 'debug': debug, 'buildMode': 'debug' if debug else 'release',
                    'minAPIVersion': 60002022, 'targetAPIVersion': 60002022}
        elf = bytearray(64); elf[:6] = b'\x7fELF\x02\x01'; struct.pack_into('<H', elf, 18, machine)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('module.json', json.dumps({'app': metadata}))
            archive.writestr('pack.info', json.dumps({'synthetic': True}))
            archive.writestr('ets/modules.abc', b'synthetic-arkts')
            archive.writestr('resources/rawfile/legal/LICENSE', b'synthetic-license')
            for name in ['libThunderbirdCore.so', 'libthunderbird.so']:
                archive.writestr('libs/arm64-v8a/'+name, bytes(elf)+secret)
        return path

    def test_inspection_accepts_release_metadata_and_records_libraries(self):
        metadata, libraries = release['inspect_hap'](self.hap(), 'arm64-v8a', 183, EXPECTED)
        self.assertFalse(metadata['debug'])
        self.assertEqual(set(libraries), {'libThunderbirdCore.so', 'libthunderbird.so'})
        self.assertTrue(all(len(digest) == 64 for digest in libraries.values()))

    def test_rejects_debug_build(self):
        with self.assertRaisesRegex(ValueError, 'non-debug release'):
            release['inspect_hap'](self.hap(debug=True), 'arm64-v8a', 183, EXPECTED)

    def test_rejects_wrong_architecture(self):
        with self.assertRaisesRegex(ValueError, 'architecture'):
            release['inspect_hap'](self.hap(machine=62), 'arm64-v8a', 183, EXPECTED)

    def test_rejects_embedded_google_secret(self):
        with self.assertRaisesRegex(ValueError, 'Credential material'):
            release['inspect_hap'](self.hap(secret=b'GOCSPX-synthetic-test-only'), 'arm64-v8a', 183, EXPECTED)

    def test_public_policy_refuses_browser_login_opt_in(self):
        policy = self.root/'harmony/entry/src/main/ets/mail/oauth/RegisteredMailOAuth.ets'
        policy.parent.mkdir(parents=True)
        policy.write_text('static readonly googleBrowserSignInEnabled: boolean = true;')
        with self.assertRaisesRegex(ValueError, 'default Google'):
            release['require_public_policy'](self.root)
        release['require_public_policy'](ROOT)

    def test_store_identity_changes_only_staged_manifest(self):
        staged = self.root/'stage'; manifest = staged/'AppScope/app.json5'
        manifest.parent.mkdir(parents=True)
        original = (ROOT/'harmony/AppScope/app.json5').read_bytes()
        manifest.write_bytes(original)
        release['appgallery_identity'](ROOT, staged)
        actual = json.loads(manifest.read_text())['app']
        self.assertEqual(actual['bundleName'], 'some.DMail.hamorny')
        self.assertEqual(actual['versionCode'], json.loads(original)['app']['versionCode'])
        self.assertEqual(actual['versionName'], json.loads(original)['app']['versionName'])
        self.assertEqual((ROOT/'harmony/AppScope/app.json5').read_bytes(), original)

    def test_app_checks_embedded_hap_and_identity(self):
        hap = self.hap(); app = self.root/'synthetic.app'
        def write(bundle_id, content):
            with zipfile.ZipFile(app, 'w') as archive:
                archive.writestr('entry-default.hap', content)
                archive.writestr('pack.info', json.dumps({'summary': {'app': {
                    'bundleName': bundle_id, 'version': {'code': 100011, 'name': '0.1.11'}}}}))
        write(EXPECTED['bundleName'], hap.read_bytes())
        release['inspect_app'](app, hap, EXPECTED)
        repacked = io.BytesIO()
        with zipfile.ZipFile(hap) as original, zipfile.ZipFile(repacked, 'w') as target:
            for name in original.namelist():
                data = original.read(name)
                if name == 'pack.info':
                    data = json.dumps(json.loads(data), indent=2).encode()
                target.writestr(name, data)
        write(EXPECTED['bundleName'], repacked.getvalue())
        release['inspect_app'](app, hap, EXPECTED)
        write('wrong.bundle.id', hap.read_bytes())
        with self.assertRaisesRegex(ValueError, 'identity/version'):
            release['inspect_app'](app, hap, EXPECTED)
        write(EXPECTED['bundleName'], b'stale-hap')
        with self.assertRaisesRegex(ValueError, 'verified release HAP'):
            release['inspect_app'](app, hap, EXPECTED)


if __name__ == '__main__':
    unittest.main()
