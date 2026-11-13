'use strict';
process.env.AI_GATEWAY_URL = 'https://gateway.example.com';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const core = require('../common/configure.cjs');
const { createDialogs, DialogError, validToken, parseResult } = require('../common/dialogs.cjs');
const OLD = 'mock-old-key-not-a-real-secret';
const NEW = 'mock-new-key-not-a-real-secret';
function fixture(t) {
  const base = fs.realpathSync(os.tmpdir());
  const dir = fs.mkdtempSync(path.join(base, 'claude-dialog-test-'));
  t.after(() => {
    const absolute = fs.realpathSync(dir);
    assert.equal(path.dirname(absolute), base);
    assert.ok(path.basename(absolute).startsWith('claude-dialog-test-'));
    fs.rmSync(absolute, { recursive: true });
  });
  return { dir, target: path.join(dir, 'config', 'settings.json') };
}
function existing(target, token = OLD, baseURL = core.gatewayUrl()) {
  fs.mkdirSync(path.dirname(target), { mode: 0o700 });
  const settings = core.mergeSettings({ permissions: { allow: ['Read'] }, env: { KEEP: 'untouched' } }, token);
  settings.env.ANTHROPIC_BASE_URL = baseURL;
  const bytes = Buffer.from(JSON.stringify(settings, null, 2) + '\n');
  fs.writeFileSync(target, bytes, { mode: 0o600 });
  return bytes;
}
function logger() {
  const output = [];
  return { output, log: message => output.push(message), safe() { const text = output.join('\n'); assert.ok(!text.includes(OLD)); assert.ok(!text.includes(NEW)); } };
}

test('missing key opens only input dialog and saves visible input without logging it', async t => {
  const { target } = fixture(t); const logs = logger(); let calls = 0;
  await core.main({ target, interaction: { choice() { assert.fail('unexpected existing-key prompt'); }, secret() { calls++; return NEW; } }, log: logs.log });
  assert.equal(calls, 1); assert.equal(core.loadSettings(target).settings.env.ANTHROPIC_AUTH_TOKEN, NEW); logs.safe();
});
test('quiet configuration hides routine output and still saves defaults with exact backup', async t => {
  const { target } = fixture(t); const before = existing(target); const logs = logger();
  const result = await core.main({ target, quiet: true, interaction: { choice: () => 'replace', secret: () => NEW }, log: logs.log });
  assert.deepEqual(fs.readFileSync(result.backup), before);
  const env = core.loadSettings(target).settings.env;
  assert.equal(env.ANTHROPIC_AUTH_TOKEN, NEW);
  assert.equal(env.ANTHROPIC_DEFAULT_SONNET_MODEL, 'claude-sonnet-5');
  assert.equal(env.CLAUDE_CODE_SUBAGENT_MODEL, 'claude-haiku-5-5');
  assert.ok(logs.output.every(text => text.startsWith('注意：'))); logs.safe();
});
test('quiet cancellation still rejects without changing the original configuration', async t => {
  const { target } = fixture(t); const before = existing(target);
  await assert.rejects(core.main({ target, quiet: true, interaction: { choice() { throw new DialogError('已取消'); } }, log() {} }), DialogError);
  assert.deepEqual(fs.readFileSync(target), before);
  assert.equal(fs.readdirSync(path.dirname(target)).length, 1);
});
test('keep button never asks for input and preserves key/settings idempotently', async t => {
  const { target } = fixture(t); const before = existing(target); const logs = logger();
  await core.main({ target, interaction: { choice: () => 'keep', secret() { assert.fail('keep must not open secret dialog'); } }, log: logs.log });
  assert.deepEqual(fs.readFileSync(target), before); assert.equal(fs.readdirSync(path.dirname(target)).length, 1); logs.safe();
});
test('replace button opens input and backs up exact original bytes', async t => {
  const { target } = fixture(t); const before = existing(target); const logs = logger(); let input = false;
  const result = await core.main({ target, interaction: { choice: () => 'replace', secret() { input = true; return NEW; } }, log: logs.log });
  assert.ok(input); assert.deepEqual(fs.readFileSync(result.backup), before);
  const settings = core.loadSettings(target).settings;
  assert.equal(settings.env.ANTHROPIC_AUTH_TOKEN, NEW); assert.equal(settings.env.KEEP, 'untouched'); logs.safe();
});
for (const mode of ['choice', 'secret']) {
  test('cancel in ' + mode + ' leaves original bytes and directory unchanged', async t => {
    const { target } = fixture(t); const before = existing(target);
    const interaction = { choice() { if (mode === 'choice') throw new DialogError('已取消，配置未修改。'); return 'replace'; }, secret() { throw new DialogError('已取消，配置未修改。'); } };
    await assert.rejects(core.main({ target, interaction, log() {} }), DialogError);
    assert.deepEqual(fs.readFileSync(target), before); assert.equal(fs.readdirSync(path.dirname(target)).length, 1);
  });
}
test('cancel initial input does not create config directory or backups', async t => {
  const { target } = fixture(t);
  await assert.rejects(core.main({ target, interaction: { secret() { throw new DialogError('已取消'); } }, log() {} }), DialogError);
  assert.ok(!fs.existsSync(path.dirname(target)));
});
test('key for another gateway is not silently retained for company gateway', async t => {
  const { target } = fixture(t); existing(target, OLD, 'https://other.invalid');
  await core.main({ target, interaction: { choice() { assert.fail('other gateway key is not reusable'); }, secret: () => NEW }, log() {} });
  assert.equal(core.loadSettings(target).settings.env.ANTHROPIC_AUTH_TOKEN, NEW);
});
for (const platform of ['darwin', 'win32']) {
  test(platform + ' dialog subprocess pipes output and never receives key in argv/input/env', () => {
    const calls = [];
    const run = (command, args, options) => { calls.push({ command, args, options }); return { status: 0, stdout: platform === 'darwin' ? 'set\n' + NEW + '\n' : JSON.stringify({ action: 'set', token: NEW }), stderr: '' }; };
    const dialogs = createDialogs({ platform, run, environment: { SystemRoot: 'C:\\Windows' } });
    assert.equal(dialogs.secret(), NEW);
    const { command, args, options } = calls[0];
    assert.ok(!JSON.stringify([command, args, options]).includes(NEW));
    assert.deepEqual(options.stdio, ['pipe', 'pipe', 'pipe']);
    if (platform === 'win32') { assert.ok(args.includes('-STA')); assert.ok(args.includes('secret')); }
  });
  test(platform + ' cancel is explicit and does not fall back to terminal', () => {
    const dialogs = createDialogs({ platform, run: () => ({ status: 0, stdout: platform === 'darwin' ? 'cancel\n' : '{"action":"cancel"}' }) });
    assert.throws(() => dialogs.secret(), error => error instanceof DialogError && /已取消/.test(error.message));
    assert.throws(() => dialogs.choice(), DialogError);
  });
  test(platform + ' errors cannot expose captured stdout/stderr secrets', () => {
    const dialogs = createDialogs({ platform, run: () => ({ status: 1, stdout: NEW, stderr: OLD }) });
    assert.throws(() => dialogs.secret(), error => error instanceof DialogError && !error.message.includes(OLD) && !error.message.includes(NEW));
  });
}
test('Mac empty input shows a warning dialog and retries with no key in warning source', () => {
  const replies = ['set\n\n', '', 'set\n' + NEW + '\n']; let index = 0;
  const dialogs = createDialogs({ platform: 'darwin', run: () => ({ status: 0, stdout: replies[index++] }) });
  assert.equal(dialogs.secret(), NEW); assert.equal(index, 3);
});
test('keep and replace choice results parse consistently on both systems', () => {
  for (const action of ['keep', 'replace']) {
    assert.deepEqual(parseResult('darwin', 'choice', action + '\n'), { action });
    assert.deepEqual(parseResult('win32', 'choice', JSON.stringify({ action })), { action });
  }
});
test('malformed dialog responses are rejected with safe errors', () => {
  for (const output of [NEW, 'null', '[]', '{"action":"error"}', '{"action":"set"}']) {
    assert.throws(() => parseResult('win32', 'secret', output), error => error instanceof DialogError && !error.message.includes(NEW));
  }
});
test('dialog input validation rejects blank, multiline, controls and excessive length', () => {
  for (const token of ['', 'a b', 'a\nb', 'a\u0000b', 'a\u00a0b', 'x'.repeat(8193)]) assert.equal(validToken(token), false);
  assert.equal(validToken(NEW), true);
});
test('Windows helper is BOM/CRLF, visible and emits only one final JSON write', () => {
  const bytes = fs.readFileSync(path.join(__dirname, '../common/key-dialog.ps1'));
  assert.deepEqual(bytes.subarray(0, 3), Buffer.from([0xef, 0xbb, 0xbf]));
  const text = bytes.toString('utf8'); assert.ok(!text.replaceAll('\r\n', '').includes('\n'));
  assert.equal(text.match(/\[Console\]::Write\(/g).length, 1);
  assert.ok(text.includes('$box.UseSystemPasswordChar = $false'));
  assert.ok(text.includes('$form.AcceptButton = $keep'));
  assert.ok(text.includes('$box.Clear()'));
  assert.ok(!/Write-Host|Write-Output|Read-Host/.test(text));
});
