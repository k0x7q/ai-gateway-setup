# AI Gateway Setup

用于安装和配置 Claude Code，或为已安装的 Codex 桌面客户端配置 API 网关。支持 macOS 和 Windows，自动下载、校验所需脚本，并在运行后清理临时文件。

- **Claude Code**：检查依赖，按需安装 Node.js、Claude Code 和 Windows 所需的 Git Bash，然后配置网关。
- **Codex 桌面客户端**：仅配置网关，客户端需自行安装。
- **网关地址**：由启动命令传入，不内置固定地址；API Key 在运行时输入。

## 使用方法

以下命令会下载并执行本仓库最新 Release 中的启动脚本，请确认信任其来源。仓库需已有正式 Release 才能使用。

### Mac

将命令中的 `https://gateway.example.com` 替换为实际网关地址，再打开「终端」，粘贴整行并按回车：

```bash
/bin/bash -c 's=$(/usr/bin/curl --fail --silent --show-error --location --proto "=https" --proto-redir "=https" --connect-timeout 15 --max-time 180 https://github.com/k0x7q/ai-gateway-setup/releases/latest/download/setup-mac.sh) || exit $?; exec /bin/bash -c "$s" -- --gateway "$1"' -- 'https://gateway.example.com'
```

### Windows

打开系统自带的 **Windows PowerShell**（不是命令提示符，也不要以管理员身份运行），将 `https://gateway.example.com` 替换为实际网关地址，粘贴整行并按回车：

```powershell
& { $ErrorActionPreference = 'Stop'; $oldTls = [Net.ServicePointManager]::SecurityProtocol; try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri 'https://github.com/k0x7q/ai-gateway-setup/releases/latest/download/setup-windows.ps1'; $s = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }; & ([scriptblock]::Create($s.TrimStart([char]0xfeff))) -GatewayUrl 'https://gateway.example.com' } finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls } }
```

建议 Windows 10/11，使用 Windows PowerShell 5.1。启动器会单独启动 STA 模式的配置子进程，不会永久修改系统执行策略。

网关地址必须为 HTTPS 域名或 IPv4 地址，可带端口及末尾 `/`，不可包含账号、其他路径、查询参数或片段；暂不支持 IPv6 字面量。Claude Code 使用该地址，Codex 自动追加 `/v1`。实际地址只需保留在内部发放的命令中，不要提交到公开仓库。

### 接下来

1. 输入 `1` 安装并配置 Claude Code，或输入 `2` 配置 Codex；`0` 取消。
2. 按窗口提示输入或复用网关密钥，完成配置。
3. 临时下载文件自动清理。查看原配置程序的输出和诊断，再关闭终端。

运行时需要网络访问 GitHub 及其 Release 下载域名；Claude Code 按需安装还需要访问 Node.js 官网、npm 官方仓库，Windows 安装 Git 可能使用 winget。不要关闭证书检查、系统安全保护或把 GitHub Token 放进启动命令。

## 注意事项

- 辅助脚本通过 SHA-256 校验后才会执行；下载或校验失败会停止。校验信息来自同一 Release，不属于独立签名验证。
- 仅清理本次运行的临时目录，不会删除已安装的软件、用户配置、备份或 Codex 安装包。强制退出时可能残留临时文件。
- 配置是否成功以配置程序的输出为准，“流程结束”不代表配置成功或已回滚。
- API Key、配置及备份可能包含明文凭据，请勿上传或分享。
- Claude Code 已有模型设置逐项保留；缺失的 Haiku 默认补 `claude-haiku-5-5`，Opus、Sonnet、Fable 默认补 `claude-sonnet-5-5`。不再自动添加全局或子代理模型指定，也不删除已有指定。详见[模型配置规则](<claude-gateway-setup/使用说明.md#模型配置规则>)。

## 构建与发布

启动脚本源文件位于 [bootstrap](<bootstrap/>)，使用 [build_release.py](<tools/build_release.py>) 构建发布资产。

1. 更新 [VERSION](<VERSION>)，版本格式为 `v数字.数字.数字`。
2. 提交代码并推送与版本号一致的 Git 标签，例如：

   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

3. GitHub Actions 通过跨平台测试后，自动构建并发布 Release。不要提前创建同名 Release 或覆盖已发布的资产。

启动命令默认使用最新 Release。若需固定版本，将 `/releases/latest/download/` 替换为 `/releases/download/v1.0.0/`。

## 本地开发与测试

不运行实际安装或修改真实用户配置：

```bash
python3 tools/build_release.py
/bin/bash -n dist/setup-mac.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
cd claude-gateway-setup
node --test tests/configure.test.cjs tests/dialogs.test.cjs tests/prepared.test.cjs
/usr/bin/ruby tests/mac_test.rb
python3 tests/terminal_test.py
python3 tests/mac_terminal_test.py
python3 tests/windows_static_test.py
python3 build_packages.py
python3 tests/distribution_test.py
cd ..
/usr/bin/ruby codex-gateway-setup/mac/辅助文件/test_setup.rb
```

Windows PowerShell：

```powershell
python tools/build_release.py
& ./tests/windows_bootstrap.Tests.ps1
& './codex-gateway-setup/windows/辅助文件/SelfTest.ps1'
```

构建只读取明确列出的源文件，保留 PowerShell 的 BOM 和 CRLF，不执行任何安装器，也不把测试、个人文件、旧 ZIP 或 macOS 元数据打包成发布资产。构建输出在 `dist`，不提交到 Git。
