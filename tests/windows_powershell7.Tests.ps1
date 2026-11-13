# Windows-only PowerShell 7 relay integration. Synthetic source; no GUI/network/config writes.
param([string]$StarterPath = (Join-Path $PSScriptRoot '..\dist\setup-windows.ps1'))
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run with PowerShell 7 on Windows.' }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}
function Host-Text {
    param([object[]]$Records)
    return (($Records | Where-Object { $_ -is [Management.Automation.InformationRecord] } |
        ForEach-Object { $_.MessageData.ToString() }) -join "`n")
}
$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($StarterPath))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-True (@($errors).Count -eq 0) 'Starter parses in PowerShell 7.'
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
$variables = @('USERPROFILE', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'AI_GATEWAY_URL',
    'AI_SETUP_TEST_SID', 'AI_SETUP_TEST_ADMIN', 'AI_SETUP_TEST_PRODUCT', 'AI_SETUP_TEST_GATEWAY')
$original = @{}
foreach ($name in $variables) { $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$originalTls = [Net.ServicePointManager]::SecurityProtocol
$originalProgress = $ProgressPreference
$originalOutput = [Console]::OutputEncoding.CodePage
$originalInput = [Console]::InputEncoding.CodePage
$originalExit = $global:LASTEXITCODE
$root = Join-Path ([IO.Path]::GetTempPath()) ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
# These paths intentionally do not exist: any actual configuration write is forbidden.
$env:USERPROFILE = Join-Path $root 'synthetic-profile'
$env:CODEX_HOME = Join-Path $root 'Codex Home'
$env:CLAUDE_CONFIG_DIR = Join-Path $root '中文 Claude Home'
$env:AI_GATEWAY_URL = 'https://original.example.com'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$env:AI_SETUP_TEST_SID = $identity.User.Value
$env:AI_SETUP_TEST_ADMIN = [string]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$env:AI_SETUP_TEST_PRODUCT = 'codex'
$env:AI_SETUP_TEST_GATEWAY = "https://gateway.example.com/'; throw 'INJECTED'; #"
try {
    $fixture = @'
param([string]$Product, [string]$GatewayUrl)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Wrong worker runtime.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Worker must be STA.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($identity.User.Value -cne $env:AI_SETUP_TEST_SID -or
    ([string]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) -cne $env:AI_SETUP_TEST_ADMIN) { throw 'Account or privilege changed.' }
if ($Product -cne $env:AI_SETUP_TEST_PRODUCT -or $GatewayUrl -cne $env:AI_SETUP_TEST_GATEWAY) { throw 'Arguments changed.' }
if ((Split-Path $env:USERPROFILE -Leaf) -cne 'synthetic-profile' -or
    (Split-Path $env:CODEX_HOME -Leaf) -cne 'Codex Home' -or
    (Split-Path $env:CLAUDE_CONFIG_DIR -Leaf) -cne '中文 Claude Home') { throw 'Environment changed.' }
[Console]::WriteLine('正在准备配置工具……')
[Console]::Error.WriteLine('中文诊断：测试信息')
for ($i = 0; $i -lt 400; $i++) {
    [Console]::WriteLine('out-' + $i + ('x' * 200))
    [Console]::Error.WriteLine('err-' + $i + ('y' * 200))
}
$env:AI_GATEWAY_URL = 'https://worker-only.example.com'
$global:LASTEXITCODE = 29
'@
    # Exceeds Windows' command-line limit; must travel through stdin, not EncodedCommand.
    $fixture += "`n#" + (' padding' * 10000)
    $records = @(Invoke-GatewayDesktopBootstrap -Source $fixture -Product codex -GatewayUrl $env:AI_SETUP_TEST_GATEWAY 6>&1)
    Assert-True ($records[-1] -eq 29) 'Real worker nonzero exit propagated.'
    $text = Host-Text $records
    Assert-True ($text.Contains('正在准备配置工具……') -and $text.Contains('中文诊断：测试信息')) 'UTF-8 stdout and stderr preserved.'
    Assert-True ($text.Contains('out-399') -and $text.Contains('err-399')) 'Both large pipes drained without deadlock.'
    Assert-True ($env:AI_GATEWAY_URL -ceq 'https://original.example.com') 'Worker environment changes do not affect caller.'
    Assert-True ($global:LASTEXITCODE -eq $originalExit) 'Relay helper does not overwrite caller exit variable.'
    Write-Host 'PASS: real 7-to-5.1 relay, STA, current account/privilege, UTF-8, large source/pipes and nonzero status.'

    $entry = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$bootstrapExit'
    })[0]
    Assert-True ($null -ne $entry) 'Distinct production entry.'
    # Only the 5.1 worker gets this harmless bootstrap mock. The 7 caller still runs
    # the production bootstrap, source capture, relay, footer and state restoration.
    $desktopMock = @'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    function Invoke-GatewayBootstrap {
        param([string]$Product, [string]$Version, [hashtable]$Hashes, [string]$GatewayUrl, [string]$Source)
        if ($Product -cne $env:AI_SETUP_TEST_PRODUCT -or $GatewayUrl -cne $env:AI_SETUP_TEST_GATEWAY) { throw 'Entry arguments changed.' }
        if ([string]::IsNullOrWhiteSpace($Source)) { throw 'Full in-memory source not captured.' }
        Write-Host '配置工具下载及完整性校验通过。'
        return 31
    }
}
'@
    $safeSource = $source.Insert($entry.Extent.StartOffset, $desktopMock + "`n")
    $env:AI_SETUP_TEST_GATEWAY = 'https://gateway.example.com:8443/'
    foreach ($product in @('claude', 'codex', '')) {
        $env:AI_SETUP_TEST_PRODUCT = $product
        $arguments = @{ GatewayUrl = $env:AI_SETUP_TEST_GATEWAY }
        if ($product) { $arguments.Product = $product }
        $records = @(& ([scriptblock]::Create($safeSource)) @arguments 6>&1)
        Assert-True ($global:LASTEXITCODE -eq 31) 'In-memory entry preserves session and publishes worker exit.'
        Assert-True ((Host-Text $records).Contains('配置工具下载及完整性校验通过。')) 'Worker host output forwarded.'
    }
    Write-Host 'PASS: production in-memory entry for Claude, Codex and omitted product (popup route).'
    $records = @(Invoke-GatewayDesktopBootstrap -Source "param([string]`$GatewayUrl)`nthrow 'synthetic worker failure'" -GatewayUrl 'https://gateway.example.com' 6>&1)
    Assert-True ($records[-1] -eq 1 -and (Host-Text $records).Contains('synthetic worker failure')) 'Worker exception status and diagnostic preserved.'
    $threw = $false
    try { Invoke-GatewayDesktopBootstrap -Source '' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Empty source stops before child launch.'
    Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $originalTls -and $ProgressPreference -eq $originalProgress) 'TLS/progress restored.'
    Assert-True ([Console]::OutputEncoding.CodePage -eq $originalOutput -and [Console]::InputEncoding.CodePage -eq $originalInput) 'Caller console encoding unchanged.'
    Assert-True ($env:AI_GATEWAY_URL -ceq 'https://original.example.com') 'Entry restores caller gateway.'
    Assert-True (-not [IO.Directory]::Exists($root)) 'No user configuration, staging, network, GUI or installation.'
    Write-Host 'PASS: failures and caller-state restoration.'
} finally {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    $global:LASTEXITCODE = $originalExit
}
Write-Host 'PASS: all PowerShell 7 relay integration checks.'
exit 0
