# Windows PowerShell 5.1; deliberately conservative TOML subset. No GUI or live paths here.
Set-StrictMode -Version 2.0

# Diagnostics never include ErrorRecord/stack/source lines, response bodies or configuration values.
# Display exception messages after removing credentials and suspected configuration fragments.
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

function Protect-DiagnosticText([string]$Text,[string]$Key='') {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # A message containing assignments/tables/JSON may be a configuration dump: omit the whole fragment.
    if ($Text -match '(?m)(?:^|\s)[A-Za-z0-9_-]+\s*=' -or $Text -match '(?m)^\s*\[[^\r\n]*\]\s*$' -or $Text -match '"[^"\r\n]+"\s*:') {
        return '异常消息包含配置格式内容，已移除该内容'
    }
    $safe=$Text
    if (-not [string]::IsNullOrEmpty($Key)) {
        $variants=@($Key,$Key.Replace('"','\"'),$Key.Replace('`','``').Replace('"','`"'),$Key.Replace("'","''"))
        try {
            $toml=ConvertTo-TomlString $Key
            $variants+=@($toml,$toml.Substring(1,$toml.Length-2))
        } catch { }
        foreach ($value in @($variants | Sort-Object { $_.Length } -Descending | Select-Object -Unique)) {
            if (-not [string]::IsNullOrEmpty($value)) { $safe=$safe.Replace($value,'[已移除密钥]') }
        }
    }
    $safe=[regex]::Replace($safe,'(?im)\bAuthorization\s*[:=]\s*[^\r\n]*','[已移除认证信息]')
    $safe=[regex]::Replace($safe,'(?i)\bBearer\s+\S+','[已移除认证信息]')
    $safe=[regex]::Replace($safe,'(?im)\b(?:experimental_bearer_token|api[_-]?key|token|secret|password)\b\s*[:=]\s*[^\r\n]*','[已移除敏感字段]')
    # Keep messages readable, but never let embedded control characters change the diagnostic layout.
    return ([regex]::Replace($safe,'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]','?'))
}
function Get-SafeExceptionDetail([System.Exception]$Exception,[string]$Key='') {
    if ($null -eq $Exception) { return [pscustomobject]@{ Reason='未提供异常对象'; Type='(无异常对象)'; HResult=0; Line=$null } }
    $reasons=@{
        'Unsupported table path'='不支持的 TOML 表路径'
        'Unsupported TOML syntax'='不支持的 TOML 语法'
        'Unsupported TOML value'='不支持的 TOML 值类型'
        'Unsupported TOML array'='不支持的 TOML 数组'
        'Unsupported TOML array element'='数组包含非字符串元素'
        'Unclosed or multiline string'='字符串未闭合或为多行字符串'
        'Unsupported TOML string'='不支持的 TOML 字符串'
        'Invalid TOML string'='字符串引号或控制字符无效'
        'Invalid TOML escape'='字符串转义无效'
        'Invalid TOML Unicode escape'='Unicode 转义无效'
        'Invalid Unicode scalar'='Unicode 码点无效'
        'Invalid control character'='存在无效控制字符'
        'Unclosed array string'='数组字符串未闭合'
        'Invalid array separator'='数组分隔符无效'
        'Model must be a string'='model 必须是字符串'
        'Duplicate table'='重复的 TOML 表'
        'Duplicate key or table conflict'='重复键或键与表冲突'
        'Table conflicts with key'='表与已有键冲突'
        'Unsupported TOML line ending'='不支持的换行符或空字符'
        'Unsupported directory link in configuration path'='配置目录链包含链接或重解析点'
        'Unsupported config link'='配置文件是链接或重解析点'
        'Unsupported network configuration drive'='不支持网络配置驱动器'
        'Invalid or network CODEX_HOME'='CODEX_HOME 不是受支持的本地绝对目录路径'
        'Invalid USERPROFILE'='USERPROFILE 无效，无法确定默认配置目录'
        'Configuration path component is not a directory'='配置目录链被同名文件占用'
        'Configuration changed during setup'='配置在读取后被其他操作修改，已停止覆盖'
        'Could not verify private configuration ACL'='无法验证配置文件的私有 ACL'
        'Empty key'='密钥为空'
        'Invalid Unicode key'='密钥包含无效 Unicode 序列'
        'Codex started during setup'='Codex 在配置期间启动；未启动新实例，请自行重启以加载配置'
        'Codex application not found'='未检测到可启动的 Codex；请自行打开应用'
    }
    $cause=$Exception; $line=$null; $known=$null
    while ($null -ne $cause) {
        if ($cause.Data.Contains('TomlLine')) { $line=[int]$cause.Data['TomlLine'] }
        if ($reasons.ContainsKey($cause.Message)) { $known=$cause; break }
        if ($null -eq $cause.InnerException) { break }
        $cause=$cause.InnerException
    }
    $reason=Protect-DiagnosticText $cause.Message $Key
    if ([string]::IsNullOrEmpty($reason)) { $reason='异常消息为空；请按阶段、异常类型与 HResult 定位' }
    if ($null -ne $known) { $reason=$reasons[$known.Message]+' ['+$known.Message+']' }
    elseif ($cause -is [Text.DecoderFallbackException]) { $reason='配置不是有效 UTF-8；严格解码失败' }
    elseif ($cause -is [ComponentModel.Win32Exception]) {
        # FormatMessage uses only the numeric OS code, not an untrusted supplied message.
        $osError=New-Object ComponentModel.Win32Exception($cause.NativeErrorCode)
        $reason=('Windows 错误 {0}: {1}' -f $cause.NativeErrorCode,$osError.Message)
    }
    elseif ($cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException] -or $cause -is [Security.SecurityException]) {
        $osCode=$cause.HResult -band 0xffff
        $osError=New-Object ComponentModel.Win32Exception($osCode)
        $reason=('文件/权限错误 {0}: {1}' -f $osCode,$osError.Message)
    }
    elseif ($cause -is [Net.WebException]) { $reason='网络异常: '+$cause.Status.ToString() }
    elseif ($cause -is [ArgumentException]) { $reason='参数无效：'+$reason }
    elseif ($cause -is [NotSupportedException]) { $reason='操作不受支持：'+$reason }
    return [pscustomobject]@{ Reason=$reason; Type=$cause.GetType().FullName; HResult=$cause.HResult; Line=$line }
}
function New-SaveState {
    return [pscustomobject]@{ Started=$false; BackupCreated=$false; PermissionsMayHaveChanged=$false; ReplacementAttempted=$false; ContentSaved=$false }
}
function Get-ConfigStateText($State) {
    if ($null -eq $State -or -not $State.Started) { return '未保存：配置内容与权限未由本工具修改。' }
    $text=if ($State.ContentSaved) { '已保存：新配置内容已写入；后续步骤失败不代表配置未保存。' }
          elseif ($State.ReplacementAttempted) { '保存结果未确认：已尝试原子替换/移动，配置内容可能已保存；请检查配置状态。' }
          else { '未保存：尚未写入新配置内容。' }
    if ($State.PermissionsMayHaveChanged) { $text+=' 原文件权限可能已修改。' }
    if ($State.BackupCreated) { $text+=' 已生成原内容备份。' }
    elseif (-not $State.ContentSaved) { $text+=' 可能生成临时文件或不完整备份，请检查同目录文件。' }
    return $text
}
function Get-SetupDiagnostic([System.Exception]$Exception,[string]$Stage,$State,[string]$Reason='',[string]$Code='',[string]$Key='') {
    $stages=@{ path=@('W001','配置路径'); read=@('W002','读取配置'); parse=@('W003','解析配置'); build=@('W004','生成配置'); save=@('W005','保存配置'); verify=@('W006','验证网关'); launch=@('W007','启动 Codex'); setup=@('W008','初始化/设置'); 'app-check'=@('W009','应用检测/运行检查'); key=@('W010','密钥选择/输入') }
    $entry=$stages[$Stage]; if ($null -eq $entry) { $entry=$stages['setup'] }
    if ([string]::IsNullOrEmpty($Code)) { $Code=$entry[0] }
    $detail=Get-SafeExceptionDetail $Exception $Key
    if ([string]::IsNullOrEmpty($Reason)) { $Reason=$detail.Reason }
    $Reason=Protect-DiagnosticText $Reason $Key
    $text=("编号：{0}`r`n阶段：{1} ({2})`r`n原因：{3}`r`n异常：{4}; HResult={5}" -f $Code,$entry[1],$Stage,$Reason,$detail.Type,$detail.HResult)
    if ($null -ne $detail.Line) { $text+="`r`nTOML 行号："+$detail.Line+'（不显示行文本）' }
    return ($text+"`r`n配置状态："+(Get-ConfigStateText $State))
}
# Pure HTTP/transport classification for synthetic regression tests. Never consume response bodies.
function Get-GatewayResult([int]$StatusCode=0,[string]$TransportStatus='',[System.Exception]$Exception=$null) {
    if ($StatusCode -ge 200 -and $StatusCode -lt 300) { return [pscustomobject]@{ Success=$true; Code=''; Reason=''; Exception=$null } }
    if ($StatusCode -gt 0) {
        $meaning=switch ($StatusCode) {
            401 { '密钥未通过认证' }; 403 { '访问被拒绝' }; 404 { '验证接口不存在' }; 429 { '请求限流' }
            { $_ -ge 300 -and $_ -lt 400 } { '返回重定向；本工具不跟随重定向' }
            { $_ -ge 500 } { '网关服务端错误' }; default { '请求未成功' }
        }
        $reason=('HTTP {0}：{1}' -f $StatusCode,$meaning); $code='W006-HTTP-'+$StatusCode
    } else {
        $meaning=switch ($TransportStatus) {
            'Timeout' { '请求超时' }; 'ConnectFailure' { '无法连接网关或代理' }
            'NameResolutionFailure' { '网关 DNS 解析失败' }; 'ProxyNameResolutionFailure' { '代理 DNS 解析失败' }
            'TrustFailure' { 'TLS 证书信任验证失败' }; 'SecureChannelFailure' { 'TLS 安全通道建立失败' }
            'ConnectionClosed' { '连接被关闭' }; 'ReceiveFailure' { '接收响应失败' }; 'SendFailure' { '发送请求失败' }
            default { '验证请求异常' }
        }
        $reason=$meaning
        if (-not [string]::IsNullOrEmpty($TransportStatus)) { $reason+=' ['+$TransportStatus+']' }
        if ($null -ne $Exception) { $reason+='；'+(Get-SafeExceptionDetail $Exception).Reason }
        $code='W006-NET'
    }
    if ($null -eq $Exception) { $Exception=New-Object System.Exception('Gateway request failed') }
    return [pscustomobject]@{ Success=$false; Code=$code; Reason=$reason; Exception=$Exception }
}

function Decode-TomlString([string]$Value) {
    if ($Value.Length -lt 2) { throw 'Unsupported TOML string' }
    $quote = $Value[0]
    if (($quote -ne '"' -and $quote -ne "'") -or $Value[$Value.Length-1] -ne $quote) { throw 'Unsupported TOML string' }
    $b = New-Object System.Text.StringBuilder
    for ($i=1; $i -lt $Value.Length-1; $i++) {
        $c = $Value[$i]
        if ([int]$c -lt 32 -or [int]$c -eq 127 -or $c -eq $quote) { throw 'Invalid TOML string' }
        if ($quote -eq '"' -and $c -eq '\') {
            $i++; if ($i -ge $Value.Length-1) { throw 'Invalid TOML escape' }
            $e = $Value[$i]
            switch -CaseSensitive ($e) {
                '"' { [void]$b.Append('"') }
                '\' { [void]$b.Append('\') }
                'b' { [void]$b.Append([char]8) }
                't' { [void]$b.Append([char]9) }
                'n' { [void]$b.Append([char]10) }
                'f' { [void]$b.Append([char]12) }
                'r' { [void]$b.Append([char]13) }
                { $_ -ceq 'u' -or $_ -ceq 'U' } {
                    $count = if ($e -ceq 'u') { 4 } else { 8 }
                    if ($i+$count -ge $Value.Length) { throw 'Invalid TOML Unicode escape' }
                    $hex = $Value.Substring($i+1,$count)
                    if ($hex -notmatch '^[0-9a-fA-F]+$') { throw 'Invalid TOML Unicode escape' }
                    $cp = [Convert]::ToInt64($hex,16)
                    if ($cp -gt 0x10ffff -or ($cp -ge 0xd800 -and $cp -le 0xdfff)) { throw 'Invalid Unicode scalar' }
                    [void]$b.Append([char]::ConvertFromUtf32([int]$cp)); $i += $count
                }
                default { throw 'Invalid TOML escape' }
            }
        } else { [void]$b.Append($c) }
    }
    return $b.ToString()
}
function ConvertTo-TomlString([string]$Value) {
    $b = New-Object System.Text.StringBuilder
    [void]$b.Append('"')
    for ($i=0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]; $n = [int]$c
        if ([char]::IsHighSurrogate($c)) {
            if ($i+1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$i+1])) { throw 'Invalid Unicode key' }
            [void]$b.Append($c); $i++; [void]$b.Append($Value[$i]); continue
        }
        if ([char]::IsLowSurrogate($c)) { throw 'Invalid Unicode key' }
        switch ($n) {
            34 { [void]$b.Append('\"') }
            92 { [void]$b.Append('\\') }
            default { if ($n -lt 32 -or $n -eq 127) { [void]$b.Append(('\u{0:X4}' -f $n)) } else { [void]$b.Append($c) } }
        }
    }
    [void]$b.Append('"'); return $b.ToString()
}
function Split-TomlComment([string]$Line) {
    $quote = [char]0; $escape = $false
    for ($i=0; $i -lt $Line.Length; $i++) {
        $c=$Line[$i]
        if ($quote -ne [char]0) {
            if ($escape) { $escape=$false; continue }
            if ($quote -eq '"' -and $c -eq '\') { $escape=$true; continue }
            if ($c -eq $quote) { $quote=[char]0 }
        } elseif ($c -eq '"' -or $c -eq "'") { $quote=$c }
        elseif ($c -eq '#') { return $Line.Substring(0,$i).TrimEnd([char[]]@(' ',[char]9)) }
    }
    if ($quote -ne [char]0) { throw 'Unclosed or multiline string' }
    return $Line.TrimEnd([char[]]@(' ',[char]9))
}
function Test-TomlStringArray([string]$Value) {
    if ($Value.Length -lt 2 -or $Value[0] -ne '[' -or $Value[$Value.Length-1] -ne ']') { throw 'Unsupported TOML array' }
    $inner=$Value.Substring(1,$Value.Length-2); $i=0; $count=$inner.Length
    while ($true) {
        while ($i -lt $count -and ($inner[$i] -eq ' ' -or $inner[$i] -eq [char]9)) { $i++ }
        if ($i -ge $count) { return }
        $start=$i; $quote=$inner[$i]
        if ($quote -ne '"' -and $quote -ne "'") { throw 'Unsupported TOML array element' }
        $i++; $closed=$false
        while ($i -lt $count) {
            $c=$inner[$i]
            if ($quote -eq '"' -and $c -eq '\') { $i+=2; continue }
            if ($c -eq $quote) { $i++; $closed=$true; break }
            $i++
        }
        if (-not $closed) { throw 'Unclosed array string' }
        [void](Decode-TomlString ($inner.Substring($start,$i-$start)))
        while ($i -lt $count -and ($inner[$i] -eq ' ' -or $inner[$i] -eq [char]9)) { $i++ }
        if ($i -ge $count) { return }
        if ($inner[$i] -ne ',') { throw 'Invalid array separator' }
        $i++
    }
}
function Get-TomlPathPart([string]$Part) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Part)
    return [Convert]::ToBase64String($bytes).Replace('/','_').Replace('+','-')
}
function Read-SafeToml([string]$Text) {
    $badEnding=[regex]::Match($Text,'\x00|\r(?!\n)')
    if ($badEnding.Success) {
        $parseException=New-Object System.Exception('Unsupported TOML line ending')
        $parseException.Data['TomlLine']=1+([regex]::Matches($Text.Substring(0,$badEnding.Index),'\n')).Count
        throw $parseException
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($Text -split '\r?\n')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $tables = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $nodes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entries = New-Object System.Collections.ArrayList
    $section = ''
    $partPattern = '(?:[A-Za-z0-9_-]+|"(?:[^"\\\x00-\x1F]|\\(?:["\\btnfr]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}))*"|''[^''\x00-\x1F]*'')'
    $lineNumber=0
    foreach ($line in $lines) {
        $lineNumber++
        try {
        if ($line -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') { throw 'Invalid control character' }
        $code = Split-TomlComment $line
        if ($code -match '^[ \t]*$') { [void]$entries.Add([pscustomobject]@{ Line=$line; Section=$section; Kind='other'; Key=''; Value=$null }); continue }
        if ($code -match '^[ \t]*\[(.*?)\][ \t]*$') {
            $header=$Matches[1]; $remainder=$header; $section=''
            while ($true) {
                if ($remainder -notmatch ('^[ \t]*('+ $partPattern +')[ \t]*(.*)$')) { throw 'Unsupported table path' }
                $part=$Matches[1]; $remainder=$Matches[2]
                if ($part.StartsWith('"') -or $part.StartsWith("'")) { $part=Decode-TomlString $part }
                $section += '/'+(Get-TomlPathPart $part)
                if ($seen.Contains($section)) { throw 'Table conflicts with key' }
                [void]$nodes.Add($section)
                if ($remainder.Length -eq 0) { break }
                if (-not $remainder.StartsWith('.')) { throw 'Unsupported table path' }
                $remainder=$remainder.Substring(1)
            }
            if (-not $tables.Add($section)) { throw 'Duplicate table' }
            [void]$entries.Add([pscustomobject]@{ Line=$line; Section=$section; Kind='table'; Key=''; Value=$null }); continue
        }
        if ($code -notmatch '^[ \t]*([A-Za-z0-9_-]+)[ \t]*=[ \t]*(.*?)[ \t]*$') { throw 'Unsupported TOML syntax' }
        $key=$Matches[1]; $value=$Matches[2]; $identity=$section+'/'+(Get-TomlPathPart $key)
        if (-not $seen.Add($identity) -or $nodes.Contains($identity)) { throw 'Duplicate key or table conflict' }
        $decoded=$null
        if ($value.StartsWith('"') -or $value.StartsWith("'")) { $decoded=Decode-TomlString $value }
        elseif ($value.StartsWith('[')) { Test-TomlStringArray $value }
        elseif ($value -cnotmatch '^(?:true|false|[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|[+-]?(?:inf|nan))$') { throw 'Unsupported TOML value' }
        if ($section -ceq '' -and $key -ceq 'model' -and $null -eq $decoded) { throw 'Model must be a string' }
        [void]$entries.Add([pscustomobject]@{ Line=$line; Section=$section; Kind='key'; Key=$key; Value=$decoded })
        } catch {
            # Carry only line number. Do not attach line text or the ErrorRecord.
            $_.Exception.Data['TomlLine']=$lineNumber
            throw
        }
    }
    return [pscustomobject]@{ Entries=$entries; Newline=$newline }
}
$script:CustomSection = '/'+(Get-TomlPathPart 'model_providers')+'/'+(Get-TomlPathPart 'custom')
function Get-ExistingKey($Parsed) {
    $url=$null; $key=$null
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -ceq $script:CustomSection -and $e.Kind -eq 'key') {
            if ($e.Key -ceq 'base_url') { $url=$e.Value }
            if ($e.Key -ceq 'experimental_bearer_token') { $key=$e.Value }
        }
    }
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($key)) { return $null }
    if ($url -cnotmatch ('^(?i:' + [regex]::Escape((ConvertTo-GatewayOrigin)) + ')(?:/|/v1/?)?$')) { return $null }
    return $key
}
function Build-Config($Parsed,[string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { throw 'Empty key' }
    $output = New-Object System.Collections.Generic.List[string]
    $hasModel=$false; $hasCustom=$false; $rootDone=$false; $customOpen=$false
    $fields=@('name','wire_api','requires_openai_auth','base_url','experimental_bearer_token')
    $providerLines=@('name = "custom"','wire_api = "responses"','requires_openai_auth = false',('base_url = '+(ConvertTo-TomlString ((ConvertTo-GatewayOrigin)+'/v1'))),('experimental_bearer_token = '+(ConvertTo-TomlString $Key)))
    foreach ($e in $Parsed.Entries) {
        if ($e.Kind -eq 'key' -and $e.Section -ceq '' -and $e.Key -ceq 'model') { $hasModel=$true }
    }
    foreach ($e in $Parsed.Entries) {
        if ($e.Kind -eq 'table') {
            if (-not $rootDone) {
                $output.Add('model_provider = "custom"'); if (-not $hasModel) { $output.Add('model = "gpt-6.1-sol"') }; $rootDone=$true
            }
            if ($customOpen) { foreach ($l in $providerLines) { $output.Add($l) }; $customOpen=$false }
            if ($e.Section -ceq $script:CustomSection) { $hasCustom=$true; $customOpen=$true }
        }
        if ($e.Kind -eq 'key' -and (($e.Section -ceq '' -and $e.Key -ceq 'model_provider') -or ($e.Section -ceq $script:CustomSection -and $fields -ccontains $e.Key))) {
            $code=Split-TomlComment $e.Line
            $tail=$e.Line.Substring($code.Length).TrimStart([char[]]@(' ',[char]9))
            if ($tail.StartsWith('#')) { $output.Add($tail) }
            continue
        }
        $output.Add($e.Line)
    }
    if (-not $rootDone) { $output.Add('model_provider = "custom"'); if (-not $hasModel) { $output.Add('model = "gpt-6.1-sol"') } }
    if ($customOpen) { foreach ($l in $providerLines) { $output.Add($l) } }
    if (-not $hasCustom) { $output.Add(''); $output.Add('[model_providers.custom]'); foreach ($l in $providerLines) { $output.Add($l) } }
    $result=[string]::Join($Parsed.Newline,$output.ToArray())+$Parsed.Newline
    [void](Read-SafeToml $result)
    return $result
}
function Assert-NoReparseAncestors([string]$Directory) {
    $current=[IO.Path]::GetFullPath($Directory)
    while (-not [string]::IsNullOrEmpty($current)) {
        try {
            $attributes=[IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsupported directory link in configuration path' }
            if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw 'Configuration path component is not a directory' }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function New-PrivateFile([string]$Path,[byte[]]$Bytes) {
    $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($sid)
    $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')
    [void]$acl.AddAccessRule($rule)
    $stream=New-Object System.IO.FileStream($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileSystemRights]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough,$acl)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Save-ConfigAtomic([string]$Path,[byte[]]$Original,[bool]$Existed,[string]$Text,$State=$null) {
    if ($null -eq $State) { $State=New-SaveState }
    $State.Started=$true
    $dir=[IO.Path]::GetDirectoryName($Path)
    Assert-NoReparseAncestors $dir
    [void][IO.Directory]::CreateDirectory($dir)
    Assert-NoReparseAncestors $dir
    $temp=[IO.Path]::Combine($dir,'.codex-gateway-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $backup=[IO.Path]::Combine($dir,'config.toml.backup-'+[guid]::NewGuid().ToString('N'))
    $utf8=New-Object System.Text.UTF8Encoding($false,$true)
    try {
        New-PrivateFile $temp ($utf8.GetBytes($Text))
        $privateAcl=[IO.File]::GetAccessControl($temp)
        if ($Existed) {
            # Never overwrite an existing backup. ACL-protected backup is created before replacement.
            New-PrivateFile $backup $Original
            $State.BackupCreated=$true
            $current=[IO.File]::ReadAllBytes($Path)
            if ([Convert]::ToBase64String($Original) -cne [Convert]::ToBase64String($current)) { throw 'Configuration changed during setup' }
            # ReplaceFile can retain the destination ACL. Tighten and verify it before exposing new bytes.
            $State.PermissionsMayHaveChanged=$true
            [IO.File]::SetAccessControl($Path,$privateAcl)
            $sections=[System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
            $expectedAcl=$privateAcl.GetSecurityDescriptorSddlForm($sections)
            $actualAcl=([IO.File]::GetAccessControl($Path)).GetSecurityDescriptorSddlForm($sections)
            if ($expectedAcl -cne $actualAcl) { throw 'Could not verify private configuration ACL' }
            $current=[IO.File]::ReadAllBytes($Path)
            if ([Convert]::ToBase64String($Original) -cne [Convert]::ToBase64String($current)) { throw 'Configuration changed during setup' }
            Assert-NoReparseAncestors $dir
            $State.ReplacementAttempted=$true
            [IO.File]::Replace($temp,$Path,$null,$true)
            $State.ContentSaved=$true
        } else {
            Assert-NoReparseAncestors $dir
            $State.ReplacementAttempted=$true
            [IO.File]::Move($temp,$Path)
            $State.ContentSaved=$true
        }
        [IO.File]::SetAccessControl($Path,$privateAcl)
    } finally {
        try { Assert-NoReparseAncestors $dir; if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } } catch { }
    }
}
