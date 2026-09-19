const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const model = { exports: {} };
new Function('module', 'exports', compile(fs.readFileSync('harmony/entry/src/main/ets/mail/oauth/RegisteredMailOAuth.ets', 'utf8')))(model, model.exports);
const { RegisteredMailOAuth } = model.exports;
const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
const methods = ['oauthAccessToken', 'oauthTokenForEndpoint', 'saveSmtp'].map(name => {
  const found = source.match(new RegExp(`  (?:private )?(?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found, `Shipping AccountStore.${name} must exist`); return found[0];
}).join('\n');
class JmapError extends Error { constructor(code) { super(code); this.code = code; } }
function fixture(provider = 'google') {
  const account = { id: 'synthetic', authentication: 'oauth', username: 'sender@example.test',
    sessionUrl: RegisteredMailOAuth.incoming(provider) };
  const login = { username: account.username, registration: { provider,
    clientID: RegisteredMailOAuth.clientID(provider), redirectURI: 'http://127.0.0.1:49152/oauth2redirect',
    ...(provider === 'microsoft' ? { microsoftPersonalOnly: true } : {}) },
    tokens: { accessToken: 'synthetic-bearer-only', refreshToken: 'synthetic-refresh-only', expiresAt: Date.now() / 1000 + 3600 } };
  const state = { writes: [], envelopes: 0, refreshes: 0, notifications: 0, ready: true };
  const asset = { Tag: { ALIAS: 1, SECRET: 2 }, update: async (query, update) => {
    state.writes.push({ alias: Buffer.from(query.get(1)).toString(), settings: JSON.parse(Buffer.from(update.get(2)).toString()) });
  }, ErrorCode: { NOT_FOUND: 1 } };
  const util = { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } };
  const Host = new Function('RegisteredMailOAuth', 'OAuthSecretBox', 'JmapError', 'util', 'asset',
    compile(`class Host { ${methods} }; return Host;`))(RegisteredMailOAuth,
    { open: async (_alias, envelope) => envelope }, JmapError, util, asset);
  const store = new Host();
  store.pending = Promise.resolve(); store.refreshing = new Map(); store.oauthRequests = new Set();
  store.oauthAlias = () => 'synthetic-oauth'; store.smtpAlias = () => 'synthetic-smtp';
  store.oauthEnvelope = async () => { state.envelopes++; return JSON.stringify(login); };
  store.enqueue = task => { const next = store.pending.then(task); store.pending = next.catch(() => {}); return next; };
  store.database = () => ({ querySql: async (_sql, values) => {
    assert.deepEqual(values, [account.id]);
    return { goToFirstRow: () => state.ready, close() {} };
  } });
  store.refreshOAuth = async () => { state.refreshes++; throw new Error('No refresh request is allowed by this fixture'); };
  store.notificationSettings = async () => { state.notifications++; return { enabled: true }; };
  const settings = endpoint => ({ endpoint, username: account.username, password: '' });
  return { store, account, login, state, settings };
}

test('Google OAuth accepts only its exact STARTTLS587 and implicit-TLS465 destinations; Outlook keeps its existing endpoint', () => {
  for (const endpoint of ['smtp://smtp.gmail.com:587', 'smtps://smtp.gmail.com:465']) {
    assert.equal(RegisteredMailOAuth.allowsOutgoing('google', endpoint), true);
    assert.equal(RegisteredMailOAuth.allowsOutgoing('microsoft', endpoint), false);
  }
  assert.equal(RegisteredMailOAuth.allowsOutgoing('microsoft', 'smtp://smtp-mail.outlook.com:587'), true);
  for (const endpoint of ['smtp://smtp.gmail.com:465', 'smtps://smtp.gmail.com:587', 'smtp://smtp.gmail.com:25',
    'smtps://smtp.gmail.com.evil.test:465', 'smtps://smtp.gmail.com@evil.test:465', 'smtps://evil.test:465',
    'smtps://smtp.gmail.com:465/path', 'smtps://smtp.gmail.com:465?host=evil.test', 'smtps://smtp.gmail.com:465#evil',
    'smtps://smtp.gmail.com.:465', 'smtps://smtp-mail.outlook.com:465', 'https://smtp.gmail.com:465']) {
    assert.equal(RegisteredMailOAuth.allowsOutgoing('google', endpoint), false, endpoint);
    assert.equal(RegisteredMailOAuth.allowsOutgoing('microsoft', endpoint), false, endpoint);
  }
});

test('Both Gmail settings persist locally and release the same valid token only to the bound SMTP login', async () => {
  const { store, account, state, settings } = fixture();
  for (const endpoint of ['smtp://smtp.gmail.com:587', 'smtps://smtp.gmail.com:465']) {
    const value = settings(endpoint);
    await store.saveSmtp(account, value);
    assert.deepEqual(state.writes.at(-1), { alias: 'synthetic-smtp', settings: value });
    assert.equal(await store.oauthAccessToken(account, value), 'synthetic-bearer-only');
  }
  assert.equal(state.writes.length, 2); assert.equal(state.refreshes, 0); assert.equal(state.notifications, 0);
});

test('OAuth settings reject changed hosts, transport pairs, usernames and account binding before persistence or token release', async () => {
  const { store, account, login, state, settings } = fixture();
  await store.saveSmtp(account, settings('smtp://smtp.gmail.com:587'));
  for (const value of [settings('smtps://evil.test:465'), settings('smtp://smtp.gmail.com:465'),
    { ...settings('smtps://smtp.gmail.com:465'), username: 'different@example.test' }]) {
    await assert.rejects(store.saveSmtp(account, value), error => error.code === 'unsafeEndpoint');
    await assert.rejects(store.oauthAccessToken(account, value), error => error.code === 'authenticationRequired');
  }
  login.username = 'different@example.test';
  await assert.rejects(store.saveSmtp(account, settings('smtps://smtp.gmail.com:465')), error => error.code === 'authenticationRequired');
  await assert.rejects(store.oauthAccessToken(account, settings('smtps://smtp.gmail.com:465')), error => error.code === 'authenticationRequired');
  assert.equal(state.writes.length, 1, 'Rejected edits preserve the previous saved settings');
  assert.equal(state.refreshes, 0);
});

test('Saving valid expired-token settings stays local; background callers never receive SMTP credentials', async () => {
  const { store, account, login, state, settings } = fixture();
  login.tokens.expiresAt = 1;
  await store.saveSmtp(account, settings('smtps://smtp.gmail.com:465'));
  assert.equal(state.refreshes, 0); assert.equal(state.writes.length, 1);
  const reads = state.envelopes;
  await assert.rejects(store.oauthAccessToken(account, settings('smtps://smtp.gmail.com:465'), true), error => error.code === 'authenticationRequired');
  assert.equal(state.envelopes, reads, 'Background SMTP is denied before opening protected login data');
});

test('Outlook and password SMTP settings retain their existing behavior', async () => {
  const f = fixture('microsoft');
  await f.store.saveSmtp(f.account, f.settings('smtp://smtp-mail.outlook.com:587'));
  assert.equal(await f.store.oauthAccessToken(f.account, f.settings('smtp://smtp-mail.outlook.com:587')), 'synthetic-bearer-only');
  await assert.rejects(f.store.saveSmtp(f.account, f.settings('smtps://smtp-mail.outlook.com:465')), error => error.code === 'unsafeEndpoint');
  assert.equal(f.state.writes.length, 1);
  const plain = fixture(); plain.account.authentication = '';
  const value = { endpoint: 'smtps://mail.example.test:2465', username: 'separate-login', password: 'synthetic-password' };
  await plain.store.saveSmtp(plain.account, value);
  assert.deepEqual(plain.state.writes[0].settings, value); assert.equal(plain.state.envelopes, 0);
});

test('A password settings write queued after account removal cannot recreate SMTP credentials', async () => {
  const f = fixture(); f.account.authentication = '';
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const removal = f.store.enqueue(async () => { await held; f.state.ready = false; });
  const save = f.store.saveSmtp(f.account, f.settings('smtps://mail.example.test:465'));
  const rejected = assert.rejects(save, /Account is unavailable/);
  release(); await removal; await rejected;
  assert.equal(f.state.writes.length, 0);
});
