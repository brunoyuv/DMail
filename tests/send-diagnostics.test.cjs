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
const { DeferredSave } = load('harmony/entry/src/main/ets/pages/DeferredSave.ts');
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
    './OutgoingAttachments': load('harmony/entry/src/main/ets/mail/smtp/OutgoingAttachments.ts'),
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
      ['initialize', 'savedFailureNotice', 'send', 'scheduleSave', 'save'])} }; return Host;`);
    const Host = new Function('BackgroundSend', 'sendFailureDiagnostic', 'sendFailureLabel', 'setSendFailure', code)(
      BackgroundSend, sent.sendFailureDiagnostic, sent.sendFailureLabel, sent.setSendFailure);
    const host = new Host();
    Object.assign(host, { active: true, ready: true, busy: false, account, store, draft: copy(value), host: 'example.test',
      initializeRevision: 0, saveRevision: 0, saveFailed: false, saves: new DeferredSave(),
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


test('SMTP acceptance still preserves local Sent when persisting the outgoing sent-state fails', async () => {
  const f = fixture(); let sentWrites = 0;
  const saveOutgoing = f.store.saveOutgoing;
  f.store.saveOutgoing = async (id, draft) => {
    if (draft.state === 'sent') throw new Error('Synthetic outgoing write failure');
    return saveOutgoing(id, draft);
  };
  f.store.mail.appendSent = async (_id, mail) => {
    sentWrites++; assert.equal(mail.textBody, 'Synthetic body');
  };
  await f.run();
  assert.equal(sentWrites, 1, 'Independent Sent persistence must still run after draft-state failure');
  assert.equal(f.BackgroundSend.wasAccepted(f.account.id, f.draft.id), true);
  assert.deepEqual(f.BackgroundSend.takeNotices(), [{ accountId: 'account-a', label: 'sent_save_error' }]);
  assert.equal(f.state.calls.filter(call => call.operation === 'send').length, 1);
  await assert.rejects(f.BackgroundSend.queue(f.account, f.store, f.draft, f.settings), error => error.code === 'alreadySent');
  assert.equal(f.state.calls.filter(call => call.operation === 'send').length, 1, 'A local save failure never repeats SMTP');
});

test('A failed Sent copy still persists accepted outgoing state and learns recipients once without replay', async () => {
  const f = fixture(); let attempts = 0;
  f.store.mail.appendSent = async () => { attempts++; throw new Error('Synthetic Sent write failure'); };
  await f.run();
  assert.equal(f.state.saved.state, 'sent'); assert.equal(attempts, 1); assert.equal(f.state.learned, 1);
  assert.deepEqual(f.BackgroundSend.takeNotices(), [{ accountId: 'account-a', label: 'sent_save_error' }]);
  assert.equal(f.BackgroundSend.wasAccepted(f.account.id, f.draft.id), true);
  assert.equal(f.state.calls.filter(call => call.operation === 'send').length, 1);
});

test('Attachments are loaded once at submission and never persisted as bytes or sent with local file references', async () => {
  const f = fixture();
  const attachment = { id: '167c7953-fbc4-412a-ab77-3e9cc0e87b2a', name: '中文.pdf', contentType: 'application/pdf', size: 7, file: 'account/draft/opaque.bin' };
  f.draft.attachments = [attachment];
  let reads = 0, acceptedMail;
  f.store.outgoingAttachmentData = async (accountId, draft) => {
    reads++; assert.equal(accountId, f.account.id); assert.notEqual(draft, f.draft);
    assert.deepEqual(draft.attachments, [attachment]);
    return [{ id: attachment.id, name: attachment.name, contentType: attachment.contentType, size: 7, base64: 'AAECA//+Kg==' }];
  };
  f.store.mail.appendSent = async (_account, mail) => { acceptedMail = mail; };
  await f.run();
  assert.equal(reads, 1);
  const [preflight, send] = f.state.calls;
  assert.equal(preflight.attachments.length, 1); assert.ok(!('base64' in preflight.attachments[0]));
  assert.equal(send.attachments[0].base64, 'AAECA//+Kg==');
  assert.ok(!JSON.stringify(f.state.calls).includes(attachment.file));
  assert.ok(!JSON.stringify(f.state.writes).includes('AAECA//+Kg=='));
  assert.equal(acceptedMail.hasAttachment, true); assert.equal(acceptedMail.attachments[0].id, attachment.id);
  assert.ok(!JSON.stringify(acceptedMail).includes(attachment.file));
});

test('A missing selected file remains an editable local failure and never attempts SMTP', async () => {
  const f = fixture();
  f.draft.attachments = [{ id: '167c7953-fbc4-412a-ab77-3e9cc0e87b2a', name: 'file.pdf', contentType: 'application/pdf', size: 7, file: 'opaque' }];
  f.store.outgoingAttachmentData = async () => { throw new Error('PRIVATE_FILE_PATH'); };
  await f.run();
  assert.deepEqual(f.state.calls.map(call => call.operation), ['validate']);
  assert.equal(f.state.saved.state, 'draft'); assert.equal(f.state.saved.failureStage, 'preflight');
  assert.equal(f.state.saved.failureCode, 'invalidMessage');
  assert.ok(!JSON.stringify(f.state.writes).includes('PRIVATE_FILE_PATH'));
});

test('Uncertain attachment delivery keeps metadata but never retries or reloads files automatically', async () => {
  const f = fixture(); f.state.smtpCode = 'deliveryUnconfirmed';
  const attachment = { id: '167c7953-fbc4-412a-ab77-3e9cc0e87b2a', name: 'file.bin', contentType: 'application/octet-stream', size: 1, file: 'opaque' };
  f.draft.attachments = [attachment]; let reads = 0;
  f.store.outgoingAttachmentData = async () => { reads++; return [{ ...attachment, base64: 'Kg==' }]; };
  await f.run(); await f.BackgroundSend.whenIdle();
  assert.equal(reads, 1); assert.equal(f.state.saved.state, 'unconfirmed');
  assert.deepEqual(f.state.saved.attachments, [attachment]);
  assert.equal(f.state.calls.filter(call => call.operation === 'send').length, 1);
  assert.ok(!JSON.stringify(f.state.writes).includes('Kg=='));
});
