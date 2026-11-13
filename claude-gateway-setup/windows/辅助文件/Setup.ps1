# Windows PowerShell 5.1; UTF-8 BOM is required for Chinese source text.
# Strict mode is enabled only when running, not when dot sourced.

function ConvertTo-GatewayOrigin {
    param([string]$Value = $env:AI_GATEWAY_URL)
    if ([string]::IsNullOrEmpty($Value) -or $Value -cnotmatch '^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?/?\z') {
        throw 'Specify AI_GATEWAY_URL / --gateway as an HTTPS host URL without credentials, path, query or fragment.'
    }
    $parsed = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -cne 'https' -or [string]::IsNullOrEmpty($parsed.Host) -or
        $parsed.Port -lt 1 -or $parsed.Port -gt 65535) {
        throw 'Invalid HTTPS gateway host or port.'
    }
    return $parsed.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
}

function Get-WindowsArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { throw '仅支持 Windows x64 或 ARM64；请使用官方支持的 64 位 Windows。' }
    }
}
function Add-ProcessPath {
    param([string[]]$Directories)
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in (@($Directories) + @($env:PATH -split ';'))) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $value = $entry.Trim().Trim('"')
            if (-not $items.Contains($value)) { [void]$items.Add($value) }
        }
    }
    $env:PATH = $items -join ';'
}
function Refresh-ProcessPath {
    param([string[]]$PriorityDirectories = @())
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    # Retain process-only entries while picking up newly installed PATH entries.
    Add-ProcessPath (@($PriorityDirectories) + @($machine -split ';') + @($user -split ';'))
}
function Add-UserPath {
    param([string]$Directory)
    $existing = [Environment]::GetEnvironmentVariable('Path', 'User')
    # Keep all unrelated entries; prioritize the verified command directory over stale user shims.
    # Do not use setx: it can truncate existing PATH values.
    $remaining = @()
    if (-not [string]::IsNullOrEmpty($existing)) {
        foreach ($entry in @($existing -split ';')) {
            if ($entry.Trim().Trim('"').TrimEnd('\') -ine $Directory.TrimEnd('\')) { $remaining += $entry }
        }
    }
    $updated = $Directory
    if ($remaining.Count -gt 0) { $updated += ';' + ($remaining -join ';') }
    if ($updated -cne $existing) { [Environment]::SetEnvironmentVariable('Path', $updated, 'User') }
    Add-ProcessPath @($Directory)
}
function Send-EnvironmentChange {
    # Notify Explorer without restarting it; bounded, best-effort and non-elevated.
    try {
        if (-not ('ClaudeGateway.EnvironmentBroadcast' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClaudeGateway {
    public static class EnvironmentBroadcast {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr window, uint message, UIntPtr wParam, string lParam,
            uint flags, uint timeout, out UIntPtr result);
    }
}
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        $sent = [ClaudeGateway.EnvironmentBroadcast]::SendMessageTimeout(
            [IntPtr]0xffff, [uint32]0x001a, [UIntPtr]::Zero, 'Environment',
            [uint32]0x0002, [uint32]5000, [ref]$result)
        if ($sent -eq [IntPtr]::Zero) {
            Write-Host '环境变量已保存，但通知窗口超时。如新终端未读取新设置，请注销并重新登录 Windows。' -ForegroundColor Yellow
        }
    } catch {
        $warning = [ordered]@{ code = 'ENVIRONMENT_NOTIFY'; stage = 'environment-notify'; reason = (Protect-DiagnosticText $_.Exception.Message); type = $_.Exception.GetType().FullName; HResult = $_.Exception.HResult; PATHstate = $script:PathState }
        Write-Host ('环境变量已保存，但通知窗口失败。' + (ConvertTo-Json $warning -Compress)) -ForegroundColor Yellow
    }
}
function Get-NativeCommandPath {
    param([string]$Name)
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return $null
}
function Get-KnownNodeDirectories {
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles)) {
        if ($root) { Join-Path $root 'nodejs' }
    }
    if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
        Join-Path $env:LOCALAPPDATA 'nodejs'
    }
}
function Get-NodeRuntime {
    param([string[]]$PriorityDirectories = @())
    $candidates = @()
    foreach ($directory in $PriorityDirectories) {
        if ($directory) { $candidates += (Join-Path $directory 'node.exe') }
    }
    $current = Get-NativeCommandPath 'node.exe'
    if ($current) { $candidates += $current }
    foreach ($directory in @(Get-KnownNodeDirectories)) { $candidates += (Join-Path $directory 'node.exe') }
    foreach ($node in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { continue }
        try {
            $versionText = (& $node --version 2>$null | Out-String).Trim()
            $nodeExit = $LASTEXITCODE
            if ($nodeExit -ne 0 -or $versionText -notmatch '^v(\d+)\.(\d+)\.(\d+)$') { continue }
            if ([int]$Matches[1] -lt 22) { continue }
            $npm = Join-Path (Split-Path -Parent $node) 'npm.cmd'
            if (-not (Test-Path -LiteralPath $npm -PathType Leaf)) { $npm = Get-NativeCommandPath 'npm.cmd' }
            if (-not $npm) { continue }
            Add-ProcessPath @((Split-Path -Parent $node))
            $npmVersion = (& $npm --version 2>$null | Out-String).Trim()
            $npmExit = $LASTEXITCODE
            if ($npmExit -ne 0 -or $npmVersion -notmatch '^\d+\.\d+\.\d+') { continue }
            return [PSCustomObject]@{ Node = $node; Npm = $npm; Version = $versionText }
        } catch { throw }
    }
    return $null
}
function Get-LatestNodeLtsRelease {
    param([object[]]$Releases, [string]$Architecture)
    $fileKey = 'win-' + $Architecture + '-msi'
    $supported = @($Releases | Where-Object {
        $_.lts -and ($_.version -match '^v\d+\.\d+\.\d+$') -and
        ([version]$_.version.Substring(1)).Major -ge 22 -and (@($_.files) -contains $fileKey)
    } | Sort-Object -Property @{ Expression = { [version]$_.version.Substring(1) }; Descending = $true })
    if ($supported.Count -eq 0) { throw 'Node.js 官方列表中没有适合此架构的 22+ LTS MSI，请查看 https://nodejs.org/ 。' }
    return $supported[0]
}
function Save-OfficialDownload {
    param([string]$Uri, [string]$Destination)
    if (-not $Uri.StartsWith('https://nodejs.org/dist/', [StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝下载：Node.js 下载地址不是官方 HTTPS 地址。'
    }
    try { Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop }
    catch { throw }
}
function Test-OfficialNodeSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { return $false }
    # Require both Windows signature validation and the expected official publisher.
    return ($signature.SignerCertificate.Subject -match '(?:^|,\s*)(?:O|CN)="?(?:Node\.js(?: Foundation)?|OpenJS Foundation)"?(?:,|$)')
}
function Install-NodeLts {
    param([string]$Architecture)
    try { $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60 -ErrorAction Stop }
    catch { throw }
    $release = Get-LatestNodeLtsRelease -Releases @($releases) -Architecture $Architecture
    $version = [string]$release.version
    if ($version -notmatch '^v\d+\.\d+\.\d+$' -or @($release.files) -notcontains ('win-' + $Architecture + '-msi')) {
        throw 'Node.js 官方版本元数据无效，已停止安装。'
    }
    $filename = 'node-' + $version + '-' + $Architecture + '.msi'
    $scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('claude-gateway-node-' + [Guid]::NewGuid().ToString('N'))))
    [void](New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop)
    $msi = Join-Path $scratch $filename
    $checksums = Join-Path $scratch 'SHASUMS256.txt'
    $baseUri = 'https://nodejs.org/dist/' + $version + '/'
    Save-OfficialDownload -Uri ($baseUri + $filename) -Destination $msi
    Save-OfficialDownload -Uri ($baseUri + 'SHASUMS256.txt') -Destination $checksums
    $matchingHashes = @()
    foreach ($line in Get-Content -LiteralPath $checksums -Encoding UTF8 -ErrorAction Stop) {
        if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') {
            if ($Matches[2] -ceq $filename) { $matchingHashes += $Matches[1] }
        }
    }
    if ($matchingHashes.Count -ne 1) { throw '官方 SHA256 列表中的目标 MSI 条目缺失或不唯一，已停止安装。' }
    $expectedHash = $matchingHashes[0]
    $actualHash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ine $expectedHash) { throw 'Node.js MSI SHA256 校验失败，已停止安装。请重新下载官方安装包。' }
    if (-not (Test-OfficialNodeSignature -Path $msi)) {
        throw 'Node.js MSI Authenticode 签名或官方发布者验证失败，已停止安装。请检查网络、系统时间与证书。'
    }
    try {
        $installer = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i', ('"' + $msi + '"'), '/passive', '/norestart') -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch { throw }
    $script:ToolExitCode = $installer.ExitCode
    $script:ToolStderr = ''
    if ($installer.ExitCode -ne 0 -and $installer.ExitCode -ne 3010) {
        Stop-Setup 'NODE_MSI_EXIT' ('Node.js 安装未完成（MSI 退出码 ' + $installer.ExitCode + '）。请从 https://nodejs.org/ 手动安装后重新运行。')
    }
    if ($installer.ExitCode -eq 3010) { Write-Host 'Node.js 安装提示需要重启；若检测失败，请重启 Windows 后重新运行。' -ForegroundColor Yellow }
    $script:Installation.node = 'installed-unverified'
    $known = @(Get-KnownNodeDirectories)
    Refresh-ProcessPath -PriorityDirectories $known
    $runtime = Get-NodeRuntime -PriorityDirectories $known
    if ($null -eq $runtime) { throw '安装后仍未检测到 Node.js 22+ 与可用 npm。请重启或打开新终端，检查 https://nodejs.org/ 后重试。' }
    return $runtime
}
function Find-GitBash {
    $candidates = @()
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates += $env:CLAUDE_CODE_GIT_BASH_PATH.Trim('"') }
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) { $candidates += (Join-Path $root 'Git\bin\bash.exe') }
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
        $candidates += (Join-Path $env:LOCALAPPDATA 'Git\bin\bash.exe')
    }
    $git = Get-NativeCommandPath 'git.exe'
    if ($git) {
        # Handle Git cmd, bin, and mingw64/bin layouts.
        $directory = Split-Path -Parent $git
        foreach ($root in @($directory, (Split-Path -Parent $directory), (Split-Path -Parent (Split-Path -Parent $directory)))) {
            if ($root) { $candidates += (Join-Path $root 'bin\bash.exe') }
        }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not [IO.Path]::IsPathRooted($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ([IO.Path]::GetFileName($candidate) -ine 'bash.exe') { continue }
        try {
            $version = (& $candidate --version 2>$null | Out-String).Trim()
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0 -and $version -match 'GNU bash') { return [IO.Path]::GetFullPath($candidate) }
        } catch { throw }
    }
    return $null
}
function Ensure-GitBash {
    $bash = Find-GitBash
    if ($bash) { return $bash }
    $winget = Get-NativeCommandPath 'winget.exe'
    if (-not $winget) { Stop-Setup 'WINGET_MISSING' '未检测到 winget。请从 https://git-scm.com/download/win 安装 Git for Windows（包含 Git Bash）后重新运行。' }
    # Automatic dependency installation; retain any required system UAC authorization.
    try {
        # Git.Git --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
        $gitInstall = Invoke-PrivateProcess $winget @('install','--id','Git.Git','--exact','--source','winget','--accept-source-agreements','--accept-package-agreements','--silent','--disable-interactivity')
        $wingetExit = $gitInstall.ExitCode
    } catch { throw }
    if ($wingetExit -ne 0) { Stop-Setup 'GIT_INSTALL' ('winget 安装 Git 失败（退出码 ' + $wingetExit + '）。请从 https://git-scm.com/download/win 手动安装后重新运行。') }
    $script:Installation.git = 'installed-unverified'
    Refresh-ProcessPath
    $bash = Find-GitBash
    if (-not $bash) { throw '安装后未找到可用 Git Bash。请从 https://git-scm.com/download/win 安装或修复 Git for Windows，打开新终端后重新运行。' }
    return $bash
}
function Get-WorkingClaude {
    param([string]$Prefix, [string]$Npm)
    $candidates = @()
    foreach ($name in @('claude.cmd', 'claude.exe')) {
        $existing = Get-NativeCommandPath $name
        if ($existing) { $candidates += $existing }
    }
    # Search standard locations even when their directories are absent from PATH.
    $directories = @($Prefix)
    if ($env:USERPROFILE) { $directories += (Join-Path $env:USERPROFILE '.local\bin') }
    if ($env:APPDATA) { $directories += (Join-Path $env:APPDATA 'npm') }
    if ($env:LOCALAPPDATA) { $directories += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links') }
    if ($Npm) {
        try {
            $globalPrefix = (& $Npm prefix -g 2>$null | Out-String).Trim()
            $prefixExit = $LASTEXITCODE
            if ($prefixExit -eq 0 -and $globalPrefix -notmatch '[\r\n]' -and [IO.Path]::IsPathRooted($globalPrefix)) {
                $directories += $globalPrefix
            }
        } catch { throw }
    }
    foreach ($directory in @($directories | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        foreach ($name in @('claude.cmd', 'claude.exe')) {
            $candidates += (Join-Path $directory $name)
        }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $version = (& $candidate --version 2>$null | Out-String).Trim()
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0 -and $version -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\s+\(Claude Code\)(?:\s|$)') {
                return [PSCustomObject]@{ Path = $candidate; Version = $version }
            }
        } catch { throw }
    }
    return $null
}
function Repair-ManagedClaudeShim {
    param([string]$Prefix, [string]$ClaudePath)
    # Only rename npm's generated PS shim inside THIS installer's dedicated prefix.
    # Keep a backup and the working CMD shim; never change execution policy or other installs.
    $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'claude-gateway\npm')).TrimEnd('\')
    $resolvedPrefix = [IO.Path]::GetFullPath($Prefix).TrimEnd('\')
    if ($resolvedPrefix -ine $expected) { throw '安装目录与预期不一致，未修改启动入口。' }
    $cmd = [IO.Path]::GetFullPath((Join-Path $resolvedPrefix 'claude.cmd'))
    if ([IO.Path]::GetFullPath($ClaudePath) -ine $cmd) { return }
    $shim = [IO.Path]::GetFullPath((Join-Path $resolvedPrefix 'claude.ps1'))
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) { return }
    $directory = Get-Item -LiteralPath $resolvedPrefix -Force -ErrorAction Stop
    $item = Get-Item -LiteralPath $shim -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Directory.FullName.TrimEnd('\') -ine $resolvedPrefix) {
        throw '启动入口路径存在链接或异常，未修改。请使用 claude.cmd 启动。'
    }
    $content = [IO.File]::ReadAllText($shim)
    if ($content -notmatch '@anthropic-ai[/\\]claude-code' -or $content -notmatch 'basedir') {
        throw 'PowerShell 入口不是可识别的 npm 自动生成文件，未修改。请使用 claude.cmd 启动。'
    }
    $disabledName = 'claude.ps1.disabled-' + [DateTime]::Now.ToString('yyyyMMddHHmmss') + '-' + [Guid]::NewGuid().ToString('N')
    $backup = [IO.Path]::GetFullPath((Join-Path $resolvedPrefix $disabledName))
    if ([IO.Path]::GetDirectoryName($backup) -ine $resolvedPrefix -or (Test-Path -LiteralPath $backup)) {
        throw '启动入口备份路径异常，未修改。'
    }
    # The absolute source and backup paths above are verified before this rename.
    Rename-Item -LiteralPath $shim -NewName $disabledName -ErrorAction Stop
    $script:Installation.shim = 'backed-up'
}
function Initialize-NativeJsonScanner {
    if ('ClaudeGateway.StrictJson' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ClaudeGateway {
 public sealed class PreflightException : Exception {
  public string Code; public int Line; public int Column;
  public PreflightException(string code, int line, int column) : base(code) { Code=code; Line=line; Column=column; }
 }
 public sealed class StrictJson {
  string s; int i;
  StrictJson(string text) { s=text; }
  void Fail(string code) { int line=1,col=1; for(int n=0;n<i && n<s.Length;n++) { if(s[n]=='\n') { line++; col=1; } else col++; } throw new PreflightException(code,line,col); }
  void Space() { while(i<s.Length && (s[i]==' '||s[i]=='\t'||s[i]=='\r'||s[i]=='\n')) i++; }
  bool Eat(char c) { Space(); if(i<s.Length && s[i]==c) { i++; return true; } return false; }
  void Need(char c) { if(!Eat(c)) Fail("JSON_SYNTAX"); }
  string Str() {
   Need('"'); var b=new StringBuilder(); bool done=false;
   while(i<s.Length) { char c=s[i++]; if(c=='"') { done=true; break; } if(c<32) Fail("JSON_SYNTAX");
    if(c=='\\') { if(i>=s.Length) Fail("JSON_SYNTAX"); c=s[i++]; switch(c) {
     case '"': case '\\': case '/': b.Append(c); break;
     case 'b': b.Append('\b'); break; case 'f': b.Append('\f'); break;
     case 'n': b.Append('\n'); break; case 'r': b.Append('\r'); break; case 't': b.Append('\t'); break;
     case 'u': if(i+4>s.Length) Fail("JSON_SYNTAX"); int value; if(!Int32.TryParse(s.Substring(i,4),NumberStyles.AllowHexSpecifier,CultureInfo.InvariantCulture,out value)) Fail("JSON_SYNTAX"); b.Append((char)value); i+=4; break;
     default: Fail("JSON_SYNTAX"); break;
    } } else b.Append(c);
   }
   if(!done) Fail("JSON_SYNTAX"); return b.ToString();
  }
  object Value(int depth) {
   if(depth > 128) Fail("JSON_DEPTH"); Space(); if(i>=s.Length) { Fail("JSON_SYNTAX"); return null; }
   if(s[i]=='{') { i++; var d=new Dictionary<string,object>(StringComparer.Ordinal); if(Eat('}')) return d;
    do { Space(); if(i>=s.Length || s[i]!='"') Fail("JSON_SYNTAX"); string key=Str(); if(d.ContainsKey(key)) Fail("DUPLICATE_KEY"); Need(':'); d.Add(key,Value(depth+1)); if(Eat('}')) return d; Need(','); } while(true);
   }
   if(s[i]=='[') { i++; var a=new List<object>(); if(Eat(']')) return a; do { a.Add(Value(depth+1)); if(Eat(']')) return a; Need(','); } while(true); }
   if(s[i]=='"') return Str();
   foreach(string literal in new [] {"true","false","null"}) { if(i+literal.Length<=s.Length && s.Substring(i,literal.Length)==literal) { i+=literal.Length; if(literal=="null") return null; return literal=="true"; } }
   int start=i; if(s[i]=='-') i++; if(i>=s.Length) Fail("JSON_SYNTAX");
   if(s[i]=='0') i++; else { if(s[i]<'1'||s[i]>'9') Fail("JSON_SYNTAX"); while(i<s.Length && s[i]>='0'&&s[i]<='9') i++; }
   if(i<s.Length && s[i]=='.') { i++; int n=i; while(i<s.Length&&s[i]>='0'&&s[i]<='9') i++; if(n==i) Fail("JSON_SYNTAX"); }
   if(i<s.Length && (s[i]=='e'||s[i]=='E')) { i++; if(i<s.Length&&(s[i]=='+'||s[i]=='-')) i++; int n=i; while(i<s.Length&&s[i]>='0'&&s[i]<='9') i++; if(n==i) Fail("JSON_SYNTAX"); }
   double number; if(!Double.TryParse(s.Substring(start,i-start),NumberStyles.Float,CultureInfo.InvariantCulture,out number)||Double.IsInfinity(number)||Double.IsNaN(number)||(Math.Truncate(number)==number && Math.Abs(number)>9007199254740991d)) Fail("UNSAFE_NUMBER"); return number;
  }
  public static Dictionary<string,object> Parse(string text) {
   var p=new StrictJson(text.Length>0 && text[0]=='\uFEFF'?text.Substring(1):text); object root=p.Value(0); p.Space(); if(p.i!=p.s.Length) p.Fail("JSON_SYNTAX");
   var d=root as Dictionary<string,object>; if(d==null) p.Fail("CONFIG_ROOT"); if(d.ContainsKey("env") && !(d["env"] is Dictionary<string,object>)) p.Fail("CONFIG_ENV"); return d;
  }
 }
 public static class FileIdentity {
  [StructLayout(LayoutKind.Sequential)] public struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
   public uint Volume,SizeHigh,SizeLow,NumberOfLinks,IndexHigh,IndexLow;
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
  public static Info Get(FileStream file) { Info info; if(!GetFileInformationByHandle(file.SafeFileHandle,out info)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); return info; }
 }
}
'@ -ErrorAction Stop
}
function Stop-Setup {
    param([string]$Code, [string]$Reason, [string]$Stage = $script:Stage)
    $exception = New-Object System.InvalidOperationException($Reason)
    $exception.Data['code'] = $Code
    $exception.Data['stage'] = $Stage
    throw $exception
}
function Test-NoConfigLinks {
    param([string]$Target)
    $current = $Target
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue -ErrorVariable itemError
        if ($null -ne $item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Setup 'CONFIG_LINK' '配置路径不能包含链接或联接。' }
            if ($current -ine $Target -and -not $item.PSIsContainer) { Stop-Setup 'CONFIG_PATH' '配置上级路径不是目录。' }
        } elseif ($itemError -and $itemError[0].CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw $itemError[0] }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Add-DiagnosticSecrets {
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 128) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -match '(?i)token|key|password|secret' -and $entry.Value -is [string] -and $entry.Value.Length -gt 0) { [void]$script:Secrets.Add($entry.Value) }
            elseif ($entry.Value -isnot [string]) { Add-DiagnosticSecrets $entry.Value ($Depth + 1) }
        }
    } elseif ($Value -is [System.Collections.IList]) {
        foreach ($child in $Value) { Add-DiagnosticSecrets $child ($Depth + 1) }
    }
}
function Get-NativeConfigPreflight {
    $directory = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($directory)) {
        if (-not $env:USERPROFILE) { Stop-Setup 'CONFIG_PATH' '无法确定当前用户配置目录。' }
        $directory = Join-Path $env:USERPROFILE '.claude'
    }
    # Drive-relative, root-relative, UNC and device paths are not local absolute paths.
    if ($directory -notmatch '^[A-Za-z]:[\\/]' -or $directory.Substring(2).Contains(':')) { Stop-Setup 'CONFIG_PATH' 'CLAUDE_CONFIG_DIR 必须是本地绝对目录，不能使用 UNC 或设备路径。' }
    $target = [IO.Path]::GetFullPath((Join-Path $directory 'settings.json'))
    Test-NoConfigLinks $target
    Initialize-NativeJsonScanner
    $digest = $null
    $settings = [ClaudeGateway.StrictJson]::Parse('{}')
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -gt 2097152) { Stop-Setup 'CONFIG_FILE' '配置必须是最大 2 MB 的普通文件。' }
        $stream = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $identity = [ClaudeGateway.FileIdentity]::Get($stream)
            if ($identity.NumberOfLinks -ne 1 -or ($identity.Attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Setup 'CONFIG_LINK' '配置文件不能是链接、联接或硬链接。' }
            if ($stream.Length -gt 2097152) { Stop-Setup 'CONFIG_FILE' '配置文件超过 2 MB。' }
            $bytes = New-Object byte[] ([int]$stream.Length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($count -eq 0) { Stop-Setup 'CONFIG_CHANGED' '读取配置时文件发生变化，请重试。' }
                $offset += $count
            }
            $after = [ClaudeGateway.FileIdentity]::Get($stream)
            if ($after.NumberOfLinks -ne 1 -or $after.IndexHigh -ne $identity.IndexHigh -or $after.IndexLow -ne $identity.IndexLow -or $stream.Length -ne $bytes.Length) { Stop-Setup 'CONFIG_CHANGED' '读取配置时文件发生变化，请重试。' }
            try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
            catch [System.Text.DecoderFallbackException] { Stop-Setup 'CONFIG_UTF8' '配置不是有效的 UTF-8 编码。' }
            $settings = [ClaudeGateway.StrictJson]::Parse($text)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        } finally { $stream.Dispose(); $text = $null; $bytes = $null }
        Test-NoConfigLinks $target
    }
    Add-DiagnosticSecrets $settings
    $existing = $null
    if ($settings.ContainsKey('env')) {
        $configEnv = $settings['env']
        # Collect every credential-like setting for diagnostic redaction, not just selected auth.
        foreach ($entry in $configEnv.GetEnumerator()) {
            if ($entry.Key -match '(?i)token|key|password|secret' -and $entry.Value -is [string] -and $entry.Value.Length -gt 0) { [void]$script:Secrets.Add($entry.Value) }
        }
        if ($configEnv.ContainsKey('ANTHROPIC_BASE_URL') -and $configEnv['ANTHROPIC_BASE_URL'] -is [string] -and $configEnv['ANTHROPIC_BASE_URL'] -ceq (ConvertTo-GatewayOrigin) -and $configEnv.ContainsKey('ANTHROPIC_AUTH_TOKEN') -and $configEnv['ANTHROPIC_AUTH_TOKEN'] -is [string] -and $configEnv['ANTHROPIC_AUTH_TOKEN'].Trim().Length -gt 0) { $existing = $configEnv['ANTHROPIC_AUTH_TOKEN'].Trim() }
    }
    return [PSCustomObject]@{ Target = $target; ExpectedDigest = $digest; ExistingToken = $existing }
}
function Test-PackageIntegrity {
    $common = $PSScriptRoot
    foreach ($file in @((Join-Path $PSScriptRoot 'Setup.ps1'), (Join-Path $common 'configure.cjs'), (Join-Path $common 'dialogs.cjs'), (Join-Path $common 'key-dialog.ps1'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Setup 'PACKAGE_MISSING' '安装包不完整，请完整解压后重新运行。' }
        Test-NoConfigLinks ([IO.Path]::GetFullPath($file))
        if ((Get-Item -LiteralPath $file -Force).Length -eq 0) { Stop-Setup 'PACKAGE_EMPTY' '安装包中存在空文件，请重新解压。' }
    }
    $configureText = [IO.File]::ReadAllText((Join-Path $common 'configure.cjs'), (New-Object System.Text.UTF8Encoding($false, $true)))
    if (-not $configureText.Contains('--prepared-stdin')) { Stop-Setup 'PACKAGE_PROTOCOL' '配置程序不支持当前预检接口，请使用完整匹配的安装包。' }
    return [PSCustomObject]@{ Configure = (Join-Path $common 'configure.cjs'); Dialog = (Join-Path $common 'key-dialog.ps1') }
}
function ConvertTo-WindowsArgument {
    param([string]$Value)
    # CommandLineToArgvW escaping, including trailing backslashes; never used for a key.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-PrivateProcess {
    param([string]$File, [string[]]$Arguments, [AllowNull()][string]$InputJson = $null, [switch]$ConfigurationWrite)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $script:ToolExitCode = $null; $script:ToolStderr = ''
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ([IO.Path]::GetExtension($File) -ieq '.cmd') {
        # npm.cmd remains the existing channel. Only trusted fixed args/local paths enter cmd.
        foreach ($argument in @($File) + $Arguments) {
            if ($argument -match '["%\r\n]') { Stop-Setup 'TOOL_ARGUMENT' '工具路径或参数含不安全的 CMD 字符。' }
        }
        $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $start.Arguments = '/d /s /c "' + (ConvertTo-WindowsArgument $File) + ' ' + (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ') + '"'
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        if ($ConfigurationWrite) { $script:ConfigState = 'unknown' }
        # Start both readers BEFORE stdin writes or WaitForExit: no pipe-buffer deadlock.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writeError = $null
        try { if ($null -ne $InputJson) { $process.StandardInput.Write($InputJson) } }
        catch { $writeError = $_ }
        finally { $process.StandardInput.Close() }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $script:ToolExitCode = $process.ExitCode
        $script:ToolStderr = Protect-DiagnosticText $stderr
        if ($null -ne $writeError) { throw $writeError }
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $script:ToolStderr }
    } finally { $process.Dispose(); $InputJson = $null; $stdout = $null; $stderr = $null }
}
function Invoke-KeyDialog {
    param([string]$Helper, [ValidateSet('choice','secret')][string]$Mode)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $result = Invoke-PrivateProcess $ps @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$Helper,'-Mode',$Mode)
    if ($result.ExitCode -ne 0) { Stop-Setup 'DIALOG_EXIT' '密钥窗口未正常结束。' }
    try { $answer = ConvertFrom-Json -InputObject $result.Stdout -ErrorAction Stop }
    catch { Stop-Setup 'DIALOG_PROTOCOL' '无法读取密钥窗口结果。' }
    if ($null -eq $answer -or $answer -is [array] -or -not $answer.PSObject.Properties['action']) { Stop-Setup 'DIALOG_PROTOCOL' '密钥窗口返回格式无效。' }
    if ($answer.action -eq 'error') {
        if ($answer.PSObject.Properties['diagnostic']) { $script:ExternalDiagnostic = ConvertTo-SafeExternalDiagnostic $answer.diagnostic }
        Stop-Setup 'DIALOG_FAILED' '密钥窗口操作失败。'
    }
    if (($Mode -eq 'choice' -and $answer.action -notin @('keep','replace','cancel')) -or ($Mode -eq 'secret' -and $answer.action -notin @('set','cancel'))) { Stop-Setup 'DIALOG_PROTOCOL' '密钥窗口返回未知操作。' }
    return $answer
}
function Select-GatewayToken {
    param($Preflight, [string]$Helper)
    if ($null -ne $Preflight.ExistingToken) {
        $choice = Invoke-KeyDialog $Helper 'choice'
        if ($choice.action -eq 'cancel') { return @{ action = 'cancel' } }
        if ($choice.action -eq 'keep') { return @{ action = 'set'; token = $Preflight.ExistingToken } }
    }
    return (Invoke-KeyDialog $Helper 'secret')
}
function Confirm-DependencyInstall {
    param([string[]]$Dependencies)
    if ($Dependencies.Count -eq 0) { return $true }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $message = '需要安装：' + ($Dependencies -join '、') + '。是否继续？'
    return ([System.Windows.Forms.MessageBox]::Show($message, '安装依赖', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::OK)
}
function Protect-DiagnosticText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    foreach ($secret in @($script:Secrets | Sort-Object { $_.Length } -Descending)) {
        if ($secret.Length -gt 0) {
            $Text = $Text.Replace($secret, '[REDACTED]')
            $encoded = ConvertTo-Json -InputObject $secret -Compress
            if ($encoded.Length -gt 2) { $Text = $Text.Replace($encoded.Substring(1, $encoded.Length - 2), '[REDACTED]') }
        }
    }
    $Text = [regex]::Replace($Text, '(?i)(Bearer\s+)[^\s"\x27,;]+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)((?:token|api[_-]?key|password|secret)["\x27]?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|[^\s,}]+)', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '?')
    if ($Text.Length -gt 12000) { $Text = $Text.Substring(0, 12000) + ' [truncated]' }
    return $Text
}
function ConvertTo-SafeExternalDiagnostic {
    param($Diagnostic)
    $safe = [ordered]@{ code = 'TOOL_DIAGNOSTIC'; stage = $script:Stage; reason = '工具返回错误。'; state = 'unknown' }
    if ($null -eq $Diagnostic -or $Diagnostic -is [array] -or $Diagnostic -is [string]) { return $safe }
    if ($Diagnostic.PSObject.Properties['code'] -and $Diagnostic.code -is [string] -and $Diagnostic.code -cmatch '^[A-Z0-9_-]{1,80}$') { $safe.code = $Diagnostic.code }
    if ($Diagnostic.PSObject.Properties['stage'] -and $Diagnostic.stage -is [string] -and $Diagnostic.stage -cmatch '^[a-z0-9_-]{1,80}$') { $safe.stage = $Diagnostic.stage }
    if ($Diagnostic.PSObject.Properties['state'] -and $Diagnostic.state -cin @('unchanged','saving','saved','unknown')) { $safe.state = $Diagnostic.state }
    foreach ($name in @('reason','type','stderr')) {
        if ($Diagnostic.PSObject.Properties[$name] -and $Diagnostic.$name -is [string]) { $safe[$name] = Protect-DiagnosticText $Diagnostic.$name }
    }
    foreach ($name in @('line','column','HResult','exitCode')) {
        if ($Diagnostic.PSObject.Properties[$name] -and ($null -eq $Diagnostic.$name -or $Diagnostic.$name -is [int] -or $Diagnostic.$name -is [long])) { $safe[$name] = $Diagnostic.$name }
    }
    return $safe
}
function Get-CurrentPathState {
    $user = 'unchanged'; $machine = 'unchanged'; $process = 'unchanged'
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $script:OriginalUserPath) { $user = 'changed' }
    if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -cne $script:OriginalMachinePath) { $machine = 'changed' }
    if ($env:PATH -cne $script:OriginalProcessPath) { $process = 'changed' }
    return [ordered]@{ user = $user; machine = $machine; process = $process; requested = $script:PathState }
}
function Show-SetupDiagnostic {
    param($Record)
    $exception = $Record.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $code = 'WINDOWS_UNEXPECTED'
    if ($exception.Data.Contains('code')) { $code = $exception.Data['code'] }
    $line = $null; $column = $null
    if ($exception.GetType().FullName -eq 'ClaudeGateway.PreflightException') { $code = $exception.Code; $line = $exception.Line; $column = $exception.Column }
    $reason = Protect-DiagnosticText $exception.Message
    $stage = $script:Stage
    if ($exception.Data.Contains('stage')) { $stage = $exception.Data['stage'] }
    $diagnostic = [ordered]@{ code = $code; stage = $stage; reason = $reason; type = $exception.GetType().FullName; HResult = $exception.HResult; line = $line; column = $column; state = $script:ConfigState; installation = $script:Installation; PATHstate = (Get-CurrentPathState); exitCode = $script:ToolExitCode; stderr = $script:ToolStderr }
    if ($null -ne $script:ExternalDiagnostic) { $diagnostic['toolDiagnostic'] = $script:ExternalDiagnostic }
    $text = ConvertTo-Json -InputObject $diagnostic -Depth 8
    Write-Host ('错误：' + $reason) -ForegroundColor Red
    Write-Host $text
    $form = $null; $font = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $form = New-Object System.Windows.Forms.Form
        $form.Text = '安装配置诊断'; $form.StartPosition = 'CenterScreen'; $form.Width = 740; $form.Height = 500
        $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10); $form.Font = $font
        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.SetBounds(16,16,690,380); $box.Anchor = 'Top,Bottom,Left,Right'; $box.Text = $text
        [void]$form.Controls.Add($box)
        $copy = New-Object System.Windows.Forms.Button; $copy.Text = '复制诊断信息'; $copy.SetBounds(390,410,165,32); $copy.Anchor = 'Bottom,Right'
        $copy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($box.Text) } catch { [void][System.Windows.Forms.MessageBox]::Show('复制失败，可选中文本后按 Ctrl+C。', '诊断信息') } })
        [void]$form.Controls.Add($copy)
        $close = New-Object System.Windows.Forms.Button; $close.Text = '关闭'; $close.SetBounds(570,410,130,32); $close.Anchor = 'Bottom,Right'; $close.DialogResult = 'Cancel'
        [void]$form.Controls.Add($close); $form.CancelButton = $close
        [void]$form.ShowDialog()
    } catch { Write-Host ('诊断窗口未能打开：reason=' + (Protect-DiagnosticText $_.Exception.Message) + '; type=' + $_.Exception.GetType().FullName + '; HResult=' + $_.Exception.HResult) -ForegroundColor Yellow }
    finally { if ($null -ne $form) { $form.Dispose() }; if ($null -ne $font) { $font.Dispose() } }
}
function Invoke-PreparedConfiguration {
    param($Runtime, [string]$Configure, $Preflight, [string]$Token)
    $payload = ConvertTo-Json -InputObject @{ token = $Token; target = $Preflight.Target; expectedDigest = $Preflight.ExpectedDigest } -Compress
    # After launch, an interrupted/invalid response cannot safely imply no saved configuration.
    try { $result = Invoke-PrivateProcess $Runtime.Node @($Configure, '--prepared-stdin') $payload -ConfigurationWrite }
    finally { $payload = $null }
    try { $answer = ConvertFrom-Json -InputObject $result.Stdout -ErrorAction Stop }
    catch { Stop-Setup 'CONFIG_PROTOCOL' '配置程序返回格式无效，保存状态未知。' }
    if ($null -eq $answer -or $answer -is [array] -or -not $answer.PSObject.Properties['ok'] -or $answer.ok -isnot [bool]) { Stop-Setup 'CONFIG_PROTOCOL' '配置程序返回格式无效，保存状态未知。' }
    if (-not $answer.ok) {
        if ($answer.PSObject.Properties['diagnostic']) {
            $script:ExternalDiagnostic = ConvertTo-SafeExternalDiagnostic $answer.diagnostic
            $script:ConfigState = $script:ExternalDiagnostic.state
        }
        if ($null -ne $script:ExternalDiagnostic) { Stop-Setup $script:ExternalDiagnostic.code $script:ExternalDiagnostic.reason $script:ExternalDiagnostic.stage }
        Stop-Setup 'CONFIG_FAILED' '配置程序未返回诊断，保存状态未知。'
    }
    if (-not $answer.PSObject.Properties['state'] -or $answer.state -cne 'saved' -or -not $answer.PSObject.Properties['target'] -or $answer.target -isnot [string] -or $answer.target -ine $Preflight.Target -or -not $answer.PSObject.Properties['verified'] -or $answer.verified -isnot [bool] -or $answer.verified -ne $false -or -not $answer.PSObject.Properties['warnings'] -or $answer.warnings -isnot [array]) { Stop-Setup 'CONFIG_PROTOCOL' '配置程序成功响应不完整，保存状态未知。' }
    $script:ConfigState = 'saved'
    if (-not $answer.PSObject.Properties['backup'] -or ($null -ne $answer.backup -and $answer.backup -isnot [string])) { Stop-Setup 'CONFIG_PROTOCOL' '配置已保存，但备份响应格式无效。' }
    if ($result.ExitCode -ne 0) { Stop-Setup 'CONFIG_EXIT' '配置已保存，但配置工具退出异常。' }
    foreach ($warning in $answer.warnings) { if ($warning -isnot [string]) { Stop-Setup 'CONFIG_PROTOCOL' '配置已保存，但警告格式无效。' }; Write-Host (Protect-DiagnosticText $warning) -ForegroundColor Yellow }
}
function Invoke-ClaudeGatewaySetup {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $script:SetupExitCode = 1
    $script:Stage = 'package-preflight'
    $script:ConfigState = 'unchanged'
    $script:PathState = 'unchanged'
    $script:Installation = [ordered]@{ node = 'not-started'; git = 'not-started'; claude = 'not-started'; shim = 'unchanged'; gitEnvironment = 'unchanged' }
    $script:ToolExitCode = $null; $script:ToolStderr = ''; $script:ExternalDiagnostic = $null
    $script:Secrets = New-Object 'System.Collections.Generic.List[string]'
    Add-DiagnosticSecrets ([Environment]::GetEnvironmentVariables())
    $selection = $null; $preflight = $null; $token = $null
    $originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $originalMachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $script:OriginalUserPath = $originalUserPath
    $script:OriginalMachinePath = $originalMachinePath
    $script:OriginalProcessPath = $env:PATH
    try {
        $env:AI_GATEWAY_URL = ConvertTo-GatewayOrigin
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = $utf8; [Console]::InputEncoding = $utf8; $OutputEncoding = $utf8
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Write-Host '正在检查配置……' -ForegroundColor Cyan
        $package = Test-PackageIntegrity
        $script:Stage = 'config-preflight'
        $preflight = Get-NativeConfigPreflight
        $script:Stage = 'key-selection'
        $selection = Select-GatewayToken $preflight $package.Dialog
        if ($selection.action -eq 'cancel') { $script:SetupExitCode = 0; return }
        if (-not (($selection -is [System.Collections.IDictionary] -and $selection.Contains('token')) -or $selection.PSObject.Properties['token'])) { Stop-Setup 'TOKEN_INVALID' '密钥窗口未返回密钥。' }
        $token = $selection.token
        if ($token -isnot [string] -or $token.Length -eq 0 -or $token.Length -gt 8192 -or [regex]::IsMatch($token, '[\s\p{Cc}]')) { Stop-Setup 'TOKEN_INVALID' '网关密钥为空、过长或含空白/控制字符，请输入新密钥。' }
        [void]$script:Secrets.Add($token)
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Stop-Setup 'INSTALL_PATH' '无法确定当前用户 LOCALAPPDATA。' }
        $architecture = Get-WindowsArchitecture
        $script:Stage = 'dependency-check'
        $runtime = Get-NodeRuntime
        $bash = Find-GitBash
        $prefix = Join-Path $env:LOCALAPPDATA 'claude-gateway\npm'
        $npm = $null; if ($null -ne $runtime) { $npm = $runtime.Npm }
        $claude = Get-WorkingClaude -Prefix $prefix -Npm $npm
        $missing = @()
        if ($null -eq $runtime) { $missing += 'Node.js 22+ LTS' } else { $script:Installation.node = 'existing' }
        if (-not $bash) { $missing += 'Git for Windows' } else { $script:Installation.git = 'existing' }
        if ($null -eq $claude) { $missing += 'Claude Code' } else { $script:Installation.claude = 'existing' }
        if (-not (Confirm-DependencyInstall $missing)) { $script:SetupExitCode = 0; return }
        if ($missing.Count -gt 0) { Write-Host '正在安装所需依赖……' -ForegroundColor Cyan }
        $script:Stage = 'node-install'
        if ($null -eq $runtime) { $script:Installation.node = 'started'; $runtime = Install-NodeLts -Architecture $architecture; $script:Installation.node = 'installed' }
        Add-ProcessPath @((Split-Path -Parent $runtime.Node))
        $script:Stage = 'git-install'
        if (-not $bash) { $script:Installation.git = 'started'; $bash = Ensure-GitBash; $script:Installation.git = 'installed' }
        Add-ProcessPath @((Split-Path -Parent $runtime.Node))
        $script:Stage = 'claude-install'
        # Recheck after installing Node: a pre-existing npm-managed command may now work.
        if ($null -eq $claude) { $claude = Get-WorkingClaude -Prefix $prefix -Npm $runtime.Npm }
        if ($null -eq $claude) {
            $script:Installation.claude = 'started'
            [void](New-Item -ItemType Directory -Path $prefix -Force -ErrorAction Stop)
            $install = Invoke-PrivateProcess $runtime.Npm @('install','-g','@anthropic-ai/claude-code@latest','--registry=https://registry.npmjs.org','--allow-scripts=@anthropic-ai/claude-code','--ignore-scripts=false','--engine-strict','--fetch-retries=1','--fetch-timeout=60000','--silent','--no-fund','--no-audit','--prefix',$prefix)
            if ($install.ExitCode -ne 0) { Stop-Setup 'NPM_INSTALL' 'Claude Code npm 安装未完成。' }
            $script:Installation.claude = 'installed'
            Add-ProcessPath @($prefix)
            $claude = Get-WorkingClaude -Prefix $prefix -Npm $runtime.Npm
            if ($null -eq $claude) { Stop-Setup 'CLAUDE_IDENTITY' '安装后 Claude Code 身份/版本检查失败。' }
        } elseif ($script:Installation.claude -eq 'not-started') { $script:Installation.claude = 'existing' }
        $script:Stage = 'shim-repair'
        Repair-ManagedClaudeShim -Prefix $prefix -ClaudePath $claude.Path
        $script:Stage = 'environment-save'
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'User')
        $script:Installation.gitEnvironment = 'saved'
        $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
        Add-UserPath -Directory (Split-Path -Parent $claude.Path)
        Add-UserPath -Directory (Split-Path -Parent $runtime.Node)
        $script:PathState = 'saved'
        Send-EnvironmentChange
        $script:Stage = 'config-save'
        Write-Host '正在保存配置……' -ForegroundColor Cyan
        Invoke-PreparedConfiguration $runtime $package.Configure $preflight $token
        Write-Host '配置已保存，未验证网关密钥或模型。' -ForegroundColor Cyan
        Write-Host '配置完成。请在项目目录打开新终端，运行 claude。' -ForegroundColor Green
        $script:SetupExitCode = 0
    } catch {
        $failure = $_
        $nativeException = $failure.Exception
        while ($null -ne $nativeException.InnerException) { $nativeException = $nativeException.InnerException }
        if ($script:Stage -eq 'node-install' -and $nativeException -is [System.ComponentModel.Win32Exception] -and $nativeException.NativeErrorCode -eq 1223) {
            Write-Host '已取消安装。已完成的更改保留。'
            $script:SetupExitCode = 0; return
        }
        if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $originalUserPath -or [Environment]::GetEnvironmentVariable('Path', 'Machine') -cne $originalMachinePath) { $script:PathState = 'changed' }
        Show-SetupDiagnostic $failure
        $script:SetupExitCode = 1
    } finally {
        $token = $null; $selection = $null; $preflight = $null; $script:Secrets.Clear()
    }
}
# Dot sourcing defines functions only: no UI, downloads, configuration or persistent changes.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ClaudeGatewaySetup
    exit $script:SetupExitCode
}
