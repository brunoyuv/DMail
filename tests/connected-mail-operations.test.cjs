const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { bindReaderLoader, MailMessageLoadCancelled, AutomaticMailWorkCancelled, automatic } = require('./reader-loader-fixture.cjs');

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
${['showError', 'showSavedCopy', 'refreshedPage', 'loadPage', 'read', 'applyReaderMetadata', 'applyBoxes', 'operationsChanged', 'loadConversationIndex', 'rowAllows', 'rowArchiveAllows', 'visibleEmails',
  'closeSwipeAction', 'rowKeyword', 'archive', 'moveTarget', 'loadMailAction', 'serverChecksTrash', 'allows', 'changeKeyword', 'applyMessage'].map(method).join('\n')}
}`, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const conversationModule = { exports: {} };
const conversationCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/Conversation.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', conversationCode)(conversationModule, conversationModule.exports);
const jmapModule = { exports: {} };
const jmapCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', jmapCode)(jmapModule, jmapModule.exports);
const sentModule = { exports: {} };
const sentCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/SentMail.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('module', 'exports', sentCode)(sentModule, sentModule.exports);
const cacheModelModule = { exports: {} };
const cacheModelCode = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/data/MailCacheModel.ts', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
new Function('require', 'module', 'exports', cacheModelCode)(name => {
  if (name === './MailContentFileModel') return require('../.tools/test-output/data/MailContentFileModel.js');
  if (name === '../mail/jmap/JmapClient') return jmapModule.exports;
  assert.equal(name, '../mail/MessagePreview');
  const preview = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/MessagePreview.ts', 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  new Function('module', 'exports', code)(preview, preview.exports);
  return preview.exports;
}, cacheModelModule, cacheModelModule.exports);
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
    nextPosition: 50, queryState: 'synthetic-state' }, viewRead: null, bodyRead: null, summaryRead: null, indexRead: null, pageCalls: 0, loaderCalls: [],
    overlays: new Map(), closeCallbacks: [], operationCalls: [], paths: [],
    folderRevisions: new Map(), folders: new Map(), folderRead: null, folderReads: [], appliedBoxes: [], folderNetworkCalls: 0 };
  const operations = {
    mailboxRevision: accountId => state.folderRevisions.get(accountId) || 0,
    currentEmailId: (_account, id) => id,
    undo: () => null, count: () => state.pending ? 1 : 0, pending: () => state.pending,
    overlay: (_account, value) => state.overlays.get(value.id) || (state.pending ? { ...value,
      keywords: value.keywords.includes('$seen') ? value.keywords.filter(keyword => keyword !== '$seen') : [...value.keywords, '$seen'] } : value),
    setKeyword: (store, client, accountId, serverId, value, keyword) => {
      state.operationCalls.push({ kind: 'keyword', store, client, accountId, serverId, mail: clone(value), keyword });
    },
    move: (store, client, accountId, serverId, value, membership, undo, action) => {
      state.operationCalls.push({ kind: 'move', store, client, accountId, serverId, mail: clone(value), membership: membership.slice(), undo, action });
    }
  };
  const module = { exports: {} };
  new Function('module', 'exports', 'MailOperations', 'MailCache', 'conversationGroups', 'conversationMessages', 'cacheReadyForReading', 'archiveTarget', 'trashTarget', 'canSetKeyword', 'MailInboxUpdates', 'shallowCopyEmail', 'stableMessageKey', 'MailMessageLoadCancelled', 'AutomaticMailWork', 'AutomaticMailWorkCancelled', 'serverSentMailbox', 'LOCAL_SENT_MAILBOX', compiled)(module, module.exports,
    operations, { mutationRevision: () => 0 }, conversationModule.exports.conversationGroups, conversationModule.exports.conversationMessages,
    cacheModelModule.exports.cacheReadyForReading, jmapModule.exports.archiveTarget, jmapModule.exports.trashTarget, jmapModule.exports.canSetKeyword, { revision: () => 0, isForeground: () => true }, jmapModule.exports.shallowCopyEmail, conversationModule.exports.stableMessageKey, MailMessageLoadCancelled, automatic(state), AutomaticMailWorkCancelled,
    sentModule.exports.serverSentMailbox, sentModule.exports.LOCAL_SENT_MAILBOX);
  const ui = new module.exports.ConnectedMailHost();
  Object.assign(ui, {
    active: true, ready: true, account: { id: 'synthetic_account', serverId: 'synthetic_server', sessionUrl: 'imaps://example.test' },
    mailAction: 'archive', mailActionReady: true, mailActionLoadRevision: 0, generation: 7, mailboxRefreshRevision: 0, mailboxRefreshActive: false, refreshing: false, operationRevision: 0, busy: false, readOnly: false, selected: null, emails: [mail()],
    inboxRequests: new Map(), inboxAcknowledged: new Map(), inboxCachedUpdates: new Set(), inboxFetching: new Set(),
    inboxSwipes: new Set(), inboxLoadRevision: 0, inboxViewRevision: 0, appliedFolderRevisions: new Map(), inboxChanged() {}, refreshUnreadStatus() {},
    mailboxId: 'inbox', nextPosition: null, queryState: undefined, query: '', unreadOnly: false, refreshRequired: false, emailsDirty: false,
    savedCopyAt: 0, savedCopyFromDirty: false, error: '', cacheWarning: false, swipeClosing: false, boxes: [],
    conversation: [], conversationIndex: [], conversationById: new Map(), conversationLoadRevision: 0,
    accountStore: { documents: { read: async () => ({ attempted: false, document: null }) }, mail: {
      boxes: async accountId => {
        state.folderReads.push(accountId);
        return state.folderRead ? state.folderRead(accountId) : clone(state.folders.get(accountId) || null);
      },
      view: async () => state.viewRead ? state.viewRead() : clone(state.view),
      cachedMessages: async () => state.indexRead ? state.indexRead() : state.view.emails.map(value => ({ mail: clone(value) })),
      email: async () => { if (state.bodyRead) return state.bodyRead(); throw new Error('Unexpected body read'); },
      emailSummary: async () => {
        const record = state.summaryRead ? await state.summaryRead() : state.bodyRead ? await state.bodyRead() : null;
        return record ? cacheModelModule.exports.cachedEmailSummary(record) : null;
      },
      saveView: async () => { throw new Error('Unexpected downloaded page'); }
    } },
    client: { emailPage: async () => { state.pageCalls++; const error = new Error('Synthetic offline'); error.code = 'network'; throw error; },
      mailboxes: async () => { state.folderNetworkCalls++; throw new Error('Unexpected folder download'); } },
    label: name => name,
    paths: { getAllPathName: () => state.paths.slice(), pushPathByName: name => state.paths.push(name) }, allows: () => false,
    mailScroller: { closeAllSwipeActions: options => state.closeCallbacks.push(options.onFinish) },
    refreshConversationFolder: async () => { throw new Error('Unexpected conversation download'); }
  });
  const applyBoxes = ui.applyBoxes.bind(ui);
  ui.applyBoxes = async (...args) => { state.appliedBoxes.push(clone(args)); return applyBoxes(...args); };
  bindReaderLoader(ui, state, conversationModule.exports.stableMessageKey);
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

function archiveFolders(label = 'Confirmed Archive') {
  return { savedAt: Date.now(), readOnly: false, roleRevision: cacheModelModule.exports.MAILBOX_ROLE_REVISION, boxes: [
    { id: 'inbox', name: 'Inbox', role: 'inbox', parentId: null, sortOrder: 0, totalEmails: 8, unreadEmails: 2,
      countsKnown: true, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true },
    { id: 'archive', name: label, role: 'archive', parentId: null, sortOrder: 1, totalEmails: 0, unreadEmails: 0,
      countsKnown: false, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true }
  ] };
}

test('Confirmed Archive folder publication reads local cache once per revision without requesting the server', async () => {
  const { ui, state } = fixture(), accountId = ui.account.id;
  const folders = archiveFolders(); state.folders.set(accountId, folders); state.folderRevisions.set(accountId, 1);
  await ui.operationsChanged();
  assert.deepEqual(ui.boxes, folders.boxes); assert.deepEqual(state.folderReads, [accountId]);
  assert.equal(ui.appliedFolderRevisions.get(accountId), 1); assert.equal(state.appliedBoxes.length, 1);
  for (let count = 0; count < 5; count++) { ui.operationRevision++; await ui.operationsChanged(); }
  assert.deepEqual(state.folderReads, [accountId]); assert.equal(state.appliedBoxes.length, 1);
  state.folders.set(accountId, archiveFolders('A later confirmed folder')); state.folderRevisions.set(accountId, 2);
  ui.operationRevision++; await ui.operationsChanged();
  assert.equal(ui.boxes[1].name, 'A later confirmed folder'); assert.equal(ui.appliedFolderRevisions.get(accountId), 2);
  assert.deepEqual(state.folderReads, [accountId, accountId]); assert.equal(state.appliedBoxes.length, 2);
  assert.equal(state.folderNetworkCalls, 0); assert.equal(state.pageCalls, 0);
});

test('A receipt for another account does not read or publish its folders in the current account', async () => {
  const { ui, state } = fixture();
  const current = archiveFolders('Current account folder').boxes; ui.boxes = current;
  state.folderRevisions.set('other_account', 9); state.folders.set('other_account', archiveFolders('Other account folder'));
  ui.operationRevision++; await ui.operationsChanged();
  assert.strictEqual(ui.boxes, current); assert.deepEqual(state.folderReads, []);
  assert.equal(ui.appliedFolderRevisions.size, 0); assert.equal(state.pageCalls, 0); assert.equal(state.folderNetworkCalls, 0);
});

test('A delayed folder read cannot repaint a switched account or consume its unapplied revision', async () => {
  const { ui, state } = fixture(), firstAccount = ui.account, oldRead = deferred(), oldStarted = deferred();
  state.folderRevisions.set(firstAccount.id, 1); state.folders.set(firstAccount.id, archiveFolders('First account Archive'));
  state.folderRevisions.set('other_account', 1); state.folders.set('other_account', archiveFolders('Second account Archive'));
  let held = false;
  state.folderRead = accountId => {
    if (accountId === firstAccount.id && !held) { held = true; oldStarted.resolve(); return oldRead.promise; }
    return clone(state.folders.get(accountId));
  };
  const pending = ui.operationsChanged(); await oldStarted.promise;
  ui.account = { id: 'other_account', serverId: 'other_server' }; ui.generation++; ui.operationRevision++;
  await ui.operationsChanged();
  assert.equal(ui.boxes[1].name, 'Second account Archive'); assert.equal(ui.appliedFolderRevisions.get('other_account'), 1);
  oldRead.resolve(clone(state.folders.get(firstAccount.id))); await pending;
  assert.equal(ui.boxes[1].name, 'Second account Archive'); assert.equal(ui.appliedFolderRevisions.has(firstAccount.id), false);
  ui.account = firstAccount; ui.generation++; ui.operationRevision++; await ui.operationsChanged();
  assert.equal(ui.boxes[1].name, 'First account Archive'); assert.equal(ui.appliedFolderRevisions.get(firstAccount.id), 1);
  assert.deepEqual(state.folderReads, [firstAccount.id, 'other_account', firstAccount.id]);
  assert.deepEqual(state.appliedBoxes.map(args => args[1]), ['other_account', firstAccount.id]);
  assert.equal(state.pageCalls, 0); assert.equal(state.folderNetworkCalls, 0);
});

test('A newer keyword acknowledgement still publishes an unapplied Archive receipt and retains newer flags', async () => {
  const { ui, state } = fixture(), accountId = ui.account.id, oldRead = deferred(), oldStarted = deferred();
  state.folderRevisions.set(accountId, 1); state.folders.set(accountId, archiveFolders());
  let reads = 0;
  state.folderRead = () => {
    if (++reads === 1) { oldStarted.resolve(); return oldRead.promise; }
    return clone(state.folders.get(accountId));
  };
  ui.operationRevision = 1; const older = ui.operationsChanged(); await oldStarted.promise;
  state.view.emails = [mail(true)]; ui.operationRevision = 2; await ui.operationsChanged();
  assert.equal(ui.boxes[1].role, 'archive'); assert.deepEqual(ui.emails[0].keywords, ['$seen']);
  assert.equal(ui.appliedFolderRevisions.get(accountId), 1);
  oldRead.resolve(archiveFolders('Obsolete cache snapshot')); await older;
  assert.equal(ui.boxes[1].name, 'Confirmed Archive'); assert.deepEqual(ui.emails[0].keywords, ['$seen']);
  assert.equal(state.appliedBoxes.length, 1, 'Only the current acknowledgement publishes the confirmed folder revision');
  ui.operationRevision++; await ui.operationsChanged();
  assert.equal(state.folderReads.length, 2, 'Settled revision must not start another folder read');
  assert.equal(state.pageCalls, 0); assert.equal(state.folderNetworkCalls, 0);
});

test('An older receipt callback cannot roll back a newer folder revision', async () => {
  const { ui, state } = fixture(), accountId = ui.account.id, oldRead = deferred(), oldStarted = deferred();
  state.folderRevisions.set(accountId, 1); let reads = 0;
  state.folderRead = () => {
    if (++reads === 1) { oldStarted.resolve(); return oldRead.promise; }
    return archiveFolders('Revision two Archive');
  };
  ui.operationRevision = 1; const older = ui.operationsChanged(); await oldStarted.promise;
  state.folderRevisions.set(accountId, 2); ui.operationRevision = 2; await ui.operationsChanged();
  oldRead.resolve(archiveFolders('Revision one Archive')); await older;
  assert.equal(ui.appliedFolderRevisions.get(accountId), 2); assert.equal(ui.boxes[1].name, 'Revision two Archive');
  assert.equal(state.appliedBoxes.length, 1); assert.equal(state.folderNetworkCalls, 0);
});

test('Missing or failed cached folders leave the revision available to a later local acknowledgement', async () => {
  for (const unavailable of ['missing', 'error']) {
    const { ui, state } = fixture(), accountId = ui.account.id;
    state.folderRevisions.set(accountId, 1); let ready = false;
    state.folderRead = () => {
      if (ready) return archiveFolders();
      if (unavailable === 'error') throw new Error('Synthetic cache temporarily unavailable');
      return null;
    };
    await ui.operationsChanged(); assert.equal(ui.appliedFolderRevisions.has(accountId), false);
    assert.deepEqual(state.appliedBoxes, []);
    ready = true; ui.operationRevision++; await ui.operationsChanged();
    assert.equal(ui.appliedFolderRevisions.get(accountId), 1); assert.equal(ui.boxes[1].role, 'archive');
    assert.equal(state.appliedBoxes.length, 1); assert.equal(state.folderNetworkCalls, 0); assert.equal(state.pageCalls, 0);
  }
});

test('Teardown retires a pending folder publication without consuming its revision', async () => {
  const { ui, state } = fixture(), accountId = ui.account.id, reading = deferred(), started = deferred();
  state.folderRevisions.set(accountId, 1); state.folderRead = () => { started.resolve(); return reading.promise; };
  const pending = ui.operationsChanged(); await started.promise;
  ui.active = false; reading.resolve(archiveFolders()); await pending;
  assert.deepEqual(ui.boxes, []); assert.equal(ui.appliedFolderRevisions.has(accountId), false);
  assert.deepEqual(state.appliedBoxes, []);
  await ui.operationsChanged(); assert.equal(state.folderReads.length, 1);
  assert.equal(state.pageCalls, 0); assert.equal(state.folderNetworkCalls, 0);
});

test('Read and star swipe actions dispatch while header refresh waits, with pending and permission guards intact', async () => {
  for (const keyword of ['$seen', '$flagged']) {
    const { ui, state } = fixture(); ui.busy = true; ui.refreshing = false; ui.mailboxRefreshActive = true;
    assert.equal(ui.rowAllows(ui.emails[0], keyword), true);
    await ui.rowKeyword(ui.emails[0], keyword);
    assert.equal(state.operationCalls.length, 0, 'Finish native swipe closure before replacing its row');
    state.closeCallbacks[0](); state.closeCallbacks[0]();
    assert.equal(state.operationCalls.length, 1);
    assert.equal(state.operationCalls[0].keyword, keyword);
    state.pending = true; assert.equal(ui.rowAllows(ui.emails[0], keyword), false);
    state.pending = false; ui.readOnly = true; assert.equal(ui.rowAllows(ui.emails[0], keyword), false);
    ui.readOnly = false; ui.mailboxRefreshActive = false; assert.equal(ui.rowAllows(ui.emails[0], keyword), false);
  }
});

test('Archive remains available while the native spinner is hidden but its header request is active', async () => {
  const { ui, state } = fixture(); ui.busy = true; ui.refreshing = false; ui.mailboxRefreshActive = true;
  ui.boxes = [{ id: 'inbox', role: 'inbox', mayRemoveItems: true }, { id: 'archive', role: 'archive', mayAddItems: true }];
  assert.equal(ui.rowArchiveAllows(ui.emails[0]), true);
  await ui.archive(ui.emails[0]); assert.equal(state.operationCalls.length, 0);
  state.closeCallbacks[0](); state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1); assert.equal(state.operationCalls[0].kind, 'move');
  assert.deepEqual(state.operationCalls[0].membership, ['archive']);
  state.pending = true; assert.equal(ui.rowArchiveAllows(ui.emails[0]), false);
  state.pending = false; ui.mailboxRefreshActive = false; assert.equal(ui.rowArchiveAllows(ui.emails[0]), false);
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
  const first = { version: 1, savedAt, bodySavedAt: savedAt, bodyDecoderRevision: 1, stateDirty: true,
    mail: { ...mail(true), subject: 'First snapshot', htmlBody: '<p>First saved body</p>' } };
  const acknowledged = { ...first, stateDirty: false,
    mail: { ...mail(false), subject: 'Later cached subject', htmlBody: '<p>Later cached body</p>' } };
  const document = { html: '<p>First prepared document</p>', pictures: [] };
  ui.accountStore.documents.read = async () => ({ attempted: true, document });
  state.pending = true; let reads = 0, summaryReads = 0;
  state.bodyRead = () => { reads++; return clone(first); };
  state.summaryRead = () => {
    summaryReads++;
    // The original callback has already announced completion before the
    // reader's second cache read. There will be no later acknowledgement.
    state.pending = false; ui.operationRevision++;
    return clone(acknowledged);
  };
  await ui.read(first.mail);
  assert.equal(reads, 1); assert.equal(summaryReads, 1, 'The second read requests metadata without loading another body');
  assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.selected.keywords.includes('$seen'), false);
  assert.equal(ui.selected.subject, first.mail.subject); assert.equal(ui.selected.htmlBody, first.mail.htmlBody);
  assert.strictEqual(ui.readerDocument, document, 'Metadata reconciliation preserves the captured prepared document');
  assert.equal(ui.refreshRequired, false, 'Only the latest cached mutation state governs reader recovery');
  assert.equal(ui.savedCopyAt, 0, 'An acknowledged message must not regain the earlier dirty caption');
  assert.equal(ui.rowAllows(ui.selected, '$seen'), true);
  assert.equal(state.pageCalls, 0);
});

test('A background flag acknowledgement preserves the open body and headers while updating mutable metadata', async () => {
  const { ui, state, savedAt } = fixture();
  const selected = { ...mail(), htmlBody: '<p>Opened snapshot</p>', textBody: 'Opened snapshot',
    subject: 'Opened subject', attachments: [{ id: 'original', name: 'saved.pdf' }] };
  const newer = { ...mail(true), htmlBody: '<p>Later cached body</p>', textBody: 'Later cached body',
    subject: 'Later subject', attachments: [], mailboxIds: ['archive'], maySetSeen: false, maySetKeywords: true };
  Object.assign(ui, { selected, selectedId: selected.id, bodyLoaded: true, conversation: [selected] });
  state.paths = ['read']; state.view.emails = [newer];
  state.bodyRead = () => ({ savedAt, bodySavedAt: savedAt, stateDirty: false, mail: newer });
  ui.operationRevision++; await ui.operationsChanged();
  assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.selected.htmlBody, selected.htmlBody);
  assert.equal(ui.selected.textBody, selected.textBody);
  assert.equal(ui.selected.subject, selected.subject);
  assert.strictEqual(ui.selected.attachments, selected.attachments);
  assert.deepEqual(ui.selected.keywords, ['$seen']);
  assert.deepEqual(ui.selected.mailboxIds, ['archive']);
  assert.equal(ui.selected.maySetSeen, false); assert.equal(ui.selected.maySetKeywords, true);
  assert.strictEqual(ui.conversation.find(value => value.id === selected.id), ui.selected);
  assert.equal(ui.emails[0].htmlBody, newer.htmlBody, 'The inbox cache may advance independently of the reader snapshot');
  assert.equal(state.pageCalls, 0);
});

test('A flag acknowledgement cannot publish a partial reader while its saved document read is pending', async () => {
  const { ui, state, savedAt } = fixture(), started = deferred(), response = deferred();
  const summary = { ...mail(), textBody: null, htmlBody: null };
  const firstBody = { ...mail(), htmlBody: '<p>First saved body</p>', textBody: 'First saved body' };
  let cached = { savedAt, bodySavedAt: savedAt, bodyDecoderRevision: 1, stateDirty: false, mail: firstBody }, bodyRequests = 0;
  state.bodyRead = () => cached;
  ui.accountStore.documents.read = async () => { started.resolve(); return response.promise; };
  ui.client.readEmail = async () => { bodyRequests++; throw new Error('Opening must stay local'); };
  const reading = ui.read(summary); await started.promise;
  const acknowledged = { ...mail(true), textBody: 'Concurrent cached body', htmlBody: '<p>Concurrent cached body</p>' };
  cached = { savedAt, bodySavedAt: savedAt, stateDirty: false, mail: acknowledged };
  state.view.emails = [acknowledged]; ui.operationRevision++;
  await ui.operationsChanged();
  assert.equal(ui.busy, true); assert.equal(ui.bodyLoaded, false);
  assert.equal(ui.selected.htmlBody, null); assert.equal(ui.selected.textBody, null);
  assert.deepEqual(ui.selected.keywords, ['$seen'], 'Mutable state remains available while the body request waits');
  const document = { html: '<p>First prepared snapshot</p>', pictures: [] };
  response.resolve({ attempted: true, document }); await reading;
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.busy, false);
  assert.equal(ui.selected.htmlBody, firstBody.htmlBody); assert.equal(ui.selected.textBody, firstBody.textBody);
  assert.strictEqual(ui.readerDocument, document); assert.deepEqual(ui.selected.keywords, ['$seen']);
  assert.equal(bodyRequests, 0); assert.equal(state.loaderCalls.length, 1);
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

test('A delayed general conversation read cannot replace a newer index after a Sent copy arrives', async () => {
  const { ui, state } = fixture(), oldRead = deferred(), oldStarted = deferred(); let reads = 0;
  const original = mail(), sent = { ...mail(true), id: 'new_sent', messageIds: ['sent@example.test'],
    references: original.messageIds, mailboxIds: ['sent'] };
  state.indexRead = () => {
    if (++reads === 1) { oldStarted.resolve(); return oldRead.promise; }
    return Promise.resolve([{ mail: original }, { mail: sent }]);
  };
  const oldCallback = ui.loadConversationIndex(ui.account.id, ui.generation); await oldStarted.promise;
  await ui.loadConversationIndex(ui.account.id, ui.generation);
  assert.deepEqual(ui.conversationIndex.map(value => value.id), ['synthetic_mail', 'new_sent']);
  assert.equal(ui.conversationById.get('synthetic_mail').length, 2);
  oldRead.resolve([{ mail: original }]); await oldCallback;
  assert.deepEqual(ui.conversationIndex.map(value => value.id), ['synthetic_mail', 'new_sent']);
  assert.equal(ui.conversationById.get('synthetic_mail').length, 2);
});

test('General conversation reads capture operation ownership even without an explicit operation argument', async () => {
  const { ui, state } = fixture(), oldRead = deferred(), oldStarted = deferred();
  const current = [{ ...mail(true), id: 'current' }]; ui.conversationIndex = current;
  state.indexRead = () => { oldStarted.resolve(); return oldRead.promise; };
  const reading = ui.loadConversationIndex(ui.account.id, ui.generation); await oldStarted.promise;
  ui.operationRevision++; oldRead.resolve([{ mail: mail(false) }]); await reading;
  assert.equal(ui.conversationIndex, current, 'A flag mutation supersedes a prior general index snapshot');
  ui.active = false; await ui.loadConversationIndex(ui.account.id, ui.generation);
  assert.equal(ui.conversationLoadRevision, 1, 'Teardown does not start or own another cache read');
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

test('Swipe Delete captures its account choice before a closing swipe can outlive navigation', async () => {
  const { ui, state } = fixture();
  ui.mailAction = 'delete';
  ui.boxes = [{ id: 'inbox', role: 'inbox', mayRemoveItems: true }, { id: 'trash', role: 'trash', mayAddItems: true }];
  assert.equal(ui.rowArchiveAllows(ui.emails[0]), true);
  await ui.archive(ui.emails[0]);
  ui.mailAction = 'archive'; ui.account = { id: 'other', serverId: 'other' };
  state.closeCallbacks[0](); state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1);
  assert.equal(state.operationCalls[0].action, 'delete');
  assert.equal(state.operationCalls[0].accountId, 'synthetic_account');
  assert.deepEqual(state.operationCalls[0].membership, ['trash']);
});

test('Account action reads ignore stale A to B to A results and tolerate folder navigation', async () => {
  const { ui } = fixture(), first = deferred(), last = deferred();
  ui.accountStore.mailAction = () => first.promise;
  const old = ui.loadMailAction();
  assert.equal(ui.mailActionReady, false);
  ui.account = { ...ui.account, id: 'other' }; ui.accountStore.mailAction = async () => 'archive';
  await ui.loadMailAction();
  ui.account = { ...ui.account, id: 'synthetic_account' }; ui.accountStore.mailAction = () => last.promise;
  const current = ui.loadMailAction(); ui.generation++;
  last.resolve('delete'); await current;
  first.resolve('archive'); await old;
  assert.equal(ui.mailAction, 'delete'); assert.equal(ui.mailActionReady, true);
});

test('Explicit IMAP Delete reaches server discovery when cached Trash permissions or role are stale', async () => {
  for (const trash of [[], [{ id: 'trash', name: 'Trash', role: null, mayAddItems: false }]]) {
    const { ui, state } = fixture(); ui.mailAction = 'delete';
    ui.boxes = [{ id: 'inbox', role: 'inbox', mayRemoveItems: false }, ...trash];
    assert.equal(ui.rowArchiveAllows(ui.emails[0]), true);
    await ui.archive(ui.emails[0]);
    assert.equal(state.closeCallbacks.length, 1);
    state.closeCallbacks[0]();
    assert.equal(state.operationCalls.length, 1);
    assert.equal(state.operationCalls[0].action, 'delete');
    assert.deepEqual(state.operationCalls[0].membership, ['inbox']);
  }
});

function enableAutomaticRead(ui, state) {
  // Exercise the production permission gate and mutation dispatch, rather than
  // the older fixtures' stub that disables automatic marking altogether.
  delete ui.allows;
  state.bodyRead = () => ({ savedAt: Date.now(), bodySavedAt: Date.now(), stateDirty: false,
    mail: clone(state.view.emails.find(value => value.id === ui.selectedId)) });
}

test('Manually marked-unread IMAP mail becomes read on reopening despite cached EXAMINE permissions', async () => {
  const { ui, state } = fixture();
  const saved = { ...mail(true), maySetSeen: false, maySetKeywords: false };
  ui.emails = [saved]; state.view.emails = [saved];
  await ui.rowKeyword(saved, '$seen'); state.closeCallbacks[0]();
  assert.equal(state.operationCalls.length, 1);
  assert.deepEqual(state.operationCalls[0].mail.keywords, ['$seen']);
  // The server acknowledges the explicit mark-unread. A later cached open
  // still has the permissions from its read-only EXAMINE session.
  state.view.emails = [{ ...saved, keywords: [] }]; ui.operationRevision++;
  await ui.operationsChanged();
  enableAutomaticRead(ui, state);
  await ui.read(ui.emails[0]);
  assert.equal(state.operationCalls.length, 2, 'Opening must submit a server-verified mark-read');
  assert.equal(state.operationCalls[1].mail.id, saved.id);
  assert.deepEqual(state.operationCalls[1].mail.keywords, []);
  assert.equal(state.operationCalls[1].keyword, '$seen');
  await ui.read(ui.emails[0]);
  assert.equal(state.operationCalls.length, 2, 'Repeated reader taps must not duplicate STORE');
  state.view.emails = [{ ...saved, keywords: ['$seen'] }]; ui.operationRevision++;
  await ui.operationsChanged();
  assert.deepEqual(ui.selected.keywords, ['$seen']);
  assert.deepEqual(ui.emails[0].keywords, ['$seen']);
  assert.equal(state.pageCalls, 0);
});

test('Expanding a combined reply marks that reply read while folded unread replies remain unread', async () => {
  const messages = [reply('newest', true, 300), reply('middle', false, 200), reply('oldest', false, 100)]
    .map(value => ({ ...value, maySetSeen: false, maySetKeywords: false }));
  const { ui, state } = await visibleFixture(messages);
  ui.unreadOnly = false; enableAutomaticRead(ui, state);
  await ui.read(ui.visibleEmails()[0]);
  assert.equal(state.operationCalls.length, 0);
  await ui.read(ui.conversation.find(value => value.id === 'middle'), true);
  assert.equal(state.operationCalls.length, 1);
  assert.equal(state.operationCalls[0].mail.id, 'middle');
  state.view.emails = messages.map(value => value.id === 'middle' ? { ...value, keywords: ['$seen'] } : value);
  state.indexRead = async () => state.view.emails.map(mail => ({ mail }));
  ui.operationRevision++; await ui.operationsChanged();
  assert.deepEqual(ui.selected.keywords, ['$seen']);
  assert.deepEqual(ui.conversation.find(value => value.id === 'middle').keywords, ['$seen']);
  assert.deepEqual(ui.conversation.find(value => value.id === 'oldest').keywords, []);
  assert.deepEqual(state.paths, ['read']);
  assert.equal(state.pageCalls, 0);
});

test('Automatic marking preserves account, dirty-cache, local-copy and pending-operation restrictions', () => {
  for (const restriction of ['readOnly', 'refreshRequired', 'savedCopyAt', 'busy', 'swipeClosing', 'pending', 'local', 'jmap']) {
    const { ui, state } = fixture(); delete ui.allows;
    ui.selected = { ...mail(), maySetSeen: false, maySetKeywords: false };
    if (restriction === 'pending') state.pending = true;
    else if (restriction === 'local') ui.selected.id = 'local_sent_synthetic';
    else if (restriction === 'jmap') ui.account.sessionUrl = 'https://jmap.example.test';
    else ui[restriction] = restriction === 'savedCopyAt' ? Date.now() : true;
    assert.equal(ui.allows('$seen'), false, restriction);
  }
});
