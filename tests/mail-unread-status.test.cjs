const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/mail/MailUnreadStatus.ets', 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const copy = value => JSON.parse(JSON.stringify(value));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const mail = (id, seen = false, mailboxIds = ['inbox']) => ({ id, keywords: seen ? ['$seen'] : [], mailboxIds });

function fixture() {
  const state = { accounts: ['a', 'b'], failed: false, read: null, reads: 0, changes: [], overlays: new Map(),
    views: new Map([['a:inbox', [mail('one')]], ['a:archive', []], ['a:sent', []],
      ['b:inbox', [mail('two', true)]], ['b:archive', []], ['b:sent', [mail('sent-only', false, ['sent'])]]]) };
  const boxes = [{ id: 'inbox', role: 'inbox', unreadEmails: 999 }, { id: 'archive', role: 'archive' }, { id: 'sent', role: 'sent' }];
  const store = { list: async () => state.accounts.map(id => ({ id })), mail: {
    boxes: async () => ({ boxes: copy(boxes) }),
    view: async (accountId, mailboxId, includeDirty) => {
      assert.equal(includeDirty, true); state.reads++;
      if (state.failed) throw new Error('Synthetic cache read failure');
      const result = { emails: copy(state.views.get(`${accountId}:${mailboxId}`) || []).filter(value => value.mailboxIds.includes(mailboxId)), nextPosition: 50 };
      return state.read ? state.read(accountId, mailboxId, result) : result;
    },
    cachedMessages: async () => { throw new Error('Retained bodies outside views must not be consulted'); }
  } };
  const load = () => {
    const module = { exports: {} };
    new Function('require', 'module', 'exports', 'AppStorage', compiled)(name => {
      assert.ok(name.endsWith('/MailOperations'));
      return { MailOperations: { pending: (accountId, id) => state.overlays.has(`${accountId}:${id}`),
        overlay: (accountId, value) => state.overlays.get(`${accountId}:${value.id}`) || value } };
    }, module, module.exports, { setOrCreate: (key, value) => state.changes.push({ key, value }) });
    return module.exports.MailUnreadStatus;
  };
  return { state, store, status: load(), load };
}

test('Dots derive from current cached membership, are account-scoped, and never treat partial counts as totals', async () => {
  const { state, store, status } = fixture();
  state.views.get('a:inbox').push(mail('archived-ghost', false, ['archive']));
  await status.refresh(store);
  assert.equal(status.hasUnread('a'), true); assert.equal(status.hasUnread('b'), false);
  assert.equal(status.hasUnread('b', 'sent'), true); assert.equal(status.anyInboxUnread(), true);
  state.views.set('a:inbox', [mail('one', true), mail('archived-ghost', false, ['archive'])]);
  await status.refresh(store);
  assert.equal(status.hasUnread('a', 'inbox'), false); assert.equal(status.anyInboxUnread(), false);
  assert.equal(typeof status.hasUnread('a'), 'boolean');
  assert.ok(state.reads > 0); assert.ok(state.changes.every(change => change.key === 'mailUnreadRevision'));
});

test('Pending read/unread and archive overlays update dots without waiting for server acknowledgement', async () => {
  const { state, store, status } = fixture(); await status.refresh(store);
  state.overlays.set('a:one', mail('one', true)); await status.refresh(store);
  assert.equal(status.hasUnread('a'), false);
  state.overlays.set('a:one', mail('one')); await status.refresh(store);
  assert.equal(status.hasUnread('a'), true);
  state.overlays.set('a:one', mail('one', false, ['archive'])); await status.refresh(store);
  assert.equal(status.hasUnread('a'), false); assert.equal(status.hasUnread('a', 'archive'), true);
  state.views.set('a:inbox', []); state.views.set('a:archive', [mail('one', false, ['archive'])]);
  state.overlays.clear(); await status.refresh(store);
  assert.equal(status.hasUnread('a'), false); assert.equal(status.hasUnread('a', 'archive'), true);
  state.overlays.set('a:one', mail('one', false, ['inbox'])); await status.refresh(store);
  assert.equal(status.hasUnread('a'), true); assert.equal(status.hasUnread('a', 'archive'), false);
});

test('Offline reopen rebuilds unread state from the persisted views and unchanged refreshes do not churn revisions', async () => {
  const { store, status, load } = fixture(); await status.refresh(store);
  const revision = status.revision(); await status.refresh(store); assert.equal(status.revision(), revision);
  const reopened = load(); assert.equal(reopened.anyInboxUnread(), false);
  await reopened.refresh(store); assert.equal(reopened.hasUnread('a'), true); assert.equal(reopened.hasUnread('b'), false);
});

test('An older delayed snapshot cannot restore unread after a newer cache refresh marked it read', async () => {
  const { state, store, status } = fixture(), entered = deferred(), release = deferred();
  let blocked = false;
  state.read = async (account, mailbox, value) => {
    if (!blocked && account === 'a' && mailbox === 'inbox') { blocked = true; entered.resolve(); await release.promise; }
    return value;
  };
  const old = status.refresh(store); await entered.promise;
  state.views.set('a:inbox', [mail('one', true)]); await status.refresh(store);
  assert.equal(status.anyInboxUnread(), false);
  release.resolve(); await old; assert.equal(status.anyInboxUnread(), false);
});

test('Removing an account clears its indicator while a transient local read failure preserves known dots', async () => {
  const { state, store, status } = fixture(); await status.refresh(store);
  state.failed = true; await status.refresh(store); assert.equal(status.hasUnread('a'), true);
  state.accounts = ['b']; await status.refresh(store);
  assert.equal(status.hasUnread('a'), false); assert.equal(status.anyInboxUnread(), false);
  state.failed = false; state.views.set('b:inbox', [mail('new-on-b')]); await status.refresh(store);
  assert.equal(status.hasUnread('b'), true);
});
