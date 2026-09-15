const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const retention = 7 * 24 * 60 * 60 * 1000;
const compile = file => ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const modelModule = { exports: {} };
new Function('module', 'exports', compile('harmony/entry/src/main/ets/data/MailSyncModel.ts'))(modelModule, modelModule.exports);
const storeModule = { exports: {} };
new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/MailSyncStore.ets'))(name => {
  if (name === './MailSyncModel') return modelModule.exports;
  if (name === './MailSyncRecovery') return { recoverFailedEmptyBodies: async () => {} };
  if (name === './MailCacheModel') return { MAIL_RETENTION_MS: retention };
  throw new Error(`Unexpected dependency ${name}`);
}, storeModule, storeModule.exports);
const { MailSyncStore } = storeModule.exports;
const mail = id => ({ id, threadId: 'thread-' + id, messageIds: [`<${id}@example.test>`], mailboxIds: ['inbox'],
  keywords: ['$seen'], from: [{ email: 'synthetic@example.test', name: 'Synthetic' }], to: [], replyTo: [],
  subject: 'Subject 文', preview: 'Preview', receivedAt: 1, hasAttachment: false, hasHtmlBody: true,
  htmlBody: '<html>Large body must not be stored here</html>', textBody: 'Body', bodyTruncated: false, bodyEncodingProblem: false });
const page = (ids, position = 0, nextPosition = null, queryState = 'state') => ({ accountId: 'server-a', queryState,
  emailState: null, position, nextPosition, total: null, emails: ids.map(mail), notFound: [] });

async function fixture({ committedReads = false, initialize = true } = {}) {
  const directory = committedReads ? fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-mail-sync-')) : null;
  const sqlite = new DatabaseSync(directory ? path.join(directory, 'synthetic.db') : ':memory:');
  if (committedReads) sqlite.exec('PRAGMA journal_mode=WAL');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT); INSERT INTO accounts VALUES ('a','ready'),('b','ready'),('pending','pending')");
  sqlite.exec('CREATE TABLE mail_cache (account_id TEXT, kind TEXT, cache_key TEXT, payload TEXT, PRIMARY KEY (account_id,kind,cache_key))');
  const reader = committedReads ? new DatabaseSync(path.join(directory, 'synthetic.db'), { readOnly: true }) : sqlite;
  let writes = 0, readsInTransaction = 0, transaction = false, closed = 0;
  const db = { version: 5,
    executeSql: async (sql, args = []) => { writes++; sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      if (transaction) readsInTransaction++;
      const statement = reader.prepare(sql); statement.setReturnArrays(true); const rows = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return rows.length > 0; }, goToNextRow: () => ++index < rows.length,
        getString: column => rows[index][column], getLong: column => rows[index][column], close() {} };
    },
    beginTransaction: () => { sqlite.exec('BEGIN IMMEDIATE'); transaction = true; },
    commit: () => { sqlite.exec('COMMIT'); transaction = false; },
    rollBack: () => { sqlite.exec('ROLLBACK'); transaction = false; },
    close: () => { closed++; }
  };
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  if (initialize) await MailSyncStore.initialize(db);
  return { sqlite, reader, db, queue, store: new MailSyncStore(db, queue), reopen: () => new MailSyncStore(db, queue),
    writes: () => writes, readsInTransaction: () => readsInTransaction, closed: () => closed,
    close: () => { if (reader !== sqlite) reader.close(); sqlite.close(); if (directory) fs.rmSync(directory, { recursive: true }); } };
}

test('Durable queue retains every one of 731 messages across restart, without copying body or address content', async () => {
  const f = await fixture({ committedReads: true });
  try {
    await f.store.enqueue('a', Array.from({ length: 731 }, (_, i) => mail(`id-${String(i).padStart(4, '0')}`)));
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 731);
    const reopened = f.reopen(), completed = new Set();
    for (;;) {
      const next = await reopened.next(['a'], 'body', 100); if (!next.length) break;
      for (const job of next) {
        completed.add(job.email.id); assert.equal(job.email.htmlBody, null); assert.equal(job.email.textBody, null);
        assert.deepEqual(job.email.from, []); assert.equal(job.email.subject, '');
        assert.deepEqual(job.email.messageIds, [`<${job.email.id}@example.test>`]);
        await reopened.markPictures('a', job.email.id, Date.now(), 'canonical-' + job.email.id);
      }
    }
    assert.equal(completed.size, 731);
    assert.equal((await reopened.next(['a'], 'pictures', 100)).length, 100);
    assert.equal(f.readsInTransaction(), 0);
  } finally { f.close(); }
});

test('Body/picture phase and retry state persist independently per protocol ID and account', async () => {
  const f = await fixture();
  try {
    const duplicateMessageId = mail('id-2'); duplicateMessageId.messageIds = mail('id-1').messageIds;
    await f.store.enqueue('a', [mail('id-1'), duplicateMessageId]); await f.store.enqueue('b', [mail('id-1')]);
    const now = Date.now(); await f.store.markPictures('a', 'id-1', now - 123, 'canonical');
    await f.store.defer('a', 'id-2', now + 60000);
    await f.reopen().enqueue('a', [mail('id-1'), mail('id-2')]);
    assert.equal((await f.store.next(['a'], 'body')).length, 0);
    assert.equal((await f.store.next(['b'], 'body'))[0].email.id, 'id-1');
    const picture = (await f.reopen().next(['a'], 'pictures'))[0];
    assert.equal(picture.messageKey, 'canonical'); assert.equal(picture.bodySavedAt, now - 123);
    const retry = f.sqlite.prepare("SELECT attempts, retry_at, stage FROM mail_sync_jobs WHERE account_id='a' AND email_id='id-2'").get();
    assert.equal(retry.attempts, 1); assert.equal(retry.retry_at, now + 60000); assert.equal(retry.stage, 'body');
    await f.store.complete('a', 'id-2'); // Cannot acknowledge an unfinished body.
    assert.equal(f.sqlite.prepare("SELECT stage FROM mail_sync_jobs WHERE account_id='a' AND email_id='id-2'").get().stage, 'body');
  } finally { f.close(); }
});

test('A separate WAL reader finds persisted retries including deadlines that passed between selection and scheduling', async () => {
  const f = await fixture({ committedReads: true }); const originalNow = Date.now;
  let clock = originalNow(); const start = clock; Date.now = () => clock;
  try {
    await f.store.enqueue('a', [mail('body'), mail('pictures')]);
    await f.store.markPictures('a', 'pictures', clock, 'picture-document');
    await f.store.defer('a', 'body', start + 30000);
    await f.store.defer('a', 'pictures', start + 20000);
    const cursor = await f.store.seedPage('a', 'inbox', page([], 0, 1));
    await f.store.deferCursor(cursor, start + 10000);
    await f.store.enqueue('b', [mail('other-account')]);
    await f.store.defer('b', 'other-account', start + 5000);
    const resumed = f.reopen(), writes = f.writes();
    assert.equal(await resumed.nextRetryAt(['a']), start + 10000);
    assert.equal(await resumed.nextRetryAt(['a', 'b']), start + 5000);
    clock = start + 10000;
    assert.equal(await resumed.nextRetryAt(['a']), start + 10000);
    assert.equal(await resumed.advance(cursor, page([], 1, null)), true);
    assert.equal(await resumed.nextRetryAt(['a']), start + 20000);
    clock = start + 20000;
    assert.equal(await resumed.nextRetryAt(['a']), start + 20000);
    await resumed.complete('a', 'pictures');
    assert.equal(await resumed.nextRetryAt(['a']), start + 30000);
    clock = start + 30000;
    assert.equal(await resumed.nextRetryAt(['a']), start + 30000);
    assert.equal((await resumed.next(['a'], 'body'))[0].email.id, 'body');
    assert.equal(f.writes(), writes + 2);
    assert.equal(f.readsInTransaction(), 0);
  } finally { Date.now = originalNow; f.close(); }
});

test('Retry deadlines exclude completed work, completed pages, deleted accounts, and unavailable accounts', async () => {
  const f = await fixture(); const now = Date.now();
  try {
    await f.store.enqueue('a', [mail('done')]);
    await f.store.markPictures('a', 'done', now, 'done-document'); await f.store.complete('a', 'done');
    await f.store.seedPage('a', 'finished', page([], 0, null));
    // Even stale positive deadline fields cannot resurrect terminal records.
    f.sqlite.prepare('UPDATE mail_sync_jobs SET retry_at = ?').run(now + 10000);
    f.sqlite.prepare('UPDATE mail_sync_cursors SET retry_at = ?').run(now + 10000);
    assert.equal(await f.store.nextRetryAt(['a']), null);
    await f.store.enqueue('b', [mail('pending')]);
    await f.store.defer('b', 'pending', now + 20000);
    const unfinished = await f.store.seedPage('b', 'inbox', page([], 0, 1));
    await f.store.deferCursor(unfinished, now + 30000);
    assert.equal(await f.store.nextRetryAt(['a', 'b']), now + 20000);
    f.sqlite.exec("UPDATE accounts SET status='deleting' WHERE id='b'");
    assert.equal(await f.store.nextRetryAt(['a', 'b']), null);
    f.sqlite.exec("DELETE FROM accounts WHERE id='b'");
    assert.equal(await f.store.nextRetryAt(['b']), null);
    assert.equal(await f.store.nextRetryAt([]), null);
    assert.equal(await f.store.nextRetryAt(['pending']), null);
    await assert.rejects(f.store.nextRetryAt(['']), /Invalid/);
  } finally { f.close(); }
});

test('A retry query freezes account selection and cannot lose a deadline that passes while queued', async () => {
  const f = await fixture(); const originalNow = Date.now(); let clock = originalNow; const realNow = Date.now;
  Date.now = () => clock;
  try {
    await f.store.enqueue('a', [mail('one')]); await f.store.defer('a', 'one', clock + 10000);
    let release; const hold = f.queue(() => new Promise(resolve => { release = resolve; }));
    await new Promise(resolve => setImmediate(resolve));
    const accounts = ['a']; const lookup = f.store.nextRetryAt(accounts); accounts[0] = 'b';
    release(); await hold;
    assert.equal(await lookup, clock + 10000);
    const second = f.queue(() => new Promise(resolve => { release = resolve; }));
    await new Promise(resolve => setImmediate(resolve));
    const expired = f.store.nextRetryAt(['a']); clock += 10000; release(); await second;
    assert.equal(await expired, clock);
  } finally { Date.now = realNow; f.close(); }
});

test('Done checkpoints suppress repeated work and expire from body download time, never later picture completion', async () => {
  const f = await fixture(); const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    await f.store.enqueue('a', [mail('one')]); const bodyTime = clock;
    f.sqlite.prepare("INSERT INTO mail_cache VALUES ('a','email','one',?)").run(JSON.stringify({ version: 1, savedAt: bodyTime, bodySavedAt: bodyTime, mail: mail('one') }));
    await f.store.markPictures('a', 'one', bodyTime, 'canonical'); clock += 60000;
    await f.store.complete('a', 'one'); await f.reopen().enqueue('a', [mail('one')]);
    assert.equal((await f.store.next(['a'], 'body')).length, 0); assert.equal((await f.store.next(['a'], 'pictures')).length, 0);
    clock = bodyTime + retention;
    await f.reopen().enqueue('a', [mail('one')]);
    const pending = (await f.store.next(['a'], 'body'))[0]; assert.equal(pending.email.id, 'one');
    assert.equal(pending.bodySavedAt, 0); assert.equal(pending.messageKey, '');
  } finally { Date.now = originalNow; f.close(); }
});

test('DONE reconciliation inspects only canonical envelope metadata and remains scoped to the exact account and protocol ID', async () => {
  const f = await fixture({ committedReads: true }); const now = Date.now();
  try {
    const values = {
      ready: JSON.stringify({ version: 1, savedAt: now, bodySavedAt: now, mail: { bodySavedAt: null, textBody: 'x'.repeat(2 * 1024 * 1024) } }),
      empty: JSON.stringify({ version: 1, savedAt: now, bodySavedAt: now, mail: { textBody: '' } }),
      partial: JSON.stringify({ version: 1, savedAt: now, bodySavedAt: now, mail: { textBody: 'Readable', bodyEncodingProblem: true } }),
      pending: JSON.stringify({ version: 1, savedAt: now, bodySavedAt: null, mail: { textBody: null } }),
      unknown: JSON.stringify({ version: 2, savedAt: now, bodySavedAt: null, mail: { textBody: null } }),
      reordered: JSON.stringify({ mail: { textBody: null }, version: 1, savedAt: now, bodySavedAt: null }),
      bounded: JSON.stringify({ version: 1, savedAt: now, padding: 'x'.repeat(192), bodySavedAt: null, mail: { textBody: null } })
    };
    const ids = [...Object.keys(values), 'absent', 'other-account', 'other-kind'];
    await f.store.enqueue('a', ids.map(mail));
    for (const id of ids) { await f.store.markPictures('a', id, now, 'shared'); await f.store.complete('a', id); }
    for (const [id, payload] of Object.entries(values)) f.sqlite.prepare("INSERT INTO mail_cache VALUES('a','email',?,?)").run(id, payload);
    f.sqlite.prepare("INSERT INTO mail_cache VALUES('b','email','other-account',?)").run(values.ready);
    f.sqlite.prepare("INSERT INTO mail_cache VALUES('a','view','other-kind',?)").run(values.ready);
    // No JSON engine or large result transfer is needed by this metadata check.
    for (const name of ['json_valid', 'json_extract', 'json_type']) f.sqlite.function(name, { varargs: true }, () => assert.fail('Unexpected JSON scan'));
    const originalQuery = f.db.querySql;
    f.db.querySql = async () => assert.fail('Registration must not transfer saved body payloads');
    await f.reopen().enqueue('a', ids.map(mail)); f.db.querySql = originalQuery;
    assert.deepEqual((await f.store.next(['a'], 'body', 100)).map(job => job.email.id).sort(), ['absent', 'other-account', 'other-kind', 'pending']);
    for (const [id, payload] of Object.entries(values)) assert.equal(f.reader.prepare("SELECT payload FROM mail_cache WHERE account_id='a' AND cache_key=?").get(id).payload, payload);
    assert.equal(f.readsInTransaction(), 0);
  } finally { f.close(); }
});

test('Incomplete picture phase can return to body recovery without resurrecting completed or removed work', async () => {
  const f = await fixture();
  try {
    await f.store.enqueue('a', [mail('recover'), mail('done')]);
    await f.store.markPictures('a', 'recover', Date.now(), 'canonical-recover');
    await f.store.markPictures('a', 'done', Date.now(), 'canonical-done'); await f.store.complete('a', 'done');
    await f.store.requeueBody('a', 'recover'); await f.store.requeueBody('a', 'done'); await f.store.requeueBody('a', 'absent');
    const jobs = await f.reopen().next(['a'], 'body', 10); assert.equal(jobs.length, 1); assert.equal(jobs[0].email.id, 'recover');
    assert.equal(jobs[0].messageKey, ''); assert.equal(jobs[0].bodySavedAt, 0); assert.equal(jobs[0].retryAt, 0);
    assert.equal((await f.store.next(['a'], 'pictures')).length, 0);
  } finally { f.close(); }
});

test('First-page seed saves jobs and cursor atomically; completed same-head traversal is not restarted', async () => {
  const f = await fixture({ committedReads: true });
  try {
    const first = page(['one', 'two'], 0, 2); const cursor = await f.store.seedPage('a', 'inbox', first);
    assert.equal(cursor.position, 2); assert.equal(cursor.revision, 1);
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 2);
    assert.equal(await f.store.advance(cursor, page(['three'], 2, null)), true);
    assert.equal(await f.reopen().nextCursor(['a']), null);
    const repeated = await f.reopen().seedPage('a', 'inbox', first);
    assert.equal(repeated.position, null); assert.equal(repeated.revision, 2);
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 3);
    assert.equal(f.readsInTransaction(), 0);
  } finally { f.close(); }
});

test('A stale page cannot enqueue jobs, rewind a newer cursor, or apply old backoff', async () => {
  const f = await fixture({ committedReads: true });
  try {
    const stale = await f.store.seedPage('a', 'inbox', page(['one'], 0, 1));
    const current = await f.reopen().seedPage('a', 'inbox', page(['new'], 0, 1, 'new-state'));
    assert.equal(current.revision, stale.revision + 1);
    assert.equal(await f.store.advance(stale, page(['stale-body'], 1, null)), false);
    await f.store.deferCursor(stale, Date.now() + 60000);
    const persisted = await f.store.nextCursor(['a']); assert.deepEqual(persisted, current);
    assert.equal(f.reader.prepare("SELECT count(*) AS n FROM mail_sync_jobs WHERE email_id='stale-body'").get().n, 0);
    assert.equal(await f.reopen().advance(current, page(['valid'], 1, null, 'new-state')), true);
  } finally { f.close(); }
});

test('Cursor continuation rolls back all page jobs when checkpoint commit fails', async () => {
  const f = await fixture({ committedReads: true });
  try {
    const cursor = await f.store.seedPage('a', 'inbox', page(['one'], 0, 1));
    f.sqlite.exec("CREATE TRIGGER reject_advance BEFORE UPDATE ON mail_sync_cursors BEGIN SELECT RAISE(ABORT, 'Synthetic failed update'); END");
    await assert.rejects(f.store.advance(cursor, page(['two', 'three'], 1, null)), /could not be saved/);
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 1);
    assert.deepEqual(await f.reopen().nextCursor(['a']), cursor);
  } finally { f.close(); }
});

test('Failed first-page enqueue rolls back its entire page and does not advance progress', async () => {
  const f = await fixture();
  try {
    f.sqlite.exec("CREATE TRIGGER reject_job BEFORE INSERT ON mail_sync_jobs WHEN NEW.email_id='bad' BEGIN SELECT RAISE(ABORT, 'Synthetic failed write'); END");
    await assert.rejects(f.store.seedPage('a', 'inbox', page(['good', 'bad'], 0, 2)), /could not be saved/);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 0);
    assert.equal(await f.store.nextCursor(['a']), null);
  } finally { f.close(); }
});

test('Cached merged views seed missing cursors and jobs without replacing live durable progress', async () => {
  const f = await fixture();
  try {
    const cached = { savedAt: Date.now(), emails: ['one','two','three'].map(mail), nextPosition: 3, queryState: 'state' };
    const initial = await f.store.seedCached('a', 'inbox', cached); assert.equal(initial.position, 3);
    await f.store.advance(initial, page(['four'], 3, 4));
    const progressed = await f.store.nextCursor(['a']);
    assert.deepEqual(await f.reopen().seedCached('a', 'inbox', cached), progressed);
    const untrusted = await f.store.seedCached('b', 'inbox', { savedAt: Date.now(), emails: [mail('one')], nextPosition: 50 });
    assert.equal(untrusted.position, 0); assert.equal(untrusted.queryState, '');
  } finally { f.close(); }
});

test('Seven-day mailbox checkpoint expiration resumes full traversal, with persisted cursor backoff', async () => {
  const f = await fixture(); const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    const first = page(['one'], 0, 1); const cursor = await f.store.seedPage('a', 'inbox', first);
    await f.store.deferCursor(cursor, clock + 30000); assert.equal(await f.reopen().nextCursor(['a']), null);
    clock += 30000; const retry = await f.reopen().nextCursor(['a']); assert.equal(retry.attempts, 1);
    await f.store.advance(retry, page(['two'], 1, null)); assert.equal(await f.store.nextCursor(['a']), null);
    clock += retention;
    const restarted = await f.reopen().seedPage('a', 'inbox', first); assert.equal(restarted.position, 1);
    assert.equal(restarted.attempts, 0); assert.ok(restarted.revision > cursor.revision);
  } finally { Date.now = originalNow; f.close(); }
});

test('Rejected server pagination state can restart from a durable first-page checkpoint after backoff', async () => {
  const f = await fixture({ committedReads: true }); const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    const cursor = await f.store.seedPage('a', 'inbox', page(['one'], 0, 1));
    await f.store.restartCursor(cursor, clock + 60000);
    assert.equal(await f.reopen().nextCursor(['a']), null);
    clock += 60000; const restarted = await f.reopen().nextCursor(['a']);
    assert.equal(restarted.position, 0); assert.equal(restarted.queryState, ''); assert.equal(restarted.head, '');
    assert.equal(restarted.revision, cursor.revision + 1); assert.equal(restarted.attempts, 1);
    assert.equal(await f.store.advance(cursor, page(['stale'], 1, null)), false);
    assert.equal(await f.store.advance(restarted, page(['fresh'], 0, 1, 'fresh-state')), true);
    const progressed = await f.store.nextCursor(['a']);
    await f.store.restartCursor(cursor, clock + 60000);
    assert.deepEqual(await f.store.nextCursor(['a']), progressed);
    assert.equal(f.reader.prepare("SELECT count(*) AS n FROM mail_sync_jobs WHERE email_id='stale'").get().n, 0);
    assert.equal(f.readsInTransaction(), 0);
  } finally { Date.now = originalNow; f.close(); }
});

test('Deleted/pending accounts cannot enqueue or publish progress, and orphan state is removed', async () => {
  const f = await fixture();
  try {
    await f.store.enqueue('pending', [mail('pending')]); assert.equal(await f.store.seedPage('pending', 'inbox', page(['pending'])), null);
    const cursor = await f.store.seedPage('a', 'inbox', page(['one'], 0, 1));
    f.sqlite.exec("UPDATE accounts SET status='deleting' WHERE id='a'");
    assert.equal(await f.store.advance(cursor, page(['two'], 1, null)), false);
    await f.store.markPictures('a', 'one', Date.now(), 'canonical');
    assert.equal((await f.store.next(['a'], 'body')).length, 0); assert.equal(await f.store.nextCursor(['a']), null);
    f.sqlite.exec("DELETE FROM accounts WHERE id='a'"); await MailSyncStore.initialize(f.db);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM mail_sync_cursors').get().n, 0);
  } finally { f.close(); }
});

test('Invalid metadata and non-progressing pages fail explicitly instead of dropping message jobs', async () => {
  const f = await fixture();
  try {
    assert.throws(() => f.store.enqueue('a', [mail('good'), mail('')]), /Invalid/);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM mail_sync_jobs').get().n, 0);
    await assert.rejects(f.store.seedPage('a', 'inbox', page(['one'], 0, 0)), /Invalid/);
    await assert.rejects(f.store.next(['a'], 'body', 1000), /Invalid/);
    await f.store.enqueue('a', [mail('one')]);
    f.sqlite.exec("UPDATE mail_sync_jobs SET payload='not JSON'");
    await assert.rejects(f.store.next(['a'], 'body'), /Invalid/);
    await f.store.discard('a', 'one'); assert.equal((await f.store.next(['a'], 'body')).length, 0);
  } finally { f.close(); }
});

test('Queued writes freeze protocol IDs, payloads, and pagination fields before callers can mutate their objects', async () => {
  const f = await fixture();
  const hold = () => { let release; const gate = new Promise(resolve => { release = resolve; }); f.queue(() => gate); return release; };
  try {
    let release = hold(); const emails = [mail('queued')], queued = f.store.enqueue('a', emails);
    emails[0].id = 'changed'; emails.push(mail('added')); release(); await queued;
    assert.deepEqual((await f.store.next(['a'], 'body', 10)).map(job => job.email.id), ['queued']);
    release = hold(); const first = page(['first'], 0, 1), seeded = f.store.seedPage('a', 'inbox', first);
    first.emails[0].id = 'changed-first'; first.nextPosition = 100; first.queryState = 'changed-state'; release();
    const cursor = await seeded; assert.equal(cursor.position, 1); assert.equal(cursor.queryState, 'state');
    release = hold(); const next = page(['second'], 1, 2), advanced = f.store.advance(cursor, next);
    cursor.position = 100; cursor.revision = 100; cursor.accountId = 'b'; next.emails[0].id = 'changed-second'; next.nextPosition = 200; next.queryState = 'changed-state'; release();
    assert.equal(await advanced, true); const saved = await f.store.nextCursor(['a']);
    assert.equal(saved.position, 2); assert.equal(saved.queryState, 'state');
    release = hold(); const cached = { savedAt: Date.now(), emails: [mail('cached')], nextPosition: 4, queryState: 'cached-state' };
    const cachedSeed = f.store.seedCached('b', 'inbox', cached);
    cached.emails[0].id = 'changed-cached'; cached.nextPosition = 400; cached.queryState = 'changed-state'; release();
    const cachedCursor = await cachedSeed; assert.equal(cachedCursor.position, 4); assert.equal(cachedCursor.queryState, 'cached-state');
    const ids = f.sqlite.prepare('SELECT email_id FROM mail_sync_jobs ORDER BY email_id').all().map(row => row.email_id);
    assert.deepEqual(ids, ['cached', 'first', 'queued', 'second']);
  } finally { f.close(); }
});

function backgroundStore(f) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/AccountStore.ets'))(name => {
    if (name === '@kit.ArkData') return { relationalStore: { getRdbStore: async () => f.db, SecurityLevel: { S3: 3 } } };
    if (name === './MailSyncStore') return storeModule.exports;
    if (name === './MailContentFiles') return { MailContentFiles: class { async prune() {} async forgetAccount() {} } };
    for (const cache of ['MailCache','PictureCache','PreparedDocumentStore','NotificationStore','UnreadBadgeStore']) {
      if (name === './' + cache) return { [cache]: class { async whenIdle() {} } };
    }
    if (name.endsWith('/NativeBrowserOAuth')) return { NativeBrowserOAuth: class {} };
    return {};
  }, module, module.exports);
  return new module.exports.AccountStore('synthetic.db');
}

test('Background account opens attach only already-migrated sync stores without writes; close clears handles', async () => {
  for (const initialized of [false, true]) {
    const f = await fixture({ initialize: initialized });
    try {
      f.sqlite.exec('CREATE TABLE oauth_credentials (id TEXT); CREATE TABLE mail_notifications (id TEXT); CREATE TABLE mail_check_lease (id TEXT); CREATE TABLE oauth_refresh_lease (id TEXT); CREATE TABLE picture_cache (id TEXT); CREATE TABLE picture_consent (id TEXT); CREATE TABLE picture_snapshot (id TEXT); CREATE TABLE prepared_documents (id TEXT)');
      const writes = f.writes(), store = backgroundStore(f); await store.openForMailChecks({ cacheDir: '/synthetic' });
      assert.equal(f.writes(), writes); assert.equal(store.mailSyncAvailable, initialized);
      if (initialized) { await store.sync.enqueue('a', [mail('one')]); assert.equal((await store.sync.next(['a'], 'body')).length, 1); }
      else assert.throws(() => store.sync, /unavailable/);
      await store.close(); assert.equal(store.mailSyncAvailable, false); assert.equal(f.closed(), 1); assert.throws(() => store.sync, /unavailable/);
    } finally { f.close(); }
  }
  const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
  const removal = source.slice(source.indexOf('  remove(id: string)'), source.indexOf('\n  close():'));
  assert.match(removal, /DELETE FROM mail_sync_jobs WHERE account_id = \?/);
  assert.match(removal, /DELETE FROM mail_sync_cursors WHERE account_id = \?/);
});
