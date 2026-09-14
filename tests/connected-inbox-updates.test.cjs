const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

// Compile shipping component methods without ArkUI builders. Controlled page
// promises and timers exercise navigation races without sockets or wall waits.
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
function method(name) {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found, `ConnectedMail.${name} must exist`); return found[0];
}
const options = { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS };
const compiled = ts.transpileModule(`export class InboxHost {
${['showError', 'showSavedCopy', 'inboxBlocked', 'inboxChanged', 'refreshInboxQuiet', 'loadPage',
  'loadConversationIndex', 'visibleEmails'].map(method).join('\n')}
}`, { compilerOptions: options }).outputText;
function model(path) {
  const module = { exports: {} };
  new Function('module', 'exports', ts.transpileModule(fs.readFileSync(path, 'utf8'),
    { compilerOptions: options }).outputText)(module, module.exports);
  return module.exports;
}
const conversation = model('harmony/entry/src/main/ets/mail/Conversation.ts');
const cache = model('harmony/entry/src/main/ets/data/MailCacheModel.ts');
const clone = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function mail(id, body = true) {
  return { id, threadId: `thread-${id}`, messageIds: [`${id}@example.test`], mailboxIds: ['inbox'],
    keywords: ['$seen'], from: [], to: [], cc: [], replyTo: [], subject: `Cached message ${id}`,
    preview: 'Cached preview', receivedAt: 123, textBody: body ? `Cached body ${id}` : null,
    htmlBody: null, hasAttachment: false, bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false };
}
function page(emails, nextPosition = null, queryState = 'new-head') {
  return { accountId: 'server-a', emails, position: 0, nextPosition, queryState, total: emails.length, notFound: [] };
}
function fixture() {
  const account = { id: 'account-a', serverId: 'server-a', sessionUrl: 'imaps://example.test' };
  const savedAt = Date.now() - 1000, timers = new Map(), versions = new Map(); let nextTimer = 0;
  const state = { foreground: true, alertsEnabled: true, paths: [], calls: [], writes: [], banners: [], overlays: new Map(),
    records: new Map(), view: { savedAt, emails: [mail('old'), mail('tail')], nextPosition: 50,
      queryState: 'cached-head', stateDirty: false }, nextPage: async () => { throw new Error('Unexpected page'); } };
  for (const value of state.view.emails) state.records.set(value.id, cache.cacheEmail(value, true, null, savedAt));
  const module = { exports: {} };
  const operations = { overlay: (_account, value) => state.overlays.get(value.id) || value, count: () => state.overlays.size };
  const bus = { isForeground: () => state.foreground, revision: id => versions.get(id) || 0 };
  new Function('module', 'exports', 'MailOperations', 'MailCache', 'MailInboxUpdates', 'MailBannerNotice',
    'conversationGroups', 'conversationMessages', 'setTimeout', 'clearTimeout', compiled)(module, module.exports,
    operations, { mutationRevision: () => 0 }, bus, { showInboxArrival: (accountId, version) => state.banners.push({ accountId, version }) }, conversation.conversationGroups, conversation.conversationMessages,
    (fn, delay) => { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; }, id => timers.delete(id));
  const ui = new module.exports.InboxHost();
  Object.assign(ui, { active: true, ready: true, account, generation: 7, operationRevision: 0,
    busy: false, changing: false, swipeClosing: false, inboxSwipes: new Set(), inboxScrollActive: false,
    inboxAcknowledged: new Map(), inboxRequests: new Map(), inboxCachedUpdates: new Set(), inboxFetching: new Set(),
    inboxTimer: -1, inboxAnchorTimer: -1, inboxLoadRevision: 0, inboxViewRevision: 0, inboxRetryKey: '',
    inboxRetries: 0, inboxRetryAt: 0, inboxFirstVisible: 0, inboxScrollRevision: 0,
    mailboxId: 'inbox', boxes: [{ id: 'inbox', role: 'inbox' }], emails: clone(state.view.emails),
    selected: null, bodyLoaded: false, query: '', unreadOnly: false, nextPosition: 50, queryState: 'cached-head',
    conversationIndex: [], conversationById: new Map(), error: '', savedCopyAt: 0, savedCopyFromDirty: false,
    refreshRequired: false, emailsDirty: false, cacheWarning: false,
    paths: { getAllPathName: () => state.paths }, label: name => name,
    mailScroller: { currentOffset: () => ({ yOffset: 0 }) },
    refreshConversationFolder: async () => { throw new Error('Unexpected companion-folder fetch'); }, refreshUnreadStatus() {},
    client: { emailPage: async (...args) => { state.calls.push(args); return state.nextPage(...args); } },
    accountStore: { notificationSettings: async () => ({ enabled: state.alertsEnabled }), mail: {
      view: async () => clone(state.view),
      cachedMessages: async () => Array.from(state.records.values()).map(clone),
      saveView: async (id, mailbox, emails, nextPosition, queryState) => {
        state.writes.push({ id, mailbox, emails: clone(emails) });
        for (const value of emails) state.records.set(value.id,
          cache.cacheEmail(value, false, state.records.get(value.id) || null, Date.now()));
        state.view = { savedAt: Date.now(), emails: emails.map(value => clone(state.records.get(value.id).mail)),
          nextPosition, queryState, stateDirty: false };
      }
    } }
  });
  function fire() {
    assert.equal(timers.size, 1, 'Exactly one debounced UI refresh must be queued');
    const [id, timer] = timers.entries().next().value; timers.delete(id); timer.fn();
    return ui.inboxRequests.get('account-a:inbox');
  }
  return { ui, state, timers, versions, fire, account };
}

test('A manual response from before A → B → A cannot overwrite the newer quiet inbox cache', async () => {
  const { ui, state, versions, account } = fixture(), old = deferred();
  state.nextPage = () => old.promise;
  const manual = ui.loadPage(true, false);
  assert.equal(state.calls.length, 1);
  ui.account = { id: 'account-b', serverId: 'server-b' }; ui.generation++; ui.inboxLoadRevision++;
  ui.account = account; ui.generation++; ui.inboxLoadRevision++; ui.busy = false;
  versions.set(account.id, 2); state.nextPage = async () => page([mail('current', false)]);
  assert.equal(await ui.refreshInboxQuiet(ui.client, account, 'inbox', 2, ui.inboxLoadRevision), true);
  old.resolve(page([mail('obsolete', false)])); await manual;
  assert.equal(state.writes.length, 1, 'Superseded manual list must not write the shared cache');
  assert.deepEqual(state.view.emails.map(value => value.id), ['current']);
  assert.deepEqual(ui.emails.map(value => value.id), ['current']);
  assert.equal(ui.busy, false);
});

test('A burst refresh retains the selected reader, cached tail and body while applying pending flags', async () => {
  const { ui, state, versions, fire, account } = fixture();
  const selected = clone(ui.emails[0]), oldSavedAt = state.records.get('old').bodySavedAt;
  Object.assign(ui, { selected, selectedId: 'old', bodyLoaded: true, query: 'cached', unreadOnly: true,
    savedCopyAt: 42, savedCopyFromDirty: true, refreshRequired: true });
  state.paths = ['read']; state.overlays.set('old', { ...mail('old'), keywords: ['$flagged'] });
  state.nextPage = async () => page([mail('new', false), mail('old', false)], 2);
  for (let version = 1; version <= 3; version++) { versions.set(account.id, version); ui.inboxChanged(); }
  await fire();
  assert.equal(state.calls.length, 1); assert.deepEqual(state.calls[0], ['server-a', 'inbox', 0]);
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
  assert.deepEqual(ui.emails.find(value => value.id === 'old').keywords, ['$flagged']);
  assert.strictEqual(ui.selected, selected); assert.equal(ui.selectedId, 'old'); assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.query, 'cached'); assert.equal(ui.unreadOnly, true); assert.equal(ui.savedCopyAt, 42);
  assert.equal(ui.savedCopyFromDirty, true); assert.equal(ui.refreshRequired, true);
  assert.equal(state.records.get('old').mail.textBody, 'Cached body old');
  assert.equal(state.records.get('old').bodySavedAt, oldSavedAt);
  assert.equal(ui.nextPosition, 2); assert.equal(ui.queryState, 'new-head');
  assert.equal(ui.inboxAcknowledged.get('account-a:inbox'), 3);
});

test('An arrival stays pending through composing, backgrounding and busy state, then resumes once usable', async () => {
  const { ui, state, timers, versions, fire, account } = fixture();
  versions.set(account.id, 1); state.nextPage = async () => page([mail('new', false)]);
  state.paths = ['compose']; ui.inboxChanged(); assert.equal(timers.size, 0);
  state.paths = []; state.foreground = false; ui.inboxChanged(); assert.equal(timers.size, 0);
  state.foreground = true; ui.busy = true; ui.inboxChanged(); assert.equal(timers.size, 0);
  ui.busy = false; ui.inboxChanged(); assert.equal(timers.size, 1);
  state.paths = ['compose']; assert.equal(fire(), undefined, 'Timer must recheck composition before requesting');
  assert.equal(state.calls.length, 0); assert.equal(ui.inboxAcknowledged.size, 0);
  state.paths = []; ui.inboxChanged(); await fire();
  assert.equal(state.calls.length, 1); assert.equal(ui.inboxAcknowledged.get('account-a:inbox'), 1);
  assert.deepEqual(ui.emails.map(value => value.id), ['new']);
});

test('A manual refresh joins an in-flight automatic head request without another download', async () => {
  const { ui, state, timers, versions, fire, account } = fixture(), response = deferred();
  versions.set(account.id, 1); state.nextPage = () => response.promise;
  ui.inboxChanged(); const automatic = fire();
  assert.equal(ui.inboxFetching.has('account-a:inbox'), true);
  const manual = ui.loadPage(true, false);
  assert.equal(state.calls.length, 1); assert.equal(ui.busy, false, 'Waiting for existing work must leave navigation responsive');
  response.resolve(page([mail('new', false), mail('old', false)]));
  await Promise.all([automatic, manual]);
  assert.equal(state.calls.length, 1); assert.equal(state.writes.length, 1);
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old']);
  assert.equal(ui.inboxRequests.size, 0); assert.equal(timers.size, 0); assert.equal(ui.busy, false);
});

test('Foreground banner announces only an accepted prepended unread arrival, not baseline, flag toggles, old rows or a new epoch', async () => {
  const unread = id => ({ ...mail(id, false), keywords: [] });
  for (const scenario of [
    { name: 'new prefix', rows: [unread('arrived'), mail('old')], expected: 1 },
    { name: 'known flag toggle', rows: [unread('old'), mail('tail')], expected: 0 },
    { name: 'older page exposure', rows: [mail('old'), unread('previously-unloaded-older')], expected: 0 },
    { name: 'new opaque epoch', rows: [unread('new-epoch')], expected: 0 },
    { name: 'empty cached inbox', rows: [unread('arrived')], expected: 1, empty: true },
    { name: 'initial download', rows: [unread('arrived')], expected: 0, missing: true },
    { name: 'failed persistence', rows: [unread('arrived'), mail('old')], expected: 0, fail: true }
  ]) {
    const { ui, state, account } = fixture();
    if (scenario.empty) { state.view.emails = []; ui.emails = []; }
    if (scenario.missing) state.view = null;
    if (scenario.fail) ui.accountStore.mail.saveView = async () => { throw new Error('Synthetic storage failure'); };
    state.nextPage = async () => page(scenario.rows);
    await ui.refreshInboxQuiet(ui.client, account, 'inbox', 3, ui.inboxLoadRevision);
    assert.equal(state.banners.length, scenario.expected, scenario.name);
    if (scenario.expected) assert.deepEqual(state.banners[0], { accountId: account.id, version: 3 });
  }
});

test('Muted accounts still update cached inbox rows but emit no foreground banner', async () => {
  const { ui, state, account } = fixture();
  state.alertsEnabled = false;
  state.nextPage = async () => page([{ ...mail('arrived', false), keywords: [] }, mail('old')]);
  assert.equal(await ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision), true);
  assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old']);
  assert.equal(state.writes.length, 1); assert.equal(state.banners.length, 0);
  assert.equal(state.calls.length, 1, 'Alert filtering must not add server requests');
});

test('Disabling alerts or removing the account while inbox headers are pending suppresses its arrival banner', async () => {
  for (const removed of [false, true]) {
    const { ui, state, account } = fixture(), response = deferred();
    state.nextPage = () => response.promise;
    const pending = ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision);
    if (removed) ui.accountStore.notificationSettings = async () => ({ enabled: false });
    else state.alertsEnabled = false;
    response.resolve(page([{ ...mail('arrived', false), keywords: [] }, mail('old')]));
    await pending;
    assert.equal(state.banners.length, 0); assert.equal(state.writes.length, 1);
    assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old']);
  }
});

test('Unread inbox rows remain usable when the local alert preference cannot be read', async () => {
  const { ui, state, account } = fixture();
  ui.accountStore.notificationSettings = async () => { throw new Error('Synthetic local read failure'); };
  state.nextPage = async () => page([{ ...mail('arrived', false), keywords: [] }, mail('old')]);
  assert.equal(await ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision), true);
  assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old']);
  assert.equal(state.banners.length, 0); assert.equal(ui.inboxRetries, 0);
});
