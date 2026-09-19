const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { bindReaderLoader, MailMessageLoadCancelled, AutomaticMailWorkCancelled, automatic, actualLoaderFixture } = require('./reader-loader-fixture.cjs');

// Compile shipping component methods without ArkUI builders. Controlled page
// promises and timers exercise navigation races without sockets or wall waits.
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
function method(name) {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found, `ConnectedMail.${name} must exist`); return found[0];
}
const options = { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS };
const compiled = ts.transpileModule(`export class InboxHost {
${['showError', 'showSavedCopy', 'refreshedPage', 'inboxBlocked', 'inboxChanged', 'refreshInboxQuiet', 'loadPage',
  'retireInboxInteraction', 'inboxVisibilityChanged', 'readerVisibilityChanged',
  'loadConversationIndex', 'refreshConversationFolder', 'visibleEmails', 'read', 'applyReaderMetadata', 'refreshMailbox', 'rowAllows', 'updateSearchPosition'].map(method).join('\n')}
}`, { compilerOptions: options }).outputText;
function model(path) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', ts.transpileModule(fs.readFileSync(path, 'utf8'),
    { compilerOptions: options }).outputText)(name => {
      if (name === './MailContentFileModel') return require('../.tools/test-output/data/MailContentFileModel.js');
      if (name === '../mail/jmap/JmapClient') return model('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts');
      assert.equal(name, '../mail/MessagePreview');
      return model('harmony/entry/src/main/ets/mail/MessagePreview.ts');
    }, module, module.exports);
  return module.exports;
}
const conversation = model('harmony/entry/src/main/ets/mail/Conversation.ts');
const cache = model('harmony/entry/src/main/ets/data/MailCacheModel.ts');
const jmap = model('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts');
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
  const state = { foreground: true, alertsEnabled: true, paths: [], calls: [], writes: [], banners: [], overlays: new Map(), loaderCalls: [], bodyCalls: [],
    records: new Map(), view: { savedAt, emails: [mail('old'), mail('tail')], nextPosition: 50,
      queryState: 'cached-head', stateDirty: false }, nextPage: async () => { throw new Error('Unexpected page'); } };
  for (const value of state.view.emails) state.records.set(value.id, cache.cacheEmail(value, true, null, savedAt));
  const module = { exports: {} };
  const operations = { overlay: (_account, value) => state.overlays.get(value.id) || value, count: () => state.overlays.size, pending: () => false, clearNotices() {} };
  const bus = { isForeground: () => state.foreground, revision: id => versions.get(id) || 0 };
  new Function('module', 'exports', 'MailOperations', 'MailCache', 'MailInboxUpdates', 'MailBannerNotice', 'DeferredSave',
    'conversationGroups', 'conversationMessages', 'cacheReadyForReading', 'canSetKeyword', 'setTimeout', 'clearTimeout', 'stableMessageKey', 'shallowCopyEmail', 'MailMessageLoadCancelled', 'AutomaticMailWork', 'AutomaticMailWorkCancelled', compiled)(module, module.exports,
    operations, { mutationRevision: () => 0 }, bus, { showInboxArrival: (accountId, version) => state.banners.push({ accountId, version }) }, { flushAll: async () => {} }, conversation.conversationGroups, conversation.conversationMessages, cache.cacheReadyForReading, jmap.canSetKeyword,
    (fn, delay) => { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; }, id => timers.delete(id), conversation.stableMessageKey, jmap.shallowCopyEmail, MailMessageLoadCancelled, automatic(state), AutomaticMailWorkCancelled);
  const ui = new module.exports.InboxHost();
  Object.assign(ui, { active: true, ready: true, account, generation: 7, operationRevision: 0, mailboxRefreshRevision: 0, mailboxRefreshActive: false, boxRolesCurrent: true, refreshing: false,
    busy: false, changing: false, swipeClosing: false, inboxSwipes: new Set(), inboxScrollActive: false,
    inboxVisible: true, readerVisible: false, readerScrollActive: false,
    inboxAcknowledged: new Map(), inboxRequests: new Map(), inboxCachedUpdates: new Set(), inboxFetching: new Set(),
    inboxTimer: -1, inboxAnchorTimer: -1, inboxLoadRevision: 0, inboxViewRevision: 0, inboxRetryKey: '',
    inboxRetries: 0, inboxRetryAt: 0, inboxFirstVisible: 0, inboxScrollRevision: 0,
    mailboxId: 'inbox', boxes: [{ id: 'inbox', role: 'inbox' }], emails: clone(state.view.emails),
    selected: null, bodyLoaded: false, query: '', unreadOnly: false, nextPosition: 50, queryState: 'cached-head',
    conversationIndex: [], conversationById: new Map(), conversationLoadRevision: 0, conversationRefreshes: new Map(), error: '', savedCopyAt: 0, savedCopyFromDirty: false,
    refreshRequired: false, emailsDirty: false, cacheWarning: false, readOnly: false, searchVisible: false, searchInteracted: false, inboxPullActive: false,
    paths: { getAllPathName: () => state.paths, pushPathByName: name => state.paths.push(name) }, allows: () => false, label: name => name,
    mailScroller: { currentOffset: () => ({ yOffset: 0 }) },
    refreshUnreadStatus() {}, openNotification: async () => {}, saveCache: async work => work,
    client: { readEmail: async (...args) => { state.bodyCalls.push(args); throw new Error('Unexpected body download'); }, emailPage: async (...args) => { state.calls.push(args); return state.nextPage(...args); } },
    accountStore: { documents: { read: async () => ({ document: null, attempted: false }) }, notificationSettings: async () => ({ enabled: state.alertsEnabled }), mail: {
      view: async () => clone(state.view),
      email: async (_accountId, id) => clone(state.records.get(id) || null),
      emailSummary: async (_accountId, id) => {
        const saved = state.records.get(id); return saved ? cache.cachedEmailSummary(clone(saved)) : null;
      },
      saveEmail: async (_accountId, value) => state.records.set(value.id, cache.cacheEmail(value, true, state.records.get(value.id) || null, Date.now())),
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
  bindReaderLoader(ui, state, conversation.stableMessageKey);
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
  await Promise.resolve(); await Promise.resolve();
  assert.equal(state.calls.length, 1);
  ui.account = { id: 'account-b', serverId: 'server-b' }; ui.generation++; ui.inboxLoadRevision++;
  ui.account = account; ui.generation++; ui.inboxLoadRevision++; ui.busy = false;
  versions.set(account.id, 2); state.nextPage = async () => page([mail('current', false)]);
  assert.equal(await ui.refreshInboxQuiet(ui.client, account, 'inbox', 2, ui.inboxLoadRevision), true);
  old.resolve(page([mail('obsolete', false)])); await manual;
  assert.equal(state.writes.length, 1, 'Superseded manual list must not write the shared cache');
  assert.deepEqual(state.view.emails.map(value => value.id), ['current', 'old', 'tail']);
  assert.deepEqual(ui.emails.map(value => value.id), ['current', 'old', 'tail']);
  assert.equal(state.loaderCalls.length, 0, 'Header responses cannot start reader work');
  assert.equal(state.bodyCalls.length, 0);
  assert.equal(ui.busy, false);
});

test('A burst refresh retains the selected reader, cached tail and body while applying pending flags', async () => {
  const { ui, state, versions, fire, account } = fixture();
  const selected = clone(ui.emails[0]), oldSavedAt = state.records.get('old').bodySavedAt;
  Object.assign(ui, { selected, selectedId: 'old', bodyLoaded: true, query: 'cached', unreadOnly: true,
    savedCopyAt: 42, savedCopyFromDirty: true, refreshRequired: true });
  state.paths = ['read']; state.overlays.set('old', { ...mail('old'), keywords: ['$flagged'] });
  state.nextPage = async () => page([mail('new', false), { ...mail('old', false), preview: '' }], 2);
  for (let version = 1; version <= 3; version++) { versions.set(account.id, version); ui.inboxChanged(); }
  await fire();
  assert.equal(state.calls.length, 1); assert.deepEqual(state.calls[0], ['server-a', 'inbox', 0, undefined, ['old', 'tail']]);
  assert.equal(ui.emails.find(value => value.id === 'old').preview, 'Cached preview');
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
  assert.deepEqual(ui.emails.find(value => value.id === 'old').keywords, ['$flagged']);
  assert.strictEqual(ui.selected, selected); assert.equal(ui.selectedId, 'old'); assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.query, 'cached'); assert.equal(ui.unreadOnly, true); assert.equal(ui.savedCopyAt, 42);
  assert.equal(ui.savedCopyFromDirty, true); assert.equal(ui.refreshRequired, true);
  assert.equal(state.records.get('old').mail.textBody, 'Cached body old');
  assert.equal(state.records.get('old').bodySavedAt, oldSavedAt);
  assert.equal(ui.nextPosition, 2); assert.equal(ui.queryState, 'new-head');
  assert.equal(ui.inboxAcknowledged.get('account-a:inbox'), 3);
  assert.equal(state.loaderCalls.length, 0, 'An arrival may save headers but cannot open or download bodies');
  assert.equal(state.bodyCalls.length, 0);
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
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
});

test('A manual refresh joins an in-flight automatic head request without another download', async () => {
  const { ui, state, timers, versions, fire, account } = fixture(), response = deferred();
  versions.set(account.id, 1); state.nextPage = () => response.promise;
  ui.inboxChanged(); const automatic = fire();
  await Promise.resolve(); await Promise.resolve();
  assert.equal(ui.inboxFetching.has('account-a:inbox'), true);
  const manual = ui.loadPage(true, false);
  assert.equal(state.calls.length, 1); assert.equal(ui.busy, false, 'Waiting for existing work must leave navigation responsive');
  response.resolve(page([mail('new', false), mail('old', false)]));
  await Promise.all([automatic, manual]);
  assert.equal(state.calls.length, 1); assert.equal(state.writes.length, 1);
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
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
  assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old', 'tail']);
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
    assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old', 'tail']);
  }
});

test('Unread inbox rows remain usable when the local alert preference cannot be read', async () => {
  const { ui, state, account } = fixture();
  ui.accountStore.notificationSettings = async () => { throw new Error('Synthetic local read failure'); };
  state.nextPage = async () => page([{ ...mail('arrived', false), keywords: [] }, mail('old')]);
  assert.equal(await ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision), true);
  assert.deepEqual(ui.emails.map(value => value.id), ['arrived', 'old', 'tail']);
  assert.equal(state.banners.length, 0); assert.equal(ui.inboxRetries, 0);
});

test('Companion-folder refresh forwards cached preview identities and stops before network after account navigation', async () => {
  const code = ts.transpileModule(`export class RelatedHost { ${method('refreshConversationFolder')} }`, { compilerOptions: options }).outputText;
  const module = { exports: {} };
  new Function('module', 'exports', 'MailCache', 'MailInboxUpdates', 'AutomaticMailWork', code)(module, module.exports,
    { mutationRevision: () => 0 }, { isForeground: () => true }, automatic({}));
  const host = new module.exports.RelatedHost(), calls = [], gate = deferred();
  let delayed = false;
  const account = { id: 'account-a', serverId: 'server-a' };
  Object.assign(host, { active: true, generation: 1, account, mailboxId: 'inbox', inboxBlocked: () => false,
    readerScrollActive: false, conversationRefreshes: new Map(), loadConversationIndex: async () => {}, paths: { getAllPathName: () => [] },
    boxes: [{ id: 'inbox', role: 'inbox' }, { id: 'sent', role: 'sent' }],
    accountStore: { mail: { view: async () => {
      if (delayed) await gate.promise;
      return { emails: [{ ...mail('sent-known'), mailboxIds: ['sent'] }, { ...mail('sent-blank'), mailboxIds: ['sent'], preview: '' }] };
    }, saveView: async () => {} } }, saveCache: async work => work });
  const client = { emailPage: async (...args) => { calls.push(args); return page([]); } };
  await host.refreshConversationFolder(client, account, 'inbox', 1);
  assert.deepEqual(calls, [['server-a', 'sent', 0, undefined, ['sent-known']]]);
  delayed = true;
  const previous = host.refreshConversationFolder(client, account, 'inbox', 1);
  host.account = { id: 'account-b', serverId: 'server-b' }; host.generation++;
  gate.resolve(); await previous;
  assert.equal(calls.length, 1, 'An old cache read must not start a provider request after account navigation');
});


// Use the actual native row's enabled expression, rather than calling read()
// through a disabled control and accidentally hiding the original regression.
function rowEnabled(ui) {
  const component = fs.readFileSync('harmony/entry/src/main/ets/pages/MailListItem.ets', 'utf8');
  const binding = component.match(/\.id\(`remote-mail-\$\{this\.mail\.id\}`\)\.enabled\(([^\n]+)\)/);
  const input = source.match(/connected: ([^,\n]+), readAllowed:/);
  assert.ok(binding && input, 'The native row receives an explicit reactive enabled binding');
  assert.match(component, /@Prop connected: boolean/);
  const connected = new Function(`return (${input[1]});`).call(ui);
  return new Function(`return (${binding[1]});`).call({ connected });
}
const flush = async () => { for (let i = 0; i < 12; ++i) await Promise.resolve(); };

test('Native visual refresh completion does not release pending headers, lock row actions or resize search', async () => {
  const { ui, state } = fixture(), headers = deferred(); state.nextPage = () => headers.promise;
  const refreshing = ui.refreshMailbox(); await flush();
  assert.equal(state.calls.length, 1); assert.equal(ui.busy, true); assert.equal(ui.mailboxRefreshActive, true);
  // Native Refresh can write false through $$refreshing when an upward drag
  // collapses its spinner, even though the page promise remains unresolved.
  ui.refreshing = false; ui.inboxScrollActive = false; ui.inboxPullActive = false; ui.searchInteracted = true;
  ui.updateSearchPosition();
  assert.equal(ui.searchVisible, false, 'The header must not resize before the held request settles');
  assert.equal(ui.inboxBlocked(), true); assert.equal(rowEnabled(ui), true);
  assert.equal(ui.rowAllows(ui.emails[0], '$seen'), true); assert.equal(ui.rowAllows(ui.emails[0], '$flagged'), true);
  await ui.refreshMailbox();
  assert.equal(state.calls.length, 1, 'Another native refresh callback cannot duplicate the held request');
  assert.equal(ui.mailboxRefreshActive, true); assert.equal(state.writes.length, 0);
  headers.resolve(page([mail('old', false), mail('new', false)])); await refreshing;
  assert.equal(ui.mailboxRefreshActive, false); assert.equal(ui.busy, false); assert.equal(ui.refreshing, false);
  assert.equal(ui.searchVisible, true, 'Search follows the settled scroll position after network completion');
  assert.equal(state.writes.length, 1);
});

test('Cached messages open during a pending manual header refresh and ignore its late result', async () => {
  const { ui, state } = fixture(), headers = deferred();
  state.nextPage = () => headers.promise;
  const refreshing = ui.refreshMailbox(); await flush();
  assert.equal(state.calls.length, 1); assert.equal(ui.busy, true);
  assert.equal(rowEnabled(ui), true, 'Refreshing headers must not disable message taps');
  const pull = source.match(/\.pullToRefresh\(([^\n]+)\)/);
  assert.ok(pull);
  assert.equal(new Function(`return (${pull[1]});`).call(ui), true, 'Network activity must not toggle native pull recognition during its gesture');
  await ui.read(ui.emails[0]);
  assert.equal(ui.mailboxRefreshActive, false, 'Reader navigation retires the old refresh owner');
  assert.equal(ui.selectedId, 'old'); assert.equal(ui.selected.textBody, 'Cached body old');
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.busy, false); assert.equal(ui.refreshing, false);
  headers.resolve(page([mail('obsolete', false)])); await refreshing;
  assert.equal(ui.selectedId, 'old'); assert.equal(ui.selected.textBody, 'Cached body old');
  assert.deepEqual(ui.emails.map(value => value.id), ['old', 'tail']);
  assert.equal(state.writes.length, 0, 'Superseded headers cannot replace the cache');
  assert.equal(ui.busy, false);
});

test('An uncached message reports its selected download failure and stale refresh cannot clear reader busy state', async () => {
  const { ui, state } = fixture(), headers = deferred(), body = deferred(), bodyStarted = deferred();
  state.records.delete('old'); state.nextPage = () => headers.promise; ui.emails[0] = mail('old', false);
  ui.accountStore.mail.email = async () => { bodyStarted.resolve(); return body.promise; };
  let downloads = 0; ui.client.readEmail = async () => { downloads++; throw Object.assign(new Error('Synthetic body failure'), { code: 'network' }); };
  const refreshing = ui.refreshMailbox(); await flush();
  assert.equal(rowEnabled(ui), true);
  const reading = ui.read(ui.emails[0]); await bodyStarted.promise;
  assert.equal(ui.selectedId, 'old'); assert.equal(ui.bodyLoaded, false); assert.equal(ui.busy, true);
  headers.resolve(page([mail('obsolete', false)])); await refreshing;
  assert.equal(ui.busy, true, 'The obsolete header finally must not unlock an active reader');
  assert.equal(ui.selectedId, 'old'); assert.equal(state.writes.length, 0);
  body.resolve(null); await reading;
  assert.equal(ui.bodyLoaded, false); assert.equal(ui.busy, false); assert.equal(ui.selected.textBody, null);
  assert.equal(downloads, 1); assert.equal(state.loaderCalls.length, 1); assert.notEqual(ui.error, '');
});

test('A refresh metadata response after opening cached mail cannot start a new list request', async () => {
  const { ui, state } = fixture(), boxes = deferred();
  ui.boxRolesCurrent = false;
  ui.loadBoxes = async () => { const generation = ++ui.generation; ui.busy = true; await boxes.promise;
    if (generation === ui.generation) ui.busy = false; };
  const refreshing = ui.refreshMailbox();
  assert.equal(rowEnabled(ui), true);
  await ui.read(ui.emails[0]);
  const generation = ui.generation;
  boxes.resolve(); await refreshing;
  assert.equal(state.calls.length, 0, 'A cancelled metadata continuation must not refresh over the reader');
  assert.equal(ui.generation, generation); assert.equal(ui.selectedId, 'old');
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.busy, false); assert.equal(ui.refreshing, false);
});

test('An earlier refresh finalizer cannot end a subsequent refresh after reader navigation', async () => {
  const { ui, state } = fixture(), oldHeaders = deferred(), currentHeaders = deferred();
  state.nextPage = () => oldHeaders.promise;
  const oldRefresh = ui.refreshMailbox(); await flush();
  await ui.read(ui.emails[0]);
  state.paths = []; state.nextPage = () => currentHeaders.promise;
  const currentRefresh = ui.refreshMailbox(); await flush();
  assert.equal(state.calls.length, 2); assert.equal(ui.refreshing, true);
  assert.equal(ui.mailboxRefreshActive, true);
  ui.refreshing = false;
  oldHeaders.resolve(page([mail('obsolete', false)])); await oldRefresh;
  assert.equal(ui.refreshing, false, 'The old request cannot change the newer native visual state');
  assert.equal(ui.mailboxRefreshActive, true, 'The newer request remains active even after native visual completion');
  assert.equal(ui.rowAllows(ui.emails[0], '$flagged'), true);
  assert.equal(ui.busy, true);
  currentHeaders.resolve(page([mail('old', false), mail('current', false)])); await currentRefresh;
  assert.equal(ui.refreshing, false); assert.equal(ui.mailboxRefreshActive, false); assert.equal(ui.busy, false);
  assert.deepEqual(ui.emails.map(value => value.id), ['old', 'current', 'tail']);
  assert.equal(state.writes.length, 1);
});


test('A missing deferred inbox cache backs off locally and stops after three attempts', async () => {
  const { ui, state, timers, versions, fire, account } = fixture();
  const saved = clone(state.view), key = 'account-a:inbox'; let reads = 0;
  ui.inboxCachedUpdates.add(key); versions.set(account.id, 1); state.view = null;
  ui.accountStore.mail.view = async () => { reads++; return clone(state.view); };
  ui.inboxChanged();
  for (let attempt = 1; attempt <= 3; attempt++) {
    await fire();
    assert.equal(ui.inboxRetries, attempt);
    if (attempt < 3) {
      assert.equal(timers.size, 1);
      assert.ok([...timers.values()][0].delay >= 9900, 'Retry uses the existing ten-second backoff');
    } else assert.equal(timers.size, 0, 'Missing cache must not keep the 250ms timer alive indefinitely');
  }
  assert.equal(reads, 3); assert.equal(state.calls.length, 0, 'Deferred cache retries add no server requests');
  assert.equal(ui.inboxCachedUpdates.has(key), true);
  state.view = saved; versions.set(account.id, 2); ui.inboxChanged(); await fire();
  assert.equal(ui.inboxRetries, 0); assert.equal(ui.inboxCachedUpdates.has(key), false);
  assert.equal(state.calls.length, 0);
  assert.equal(timers.size, 1, 'The new server revision remains eligible for its normal header check');
});

test('A cached reader opens during automatic headers and remains selected when the update arrives', async () => {
  const { ui, state, versions, fire, account } = fixture(), headers = deferred();
  state.nextPage = () => headers.promise; versions.set(account.id, 1);
  ui.inboxChanged(); const automatic = fire(); await flush();
  await ui.read(ui.emails[0]);
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.selectedId, 'old'); assert.equal(state.calls.length, 1);
  headers.resolve(page([mail('new', false), mail('old', false)])); await automatic;
  assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
  assert.equal(ui.selectedId, 'old'); assert.equal(ui.selected.textBody, 'Cached body old');
  assert.equal(ui.bodyLoaded, true); assert.equal(ui.busy, false); assert.equal(state.writes.length, 1);
});

test('Repeated taps on an unresolved local reader do not duplicate cache reads, downloads, or navigation entries', async () => {
  const { ui, state } = fixture(), body = deferred(); let downloads = 0, reads = 0;
  ui.accountStore.mail.email = async () => { reads++; return body.promise; };
  ui.client.readEmail = async () => { downloads++; throw new Error('Opening must stay local'); };
  const first = ui.read(ui.emails[0]); await flush();
  assert.equal(reads, 1); assert.equal(downloads, 0); const generation = ui.generation;
  for (let i = 0; i < 20; i++) await ui.read(ui.emails[0]);
  assert.equal(reads, 1); assert.equal(downloads, 0); assert.equal(ui.generation, generation);
  assert.deepEqual(state.paths, ['read']);
  body.resolve(state.records.get('old')); await first;
  assert.equal(ui.bodyLoaded, true); assert.equal(state.loaderCalls.length, 1);
});

test('Picking another cached message reuses the reader destination and stays immediately available', async () => {
  const { ui, state } = fixture();
  await ui.read(ui.emails[0]); await ui.read(ui.emails[1]);
  assert.deepEqual(state.paths, ['read']); assert.equal(ui.selectedId, 'tail');
  assert.equal(ui.selected.textBody, 'Cached body tail'); assert.equal(ui.bodyLoaded, true);
});


test('Inbox refresh completes before a held conversation-index read and optional Sent request', async () => {
  const { ui, state } = fixture(), index = deferred(), sent = deferred();
  let indexReads = 0, finished = false, sentWrites = 0;
  ui.boxes.push({ id: 'sent', role: 'sent' });
  const view = ui.accountStore.mail.view, saveView = ui.accountStore.mail.saveView;
  ui.accountStore.mail.view = async (account, mailbox) => mailbox === 'sent' ? null : view(account, mailbox);
  ui.accountStore.mail.saveView = async (account, mailbox, ...rest) => {
    if (mailbox === 'sent') { sentWrites++; return; }
    return saveView(account, mailbox, ...rest);
  };
  ui.accountStore.mail.cachedMessages = async () => { indexReads++; if (indexReads === 1) await index.promise; return []; };
  state.nextPage = (_account, mailbox) => mailbox === 'sent' ? sent.promise : Promise.resolve(page([mail('new', false)]));
  const refreshing = ui.refreshMailbox().then(() => { finished = true; });
  try {
    await new Promise(setImmediate);
    assert.equal(finished, true, 'Visible Inbox completion must not await the account-wide index');
    assert.equal(ui.busy, false); assert.equal(ui.mailboxRefreshActive, false); assert.equal(ui.refreshing, false);
    assert.deepEqual(ui.emails.map(value => value.id), ['new', 'old', 'tail']);
    index.resolve(); await flush();
    assert.equal(state.calls.filter(call => call[1] === 'sent').length, 1);
    assert.equal(sentWrites, 0, 'The optional server response is still held');
    await ui.refreshMailbox(); await flush();
    assert.equal(state.calls.filter(call => call[1] === 'sent').length, 1, 'Repeated pulls share pending companion work');
    sent.resolve(page([])); await new Promise(setImmediate);
    assert.equal(sentWrites, 1, 'The latest pull must eventually persist its companion update');
    assert.equal(state.calls.filter(call => call[1] === 'sent').length, 2, 'One current successor replaces the superseded response');
  } finally { index.resolve(); sent.resolve(page([])); await refreshing; await flush(); }
});

test('Reopening a cached mailbox retains its pagination without downloading any of its 251 bodies', async () => {
  const { ui, state } = fixture();
  state.view.emails = Array.from({ length: 251 }, (_, i) => mail(`cached-${i}`, false));
  state.view.nextPosition = 50;
  await ui.loadPage(true, true);
  assert.equal(state.calls.length, 0); assert.equal(state.loaderCalls.length, 0); assert.equal(state.bodyCalls.length, 0);
  assert.equal(ui.emails.length, 251); assert.equal(ui.nextPosition, 50); assert.equal(ui.queryState, 'cached-head');
});

test('Pagination saves only its requested headers without queuing bodies or more pages', async () => {
  const { ui, state } = fixture();
  state.nextPage = async () => page([mail('old', false), mail('new', false)], 100);
  await ui.loadPage(false, false); await new Promise(setImmediate);
  assert.equal(ui.busy, false); assert.equal(state.calls.length, 1);
  assert.deepEqual(ui.emails.map(value => value.id), ['old', 'tail', 'new']);
  assert.equal(ui.nextPosition, 100); assert.equal(state.loaderCalls.length, 0); assert.equal(state.bodyCalls.length, 0);
});

test('Backgrounding during Inbox headers saves downloaded rows but starts no optional work', async () => {
  const { ui, state } = fixture(), headers = deferred(); let indexReads = 0;
  ui.boxes.push({ id: 'sent', role: 'sent' });
  ui.accountStore.mail.cachedMessages = async () => { indexReads++; return []; };
  state.nextPage = () => headers.promise;
  const refreshing = ui.refreshMailbox(); await flush(); state.foreground = false;
  headers.resolve(page([mail('arrived', false)])); await refreshing; await flush();
  assert.equal(state.writes.length, 1, 'Downloaded headers remain available offline');
  assert.equal(state.calls.length, 1, 'No Sent session starts after background');
  assert.equal(indexReads, 0, 'No invisible account-wide conversation rebuild');
  assert.equal(ui.busy, false); assert.equal(ui.mailboxRefreshActive, false);
});

test('An optional folder cache read cannot start HTTP after background or duplicate a pending request', async () => {
  const { ui, state, account } = fixture(), cached = deferred();
  ui.boxes.push({ id: 'sent', role: 'sent' });
  ui.accountStore.mail.view = async () => { await cached.promise; return null; };
  const first = ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
  const second = ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
  state.foreground = false; cached.resolve(); await Promise.all([first, second]);
  assert.equal(state.calls.length, 0); assert.equal(ui.conversationRefreshes.size, 0);
});


test('A quiet or explicit refresh cannot begin a server page after a backgrounded cache read', async () => {
  for (const automatic of [false, true]) {
    const { ui, state, account } = fixture(), cached = deferred();
    ui.accountStore.mail.view = async () => { await cached.promise; return clone(state.view); };
    const work = automatic ? ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision) : ui.refreshMailbox();
    await flush(); state.foreground = false; cached.resolve(); await work; await flush();
    assert.equal(state.calls.length, 0, automatic ? 'automatic' : 'manual');
    assert.equal(ui.busy, false);
  }
});

test('A conversation index finishing after background does not rebuild invisible rows', async () => {
  const { ui, state, account } = fixture(), indexed = deferred();
  ui.accountStore.mail.cachedMessages = () => indexed.promise;
  const work = ui.loadConversationIndex(account.id, ui.generation);
  state.foreground = false; indexed.resolve([{ mail: mail('late') }]); await work;
  assert.deepEqual(ui.conversationIndex, []);
});


test('A pending companion successor is dropped after background or account navigation', async () => {
  for (const background of [true, false]) {
    const { ui, state, account } = fixture(), sent = deferred();
    ui.boxes.push({ id: 'sent', role: 'sent' });
    ui.accountStore.mail.view = async () => null;
    state.nextPage = () => sent.promise;
    const first = ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
    await flush(); ui.generation++;
    await ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
    if (background) state.foreground = false;
    else { ui.account = { id: 'other', serverId: 'other' }; ui.generation++; }
    sent.resolve(page([])); await first; await flush();
    assert.equal(state.calls.length, 1); assert.equal(ui.conversationRefreshes.size, 0);
    assert.equal(state.writes.length, 0, 'An obsolete response cannot replace the cache');
  }
});


test('A deferred cached conversation index resumes once without a new arrival or server request', async () => {
  const { ui, state, account } = fixture(), indexed = deferred(); let reads = 0;
  ui.unreadForeground = true;
  ui.accountStore.mail.cachedMessages = async () => { reads++; return reads === 1 ? indexed.promise : [{ mail: mail('current') }]; };
  const work = ui.loadConversationIndex(account.id, ui.generation);
  state.foreground = false; ui.inboxChanged(); indexed.resolve([{ mail: mail('late') }]); await work;
  assert.equal(ui.conversationIndexPending, true); assert.deepEqual(ui.conversationIndex, []);
  state.foreground = true; ui.inboxChanged(); await flush();
  assert.equal(ui.conversationIndexPending, false); assert.equal(reads, 2);
  assert.deepEqual(ui.conversationIndex.map(value => value.id), ['current']);
  for (let i = 0; i < 10; i++) ui.inboxChanged(); await flush();
  assert.equal(reads, 2); assert.equal(state.calls.length, 0);
});

test('Opening Compose during a detached index or companion cache read prevents new Sent requests', async () => {
  for (const duringIndex of [true, false]) {
    const { ui, state, account } = fixture(), held = deferred();
    ui.boxes.push({ id: 'sent', role: 'sent' });
    if (duringIndex) {
      ui.accountStore.mail.cachedMessages = async () => { await held.promise; return []; };
      state.nextPage = async () => page([mail('new', false)]);
      await ui.refreshMailbox();
    } else {
      ui.accountStore.mail.view = async () => { await held.promise; return null; };
      ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
    }
    state.paths = ['compose']; held.resolve(); await new Promise(setImmediate);
    assert.equal(state.calls.filter(call => call[1] === 'sent').length, 0);
    assert.equal(ui.conversationRefreshes.size, 0);
  }
});

// One integration joins the actual UI method and actual message loader. Only
// RDB/HTTP endpoints are synthetic; selection, cache decisions, HTML planning,
// cancellation and single publication all run the shipping code.
test('Only opening prepares HTML and publishes it without waiting for optional pictures', async () => {
  const f = fixture(), body = deferred(), bodyStarted = deferred();
  const w = actualLoaderFixture({
    read: async (_account, id) => { bodyStarted.resolve(); await body.promise; return w.mail(id, { keywords: ['$seen'] }); },
    batch: async () => assert.fail('The body loader must leave picture work to the mounted reader')
  });
  const { ui, state } = f;
  ui.account = { ...w.account, sessionUrl: 'imaps://example.test' }; ui.messageLoader = w.loader;
  ui.client.readEmail = w.client.readEmail;
  ui.accountStore.mail.email = w.store.mail.email;
  ui.accountStore.mail.emailSummary = async (account, id) => {
    const saved = w.bodies.get(`${account}:${id}`); return saved ? cache.cachedEmailSummary(clone(saved)) : null;
  };
  const header = { ...w.mail('selected', { keywords: ['$seen'] }), textBody: null, htmlBody: null };
  state.view.emails = [header]; state.records.clear(); ui.emails = [header];
  state.nextPage = async () => page([header]);
  try {
    await ui.refreshMailbox();
    await ui.refreshInboxQuiet(ui.client, ui.account, 'inbox', 1, ui.inboxLoadRevision);
    await ui.loadPage(true, true);
    assert.equal(w.state.reads.length, 0); assert.equal(w.state.scans, 0); assert.equal(w.state.batches.length, 0);
    const reading = ui.read(header); await bodyStarted.promise;
    assert.equal(ui.busy, true); assert.equal(ui.bodyLoaded, false); assert.equal(w.state.reads.length, 1);
    body.resolve(); await reading;
    assert.equal(w.state.scans, 1); assert.equal(w.state.batches.length, 0);
    assert.equal(ui.busy, false); assert.equal(ui.bodyLoaded, true); assert.equal(ui.selected.textBody, 'Body selected');
    assert.ok(ui.readerDocument.html.includes('Body selected'));
    const document = clone(ui.readerDocument);
    for (let i = 0; i < 5; i++) await ui.read(header);
    state.paths.pop(); await ui.read(header);
    assert.deepEqual(ui.readerDocument, document); assert.equal(w.state.reads.length, 1);
    assert.equal(w.state.scans, 1); assert.equal(w.state.batches.length, 0);
  } finally { body.resolve(); w.loader.cancel(); await w.loader.whenIdle(); }
});

test('Shipping Inbox prefetch wiring follows foreground visibility, interaction and active mailbox ownership', () => {
  const f = fixture(); const updates = [], permission = [];
  const constructor = source.match(/this\.inboxPrefetch = new InboxPrefetch\([\s\S]*?;/)[0];
  class Worker {
    constructor(store, allowed) { assert.equal(store, f.ui.accountStore); this.allowed = allowed; }
    update(...args) { updates.push(args); permission.push(this.allowed()); }
    clear() { permission.push('cleared'); }
  }
  new Function('InboxPrefetch', 'MailInboxUpdates', constructor).call(f.ui, Worker, { isForeground: () => f.state.foreground });
  f.state.alertsEnabled = false; f.ui.inboxChanged(); assert.equal(permission.at(-1), true);
  assert.equal(updates[0][0], f.ui.client); assert.equal(updates[0][1], f.ui.account);
  assert.equal(updates[0][2], 'inbox'); assert.equal(updates[0][3], f.ui.emails);
  assert.equal(updates[0][4], 50); assert.equal(updates[0][5], 'cached-head');
  f.ui.inboxVisible = false; f.ui.readerVisible = true; f.ui.inboxChanged(); assert.equal(permission.at(-1), true);
  f.state.foreground = false; f.ui.inboxChanged(); assert.equal(permission.at(-1), false);
  f.state.foreground = true; f.state.paths = ['compose']; f.ui.inboxChanged(); assert.equal(permission.at(-1), false);
  f.state.paths = []; f.ui.busy = true; f.ui.inboxChanged(); assert.equal(permission.at(-1), false);
  f.ui.busy = false; f.ui.readerScrollActive = true; f.ui.inboxChanged(); assert.equal(permission.at(-1), false);
  f.ui.readerScrollActive = false; f.ui.readerVisible = false; f.ui.inboxChanged(); assert.equal(permission.at(-1), false);
  f.ui.mailboxId = 'sent'; f.ui.inboxChanged(); assert.equal(permission.at(-1), 'cleared');
});

test('Manual refresh retains loaded older pages, the open reader and the unchanged paging cursor', async () => {
  const { ui, state } = fixture();
  const loaded = Array.from({ length: 150 }, (_, i) => mail(`loaded-${i}`));
  state.view = { ...state.view, emails: loaded, nextPosition: 150, queryState: 'stable' };
  ui.emails = clone(loaded); ui.nextPosition = 150; ui.queryState = 'stable';
  const selected = loaded[100], document = { html: '<p>Keep this reader</p>' };
  Object.assign(ui, { selected, selectedId: selected.id, bodyLoaded: true, readerDocument: document });
  state.nextPage = async (_account, _box, position) => position === 0 ?
    page(loaded.slice(0, 50).map(value => ({ ...value, textBody: null })), 50, 'stable') :
    page([mail('older')], null, 'stable');
  await ui.loadPage(true);
  assert.equal(ui.emails.length, 150); assert.equal(state.view.emails.length, 150);
  assert.equal(ui.nextPosition, 150); assert.equal(state.view.nextPosition, 150);
  assert.strictEqual(ui.selected, selected); assert.strictEqual(ui.readerDocument, document);
  assert.equal(ui.bodyLoaded, true); assert.equal(state.bodyCalls.length, 0);
  await ui.loadPage(false);
  assert.deepEqual(state.calls.map(call => call[2]), [0, 150]);
  assert.equal(ui.emails.length, 151); assert.equal(ui.emails.at(-1).id, 'older');
});

test('Quiet refresh retains the reached end for an unchanged mailbox', async () => {
  const { ui, state, account } = fixture();
  state.view.nextPosition = null; ui.nextPosition = null;
  state.nextPage = async () => page([mail('old', false)], 1, 'cached-head');
  await ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision);
  assert.deepEqual(ui.emails.map(value => value.id), ['old', 'tail']);
  assert.equal(ui.nextPosition, null); assert.equal(state.view.nextPosition, null);
});

test('A partial refreshed head does not delete loaded rows merely because there is no overlap', async () => {
  for (const quiet of [false, true]) {
    const { ui, state, account } = fixture();
    state.nextPage = async () => page([mail('new-1', false), mail('new-2', false)], 2, 'changed');
    if (quiet) await ui.refreshInboxQuiet(ui.client, account, 'inbox', 1, ui.inboxLoadRevision);
    else await ui.loadPage(true);
    assert.deepEqual(ui.emails.map(value => value.id), ['new-1', 'new-2', 'old', 'tail']);
    assert.equal(ui.nextPosition, 2, 'A changed snapshot must use its verified cursor');
  }
});

test('Even a complete refreshed mailbox retains downloaded rows and body records', async () => {
  const { ui, state } = fixture();
  state.nextPage = async () => page([mail('old', false)], null);
  await ui.loadPage(true);
  assert.deepEqual(ui.emails.map(value => value.id), ['old', 'tail']);
  assert.equal(ui.nextPosition, null);
  assert.equal(state.records.get('tail').mail.textBody, 'Cached body tail');
});

test('Companion-folder refresh preserves its previously loaded tail and pagination', async () => {
  const { ui, state, account } = fixture();
  ui.boxes.push({ id: 'sent', role: 'sent' });
  state.view.nextPosition = 100;
  state.nextPage = async () => page([mail('old', false)], 50, 'cached-head');
  await ui.refreshConversationFolder(ui.client, account, 'inbox', ui.generation);
  assert.equal(state.writes[0].mailbox, 'sent');
  assert.deepEqual(state.view.emails.map(value => value.id), ['old', 'tail']);
  assert.equal(state.view.nextPosition, 100);
});
