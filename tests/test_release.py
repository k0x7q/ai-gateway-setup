"""Release builder tests: no installation, real profile or network access."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_builder', ROOT / 'tools/build_release.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ReleaseTests(unittest.TestCase):
    def test_assets_exact_bytes_and_hashes_and_encoding(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp).resolve()
            manifest = builder.build('v1.2.3', out)
            self.assertEqual(len(manifest['sha256']), 12)
            self.assertEqual(set(p.name for p in out.iterdir()),
                             set(builder.ASSETS) | {'setup-mac.sh', 'setup-windows.ps1', 'manifest.json', 'SHA256SUMS'})
            for asset, relative in builder.ASSETS.items():
                self.assertEqual((out / asset).read_bytes(), (ROOT / relative).read_bytes())
            for asset, digest in manifest['sha256'].items():
                self.assertEqual(hashlib.sha256((out / asset).read_bytes()).hexdigest(), digest)
            for asset in ('setup-mac.sh', 'setup-windows.ps1'):
                text = (out / asset).read_text(encoding='utf-8-sig')
                self.assertNotIn('@@', text)
                self.assertIn('v1.2.3', text)
                for source, digest in manifest['sha256'].items():
                    if source in builder.ASSETS and ('-mac-' in source) == asset.endswith('.sh'):
                        self.assertIn(digest, text)
            win = (out / 'setup-windows.ps1').read_bytes()
            self.assertTrue(win.startswith(b'\xef\xbb\xbf'))
            self.assertNotIn(b'\n', win.replace(b'\r\n', b''))
            self.assertEqual(json.loads((out / 'manifest.json').read_text()), manifest)
            first = {p.name: p.read_bytes() for p in out.iterdir()}
            builder.build('v1.2.3', out)
            self.assertEqual(first, {p.name: p.read_bytes() for p in out.iterdir()})

    def test_unsafe_version_rejected(self):
        for version in ('latest', '../v1', 'v1.0', 'v1.0.0;echo bad', 'v1.0.0\n'):
            with self.assertRaises(ValueError):
                builder.build(version)

    def test_linked_output_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'actual').mkdir()
            try:
                (root / 'linked').symlink_to(root / 'actual', target_is_directory=True)
            except OSError:
                self.skipTest('Symlink permission unavailable')
            with self.assertRaises(ValueError):
                builder.build('v1.0.0', root / 'linked')


if __name__ == '__main__':
    unittest.main()
