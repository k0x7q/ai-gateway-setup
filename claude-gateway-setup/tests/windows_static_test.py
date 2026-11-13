"""Static regression checks only; NOT native PowerShell syntax/runtime validation."""
import base64
import json
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WindowsStaticTests(unittest.TestCase):
    def setUp(self):
        self.ps_bytes = (ROOT / 'windows/辅助文件/Setup.ps1').read_bytes()
        self.ps = self.ps_bytes.decode('utf-8-sig')
        self.cmd_bytes = (ROOT / 'windows/双击此文件安装配置 Claude Code.cmd').read_bytes()
        self.cmd = self.cmd_bytes.decode('utf-8')
        self.dialog_bytes = (ROOT / 'common/key-dialog.ps1').read_bytes()
        self.dialog = self.dialog_bytes.decode('utf-8-sig')

    def test_source_encoding(self):
        for source in (self.ps_bytes, self.dialog_bytes):
            self.assertTrue(source.startswith(b'\xef\xbb\xbf'))
            self.assertNotIn(b'\n', source.replace(b'\r\n', b''))
        self.assertFalse(self.cmd_bytes.startswith(b'\xef\xbb\xbf'))
        self.assertNotIn(b'\n', self.cmd_bytes.replace(b'\r\n', b''))

    def test_launcher_private_and_waits_before_exit(self):
        self.assertIn('DisableDelayedExpansion', self.cmd)
        self.assertIn('-STA', self.cmd)
        self.assertIn('set "SETUP_EXIT=%ERRORLEVEL%"', self.cmd)
        self.assertIn('exit /b %SETUP_EXIT%', self.cmd)
        from build_windows_launcher import launcher_text
        self.assertEqual(self.cmd, launcher_text())
        done = self.cmd.split('\r\n:done\r\n', 1)[1]
        self.assertIn('echo 流程已结束，请查看上方结果。', done)
        self.assertIn('echo 按任意键关闭此窗口 . . .', done)
        self.assertIn('pause >nul\r\nexit /b %SETUP_EXIT%', done)
        self.assertEqual(len(re.findall(r'(?im)^\s*pause\b', self.cmd)), 1)
        self.assertNotIn('SETUP_EXIT=', done)
        self.assertNotIn('配置完成', done)  # Exit code 0 also covers user cancellation.
        self.assertIn('set "SETUP_EXIT=2"\r\ngoto done', self.cmd)
        self.assertIn('set "SETUP_EXIT=3"\r\n:done', self.cmd)
        self.assertNotRegex(self.cmd, r'(?im)^\s*call\b')
        self.assertLess(self.cmd.index('chcp 65001 >nul'), self.cmd.index('辅助文件'))
        for name in ('configure.cjs', 'dialogs.cjs', 'key-dialog.ps1'):
            self.assertLess(self.cmd.index('if not exist "%~dp0辅助文件\\' + name), self.cmd.index('-File "%~dp0辅助文件\\Setup.ps1"'))
        notices = re.findall(r'-EncodedCommand ([A-Za-z0-9+/=]+)', self.cmd)
        for notice in notices:
            text = base64.b64decode(notice).decode('utf-16-le')
            self.assertNotIn('技术支持', text)
            self.assertNotIn('pause', text.lower())

    def test_preflight_and_choice_before_install(self):
        main = self.ps.split('function Invoke-ClaudeGatewaySetup {', 1)[1]
        for earlier, later in [('Test-PackageIntegrity', 'Get-NativeConfigPreflight'), ('Get-NativeConfigPreflight', 'Select-GatewayToken'), ('Select-GatewayToken', 'Install-NodeLts'), ('Select-GatewayToken', 'Ensure-GitBash'), ('Select-GatewayToken', 'New-Item'), ('Select-GatewayToken', "SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH'")]:
            self.assertLess(main.index(earlier), main.index(later))
        self.assertIn("if ($selection.action -eq 'cancel') { $script:SetupExitCode = 0; return }", main)
        self.assertIn('Confirm-DependencyInstall', main)
        self.assertNotIn('Read-Host', self.ps)

    def test_private_prepared_protocol(self):
        for required in ('ProcessStartInfo', 'RedirectStandardInput', 'RedirectStandardOutput', 'RedirectStandardError', 'ReadToEndAsync()', 'StandardInput.Write', 'StandardInput.Close', '--prepared-stdin', 'expectedDigest', 'ConvertTo-Json'):
            self.assertIn(required, self.ps)
        self.assertLess(self.ps.index('ReadToEndAsync()'), self.ps.index('StandardInput.Write'))
        self.assertNotIn('& $runtime.Node $configure', self.ps)
        self.assertNotIn('--token', self.ps)
        self.assertNotRegex(self.ps, r'(?i)(ArgumentList|Arguments|SetEnvironmentVariable)\s*[^\n]*\$token')
        self.assertIn('CONFIG_PROTOCOL', self.ps)
        self.assertIn("$script:ConfigState = 'unknown'", self.ps)

    def test_native_preflight_guards(self):
        for required in ('CLAUDE_CONFIG_DIR', "'.claude'", "'settings.json'", '2097152', 'UTF8Encoding($false, $true)', 'ReparsePoint', 'NumberOfLinks', 'FileShare]::Read', 'SHA256', 'StringComparer.Ordinal', 'DUPLICATE_KEY', 'UNSAFE_NUMBER', '9007199254740991', 'CONFIG_ROOT', 'CONFIG_ENV', 'CONFIG_PATH', 'CONFIG_UTF8', 'CONFIG_CHANGED', 'depth > 128'):
            self.assertIn(required, self.ps)
        self.assertNotIn('ConvertFrom-Json -InputObject $text', self.ps)
        self.assertIn("-ceq (ConvertTo-GatewayOrigin)", self.ps)
        self.assertIn("ContainsKey('ANTHROPIC_AUTH_TOKEN')", self.ps)

    def test_key_dialog_compatibility_and_copy(self):
        self.assertIn("ValidateSet('choice','secret')", self.dialog)
        self.assertIn("$label.Text = '请输入网关密钥'", self.dialog)
        self.assertIn("$label.Text = '检测到已有网关密钥，是否使用？'", self.dialog)
        self.assertIn("$keep.Text = '使用现有密钥'", self.dialog)
        self.assertIn("$replace.Text = '输入新密钥'", self.dialog)
        self.assertIn('$box.UseSystemPasswordChar = $false', self.dialog)
        self.assertIn('$box.MaxLength = 0', self.dialog)
        for action in ('keep', 'replace', 'cancel', 'set', 'error'):
            self.assertIn("action = '" + action + "'", self.dialog)
        for field in ('diagnostic', 'HResult', 'type'):
            self.assertIn(field, self.dialog)
        self.assertIn('$reason = $exception.Message', self.dialog)
        self.assertIn("$reason.Replace($secret, '[REDACTED]')", self.dialog)

    def test_installer_and_identity_safety_retained(self):
        for required in ('https://nodejs.org/dist/', 'SHASUMS256.txt', 'Get-AuthenticodeSignature', 'SignerCertificate', '-Verb RunAs', "'/passive'", 'Git.Git --exact --source winget', '--accept-source-agreements --accept-package-agreements --silent --disable-interactivity', '--registry=https://registry.npmjs.org', '--allow-scripts=@anthropic-ai/claude-code', '--engine-strict', 'GNU bash', r'\(Claude Code\)', 'claude.ps1.disabled-', 'Rename-Item -LiteralPath $shim -NewName $disabledName'):
            self.assertIn(required, self.ps)
        self.assertIn('if ($resolvedPrefix -ine $expected)', self.ps)
        self.assertIn('GetDirectoryName($backup)', self.ps)
        self.assertNotIn('Set-ExecutionPolicy', self.ps)
        self.assertNotIn('setx ', self.ps)
        self.assertIn("SetEnvironmentVariable('Path', $updated, 'User')", self.ps)
        self.assertIn('$remaining += $entry', self.ps)

    def test_diagnostics_and_exact_success(self):
        for required in ('Show-SetupDiagnostic', 'Protect-DiagnosticText', '复制诊断信息', '关闭', 'installation', 'PATHstate', 'ConfigState', 'HResult', 'stderr', 'exitCode', 'reason', 'stage', 'type'):
            self.assertIn(required, self.ps)
        self.assertIn('配置完成。请在项目目录打开新终端，运行 claude。', self.ps)
        self.assertNotRegex(self.ps, r'&\s*\$claude\.Path\s*(?:\r?\n|$)')
        for forbidden in ('技术支持', '随包说明', '为保护密钥', '未输出敏感配置'):
            self.assertNotIn(forbidden, self.ps + self.dialog + self.cmd)

    def test_state_and_redaction_are_fieldwise(self):
        self.assertIn('ConvertTo-SafeExternalDiagnostic', self.ps)
        self.assertIn("'^[A-Z0-9_-]{1,80}$'", self.ps)
        self.assertIn("@('unchanged','saving','saved','unknown')", self.ps)
        self.assertIn('$text = ConvertTo-Json -InputObject $diagnostic -Depth 8', self.ps)
        self.assertNotIn('Protect-DiagnosticText (ConvertTo-Json -InputObject $diagnostic', self.ps)
        for field in ('OriginalMachinePath', 'OriginalUserPath', 'OriginalProcessPath', 'Get-CurrentPathState'):
            self.assertIn(field, self.ps)
        self.assertIn("$script:Installation.node = 'installed-unverified'", self.ps)
        self.assertIn("$script:Installation.git = 'installed-unverified'", self.ps)
        launch = self.ps.index('[void]$process.Start()')
        self.assertGreater(self.ps.index("if ($ConfigurationWrite) { $script:ConfigState = 'unknown' }"), launch)

    def test_existing_key_selection_fixtures(self):
        # Contract fixtures, not execution of the native PowerShell predicate.
        def existing(env):
            url, token = env.get('ANTHROPIC_BASE_URL'), env.get('ANTHROPIC_AUTH_TOKEN')
            return isinstance(url, str) and url == 'https://gateway.example.com' and isinstance(token, str) and bool(token.strip())
        for env, expected in [
            ({}, False),
            ({'ANTHROPIC_BASE_URL': 'https://gateway.example.com', 'ANTHROPIC_AUTH_TOKEN': 'old-fixture'}, True),
            ({'ANTHROPIC_BASE_URL': 'https://gateway.example.com/', 'ANTHROPIC_AUTH_TOKEN': 'old-fixture'}, False),
            ({'ANTHROPIC_BASE_URL': ['https://gateway.example.com'], 'ANTHROPIC_AUTH_TOKEN': 'old-fixture'}, False),
            ({'ANTHROPIC_BASE_URL': 'HTTPS://GATEWAY.EXAMPLE.COM', 'ANTHROPIC_AUTH_TOKEN': 'old-fixture'}, False),
            ({'ANTHROPIC_BASE_URL': 'https://gateway.example.com', 'ANTHROPIC_AUTH_TOKEN': '   '}, False),
            ({'ANTHROPIC_BASE_URL': 'https://gateway.example.com', 'ANTHROPIC_API_KEY': 'other-fixture'}, False),
        ]:
            with self.subTest(env=env):
                self.assertEqual(existing(env), expected)
        self.assertIn("$configEnv['ANTHROPIC_BASE_URL'] -is [string]", self.ps)
        self.assertIn("$configEnv['ANTHROPIC_AUTH_TOKEN'].Trim().Length -gt 0", self.ps)

    def test_fixture_contract_is_strict_and_case_sensitive(self):
        # These fixtures exercise the test oracle, NOT the embedded C# scanner on Windows.
        def strict_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError('duplicate')
                result[key] = value
            return result
        invalid = ['{"env":{},"env":{}}', '{"env":{"A":1,"\\u0041":2}}', '{"x":[{"a":0,"a":1}]}']
        for fixture in invalid:
            with self.subTest(fixture=fixture), self.assertRaises(ValueError):
                json.loads(fixture, object_pairs_hook=strict_pairs)
        valid = ['{}', '{"env":{"A":1,"a":2}}', '{"x":"中\\u6587","env":{}}']
        for fixture in valid:
            json.loads(fixture, object_pairs_hook=strict_pairs)
        for fixture in ('9007199254740992', '1e309', '-9007199254740992'):
            number = float(fixture)
            self.assertTrue(not number < float('inf') or abs(number) > 9007199254740991)
        with self.assertRaises(UnicodeDecodeError):
            b'{"x":"\xff"}'.decode('utf-8', errors='strict')

if __name__ == '__main__':
    unittest.main()
