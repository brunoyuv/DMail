const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const copy = value => JSON.parse(JSON.stringify(value));
function load(file, imports = {}, appStorage = {}) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'AppStorage', compile(fs.readFileSync(file, 'utf8')))(name => {
    assert.ok(name in imports, `Unexpected dependency ${name}`); return imports[name];
  }, module, module.exports, appStorage);
  return module.exports;
}
const sent = load('harmony/entry/src/main/ets/mail/smtp/SentMail.ts');
function methods(file, names) {
  const source = fs.readFileSync(file, 'utf8');
  return names.map(name => {
    const found = source.match(new RegExp(`  (?:private )?(?:async )?${name}\\([\\s\\S]*?\\n  }`));
    assert.ok(found, `Shipping ${name} must exist`); return found[0];
  }).join('\n');
}
function fixture() {
  const state = { authError: null, smtpCode: '', calls: [], saved: null, writes: [], learned: 0, storage: new Map() };
  const native = load('harmony/entry/src/main/ets/mail/smtp/NativeSmtpClient.ets', {
    'libthunderbird.so': { smtpAccountRequest: async raw => {
      const input = JSON.parse(raw); state.calls.push(input);
      if (input.operation === 'validate') return '{}';
      if (state.smtpCode) return JSON.stringify({ error: state.smtpCode });
      return JSON.stringify({ accepted: true, messageId: 'synthetic@example.test', date: 123,
        textBody: 'Synthetic body', sentCopy: 'saved', sentMailboxId: 'sent' });
    } }
  });
  const { BackgroundSend } = load('harmony/entry/src/main/ets/mail/smtp/BackgroundSend.ets', {
    './NativeSmtpClient': native, './SentMail': sent
  }, { setOrCreate: (key, value) => state.storage.set(key, value), get: key => state.storage.get(key) });
  const account = { id: 'account-a', authentication: 'oauth', emailAddress: 'sender@example.test', username: 'sender@example.test', sessionUrl: 'imaps://example.test:993' };
  const settings = { endpoint: 'smtp://example.test:587', username: 'sender@example.test', password: '' };
  const store = { saveSmtp: async () => {}, saveOutgoing: async (_id, draft) => {
    state.saved = copy(draft); state.writes.push(copy(draft));
  }, outgoing: async () => copy(state.saved), smtp: async () => settings,
    oauthAccessToken: async () => { if (state.authError) throw state.authError; return 'synthetic-token'; },
    credentials: () => ({ authorization: async () => 'Bearer synthetic-token', username: account.username }),
    rememberRecipients: async () => { state.learned++; },
    mail: { boxes: async () => ({ boxes: [] }), appendSent: async () => {} }
  };
  const draft = new native.OutgoingDraft(); draft.id = 'draft-a'; draft.to = 'recipient@example.test'; draft.text = 'Synthetic body';
  async function run(value = draft) { await BackgroundSend.queue(account, store, value, settings); await BackgroundSend.whenIdle(); }
  function composer(value = state.saved) {
    state.saved = copy(value);
    const code = compile(`class Host { ${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets',
      ['initialize', 'savedFailureNotice', 'send', 'save'])} }; return Host;`);
    const Host = new Function('BackgroundSend', 'sendFailureDiagnostic', 'sendFailureLabel', 'setSendFailure', code)(
      BackgroundSend, sent.sendFailureDiagnostic, sent.sendFailureLabel, sent.setSendFailure);
    const host = new Host();
    Object.assign(host, { active: true, ready: true, busy: false, account, store, draft: copy(value), host: 'example.test',
      username: account.username, password: '', notice: '', label: name => name, loadRecipients() {},
      editable: () => host.draft.state === 'draft' && !host.busy, onQueued() {}, settings: () => settings });
    return host;
  }
  return { state, account, store, settings, draft, run, composer, BackgroundSend, native };
}

test('OAuth refresh failure never submits SMTP and its safe AUTH detail survives saved-draft reopening', async () => {
  const f = fixture(); f.state.authError = { code: 'network', message: 'SECRET provider reply' };
  await f.run();
  assert.deepEqual(f.state.calls.map(call => call.operation), ['validate']);
  assert.equal(f.state.saved.state, 'draft'); assert.equal(f.state.saved.failureStage, 'authRefresh');
  assert.equal(f.state.saved.failureCode, 'network'); assert.equal(f.state.learned, 0);
  assert.deepEqual(f.BackgroundSend.takeNotices(), [{ accountId: 'account-a', label: 'smtp_network_error', diagnostic: 'AUTH/network' }]);
  const composer = f.composer(); await composer.initialize();
  assert.equal(composer.notice, 'smtp_network_error (AUTH/network)'); assert.equal(composer.ready, true);
  assert.ok(!JSON.stringify(f.state.writes).includes('SECRET'));
});

test('SMTP failures retain a distinct safe stage and uncertain delivery stays blocked after reopen', async () => {
  for (const code of ['network', 'deliveryUnconfirmed']) {
    const f = fixture(); f.state.smtpCode = code; await f.run();
    assert.deepEqual(f.state.calls.map(call => call.operation), ['validate', 'send']);
    assert.equal(f.state.saved.failureStage, 'smtp'); assert.equal(f.state.saved.failureCode, code);
    assert.equal(f.state.saved.state, code === 'network' ? 'draft' : 'unconfirmed');
    const composer = f.composer(); await composer.initialize();
    assert.ok(composer.notice.includes(`SMTP/${code}`));
    if (code === 'deliveryUnconfirmed') { await composer.send(); assert.equal(f.state.calls.length, 2); }
  }
});

test('Unknown provider codes and errors never persist or display raw contents, and attempted delivery remains uncertain', async () => {
  for (const auth of [false, true]) {
    const f = fixture(); const raw = 'RAW_TOKEN provider=response user=private@example.test';
    if (auth) f.state.authError = { code: raw, message: raw }; else f.state.smtpCode = raw;
    await f.run();
    assert.equal(f.state.saved.failureCode, 'unknown');
    assert.equal(f.state.saved.state, auth ? 'draft' : 'unconfirmed');
    const notices = f.BackgroundSend.takeNotices(), composer = f.composer(); await composer.initialize();
    assert.ok(composer.notice.includes(auth ? 'AUTH/unknown' : 'SMTP/unknown'));
    assert.ok(!JSON.stringify({ writes: f.state.writes, notices, notice: composer.notice }).includes(raw));
  }
  assert.equal(sent.sendFailureDiagnostic({ failureStage: 'RAW', failureCode: 'secret' }), '');
  assert.equal(sent.sendFailureDiagnostic({ failureStage: 'smtp', failureCode: 'secret' }), 'SMTP/unknown');
});

test('An explicit retry clears old failure details before sending and does not serialize diagnostics into SMTP MIME input', async () => {
  const f = fixture(); f.state.authError = { code: 'network' }; await f.run(); f.BackgroundSend.takeNotices();
  const retry = copy(f.state.saved); f.state.authError = null; await f.run(retry);
  assert.equal(retry.failureStage, ''); assert.equal(retry.failureCode, '');
  assert.equal(f.state.saved.state, 'sent'); assert.equal(f.state.saved.failureStage, ''); assert.equal(f.state.saved.failureCode, '');
  assert.equal(f.state.calls.filter(call => call.operation === 'send').length, 1);
  for (const call of f.state.calls) { assert.ok(!('failureStage' in call)); assert.ok(!('failureCode' in call)); }
  assert.deepEqual(f.BackgroundSend.takeNotices(), [{ accountId: 'account-a', label: 'sent' }]);
});

test('Composer preflight rejection is saved with a safe CHECK detail without any SMTP request', async () => {
  const f = fixture(); const composer = f.composer(f.draft);
  composer.settings = () => { throw new f.native.SmtpError('unsafeEndpoint'); };
  await composer.send();
  assert.equal(f.state.calls.length, 0); assert.equal(f.state.saved.state, 'draft');
  assert.equal(f.state.saved.failureStage, 'preflight'); assert.equal(f.state.saved.failureCode, 'unsafeEndpoint');
  const reopened = f.composer(); await reopened.initialize();
  assert.equal(reopened.notice, 'smtp_tls_error (CHECK/unsafeEndpoint)');
});

test('Inbox completion toast includes the already-sanitized diagnostic while legacy drafts remain readable', async () => {
  const f = fixture(); f.state.authError = { code: 'network' }; await f.run();
  const code = compile(`class Host { ${methods('harmony/entry/src/main/ets/pages/ConnectedMail.ets', ['sendChanged'])} }; return Host;`);
  const Host = new Function('BackgroundSend', code)(f.BackgroundSend), inbox = new Host(), toasts = [];
  Object.assign(inbox, { active: true, ready: true, account: { id: 'other-account' }, refreshUnreadStatus() {}, label: name => name,
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }) });
  await inbox.sendChanged(); assert.deepEqual(toasts, ['smtp_network_error (AUTH/network)']);
  const legacy = copy(f.draft); delete legacy.failureStage; delete legacy.failureCode;
  const composer = f.composer(legacy); await composer.initialize(); assert.equal(composer.notice, '');
});
