# Standalone Windows PowerShell 5.1 tests. No Pester, network, GUI or installation.
param([string]$StarterPath = (Join-Path $PSScriptRoot '..\dist\setup-windows.ps1'))
$ErrorActionPreference = 'Stop'
$passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host ('PASS: ' + $Name)
}

if (-not (Test-Path -LiteralPath $StarterPath -PathType Leaf)) {
    throw 'Generate dist/setup-windows.ps1 before running these tests.'
}
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($StarterPath), [ref]$tokens, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) 'Generated starter must parse in Windows PowerShell 5.1.'
$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($StarterPath))
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') {
    throw 'Run these standalone tests with Windows PowerShell 5.1 (Desktop), not pwsh.'
}
Assert-True (-not $source.Contains('@@VERSION@@') -and -not $source.Contains('@@HASHES@@')) 'Release placeholders must be substituted.'
# Load only function definitions: never execute the generated starter entry or exit.
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false))
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
Assert-True ($definitions.Count -eq 8) 'Expected standalone function contract.'
$realRemove = ${function:Remove-GatewayPrivateDirectory}
$realRead = ${function:Read-GatewayProduct}
$realNew = ${function:New-GatewayPrivateDirectory}
$originalGateway = $env:AI_GATEWAY_URL
$env:AI_GATEWAY_URL = 'https://gateway.example.com'
$originalTls = [Net.ServicePointManager]::SecurityProtocol
$originalProgress = $ProgressPreference
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = [IO.Path]::GetFullPath($testRoot)
# Raw fixture includes BOM and CRLF; the downloader mock writes bytes without decoding.
$script:fixture = [byte[]](239, 187, 191, 35, 32, 116, 101, 115, 116, 13, 10)
$sha = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sha.ComputeHash($script:fixture))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$hashes = @{}
foreach ($productName in @('claude', 'codex')) {
    foreach ($asset in @(Get-GatewayAssets $productName)) { $hashes[$asset.Asset] = $digest }
}
$script:downloaded = New-Object 'Collections.Generic.List[string]'
$script:executed = 0
$script:childExit = 23
$script:corruptAsset = ''
$script:downloadFailure = $false
$script:lastDirectory = $null
$script:cleanupCalls = 0
function New-GatewayPrivateDirectory {
    param([string]$TempRoot)
    $script:lastDirectory = Join-Path $TempRoot ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:lastDirectory)
    return $script:lastDirectory
}
function Invoke-GatewayDownload {
    param([string]$Uri, [string]$Destination)
    if ($script:downloadFailure) { throw 'Mock download failed.' }
    $asset = ([uri]$Uri).Segments[-1]
    Assert-True ($Uri -ceq ('https://github.com/k0x7q/ai-gateway-setup/releases/download/v1.2.3/' + $asset)) 'Fixed release download URL.'
    [void]$script:downloaded.Add($asset)
    $bytes = $script:fixture
    if ($asset -eq $script:corruptAsset) { $bytes = [byte[]](1, 2, 3) }
    [IO.File]::WriteAllBytes($Destination, $bytes)
}
function Invoke-GatewayChild {
    param([string]$Helper)
    $script:executed++
    Assert-True ($env:AI_GATEWAY_URL -ceq $script:expectedGateway) 'Configured gateway must be inherited by child.'
    Assert-True ([IO.Path]::GetFileName($Helper) -eq 'Setup.ps1') 'Execute helper directly, never cmd launcher.'
    Assert-True ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Helper)) -eq 'helpers') 'Expected helpers layout.'
    foreach ($file in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Helper)) -File)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert-True ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($script:fixture)) 'Downloaded BOM and CRLF must be unchanged.'
    }
    return $script:childExit
}
function Remove-GatewayPrivateDirectory {
    param([string]$Path, [string]$TempRoot, [string]$TrackedPath)
    $script:cleanupCalls++
    & $script:realRemove -Path $Path -TempRoot $TempRoot -TrackedPath $TrackedPath
}
function Read-GatewayProduct { return $script:selection }
function Reset-Mocks {
    $script:downloaded.Clear()
    $script:executed = 0
    $script:corruptAsset = ''
    $script:downloadFailure = $false
    $script:lastDirectory = $null
    $script:cleanupCalls = 0
    $script:childExit = 23
    $script:expectedGateway = 'https://gateway.example.com'
}
try {
    Test-Case 'In-memory entry preserves the session and publishes exit status' {
        $entry = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$bootstrapExit'
        })[0]
        Assert-True ($null -ne $entry) 'Starter has a distinct entry assignment.'
        $exitNodes = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.ExitStatementAst]
        }, $true))
        Assert-True ($exitNodes.Count -eq 1 -and $exitNodes[0].Parent.Parent -is [Management.Automation.Language.IfStatementAst]) 'Process exit must be guarded, never unconditional.'
        Assert-True ($exitNodes[0].Parent.Parent.Extent.Text.Contains('[Management.Automation.ExternalScriptInfo]')) 'Only real script-file invocation may exit.'
        function Invoke-GatewayBootstrap {
            param([string]$Product, [string]$Version, [hashtable]$Hashes, [string]$GatewayUrl)
            return 37
        }
        $oldExit = $global:LASTEXITCODE
        try {
            # Execute only the safe footer with a mocked bootstrap. Unconditional exit
            # would terminate the test process with 37, failing Windows CI.
            & ([scriptblock]::Create($source.Substring($entry.Extent.StartOffset)))
            Assert-True ($global:LASTEXITCODE -eq 37) 'In-memory entry returns control with child status.'
        }
        finally { $global:LASTEXITCODE = $oldExit }
    }
    Test-Case 'Unsupported PowerShell edition/version rejected before staging' {
        Reset-Mocks
        $bootstrapDefinition = @($definitions | Where-Object { $_.Name -eq 'Invoke-GatewayBootstrap' })[0]
        $fixtureSource = $bootstrapDefinition.Extent.Text.Replace('$PSVersionTable', '$script:fakeVersionTable')
        . ([scriptblock]::Create($fixtureSource))
        $script:fakeVersionTable = @{ PSVersion = [version]'7.4'; PSEdition = 'Core' }
        Assert-True ((Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes) -eq 1) 'Reject PowerShell Core.'
        $script:fakeVersionTable = @{ PSVersion = [version]'5.0'; PSEdition = 'Desktop' }
        Assert-True ((Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes) -eq 1) 'Reject older Windows PowerShell.'
        Assert-True ($null -eq $script:lastDirectory -and $script:downloaded.Count -eq 0 -and $script:executed -eq 0) 'Unsupported runtime is side-effect free.'
    }
    Test-Case 'Claude selection, byte preservation, exit and cleanup' {
        Reset-Mocks
        $result = Invoke-GatewayBootstrap -Product claude -Version v1.2.3 -Hashes $hashes
        Assert-True ($result -eq 23) 'Preserve nonzero child exit.'
        Assert-True ($script:executed -eq 1 -and $script:downloaded.Count -eq 4) 'Run once after four verified Claude assets.'
        Assert-True ($script:downloaded[0] -eq 'claude-windows-Setup.ps1') 'Claude selected.'
        Assert-True ($script:cleanupCalls -eq 1 -and -not [IO.Directory]::Exists($script:lastDirectory)) 'Clean after child.'
    }
    Test-Case 'Gateway argument overrides environment only for the setup child' {
        Reset-Mocks
        $script:expectedGateway = 'https://other.example.com:8443'
        $result = Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes -GatewayUrl 'https://other.example.com:8443/'
        Assert-True ($result -eq 23 -and $script:executed -eq 1) 'Configured gateway reaches child.'
        Assert-True ($env:AI_GATEWAY_URL -ceq 'https://gateway.example.com') 'Calling session environment is restored.'
    }
    Test-Case 'Missing or invalid gateway rejected before staging' {
        foreach ($value in @('', 'http://gateway.example.com', 'https://user@gateway.example.com',
            'https://gateway.example.com/v1', 'https://gateway.example.com?x=1',
            'https://gateway.example.com#f', 'https://gateway.example.com:0', 'https://gateway.example.com:65536')) {
            Reset-Mocks
            $result = Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes -GatewayUrl $value
            Assert-True ($result -eq 1 -and $script:executed -eq 0 -and $script:downloaded.Count -eq 0 -and $null -eq $script:lastDirectory) 'Invalid gateway must not download or execute.'
        }
    }
    Test-Case 'Codex menu selection downloads only config helpers' {
        Reset-Mocks
        $script:selection = 'codex'
        $script:childExit = 0
        $result = Invoke-GatewayBootstrap -Version v1.2.3 -Hashes $hashes
        Assert-True ($result -eq 0 -and $script:executed -eq 1) 'Preserve zero without claiming configuration success.'
        Assert-True ($script:downloaded.Count -eq 2 -and $script:downloaded[1] -eq 'codex-windows-ConfigCore.ps1') 'Only two Codex assets.'
    }
    Test-Case 'Cancel creates no directory and executes nothing' {
        Reset-Mocks
        $script:selection = ''
        $result = Invoke-GatewayBootstrap -Version v1.2.3 -Hashes $hashes
        Assert-True ($result -eq 0 -and $script:executed -eq 0 -and $null -eq $script:lastDirectory) 'Cancel is side-effect free.'
    }
    Test-Case 'Last asset mismatch prevents all execution and cleans' {
        Reset-Mocks
        $script:corruptAsset = 'claude-windows-key-dialog.ps1'
        $result = Invoke-GatewayBootstrap -Product claude -Version v1.2.3 -Hashes $hashes
        Assert-True ($result -eq 1 -and $script:executed -eq 0 -and $script:downloaded.Count -eq 4) 'Never execute even if earlier hashes passed.'
        Assert-True (-not [IO.Directory]::Exists($script:lastDirectory)) 'Mismatch cleanup.'
    }
    Test-Case 'Nonregular downloaded file is rejected before execution' {
        Reset-Mocks
        function Get-Item {
            param([string]$LiteralPath, [switch]$Force, [string]$ErrorAction)
            if ([IO.Path]::GetFileName($LiteralPath) -eq 'ConfigCore.ps1') {
                return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $false }
            }
            return Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
        }
        $result = Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes
        Assert-True ($result -eq 1 -and $script:executed -eq 0) 'Reject linked download even if its bytes hash correctly.'
        Assert-True (-not [IO.Directory]::Exists($script:lastDirectory)) 'Rejection cleans staging.'
    }
    Test-Case 'Invalid metadata rejected before download' {
        Reset-Mocks
        $badHashes = $hashes.Clone()
        $badHashes['codex-windows-ConfigCore.ps1'] = 'not-a-hash'
        Assert-True ((Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $badHashes) -eq 1) 'Bad hash rejected.'
        Assert-True ($script:downloaded.Count -eq 0 -and $null -eq $script:lastDirectory) 'Metadata checked before staging.'
        Assert-True ((Invoke-GatewayBootstrap -Product codex -Version '../main' -Hashes $hashes) -eq 1) 'Unsafe version rejected.'
    }
    Test-Case 'Download failure cleans and never executes' {
        Reset-Mocks
        $script:downloadFailure = $true
        Assert-True ((Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes) -eq 1) 'Download failure exit.'
        Assert-True ($script:executed -eq 0 -and -not [IO.Directory]::Exists($script:lastDirectory)) 'Failure cleanup.'
    }
    Test-Case 'Menu mapping and invalid-input retry' {
        $script:answers = New-Object 'Collections.Generic.Queue[string]'
        foreach ($answer in @('invalid', '1', '2', '0')) { $script:answers.Enqueue($answer) }
        function Read-Host { param([string]$Prompt) return $script:answers.Dequeue() }
        Assert-True ((& $script:realRead) -eq 'claude') '1 means Claude, invalid retried.'
        Assert-True ((& $script:realRead) -eq 'codex') '2 means Codex.'
        Assert-True ((& $script:realRead) -eq '') '0 means cancel.'
    }
    Test-Case 'Cleanup refuses untracked, relative, parent and nested paths' {
        $child = Join-Path $testRoot ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($child)
        Assert-Throws { & $script:realRemove -Path $testRoot -TempRoot $testRoot -TrackedPath $testRoot } 'Cannot delete temp root itself.'
        Assert-Throws { & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath '' } 'Requires tracked path.'
        Assert-Throws { & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $testRoot } 'Mismatched tracked path denied.'
        Assert-Throws { & $script:realRemove -Path '.\ai-gateway-relative' -TempRoot $testRoot -TrackedPath $child } 'Relative path denied.'
        $nested = Join-Path $child ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($nested)
        Assert-Throws { & $script:realRemove -Path $nested -TempRoot $testRoot -TrackedPath $nested } 'Only direct child allowed.'
        Assert-True ([IO.Directory]::Exists($nested)) 'Refusal leaves directories intact.'
        & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $child
        Assert-True (-not [IO.Directory]::Exists($child)) 'Valid tree removed.'
    }
    Test-Case 'Cleanup rejects mocked reparse directory without deleting it' {
        $child = Join-Path $testRoot ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($child)
        # No junction privileges needed: emulate filesystem metadata, retain real deletion.
        function Get-Item {
            param([string]$LiteralPath, [switch]$Force, [string]$ErrorAction)
            return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $true }
        }
        Assert-Throws { & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $child } 'Reparse directory rejected.'
        Assert-True ([IO.Directory]::Exists($child)) 'Link rejection must not delete.'
        Remove-Item Function:\Get-Item
        & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $child
    }
    Test-Case 'Cleanup rejects a mocked descendant reparse file' {
        $child = Join-Path $testRoot ('ai-gateway-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($child)
        function Get-ChildItem {
            param([string]$LiteralPath, [switch]$Force, [string]$ErrorAction)
            return [pscustomobject]@{
                Attributes = [IO.FileAttributes]::ReparsePoint
                PSIsContainer = $false
                FullName = (Join-Path $LiteralPath 'mock-link')
            }
        }
        Assert-Throws { & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $child } 'Descendant reparse file rejected.'
        Assert-True ([IO.Directory]::Exists($child)) 'Descendant rejection must not delete tree.'
        Remove-Item Function:\Get-ChildItem
        & $script:realRemove -Path $child -TempRoot $testRoot -TrackedPath $child
    }
    Test-Case 'Cleanup failure preserves child exit and restores preferences' {
        Reset-Mocks
        function Remove-GatewayPrivateDirectory {
            param([string]$Path, [string]$TempRoot, [string]$TrackedPath)
            throw 'Mock cleanup refusal.'
        }
        try {
            $result = Invoke-GatewayBootstrap -Product codex -Version v1.2.3 -Hashes $hashes
            Assert-True ($result -eq 23) 'Cleanup warning must not overwrite setup exit.'
            Assert-True ([IO.Directory]::Exists($script:lastDirectory)) 'Refused cleanup leaves evidence.'
            Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $originalTls) 'TLS restored even with cleanup failure.'
        }
        finally {
            & $script:realRemove -Path $script:lastDirectory -TempRoot ([IO.Path]::GetTempPath()) -TrackedPath $script:lastDirectory
        }
    }
    Test-Case 'Private directory ACL is noninheriting and user/system only' {
        $private = & $script:realNew -TempRoot $testRoot
        try {
            $acl = Get-Acl -LiteralPath $private
            Assert-True $acl.AreAccessRulesProtected 'ACL inheritance disabled.'
            $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
            $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Assert-True ($sids.Count -eq 2 -and $sids -contains $userSid -and $sids -contains 'S-1-5-18') 'Only current user and SYSTEM grants.'
        }
        finally { & $script:realRemove -Path $private -TempRoot $testRoot -TrackedPath $private }
    }
    Test-Case 'Process TLS and progress preferences restored' {
        Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $originalTls) 'Restore process TLS.'
        Assert-True ($ProgressPreference -eq $originalProgress) 'Restore progress preference.'
    }
    Write-Host ('PASS: ' + $passed + ' standalone Windows bootstrap tests.')
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $originalTls
    $ProgressPreference = $originalProgress
    $env:AI_GATEWAY_URL = $originalGateway
    # Test root is itself tracked and a direct child of the system temp root.
    & $script:realRemove -Path $testRoot -TempRoot ([IO.Path]::GetTempPath()) -TrackedPath $testRoot
}
