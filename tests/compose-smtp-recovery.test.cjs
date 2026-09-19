const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ComposeMail.ets', 'utf8');
const compile = input => ts.transpileModule(input, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const clone = value => JSON.parse(JSON.stringify(value));
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
async function microtasks() { for (let i = 0; i < 12; i++) { await Promise.resolve(); } }
function method(name) {
  const start = source.match(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
  assert.ok(start, `Shipping ComposeMail.${name} must exist`);
  const lineEnd = source.indexOf('\n', start.index);
  if (source.slice(start.index, lineEnd).trimEnd().endsWith('}')) { return source.slice(start.index, lineEnd); }
  const end = source.indexOf('\n  }', start.index);
  assert.ok(end > start.index);
  return source.slice(start.index, end + 4);
}
const smtpSource = fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/NativeSmtpClient.ets', 'utf8');
const modelSource = ['SmtpSettings', 'OutgoingDraft', 'SmtpError'].map(name => {
  const found = smtpSource.match(new RegExp(`export class ${name}\\b[\\s\\S]*?\n}`));
  assert.ok(found); return found[0];
}).join('\n');
const model = { exports: {} };
new Function('module', 'exports', compile(modelSource))(model, model.exports);
const { SmtpSettings, OutgoingDraft, SmtpError } = model.exports;
function settings(endpoint = '', username = '', password = '') {
  return Object.assign(new SmtpSettings(), { endpoint, username, password });
}
function account(id = 'account-a') {
  return { id, authentication: '', sessionUrl: 'imaps://imap.gmail.com:993', username: 'synthetic@example.test' };
}
function fixture() {
  const state = { smtpReads: [], defaultReads: [], smtpWrites: [], queued: [], published: [], toasts: [],
    events: [], smtp: settings(), defaults: settings('smtps://smtp.gmail.com:465', 'synthetic@example.test', 'synthetic-app-password'),
    read: async () => clone(state.smtp), recover: async () => clone(state.defaults), save: async () => {}, sending: false };
  const background = {
    isSending: () => state.sending, wasAccepted: () => false,
    queue: async (owner, _store, draft, value) => {
      state.events.push('queue'); state.queued.push({ account: owner.id, draft: draft.id, settings: clone(value) });
    },
    publish: (...args) => state.published.push(args)
  };
  const names = ['initialize', 'restoreGmailSmtp', 'saveSettings', 'settings', 'send', 'editable', 'aboutToDisappear'];
  const Host = new Function('BackgroundSend', 'SmtpSettings', 'SmtpError', 'setSendFailure', 'sendFailureLabel',
    'sendFailureDiagnostic', compile(`class Host { ${names.map(method).join('\n')} }; return Host;`))(
    background, SmtpSettings, SmtpError, () => {}, value => value, () => '');
  const host = new Host();
  const draft = Object.assign(new OutgoingDraft(), { id: 'draft-a', to: 'recipient@example.test', text: 'Synthetic draft' });
  Object.assign(host, { account: account(), draft, active: true, ready: false, busy: false, setup: false,
    smtpMissing: false, smtpLoadFailed: false, smtpRestoring: false, smtpRecovered: false,
    attachmentPicking: false, attachmentRevision: 0, initializeRevision: 0, previewRevision: 0,
    host: '', port: '587', tls: false, username: '', password: '', notice: '',
    saves: { flush: async () => {} }, loadRecipients() {}, savedFailureNotice: () => '',
    newDraft: async () => draft, save: async () => {}, label: name => name, onQueued() {},
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => state.toasts.push(value) }) }),
    store: {
      outgoing: async () => draft,
      smtp: async owner => { state.smtpReads.push(owner.id); return state.read(owner); },
      gmailSmtpDefaults: async owner => { state.defaultReads.push(owner.id); return state.recover(owner); },
      saveSmtp: async (owner, value) => {
        const snapshot = clone(value); await state.save(owner, snapshot);
        state.events.push('save'); state.smtpWrites.push({ account: owner.id, settings: snapshot });
        state.smtp = snapshot;
      }
    }
  });
  return { host, state };
}

test('Missing Gmail SMTP remains a recoverable local state and Send opens setup without network or writes', async () => {
  const { host, state } = fixture(); await host.initialize();
  assert.equal(host.ready, true); assert.equal(host.smtpMissing, true); assert.equal(host.smtpLoadFailed, false);
  assert.equal(host.smtpRecovered, false); assert.equal(host.host, '');
  await host.send();
  assert.equal(host.setup, true); assert.equal(state.defaultReads.length, 0);
  assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []);
});

test('Gmail recovery proposes implicit TLS locally, and explicit Save is required before Send', async () => {
  const { host, state } = fixture(); await host.initialize(); await host.send(); await host.restoreGmailSmtp();
  assert.deepEqual([host.host, host.port, host.tls, host.username, host.password],
    ['smtp.gmail.com', '465', true, 'synthetic@example.test', 'synthetic-app-password']);
  assert.equal(host.smtpRecovered, true); assert.equal(host.smtpMissing, true);
  assert.deepEqual(state.defaultReads, ['account-a']); assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []);
  await host.send(); assert.equal(host.setup, true); assert.deepEqual(state.queued, []);
  await host.saveSettings();
  assert.equal(host.smtpMissing, false); assert.equal(host.smtpRecovered, false); assert.equal(host.setup, false);
  assert.deepEqual(state.toasts, [{ message: 'smtp_saved' }]); assert.equal(state.smtpWrites.length, 1);
  await host.send(); assert.deepEqual(state.events, ['save', 'queue']);
  assert.equal(state.queued[0].settings.endpoint, 'smtps://smtp.gmail.com:465');
});

test('A failed recovery preserves manually entered fields and keeps Save and Send separate', async () => {
  const { host, state } = fixture(); await host.initialize();
  Object.assign(host, { host: 'custom.example.test', port: '2525', tls: false, username: 'custom', password: 'synthetic-existing' });
  state.recover = async () => { throw new Error('Synthetic Asset unavailable'); };
  await host.restoreGmailSmtp();
  assert.deepEqual([host.host, host.port, host.tls, host.username, host.password],
    ['custom.example.test', '2525', false, 'custom', 'synthetic-existing']);
  assert.equal(host.notice, 'gmail_smtp_recovery_error'); assert.equal(host.smtpMissing, true);
  assert.equal(host.smtpRecovered, false); assert.equal(host.smtpRestoring, false);
  await host.send(); assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []);
});

test('Existing SMTP settings, OAuth and other providers cannot invoke password recovery', async () => {
  for (const scenario of ['existing', 'oauth', 'other-provider']) {
    const { host, state } = fixture();
    if (scenario === 'existing') { state.smtp = settings('smtp://custom.example.test:587', 'custom', 'synthetic-existing'); }
    if (scenario === 'oauth') { host.account.authentication = 'oauth'; }
    if (scenario === 'other-provider') { host.account.sessionUrl = 'imaps://other.example.test:993'; }
    await host.initialize(); const fields = [host.host, host.port, host.tls, host.username, host.password];
    await host.restoreGmailSmtp();
    assert.deepEqual(state.defaultReads, [], scenario); assert.deepEqual(state.smtpWrites, [], scenario);
    assert.deepEqual([host.host, host.port, host.tls, host.username, host.password], fields, scenario);
  }
});

test('Recovery disables overlapping restore, editing, Save and Send until its local credential read completes', async () => {
  const { host, state } = fixture(), gate = deferred(); await host.initialize(); state.recover = () => gate.promise;
  const operation = host.restoreGmailSmtp();
  assert.equal(host.smtpRestoring, true); assert.equal(host.editable(), false);
  await host.restoreGmailSmtp(); await host.saveSettings(); await host.send();
  assert.deepEqual(state.defaultReads, ['account-a']); assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []);
  gate.resolve(state.defaults); await operation; assert.equal(host.smtpRestoring, false); assert.equal(host.editable(), true);
});

test('Hidden composer rejects late recovery success and clears the previously shown password', async () => {
  const { host, state } = fixture(), gate = deferred(); await host.initialize(); state.recover = () => gate.promise;
  host.password = 'synthetic-current'; const operation = host.restoreGmailSmtp(); host.aboutToDisappear();
  gate.resolve(state.defaults); await operation;
  assert.equal(host.host, ''); assert.equal(host.password, ''); assert.equal(host.smtpRecovered, false);
  assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.published, []);
});

test('Old recovery success or failure cannot overwrite a replacement account or a newer initialization', async () => {
  for (const replacement of ['other-account', 'same-account']) {
    for (const fails of [false, true]) {
      const { host, state } = fixture(), gate = deferred(); await host.initialize(); state.recover = () => gate.promise;
      const operation = host.restoreGmailSmtp();
      if (replacement === 'other-account') { host.account = account('account-b'); }
      state.smtp = settings('smtp://new.example.test:587', 'new-user', 'synthetic-new'); await host.initialize();
      if (fails) { gate.reject(new Error('Synthetic late failure')); } else { gate.resolve(state.defaults); }
      await operation;
      assert.deepEqual([host.host, host.port, host.tls, host.username, host.password],
        ['new.example.test', '587', false, 'new-user', 'synthetic-new']);
      assert.equal(host.notice, ''); assert.equal(host.smtpRecovered, false); assert.equal(host.smtpRestoring, false);
      assert.deepEqual(state.smtpWrites, []);
    }
  }
});

test('Fresh initialize resets stale SMTP fields before awaiting either draft or settings', async () => {
  const { host } = fixture(), gate = deferred();
  Object.assign(host, { host: 'old.example.test', port: '465', tls: true, username: 'old-user', password: 'synthetic-old',
    smtpMissing: true, smtpLoadFailed: true, smtpRecovered: true, smtpRestoring: true, ready: true });
  host.store.outgoing = () => gate.promise;
  const operation = host.initialize();
  assert.deepEqual([host.host, host.port, host.tls, host.username, host.password], ['', '587', false, '', '']);
  assert.equal(host.ready, false); assert.equal(host.smtpLoadFailed, false); assert.equal(host.smtpRecovered, false);
  assert.equal(host.smtpRestoring, false);
  gate.resolve(host.draft); await operation; assert.equal(host.ready, true); assert.equal(host.smtpMissing, true);
});

test('SMTP read failure exposes a retry state instead of missing-settings recovery; retry reloads valid settings', async () => {
  const { host, state } = fixture(); state.read = async () => { throw new Error('Synthetic locked Asset'); };
  await host.initialize();
  assert.equal(host.ready, false); assert.equal(host.smtpMissing, false); assert.equal(host.smtpLoadFailed, true);
  assert.equal(host.notice, 'smtp_load_error'); await host.restoreGmailSmtp(); await host.send();
  assert.deepEqual(state.defaultReads, []); assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []);
  state.read = async () => settings('smtps://smtp.gmail.com:465', 'synthetic@example.test', 'synthetic-valid');
  await host.initialize(); assert.equal(host.ready, true); assert.equal(host.smtpLoadFailed, false); assert.equal(host.smtpMissing, false);
  assert.equal(host.host, 'smtp.gmail.com'); assert.equal(host.password, 'synthetic-valid'); assert.equal(host.notice, '');
});

test('Draft read failure is distinct from SMTP failure and never attempts SMTP recovery', async () => {
  const { host, state } = fixture(); host.store.outgoing = async () => { throw new Error('Synthetic draft failure'); };
  await host.initialize(); assert.equal(host.ready, false); assert.equal(host.smtpLoadFailed, false);
  assert.equal(host.notice, 'draft_load_error'); assert.deepEqual(state.smtpReads, []);
  await host.restoreGmailSmtp(); assert.deepEqual(state.defaultReads, []);
});

test('Saving recovered settings unsuccessfully keeps the proposal unsaved and never queues mail', async () => {
  const { host, state } = fixture(); await host.initialize(); await host.restoreGmailSmtp();
  state.save = async () => { throw new Error('Synthetic write failure'); };
  await host.saveSettings(); await host.send();
  assert.equal(host.smtpMissing, true); assert.equal(host.smtpRecovered, true); assert.equal(host.setup, true);
  assert.equal(host.notice, 'smtp_settings_error'); assert.equal(host.password, 'synthetic-app-password');
  assert.deepEqual(state.smtpWrites, []); assert.deepEqual(state.queued, []); assert.deepEqual(state.toasts, []);
});

test('An old successful settings save cannot dismiss or mark the replacement account configured', async () => {
  const { host, state } = fixture(), gate = deferred(); await host.initialize(); await host.restoreGmailSmtp();
  state.save = () => gate.promise; const operation = host.saveSettings(); await microtasks();
  host.account = account('account-b'); await host.initialize(); host.setup = true;
  assert.equal(host.busy, false, 'Replacement composer must not retain the old save lock');
  gate.resolve(); await operation;
  assert.equal(host.smtpMissing, true); assert.equal(host.setup, true); assert.equal(host.smtpRecovered, false);
  assert.equal(host.editable(), true);
  assert.deepEqual(state.toasts, []); assert.deepEqual(state.smtpWrites.map(item => item.account), ['account-a']);
});

test('An old settings-save completion cannot unlock a newer save on the replacement account', async () => {
  const { host, state } = fixture(), oldGate = deferred(), newGate = deferred();
  await host.initialize(); await host.restoreGmailSmtp();
  state.save = owner => owner.id === 'account-a' ? oldGate.promise : newGate.promise;
  const oldSave = host.saveSettings(); await microtasks();
  host.account = account('account-b'); await host.initialize(); await host.restoreGmailSmtp();
  const newSave = host.saveSettings(); await microtasks(); assert.equal(host.busy, true);
  oldGate.resolve(); await oldSave;
  assert.equal(host.busy, true); assert.equal(host.smtpMissing, true); assert.deepEqual(state.toasts, []);
  newGate.resolve(); await newSave;
  assert.equal(host.busy, false); assert.equal(host.smtpMissing, false);
  assert.deepEqual(state.toasts, [{ message: 'smtp_saved' }]);
  assert.deepEqual(state.smtpWrites.map(item => item.account), ['account-a', 'account-b']);
});

test('A late SMTP initialization result cannot replace the new account settings or its notice', async () => {
  for (const fails of [false, true]) {
    const { host, state } = fixture(), gate = deferred();
    state.read = owner => owner.id === 'account-a' ? gate.promise :
      Promise.resolve(settings('smtp://new.example.test:587', 'new-user', 'synthetic-new'));
    const old = host.initialize(); await microtasks();
    host.account = account('account-b'); await host.initialize();
    if (fails) { gate.reject(new Error('Synthetic old account read failure')); }
    else { gate.resolve(settings('smtps://old.example.test:465', 'old-user', 'synthetic-old')); }
    await old;
    assert.deepEqual([host.host, host.port, host.tls, host.username, host.password],
      ['new.example.test', '587', false, 'new-user', 'synthetic-new']);
    assert.equal(host.notice, ''); assert.equal(host.smtpLoadFailed, false); assert.equal(host.smtpMissing, false);
    assert.equal(host.ready, true); assert.deepEqual(state.smtpWrites, []);
  }
});

test('A hidden settings-save failure is published to the original account only', async () => {
  const { host, state } = fixture(), gate = deferred(); await host.initialize(); await host.restoreGmailSmtp();
  state.save = () => gate.promise; const operation = host.saveSettings(); await microtasks();
  host.aboutToDisappear(); host.account = account('account-b'); gate.reject(new Error('Synthetic late write failure')); await operation;
  assert.deepEqual(state.published, [['account-a', 'smtp_settings_error']]);
  assert.equal(host.password, ''); assert.deepEqual(state.toasts, []); assert.deepEqual(state.smtpWrites, []);
});
