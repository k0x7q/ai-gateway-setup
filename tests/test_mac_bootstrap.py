"""Offline integration tests for the rendered stock-Bash macOS bootstrap.

Only the test fixture replaces hardcoded executable paths with local stubs.
Release download URLs, executables and checksums cannot be overridden; the API gateway is a runtime parameter.
Run: python3 -m unittest discover -s tests -p test_mac_bootstrap.py -v
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "bootstrap" / "setup-mac.sh.in"
ASSETS = {
    "claude-mac-setup.rb": b"# fixture Claude setup\n",
    "claude-mac-configure.cjs": b"// fixture configure\n",
    "claude-mac-dialogs.cjs": b"// fixture dialogs\n",
    "codex-mac-codex_setup.rb": b"# fixture Codex setup\n",
}


class MacBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mac bootstrap tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tmp = self.root / "temporary files with spaces"
        self.tmp.mkdir()
        self.marker = self.tmp / "do-not-delete.txt"
        self.marker.write_text("unrelated user data", encoding="utf-8")
        self.asset_dir = self.root / "assets"
        self.asset_dir.mkdir()
        for name, data in ASSETS.items():
            (self.asset_dir / name).write_bytes(data)
        self.fetch_log = self.root / "fetch.jsonl"
        self.ruby_log = self.root / "ruby.json"
        self.mode = self.root / "mode.json"
        self.mode.write_text("{}", encoding="utf-8")
        self.stub_uname = self.stub("uname", "print('Darwin')\n")
        self.stub_curl = self.stub("curl", f"""
import json, pathlib, sys
root = pathlib.Path({str(self.root)!r})
args = sys.argv[1:]
url = args[-1]
asset = url.rsplit('/', 1)[-1]
with (root / 'fetch.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\\n')
mode = json.loads((root / 'mode.json').read_text())
if mode.get('fetch_fail') == asset:
    sys.exit(22)
data = (root / 'assets' / asset).read_bytes()
if mode.get('corrupt') == asset:
    data += b'corrupted'
pathlib.Path(args[args.index('--output') + 1]).write_bytes(data)
""")
        self.stub_hash = self.stub("shasum", """
import hashlib, pathlib, sys
assert sys.argv[1:3] == ['-a', '256']
print(hashlib.sha256(pathlib.Path(sys.argv[3]).read_bytes()).hexdigest() + '  ' + sys.argv[3])
""")
        self.stub_ruby = self.stub("ruby", f"""
import json, os, pathlib, signal, sys
root = pathlib.Path({str(self.root)!r})
helper = pathlib.Path(sys.argv[1])
files = {{p.name: p.read_text() for p in helper.parent.iterdir()}}
(root / 'ruby.json').write_text(json.dumps({{
    'helper': str(helper), 'files': files, 'path': os.environ['PATH'], 'gateway': os.environ['AI_GATEWAY_URL'],
    'mode': helper.parent.parent.stat().st_mode & 0o777
}}))
mode = json.loads((root / 'mode.json').read_text())
if mode.get('signal'):
    os.kill(os.getppid(), signal.SIGTERM)
sys.exit(mode.get('child_exit', 0))
""")
        self.script = TEMPLATE.read_text(encoding="utf-8")
        self.script = self.script.replace("@@VERSION@@", "v1.2.3")
        entries = "\n".join(
            f'    {name}) expected="{hashlib.sha256(data).hexdigest()}" ;;'
            for name, data in ASSETS.items()
        )
        self.script = self.script.replace("@@HASHES@@", entries)
        for executable, stub in (
            ("/usr/bin/uname", self.stub_uname),
            ("/usr/bin/curl", self.stub_curl),
            ("/usr/bin/shasum", self.stub_hash),
            ("/usr/bin/ruby", self.stub_ruby),
        ):
            # Paths are shell quoted even though fixture directory has spaces.
            self.script = self.script.replace(executable, shlex.quote(str(stub)))

    def stub(self, name, body):
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n" + body.lstrip(), encoding="utf-8")
        path.chmod(0o700)
        return path

    def run_bootstrap(self, *args, input_text=None, **mode):
        self.mode.write_text(json.dumps(mode), encoding="utf-8")
        env = os.environ.copy()
        env['AI_GATEWAY_URL'] = 'https://gateway.example.com'
        env["TMPDIR"] = str(self.tmp)
        env["HOME"] = str(self.root / "home with spaces")
        # Match the production in-memory entry: bash -c downloaded-text.
        result = subprocess.run(
            ["/bin/bash", "-c", self.script, "setup-mac", *args],
            input=input_text, text=True, capture_output=True, env=env, timeout=15,
        )
        self.assertEqual(list(self.tmp.iterdir()), [self.marker], result.stderr)
        self.assertEqual(self.marker.read_text(), "unrelated user data")
        return result

    def fetched(self):
        if not self.fetch_log.exists():
            return []
        return [json.loads(line) for line in self.fetch_log.read_text().splitlines()]

    def test_claude_success_all_siblings_private_and_https(self):
        result = self.run_bootstrap("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.ruby_log.read_text())
        self.assertEqual(Path(record["helper"]).name, "setup.rb")
        self.assertEqual(set(record["files"]), {"setup.rb", "configure.cjs", "dialogs.cjs"})
        self.assertEqual(record["mode"], 0o700)
        self.assertTrue(record["path"].startswith(
            f"/opt/homebrew/bin:/usr/local/bin:{self.root}/home with spaces/.local/bin:"
        ))
        requests = self.fetched()
        self.assertEqual(len(requests), 3)
        for args in requests:
            self.assertTrue(args[-1].startswith(
                "https://github.com/k0x7q/ai-gateway-setup/releases/download/v1.2.3/"
            ))
            self.assertEqual(args[args.index("--proto") + 1], "=https")
            self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
            for option in ("--max-time", "--connect-timeout", "--retry", "--retry-max-time"):
                self.assertIn(option, args)
        self.assertIn("临时脚本已清理", result.stdout)
        self.assertNotIn("配置成功", result.stdout)
        self.assertNotIn("安装成功", result.stdout)

    def test_codex_menu_success_only_one_file(self):
        result = self.run_bootstrap(input_text="2\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.fetched()), 1)
        record = json.loads(self.ruby_log.read_text())
        self.assertEqual(set(record["files"]), {"codex_setup.rb"})
        self.assertIn("仅配置", result.stdout)

    def test_cancel_argument_and_menu_do_not_download_or_execute(self):
        for args, text in ((["cancel"], None), ([], "0\n")):
            with self.subTest(args=args):
                result = self.run_bootstrap(*args, input_text=text)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("已取消", result.stdout)
                self.assertFalse(self.fetch_log.exists())
                self.assertFalse(self.ruby_log.exists())

    def test_last_claude_hash_mismatch_never_executes_ruby(self):
        result = self.run_bootstrap("claude", corrupt="claude-mac-dialogs.cjs")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertEqual(len(self.fetched()), 3)
        self.assertFalse(self.ruby_log.exists())

    def test_fetch_failure_never_executes_ruby(self):
        result = self.run_bootstrap("codex", fetch_fail="codex-mac-codex_setup.rb")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("下载失败", result.stderr)
        self.assertFalse(self.ruby_log.exists())

    def test_child_nonzero_preserved_and_cleaned(self):
        result = self.run_bootstrap("codex", child_exit=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertTrue(self.ruby_log.exists())
        self.assertIn("退出码 23", result.stderr)
        self.assertNotIn("临时脚本已清理", result.stdout)

    def test_sigterm_cleans_owned_directory_and_preserves_signal_status(self):
        result = self.run_bootstrap("codex", signal=True)
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertTrue(self.ruby_log.exists())
        self.assertIn("退出码 143", result.stderr)

    def test_non_darwin_refused_before_download(self):
        self.stub_uname.write_text(f"#!{sys.executable}\nprint('Linux')\n", encoding="utf-8")
        result = self.run_bootstrap("claude")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("仅支持 macOS", result.stderr)
        self.assertFalse(self.fetch_log.exists())
        self.assertFalse(self.ruby_log.exists())

    def test_invalid_choice_refused_before_download(self):
        result = self.run_bootstrap("not-a-product")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.fetch_log.exists())

    def test_gateway_argument_reaches_helper_and_overrides_environment(self):
        result = self.run_bootstrap('--gateway', 'https://other.example.com:8443/', 'codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.ruby_log.read_text())['gateway'], 'https://other.example.com:8443')

    def test_missing_and_invalid_gateway_refused_before_download(self):
        for gateway in ('', 'http://gateway.example.com', 'https://user@gateway.example.com',
                        'https://gateway.example.com/v1', 'https://gateway.example.com?x=1',
                        'https://gateway.example.com#fragment', 'https://gateway.example.com:0',
                        'https://gateway.example.com:65536', 'https://gateway.example.com\n'):
            with self.subTest(gateway=gateway):
                result = self.run_bootstrap('claude', '--gateway', gateway)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.fetch_log.exists())
                self.assertFalse(self.ruby_log.exists())

    def test_unrendered_template_fails_closed(self):
        self.script = TEMPLATE.read_text(encoding="utf-8").replace(
            "/usr/bin/uname", shlex.quote(str(self.stub_uname))
        )
        result = self.run_bootstrap("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.fetch_log.exists())
        self.assertFalse(self.ruby_log.exists())


if __name__ == "__main__":
    unittest.main()
