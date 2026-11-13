"""Mac launcher PTY regression: stub Ruby helper, no GUI/install/profile changes."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = '双击此文件安装配置 Claude Code.command'
PROMPT = '流程已结束，可以关闭此终端窗口。'.encode()


class MacTerminalTests(unittest.TestCase):
    def setUp(self):
        base = Path(tempfile.gettempdir()).resolve()
        self.temporary = tempfile.TemporaryDirectory(prefix='claude-mac-terminal-', dir=base)
        self.temp = Path(self.temporary.name)
        self.assertEqual(self.temp.resolve(), self.temp)
        self.assertEqual(self.temp.parent, base)
        self.assertTrue(self.temp.name.startswith('claude-mac-terminal-'))
        self.addCleanup(self.temporary.cleanup)
        self.folder = self.temp / '中文 路径 & spaces'
        self.folder.mkdir()
        (self.folder / '辅助文件').mkdir()
        self.launcher = self.folder / LAUNCHER
        self.launcher.write_bytes((ROOT / 'mac' / LAUNCHER).read_bytes())

    def helper(self, code):
        # Only the launcher is real; dependency/configuration operations never run.
        (self.folder / '辅助文件/setup.rb').write_text(
            'STDOUT.sync = true\nSTDERR.sync = true\n'
            'puts "配置完成。请在项目目录打开新终端，运行 claude。"\n'
            'warn "必要警告-fixture"\n'
            f'exit {code}\n', encoding='utf-8')

    def read_until(self, master, output, marker):
        deadline = time.monotonic() + 5
        while marker not in output:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, output.decode(errors='replace'))
            ready, _, _ = select.select([master], [], [], remaining)
            self.assertTrue(ready, 'terminal output timed out')
            chunk = os.read(master, 65536)
            self.assertTrue(chunk, 'terminal closed before result')
            output.extend(chunk)

    def test_interactive_result_waits_even_after_enter_and_preserves_warning(self):
        for code in (0, 7):
            with self.subTest(code=code):
                self.helper(code)
                master, slave = pty.openpty()
                proc = subprocess.Popen(['/bin/bash', str(self.launcher)], stdin=slave,
                                        stdout=slave, stderr=slave)
                os.close(slave)
                output = bytearray()
                try:
                    self.read_until(master, output, PROMPT)
                    self.assertTrue(output.startswith(b'\x1b[2J\x1b[H'))
                    self.assertNotIn(b'\x1b[3J', output)  # Do not erase scrollback.
                    self.assertIn('必要警告-fixture'.encode(), output)
                    self.assertIn('配置完成。'.encode(), output)
                    self.assertIsNone(proc.poll(), 'launcher exited instead of holding result')
                    os.write(master, b'\n')
                    select.select([master], [], [], 0.1)
                    self.assertIsNone(proc.poll(), 'Enter must not trigger shell exit logs')
                    # EOF is an explicit escape hatch; it preserves the helper exit code.
                    os.write(master, b'\x04')
                    self.assertEqual(proc.wait(timeout=3), code)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                        proc.wait(timeout=3)
                    os.close(master)

    def test_redirected_run_never_clears_or_waits_and_keeps_exit_code(self):
        for code in (0, 7):
            with self.subTest(code=code):
                self.helper(code)
                result = subprocess.run(['/bin/bash', str(self.launcher)], input='',
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, code)
                self.assertNotIn('\x1b', result.stdout)
                self.assertNotIn(PROMPT.decode(), result.stdout)
                self.assertIn('配置完成。', result.stdout)
                self.assertIn('必要警告-fixture', result.stderr)


if __name__ == '__main__':
    unittest.main()
