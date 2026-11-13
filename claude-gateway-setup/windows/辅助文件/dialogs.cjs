'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');

class DialogError extends Error {
  constructor(message, details = {}) { super(message); this.name = 'DialogError'; this.cancelled = message.startsWith('已取消'); Object.assign(this, details); }
}
const CANCELLED = '已取消，Claude Code 配置未修改。';
const FAILED = '无法打开或读取密钥弹窗，Claude Code 配置未修改。请在电脑桌面环境重新运行安装程序。';
const INVALID = 'API Key 不能为空、含空格或控制字符，且不能超过 8192 个字符。请只复制密钥后重新输入。';
const validToken = token => typeof token === 'string' && token.length > 0 && token.length <= 8192 && !/[\s\x00-\x1f\x7f]/u.test(token);

const MAC_CHOICE = `with timeout of 86400 seconds
try
    set selected to button returned of (display dialog "检测到已有网关密钥，是否使用？" with title "Claude Code 网关配置" buttons {"取消", "使用现有密钥", "输入新密钥"} default button "使用现有密钥" cancel button "取消")
    if selected is "使用现有密钥" then
        return "keep"
    else
        return "replace"
    end if
on error number -128
    return "cancel"
end try
end timeout`;
const MAC_SECRET = `with timeout of 86400 seconds
try
    set entered to text returned of (display dialog "请输入网关密钥" with title "Claude Code 网关配置" default answer "" buttons {"取消", "确定"} default button "确定" cancel button "取消")
    return "set" & linefeed & entered
on error number -128
    return "cancel"
end try
end timeout`;
const MAC_INVALID = `display dialog "${INVALID}" with title "Claude Code 网关配置" buttons {"好"} default button "好"`;

function parseResult(platform, mode, output) {
  if (typeof output !== 'string') throw new DialogError(FAILED);
  if (platform === 'darwin') {
    const text = output.replace(/\r?\n$/, '');
    if (text === 'cancel') return { action: 'cancel' };
    if (mode === 'choice' && ['keep', 'replace'].includes(text)) return { action: text };
    if (mode === 'secret' && text.startsWith('set\n')) return { action: 'set', token: text.slice(4) };
    throw new DialogError(FAILED);
  }
  let result;
  try { result = JSON.parse(output.replace(/^\uFEFF/, '')); } catch { throw new DialogError(FAILED); }
  if (!result || typeof result !== 'object' || Array.isArray(result)) throw new DialogError(FAILED);
  if (result.action === 'cancel') return { action: 'cancel' };
  if (mode === 'choice' && ['keep', 'replace'].includes(result.action)) return { action: result.action };
  if (mode === 'secret' && result.action === 'set' && typeof result.token === 'string') return { action: 'set', token: result.token };
  throw new DialogError(FAILED);
}

function createDialogs({ platform = process.platform, run = spawnSync, environment = process.env } = {}) {
  function invoke(mode) {
    let command, args, input;
    if (platform === 'darwin') {
      command = '/usr/bin/osascript';
      args = ['-'];
      input = mode === 'choice' ? MAC_CHOICE : mode === 'secret' ? MAC_SECRET : MAC_INVALID;
    } else if (platform === 'win32') {
      const root = environment.SystemRoot || 'C:\\Windows';
      command = path.win32.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      args = ['-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'key-dialog.ps1'), '-Mode', mode];
    } else {
      throw new DialogError('密钥弹窗仅支持 macOS 和 Windows；Claude Code 配置未修改。');
    }
    // The key returns only through a private child stdout pipe. Never inherit or print it.
    let result;
    try {
      result = run(command, args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, maxBuffer: 65536 });
    } catch { throw new DialogError(FAILED); }
    if (result.error || result.status !== 0) throw new DialogError(FAILED);
    if (mode === 'invalid') return;
    return parseResult(platform, mode, result.stdout);
  }
  return {
    choice() {
      const result = invoke('choice');
      if (result.action === 'cancel') throw new DialogError(CANCELLED);
      return result.action;
    },
    secret() {
      while (true) {
        const result = invoke('secret');
        if (result.action === 'cancel') throw new DialogError(CANCELLED);
        const token = result.token.trim();
        if (validToken(token)) return token;
        // Windows validates inside its input form; this loop also defends its result.
        if (platform === 'darwin') invoke('invalid');
        else throw new DialogError(INVALID + ' 配置未修改。');
      }
    },
  };
}
module.exports = { createDialogs, DialogError, validToken, parseResult, MAC_CHOICE, MAC_SECRET, MAC_INVALID };
