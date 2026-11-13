'use strict';
process.env.AI_GATEWAY_URL = 'https://gateway.example.com';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const core = require('../common/configure.cjs');
const fakeKey = 'test-key-not-a-real-secret';
function fixture(t) {
  const base = fs.realpathSync(os.tmpdir());
  const dir = fs.mkdtempSync(path.join(base, 'claude-config-test-'));
  t.after(() => {
    const resolved = fs.realpathSync(dir);
    assert.equal(path.dirname(resolved), base);
    assert.ok(path.basename(resolved).startsWith('claude-config-test-'));
    fs.rmSync(resolved, { recursive: true });
  });
  return { dir, target: path.join(dir, '.claude', 'settings.json') };
}
test('default models match configured model defaults and base URL has no /v1', () => {
  const result = core.mergeSettings({}, fakeKey);
  assert.equal(result.env.ANTHROPIC_BASE_URL, 'https://gateway.example.com');
  assert.equal(result.env.ANTHROPIC_AUTH_TOKEN, fakeKey);
  assert.deepEqual(result.env, {
    ANTHROPIC_BASE_URL: 'https://gateway.example.com',
    ANTHROPIC_AUTH_TOKEN: fakeKey,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: 'claude-haiku-5-5',
    ANTHROPIC_DEFAULT_OPUS_MODEL: 'claude-sonnet-5-5',
    ANTHROPIC_DEFAULT_SONNET_MODEL: 'claude-sonnet-5-5',
    ANTHROPIC_DEFAULT_FABLE_MODEL: 'claude-sonnet-5-5',
  });
});
test('existing model choices and legacy global/subagent overrides are preserved', () => {
  const models = {
    ANTHROPIC_DEFAULT_HAIKU_MODEL: 'personal-haiku',
    ANTHROPIC_DEFAULT_OPUS_MODEL: 'personal-opus',
    ANTHROPIC_DEFAULT_SONNET_MODEL: 'personal-sonnet',
    ANTHROPIC_DEFAULT_FABLE_MODEL: 'personal-fable',
    ANTHROPIC_MODEL: 'personal-main',
    CLAUDE_CODE_SUBAGENT_MODEL: 'personal-agent',
  };
  const original = { model: 'personal-top-level', env: { ...models, ANTHROPIC_BASE_URL: 'https://old.example.com', ANTHROPIC_AUTH_TOKEN: 'old-fake-key' } };
  const snapshot = JSON.stringify(original);
  const result = core.mergeSettings(original, fakeKey);
  for (const [key, model] of Object.entries(models)) assert.equal(result.env[key], model);
  assert.equal(result.model, original.model);
  assert.equal(result.env.ANTHROPIC_BASE_URL, 'https://gateway.example.com');
  assert.equal(result.env.ANTHROPIC_AUTH_TOKEN, fakeKey);
  assert.equal(JSON.stringify(original), snapshot);
});
test('partial existing model configuration fills only missing fields', () => {
  const result = core.mergeSettings({ env: { ANTHROPIC_DEFAULT_SONNET_MODEL: 'personal-sonnet' } }, fakeKey);
  assert.equal(result.env.ANTHROPIC_DEFAULT_SONNET_MODEL, 'personal-sonnet');
  assert.equal(result.env.ANTHROPIC_DEFAULT_HAIKU_MODEL, 'claude-haiku-5-5');
  assert.equal(result.env.ANTHROPIC_DEFAULT_OPUS_MODEL, 'claude-sonnet-5-5');
  assert.equal(result.env.ANTHROPIC_DEFAULT_FABLE_MODEL, 'claude-sonnet-5-5');
  assert.equal(Object.hasOwn(result.env, 'ANTHROPIC_MODEL'), false);
  assert.equal(Object.hasOwn(result.env, 'CLAUDE_CODE_SUBAGENT_MODEL'), false);
});
test('existing empty or non-string model fields are not silently replaced', () => {
  const env = { ANTHROPIC_DEFAULT_HAIKU_MODEL: '', ANTHROPIC_DEFAULT_OPUS_MODEL: null,
    ANTHROPIC_DEFAULT_SONNET_MODEL: false, ANTHROPIC_DEFAULT_FABLE_MODEL: 0 };
  const result = core.mergeSettings({ env }, fakeKey);
  for (const key of Object.keys(env)) assert.equal(result.env[key], env[key]);
});
test('legacy sonnet-only defaults survive repeated configuration unchanged', () => {
  const env = Object.fromEntries(Object.keys(core.DEFAULT_MODELS).map(key => [key, 'claude-sonnet-5']));
  env.ANTHROPIC_MODEL = 'claude-sonnet-5';
  env.CLAUDE_CODE_SUBAGENT_MODEL = 'claude-haiku-5-5';
  const first = core.mergeSettings({ env }, fakeKey);
  const second = core.mergeSettings(first, fakeKey);
  assert.deepEqual(second, first);
  for (const key of Object.keys(env)) assert.equal(second.env[key], env[key]);
});
test('gateway URL is supplied at runtime and normalizes origin and port', () => {
  assert.equal(core.gatewayUrl('https://OTHER.example.com:8443/'), 'https://other.example.com:8443');
  assert.equal(core.gatewayUrl('https://other.example.com:443/'), 'https://other.example.com');
  for (const value of [undefined, '', 'http://gateway.example.com', 'https://user@gateway.example.com',
    'https://gateway.example.com/v1', 'https://gateway.example.com?x=1', 'https://gateway.example.com#f',
    'https://gateway.example.com:0', 'https://gateway.example.com:65536', 'https://gateway.example.com\n']) {
    // Undefined selects the environment default, so validate missing separately below.
    if (value !== undefined) assert.throws(() => core.gatewayUrl(value), core.SetupError);
  }
});
test('missing gateway refuses configuration before prompting or saving', async t => {
  const { target } = fixture(t);
  const previous = process.env.AI_GATEWAY_URL;
  delete process.env.AI_GATEWAY_URL;
  try {
    await assert.rejects(core.main({ target, interaction: {
      choice() { assert.fail('must not ask for credentials'); },
      secret() { assert.fail('must not ask for credentials'); },
    } }), core.SetupError);
    assert.equal(fs.existsSync(path.dirname(target)), false);
  } finally { process.env.AI_GATEWAY_URL = previous; }
});
test('merge preserves unrelated settings and does not mutate input', () => {
  const original = { permissions: { allow: ['Read'] }, hooks: { Stop: [] }, model: 'custom', env: { KEEP: 'yes', ANTHROPIC_API_KEY: 'old' } };
  const snapshot = JSON.stringify(original);
  const result = core.mergeSettings(original, fakeKey);
  assert.equal(JSON.stringify(original), snapshot);
  assert.deepEqual(result.permissions, original.permissions);
  assert.deepEqual(result.hooks, original.hooks);
  assert.equal(result.model, 'custom');
  assert.equal(result.env.KEEP, 'yes');
  assert.equal(result.env.ANTHROPIC_API_KEY, 'old');
});
test('accept UTF-8 BOM and escaped JSON strings/arrays', () => {
  const input = '\ufeff{"env":{"KEEP":"引号\\\"和反斜杠\\\\"},"a":[1,true,null,{"x":1}]}';
  assert.equal(core.parseSettings(input).a[3].x, 1);
});
for (const input of ['[]', 'null', '{"env":null}', '{"env":[]}', '{"env":"wrong"}', 'not json', '{/* comment */}', '{"a":1,}']) {
  test('reject malformed/unsupported settings ' + input, () => assert.throws(() => core.parseSettings(input), core.SetupError));
}
for (const input of ['{"env":{},"env":{}}', '{"a":1,"\\u0061":2}', '{"nested":{"x":1,"x":2}}', '{"a":[{"k":1,"k":2}]}']) {
  test('reject duplicate keys ' + input, () => assert.throws(() => core.parseSettings(input), /重复/));
}
for (const key of ['', ' ', 'a b', 'a\nb', 'a\u0000b', 'x'.repeat(8193)]) {
  test('reject invalid key of length ' + key.length, () => {
    assert.throws(() => core.mergeSettings({}, key), core.SetupError);
  });
}
for (const input of ['{"n":9007199254740993}', '{"n":1e309}', '{"n":-9007199254740993}']) {
  test('refuse lossy number ' + input, () => assert.throws(() => core.parseSettings(input), /安全精度/));
}
test('default and overridden config paths', () => {
  const home = process.platform === 'win32' ? 'C:\\Users\\Test' : '/Users/test';
  assert.equal(core.configPath({}, home), path.join(home, '.claude', 'settings.json'));
  assert.equal(core.configPath({ CLAUDE_CONFIG_DIR: path.join(home, 'custom') }, home), path.join(home, 'custom', 'settings.json'));
  assert.throws(() => core.configPath({ CLAUDE_CONFIG_DIR: 'relative' }, home), core.SetupError);
});
test('new settings are created, no original backup needed', t => {
  const { target } = fixture(t);
  assert.deepEqual(core.loadSettings(target), { settings: {}, bytes: null });
  const result = core.mergeSettings({}, fakeKey);
  assert.equal(core.saveSettings(target, null, result), null);
  assert.deepEqual(core.loadSettings(target).settings, result);
  if (process.platform !== 'win32') assert.equal(fs.statSync(target).mode & 0o777, 0o600);
});
test('original bytes backed up exactly and unrelated settings preserved', t => {
  const { target } = fixture(t);
  fs.mkdirSync(path.dirname(target));
  const bytes = Buffer.from('\ufeff{\r\n "env": {"KEEP":"值"}, "permissions":{"deny":["Bash(rm *)"]}\r\n}\r\n');
  fs.writeFileSync(target, bytes);
  const original = core.loadSettings(target);
  const result = core.mergeSettings(original.settings, fakeKey);
  const backup = core.saveSettings(target, original.bytes, result);
  assert.deepEqual(fs.readFileSync(backup), bytes);
  assert.deepEqual(core.loadSettings(target).settings.permissions, original.settings.permissions);
  assert.equal(core.loadSettings(target).settings.env.KEEP, '值');
  if (process.platform !== 'win32') assert.equal(fs.statSync(backup).mode & 0o777, 0o600);
});
test('repeat same configuration is idempotent with no additional backup', t => {
  const { target } = fixture(t);
  const result = core.mergeSettings({}, fakeKey);
  core.saveSettings(target, null, result);
  const original = core.loadSettings(target);
  assert.equal(core.saveSettings(target, original.bytes, result), null);
  assert.deepEqual(fs.readdirSync(path.dirname(target)), ['settings.json']);
});
test('refuse overwriting concurrent changes', t => {
  const { target } = fixture(t);
  core.saveSettings(target, null, {});
  const original = core.loadSettings(target);
  fs.writeFileSync(target, '{"changed":true}');
  assert.throws(() => core.saveSettings(target, original.bytes, core.mergeSettings({}, fakeKey)), /修改/);
  assert.equal(fs.readFileSync(target, 'utf8'), '{"changed":true}');
});
test('invalid UTF-8 is refused without changing original', t => {
  const { target } = fixture(t);
  fs.mkdirSync(path.dirname(target));
  const bytes = Buffer.from([0xc3, 0x28]);
  fs.writeFileSync(target, bytes);
  assert.throws(() => core.loadSettings(target), /UTF-8/);
  assert.deepEqual(fs.readFileSync(target), bytes);
});
test('reject linked file and directory', { skip: process.platform === 'win32' }, t => {
  const { target, dir } = fixture(t);
  const actual = path.join(dir, 'actual');
  fs.mkdirSync(actual);
  fs.writeFileSync(path.join(actual, 'settings.json'), '{}');
  fs.symlinkSync(actual, path.dirname(target));
  assert.throws(() => core.loadSettings(target), /链接/);
  const link = path.join(dir, 'settings-link.json');
  fs.symlinkSync(path.join(actual, 'settings.json'), link);
  assert.throws(() => core.loadSettings(link), /链接/);
});
test('reject hardlinked configuration and oversized files', t => {
  const { target, dir } = fixture(t);
  fs.mkdirSync(path.dirname(target));
  fs.writeFileSync(target, '{}');
  fs.linkSync(target, path.join(dir, 'hardlink'));
  assert.throws(() => core.loadSettings(target), core.SetupError);
  const huge = path.join(dir, 'huge.json');
  fs.writeFileSync(huge, ' '.repeat(2 * 1024 * 1024 + 1));
  assert.throws(() => core.loadSettings(huge), core.SetupError);
});
