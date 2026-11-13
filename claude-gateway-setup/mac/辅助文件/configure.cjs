/* Shared Claude Code settings merger. No dependencies, network calls or model requests. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const readline = require('node:readline');
const { spawnSync } = require('node:child_process');
const { createDialogs, DialogError, validToken } = require('./dialogs.cjs');
const MODEL = 'claude-sonnet-5';
const SUBAGENT_MODEL = 'claude-haiku-5-5';
const MODEL_KEYS = ['ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
  'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_FABLE_MODEL'];
const MAX_BYTES = 2 * 1024 * 1024;
class SetupError extends Error {
  constructor(message, details = {}) { super(message); this.name = 'SetupError'; Object.assign(this, details); }
}
function gatewayUrl(value = process.env.AI_GATEWAY_URL) {
  if (typeof value !== 'string' || value !== value.trim() || !/^https:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?\/?$/.test(value)) {
    throw new SetupError('请通过 AI_GATEWAY_URL 提供 HTTPS 网关域名地址，不可包含账号、路径、查询参数或片段。');
  }
  let parsed;
  try { parsed = new URL(value); } catch { throw new SetupError('网关地址或端口无效。'); }
  if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.port === '0') throw new SetupError('网关地址或端口无效。');
  return parsed.origin;
}
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);

// Validate without quoting configuration text in syntax errors. Native launchers also
// preflight before installing; this authoritative second check includes duplicate keys.
function parseSettings(text) {
  const source = text.replace(/^\uFEFF/, '');
  let i = 0, envPosition = 0;
  const fail = (reason = '现有配置不是有效的 JSON；原文件未修改。', position = i, code = 'CFG-JSON-001') => {
    const prefix = source.slice(0, position);
    const line = prefix.split('\n').length;
    const column = position - prefix.lastIndexOf('\n');
    throw new SetupError(reason, { code, stage: 'parse', line, column });
  };
  const space = () => { while (i < source.length && /[\x20\t\r\n]/.test(source[i])) i++; };
  function string() {
    const start = i;
    if (source[i++] !== '"') fail(undefined, start);
    while (i < source.length) {
      const c = source[i++];
      if (c === '"') return JSON.parse(source.slice(start, i));
      if (c === '\\') {
        const escape = source[i++];
        if (escape === 'u') {
          if (!/^[0-9a-fA-F]{4}$/.test(source.slice(i, i + 4))) fail(undefined, i);
          i += 4;
        } else if (!escape || !'"\\/bfnrt'.includes(escape)) fail(undefined, i - 1);
      } else if (c.charCodeAt(0) < 32) fail(undefined, i - 1);
    }
    fail(undefined, start);
  }
  function walk(depth = 0) {
    space();
    if (depth > 256) fail('配置嵌套超过安全上限；原文件未修改。', i, 'CFG-DEPTH-001');
    if (source[i] === '{') {
      i++; space(); const seen = new Set();
      if (source[i] === '}') { i++; return; }
      while (true) {
        space(); const start = i, key = string();
        if (seen.has(key)) fail('配置包含重复的 JSON 键；请先修复，原文件未修改。', start, 'CFG-DUPLICATE-001');
        if (depth === 0 && key === 'env') envPosition = start;
        seen.add(key); space();
        if (source[i++] !== ':') fail(undefined, i - 1);
        walk(depth + 1); space();
        if (source[i] === '}') { i++; return; }
        if (source[i++] !== ',') fail(undefined, i - 1);
      }
    }
    if (source[i] === '[') {
      i++; space(); if (source[i] === ']') { i++; return; }
      while (true) {
        walk(depth + 1); space();
        if (source[i] === ']') { i++; return; }
        if (source[i++] !== ',') fail(undefined, i - 1);
      }
    }
    if (source[i] === '"') { string(); return; }
    for (const literal of ['true', 'false', 'null']) {
      if (source.startsWith(literal, i)) { i += literal.length; return; }
    }
    const start = i, match = source.slice(i).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
    if (!match) fail();
    i += match[0].length;
    const number = Number(match[0]);
    if (!Number.isFinite(number) || (Number.isInteger(number) && !Number.isSafeInteger(number))) {
      fail('配置含超出安全精度的数值，无法保证保留原设置；原文件未修改。', start, 'CFG-NUMBER-001');
    }
  }
  walk(); space(); if (i !== source.length) fail();
  let value;
  try { value = JSON.parse(source); } catch { fail(); }
  if (!isObject(value) || (Object.hasOwn(value, 'env') && !isObject(value.env))) {
    fail('配置根节点和 env 必须是 JSON 对象；原文件未修改。', envPosition, 'CFG-STRUCTURE-001');
  }
  return value;
}
function mergeSettings(settings, token) {
  const BASE_URL = gatewayUrl();
  if (!isObject(settings) || (Object.hasOwn(settings, 'env') && !isObject(settings.env))) throw new SetupError('env 必须是对象。');
  if (!validToken(token)) {
    throw new SetupError('网关密钥为空、含空白或控制字符，或者过长，请重新输入。');
  }
  const env = { ...(settings.env || {}), ANTHROPIC_BASE_URL: BASE_URL, ANTHROPIC_AUTH_TOKEN: token };
  for (const key of MODEL_KEYS) env[key] = MODEL;
  env.CLAUDE_CODE_SUBAGENT_MODEL = SUBAGENT_MODEL;
  return { ...settings, env };
}
function configPath(environment = process.env, home = os.homedir()) {
  const dir = environment.CLAUDE_CONFIG_DIR || path.join(home, '.claude');
  if (!path.isAbsolute(dir) || (process.platform === 'win32' && dir.startsWith('\\\\'))) {
    throw new SetupError('CLAUDE_CONFIG_DIR 必须是本地绝对目录。');
  }
  return path.join(path.resolve(dir), 'settings.json');
}
function assertNoLinks(target) {
  const absolute = path.resolve(target);
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    if (stat.isSymbolicLink()) throw new SetupError('配置路径存在链接或联接，无法安全处理。');
    if (current !== absolute && !stat.isDirectory()) throw new SetupError('配置路径的上级目录不是文件夹。');
  }
}
function loadSettings(target) {
  assertNoLinks(target);
  let stat;
  try { stat = fs.lstatSync(target); } catch (error) {
    if (error.code === 'ENOENT') return { settings: {}, bytes: null };
    throw error;
  }
  if (!stat.isFile() || stat.size > MAX_BYTES || stat.nlink !== 1) throw new SetupError('配置不是普通文件、存在硬链接或过大；原文件未修改。');
  const fd = fs.openSync(target, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(fd);
    if (opened.ino !== stat.ino || opened.dev !== stat.dev) throw new SetupError('配置在读取时发生变化，请关闭 Claude Code 后重试。');
    const bytes = fs.readFileSync(fd);
    if (bytes.length > MAX_BYTES) throw new SetupError('配置文件过大。');
    let text;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch { throw new SetupError('配置不是有效的 UTF-8 编码；原文件未修改。'); }
    return { settings: parseSettings(text), bytes };
  } finally { fs.closeSync(fd); }
}
function nativeToolError(reason, name, result) {
  const detail = result.error ? `${result.error.name}: ${result.error.message}` : String(result.stderr || '').trim();
  return new SetupError(`${reason}；工具：${name}；退出码：${result.status ?? '未启动'}${result.signal ? `；信号：${result.signal}` : ''}${detail ? `\n${detail}` : ''}`, { code: 'CFG-PERMISSIONS-001' });
}
let windowsSid;
function makePrivate(target) {
  if (process.platform !== 'win32') {
    if (process.platform === 'darwin') {
      const result = spawnSync('/bin/chmod', ['-N', target], { encoding: 'utf8' });
      if (result.status !== 0) throw nativeToolError('无法移除继承权限，未写入密钥。', 'chmod', result);
    }
    fs.chmodSync(target, 0o600); return;
  }
  if (!windowsSid) {
    const who = spawnSync('whoami.exe', ['/user', '/fo', 'csv', '/nh'], { encoding: 'utf8', windowsHide: true });
    windowsSid = who.status === 0 && who.stdout.match(/S-1-5-[0-9-]+/)?.[0];
    if (!windowsSid) throw nativeToolError('无法识别当前用户，未写入密钥。', 'whoami', who);
  }
  const result = spawnSync('icacls.exe', [target, '/inheritance:r', '/grant:r',
    `*${windowsSid}:(F)`, '*S-1-5-18:(F)', '*S-1-5-32-544:(F)'], { encoding: 'utf8', windowsHide: true });
  if (result.status !== 0) throw nativeToolError('无法设置配置文件的私有权限，未写入密钥。', 'icacls', result);
}
function createPrivate(target, bytes) {
  const fd = fs.openSync(target, 'wx', 0o600);
  try { makePrivate(target); fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
}
function saveSettings(target, original, settings, state = {}) {
  assertNoLinks(target);
  state.value = 'saving';
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  assertNoLinks(target);
  const now = loadSettings(target).bytes;
  if ((now === null) !== (original === null) || (now && !now.equals(original))) throw new SetupError('配置已被其他程序修改，请关闭 Claude Code 后重新运行。');
  const rendered = Buffer.from(JSON.stringify(settings, null, 2) + '\n');
  parseSettings(rendered.toString('utf8'));
  const unchanged = original && original.equals(rendered);
  if (unchanged && process.platform !== 'win32') { makePrivate(target); state.value = 'saved'; return null; }
  const suffix = `${new Date().toISOString().replace(/[:.]/g, '-')}-${crypto.randomBytes(6).toString('hex')}`;
  let backup = null;
  if (original !== null && !unchanged) { backup = `${target}.backup-${suffix}`; createPrivate(backup, original); }
  const temp = path.join(path.dirname(target), `.settings-${suffix}.tmp`);
  createPrivate(temp, rendered);
  // Leave private temporary files on failure for support rather than risk deleting user data.
  assertNoLinks(target);
  const latest = loadSettings(target).bytes;
  if ((latest === null) !== (original === null) || (latest && !latest.equals(original))) {
    throw new SetupError('保存前配置发生变化，原文件未覆盖；可能已创建私有备份及临时文件。');
  }
  fs.renameSync(temp, target);
  state.value = 'saved';
  return backup;
}
function ask(question) {
  return new Promise(resolve => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, answer => { rl.close(); resolve(answer.trim()); });
  });
}
function askSecret() {
  if (!process.stdin.isTTY || !process.stdin.setRawMode) throw new SetupError('请双击入口，在正常终端中运行；不支持管道输入 API Key。');
  return new Promise((resolve, reject) => {
    let secret = '';
    let escapeSequence = '';
    let bracketPaste = false;
    let pasteNewline = false;
    process.stdin.setEncoding('utf8'); process.stdin.setRawMode(true); process.stdin.resume();
    process.stdout.write('请粘贴公司 API Key，然后按回车（输入不会显示；Ctrl+C 取消）：');
    const finish = error => {
      process.stdin.removeListener('data', onData); process.stdin.setRawMode(false); process.stdin.pause();
      process.stdout.write('\n'); if (error) reject(error); else resolve(secret.trim());
    };
    const onData = chunk => {
      for (const c of chunk) {
        if (escapeSequence) {
          escapeSequence += c;
          if (escapeSequence === '\u001b[' || escapeSequence === '\u001bO') continue;
          if (escapeSequence.length > 2 && /[@-~]/.test(c) || escapeSequence.length === 2 && c !== '[' && c !== 'O') {
            if (escapeSequence === '\u001b[200~') bracketPaste = true;
            if (escapeSequence === '\u001b[201~') bracketPaste = false;
            escapeSequence = '';
          }
          if (escapeSequence.length > 64) { finish(new SetupError('终端控制输入异常，已取消。')); return; }
          continue;
        }
        if (c === '\u001b') { escapeSequence = c; continue; }
        if (c === '\u0003' || c === '\u0004') { finish(new SetupError('已取消，配置未修改。', { cancelled: true })); return; }
        if (c === '\r' || c === '\n') {
          if (bracketPaste) { pasteNewline = true; continue; }
          if (pasteNewline) { finish(new SetupError('API Key 粘贴包含多行，请只复制密钥后重新运行。')); return; }
          finish(); return;
        }
        if (c === '\u007f' || c === '\b') secret = secret.slice(0, -1);
        else if (c >= ' ' && c !== '\u007f') secret += c;
        if (secret.length > 8192) { finish(new SetupError('输入过长，已取消。')); return; }
      }
    };
    process.stdin.on('data', onData);
  });
}
function redactDiagnostic(text, tokens = []) {
  let result = String(text ?? '');
  const variants = new Set();
  for (const token of tokens) {
    if (typeof token !== 'string' || !token) continue;
    variants.add(token); variants.add(JSON.stringify(token).slice(1, -1));
    variants.add(token.replaceAll("'", "''"));
    try { variants.add(encodeURIComponent(token)); } catch { /* Invalid Unicode is still filtered literally. */ }
  }
  for (const value of [...variants].sort((a, b) => b.length - a.length)) result = result.split(value).join('[密钥已移除]');
  result = result.replace(/((?:authorization|x-api-key|anthropic_(?:auth_token|api_key))\s*[:=]\s*)([^\r\n]+)/ig, '$1[密钥已移除]');
  result = result.replace(/\{[\s\S]*\}/g, '[配置片段已移除]');
  return result.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '?').slice(0, 6000);
}
function credentialValues(settings) {
  const values = [];
  function walk(value, depth = 0) {
    if (depth > 256 || !value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      if (typeof child === 'string' && /key|token|secret|password/i.test(key)) values.push(child);
      else if (typeof child === 'object') walk(child, depth + 1);
    }
  }
  walk(settings);
  for (const [key, value] of Object.entries(process.env)) if (/key|token|secret|password/i.test(key)) values.push(value);
  return values;
}
function errorDiagnostic(error, { stage = 'configure', state = 'unchanged', tokens = [] } = {}) {
  const cancelled = Boolean(error?.cancelled);
  const allowedStages = new Set(['configure', 'path', 'read', 'parse', 'key', 'build', 'save', 'preflight']);
  stage = allowedStages.has(error?.stage) ? error.stage : (allowedStages.has(stage) ? stage : 'configure');
  const code = typeof error?.code === 'string' && /^(?:CFG-[A-Z0-9-]+|SETUP-CANCELLED|E[A-Z0-9_]+)$/.test(error.code) ? error.code : (cancelled ? 'SETUP-CANCELLED' : `CFG-${stage.toUpperCase()}-001`);
  const type = error?.name && error.name !== 'SetupError' ? `[${error.name}] ` : '';
  const osDetails = error?.syscall ? `；操作：${error.syscall}${error.errno !== undefined ? `；系统错误号：${error.errno}` : ''}` : '';
  const reason = redactDiagnostic(type + (error?.message || String(error)) + osDetails, tokens);
  const reportedState = error?.state || state;
  return { code, stage, reason, line: Number.isInteger(error?.line) ? error.line : null, column: Number.isInteger(error?.column) ? error.column : null, state: ['unchanged', 'saving', 'saved', 'unknown'].includes(reportedState) ? reportedState : 'unknown', cancelled };
}
function digest(bytes) { return bytes === null ? null : crypto.createHash('sha256').update(bytes).digest('hex'); }
async function main(options = {}) {
  const { interaction = createDialogs(), log = message => console.log(message), quiet = false } = options;
  let stage = 'path', target, settings, token = options.token;
  const state = { value: 'unchanged' }, tokens = [];
  if (typeof token === 'string') tokens.push(token);
  try {
    const BASE_URL = gatewayUrl();
    target = options.target ?? configPath();
    stage = 'read';
    const loaded = loadSettings(target); settings = loaded.settings;
    tokens.push(...credentialValues(settings));
    if (Object.hasOwn(options, 'expectedDigest') && options.expectedDigest !== digest(loaded.bytes)) {
      throw new SetupError('配置在预检后发生变化，请关闭 Claude Code 后重新运行；原文件未覆盖。', { code: 'CFG-CONCURRENT-001' });
    }
    const previous = settings.env || {}, warnings = [];
    if (settings.apiKeyHelper || previous.ANTHROPIC_API_KEY || settings.model ||
        ['CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'].some(k => previous[k] || process.env[k]) ||
        Object.keys(process.env).some(k => k.startsWith('ANTHROPIC_'))) {
      warnings.push('注意：存在其他认证或模型设置，可能影响网关；如启动异常，请检查这些设置。');
    }
    stage = 'key';
    if (!Object.hasOwn(options, 'token')) {
      token = null;
      if (previous.ANTHROPIC_BASE_URL === BASE_URL && typeof previous.ANTHROPIC_AUTH_TOKEN === 'string' && previous.ANTHROPIC_AUTH_TOKEN.trim()) {
        const action = await interaction.choice();
        if (action === 'keep') token = previous.ANTHROPIC_AUTH_TOKEN;
        else if (action !== 'replace') throw new SetupError('密钥选择未完成，配置未修改。');
      }
      if (token === null) token = await interaction.secret();
      if (typeof token === 'string') tokens.push(token);
    }
    stage = 'build'; const merged = mergeSettings(settings, token);
    stage = 'save'; const backup = saveSettings(target, loaded.bytes, merged, state);
    for (const warning of warnings) log(warning);
    if (!quiet) log('配置已保存（未验证网关密钥或模型）。');
    return { target, backup, state: 'saved', warnings, verified: false };
  } catch (caught) {
    const error = caught instanceof Error ? caught : new SetupError(String(caught));
    error.diagnostic = errorDiagnostic(error, { stage, state: state.value, tokens });
    throw error;
  } finally { token = null; }
}
async function preparedMain(input) {
  let packet, tokens = [];
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(input);
    packet = parseSettings(text);
    if (typeof packet.token === 'string') tokens.push(packet.token);
    if (typeof packet.target !== 'string' || !path.isAbsolute(packet.target) ||
        (process.platform === 'win32' && packet.target.startsWith('\\\\')) || path.basename(packet.target) !== 'settings.json' ||
        !(packet.expectedDigest === null || (typeof packet.expectedDigest === 'string' && /^[a-f0-9]{64}$/.test(packet.expectedDigest)))) {
      throw new SetupError('预检参数无效：需要本地绝对配置路径和原配置摘要。', { code: 'CFG-REQUEST-001', stage: 'preflight' });
    }
    const result = await main({ target: packet.target, token: packet.token, expectedDigest: packet.expectedDigest, quiet: true, log() {} });
    return { ok: true, ...result };
  } catch (error) {
    return { ok: false, diagnostic: error.diagnostic || errorDiagnostic(error, { stage: 'preflight', tokens }) };
  }
}
async function readPreparedInput(stream) {
  const chunks = []; let size = 0;
  for await (const chunk of stream) {
    const bytes = Buffer.from(chunk); size += bytes.length;
    if (size > 65536) throw new SetupError('预检参数过大。', { code: 'CFG-REQUEST-002', stage: 'preflight' });
    chunks.push(bytes);
  }
  return Buffer.concat(chunks);
}
if (require.main === module) {
  if (process.argv.includes('--prepared-stdin')) {
    (async () => {
      let result;
      try { result = await preparedMain(await readPreparedInput(process.stdin)); }
      catch (error) { result = { ok: false, diagnostic: errorDiagnostic(error, { stage: 'preflight' }) }; }
      process.stdout.write(JSON.stringify(result) + '\n');
      process.exitCode = result.ok ? 0 : 1;
    })();
  } else {
    // Explicit developer terminal test mode; shipped launchers collect GUI input natively.
    const options = process.argv.includes('--terminal') ? { interaction: {
      choice: async () => (await ask('已有网关密钥。按回车使用；输入 N 后回车输入新密钥：')).toLowerCase() === 'n' ? 'replace' : 'keep', secret: askSecret,
    } } : {};
    options.quiet = process.argv.includes('--quiet');
    main(options).catch(error => {
      const diagnostic = error.diagnostic || errorDiagnostic(error);
      if (!diagnostic.cancelled) console.error(`${diagnostic.code}\n阶段：${diagnostic.stage}\n原因：${diagnostic.reason}${diagnostic.line ? `\n位置：第 ${diagnostic.line} 行，第 ${diagnostic.column} 列` : ''}\n配置状态：${diagnostic.state}`);
      process.exitCode = diagnostic.cancelled ? 0 : 1;
    });
  }
}
module.exports = { gatewayUrl, MODEL, MODEL_KEYS, SetupError, parseSettings, mergeSettings, configPath, loadSettings, saveSettings, main, digest, preparedMain, readPreparedInput, errorDiagnostic, redactDiagnostic };
