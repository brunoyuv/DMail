const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

async function fixture({ table = true, committedReads = false } = {}) {
  const directory = committedReads ? fs.mkdtempSync(path.join(os.tmpdir(), 'thunderbird-badge-synthetic-')) : null;
  const filename = directory ? path.join(directory, 'fixture.db') : ':memory:';
  const sqlite = new DatabaseSync(filename);
  if (committedReads) sqlite.exec('PRAGMA journal_mode=WAL');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready'); CREATE TABLE mail_notifications (account_id TEXT PRIMARY KEY, enabled INTEGER, revision INTEGER); INSERT INTO mail_notifications VALUES ('a',1,1), ('b',0,1)");
  const reader = committedReads ? new DatabaseSync(filename, { readOnly: true }) : sqlite;
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = reader.prepare(sql); statement.setReturnArrays(true);
      const values = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return values.length > 0; }, goToNextRow: () => ++index < values.length,
        getString: n => values[index][n], getLong: n => values[index][n], close() {} };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK')
  };
  const modules = new Map();
  function load(file) {
    if (modules.has(file)) return modules.get(file);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    const module = { exports: {} }; modules.set(file, module.exports);
    new Function('require', 'module', 'exports', code)(name => {
      if (name === '@kit.ArkData') return { relationalStore: {} };
      assert.ok(name.startsWith('.'));
      const base = path.resolve(path.dirname(file), name); return load(fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets');
    }, module, module.exports);
    return module.exports;
  }
  const { UnreadBadgeStore } = load(path.resolve('harmony/entry/src/main/ets/data/UnreadBadgeStore.ets'));
  const { MailCache } = load(path.resolve('harmony/entry/src/main/ets/data/MailCache.ets'));
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  await MailCache.initialize(db);
  if (table) await UnreadBadgeStore.initialize(db);
  const badges = new UnreadBadgeStore(db, queue, table), cache = new MailCache(db, queue, badges);
  return { sqlite, db, badges, cache, reopen: () => new UnreadBadgeStore(db, queue, table),
    record: async (count, account = 'a') => badges.record(account, await badges.beginCheck(account), count, 'inbox', Date.now()),
    row: account => sqlite.prepare('SELECT * FROM mail_unread_badges WHERE account_id = ?').get(account),
    close: () => { if (reader !== sqlite) reader.close(); sqlite.close(); if (directory) fs.rmSync(directory, { recursive: true }); } };
}
const mail = (id, seen = false, mailboxIds = ['inbox']) => ({ id, threadId: id, mailboxIds, keywords: seen ? ['$seen'] : [], messageIds: [],
  from: [], to: [], replyTo: [], subject: 'Synthetic badge fixture', preview: '', receivedAt: 0, hasAttachment: false,
  textBody: 'Saved synthetic body', htmlBody: null, bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false });
const box = (unreadEmails, countsKnown = true) => ({ id: 'inbox', name: 'Inbox', role: 'inbox', parentId: null, sortOrder: 0,
  totalEmails: 1000, unreadEmails, countsKnown, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true });

test('Badge totals use exact persisted counts from enabled ready accounts, including counts beyond fetched windows and offline reopen', async () => {
  const f = await fixture();
  try {
    await f.record(317); await f.record(999, 'b');
    assert.equal(await f.badges.total(), 317); assert.equal(await f.reopen().total(), 317);
    f.sqlite.exec("UPDATE mail_notifications SET enabled=1, revision=revision+1 WHERE account_id='b'");
    assert.equal(await f.badges.total(), null);
    await f.record(28, 'b'); assert.equal(await f.badges.total(), 345);
    f.sqlite.exec("UPDATE mail_notifications SET enabled=0, revision=revision+1 WHERE account_id='a'");
    assert.equal(await f.badges.total(), 28);
    f.sqlite.exec("UPDATE accounts SET status='deleting' WHERE id='b'");
    assert.equal(await f.badges.total(), 0);
  } finally { f.close(); }
});

test('Known clean Inbox metadata can seed once; partial windows and unknown metadata never fabricate counts', async () => {
  const f = await fixture();
  try {
    await f.cache.saveView('a', 'inbox', [mail('one')], 50); assert.equal(await f.badges.total(), null);
    await f.cache.saveBoxes('a', [box(1, false)]); assert.equal(await f.badges.total(), null);
    await f.cache.saveBoxes('a', [box(123)]); assert.equal(await f.badges.total(), 123);
    const timestamp = f.row('a').checked_at;
    await f.cache.saveBoxes('a', [box(98)]); assert.equal(await f.badges.total(), 123);
    assert.equal(f.row('a').checked_at, timestamp);
    await f.record(99); assert.equal(await f.badges.total(), 99);
  } finally { f.close(); }
});

test('Stale check responses cannot replace newer counts or re-enable disabled, changed, or removed accounts', async () => {
  const f = await fixture();
  try {
    await f.record(9);
    const old = await f.badges.beginCheck('a'), recent = await f.badges.beginCheck('a');
    await f.badges.record('a', recent, 11, 'inbox', Date.now());
    await f.badges.record('a', old, 7, 'inbox', Date.now()); assert.equal(await f.badges.total(), 11);
    await f.badges.record('a', recent, 13, 'inbox', Date.now()); assert.equal(await f.badges.total(), 11);
    const guard = await f.badges.beginCheck('a');
    f.sqlite.exec("UPDATE mail_notifications SET enabled=0, revision=revision+1 WHERE account_id='a'");
    assert.equal(await f.badges.total(), 0);
    f.sqlite.exec("UPDATE mail_notifications SET enabled=1, revision=revision+1 WHERE account_id='a'");
    await f.badges.record('a', guard, 88, 'inbox', Date.now()); assert.equal(await f.badges.total(), 11);
    const removed = await f.badges.beginCheck('a'); f.sqlite.exec("DELETE FROM accounts WHERE id='a'");
    await f.badges.record('a', removed, 77, 'inbox', Date.now()); assert.equal(await f.badges.total(), 0);
  } finally { f.close(); }
});

test('Pending overlays apply immediately and confirmed read/unread acknowledgement adjusts exactly once without changing body retention', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a', mail('one')); await f.record(4);
    const before = await f.cache.email('a', 'one', true);
    const overlay = (_account, value) => value.id === 'one' ? { ...value, keywords: ['$seen'] } : value;
    assert.equal(await f.badges.total(overlay, () => ['one']), 3);
    const guard = await f.badges.beginCheck('a');
    assert.equal(await f.cache.beginMutation('a', 'one'), true);
    assert.equal(await f.badges.beginCheck('a'), null);
    await f.badges.record('a', guard, 3, 'inbox', Date.now()); assert.equal(await f.badges.total(), 4);
    await f.cache.updateKeyword('a', 'one', '$seen', true, true);
    assert.equal(await f.badges.total(overlay, () => ['one']), 3); assert.equal(await f.badges.total(), 3);
    await f.cache.updateKeyword('a', 'one', '$seen', true, true); assert.equal(await f.badges.total(), 3);
    f.cache.endMutation('a', 'one');
    const after = await f.cache.email('a', 'one', true);
    assert.equal(after.mail.textBody, before.mail.textBody); assert.equal(after.bodySavedAt, before.bodySavedAt);
    await f.cache.beginMutation('a', 'one'); await f.cache.updateKeyword('a', 'one', '$seen', false, true); f.cache.endMutation('a', 'one');
    assert.equal(await f.badges.total(), 4);
  } finally { f.close(); }
});

test('Archive and undo update Inbox contribution while a vanished cached header never double-subtracts from a server total', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a', mail('one')); await f.cache.saveEmail('a', mail('seen', true)); await f.record(20);
    await f.cache.beginMutation('a', 'one');
    assert.equal(await f.badges.total((_id, value) => value.id === 'one' ? { ...value, mailboxIds: ['archive'] } : value, () => ['one']), 19);
    await f.cache.updateMailboxes('a', 'one', ['archive']); f.cache.endMutation('a', 'one');
    assert.equal(await f.badges.total(), 19);
    await f.cache.updateMailboxes('a', 'one', ['archive']); assert.equal(await f.badges.total(), 19);
    await f.cache.updateMailboxes('a', 'one', ['inbox', 'label']); assert.equal(await f.badges.total(), 20);
    await f.cache.forgetEmail('a', 'seen'); assert.equal(await f.badges.total(), 20);
    await f.cache.forgetEmail('a', 'one'); assert.equal(await f.badges.total(), 20);
    await f.cache.forgetEmail('a', 'one'); assert.equal(await f.badges.total(), 20);
  } finally { f.close(); }
});

test('Failed uncertain mutations block count recording through reopen until flags are refreshed; refused mutations retain the old total', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a', mail('one')); await f.record(6);
    await f.cache.beginMutation('a', 'one'); f.cache.endMutation('a', 'one');
    assert.equal(await f.reopen().beginCheck('a'), null); assert.equal(await f.reopen().total(), 6);
    await f.cache.saveEmail('a', mail('one', true)); await f.record(5); assert.equal(await f.badges.total(), 5);
    await f.cache.beginMutation('a', 'one'); await f.cache.updateKeyword('a', 'one', '$seen', true); f.cache.endMutation('a', 'one');
    assert.equal(await f.badges.total(), 5);
  } finally { f.close(); }
});

test('First local operation seeds trusted old metadata before changing flags, while unknown counts stay unknown', async () => {
  const f = await fixture();
  try {
    await f.cache.saveBoxes('a', [box(15)]); await f.cache.saveEmail('a', mail('one'));
    await f.cache.beginMutation('a', 'one'); await f.cache.updateKeyword('a', 'one', '$seen', true, true); f.cache.endMutation('a', 'one');
    assert.equal(await f.badges.total(), 14);
    f.sqlite.exec("DELETE FROM mail_unread_badges; DELETE FROM mail_cache WHERE kind='boxes'");
    await f.cache.beginMutation('a', 'one'); await f.cache.updateKeyword('a', 'one', '$seen', false, true); f.cache.endMutation('a', 'one');
    assert.equal(await f.badges.total(), null);
  } finally { f.close(); }
});

test('Background use before first upgraded foreground launch skips badges without migrations or errors', async () => {
  const f = await fixture({ table: false });
  try {
    assert.equal(await f.badges.beginCheck('a'), null); await f.badges.record('a', null, 7, 'inbox', Date.now());
    assert.equal(await f.badges.total(), null);
    assert.equal(f.sqlite.prepare("SELECT name FROM sqlite_master WHERE name='mail_unread_badges'").get(), undefined);
  } finally { f.close(); }
});


test('A separate committed reader connection records valid guards and exact counts through reopen', async () => {
  const f = await fixture({ committedReads: true });
  try {
    // Native RDB can execute querySql on a reader connection. Such a read does
    // not observe a writer's uncommitted revision increment, unlike :memory:.
    const guard = await f.badges.beginCheck('a');
    assert.deepEqual(guard, { revision: 1, settingsRevision: 1 });
    await f.badges.record('a', guard, 137, 'inbox', Date.now());
    assert.equal(await f.badges.total(), 137);
    f.sqlite.exec("UPDATE mail_notifications SET enabled=1, revision=revision+1 WHERE account_id='b'");
    await f.record(8, 'b'); assert.equal(await f.reopen().total(), 145);
    await f.cache.saveEmail('a', mail('one'));
    await f.cache.beginMutation('a', 'one');
    await f.cache.updateKeyword('a', 'one', '$seen', true, true); f.cache.endMutation('a', 'one');
    assert.equal(await f.reopen().total(), 144);
    f.sqlite.exec("UPDATE mail_notifications SET enabled=0, revision=revision+1 WHERE account_id='a'");
    assert.equal(await f.reopen().total(), 8);
  } finally { f.close(); }
});
