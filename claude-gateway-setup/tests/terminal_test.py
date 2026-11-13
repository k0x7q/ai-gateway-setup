"""Real PTY input tests; no network or real user settings are used (macOS/Linux)."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'common' / 'configure.cjs'

class TerminalTests(unittest.TestCase):
    def run_input(self, payload, expected_code=0):
        with tempfile.TemporaryDirectory(prefix='claude-terminal-test-', dir=os.path.realpath(tempfile.gettempdir())) as directory:
            resolved = Path(directory).resolve()
            self.assertTrue(resolved.name.startswith('claude-terminal-test-'))
            self.assertEqual(resolved.parent, Path(tempfile.gettempdir()).resolve())
            environment = {k: v for k, v in os.environ.items() if not k.startswith('ANTHROPIC_')}
            environment['AI_GATEWAY_URL'] = 'https://gateway.example.com'
            environment['CLAUDE_CONFIG_DIR'] = str(resolved / 'config')
            master, slave = pty.openpty()
            proc = subprocess.Popen(['node', str(SCRIPT), '--terminal'], stdin=slave, stdout=slave, stderr=slave, env=environment)
            os.close(slave)
            output = bytearray()
            deadline = time.monotonic() + 8
            try:
                prompt = 'Ctrl+C 取消'.encode()
                while prompt not in output:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, 'prompt timed out')
                    ready, _, _ = select.select([master], [], [], remaining)
                    self.assertTrue(ready, 'prompt timed out')
                    output.extend(os.read(master, 65536))
                os.write(master, payload)
                while True:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, 'process timed out')
                    ready, _, _ = select.select([master], [], [], remaining)
                    if not ready:
                        self.fail('process timed out')
                    try:
                        chunk = os.read(master, 65536)
                        if not chunk:
                            break
                        output.extend(chunk)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                self.assertEqual(proc.wait(timeout=2), expected_code, output.decode(errors='replace'))
                self.assertNotIn(b'pty-test-key', output, 'secret leaked into terminal output')
                target = resolved / 'config' / 'settings.json'
                return json.loads(target.read_text()) if target.exists() else None
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                os.close(master)

    def test_normal_paste_is_hidden(self):
        settings = self.run_input(b'pty-test-key\r')
        self.assertEqual(settings['env']['ANTHROPIC_AUTH_TOKEN'], 'pty-test-key')

    def test_bracketed_paste_and_arrow_sequences(self):
        settings = self.run_input(b'\x1b[200~pty-test-key\x1b[201~\x1b[D\r')
        self.assertEqual(settings['env']['ANTHROPIC_AUTH_TOKEN'], 'pty-test-key')

    def test_split_escape_sequence(self):
        settings = self.run_input(b'\x1b[200~pty-test-key\x1b[201~\r')
        self.assertEqual(settings['env']['ANTHROPIC_AUTH_TOKEN'], 'pty-test-key')

    def test_multiline_bracketed_paste_is_refused(self):
        self.assertIsNone(self.run_input(b'\x1b[200~pty-test-key\nextra\x1b[201~\r', 1))

    def test_cancel_leaves_no_settings(self):
        self.assertIsNone(self.run_input(b'\x03', 0))

if __name__ == '__main__':
    unittest.main()
