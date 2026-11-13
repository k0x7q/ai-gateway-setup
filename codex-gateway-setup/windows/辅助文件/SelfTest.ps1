# Run on Windows PowerShell 5.1. Synthetic data only; files are created under this directory.
$ErrorActionPreference='Stop'
$env:AI_GATEWAY_URL='https://gateway.example.com'
. (Join-Path $PSScriptRoot 'ConfigCore.ps1')
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Reject([string]$Text) {
    $rejected=$false; try { [void](Read-SafeToml $Text) } catch { $rejected=$true }
    Assert-True $rejected 'Unsafe or unsupported TOML was accepted'
}
# Parse production scripts without running GUI, network or reading user configuration.
foreach ($scriptName in @('Setup.ps1','ConfigCore.ps1','SelfTest.ps1')) {
    $tokens=$null; $parseErrors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $scriptName),[ref]$tokens,[ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) 'Production script has a PowerShell syntax error'
}
$setupSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Setup.ps1'))
Assert-True ($setupSource -notmatch '\$home\b') 'Setup must not use the read-only HOME variable as a local variable'
foreach ($codePoint in @(0x2018,0x2019,0x201c,0x201d)) {
    Assert-True (-not $setupSource.Contains([string][char]$codePoint)) 'Setup must not contain smart quote characters'
}
# BOM is required for Chinese source on Windows PowerShell 5.1.
foreach ($scriptName in @('Setup.ps1','ConfigCore.ps1','SelfTest.ps1')) {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $scriptName))
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) 'PowerShell source must retain UTF-8 BOM'
}
# Inspect UI and run only the key-choice orchestration with synthetic dialog mocks.
$tokens=$null; $parseErrors=$null
$setupAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Setup.ps1'),[ref]$tokens,[ref]$parseErrors)
$definitions=@($setupAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))
$askKey=@($definitions | Where-Object { $_.Name -eq 'Ask-Key' })[0].Extent.Text
$askExisting=@($definitions | Where-Object { $_.Name -eq 'Ask-ExistingKey' })[0].Extent.Text
$selector=@($definitions | Where-Object { $_.Name -eq 'Select-GatewayKey' })[0].Extent.Text
Assert-True ($askKey.Contains("`$label.Text='请输入网关密钥'")) 'Key prompt must contain only the requested label'
Assert-True ($askKey -notmatch 'UseSystemPasswordChar|PasswordChar|隐藏|命令参数|网址') 'Key entry must be visible and concise'
foreach ($label in @('检测到已有网关密钥，是否使用？','使用现有密钥','输入新密钥','取消')) {
    Assert-True ($askExisting.Contains($label)) 'Existing-key dialog is missing a required choice'
}
Assert-True ($askExisting -notmatch '\$ExistingKey|\$Key\b|Get-ExistingKey') 'Existing-key dialog must not receive or render a secret'
Assert-True ($setupSource -notmatch '\$welcome|Show-Notice|Show-ErrorNotice|Stop-Process|taskkill|打开下载网站|为保护密钥，不显示详细错误') 'Removed confirmation, installer or forced-termination behavior reappeared'
Assert-True ($setupSource.Contains("`$copy.Text='复制诊断信息'") -and $setupSource.Contains("`$close.Text='关闭'")) 'Diagnostic buttons missing'
. ([scriptblock]::Create($selector))
$script:keyPrompts=0; $script:reusePrompts=0; $script:reuseAnswer='reuse'; $script:newKey='synthetic-new'
function Ask-Key { $script:keyPrompts++; return $script:newKey }
function Ask-ExistingKey { $script:reusePrompts++; return $script:reuseAnswer }
Assert-True ((Select-GatewayKey '') -ceq 'synthetic-new') 'No-key flow did not prompt for key'
Assert-True ($script:keyPrompts -eq 1 -and $script:reusePrompts -eq 0) 'No-key flow showed wrong dialogs'
Assert-True ((Select-GatewayKey 'synthetic-old') -ceq 'synthetic-old') 'Reuse choice changed existing key'
Assert-True ($script:keyPrompts -eq 1 -and $script:reusePrompts -eq 1) 'Reuse must ask once without showing input'
$script:reuseAnswer='new'
Assert-True ((Select-GatewayKey 'synthetic-old') -ceq 'synthetic-new') 'New-key choice did not prompt'
$script:reuseAnswer='cancel'
Assert-True ($null -eq (Select-GatewayKey 'synthetic-old')) 'Cancel returned a key'
Assert-True ($script:keyPrompts -eq 2 -and $script:reusePrompts -eq 3) 'Cancel opened an input dialog'
$script:newKey=$null
Assert-True ($null -eq (Select-GatewayKey '')) 'Input cancellation did not propagate'
# Maintainer diagnostics: numbered stage, concrete safe reason, state, no untrusted text.
foreach ($case in @(
    @('Unsupported TOML value','值类型'), @('Unsupported table path','表路径'),
    @('Unclosed or multiline string','未闭合'), @('Duplicate table','重复'),
    @('Invalid TOML escape','转义'), @('Unsupported TOML line ending','换行'),
    @('Unsupported directory link in configuration path','链接'), @('Unsupported network configuration drive','网络'),
    @('Invalid USERPROFILE','默认配置目录'), @('Configuration path component is not a directory','同名文件')
)) {
    $notice=Get-SetupDiagnostic (New-Object System.Exception($case[0])) 'parse' (New-SaveState)
    Assert-True ($notice.Contains($case[1]) -and $notice.Contains('W003') -and $notice.Contains('parse')) 'Wrong diagnostic reason or stage'
    Assert-True ($notice.Contains('未保存') -and $notice.Contains('权限未由本工具修改')) 'Pre-save state missing'
}
$secretText='synthetic-secret Authorization: Bearer synthetic-token experimental_bearer_token = "synthetic-config"'
foreach ($exception in @(
    (New-Object System.Exception($secretText)),
    (New-Object System.IO.IOException($secretText)),
    (New-Object System.UnauthorizedAccessException($secretText)),
    (New-Object System.Text.DecoderFallbackException($secretText)),
    (New-Object System.ArgumentException($secretText)),
    (New-Object System.ComponentModel.Win32Exception(5,$secretText)),
    (New-Object System.Exception($secretText,(New-Object System.Exception('Duplicate key or table conflict'))))
)) {
    foreach ($stage in @('path','read','parse','build','save','verify','launch','setup','app-check','key')) {
        $notice=Get-SetupDiagnostic $exception $stage (New-SaveState) -Key 'synthetic-secret'
        Assert-True ($notice -notmatch 'synthetic-secret|Authorization|synthetic-token|experimental_bearer_token|synthetic-config') 'Sensitive exception text leaked'
        Assert-True ($notice.Contains('异常：') -and $notice.Contains('HResult=')) 'Exception identity missing'
    }
}
$permissionNotice=Get-SetupDiagnostic (New-Object System.ComponentModel.Win32Exception(5,$secretText)) 'save' (New-SaveState)
Assert-True ($permissionNotice.Contains('Windows 错误 5')) 'Safe numeric OS error was lost'
$encodingNotice=Get-SetupDiagnostic (New-Object System.Text.DecoderFallbackException($secretText)) 'read' (New-SaveState)
Assert-True ($encodingNotice.Contains('UTF-8')) 'Encoding cause missing'
# Ordinary unknown errors remain concrete, while current keys and encoded variants are removed.
$ordinaryNotice=Get-SetupDiagnostic (New-Object System.Exception('Synthetic device is busy')) 'launch' (New-SaveState)
Assert-True ($ordinaryNotice.Contains('Synthetic device is busy')) 'Ordinary exception message was hidden'
$redactionKey='syn"thetic\secret'
$encodedKey=ConvertTo-TomlString $redactionKey
$encodedKey=$encodedKey.Substring(1,$encodedKey.Length-2)
$rawFailure=New-Object System.Exception(('Synthetic device is busy: '+$redactionKey+'; escaped: '+$encodedKey))
$redactedNotice=Get-SetupDiagnostic $rawFailure 'launch' (New-SaveState) -Key $redactionKey
Assert-True ($redactedNotice.Contains('Synthetic device is busy') -and -not $redactedNotice.Contains($redactionKey) -and -not $redactedNotice.Contains($encodedKey)) 'Current key or escaped key leaked, or safe detail was hidden'
$configFailure=New-Object System.Exception("[private]`nextra = `"synthetic-config`"")
Assert-True (-not (Get-SetupDiagnostic $configFailure 'parse' (New-SaveState)).Contains('synthetic-config')) 'Unknown exception leaked configuration content'
$nullNotice=Get-SetupDiagnostic $null 'key' $null
Assert-True ($nullNotice.Contains('W010') -and $nullNotice.Contains('无异常对象')) 'Null exception caused a secondary error'
Assert-True ((Get-SetupDiagnostic $null 'app-check' (New-SaveState)).Contains('W009')) 'Application-check stage missing'
Assert-True ($setupSource.Contains("`$stage='key'; `$key=Select-GatewayKey") -and $setupSource.Contains("`$stage='app-check'")) 'Interactive stages are inaccurate'
# All rejected per-line constructs must carry the nearest line without source text.
foreach ($badLine in @('x = { secret = "synthetic-config" }','x = "synthetic-secret','x = [1]','model = false','x = "\N"')) {
    $caught=$null
    try { [void](Read-SafeToml ("# synthetic header`n"+$badLine)) } catch { $caught=$_.Exception }
    Assert-True ($null -ne $caught -and $caught.Data['TomlLine'] -eq 2) 'Parser failure missing line number'
    $notice=Get-SetupDiagnostic $caught 'parse' (New-SaveState)
    Assert-True ($notice.Contains('TOML 行号：2') -and $notice -notmatch 'synthetic-secret|synthetic-config|synthetic header') 'Parse diagnostic leaks source or lacks line'
}
foreach ($badText in @("# header`nx = 1`nx = 2","# header`n[a]`n[a]")) {
    $caught=$null; try { [void](Read-SafeToml $badText) } catch { $caught=$_.Exception }
    Assert-True ($null -ne $caught -and $caught.Data['TomlLine'] -eq 3) 'Duplicate failure missing line number'
}
$caught=$null; try { [void](Read-SafeToml ("# header`nx = 1"+[char]0)) } catch { $caught=$_.Exception }
Assert-True ($null -ne $caught -and $caught.Data['TomlLine'] -eq 2) 'Line-ending failure missing line number'
# No live network. Distinguish status codes from timeout, DNS, connection and TLS errors.
foreach ($code in @(200,204,299)) { Assert-True (Get-GatewayResult -StatusCode $code).Success '2xx was not accepted' }
foreach ($code in @(301,401,403,404,429,500,503)) {
    $result=Get-GatewayResult -StatusCode $code -Exception (New-Object System.Exception($secretText))
    Assert-True (-not $result.Success -and $result.Reason.Contains("HTTP $code") -and $result.Code -eq "W006-HTTP-$code") 'HTTP category lost'
    $state=New-SaveState; $state.Started=$true; $state.ContentSaved=$true
    $notice=Get-SetupDiagnostic $result.Exception 'verify' $state $result.Reason $result.Code
    Assert-True ($notice.Contains('已保存') -and $notice -notmatch 'synthetic-|Authorization|experimental_bearer_token') 'HTTP diagnostic state or redaction failed'
}
foreach ($status in @('Timeout','ConnectFailure','NameResolutionFailure','ProxyNameResolutionFailure','TrustFailure','SecureChannelFailure','ConnectionClosed','ReceiveFailure','SendFailure')) {
    $statusValue=[Net.WebExceptionStatus]([Enum]::Parse([Net.WebExceptionStatus],$status))
    $exception=New-Object System.Net.WebException($secretText,$statusValue)
    $result=Get-GatewayResult -TransportStatus $status -Exception $exception
    Assert-True (-not $result.Success -and $result.Reason.Contains($status) -and $result.Code -eq 'W006-NET') 'Transport category lost'
    Assert-True ($result.Reason -notmatch 'synthetic-|Authorization|experimental_bearer_token') 'Transport message leaked'
}
# Synthetic state matrix includes failures before/after replacement and after successful content save.
$state=New-SaveState
Assert-True ((Get-ConfigStateText $state).Contains('权限未由本工具修改')) 'Initial state is ambiguous'
$state.Started=$true
Assert-True ((Get-ConfigStateText $state).Contains('未保存') -and (Get-ConfigStateText $state).Contains('可能生成')) 'Early save failure is ambiguous'
$state.BackupCreated=$true; $state.PermissionsMayHaveChanged=$true
$notice=Get-ConfigStateText $state
Assert-True ($notice.Contains('未保存') -and $notice.Contains('权限可能已修改') -and $notice.Contains('已生成原内容备份')) 'Pre-replacement failure hides side effects'
$state.ReplacementAttempted=$true
Assert-True ((Get-ConfigStateText $state).Contains('保存结果未确认')) 'Unconfirmed replacement falsely claims unchanged file'
$state.ContentSaved=$true
Assert-True ((Get-ConfigStateText $state).StartsWith('已保存')) 'Post-save failure falsely claims no change'
$fixture=@'
# [model_providers.custom] is only a comment
model = "existing-model"
model_provider = "old" # provider comment
notify = ["C:\\example\\notify.cmd", "turn-ended"] # preserved
[plugins."codex-app-tools@openai-bundled"]
enabled = true
args = []
[projects."/Users/example/project"]
trust_level = "trusted"
[model_providers.custom]
base_url = "https://gateway.example.com/v1/"
experimental_bearer_token = "old-secret"
extra = "untouched # text"
'@
$parsed=Read-SafeToml $fixture
Assert-True ((Get-ExistingKey $parsed) -ceq 'old-secret') 'Existing key was not preserved'
$key='quote"slash\ tab'+[char]9+' newline'+[char]10+'中文'
$out=Build-Config $parsed $key
$again=Read-SafeToml $out
Assert-True ((Get-ExistingKey $again) -ceq $key) 'Key escaping did not round-trip'
Assert-True ($out.Contains('model = "existing-model"')) 'Model changed'
Assert-True ($out.Contains('[plugins."codex-app-tools@openai-bundled"]')) 'Quoted table changed'
Assert-True ($out.Contains('extra = "untouched # text"')) 'Unrelated value changed'
Assert-True ($out.Contains('# provider comment')) 'Target comment lost'
Assert-True ($out.Contains('notify = ["C:\\example\\notify.cmd", "turn-ended"]')) 'String array changed'
Assert-True ($out.Contains('args = []')) 'Empty array changed'
Assert-True ((Build-Config (Read-SafeToml '') 'synthetic') -match 'model = "gpt-6.1-sol"') 'Default model missing'
foreach ($url in @('https://gateway.example.com.attacker.test/v1','https://gateway.example.com/v1?x=1','http://gateway.example.com/v1','https://gateway.example.com/foo/../v1','https://gateway.example.com/V1','https://gateway.example.com:444/v1')) {
    $inputText="[model_providers.custom]`nbase_url = `"$url`"`nexperimental_bearer_token = `"synthetic`""
    Assert-True ($null -eq (Get-ExistingKey (Read-SafeToml $inputText))) 'Unexpected old-key reuse'
}
Assert-Reject "x = 1`nx = 2"
Assert-Reject "[a]`n[a]"
Assert-Reject "[a.b]`n[a.`"b`"]"
Assert-Reject "a = 1`n[a.b]"
Assert-Reject 'x = [1, 2]'
Assert-Reject 'x = ["a" "b"]'
Assert-Reject 'x = ["a",, "b"]'
Assert-Reject 'model = false'
Assert-Reject 'x = TRUE'
Assert-Reject 'x = "\N"'
Assert-Reject 'x = { a = 1 }'
Assert-Reject "x = `"`"`"abc`nend`"`"`""
Assert-Reject 'a.b = 1'
Assert-Reject '"model" = "x"'
Assert-Reject '[[table]]'
$dir=Join-Path $PSScriptRoot ('test-output-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
Assert-NoReparseAncestors $dir
$target=Join-Path $dir 'junction-target'; $link=Join-Path $dir 'junction-link'
[void][IO.Directory]::CreateDirectory((Join-Path $target 'child'))
$junctionCreated=$false
try { [void](New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop); $junctionCreated=$true } catch { Write-Output 'SKIP: this Windows environment cannot create a junction for the reparse test.' }
if ($junctionCreated) {
    foreach ($check in @($link,(Join-Path $link 'child'))) {
        $rejected=$false; try { Assert-NoReparseAncestors $check } catch { $rejected=$true }
        Assert-True $rejected 'Directory or ancestor junction was not rejected'
    }
    $rejected=$false
    try { Save-ConfigAtomic (Join-Path (Join-Path $link 'child') 'config.toml') ([byte[]]@()) $false 'synthetic' } catch { $rejected=$true }
    Assert-True $rejected 'Save through junction was not rejected'
    Assert-True (-not [IO.File]::Exists((Join-Path (Join-Path $target 'child') 'config.toml'))) 'Config was written through junction'
}
$path=Join-Path $dir 'config.toml'
$utf8=New-Object System.Text.UTF8Encoding($false,$true)
$initial=$utf8.GetBytes('model = "test"')
New-PrivateFile $path $initial
$savedState=New-SaveState
Save-ConfigAtomic $path $initial $true (Build-Config (Read-SafeToml 'model = "test"') 'synthetic') $savedState
Assert-True ($savedState.Started -and $savedState.BackupCreated -and $savedState.PermissionsMayHaveChanged -and $savedState.ReplacementAttempted -and $savedState.ContentSaved) 'Successful save state was not tracked'
Assert-True ((Get-ExistingKey (Read-SafeToml ([IO.File]::ReadAllText($path)))) -ceq 'synthetic') 'Save failed'
$backups=@(Get-ChildItem -LiteralPath $dir -Filter 'config.toml.backup-*')
Assert-True ($backups.Count -eq 1) 'Missing backup'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName)) -ceq [Convert]::ToBase64String($initial)) 'Backup differs'
$conflictState=New-SaveState
$conflict=$false; try { Save-ConfigAtomic $path $initial $true 'different' $conflictState } catch { $conflict=$true }
Assert-True $conflict 'Concurrent change was not detected'
Assert-True ($conflictState.BackupCreated -and -not $conflictState.ContentSaved -and -not $conflictState.ReplacementAttempted) 'Conflict failure state was not tracked'
Assert-True ((Get-ConfigStateText $conflictState).Contains('已生成原内容备份')) 'Conflict diagnostic hides backup'
# Preserve BOM on the user's config as well as on the source scripts.
$bomPath=Join-Path $dir 'bom-config.toml'
$bomText=([string][char]0xfeff)+(Build-Config (Read-SafeToml '') 'synthetic-bom')
$bomState=New-SaveState
Save-ConfigAtomic $bomPath ([byte[]]@()) $false $bomText $bomState
$bomBytes=[IO.File]::ReadAllBytes($bomPath)
Assert-True ($bomBytes[0] -eq 0xef -and $bomBytes[1] -eq 0xbb -and $bomBytes[2] -eq 0xbf) 'Configuration BOM was lost'
Assert-True ($bomState.ContentSaved -and -not $bomState.BackupCreated) 'New-file state is incorrect'
# Inject an early helper failure in the test scope; never alter production save primitives.
$coreAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ConfigCore.ps1'),[ref]$tokens,[ref]$parseErrors)
$privateFileDefinition=@($coreAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-PrivateFile' },$true))[0].Extent.Text
$earlyState=New-SaveState; $earlyPath=Join-Path $dir 'early-failure.toml'; $earlyFailed=$false
try {
    function New-PrivateFile([string]$Path,[byte[]]$Bytes) { throw (New-Object System.IO.IOException('synthetic-secret')) }
    try { Save-ConfigAtomic $earlyPath ([byte[]]@()) $false 'synthetic' $earlyState } catch { $earlyFailed=$true }
} finally { . ([scriptblock]::Create($privateFileDefinition)) }
Assert-True ($earlyFailed -and $earlyState.Started -and -not $earlyState.ContentSaved -and -not $earlyState.ReplacementAttempted) 'Early save failure state is incorrect'
Assert-True (-not [IO.File]::Exists($earlyPath)) 'Early failure wrote destination content'
Write-Output 'PASS: synthetic UI orchestration, diagnostic redaction/line/state, HTTP/transport classification, parser, escaping, URL, BOM, backup and conflict tests. Test output is retained alongside this script.'
