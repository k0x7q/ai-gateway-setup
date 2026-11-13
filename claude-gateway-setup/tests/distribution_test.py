"""Isolated distribution integration. No GUI, network, installer or real profile use."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KEY = 'distribution-fixture-key-"\\-not-real'
RUBY = r'''
require ARGV.fetch(0)
raise 'HOME isolation failed' unless Dir.home == ENV.fetch('HOME')
ENV.delete('CLAUDE_CONFIG_DIR')
ENV.delete('ZDOTDIR')
FAKE_KEY = JSON.parse(STDIN.read)
module ClaudeInstaller
  def supported_platform?; true; end
  def executable(name)
    return ENV.fetch('TEST_NODE_PATH') if name == 'node'
    return ENV.fetch('TEST_CLAUDE_PATH') if name == 'claude'
    raise 'Unexpected executable lookup'
  end
  def node_ready?
    raise 'Cancellation reached dependency check' if ENV['TEST_MODE'] == 'cancel'
    true
  end
  def native(script)
    return '关闭' if script.include?('复制诊断信息')
    raise Cancelled if ENV['TEST_MODE'] == 'cancel'
    return '使用现有密钥' if script.include?('检测到已有网关密钥')
    return FAKE_KEY if script.include?('请输入网关密钥')
    raise 'Unexpected GUI or installation confirmation'
  end
  def install_node; raise 'Real installation forbidden'; end
  def install_claude(*); raise 'Real installation forbidden'; end
  alias_method :real_persist_user_bin, :persist_user_bin
  def persist_user_bin(claude)
    raise Failure.new('simulated isolated PATH failure', 'MAC_TEST_PATH') if ENV['TEST_MODE'] == 'path-failure'
    real_persist_user_bin(claude)
  end
  module_function :supported_platform?, :executable, :node_ready?, :native,
                  :install_node, :install_claude, :persist_user_bin, :real_persist_user_bin
end
exit ClaudeInstaller.main
'''
# Ruby code and fake input both travel over stdin, not command-line credential arguments.
RUNNER = "source = STDIN.read; eval(source, TOPLEVEL_BINDING, 'isolated-runner');"

class DistributionTests(unittest.TestCase):
    def setUp(self):
        base = Path(tempfile.gettempdir()).resolve()
        self.temporary = tempfile.TemporaryDirectory(prefix='claude-distribution-test-', dir=base)
        self.temp = Path(self.temporary.name)
        self.assertEqual(self.temp.resolve(), self.temp)
        self.assertEqual(self.temp.parent, base)
        self.assertTrue(self.temp.name.startswith('claude-distribution-test-'))
        self.addCleanup(self.temporary.cleanup)
        self.folder = self.temp / '中文 路径 & spaces'
        self.folder.mkdir()
        self.home = self.temp / 'isolated-home'
        self.home.mkdir()
        self.node = shutil.which('node')
        self.assertIsNotNone(self.node)
        self.claude = self.temp / 'fake-claude'
        self.claude.write_text('#!/bin/sh\nprintf "Claude fixture version\\n"\n')
        self.claude.chmod(0o700)
        self.env = {**os.environ, 'AI_GATEWAY_URL': 'https://gateway.example.com', 'HOME': str(self.home), 'TEST_NODE_PATH': self.node, 'TEST_CLAUDE_PATH': str(self.claude)}
        self.env.pop('CLAUDE_CONFIG_DIR', None)
        self.env.pop('ZDOTDIR', None)

    def extract(self, platform):
        prefix = 'ClaudeCode网关配置-' + platform
        with zipfile.ZipFile(ROOT / (prefix + '.zip')) as archive:
            for name in archive.namelist():
                self.assertTrue(name.startswith(prefix + '/'))
                self.assertNotIn('..', Path(name).parts)
                self.assertFalse(Path(name).is_absolute())
            archive.extractall(self.folder)
        return self.folder / prefix

    def run_flow(self, extracted, mode='normal'):
        # Feed a single complete Ruby program. The test key is embedded only in stdin.
        script = RUBY.replace('FAKE_KEY = JSON.parse(STDIN.read)', 'FAKE_KEY = ' + json.dumps(KEY, ensure_ascii=False))
        result = subprocess.run(['/usr/bin/ruby', '-', str(extracted / '辅助文件/setup.rb')],
                                input=script, text=True, capture_output=True,
                                env={**self.env, 'TEST_MODE': mode}, timeout=15)
        self.assertNotIn(KEY, result.stdout + result.stderr)
        self.assertNotIn(json.dumps(KEY)[1:-1], result.stdout + result.stderr)
        return result

    def test_mac_archive_shared_real_pipeline_and_safe_profile_idempotence(self):
        extracted = self.extract('Mac')
        first = self.run_flow(extracted)
        self.assertEqual(first.returncode, 0, first.stderr)
        target = self.home / '.claude/settings.json'
        settings = json.loads(target.read_text())
        self.assertEqual(settings['env']['ANTHROPIC_AUTH_TOKEN'], KEY)
        self.assertEqual(settings['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'claude-haiku-5-5')
        for key in ('ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_FABLE_MODEL'):
            self.assertEqual(settings['env'][key], 'claude-sonnet-5-5')
        self.assertNotIn('ANTHROPIC_MODEL', settings['env'])
        self.assertNotIn('CLAUDE_CODE_SUBAGENT_MODEL', settings['env'])
        self.assertIn('未验证网关密钥或模型', first.stdout)
        self.assertIn('配置完成。请在项目目录打开新终端，运行 claude。', first.stdout)
        original = {str(p.relative_to(self.home)): p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        second = self.run_flow(extracted)
        self.assertEqual(second.returncode, 0, second.stderr)
        after = {str(p.relative_to(self.home)): p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        self.assertEqual(after, original)
        self.assertIn('Claude company gateway PATH', (self.home / '.zshrc').read_text())

    def test_mac_key_cancel_is_zero_side_effects(self):
        result = self.run_flow(self.extract('Mac'), 'cancel')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertNotIn('配置未完成', result.stderr)

    def test_mac_real_shared_save_then_path_failure_reports_saved(self):
        result = self.run_flow(self.extract('Mac'), 'path-failure')
        self.assertEqual(result.returncode, 1)
        self.assertIn('配置保存：saved', result.stderr)
        self.assertIn('simulated isolated PATH failure', result.stderr)
        self.assertEqual(json.loads((self.home / '.claude/settings.json').read_text())['env']['ANTHROPIC_AUTH_TOKEN'], KEY)

    def test_mac_root_launcher_resolves_helper_with_chinese_spaces(self):
        extracted = self.extract('Mac')
        startup = extracted / '双击此文件安装配置 Claude Code.command'
        self.assertEqual(startup.read_bytes(), (ROOT / 'mac' / startup.name).read_bytes())
        self.assertIn('流程已结束，可以关闭此终端窗口。', startup.read_text())
        helper = extracted / '辅助文件/setup.rb'
        helper.write_text("puts File.basename(__dir__)\nexit 7\n")
        result = subprocess.run(['/bin/bash', str(extracted / '双击此文件安装配置 Claude Code.command')],
                                text=True, capture_output=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout.strip(), '辅助文件')
        self.assertEqual(list(self.home.iterdir()), [])

    def test_windows_archive_flat_helper_resolution_and_source_metadata(self):
        extracted = self.extract('Windows')
        startup = extracted / '双击此文件安装配置 Claude Code.cmd'
        batch = startup.read_bytes().decode('utf-8')
        self.assertTrue(batch.startswith('@echo off\r\nchcp 65001 >nul\r\n'))
        self.assertIn('-File "%~dp0辅助文件\\Setup.ps1"', batch)
        self.assertEqual(startup.read_bytes(), (ROOT / 'windows' / startup.name).read_bytes())
        self.assertIn('echo 按任意键关闭此窗口 . . .\r\npause >nul\r\nexit /b %SETUP_EXIT%', batch)
        self.assertIn('$common = $PSScriptRoot', (extracted / '辅助文件/Setup.ps1').read_text(encoding='utf-8-sig'))
        for name in ('configure.cjs', 'dialogs.cjs', 'key-dialog.ps1'):
            self.assertEqual((extracted / '辅助文件' / name).read_bytes(), (ROOT / 'common' / name).read_bytes())
        for name in ('Setup.ps1', 'key-dialog.ps1'):
            data = (extracted / '辅助文件' / name).read_bytes()
            self.assertTrue(data.startswith(b'\xef\xbb\xbf'))
            self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
        self.assertEqual({p.name for p in extracted.iterdir()}, {'辅助文件', startup.name})

if __name__ == '__main__':
    unittest.main()
