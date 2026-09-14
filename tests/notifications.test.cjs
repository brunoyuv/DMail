const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { DatabaseSync } = require('node:sqlite');
const model = require('../.tools/test-output/mail/notifications/NotificationModel');
const { runNotificationChecks, deliverPending } = require('../.tools/test-output/mail/notifications/NotificationEngine');
const { NotificationAccountState, checkIsDue, scheduledMinutes, compareJmapInbox } = model;
const compiled = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/data/NotificationStore.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const storeModule = { exports: {} };
new Function('require', 'module', 'exports', compiled)(() => model, storeModule, storeModule.exports);
const { NotificationStore } = storeModule.exports;
function database(sqlite) {
  return { executeSql: async (sql, args = []) => sqlite.prepare(sql).run(...args),
    querySql: async (sql, args = []) => {
      const statement = sqlite.prepare(sql), columns = statement.columns().map(value => value.name);
      statement.setReturnArrays(true); const values = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return values.length > 0; },
        goToNextRow: () => ++index < values.length, getColumnIndex: name => columns.indexOf(name),
        getString: col => values[index][col], getLong: col => Number(values[index][col]), close() {} };
    }, beginTransaction: () => sqlite.exec('BEGIN IMMEDIATE'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK') };
}
async function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT); INSERT INTO accounts VALUES ('a','ready'),('b','ready')");
  const adapter = database(db); await NotificationStore.initialize(adapter);
  const makeStore = () => { let pending = Promise.resolve(); return new NotificationStore(adapter, action => {
    const work = pending.catch(() => {}).then(action); pending = work.catch(() => {}); return work;
  }); };
  const store = makeStore();
  return { db, store, makeStore };
}
const check = (state, count = 0) => ({ state, mailboxId: 'inbox', newMessages: count });

test('Intervals respect platform minimum and apply bounded error backoff without affecting disabled accounts', () => {
  const value = new NotificationAccountState();
  assert.equal(checkIsDue(value, false, 1000000), false);
  value.enabled = true; value.lastAttempt = 1000;
  assert.equal(checkIsDue(value, false, 301000), true);
  assert.equal(checkIsDue(value, true, 301000), false);
  value.failures = 1; assert.equal(checkIsDue(value, false, 301000), false);
  assert.equal(checkIsDue(value, false, 601000), true);
  assert.equal(scheduledMinutes([value]), 120);
  value.enabled = false; assert.equal(scheduledMinutes([value]), null);
});

test('JMAP baseline, repeated unread toggles, retained IDs and Inbox identity changes stay silent', () => {
  const mail = (id, receivedAt, unread = true) => ({ id, receivedAt, unread });
  const first = compareJmapInbox('', 'inbox', [mail('one', 2), mail('two', 1, false)]);
  assert.equal(first.newMessages, 0);
  const next = compareJmapInbox(first.state, 'inbox', [mail('new', 3), mail('one', 2)]);
  assert.equal(next.newMessages, 1);
  assert.equal(compareJmapInbox(next.state, 'inbox', [mail('never-seen-old', 1)]).newMessages, 0);
  assert.equal(compareJmapInbox(next.state, 'inbox', [mail('two', 1), mail('one', 2)]).newMessages, 0);
  assert.equal(compareJmapInbox(next.state, 'replacement', [mail('new', 3), mail('one', 2)]).newMessages, 0);
});

test('Persistent account preferences, silent baseline, interval edits and notification acknowledgement preserve identity', async () => {
  const { db, store, makeStore } = await fixture();
  try {
    assert.equal((await store.get('a')).enabled, false);
    await store.configure('a', true); const initial = await store.get('a');
    await store.complete('a', initial.revision, check('first', 9), 1000);
    assert.equal((await store.get('a')).noticeVersion, 0);
    await store.complete('a', initial.revision, check('second', 2), 2000);
    await store.frequencies('a', 15, 240);
    const persisted = await makeStore().get('a');
    assert.equal(persisted.cursor, 'second'); assert.equal(persisted.notificationId, initial.notificationId);
    assert.equal(persisted.noticeVersion, 1); assert.equal(persisted.foregroundMinutes, 15);
    await store.acknowledge('a', 1); assert.equal((await store.get('a')).acknowledgedVersion, 1);
    assert.equal((await store.get('b')).enabled, false);
    await assert.rejects(store.frequencies('a', 1, 20));
  } finally { db.close(); }
});

test('Late results after disable, frequency edits or account removal cannot restore state or alerts', async () => {
  const { db, store } = await fixture();
  try {
    await store.configure('a', true); const initial = await store.get('a');
    await store.frequencies('a', 30, 120);
    assert.equal(await store.complete('a', initial.revision, check('late', 1), 1000), false);
    const current = await store.get('a'); await store.configure('a', false);
    assert.equal(await store.complete('a', current.revision, check('late', 1), 1000), false);
    await store.configure('a', true); const restored = await store.get('a');
    db.exec("DELETE FROM accounts WHERE id = 'a'");
    assert.equal(await store.complete('a', restored.revision, check('late', 1), 1000), false);
    assert.equal((await store.get('a')).enabled, false);
  } finally { db.close(); }
});

test('Separate process stores share an expiring lease and cannot release another owner', async () => {
  const { db, store, makeStore } = await fixture();
  try {
    const other = makeStore();
    assert.equal(await store.acquire('one', 1000), true);
    assert.equal(await other.acquire('two', 1100), false);
    await other.release('two'); assert.equal(await other.acquire('two', 1200), false);
    assert.equal(await other.acquire('two', 151000), true);
    await store.release('one'); assert.equal(await store.acquire('one', 151001), false);
  } finally { db.close(); }
});

function environment(store) {
  let now = 1000000;
  const events = [];
  return { events, now: () => now, advance: () => now += 300000, cancelled: () => false, permitted: async () => true,
    check: async value => { events.push(`check:${value.accountId}`); return check(`${now}`, 1); },
    publish: async value => { events.push(`publish:${value.accountId}`); }, cancel: async id => events.push(`cancel:${id}`) };
}
test('Engine runs a silent baseline, deduplicates repeat checks and delivers only newly observed messages', async () => {
  const { db, store } = await fixture(); const env = environment(store);
  try {
    await store.configure('a', true);
    assert.equal(await runNotificationChecks(store, env, 'first', false), true);
    assert.deepEqual(env.events, ['check:a']);
    await runNotificationChecks(store, env, 'second', false);
    assert.deepEqual(env.events, ['check:a']);
    env.advance(); await runNotificationChecks(store, env, 'third', false);
    assert.deepEqual(env.events, ['check:a', 'check:a', 'publish:a']);
    assert.equal((await store.get('a')).noticeVersion, (await store.get('a')).acknowledgedVersion);
  } finally { db.close(); }
});
test('Permission refusal and an occupied lease issue no mailbox requests; an IDLE event can be retained for retry', async () => {
  const { db, store } = await fixture(); const env = environment(store);
  try {
    await store.configure('a', true); env.permitted = async () => false;
    assert.equal(await runNotificationChecks(store, env, 'denied', false, 'a'), false);
    env.permitted = async () => true; await store.acquire('other', env.now());
    assert.equal(await runNotificationChecks(store, env, 'busy', false, 'a'), false);
    assert.deepEqual(env.events, []);
    await store.release('other'); assert.equal(await runNotificationChecks(store, env, 'retry', false, 'a'), true);
    assert.deepEqual(env.events, ['check:a']);
  } finally { db.close(); }
});
test('IDLE suppresses interval requests, explicit server events check only that account, and failures back off', async () => {
  const { db, store } = await fixture(); const env = environment(store);
  try {
    await store.configure('a', true); await store.configure('b', true);
    await runNotificationChecks(store, env, 'quiet', false, '', ['a', 'b']); assert.deepEqual(env.events, []);
    await runNotificationChecks(store, env, 'arrival', false, 'a', ['a', 'b']); assert.deepEqual(env.events, ['check:a']);
    env.check = async () => { env.events.push('fail'); throw new Error('synthetic failure'); };
    assert.equal(await runNotificationChecks(store, env, 'fail', false, 'a', ['a']), false);
    assert.equal(await runNotificationChecks(store, env, 'backoff', false, 'a', ['a']), false);
    assert.deepEqual(env.events, ['check:a', 'fail']);
  } finally { db.close(); }
});
test('A failed platform publication remains pending and disable during publish removes the resulting notification', async () => {
  const { db, store } = await fixture(); const env = environment(store);
  try {
    await store.configure('a', true); const value = await store.get('a');
    await store.complete('a', value.revision, check('baseline'), 1000);
    await store.complete('a', value.revision, check('new', 1), 2000);
    env.publish = async () => { throw new Error('publish failed'); };
    await assert.rejects(deliverPending(store, env, 'a'));
    assert.equal((await store.get('a')).acknowledgedVersion, 0);
    env.publish = async () => { await store.configure('a', false); };
    await deliverPending(store, env, 'a');
    assert.deepEqual(env.events, [`cancel:${value.notificationId}`]);
  } finally { db.close(); }
});

test('Disable then reenable during publication cancels a notification from the previous opt-in revision', async () => {
  const { db, store } = await fixture(); const env = environment(store);
  try {
    await store.configure('a', true); const value = await store.get('a');
    await store.complete('a', value.revision, check('baseline'), 1000);
    await store.complete('a', value.revision, check('new', 1), 2000);
    env.publish = async () => { await store.configure('a', false); await store.configure('a', true); };
    await deliverPending(store, env, 'a');
    assert.deepEqual(env.events, [`cancel:${value.notificationId}`]);
    assert.equal((await store.get('a')).cursor, '');
  } finally { db.close(); }
});

test('Disable or account removal during acknowledgement cannot restore the banner or badge', async () => {
  for (const removed of [false, true]) {
    const { db, store } = await fixture(); const env = environment(store);
    try {
      await store.configure('a', true); const value = await store.get('a');
      await store.complete('a', value.revision, check('baseline'), 1000);
      await store.complete('a', value.revision, check('new', 1), 2000);
      const acknowledge = store.acknowledge.bind(store);
      store.acknowledge = async (id, version) => {
        await acknowledge(id, version);
        if (removed) db.exec("DELETE FROM accounts WHERE id = 'a'");
        else await store.configure('a', false);
      };
      env.published = () => env.events.push('banner-or-badge');
      await deliverPending(store, env, 'a');
      assert.deepEqual(env.events, ['publish:a', `cancel:${value.notificationId}`]);
    } finally { db.close(); }
  }
});

test('Revoked notification permission is checked again before a queued account reaches its server', async () => {
  const { db, store } = await fixture(); const env = environment(store); let calls = 0;
  try {
    await store.configure('a', true);
    env.permitted = async () => ++calls === 1;
    await runNotificationChecks(store, env, 'permission-race', false);
    assert.deepEqual(env.events, []);
  } finally { db.close(); }
});
