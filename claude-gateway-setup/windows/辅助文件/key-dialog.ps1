param([ValidateSet('choice','secret')][string]$Mode)

# Standalone Windows PowerShell 5.1 helper. Stdout is reserved for one JSON result.
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$script:result = @{ action = 'cancel' }
$script:enteredSecret = $null
$form = $null
$box = $null
$font = $null
$json = '{"action":"error","diagnostic":{"code":"DIALOG_SERIALIZE","stage":"key-dialog","reason":"无法编码弹窗结果"}}'
function ConvertTo-DialogJsonString {
    param([string]$Value)
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 34) { [void]$builder.Append('\"') }
        elseif ($code -eq 92) { [void]$builder.Append('\\') }
        elseif ($code -lt 32 -or $code -gt 126) { [void]$builder.Append('\u' + $code.ToString('x4')) }
        else { [void]$builder.Append($character) }
    }
    return '"' + $builder.ToString() + '"'
}
function Get-DialogDiagnostic {
    param($Record)
    $exception = $Record.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $reason = $exception.Message
    $values = @($script:enteredSecret)
    if ($null -ne $box) { $values += $box.Text }
    foreach ($value in $values) {
        if ($value -isnot [string] -or $value.Length -eq 0) { continue }
        foreach ($secret in @($value, $value.Trim())) {
            if ($secret.Length -eq 0) { continue }
            $reason = $reason.Replace($secret, '[REDACTED]')
            $encoded = ConvertTo-DialogJsonString $secret
            $reason = $reason.Replace($encoded.Substring(1, $encoded.Length - 2), '[REDACTED]')
        }
    }
    $reason = [regex]::Replace($reason, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '?')
    return @{ action = 'error'; diagnostic = @{
        code = 'DIALOG_FAILED'; stage = 'key-dialog'; reason = $reason
        type = $exception.GetType().FullName; HResult = $exception.HResult
    } }
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Claude 网关设置'
    $form.Font = $font
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $true

    if ($Mode -eq 'choice') {
        $form.ClientSize = New-Object System.Drawing.Size(520, 180)
        $label = New-Object System.Windows.Forms.Label
        $label.SetBounds(20, 20, 480, 72)
        $label.Text = '检测到已有网关密钥，是否使用？'
        [void]$form.Controls.Add($label)

        $replace = New-Object System.Windows.Forms.Button
        $replace.Text = '输入新密钥'
        $replace.SetBounds(100, 118, 125, 36)
        $replace.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $replace.TabIndex = 1
        [void]$form.Controls.Add($replace)

        $keep = New-Object System.Windows.Forms.Button
        $keep.Text = '使用现有密钥'
        $keep.SetBounds(237, 118, 125, 36)
        $keep.DialogResult = [System.Windows.Forms.DialogResult]::No
        $keep.TabIndex = 0
        [void]$form.Controls.Add($keep)
        $form.AcceptButton = $keep
        $form.ActiveControl = $keep

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = '取消'
        $cancel.TabIndex = 2
        $cancel.SetBounds(374, 118, 125, 36)
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$form.Controls.Add($cancel)
        $form.CancelButton = $cancel

        $answer = $form.ShowDialog()
        if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
            $script:result = @{ action = 'keep' }
        } elseif ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:result = @{ action = 'replace' }
        }
    } elseif ($Mode -eq 'secret') {
        $form.ClientSize = New-Object System.Drawing.Size(520, 200)
        $label = New-Object System.Windows.Forms.Label
        $label.SetBounds(20, 18, 480, 56)
        $label.Text = '请输入网关密钥'
        [void]$form.Controls.Add($label)

        $box = New-Object System.Windows.Forms.TextBox
        $box.SetBounds(20, 80, 480, 30)
        $box.UseSystemPasswordChar = $false
        $box.ShortcutsEnabled = $true
        # Do not silently truncate pasted input; validate the complete value on OK.
        $box.MaxLength = 0
        $box.TabIndex = 0
        [void]$form.Controls.Add($box)
        $form.ActiveControl = $box

        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = '确定'
        $ok.SetBounds(238, 144, 125, 36)
        $ok.TabIndex = 1
        # No DialogResult until validation succeeds, so invalid input stays open.
        $ok.Add_Click({
            $candidate = $null
            try {
                $script:enteredSecret = $box.Text
                $candidate = $script:enteredSecret.Trim()
                if ($candidate.Length -eq 0 -or $candidate.Length -gt 8192 -or
                    [regex]::IsMatch($candidate, '[\s\p{Cc}]')) {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        $form,
                        '密钥须为 1 至 8192 个字符，不能包含空白或控制字符。',
                        '输入无效',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                    [void]$box.Focus()
                    return
                }
                $script:result = @{ action = 'set'; token = $candidate }
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            } catch {
                # WinForms event exceptions must not escape to an error dialog/log.
                $script:result = Get-DialogDiagnostic $_
                $form.DialogResult = [System.Windows.Forms.DialogResult]::Abort
            } finally {
                $candidate = $null
            }
        })
        [void]$form.Controls.Add($ok)
        $form.AcceptButton = $ok

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = '取消'
        $cancel.SetBounds(375, 144, 125, 36)
        $cancel.TabIndex = 2
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        [void]$form.Controls.Add($cancel)
        $form.CancelButton = $cancel

        $answer = $form.ShowDialog()
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK -and
            $script:result.action -ne 'error') {
            $script:result = @{ action = 'cancel' }
        }
    } else {
        $script:result = @{ action = 'error'; diagnostic = @{ code = 'DIALOG_MODE'; stage = 'key-dialog'; reason = '未知窗口模式' } }
    }
} catch {
    # Never emit exception details, file contents, or keys on any error stream.
    $script:result = Get-DialogDiagnostic $_
} finally {
    try {
        if ($null -ne $box) { $box.Clear() }
    } catch { $script:result = Get-DialogDiagnostic $_ }
    try {
        if ($null -ne $form) { $form.Dispose() }
    } catch { $script:result = Get-DialogDiagnostic $_ }
    try {
        if ($null -ne $font) { $font.Dispose() }
    } catch { $script:result = Get-DialogDiagnostic $_ }
}

try {
    $json = ConvertTo-Json -InputObject $script:result -Compress -Depth 3
} catch {
    $failure = (Get-DialogDiagnostic $_).diagnostic
    $json = '{"action":"error","diagnostic":{"code":"DIALOG_SERIALIZE","stage":"key-dialog","reason":' + (ConvertTo-DialogJsonString $failure.reason) + ',"type":' + (ConvertTo-DialogJsonString $failure.type) + ',"HResult":' + $failure.HResult.ToString([Globalization.CultureInfo]::InvariantCulture) + '}}'
}
try {
    [Console]::Write($json)
} catch {
    # No second output path may receive a key when the private stdout pipe breaks.
    [Environment]::ExitCode = 1
} finally {
    $json = $null
    $script:result = $null
    $script:enteredSecret = $null
    $box = $null
    $form = $null
    $font = $null
}
