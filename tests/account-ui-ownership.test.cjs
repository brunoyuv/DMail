const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['saveAccount', 'removeAccount'].map(name => source.match(new RegExp(`  private async ${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const compiled = ts.transpileModule(`class Host { ${methods} }; return Host;`, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
function fixture() {
  const a = { id: 'a' }, b = { id: 'b' }, added = { id: 'new' };
  const state = { accounts: [a, b], added: [], removed: [], cancelled: [], scheduled: [], visible: [], opened: [],
    cleared: 0, unread: 0, discovery: 0, lists: 0, loaderCancels: 0, addGate: null, removeGate: null, listGate: null, noticeGate: null };
  const context = { marker: 'original context' };
  class SavedAccount { id = ''; }
  const Host = new Function('SavedAccount', 'NotificationPlatform', 'MailNotificationService', 'AutomaticMailWork', compiled)(SavedAccount,
    { cancel: async id => state.cancelled.push(id) },
    { settingsChanged: async value => state.scheduled.push(value), setVisibleAccount: id => state.visible.push(id) },
    { cancelInactive() {} });
  const store = {
    add: async (...args) => { state.added.push(args); if (state.addGate) await state.addGate.promise; state.accounts.push(added); return added; },
    list: async () => { state.lists++; if (state.listGate) await state.listGate.promise; return state.accounts.slice(); },
    notificationSettings: async id => { assert.equal(id, 'a'); if (state.noticeGate) await state.noticeGate.promise; return { notificationId: 37 }; },
    remove: async id => { state.removed.push(id); if (state.removeGate) await state.removeGate.promise; state.accounts = state.accounts.filter(account => account.id !== id); }
  };
  const host = Object.assign(new Host(), { active: true, generation: 1, busy: false, error: '', token: 'synthetic token',
    username: 'synthetic username', emailAddress: 'synthetic@example.test', candidates: ['candidate'], serverUrl: 'synthetic server',
    protocol: 'imap', accountStore: store, accounts: state.accounts.slice(), account: a, openInboxOnLaunch: true,
    client: { marker: 'a client' }, selected: { id: 'mail-a' }, selectedId: 'mail-a', bodyLoaded: true,
    messageLoader: { cancel: () => state.loaderCancels++ },
    boxes: ['inbox'], emails: ['mail-a'], mailboxId: 'inbox', boxName: 'Inbox', conversation: ['mail-a'],
    conversationIndex: ['mail-a'], conversationById: new Map(), conversationRevision: 0,
    paths: { clear: () => state.cleared++ },
    label: key => key, endpoint: () => 'imaps://synthetic.test:993', secret: () => 'synthetic secret', discoveredSmtp: () => undefined,
    clearDiscovery: () => state.discovery++, refreshUnreadStatus: () => state.unread++,
    getUIContext: () => { assert.equal(host.active, true); return { getHostContext: () => context }; }
  });
  host.openAccount = async (account, inbox) => { state.opened.push({ id: account.id, inbox }); host.account = account; host.generation++; host.busy = true; };
  const navigate = (active = true) => {
    host.generation++; host.active = active; host.busy = true; host.error = 'newer notice';
    host.token = 'newer token'; host.candidates = ['newer candidate']; host.accounts = [b]; host.account = b;
  };
  return { host, state, a, b, context, navigate };
}

test('A late account add remains saved without clearing a newer view or navigating after teardown', async () => {
  for (const active of [true, false]) {
    const f = fixture(); f.state.addGate = deferred();
    const saving = f.host.saveAccount({ id: 'server' }); await flush(); f.navigate(active);
    f.state.addGate.resolve(); await saving;
    assert.ok(f.state.accounts.some(account => account.id === 'new'));
    assert.equal(f.host.token, 'newer token'); assert.deepEqual(f.host.candidates, ['newer candidate']);
    assert.equal(f.host.error, 'newer notice'); assert.equal(f.host.busy, true);
    assert.deepEqual(f.state.opened, []); assert.equal(f.state.discovery, 0); assert.equal(f.state.lists, 0);
  }
});

test('Navigation during the post-add account read prevents applying its old form reset and account list', async () => {
  const f = fixture(); f.state.listGate = deferred(); const saving = f.host.saveAccount({ id: 'server' });
  await flush(); assert.equal(f.state.lists, 1); f.navigate(); f.state.listGate.resolve(); await saving;
  assert.deepEqual(f.host.accounts, [f.b]); assert.equal(f.host.token, 'newer token'); assert.equal(f.host.busy, true);
  assert.deepEqual(f.state.opened, []);
});

test('An add invoked by an already-busy probe can finish and leaves the new account load in control', async () => {
  const f = fixture(); f.host.busy = true; await f.host.saveAccount({ id: 'server' });
  assert.deepEqual(f.state.opened, [{ id: 'new', inbox: true }]);
  assert.equal(f.host.busy, true, 'Old save finalization cannot clear the new account load');
  assert.equal(f.host.token, ''); assert.equal(f.state.discovery, 1);
});

test('Requested removal and original notification cleanup survive navigation and disappearance', async () => {
  for (const active of [true, false]) {
    const f = fixture(); f.state.noticeGate = deferred(); const removing = f.host.removeAccount(f.a);
    await flush(); f.navigate(active); f.state.noticeGate.resolve(); await removing;
    assert.deepEqual(f.state.removed, ['a']); assert.deepEqual(f.state.cancelled, [37]);
    assert.deepEqual(f.state.scheduled, [f.context]); assert.deepEqual(f.host.accounts, [f.b]);
    assert.equal(f.host.error, 'newer notice'); assert.equal(f.host.busy, true);
    assert.equal(f.state.unread, 0); assert.deepEqual(f.state.opened, []); assert.equal(f.state.lists, 0);
  }
});

test('Removing the selected account opens a remaining saved account without resetting its new loading state', async () => {
  const f = fixture(); f.state.removeGate = deferred(); const removing = f.host.removeAccount(f.a); await flush();
  f.state.removeGate.resolve(); await removing;
  assert.deepEqual(f.state.opened, [{ id: 'b', inbox: true }]); assert.equal(f.host.account.id, 'b');
  assert.deepEqual(f.host.accounts, [f.b]); assert.equal(f.host.busy, true);
  assert.deepEqual(f.state.cancelled, [37]);
});

test('Removing the final account clears the live client, reader and navigation', async () => {
  const f = fixture(); f.state.accounts = [f.a]; await f.host.removeAccount(f.a);
  assert.deepEqual(f.host.accounts, []); assert.equal(f.host.account.id, ''); assert.equal(f.host.client, null);
  assert.equal(f.host.selected, null); assert.equal(f.host.bodyLoaded, false);
  assert.deepEqual(f.host.emails, []); assert.equal(f.host.mailboxId, ''); assert.equal(f.state.cleared, 1);
  assert.equal(f.host.busy, false); assert.deepEqual(f.state.visible, ['']);
  assert.equal(f.state.loaderCancels, 1);
});

test('A committed removal retires its live client even when the follow-up account read fails', async () => {
  for (const hasOther of [true, false]) {
    const f = fixture();
    if (!hasOther) { f.state.accounts = [f.a]; f.host.accounts = [f.a]; }
    f.host.accountStore.list = async () => { throw new Error('Synthetic read failure after deletion'); };
    await f.host.removeAccount(f.a);
    assert.deepEqual(f.state.removed, ['a']); assert.deepEqual(f.state.cancelled, [37]);
    assert.equal(f.host.account.id, hasOther ? 'b' : '');
    if (!hasOther) { assert.equal(f.host.client, null); assert.equal(f.host.selected, null); }
  }
});

test('Rejected old add or remove writes do not replace a newer error or spinner', async () => {
  for (const operation of ['add', 'remove']) {
    const f = fixture(), gate = deferred();
    if (operation === 'add') f.state.addGate = gate; else f.state.removeGate = gate;
    const work = operation === 'add' ? f.host.saveAccount({ id: 'server' }) : f.host.removeAccount(f.a);
    await flush(); f.navigate(); gate.reject(new Error('Synthetic rejected write')); await work;
    assert.equal(f.host.error, 'newer notice'); assert.equal(f.host.busy, true); assert.deepEqual(f.state.opened, []);
  }
});
