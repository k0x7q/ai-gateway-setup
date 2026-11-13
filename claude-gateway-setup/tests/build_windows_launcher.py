"""Generate the UTF-8/CRLF root launcher. Keep every result visible until a keypress."""
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTICE = '$ErrorActionPreference = \'Stop\'\n$text = \'{"code":"BOOT-PACKAGE-001","stage":"package-preflight","reason":"安装包不完整，请完整解压后重新运行。","state":"unchanged","installation":"not-started","PATHstate":"unchanged"}\'\nWrite-Host $text\n$form = $null\ntry {\n    Add-Type -AssemblyName System.Windows.Forms\n    $form = New-Object System.Windows.Forms.Form\n    $form.Text = \'安装配置诊断\'; $form.Width = 680; $form.Height = 280; $form.StartPosition = \'CenterScreen\'\n    $box = New-Object System.Windows.Forms.TextBox\n    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = \'Both\'; $box.SetBounds(16,16,630,170); $box.Text = $text\n    [void]$form.Controls.Add($box)\n    $copy = New-Object System.Windows.Forms.Button; $copy.Text = \'可复制诊断信息\'; $copy.SetBounds(330,200,165,32)\n    $copy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($box.Text) } catch { [void][System.Windows.Forms.MessageBox]::Show(\'复制失败，可选中文本后按 Ctrl+C。\') } })\n    [void]$form.Controls.Add($copy)\n    $close = New-Object System.Windows.Forms.Button; $close.Text = \'关闭\'; $close.SetBounds(510,200,130,32); $close.DialogResult = \'Cancel\'\n    [void]$form.Controls.Add($close); $form.CancelButton = $close\n    [void]$form.ShowDialog()\n} catch { Write-Host (\'Diagnostic window error: type=\' + $_.Exception.GetType().FullName + \'; HResult=\' + $_.Exception.HResult) }\nfinally { if ($null -ne $form) { $form.Dispose() } }\n'

def launcher_text():
    encoded = base64.b64encode(NOTICE.encode('utf-16-le')).decode('ascii')
    lines = ['@echo off', 'chcp 65001 >nul', 'setlocal EnableExtensions DisableDelayedExpansion', 'title Claude Code Setup', 'set "PS=%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"', 'if not exist "%PS%" goto missing_powershell', 'if not exist "%~dp0辅助文件\\Setup.ps1" goto missing_package', 'if not exist "%~dp0辅助文件\\configure.cjs" goto missing_package', 'if not exist "%~dp0辅助文件\\dialogs.cjs" goto missing_package', 'if not exist "%~dp0辅助文件\\key-dialog.ps1" goto missing_package', '"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0辅助文件\\Setup.ps1"', 'set "SETUP_EXIT=%ERRORLEVEL%"', 'goto done', ':missing_package', '"%PS%" -NoLogo -NoProfile -STA -EncodedCommand {encoded}', 'set "SETUP_EXIT=2"', 'goto done', ':missing_powershell', 'echo code=BOOT-POWERSHELL-001 stage=bootstrap reason=Windows PowerShell was not found.', 'echo state=unchanged installation=not-started PATHstate=unchanged', 'echo Please copy this diagnostic before closing the window.', 'set "SETUP_EXIT=3"', ':done', 'echo.', 'echo 流程已结束，请查看上方结果。', 'echo 按任意键关闭此窗口 . . .', 'pause >nul', 'exit /b %SETUP_EXIT%', '']
    return '\r\n'.join(line.replace('{encoded}', encoded) for line in lines)

if __name__ == '__main__':
    target = ROOT / 'windows' / '双击此文件安装配置 Claude Code.cmd'
    target.write_bytes(launcher_text().encode('utf-8'))
    print('Generated UTF-8 CMD with CRLF, code-page setup and helper-folder checks.')
