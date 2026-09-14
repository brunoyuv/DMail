const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

// Run the actual ArkTS cache service against SQLite, substituting only the
// platform RDB result adapter and a synthetic HTTP transport. No real network.
const source = fs.readFileSync('harmony/entry/src/main/ets/data/PictureCache.ets', 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
  module: ts.ModuleKind.CommonJS } }).outputText;
const retention = 7 * 24 * 60 * 60 * 1000;
const imageUrl = 'https://images.example.test/image.png';
const image = (bytes = [137, 80, 78, 71]) => ({ responseCode: 200, header: { 'Content-Type': 'image/png; charset=binary' },
  result: new Uint8Array(bytes).buffer });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(respond = async () => image()) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return rows.length > 0; },
        goToNextRow: () => ++index < rows.length, getString: column => rows[index][column],
        getLong: column => rows[index][column], getBlob: column => rows[index][column], close() {} };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK')
  };
  const calls = []; let destroyed = 0;
  const http = { RequestMethod: { GET: 'GET' }, HttpDataType: { ARRAY_BUFFER: 2 }, createHttp: () => ({
    request: async (url, options) => { calls.push({ url, options }); return respond(url, options); },
    destroy: () => { destroyed++; }
  }) };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compiled)(name => {
    if (name === '@kit.NetworkKit') return { http };
    if (name === './MailCacheModel') return { MAIL_RETENTION_MS: retention };
    throw new Error(`Unexpected dependency ${name}`);
  }, module, module.exports);
  const { PictureCache } = module.exports;
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  await PictureCache.initialize(db);
  return { cache: new PictureCache(db, queue), reopen: () => new PictureCache(db, queue), calls, sqlite,
    initialize: () => PictureCache.initialize(db), destroyed: () => destroyed };
}

test('Picture consent is per message/account, survives reopening, and serves downloaded bytes offline without HTTP', async () => {
  let online = true;
  const f = await fixture(async () => { if (!online) throw new Error('offline'); return image(); });
  try {
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    assert.equal(f.calls.length, 0);
    await f.cache.allow('a', 'message');
    const downloaded = await f.cache.load('a', 'message', imageUrl);
    assert.equal(downloaded.mimeType, 'image/png');
    assert.deepEqual([...new Uint8Array(downloaded.data)], [137, 80, 78, 71]);
    online = false;
    const reopened = f.reopen();
    assert.equal(await reopened.allowed('a', 'message'), true);
    assert.equal(await reopened.allowed('b', 'message'), false);
    assert.equal(await reopened.allowed('a', 'other-message'), false);
    assert.deepEqual(await reopened.load('a', 'message', imageUrl), downloaded);
    assert.equal(await reopened.load('b', 'message', imageUrl), null);
    assert.equal(f.calls.length, 1);
    const { options } = f.calls[0];
    assert.deepEqual(options.header, { Accept: 'image/*' });
    assert.equal(options.usingCache, false); assert.equal(options.maxLimit, 8 * 1024 * 1024);
    assert.equal(f.destroyed(), 1);
  } finally { f.sqlite.close(); }
});

test('Duplicate picture loads coalesce and whenIdle waits through the cache write', async () => {
  const gate = deferred(); const started = deferred();
  const f = await fixture(async () => { started.resolve(); await gate.promise; return image(); });
  try {
    await f.cache.allow('a', 'message');
    const one = f.cache.load('a', 'message', imageUrl), two = f.cache.load('a', 'message', imageUrl);
    assert.equal(one, two); await started.promise;
    let idle = false; const waiting = f.cache.whenIdle().then(() => { idle = true; });
    await Promise.resolve(); assert.equal(idle, false);
    gate.resolve(); await waiting;
    assert.equal(f.calls.length, 1);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 1);
    assert.ok(await one);
  } finally { f.sqlite.close(); }
});

test('Removed accounts cannot receive consent or be resurrected by a late picture download', async () => {
  const gate = deferred(); const started = deferred();
  const f = await fixture(async () => { started.resolve(); await gate.promise; return image(); });
  try {
    await f.cache.allow('a', 'message');
    const pending = f.cache.load('a', 'message', imageUrl); await started.promise;
    f.sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'; DELETE FROM picture_consent WHERE account_id = 'a'; DELETE FROM accounts WHERE id = 'a'");
    await f.cache.allow('a', 'message');
    gate.resolve(); await pending;
    assert.equal(await f.cache.allowed('a', 'message'), false);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_consent').get().n, 0);
  } finally { f.sqlite.close(); }
});

test('Seven-day cleanup expires picture bytes while keeping the message permission', async () => {
  const f = await fixture();
  try {
    await f.cache.allow('a', 'message'); await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - retention - 1);
    await f.initialize();
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.ok(await f.cache.load('a', 'message', imageUrl));
    assert.equal(f.calls.length, 2);
  } finally { f.sqlite.close(); }
});

test('Picture loads reject credentials, local URLs, non-image content, oversized bytes and failed responses', async () => {
  let response = { ...image(), header: { 'content-type': 'text/html' } };
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    for (const url of ['file:///tmp/private', 'https://name:secret@example.test/pic', 'https://example.test/\nimg', 'data:image/png;base64,AAAA', 'https://example.test\\private']) {
      assert.equal(await f.cache.load('a', 'message', url), null);
    }
    assert.equal(f.calls.length, 0);
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    response = { ...image(), result: new ArrayBuffer(8 * 1024 * 1024 + 1) };
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    response = { ...image(), responseCode: 403 };
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    assert.equal(f.destroyed(), 3);
  } finally { f.sqlite.close(); }
});

test('Separate stores never share in-flight requests or cached picture bytes', async () => {
  const one = await fixture(async () => image([1])), two = await fixture(async () => image([2]));
  try {
    await Promise.all([one.cache.allow('a', 'message'), two.cache.allow('a', 'message')]);
    const results = await Promise.all([one.cache.load('a', 'message', imageUrl), two.cache.load('a', 'message', imageUrl)]);
    assert.deepEqual(results.map(value => [...new Uint8Array(value.data)]), [[1], [2]]);
    assert.equal(one.calls.length, 1); assert.equal(two.calls.length, 1);
  } finally { one.sqlite.close(); two.sqlite.close(); }
});

test('Picture downloading limits simultaneous requests while still completing queued images', async () => {
  const gate = deferred(), fourStarted = deferred(); let active = 0, peak = 0, started = 0;
  const f = await fixture(async () => {
    peak = Math.max(peak, ++active); if (++started === 4) fourStarted.resolve();
    await gate.promise; active--; return image();
  });
  try {
    await f.cache.allow('a', 'message');
    const pending = Array.from({ length: 7 }, (_, i) => f.cache.load('a', 'message', `${imageUrl}?image=${i}`));
    await fourStarted.promise; assert.equal(f.calls.length, 4);
    gate.resolve(); assert.ok((await Promise.all(pending)).every(Boolean));
    assert.equal(f.calls.length, 7); assert.equal(peak, 4);
  } finally { f.sqlite.close(); }
});

test('Picture budget evicts the oldest bytes within the account without removing consent or another account', async () => {
  const f = await fixture();
  try {
    // SQLite supplies virtual blob lengths to exercise the production budget
    // SQL without allocating hundreds of MiB for a fixture.
    f.sqlite.function('length', bytes => 64 * 1024 * 1024);
    await f.cache.allow('a', 'message'); await f.cache.allow('b', 'message');
    await f.cache.load('b', 'message', imageUrl);
    for (let i = 0; i < 3; i++) {
      await f.cache.load('a', 'message', `${imageUrl}?image=${i}`);
      f.sqlite.prepare('UPDATE picture_cache SET saved_at = ? WHERE account_id = ? AND url = ?')
        .run(Date.now() - 10000 + i, 'a', `${imageUrl}?image=${i}`);
    }
    const rows = f.sqlite.prepare('SELECT account_id, url FROM picture_cache ORDER BY account_id, url').all();
    assert.deepEqual(rows.map(row => [row.account_id, row.url]), [
      ['a', `${imageUrl}?image=1`], ['a', `${imageUrl}?image=2`], ['b', imageUrl]
    ]);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.equal(await f.cache.allowed('b', 'message'), true);
  } finally { f.sqlite.close(); }
});

test('Explicit picture refresh replaces only its account/message bytes and subsequent reopen stays offline', async () => {
  let next = 1;
  const f = await fixture(async () => image([next++]));
  try {
    await f.cache.allow('a', 'message'); await f.cache.allow('b', 'message');
    await f.cache.load('a', 'message', imageUrl); await f.cache.load('b', 'message', imageUrl);
    assert.deepEqual([...new Uint8Array((await f.cache.load('a', 'message', imageUrl, true)).data)], [3]);
    const reopened = f.reopen();
    assert.deepEqual([...new Uint8Array((await reopened.load('a', 'message', imageUrl)).data)], [3]);
    assert.deepEqual([...new Uint8Array((await reopened.load('b', 'message', imageUrl)).data)], [2]);
    assert.equal(f.calls.length, 3);
    assert.equal(await reopened.allowed('a', 'message'), true);
    assert.equal(await reopened.load('a', 'unapproved', imageUrl, true), null);
    assert.equal(f.calls.length, 3);
  } finally { f.sqlite.close(); }
});

test('Offline or invalid refresh responses preserve the successful cached image and its retention time', async () => {
  let mode = 'ok';
  const f = await fixture(async () => {
    if (mode === 'offline') throw new Error('offline');
    if (mode === 'invalid') return { ...image(), header: { 'content-type': 'text/html' } };
    return image([7]);
  });
  try {
    await f.cache.allow('a', 'message'); const original = await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const savedAt = f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at;
    for (const failure of ['offline', 'invalid']) {
      mode = failure;
      assert.deepEqual(await f.cache.load('a', 'message', imageUrl, true), original);
      assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at, savedAt);
    }
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), original);
    assert.equal(f.calls.length, 3);
  } finally { f.sqlite.close(); }
});

test('A failed first image can be retried explicitly without asking for consent again', async () => {
  let online = false;
  const f = await fixture(async () => { if (!online) throw new Error('offline'); return image(); });
  try {
    await f.cache.allow('a', 'message');
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    online = true; assert.ok(await f.cache.load('a', 'message', imageUrl, true));
    assert.ok(await f.reopen().load('a', 'message', imageUrl));
    assert.equal(f.calls.length, 2);
    assert.equal(await f.cache.allowed('a', 'message'), true);
  } finally { f.sqlite.close(); }
});

test('Explicit refresh queues behind an older load and coalesces duplicate refreshes without stale writes', async () => {
  const old = deferred(), oldStarted = deferred(), fresh = deferred(), freshStarted = deferred(); let count = 0;
  const f = await fixture(async () => {
    if (++count === 1) { oldStarted.resolve(); await old.promise; return image([1]); }
    freshStarted.resolve(); await fresh.promise; return image([2]);
  });
  try {
    await f.cache.allow('a', 'message');
    const first = f.cache.load('a', 'message', imageUrl); await oldStarted.promise;
    const refresh = f.cache.load('a', 'message', imageUrl, true);
    assert.equal(f.cache.load('a', 'message', imageUrl, true), refresh);
    assert.equal(f.calls.length, 1);
    old.resolve(); await first; await freshStarted.promise;
    let idle = false; const waiting = f.cache.whenIdle().then(() => { idle = true; });
    await Promise.resolve(); assert.equal(idle, false);
    fresh.resolve(); await refresh; await waiting;
    assert.equal(f.calls.length, 2);
    assert.deepEqual([...new Uint8Array((await f.reopen().load('a', 'message', imageUrl)).data)], [2]);
    assert.equal(f.calls.length, 2);
  } finally { f.sqlite.close(); }
});
