const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function model(file) {
  const module = { exports: {} };
  new Function('module', 'exports', compile(fs.readFileSync(file, 'utf8')))(module, module.exports);
  return module.exports;
}
const { RegisteredMailOAuth } = model('harmony/entry/src/main/ets/mail/oauth/RegisteredMailOAuth.ets');
const { oauthFailureLabel, oauthFailureCode } = model('harmony/entry/src/main/ets/mail/oauth/OAuthFailure.ets');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['signIn', 'reconnectProvider', 'reconnectOAuth', 'cancelSignIn'].map(name => {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([^\\n]*[\\s\\S]*?\\n  }`));
  if (name === 'cancelSignIn') return source.match(/  private cancelSignIn\(\): void \{[^\n]*\}/)[0];
  assert.ok(found, `Shipping ConnectedMail.${name} must exist`); return found[0];
}).join('\n');
class JmapError extends Error { constructor(code) { super(code); this.code = code; } }
class TokenCredentials { constructor(token, scheme, username) { this.token = token; this.scheme = scheme; this.username = username; } }
function fixture(googleBrowserSignInEnabled = true) {
  // Exercise the retained experimental path without changing the shipping default.
  const policy = Object.assign(Object.create(RegisteredMailOAuth), { googleBrowserSignInEnabled });
  const account = { id: 'saved-account', serverId: 'default', authentication: 'oauth',
    username: 'saved@example.test', emailAddress: 'alias@example.test', sessionUrl: RegisteredMailOAuth.incoming('google') };
  const state = { paths: ['read'], replacements: [], creates: [], resumed: [], signIns: [], scheduler: 0, credentialsChanged: [],
    cancelled: 0, connect: async () => ({ accounts: [{ id: 'default' }] }), signIn: async () => ({ accessToken: 'synthetic-new-token', expiresAt: Date.now() / 1000 + 3600 }) };
  const flow = { registration: { provider: 'google' }, failureStage: 'token',
    signIn: async (...args) => { state.signIns.push(args); return state.signIn(); }, cancel: () => { state.cancelled++; } };
  const Host = new Function('RegisteredMailOAuth', 'LoopbackBrowserSignIn', 'TokenCredentials', 'JmapError',
    'MailNotificationService', 'oauthFailureLabel', 'oauthFailureCode', compile(`class Host { ${methods} }; return Host;`))(
    policy, { forContext: () => flow }, TokenCredentials, JmapError,
    { settingsChanged: async () => { state.scheduler++; }, credentialsChanged: accountId => {
      assert.equal(accountId, state.replacements.at(-1)[0].id, 'Invalidate only the account whose credentials were replaced');
      state.credentialsChanged.push(accountId);
    } }, oauthFailureLabel, oauthFailureCode);
  const ui = Object.assign(new Host(), { active: true, busy: false, generation: 10, oauthPending: false, error: '', account,
    selectedId: 'old-mail', mailboxId: 'inbox', paths: { getAllPathName: () => state.paths }, label: name => name,
    getUIContext: () => ({ getHostContext: () => ({}) }),
    accountStore: { replaceOAuth: async (...args) => { state.replacements.push(args); }, credentials: () => ({ saved: true }) },
    clientFactory: { create: (endpoint, credentials) => { state.creates.push({ endpoint, credentials }); return { connect: () => state.connect() }; } },
    refreshReader: async () => { throw new Error('Reconnect must not fetch the open reader body'); },
    loadPage: async refresh => { state.resumed.push(['page', refresh]); }, refreshMailbox: async () => { state.resumed.push('mailbox'); },
    loadBoxes: async preferCache => { state.resumed.push(['boxes', preferCache]); }
  });
  return { ui, state, account };
}

test('Default package blocks Google sign-in and reconnect before browser, mail or storage work', async () => {
  assert.equal(RegisteredMailOAuth.googleBrowserSignInEnabled, false);
  const { ui, state, account } = fixture(RegisteredMailOAuth.googleBrowserSignInEnabled);
  await ui.signIn('google');
  assert.equal(ui.error, 'gmail_app_password_help');
  assert.equal(ui.reconnectProvider(account), null);
  await ui.reconnectOAuth(account);
  assert.deepEqual(state.signIns, []); assert.deepEqual(state.creates, []);
  assert.deepEqual(state.replacements, []); assert.deepEqual(state.resumed, []);
  assert.deepEqual(state.credentialsChanged, []);
  assert.equal(ui.account, account); assert.equal(ui.generation, 10);
  assert.equal(ui.busy, false); assert.equal(ui.oauthPending, false);
});

test('Default Google policy retains Microsoft reconnect and saved Google token validation', async () => {
  const { ui, state, account } = fixture(false);
  const microsoft = { ...account, sessionUrl: RegisteredMailOAuth.incoming('microsoft') };
  assert.equal(ui.reconnectProvider(microsoft), 'microsoft');
  await ui.reconnectOAuth(microsoft);
  assert.equal(state.signIns[0][0], 'microsoft'); assert.equal(state.replacements.length, 1);
  assert.equal(RegisteredMailOAuth.valid({ username: account.username,
    registration: { provider: 'google', clientID: RegisteredMailOAuth.clientID('google'),
      redirectURI: 'http://127.0.0.1:45678/oauth2redirect' },
    tokens: { accessToken: 'synthetic-access-only', expiresAt: Date.now() / 1000 + 3600 }
  }), true);
});

test('Reconnect verifies the saved login, replaces credentials in place and queues mailbox sync without reloading the reader', async () => {
  const { ui, state, account } = fixture();
  await ui.reconnectOAuth(account);
  assert.equal(state.signIns[0][2], account.username, 'Use the saved server login, preserving a separate From identity');
  assert.equal(state.creates[0].endpoint, account.sessionUrl);
  assert.equal(state.creates[0].credentials.username, account.username);
  assert.equal(state.creates[0].credentials.token, 'synthetic-new-token');
  assert.equal(state.replacements.length, 1); assert.equal(state.replacements[0][0].id, account.id);
  assert.equal(state.replacements[0][2].username, account.username);
  assert.deepEqual(state.creates[1].credentials, { saved: true }, 'Later requests use renewable stored credentials');
  assert.deepEqual(state.resumed, [['page', true]]); assert.equal(state.scheduler, 1);
  assert.equal(ui.selectedId, 'old-mail'); assert.deepEqual(state.paths, ['read']);
  assert.deepEqual(state.credentialsChanged, [account.id]);
  assert.equal(ui.busy, false); assert.equal(ui.oauthPending, false); assert.equal(ui.error, '');
});

test('A different Google token rejected for the saved login cannot replace credentials or retry message reading', async () => {
  const { ui, state, account } = fixture(); state.connect = async () => { throw new JmapError('authenticationRequired'); };
  await ui.reconnectOAuth(account);
  assert.equal(state.replacements.length, 0); assert.deepEqual(state.resumed, []); assert.equal(state.scheduler, 0);
  assert.deepEqual(state.credentialsChanged, []);
  assert.equal(ui.error, 'oauth_error_mail (authenticationRequired)');
  assert.equal(ui.account.id, account.id); assert.equal(ui.selectedId, 'old-mail');
});

test('Cancelling the browser flow or leaving while verification is pending preserves the saved account and reader', async () => {
  for (const stage of ['browser', 'verification']) {
    const { ui, state, account } = fixture(), pending = deferred(), entered = deferred();
    if (stage === 'browser') state.signIn = () => { entered.resolve(); return pending.promise; };
    else state.connect = () => { entered.resolve(); return pending.promise; };
    const reconnect = ui.reconnectOAuth(account); await entered.promise;
    ui.cancelSignIn();
    pending.resolve(stage === 'browser' ? { accessToken: 'synthetic-new-token' } : { accounts: [{ id: account.serverId }] });
    await reconnect;
    assert.equal(state.replacements.length, 0); assert.deepEqual(state.resumed, []); assert.equal(state.scheduler, 0);
    assert.equal(state.cancelled, 1); assert.equal(ui.busy, false); assert.equal(ui.oauthPending, false);
    assert.equal(ui.account.id, account.id); assert.equal(ui.selectedId, 'old-mail');
  }
});

test('A mailbox reconnect refreshes that view; reconnecting another saved account leaves the current view intact', async () => {
  const f = fixture(); f.state.paths = [];
  await f.ui.reconnectOAuth(f.account); assert.deepEqual(f.state.resumed, ['mailbox']);
  const other = fixture(); other.ui.account = { ...other.account, id: 'currently-viewed-account' };
  await other.ui.reconnectOAuth(other.account);
  assert.equal(other.state.replacements.length, 1); assert.deepEqual(other.state.resumed, []);
  assert.deepEqual(other.state.credentialsChanged, [other.account.id]);
  assert.equal(other.state.creates.length, 1, 'Do not replace the visible account client');
});

test('Unknown endpoints and the composer do not start reconnect; provider errors display only allowlisted details', async () => {
  const f = fixture(); await f.ui.reconnectOAuth({ ...f.account, sessionUrl: 'imaps://other.example.test:993' });
  f.state.paths = ['compose']; await f.ui.reconnectOAuth(f.account); assert.equal(f.state.signIns.length, 0);
  f.state.paths = ['read']; f.state.signIn = async () => { throw { code: 'private-provider-token', message: 'private-account' }; };
  await f.ui.reconnectOAuth(f.account);
  assert.equal(f.ui.error, 'oauth_error_token (unknown)'); assert.equal(f.state.replacements.length, 0);
});
