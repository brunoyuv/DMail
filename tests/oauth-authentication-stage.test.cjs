const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

function load(path, imports = {}) {
  const module = { exports: {} };
  const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  new Function('require', 'module', 'exports', compiled)(name => {
    assert.ok(name in imports, `Unexpected dependency ${name}`); return imports[name];
  }, module, module.exports);
  return module.exports;
}
const jmap = load('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts');
const { oauthFailureCode } = load('harmony/entry/src/main/ets/mail/oauth/OAuthFailure.ets');

function fixture(reply) {
  const requests = [];
  const { NativeImapClient } = load('harmony/entry/src/main/ets/mail/imap/NativeImapClient.ets', {
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'synthetic-id' } },
    '../jmap/JmapClient': jmap,
    'libthunderbird.so': { imapAccountRequest: async raw => {
      const request = JSON.parse(raw); requests.push(request);
      return JSON.stringify(request.operation === 'closeSyncSession' ? { state: 'closed' } : reply);
    } }
  });
  return { requests, client: new NativeImapClient('imaps://synthetic.test:993',
    { authorization: async () => 'Bearer synthetic-token' }, 'synthetic@example.test') };
}

test('Connection authentication categories survive with logging disabled and without retry or changing credentials', async () => {
  for (const authenticationStage of ['credentials', 'server']) {
    const f = fixture({ error: 'authenticationRequired', authenticationStage });
    await assert.rejects(f.client.connect(), error => {
      assert.equal(error.code, 'authenticationRequired');
      assert.equal(error.authenticationStage, authenticationStage);
      assert.equal(error.message, 'JMAP: authenticationRequired');
      assert.equal(oauthFailureCode(error.code, error.authenticationStage), `authenticationRequired/${authenticationStage}`);
      return true;
    });
    assert.equal(f.requests.length, 1);
    assert.equal(f.requests[0].authorization, 'Bearer synthetic-token');
    assert.equal(f.requests[0].username, 'synthetic@example.test');
    assert.equal(f.requests[0].downloadDiagnostics, undefined);
  }
});

test('Existing-account, pooled-read and IDLE authentication failures retain the category without replaying work', async () => {
  for (const operation of ['mailboxes', 'readEmail', 'watchInbox']) {
    const f = fixture({ error: 'authenticationRequired', authenticationStage: 'server' });
    await assert.rejects(f.client[operation]('default', 'synthetic-message'), error => {
      assert.equal(error.code, 'authenticationRequired');
      assert.equal(error.authenticationStage, 'server');
      assert.equal(oauthFailureCode(error.code, error.authenticationStage), 'authenticationRequired/server');
      return true;
    });
    assert.deepEqual(f.requests.map(request => request.operation),
      operation === 'readEmail' ? ['readEmail', 'closeSyncSession'] : [operation]);
  }
});

test('Only fixed categories paired with authenticationRequired may cross the error or display boundary', async () => {
  for (const stage of [undefined, null, 7, {}, ['server'], 'SERVER', 'unknown', 'server synthetic-private-response']) {
    const f = fixture({ error: 'authenticationRequired', authenticationStage: stage, message: 'synthetic-private-response' });
    await assert.rejects(f.client.connect(), error => {
      assert.equal(error.authenticationStage, undefined);
      assert.equal(oauthFailureCode(error.code, stage), 'authenticationRequired');
      assert.ok(!JSON.stringify(error).includes('private'));
      assert.ok(!error.message.includes('private')); return true;
    });
  }
  for (const code of ['network', 'invalidArgument', 'certificate', 'synthetic-private-response']) {
    const error = new jmap.JmapError(code, 0, 'server');
    assert.equal(error.authenticationStage, undefined);
    assert.equal(oauthFailureCode(code, 'server'), code === 'synthetic-private-response' ? 'unknown' : code);
  }
  const f = fixture({ error: 'authenticationRequired', authenticationStage: 'refresh' });
  await assert.rejects(f.client.connect(), error => error.authenticationStage === undefined,
    'The IMAP boundary cannot originate the OAuth refresh category');
});

test('Normal error display preserves the reconnect label and clears any stale or untrusted detail', () => {
  const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
  const showError = source.match(/  private showError\([^\n]*[\s\S]*?\n  }/)[0];
  const compiled = ts.transpileModule(`class Host { ${showError} }; return Host;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const Host = new Function(compiled)();
  const host = Object.assign(new Host(), { label: key => key, error: '', authenticationDetail: '' });
  for (const stage of ['credentials', 'server', 'refresh']) {
    host.showError(new jmap.JmapError('authenticationRequired', 0, stage));
    assert.equal(host.error, 'account_auth_error', 'Reconnect depends on this exact label');
    assert.equal(host.authenticationDetail, `authenticationRequired/${stage}`);
    assert.equal(oauthFailureCode('authenticationRequired', stage), `authenticationRequired/${stage}`);
    host.showError(new jmap.JmapError('network'));
    assert.equal(host.error, 'account_network_error'); assert.equal(host.authenticationDetail, '');
  }
  for (const stage of [undefined, {}, 'synthetic-private-response']) {
    host.showError({ code: 'authenticationRequired', authenticationStage: stage, message: 'synthetic-private-response' });
    assert.equal(host.error, 'account_auth_error'); assert.equal(host.authenticationDetail, '');
  }
  host.showError({ code: 'queryChanged', authenticationStage: 'server' });
  assert.equal(host.error, 'mailbox_changed'); assert.equal(host.authenticationDetail, '');
});

test('Refresh failure categories preserve credentials, cleanup and existing network classification', async () => {
  const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
  const refresh = source.match(/  private async refreshOAuth\([^\n]*[\s\S]*?\n  }/)[0];
  const compiled = ts.transpileModule(`class Host { ${refresh} }; return Host;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  for (const failure of ['invalid_grant', 'access_denied', 'invalid_client', 'unauthorized_client', 'invalid_scope', 'invalid_request', 'network', 'invalidTokenResponse', 'synthetic-private-response']) {
    const state = { requests: 0, closed: 0, released: 0 };
    const account = { id: 'synthetic-account', username: 'synthetic@example.test', sessionUrl: 'imaps://synthetic.test' };
    const login = { username: account.username, registration: { provider: 'microsoft' },
      tokens: { accessToken: 'synthetic-expired', refreshToken: 'synthetic-refresh', expiresAt: 1 } };
    const original = structuredClone(login);
    const key = { open: async () => JSON.stringify(login), close: () => state.closed++,
      seal: async () => assert.fail('Failed refresh must not change credentials') };
    const Host = new Function('util', 'OAuthSecretBox', 'RegisteredMailOAuth', 'JmapError', compiled)(
      { generateRandomUUID: () => 'synthetic-owner' }, { retain: async () => key },
      { valid: () => true, incoming: () => account.sessionUrl }, jmap.JmapError);
    const host = Object.assign(new Host(), { oauthAlias: () => 'synthetic-alias', oauthEnvelope: async () => 'synthetic-envelope',
      acquireRefreshLease: async () => true, releaseRefreshLease: async () => state.released++,
      enqueue: async () => assert.fail('Failed refresh must not write storage'),
      oauthService: { refresh: async () => { state.requests++; throw Object.assign(new Error('synthetic-private-response'), { code: failure }); } } });
    await assert.rejects(host.refreshOAuth(account, login, 'synthetic-envelope'), error => {
      const rejected = ['invalid_grant', 'access_denied', 'invalid_client', 'unauthorized_client', 'invalid_scope', 'invalid_request'].includes(failure);
      assert.equal(error.code, rejected ? 'authenticationRequired' : 'network');
      assert.equal(error.authenticationStage, rejected ? 'refresh' : undefined);
      assert.ok(!error.message.includes('private')); return true;
    });
    assert.deepEqual(login, original); assert.deepEqual(state, { requests: 1, closed: 1, released: 1 });
  }
});

test('A late refresh cannot invalidate or overwrite newer reconnect credentials before or during its conditional save', async () => {
  const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
  const refresh = source.match(/  private async refreshOAuth\([^\n]*[\s\S]*?\n  }/)[0];
  const compiled = ts.transpileModule(`class Host { ${refresh} }; return Host;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
  for (const supersededAt of ['beforeSave', 'conditionalSave', 'removed']) {
    const started = deferred(), response = deferred();
    const state = { envelope: 'old-envelope', removed: false, requests: 0, saveAttempts: 0, closed: 0, released: 0 };
    const account = { id: 'synthetic-account', username: 'synthetic@example.test', sessionUrl: 'imaps://synthetic.test' };
    const login = { username: account.username, registration: { provider: 'microsoft' },
      tokens: { accessToken: 'synthetic-old', refreshToken: 'synthetic-refresh', expiresAt: 1 } };
    const key = { open: async envelope => { assert.equal(envelope, 'old-envelope'); return JSON.stringify(login); },
      seal: async () => 'late-refresh-envelope', close: () => state.closed++ };
    const Host = new Function('util', 'OAuthSecretBox', 'RegisteredMailOAuth', 'JmapError', compiled)(
      { generateRandomUUID: () => 'synthetic-owner' }, { retain: async () => key },
      { valid: () => true, incoming: () => account.sessionUrl }, jmap.JmapError);
    const host = Object.assign(new Host(), { oauthAlias: () => 'synthetic-alias',
      oauthEnvelope: async () => { if (state.removed) throw new jmap.JmapError('authenticationRequired'); return state.envelope; },
      acquireRefreshLease: async () => true, releaseRefreshLease: async () => state.released++,
      enqueue: async action => action(), database: () => ({ executeSql: async (query, parameters) => {
        state.saveAttempts++;
        assert.ok(query.includes('AND envelope = ?'));
        assert.equal(parameters[2], 'old-envelope');
        assert.equal(supersededAt, 'conditionalSave');
        // A different credential owner committed after the pre-save read.
        // Its envelope fails this update's old-envelope WHERE condition.
        state.envelope = 'newer-reconnect-envelope';
      } }),
      oauthService: { refresh: async () => { state.requests++; started.resolve(); return response.promise; } } });
    const pending = host.refreshOAuth(account, login, 'old-envelope');
    await started.promise;
    if (supersededAt === 'beforeSave') state.envelope = 'newer-reconnect-envelope';
    if (supersededAt === 'removed') state.removed = true;
    response.resolve({ accessToken: 'synthetic-late-token', refreshToken: 'synthetic-rotated-refresh', expiresAt: Date.now() / 1000 + 3600 });
    await assert.rejects(pending, error => {
      assert.equal(error.code, supersededAt === 'removed' ? 'authenticationRequired' : 'network');
      assert.equal(error.authenticationStage, supersededAt === 'removed' ? 'refresh' : undefined); return true;
    });
    assert.equal(state.envelope, supersededAt === 'removed' ? 'old-envelope' : 'newer-reconnect-envelope');
    assert.equal(state.requests, 1); assert.equal(state.saveAttempts, supersededAt === 'conditionalSave' ? 1 : 0);
    assert.equal(state.closed, 1); assert.equal(state.released, 1);
  }
});
