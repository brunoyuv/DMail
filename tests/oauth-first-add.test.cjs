const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const root = process.env.DMAIL_OAUTH_SOURCE_ROOT || '.';
const read = path => fs.readFileSync(`${root}/harmony/entry/src/main/ets/${path}`, 'utf8');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
function moduleOf(source, dependencies = {}) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compile(source))(name => {
    assert.ok(name in dependencies, name); return dependencies[name];
  }, module, module.exports);
  return module.exports;
}
const jmap = moduleOf(read('mail/jmap/JmapClient.ts'));
const policy = moduleOf(read('mail/oauth/RegisteredMailOAuth.ets'));
const failures = moduleOf(read('mail/oauth/OAuthFailure.ets'));
const source = read('pages/ConnectedMail.ets');
const credentials = source.match(/class TokenCredentials[\s\S]*?\n}/)[0];
const signIn = source.match(/  private async signIn\([\s\S]*?\n  }/)[0];
function fixture(reply, token = 'synthetic-access-token') {
  const calls = [], saved = [];
  const native = moduleOf(read('mail/imap/NativeImapClient.ets'), {
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'synthetic-session' } },
    '../jmap/JmapClient': jmap,
    'libthunderbird.so': { imapAccountRequest: async raw => { calls.push(JSON.parse(raw)); return JSON.stringify(reply); } }
  });
  const factory = moduleOf(read('mail/HarmonyMailClientFactory.ets'), {
    './imap/NativeImapClient': native,
    './jmap/HarmonyJmapTransport': { HarmonyJmapClientFactory: class { create() { assert.fail('Outlook must use the Swift IMAP bridge'); } } }
  });
  const registration = { provider: 'microsoft', clientID: policy.RegisteredMailOAuth.clientID('microsoft'),
    redirectURI: 'http://127.0.0.1:49152/oauth2redirect', microsoftPersonalOnly: true };
  const tokens = { accessToken: token, refreshToken: 'synthetic-refresh-token', expiresAt: Date.now() / 1000 + 3600 };
  const Host = new Function('RegisteredMailOAuth', 'LoopbackBrowserSignIn', 'validateEmailAddress', 'SmtpSettings',
    'JmapError', 'oauthFailureLabel', 'oauthFailureCode', compile(`${credentials}\nclass Host { ${signIn} }; return Host;`))(
      policy.RegisteredMailOAuth, { forContext: () => ({ registration, signIn: async () => tokens }) },
      () => true, class {}, jmap.JmapError, failures.oauthFailureLabel, failures.oauthFailureCode);
  const ui = Object.assign(new Host(), {
    busy: false, emailAddress: 'synthetic@outlook.com', username: '', generation: 0,
    clientFactory: new factory.HarmonyMailClientFactory(), label: name => name,
    getUIContext: () => ({ getHostContext: () => ({}) }), clearDiscovery() {}, openInboxOnLaunch: false,
    accountStore: { add: async (...args) => { saved.push(args); return { id: 'synthetic-saved' }; }, list: async () => [] }
  });
  return { ui, calls, saved, tokens };
}

test('First Outlook sign-in preserves the token and login through actual credentials, factory and IMAP serialization', async () => {
  for (const token of ['synthetic+token/value=with-punctuation', 'x'.repeat(32768)]) {
    const f = fixture({ session: { accounts: [{ id: 'default', name: 'Synthetic' }] } }, token);
    await f.ui.signIn('microsoft');
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].operation, 'connect');
    assert.equal(f.calls[0].sessionUrl, 'imaps://outlook.office365.com:993');
    assert.equal(f.calls[0].username, 'synthetic@outlook.com');
    assert.equal(f.calls[0].authorization, `Bearer ${token}`);
    assert.equal(f.saved.length, 1);
    assert.equal(f.saved[0][5].tokens.accessToken, token);
    assert.equal(f.saved[0][5].username, 'synthetic@outlook.com');
    assert.equal(f.ui.error, ''); assert.equal(f.ui.busy, false);
  }
});

test('A first-add authentication rejection cannot save an account or replay native authentication', async () => {
  const f = fixture({ error: 'authenticationRequired' });
  await f.ui.signIn('microsoft');
  assert.equal(f.calls.length, 1); assert.equal(f.saved.length, 0);
  assert.equal(f.ui.error, 'oauth_error_mail (authenticationRequired)');
  assert.equal(f.ui.emailAddress, 'synthetic@outlook.com');
  assert.equal(f.ui.busy, false); assert.equal(f.ui.oauthPending, false);
});
