"""Mock GitHub API: prove failed uploads never publish an incomplete release."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publisher', ROOT / 'tools/publish_release.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'setup-mac.sh').write_bytes(b'fixture script, never execute')
        manifest = {'version': 'v1.2.3', 'repository': publisher.REPO,
                    'sha256': {'setup-mac.sh': hashlib.sha256((self.root / 'setup-mac.sh').read_bytes()).hexdigest()}}
        (self.root / 'manifest.json').write_text(json.dumps(manifest))
        (self.root / 'SHA256SUMS').write_text('fixture')
        self.calls = []
        self.existing = False
        self.upload_fail = False
        self.endpoint = 'https://uploads.github.com/repos/k0x7q/ai-gateway-setup/releases/42/assets{?name,label}'

    def fake_request(self, url, token, method='GET', data=None, content_type='application/json'):
        self.calls.append((method, url, data))
        self.assertEqual(token, 'test-only-not-a-real-token')
        if method == 'GET':
            if self.existing:
                return {'id': 42}
            raise urllib.error.HTTPError(url, 404, 'Not found', {}, None)
        if method == 'POST' and url == publisher.API + '/releases':
            self.assertTrue(json.loads(data)['draft'])
            return {'id': 42, 'upload_url': self.endpoint}
        if method == 'POST':
            if self.upload_fail:
                raise urllib.error.HTTPError(url, 500, 'Fixture upload failed', {}, None)
            return {'state': 'uploaded', 'size': len(data)}
        self.assertEqual(method, 'PATCH')
        self.assertFalse(json.loads(data)['draft'])
        return {'html_url': 'https://github.com/' + publisher.REPO + '/releases/tag/v1.2.3'}

    def run_publish(self):
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'test-only-not-a-real-token'}), \
             patch.object(publisher, 'request', self.fake_request):
            publisher.publish('v1.2.3', self.root)

    def test_publish_after_all_uploads_only(self):
        self.run_publish()
        self.assertEqual([item[0] for item in self.calls], ['GET', 'POST', 'POST', 'POST', 'POST', 'PATCH'])

    def test_upload_failure_leaves_draft(self):
        self.upload_fail = True
        with self.assertRaises(urllib.error.HTTPError):
            self.run_publish()
        self.assertNotIn('PATCH', [item[0] for item in self.calls])

    def test_existing_release_never_overwritten(self):
        self.existing = True
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertEqual([item[0] for item in self.calls], ['GET'])

    def test_bad_checksum_prevents_any_api_calls(self):
        (self.root / 'setup-mac.sh').write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertEqual(self.calls, [])

    def test_untrusted_upload_endpoint_never_receives_token(self):
        self.endpoint = 'https://example.invalid/assets'
        with self.assertRaises(ValueError):
            self.run_publish()
        self.assertEqual([item[0] for item in self.calls], ['GET', 'POST'])


if __name__ == '__main__':
    unittest.main()
