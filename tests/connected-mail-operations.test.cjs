const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

// Compile the actual component methods, leaving ArkUI builders outside the
// host runtime. Cache snapshots and pending acknowledgements are controlled at
// their public boundaries so the races do not depend on network/device timing.
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
function method(name) {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found, `Production ConnectedMail.${name} must exist`);
  return found[0];
}
const compiled = ts.transpileModule(`export class ConnectedMailHost {
${['showError', 'showSavedCopy', 'loadPage', 'read', 'operationsChanged', 'loadConversationIndex', 'rowAllows', 'visibleEmails',
  'closeSwipeAction', 'rowKeyword', 'archive'].map(method).join('\n')}
}`, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const conversationModule = { exports: {} };
const conversationCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/Conversation.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', conversationCode)(conversationModule, conversationModule.exports);
const cacheModelModule = { exports: {} };
const cacheModelCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/data/MailCacheModel.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', cacheModelCode)(cacheModelModule, cacheModelModule.exports);
const jmapModule = { exports: {} };
const jmapCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', jmapCode)(jmapModule, jmapModule.exports);

const clone = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function mail(seen = false) {
  return { id: 'synthetic_mail', threadId: 'synthetic_thread', messageIds: ['synthetic@example.test'],
    mailboxIds: ['inbox'], keywords: seen ? ['$seen'] : [], from: [], to: [], cc: [], replyTo: [],
    subject: 'Synthetic read/unread', preview: 'Cached body', receivedAt: 123,
    textBody: 'Cached body', htmlBody: null, hasAttachment: false, bodyTruncated: false,
    bodyEncodingProblem: false, hasHtmlBody: false };
}
function fixture() {
  const savedAt = Date.now() - 1000;
  const state = { pending: false, view: { savedAt, emails: [mail()], stateDirty: false,
    nextPosition: 50, queryState: 'synthetic-state' }, viewRead: null, bodyRead: null, indexRead: null, pageCalls: 0,
    overlays: new Map(), closeCallbacks: [], operationCalls: [] };
  const operations = {
    undo: () => null, count: () => state.pending ? 1 : 0, pending: () => state.pending,
    overlay: (_account, value) => state.overlays.get(value.id) || (state.pending ? { ...value,
      keywords: value.keywords.includes('$seen') ? value.keywords.filter(keyword => keyword !== '$seen') : [...value.keywords, '$seen'] } : value),
    setKeyword: (store, client, accountId, serverId, value, keyword) => {
      state.operationCalls.push({ kind: 'keyword', store, client, accountId, serverId, mail: clone(value), keyword });
    },
    move: (store, client, accountId, serverId, value, membership) => {
      state.operationCalls.push({ kind: 'move', store, client, accountId, serverId, mail: clone(value), membership: membership.slice() });
    }
  };
  const module = { exports: {} };
  new Function('module', 'exports', 'MailOperations', 'MailCache', 'conversationGroups', 'conversationMessages', 'cacheReadyForReading', 'archiveTarget', 'canSetKeyword', 'MailInboxUpdates', compiled)(module, module.exports,
    operations, { mutationRevision: () => 0 }, conversationModule.exports.conversationGroups, conversationModule.exports.conversationMessages,
    cacheModelModule.exports.cacheReadyForReading, jmapModule.exports.archiveTarget, jmapModule.exports.canSetKeyword, { revision: () => 0 });
  const ui = new module.exports.ConnectedMailHost();
  Object.assign(ui, {
    active: true, ready: true, account: { id: 'synthetic_account', serverId: 'synthetic_server', sessionUrl: 'imaps://example.test' },
    generation: 7, operationRevision: 0, busy: false, readOnly: false, selected: null, emails: [mail()],
    inboxRequests: new Map(), inboxAcknowledged: new Map(), inboxCachedUpdates: new Set(), inboxFetching: new Set(),
    inboxSwipes: new Set(), inboxLoadRevision: 0, inboxViewRevision: 0, inboxChanged() {}, refreshUnreadStatus() {},
    mailboxId: 'inbox', nextPosition: null, queryState: undefined, query: '', unreadOnly: false, refreshRequired: false, emailsDirty: false,
    savedCopyAt: 0, savedCopyFromDirty: false, error: '', cacheWarning: false, swipeClosing: false, boxes: [],
    conversationIndex: [], conversationById: new Map(),
    accountStore: { mail: {
      view: async () => state.viewRead ? state.viewRead() : clone(state.view),
      cachedMessages: async () => state.indexRead ? state.indexRead() : state.view.emails.map(value => ({ mail: clone(value) })),
      email: async () => { if (state.bodyRead) return state.bodyRead(); throw new Error('Unexpected body read'); },
      saveView: async () => { throw new Error('Unexpected downloaded page'); }
    } },
    client: { emailPage: async () => { state.pageCalls++; const error = new Error('Synthetic offline'); error.code = 'network'; throw error; } },
    label: name => name,
    paths: { pushPathByName() {} }, allows: () => false,
    mailScroller: { closeAllSwipeActions: options => state.closeCallbacks.push(options.onFinish) },
    refreshConversationFolder: async () => { throw new Error('Unexpected conversation download'); }
  });
  return { ui, state, savedAt };
}

test('Cached navigation during a read/unread operation remains actionable after each background acknowledgement', async () => {
  const { ui, state } = fixture();
  for (const seen of [true, false, true, false]) {
    state.pending = true; state.view.stateDirty = true;
    await ui.loadPage(true, true);
    assert.equal(ui.rowAllows(ui.emails[0], '$seen'), false, 'An in-flight operation cannot be duplicated');
    state.pending = false; state.view.stateDirty = false; state.view.emails = [mail(seen)];
    ui.operationRevision++;
    await ui.operationsChanged();
    assert.equal(ui.rowAllows(ui.emails[0], '$seen'), true, 'A completed operation must allow the next read/unread toggle');
    assert.equal(ui.refreshRequired, false);
    assert.equal(ui.emailsDirty, false);
    assert.equal(ui.savedCopyAt, 0, 'A transient dirty caption must not lock out later operations');
    assert.equal(ui.emails[0].keywords.includes('$seen'), seen);
  }
  assert.equal(state.pageCalls, 0, 'Reopening downloaded mail must not require a server request');
});

test('A genuine offline saved-copy indication survives a clean background acknowledgement', async () => {
  const { ui, state, savedAt } = fixture();
  await ui.loadPage(true, false);
  assert.equal(state.pageCalls, 1); assert.equal(ui.savedCopyAt, savedAt);
  state.view.emails = [mail(true)]; ui.operationRevision++;
  await ui.operationsChanged();
  assert.equal(ui.emails[0].keywords.includes('$seen'), true);
  assert.equal(ui.savedCopyAt, savedAt, 'Acknowledging one operation does not prove the mailbox is online');
  assert.equal(ui.rowAllows(ui.emails[0], '$seen'), false);
});

test('A reader acknowledgement between its two cache reads cannot restore an obsolete dirty lockout', async () => {
  const { ui, state, savedAt } = fixture();
  const first = { version: 1, savedAt, bodySavedAt: savedAt, bodyDecoderRevision: 1, stateDirty: true, mail: mail(true) };
  const acknowledged = { ...first, stateDirty: false, mail: mail(false) };
  state.pending = true; let reads = 0;
  state.bodyRead = () => {
    if (++reads === 1) return clone(first);
    // The original callback has already announced completion before the
    // reader's second cache read. There will be no later acknowledgement.
    state.pending = false; ui.operationRevision++;
    return clone(acknowledged);
  };
  await ui.read(first.mail);
  assert.equal(reads, 2);
  assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.selected.keywords.includes('$seen'), false);
  assert.equal(ui.refreshRequired, false, 'Only the latest cached mutation state governs reader recovery');
  assert.equal(ui.savedCopyAt, 0, 'An acknowledged message must not regain the earlier dirty caption');
  assert.equal(ui.rowAllows(ui.selected, '$seen'), true);
  assert.equal(state.pageCalls, 0);
});

test('An older operation callback cannot replace newer acknowledged flags in the same navigation generation', async () => {
  const { ui, state } = fixture();
  const oldRead = deferred(), oldStarted = deferred();
  const staleSnapshot = clone(state.view); let reads = 0;
  state.viewRead = () => {
    if (++reads === 1) { oldStarted.resolve(); return oldRead.promise; }
    return Promise.resolve(clone(state.view));
  };
  ui.operationRevision = 1;
  const oldCallback = ui.operationsChanged();
  await oldStarted.promise;
  state.view.emails = [mail(true)]; ui.operationRevision = 2;
  await ui.operationsChanged();
  assert.equal(ui.emails[0].keywords.includes('$seen'), true);
  oldRead.resolve(staleSnapshot); await oldCallback;
  assert.equal(ui.emails[0].keywords.includes('$seen'), true, 'Late old cache snapshots must not undo the newer acknowledgement');
  assert.equal(ui.rowAllows(ui.emails[0], '$seen'), true);
});

test('A delayed conversation-index read cannot put old read/unread flags back after a newer acknowledgement', async () => {
  const { ui, state } = fixture();
  const oldRead = deferred(), oldStarted = deferred(); let reads = 0;
  state.indexRead = () => {
    if (++reads === 1) { oldStarted.resolve(); return oldRead.promise; }
    return Promise.resolve(state.view.emails.map(value => ({ mail: clone(value) })));
  };
  ui.operationRevision = 1;
  const oldCallback = ui.operationsChanged(); await oldStarted.promise;
  state.view.emails = [mail(true)]; ui.operationRevision = 2;
  await ui.operationsChanged();
  assert.equal(ui.conversationIndex[0].keywords.includes('$seen'), true);
  oldRead.resolve([{ mail: mail(false) }]); await oldCallback;
  assert.equal(ui.conversationIndex[0].keywords.includes('$seen'), true,
    'Conversation unread grouping must use the latest operation revision');
  assert.equal(ui.conversationById.get('synthetic_mail')[0].keywords.includes('$seen'), true);
});

function reply(id, seen, receivedAt, mailboxIds = ['inbox']) {
  return { ...mail(seen), id, threadId: 'received_and_sent_thread', messageIds: [`${id}@example.test`], receivedAt, mailboxIds };
}
async function visibleFixture(messages, records = messages) {
  const result = fixture(), { ui, state } = result;
  state.view.emails = clone(messages); ui.emails = clone(messages);
  state.indexRead = async () => records.map(value => ({ mail: clone(value) }));
  await ui.loadConversationIndex(ui.account.id, ui.generation);
  ui.unreadOnly = true;
  return result;
}

test('Unread conversations open the older unread message when the newest reply is already read', async () => {
  const newest = reply('newest_read', true, 200), older = reply('older_unread', false, 100);
  const { ui } = await visibleFixture([newest, older]);
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [older.id]);
  ui.unreadOnly = false;
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [newest.id]);
});

test('All-read inbox conversations stay out of the unread filter even when a related message in Sent is unread', async () => {
  const newest = reply('newest_read', true, 200), older = reply('older_read', true, 100);
  const sent = reply('sent_copy', false, 150, ['server_sent']);
  const { ui } = await visibleFixture([newest, older], [newest, older, sent]);
  assert.deepEqual(ui.visibleEmails(), []);
});

test('Pending read and unread overlays immediately update conversation filtering before the cache acknowledgement', async () => {
  const newest = reply('newest_read', true, 200), older = reply('older_unread', false, 100);
  const { ui, state } = await visibleFixture([newest, older]);
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [older.id]);
  state.overlays.set(older.id, { ...older, keywords: ['$seen'] });
  assert.deepEqual(ui.visibleEmails(), []);
  assert.deepEqual(ui.emails[1].keywords, [], 'Only the pending operation changed; the stored row is still old');
  state.overlays.set(newest.id, { ...newest, keywords: [] });
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [newest.id]);
});

test('Pending moves remove only the moved inbox member from the unread conversation filter', async () => {
  const newest = reply('newest_read', true, 200), older = reply('older_unread', false, 100);
  const { ui, state } = await visibleFixture([newest, older]);
  state.overlays.set(newest.id, { ...newest, mailboxIds: ['archive'] });
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [older.id]);
  state.overlays.clear();
  state.overlays.set(older.id, { ...older, mailboxIds: ['archive'] });
  assert.deepEqual(ui.visibleEmails(), []);
  ui.unreadOnly = false;
  assert.deepEqual(ui.visibleEmails().map(value => value.id), [newest.id]);
});

test('Swipe read/unread and Star use current flags and dispatch once after the native swipe region closes', async () => {
  for (const keyword of ['$seen', '$flagged']) {
    const { ui, state } = fixture();
    const rendered = { ...mail(), keywords: [] };
    ui.emails = [{ ...rendered, keywords: [keyword] }];
    await ui.rowKeyword(rendered, keyword);
    await ui.rowKeyword(rendered, keyword);
    await ui.rowKeyword(rendered, keyword === '$seen' ? '$flagged' : '$seen');
    assert.equal(state.closeCallbacks.length, 1, 'Repeated taps cannot start another native close');
    assert.equal(state.operationCalls.length, 0, 'Rows must not mutate underneath the revealed hit region');
    assert.equal(ui.rowAllows(ui.emails[0], keyword), false);
    state.closeCallbacks[0](); state.closeCallbacks[0]();
    assert.equal(state.operationCalls.length, 1, 'A duplicate native finish callback must not replay the action');
    assert.equal(state.operationCalls[0].keyword, keyword);
    assert.deepEqual(state.operationCalls[0].mail.keywords, [keyword], 'Toggle the latest flag state, not the old rendered button argument');
  }
});

test('An interrupted native swipe close dispatches once after its deadline and ignores a late finish callback', async () => {
  const { ui, state } = fixture();
  await ui.rowKeyword(ui.emails[0], '$flagged');
  assert.equal(ui.swipeClosing, true); assert.equal(state.operationCalls.length, 0);
  // Deliberately omit the native onFinish, as happens when a panel animation
  // is interrupted. Exercise the production deadline, not a copied timeout.
  await new Promise(resolve => setTimeout(resolve, 1100));
  assert.equal(state.operationCalls.length, 1);
  assert.equal(state.operationCalls[0].keyword, '$flagged');
  assert.equal(ui.swipeClosing, false); assert.equal(ui.pendingSwipeAction, null);
  state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1, 'A delayed native finish must not submit again');
});

test('A queued swipe action retains its original account without changing the newly selected account', async () => {
  const { ui, state } = fixture();
  const original = { accountId: ui.account.id, serverId: ui.account.serverId, client: ui.client, store: ui.accountStore };
  await ui.rowKeyword(ui.emails[0], '$flagged');
  ui.account = { id: 'other_account', serverId: 'other_server', sessionUrl: 'imaps://other.example.test' };
  ui.client = { name: 'other_client' }; ui.accountStore = { name: 'other_store' }; ui.generation++;
  const otherMail = { ...mail(true), subject: 'Other account, same protocol identifier' };
  ui.emails = [otherMail];
  state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1);
  const call = state.operationCalls[0];
  assert.equal(call.accountId, original.accountId); assert.equal(call.serverId, original.serverId);
  assert.equal(call.client, original.client); assert.equal(call.store, original.store);
  assert.equal(ui.emails[0], otherMail, 'Completion must not repaint a colliding message ID from another account');
});

test('Stale swipe buttons cannot operate on a message that is no longer in the current inbox rows', async () => {
  const { ui, state } = fixture();
  const removed = ui.emails[0]; ui.emails = [];
  await ui.rowKeyword(removed, '$seen');
  await ui.rowKeyword(removed, '$flagged');
  assert.equal(state.closeCallbacks.length, 0); assert.equal(state.operationCalls.length, 0);
});

test('Swipe Archive closes first and preserves the current membership and original account across navigation', async () => {
  const { ui, state } = fixture();
  ui.boxes = [
    { id: 'inbox', role: 'inbox', mayRemoveItems: true },
    { id: 'archive', role: 'archive', mayAddItems: true }
  ];
  const rendered = { ...mail(), mailboxIds: ['inbox', 'old_label'] };
  const latest = { ...rendered, mailboxIds: ['inbox', 'new_label'] }; ui.emails = [latest];
  const original = { accountId: ui.account.id, serverId: ui.account.serverId, client: ui.client, store: ui.accountStore };
  await ui.archive(rendered); await ui.archive(rendered);
  assert.equal(state.closeCallbacks.length, 1); assert.equal(state.operationCalls.length, 0);
  ui.account = { id: 'other_account', serverId: 'other_server', sessionUrl: 'imaps://other.example.test' };
  ui.client = {}; ui.accountStore = {}; ui.generation++; ui.emails = [];
  state.closeCallbacks[0](); state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1);
  const call = state.operationCalls[0];
  assert.equal(call.kind, 'move'); assert.deepEqual(call.membership, ['new_label', 'archive']);
  assert.deepEqual(call.mail.mailboxIds, latest.mailboxIds);
  assert.equal(call.accountId, original.accountId); assert.equal(call.serverId, original.serverId);
  assert.equal(call.client, original.client); assert.equal(call.store, original.store);
  assert.deepEqual(ui.emails, []);
});
