$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'ConfigCore.ps1')

function Show-Diagnostic([string]$Text) {
    $form=New-Object Windows.Forms.Form
    $form.Text='Codex 设置诊断'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(640,330); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $box=New-Object Windows.Forms.TextBox; $box.SetBounds(18,18,604,245); $box.Multiline=$true; $box.ReadOnly=$true; $box.ScrollBars='Vertical'; $box.Text=$Text; $form.Controls.Add($box)
    $copy=New-Object Windows.Forms.Button; $copy.Text='复制诊断信息'; $copy.SetBounds(398,282,108,30)
    $copy.Add_Click({
        try { [Windows.Forms.Clipboard]::SetText($box.Text); $copy.Text='已复制' }
        catch { $copy.Text='复制失败'; $box.Focus(); $box.SelectAll() }
    }); $form.Controls.Add($copy)
    $close=New-Object Windows.Forms.Button; $close.Text='关闭'; $close.SetBounds(518,282,104,30); $close.DialogResult=[Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($close); $form.CancelButton=$close
    [void]$form.ShowDialog(); $form.Dispose()
}
function Find-CodexApp {
    $paths=@()
    if ($env:LOCALAPPDATA) { $paths += (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe') }
    if ($env:ProgramFiles) { $paths += (Join-Path $env:ProgramFiles 'Codex\Codex.exe') }
    if (${env:ProgramFiles(x86)}) { $paths += (Join-Path ${env:ProgramFiles(x86)} 'Codex\Codex.exe') }
    foreach ($p in $paths) { if ([IO.File]::Exists($p)) { return [pscustomobject]@{ Type='exe'; Target=$p } } }
    try {
        if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
            $app=Get-StartApps | Where-Object { $_.Name -ceq 'Codex' } | Select-Object -First 1
            if ($app -and $app.AppID) { return [pscustomobject]@{ Type='app'; Target=$app.AppID } }
        }
    } catch { }
    return $null
}
function Is-CodexRunning {
    return @((Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)).Count -gt 0
}
function Wait-CodexClosed {
    while (Is-CodexRunning) {
        $r=[Windows.Forms.MessageBox]::Show('检测到 Codex 正在运行。请保存工作并自行关闭 Codex，然后点击重试。本工具不会强制结束进程。','请关闭 Codex',[Windows.Forms.MessageBoxButtons]::RetryCancel,[Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [Windows.Forms.DialogResult]::Retry) { return $false }
    }
    return $true
}
function Choose-App {
    while ($true) {
        $app=Find-CodexApp
        if ($null -ne $app) { return [pscustomobject]@{ Continue=$true; App=$app } }
        $form=New-Object Windows.Forms.Form
        $form.Text='未检测到 Codex'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(460,145); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
        $label=New-Object Windows.Forms.Label; $label.SetBounds(18,16,424,52)
        $label.Text='未检测到 Codex。可以继续配置，之后自行打开应用。本工具不安装软件。'; $form.Controls.Add($label)
        $retry=New-Object Windows.Forms.Button; $retry.Text='重新检测'; $retry.SetBounds(18,92,125,32); $retry.DialogResult=[Windows.Forms.DialogResult]::Retry; $form.Controls.Add($retry)
        $proceed=New-Object Windows.Forms.Button; $proceed.Text='继续配置'; $proceed.SetBounds(158,92,135,32); $proceed.DialogResult=[Windows.Forms.DialogResult]::Yes; $form.Controls.Add($proceed)
        $cancel=New-Object Windows.Forms.Button; $cancel.Text='取消'; $cancel.SetBounds(308,92,134,32); $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($cancel); $form.CancelButton=$cancel
        $answer=$form.ShowDialog(); $form.Dispose()
        if ($answer -eq [Windows.Forms.DialogResult]::Retry) { continue }
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { return [pscustomobject]@{ Continue=$true; App=$null } }
        return [pscustomobject]@{ Continue=$false; App=$null }
    }
}
function Ask-Key {
    $form=New-Object Windows.Forms.Form
    $form.Text='请输入网关密钥'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(480,160); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $label=New-Object Windows.Forms.Label; $label.SetBounds(18,15,440,30); $label.Text='请输入网关密钥'; $form.Controls.Add($label)
    $box=New-Object Windows.Forms.TextBox; $box.SetBounds(18,57,440,25); $form.Controls.Add($box)
    $ok=New-Object Windows.Forms.Button; $ok.Text='确定'; $ok.SetBounds(255,105,95,30); $ok.DialogResult=[Windows.Forms.DialogResult]::OK; $form.Controls.Add($ok); $form.AcceptButton=$ok
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='取消'; $cancel.SetBounds(362,105,95,30); $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($cancel); $form.CancelButton=$cancel
    $form.Add_Shown({ [void]$box.Focus() })
    $answer=$form.ShowDialog(); $value=if ($answer -eq [Windows.Forms.DialogResult]::OK) { $box.Text } else { $null }; $box.Text=''; $form.Dispose()
    return $value
}
function Ask-ExistingKey {
    # This dialog receives no key and must never display the existing value.
    $form=New-Object Windows.Forms.Form
    $form.Text='网关密钥'; $form.StartPosition='CenterScreen'; $form.ClientSize=New-Object Drawing.Size(460,140); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $label=New-Object Windows.Forms.Label; $label.SetBounds(18,18,424,40); $label.Text='检测到已有网关密钥，是否使用？'; $form.Controls.Add($label)
    $reuse=New-Object Windows.Forms.Button; $reuse.Text='使用现有密钥'; $reuse.SetBounds(18,88,135,32); $reuse.DialogResult=[Windows.Forms.DialogResult]::Yes; $form.Controls.Add($reuse)
    $replace=New-Object Windows.Forms.Button; $replace.Text='输入新密钥'; $replace.SetBounds(164,88,135,32); $replace.DialogResult=[Windows.Forms.DialogResult]::No; $form.Controls.Add($replace)
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='取消'; $cancel.SetBounds(310,88,132,32); $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($cancel); $form.CancelButton=$cancel
    $answer=$form.ShowDialog(); $form.Dispose()
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) { return 'reuse' }
    if ($answer -eq [Windows.Forms.DialogResult]::No) { return 'new' }
    return 'cancel'
}
function Select-GatewayKey([string]$ExistingKey) {
    if ([string]::IsNullOrWhiteSpace($ExistingKey)) { return (Ask-Key) }
    $answer=Ask-ExistingKey
    if ($answer -eq 'reuse') { return $ExistingKey }
    if ($answer -eq 'new') { return (Ask-Key) }
    return $null
}
function Test-Gateway([string]$Key) {
    $response=$null
    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $request=[Net.HttpWebRequest]::Create((ConvertTo-GatewayOrigin)+'/v1/models')
        $request.Method='GET'; $request.AllowAutoRedirect=$false; $request.Timeout=15000; $request.ReadWriteTimeout=15000
        $request.Headers[[Net.HttpRequestHeader]::Authorization]='Bearer '+$Key
        $response=$request.GetResponse()
        return (Get-GatewayResult -StatusCode ([int]$response.StatusCode))
    } catch {
        $failure=$_.Exception; $cause=$failure
        while ($null -ne $cause -and $cause -isnot [Net.WebException]) { $cause=$cause.InnerException }
        if ($null -ne $cause) {
            $response=$cause.Response
            if ($response -is [Net.HttpWebResponse]) { return (Get-GatewayResult -StatusCode ([int]$response.StatusCode) -Exception $failure) }
            return (Get-GatewayResult -TransportStatus $cause.Status.ToString() -Exception $failure)
        }
        return (Get-GatewayResult -Exception $failure)
    } finally { if ($null -ne $response) { $response.Dispose() } }
}
function Get-ConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $configDirectory=$env:CODEX_HOME
        if (-not [IO.Path]::IsPathRooted($configDirectory) -or $configDirectory -notmatch '^[A-Za-z]:\\') { throw 'Invalid or network CODEX_HOME' }
        $configDirectory=[IO.Path]::GetFullPath($configDirectory)
    } else {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE) -or $env:USERPROFILE -notmatch '^[A-Za-z]:\\') { throw 'Invalid USERPROFILE' }
        $configDirectory=Join-Path $env:USERPROFILE '.codex'
    }
    $drive=New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($configDirectory))
    if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Unsupported network configuration drive' }
    Assert-NoReparseAncestors $configDirectory
    return (Join-Path $configDirectory 'config.toml')
}
$stage='setup'; $saveState=New-SaveState; $key=$null
try {
    $env:AI_GATEWAY_URL=ConvertTo-GatewayOrigin
    $stage='app-check'
    $choice=Choose-App; if (-not $choice.Continue) { return }
    $stage='app-check'
    if (-not (Wait-CodexClosed)) { return }
    $stage='path'
    $path=Get-ConfigPath; $exists=[IO.File]::Exists($path); $original=[byte[]]@(); $text=''; $hadBom=$false
    $stage='read'
    if ($exists) {
        if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsupported config link' }
        $original=[IO.File]::ReadAllBytes($path)
        $utf8=New-Object System.Text.UTF8Encoding($false,$true); $text=$utf8.GetString($original)
        if ($text.StartsWith([string][char]0xfeff)) { $hadBom=$true; $text=$text.Substring(1) }
    }
    $stage='parse'; $parsed=Read-SafeToml $text
    $stage='key'; $key=Select-GatewayKey (Get-ExistingKey $parsed)
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $stage='build'; $result=Build-Config $parsed $key
    if ($hadBom) { $result=([string][char]0xfeff)+$result }
    $stage='app-check'
    if (-not (Wait-CodexClosed)) { return }
    $stage='save'; Save-ConfigAtomic $path $original $exists $result $saveState
    $stage='verify'
    $progress=New-Object Windows.Forms.Form
    $progress.Text='验证网关'; $progress.StartPosition='CenterScreen'; $progress.ClientSize=New-Object Drawing.Size(310,75); $progress.FormBorderStyle='FixedDialog'; $progress.ControlBox=$false
    $progressLabel=New-Object Windows.Forms.Label; $progressLabel.SetBounds(18,20,274,35); $progressLabel.Text='正在验证网关…'; $progress.Controls.Add($progressLabel)
    $progress.Show(); $progress.Refresh(); [Windows.Forms.Application]::DoEvents()
    try { $verified=Test-Gateway $key } finally { $progress.Close(); $progress.Dispose() }
    if (-not $verified.Success) {
        Show-Diagnostic (Get-SetupDiagnostic $verified.Exception $stage $saveState $verified.Reason $verified.Code $key); return
    }
    $stage='launch'
    if (-not $choice.App) { throw 'Codex application not found' }
    if (Is-CodexRunning) { throw 'Codex started during setup' }
    if ($choice.App.Type -eq 'exe') { Start-Process -FilePath $choice.App.Target -ErrorAction Stop }
    else { Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\'+$choice.App.Target) -ErrorAction Stop }
    # Success requires no acknowledgment: request application launch and return.
} catch { Show-Diagnostic (Get-SetupDiagnostic $_.Exception $stage $saveState -Key $key) }
finally { $key=$null }
