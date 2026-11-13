'use strict';
process.env.AI_GATEWAY_URL = 'https://gateway.example.com';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Readable } = require('node:stream');
const core = require('../common/configure.cjs');
const { MAC_SECRET, MAC_CHOICE } = require('../common/dialogs.cjs');
const KEY = 'prepared-fake-key-"-not-a-real-secret';
function fixture(t) {
  const base = fs.realpathSync(os.tmpdir());
  const dir = fs.mkdtempSync(path.join(base, 'claude-prepared-test-'));
  t.after(() => {
    const absolute = fs.realpathSync(dir);
    assert.equal(path.dirname(absolute), base);
    assert.ok(path.basename(absolute).startsWith('claude-prepared-test-'));
    fs.rmSync(absolute, { recursive: true });
  });
  return { dir, target: path.join(dir, 'config', 'settings.json') };
}
function request(target, expectedDigest = null, token = KEY) {
  return Buffer.from(JSON.stringify({ token, target, expectedDigest }));
}
function noKey(value, key = KEY) {
  const text = JSON.stringify(value);
  assert.ok(!text.includes(key));
  assert.ok(!text.includes(JSON.stringify(key).slice(1, -1)));
}
test('Mac GUI is visible and fixed positive-choice wording', () => {
  assert.ok(!MAC_SECRET.includes('hidden answer'));
  assert.ok(MAC_SECRET.includes('请输入网关密钥'));
  for (const label of ['检测到已有网关密钥，是否使用？', '使用现有密钥', '输入新密钥', '取消']) assert.ok(MAC_CHOICE.includes(label));
});
test('JSON syntax diagnostics include exact position without source text', () => {
  const source = '{\n  "env": {},\n  "private": "' + KEY.replaceAll('"', '\\"') + '",\n  "broken": }';
  assert.throws(() => core.parseSettings(source), error => {
    assert.equal(error.code, 'CFG-JSON-001'); assert.equal(error.line, 4); assert.equal(error.column, 13);
    noKey(error.message); return true;
  });
});
test('JSON duplicate escaped key and unsafe number report their own line', () => {
  for (const [source, code] of [['{\n "a": 1,\n "\\u0061":2}', 'CFG-DUPLICATE-001'], ['{\n "n":9007199254740993}', 'CFG-NUMBER-001']]) {
    assert.throws(() => core.parseSettings(source), error => { assert.equal(error.code, code); assert.ok(error.line >= 2); return true; });
  }
});
test('malformed syntax and excessive depth terminate with controlled errors', () => {
  for (const source of ['{"x":"\\q"}', '{"x":"unterminated}', '{"x":01}', '{"x":truefalse}', '{"x":1e}', '{"x":[1,]}', '{"x":1}\u00a0', '['.repeat(258) + '0' + ']'.repeat(258)]) {
    assert.throws(() => core.parseSettings(source), core.SetupError);
  }
});
test('Unicode whitespace is invalid in keys', () => {
  for (const key of ['a\u00a0b', 'a\u3000b', 'a\u2028b']) assert.throws(() => core.mergeSettings({}, key), core.SetupError);
});
test('prepared first save returns one non-secret status and does not need GUI', async t => {
  const { target } = fixture(t);
  const result = await core.preparedMain(request(target));
  assert.equal(result.ok, true); assert.equal(result.state, 'saved'); assert.equal(result.verified, false);
  assert.deepEqual(result.warnings, []); assert.equal(result.backup, null); noKey(result);
  assert.equal(core.loadSettings(target).settings.env.ANTHROPIC_AUTH_TOKEN, KEY);
});
test('prepared existing save backs up exact bytes and keeps conflict warnings', async t => {
  const { target } = fixture(t); fs.mkdirSync(path.dirname(target));
  const original = Buffer.from('\ufeff{\r\n "model":"personal", "env":{"ANTHROPIC_API_KEY":"other-fake-credential"}\r\n}\r\n');
  fs.writeFileSync(target, original);
  const result = await core.preparedMain(request(target, core.digest(original)));
  assert.equal(result.ok, true); assert.equal(result.warnings.length, 1); noKey(result);
  assert.deepEqual(fs.readFileSync(result.backup), original);
  assert.equal(core.loadSettings(target).settings.model, 'personal');
});
test('preflight snapshot mismatch refuses to overwrite or create backup', async t => {
  const { target } = fixture(t); fs.mkdirSync(path.dirname(target)); fs.writeFileSync(target, '{"changed":true}');
  const result = await core.preparedMain(request(target, core.digest(Buffer.from('{}'))));
  assert.equal(result.ok, false); assert.equal(result.diagnostic.code, 'CFG-CONCURRENT-001');
  assert.equal(result.diagnostic.state, 'unchanged'); assert.equal(fs.readFileSync(target, 'utf8'), '{"changed":true}');
  assert.deepEqual(fs.readdirSync(path.dirname(target)), ['settings.json']); noKey(result);
});
test('new file appearing after preflight is never overwritten', async t => {
  const { target } = fixture(t); fs.mkdirSync(path.dirname(target)); fs.writeFileSync(target, '{}');
  const result = await core.preparedMain(request(target));
  assert.equal(result.ok, false); assert.equal(result.diagnostic.code, 'CFG-CONCURRENT-001');
  assert.equal(fs.readFileSync(target, 'utf8'), '{}');
});
test('invalid request and invalid key never create configuration directory', async t => {
  const { target } = fixture(t);
  for (const input of [request('relative/settings.json'), request(target, 'invalid-digest'), request(target, null, ''), Buffer.from('{"token":"secret",')]) {
    const result = await core.preparedMain(input); assert.equal(result.ok, false); noKey(result);
  }
  assert.equal(fs.existsSync(path.dirname(target)), false);
});
test('unexpected filesystem errors retain concrete cause, safe OS details and save state', async t => {
  const { target } = fixture(t);
  const original = fs.renameSync;
  t.after(() => { fs.renameSync = original; });
  fs.renameSync = () => { const error = new Error('rename denied ' + KEY); error.code = 'EACCES'; error.syscall = 'rename'; error.errno = -13; throw error; };
  const result = await core.preparedMain(request(target));
  assert.equal(result.ok, false); assert.equal(result.diagnostic.code, 'EACCES');
  assert.equal(result.diagnostic.stage, 'save'); assert.equal(result.diagnostic.state, 'saving');
  assert.ok(result.diagnostic.reason.includes('rename denied')); assert.ok(result.diagnostic.reason.includes('-13')); noKey(result);
  assert.equal(fs.existsSync(target), false);
});
test('explicit state object reaches saved only after replacement or idempotent success', t => {
  const { target } = fixture(t), state = {};
  const settings = core.mergeSettings({}, KEY);
  core.saveSettings(target, null, settings, state); assert.equal(state.value, 'saved');
  const second = {};
  core.saveSettings(target, core.loadSettings(target).bytes, settings, second); assert.equal(second.value, 'saved');
});
test('stdin CLI keeps key outside arguments and returns exactly one JSON record', t => {
  const { target } = fixture(t), script = path.join(__dirname, '../common/configure.cjs');
  const result = spawnSync(process.execPath, [script, '--prepared-stdin'], { input: request(target), encoding: 'utf8', env: { ...process.env, ANTHROPIC_API_KEY: '' } });
  assert.equal(result.status, 0, result.stderr); assert.equal(result.stderr, '');
  assert.equal(result.stdout.trim().split('\n').length, 1);
  assert.equal(JSON.parse(result.stdout).ok, true); noKey(result.stdout); noKey(result.stderr);
});
test('stdin size cap is enforced without printing any input data', async () => {
  await assert.rejects(core.readPreparedInput(Readable.from([Buffer.alloc(65537, 97)])), error => { assert.equal(error.code, 'CFG-REQUEST-002'); return true; });
});
test('diagnostic redaction covers literal, JSON-escaped and authorization variants', () => {
  const message = `${KEY}\n${JSON.stringify(KEY).slice(1, -1)}\nAuthorization: Bearer another-credential\n{"env":{"private":"raw-config"}}`;
  const result = core.redactDiagnostic(message, [KEY]); noKey(result);
  assert.ok(!result.includes('another-credential')); assert.ok(!result.includes('raw-config'));
  assert.ok(core.redactDiagnostic('EACCES permission denied', [KEY]).includes('EACCES permission denied'));
});

test('short credential cannot corrupt controlled diagnostic state/stage/code', () => {
  const error = new Error('permission denied a'); error.code = 'EACCES';
  const result = core.errorDiagnostic(error, { stage: 'save', state: 'saving', tokens: ['a'] });
  assert.equal(result.stage, 'save'); assert.equal(result.state, 'saving'); assert.equal(result.code, 'EACCES');
});
