const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const clone = value => JSON.parse(JSON.stringify(value));
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
function model(file) {
  const module = { exports: {} };
  new Function('module', 'exports', compile(fs.readFileSync(file, 'utf8')))(module, module.exports); return module.exports;
}
const cache = model('harmony/entry/src/main/ets/data/MailCacheModel.ts');
const conversations = model('harmony/entry/src/main/ets/mail/Conversation.ts');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['showError', 'showSavedCopy', 'read', 'refreshReader', 'canRetryReader', 'retryReader', 'applyMessage'].map(name => {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found, `Shipping ConnectedMail.${name} exists`); return found[0];
}).join('\n');
const createHost = new Function('MailCache', 'MailOperations', 'cacheReadyForReading', 'conversationMessages',
  compile(`class Host { ${methods} }; return Host;`));
function message(id = 'old_message', textBody = null) {
  return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds: ['inbox'], keywords: ['$seen'],
    from: [], to: [], cc: [], replyTo: [], references: [], inReplyTo: [], subject: 'Years-old synthetic message',
    preview: 'Downloaded summary', receivedAt: Date.UTC(2001, 0, 1), textBody, htmlBody: null,
    hasAttachment: false, hasHtmlBody: false, bodyTruncated: false, bodyEncodingProblem: false };
}
function failure(code) { const error = new Error('Synthetic failure only'); error.code = code; return error; }
function fixture() {
  const summary = message(), state = { stored: null, readCalls: 0, boxCalls: 0, connectCalls: 0,
    response: async () => { throw failure('network'); }, boxResponse: async () => [], pops: 0, refreshes: 0, changes: 0, pending: false };
  const Host = createHost({ mutationRevision: () => 0 }, { pending: () => state.pending,
    overlay: (_account, mail) => ({ ...mail, keywords: [...mail.keywords, '$flagged'] }) },
  cache.cacheReadyForReading, conversations.conversationMessages);
  const ui = new Host();
  Object.assign(ui, { active: true, account: { id: 'a', serverId: 'server-a' }, generation: 1,
    selected: null, selectedId: '', bodyLoaded: false, busy: false, readOnly: false, refreshRequired: false,
    savedCopyAt: 0, savedCopyFromDirty: false, boxesDirty: false, boxes: [], emails: [summary], conversationIndex: [],
    cacheWarning: false, error: '', label: name => name, paths: { pushPathByName() {}, pop: () => state.pops++ },
    loadConversationIndex: async () => {}, allows: () => false, changeKeyword: async () => state.changes++,
    saveCache: async operation => { try { await operation; } catch (_) { ui.cacheWarning = true; } },
    back: () => { ui.generation++; ui.error = ''; }, refreshMailbox: async () => state.refreshes++,
    client: { readEmail: async () => { state.readCalls++; return state.response(); },
      mailboxes: async () => { state.boxCalls++; return state.boxResponse(); },
      connect: async () => { state.connectCalls++; return { accounts: [{ id: 'server-a', isReadOnly: false }] }; } },
    accountStore: { mail: { email: async () => {
      if (!state.stored) return null;
      const value = cache.retainedEmail(clone(state.stored)); return value.bodySavedAt === null ? null : value;
    }, saveEmail: async (_account, mail) => { state.stored = cache.cacheEmail(mail, true, state.stored, Date.now()); },
      forgetEmail: async () => { state.stored = null; }, saveBoxes: async () => {} } }
  });
  return { ui, state, summary };
}

test('Missing-body failures preserve actionable authentication and connection errors and expose Retry', async () => {
  for (const [code, label] of [['authenticationRequired', 'account_auth_error'], ['network', 'account_network_error']]) {
    const { ui, state, summary } = fixture(); state.response = async () => { throw failure(code); };
    await ui.read(summary);
    assert.equal(ui.error, label); assert.equal(ui.bodyLoaded, false); assert.equal(ui.canRetryReader(), true);
    assert.equal(ui.selected.id, summary.id); assert.equal(state.readCalls, 1);
    assert.equal(state.boxCalls, 0); assert.equal(state.connectCalls, 0);
  }
});

test('An old message downloads on Retry without redundant mailbox requests and remains cached for reopening', async () => {
  const { ui, state, summary } = fixture(); await ui.read(summary);
  state.response = async () => message(summary.id, 'Downloaded old body');
  await ui.retryReader();
  assert.equal(state.readCalls, 2); assert.equal(state.boxCalls, 0); assert.equal(state.connectCalls, 0);
  assert.equal(ui.selected.textBody, 'Downloaded old body'); assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.error, ''); assert.equal(ui.savedCopyAt, 0); assert.equal(ui.canRetryReader(), false);
  await ui.read(summary); assert.equal(state.readCalls, 2); assert.equal(ui.bodyLoaded, true);
});

test('A two-hour cached old body survives failed refresh and decoder upgrade attempts with its original timestamp and pending overlay', async () => {
  const { ui, state, summary } = fixture(), savedAt = Date.now() - 2 * 60 * 60 * 1000;
  state.stored = cache.cacheEmail(message(summary.id, 'Saved body'), true, null, savedAt);
  delete state.stored.bodyDecoderRevision;
  await ui.read(summary);
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.selected.textBody, 'Saved body');
  assert.ok(ui.selected.keywords.includes('$flagged')); assert.equal(ui.savedCopyAt, savedAt);
  assert.equal(ui.canRetryReader(), true); assert.equal(state.stored.bodySavedAt, savedAt);
  state.response = async () => { throw failure('authenticationRequired'); }; await ui.retryReader();
  assert.equal(ui.error, 'account_auth_error'); assert.equal(ui.savedCopyAt, savedAt); assert.equal(ui.bodyLoaded, true);
  assert.equal(state.stored.bodySavedAt, savedAt); assert.equal(ui.canRetryReader(), true);
});

test('Mailbox epoch changes refresh the visible folder instead of looping on an obsolete ID; vanished UIDs remain removed', async () => {
  const f = fixture(); f.state.response = async () => { throw failure('queryChanged'); };
  await f.ui.read(f.summary); assert.equal(f.ui.error, 'mailbox_changed');
  await f.ui.retryReader();
  assert.equal(f.state.readCalls, 1); assert.equal(f.state.pops, 1); assert.equal(f.state.refreshes, 1);
  const removed = fixture(); removed.state.response = async () => null; await removed.ui.read(removed.summary);
  assert.equal(removed.ui.selected, null); assert.equal(removed.ui.error, 'message_removed');
  assert.equal(removed.ui.canRetryReader(), false); assert.equal(removed.state.stored, null);
});

test('A downloaded retry body is visible even when a required permissions refresh subsequently fails', async () => {
  const { ui, state, summary } = fixture(); await ui.read(summary); ui.refreshRequired = true;
  state.response = async () => message(summary.id, 'Downloaded before permissions failure');
  state.boxResponse = async () => {
    assert.equal(ui.bodyLoaded, true); assert.equal(ui.selected.textBody, 'Downloaded before permissions failure');
    throw failure('authenticationRequired');
  };
  await ui.retryReader();
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.selected.textBody, 'Downloaded before permissions failure');
  assert.equal(ui.error, 'account_auth_error'); assert.equal(ui.refreshRequired, true);
  assert.equal(state.boxCalls, 1); assert.equal(state.connectCalls, 0); assert.equal(ui.canRetryReader(), true);
});

test('Retention depends on download age, while fresh cached bodies and another account never trigger unwanted downloads', async () => {
  const f = fixture(), savedAt = Date.now() - 2 * 60 * 60 * 1000;
  f.state.stored = cache.cacheEmail(message(f.summary.id, 'Recently downloaded historic mail'), true, null, savedAt);
  await f.ui.read(f.summary); assert.equal(f.state.readCalls, 0); assert.equal(f.ui.bodyLoaded, true);
  f.state.stored.bodySavedAt = Date.now() - cache.MAIL_RETENTION_MS - 1;
  await f.ui.read(f.summary); assert.equal(f.state.readCalls, 1); assert.equal(f.ui.bodyLoaded, false);
  assert.equal(f.ui.canRetryReader(), true);
  let finish; f.state.response = () => new Promise(resolve => { finish = resolve; });
  const retry = f.ui.retryReader();
  f.ui.generation++; f.ui.account = { id: 'b', serverId: 'server-b' }; f.ui.selected = message('other', 'Other account body');
  finish(message(f.summary.id, 'Late old-account download')); await retry;
  assert.equal(f.ui.selected.textBody, 'Other account body');
});

test('Successful retry marks an unseen message read once, after permissions resolve and without duplicating a pending change', async () => {
  for (const blocked of ['', 'pending', 'permissions']) {
    const { ui, state, summary } = fixture(); await ui.read(summary);
    state.response = async () => ({ ...message(summary.id, 'Unread old body'), keywords: [] });
    ui.allows = () => !ui.busy && !ui.refreshRequired && ui.savedCopyAt === 0;
    ui.changeKeyword = async () => { state.changes++; ui.selected.keywords.push('$seen'); state.pending = true; };
    state.pending = blocked === 'pending';
    if (blocked === 'permissions') {
      ui.refreshRequired = true; state.boxResponse = async () => { throw failure('authenticationRequired'); };
    }
    await ui.retryReader();
    assert.equal(state.changes, blocked === '' ? 1 : 0, blocked);
    if (blocked === '') { await ui.retryReader(); assert.equal(state.changes, 1); }
  }
});
