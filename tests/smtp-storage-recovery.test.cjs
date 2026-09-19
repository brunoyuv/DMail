const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
const stored = source.match(/async function storedSecret\([\s\S]*?\n}/)?.[0];
assert.ok(stored, 'Shipping Asset reader must exist');
const method = name => {
  const value = source.match(new RegExp(`  (?:private )?(?:async )?${name}\\([\\s\\S]*?\\n  }`))?.[0];
  assert.ok(value, `Shipping AccountStore.${name} must exist`); return value;
};
const methods = ['smtp', 'readSmtp', 'gmailSmtpDefaults'].map(method).join('\n');
const plain = value => JSON.parse(JSON.stringify(value));
const encode = text => new TextEncoder().encode(text);
const basic = text => encode(Buffer.from(text).toString('base64'));
const defaultAccount = () => ({ id: 'synthetic-a', serverId: 'server-a', sessionUrl: 'imaps://imap.gmail.com:993',
  authentication: '', emailAddress: 'display@example.invalid', username: '' });
const valid = () => ({ endpoint: 'smtps://custom.example.invalid:2465', username: '独立-login', password: 'synthetic-only' });
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function fixture() {
  const state = { secrets: new Map(), queried: [], buffers: [], decoded: [], missing: 'empty',
    beforeQuery: async () => {}, account: defaultAccount(), rows: 0, beforeRows: async () => {} };
  const tags = { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3 };
  const asset = { Tag: tags, ReturnType: { ALL: 10 }, ErrorCode: { NOT_FOUND: 24000002 },
    query: async query => {
      assert.equal(query.get(tags.RETURN_TYPE), 10);
      const alias = new TextDecoder().decode(query.get(tags.ALIAS)); state.queried.push(alias);
      await state.beforeQuery(alias);
      if (!state.secrets.has(alias)) {
        if (state.missing === 'empty') return [];
        throw { code: state.missing === 'not-found' ? 24000002 : 24000005 };
      }
      const value = state.secrets.get(alias);
      if (value instanceof Uint8Array) {
        const copy = value.slice(); state.buffers.push(copy); return [new Map([[tags.SECRET, copy]])];
      }
      return [new Map(value === undefined ? [] : [[tags.SECRET, value]])];
    }
  };
  const util = {
    TextEncoder: class { encodeInto(text) { return encode(text); } },
    TextDecoder: class { constructor(label, options) { this.decoder = new TextDecoder(label, options); }
      decodeToString(bytes) { return this.decoder.decode(bytes); } },
    Base64Helper: class { decodeSync(text) { const bytes = new Uint8Array(Buffer.from(text, 'base64')); state.decoded.push(bytes); return bytes; } }
  };
  class SmtpSettings { endpoint = ''; username = ''; password = ''; }
  const Host = new Function('asset', 'util', 'SmtpSettings', 'RegisteredMailOAuth', compile(`${stored}\nclass Host { ${methods} }; return Host;`))(
    asset, util, SmtpSettings, { incoming: provider => { assert.equal(provider, 'google'); return 'imaps://imap.gmail.com:993'; } });
  const store = new Host(); store.pending = Promise.resolve();
  store.smtpAlias = id => `smtp.${id}`; store.alias = id => `imap.${id}`;
  store.enqueue = operation => { const task = store.pending.then(operation); store.pending = task.catch(() => {}); return task; };
  store.rows = async sql => { assert.equal(sql, "SELECT * FROM accounts WHERE status = 'ready'"); ++state.rows;
    await state.beforeRows(state.rows); return state.account ? [plain(state.account)] : []; };
  const account = defaultAccount();
  return { store, state, account, save: value => state.secrets.set(`smtp.${account.id}`, encode(JSON.stringify(value))),
    basic: value => state.secrets.set(`imap.${account.id}`, basic(value)) };
}
function cleared(state) { assert.ok(state.buffers.every(bytes => bytes.every(byte => byte === 0)), 'Every returned credential buffer is cleared');
  assert.ok(state.decoded.every(bytes => bytes.every(byte => byte === 0)), 'Decoded login buffers are cleared'); }

test('SMTP reads distinguish truly absent records from protected-store failures', async () => {
  for (const missing of ['empty', 'not-found']) {
    const f = fixture(); f.state.missing = missing;
    assert.deepEqual(plain(await f.store.smtp(f.account)), { endpoint: '', username: '', password: '' });
    assert.deepEqual(f.state.queried, ['smtp.synthetic-a']);
  }
  const f = fixture(); f.state.missing = 'unavailable';
  await assert.rejects(f.store.smtp(f.account), /^Error: Outgoing settings are unavailable$/);
});

test('A present Asset without a usable byte secret is an error, never blank SMTP defaults', async () => {
  for (const secret of [undefined, null, 'synthetic-only', [1, 2], new Uint8Array(0)]) {
    const f = fixture(); f.state.secrets.set('smtp.synthetic-a', secret);
    await assert.rejects(f.store.smtp(f.account), /^Error: Outgoing settings are unavailable$/);
    cleared(f.state);
  }
});

test('Malformed SMTP payloads are rejected and their buffers cleared', async () => {
  const malformed = ['{', 'null', '[]', '42', '{}', ...[
    { ...valid(), endpoint: '' }, { ...valid(), endpoint: 4 }, { ...valid(), username: '' },
    { ...valid(), username: 4 }, { ...valid(), password: null },
    { ...valid(), endpoint: 'https://example.invalid:443' }, { ...valid(), endpoint: 'smtp://example.invalid:587\n' },
    { ...valid(), endpoint: 'smtp://example.invalid :587' }, { ...valid(), endpoint: 'smtp://example.invalid\\:587' },
    { ...valid(), endpoint: 'smtp://' + 'a'.repeat(1024) }, { ...valid(), username: 'a\nprivate' },
    { ...valid(), password: 'a\rprivate' }, { ...valid(), username: 'a'.repeat(513) },
    { ...valid(), password: 'a'.repeat(1025) }
  ].map(JSON.stringify), ' '.repeat(4097)];
  for (const value of malformed) {
    const f = fixture(); f.state.secrets.set('smtp.synthetic-a', encode(value));
    await assert.rejects(f.store.smtp(f.account), /^Error: Outgoing settings are unavailable$/);
    cleared(f.state);
  }
  const f = fixture();
  f.state.secrets.set('smtp.synthetic-a', new Uint8Array(Buffer.concat([
    Buffer.from('{"endpoint":"smtp://example.invalid:587","username":"'), Buffer.from([0xff]),
    Buffer.from('","password":"synthetic-only"}')
  ])));
  await assert.rejects(f.store.smtp(f.account), /^Error: Outgoing settings are unavailable$/); cleared(f.state);
});

test('Valid custom settings, native endpoint forms and intentionally blank passwords survive reads unchanged', async () => {
  for (const settings of [valid(), { endpoint: 'smtp://smtp.gmail.com:587', username: 'bound@gmail.test', password: '' },
    { endpoint: 'smtps://smtp.gmail.com:465', username: 'bound@gmail.test', password: 'synthetic:only' },
    ...['smtp://custom.example.invalid', 'smtps://custom.example.invalid/', 'smtp://custom.example.invalid:587/',
      'smtps://[2001:db8::1]:465', 'smtp://[2001:db8::1]', 'smtps://mail_legacy.example.invalid:465',
      'smtp://例え.invalid:587'].map(endpoint => ({ ...valid(), endpoint })), { ...valid(), username: ' ' }]) {
    const f = fixture(); f.save(settings);
    assert.deepEqual(await f.store.smtp(f.account), settings); cleared(f.state);
    assert.deepEqual(f.state.queried, ['smtp.synthetic-a']);
    assert.equal(f.state.rows, 0);
  }
});

test('SMTP reads wait for pending writes before retrieving their original account record', async () => {
  const f = fixture(), held = deferred(); f.store.pending = held.promise;
  const read = f.store.smtp(f.account); await Promise.resolve(); assert.equal(f.state.queried.length, 0);
  f.save(valid()); held.resolve(); assert.deepEqual(await read, valid()); cleared(f.state);
});

test('Explicit Gmail recovery proposes the saved Basic login at exact SMTPS465 without writing or networking', async () => {
  for (const missing of ['empty', 'not-found']) {
    const f = fixture(); f.state.missing = missing; f.basic('bound-login@gmail.test:synthetic:app-password');
    const before = Array.from(f.state.secrets, ([key, bytes]) => [key, bytes.slice()]);
    assert.deepEqual(plain(await f.store.gmailSmtpDefaults(f.account)), {
      endpoint: 'smtps://smtp.gmail.com:465', username: 'bound-login@gmail.test', password: 'synthetic:app-password'
    });
    assert.deepEqual(Array.from(f.state.secrets), before, 'Recovery only proposes fields and never persists them');
    assert.equal(f.state.rows, 3); cleared(f.state);
  }
});

test('Gmail recovery preserves existing SMTP settings and rejects corrupt or unavailable records', async () => {
  for (const record of [valid(), { endpoint: 'smtp://smtp.gmail.com:587', username: 'separate@gmail.test', password: '' }, {}]) {
    const f = fixture(); f.save(record); f.basic('bound@gmail.test:synthetic-password');
    const before = f.state.secrets.get('smtp.synthetic-a').slice();
    await assert.rejects(f.store.gmailSmtpDefaults(f.account));
    assert.deepEqual(f.state.secrets.get('smtp.synthetic-a'), before);
    assert.deepEqual(f.state.queried, ['smtp.synthetic-a']); cleared(f.state);
  }
  const f = fixture(); f.state.missing = 'unavailable';
  await assert.rejects(f.store.gmailSmtpDefaults(f.account));
  assert.deepEqual(f.state.queried, ['smtp.synthetic-a']);
});

test('OAuth, unrecognized Gmail endpoints and stale/removed account identities cannot recover Basic credentials', async () => {
  for (const change of [{ authentication: 'oauth' }, { authentication: 'other' },
    { sessionUrl: 'imaps://imap.gmail.com.evil.invalid:993' }, { sessionUrl: 'imaps://imap.gmail.com:1993' }]) {
    const f = fixture(); Object.assign(f.account, change);
    await assert.rejects(f.store.gmailSmtpDefaults(f.account)); assert.equal(f.state.queried.length, 0);
  }
  for (const change of [null, { serverId: 'replaced' }, { authentication: 'oauth' },
    { sessionUrl: 'imaps://example.invalid:993' }, { emailAddress: 'other@example.invalid' }, { username: 'other' }]) {
    const f = fixture(); f.state.account = change === null ? null : { ...f.state.account, ...change };
    await assert.rejects(f.store.gmailSmtpDefaults(f.account)); assert.equal(f.state.queried.length, 0);
  }
});

test('Removal, identity replacement or another SMTP save during credential waits wins over recovery', async () => {
  for (const change of ['removed', 'replaced', 'smtp']) {
    const f = fixture(); f.basic('bound@gmail.test:synthetic-password');
    f.state.beforeQuery = async alias => {
      if (alias !== 'imap.synthetic-a') return;
      if (change === 'removed') f.state.account = null;
      else if (change === 'replaced') f.state.account.serverId = 'new-server';
      else f.save(valid());
    };
    await assert.rejects(f.store.gmailSmtpDefaults(f.account)); cleared(f.state);
    if (change === 'smtp') assert.deepEqual(JSON.parse(new TextDecoder().decode(f.state.secrets.get('smtp.synthetic-a'))), valid());
  }
  const f = fixture(); f.basic('bound@gmail.test:synthetic-password');
  f.state.beforeRows = async count => { if (count === 3) f.state.account = null; };
  await assert.rejects(f.store.gmailSmtpDefaults(f.account)); cleared(f.state);
});

test('Missing and malformed saved Basic credentials never produce recovery proposals and clear byte buffers', async () => {
  for (const value of [undefined, encode('not-base64'), encode('!!!!'), encode('YQ=='),
    basic(':synthetic-password'), basic('bound@gmail.test:'), basic('bound\n@gmail.test:synthetic-password'),
    basic('bound@gmail.test:bad\npassword'), basic('a'.repeat(513) + ':synthetic-password'),
    basic('bound@gmail.test:' + 'a'.repeat(1025)), encode(Buffer.from([0xff, 0x3a, 0x61]).toString('base64'))]) {
    const f = fixture(); if (value !== undefined) f.state.secrets.set('imap.synthetic-a', value);
    await assert.rejects(f.store.gmailSmtpDefaults(f.account)); cleared(f.state);
  }
});
