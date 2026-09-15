const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

// Run the actual ArkTS cache service against SQLite, substituting only the
// platform RDB result adapter and a synthetic HTTP transport. No real network.
const source = fs.readFileSync('harmony/entry/src/main/ets/data/PictureCache.ets', 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
  module: ts.ModuleKind.CommonJS } }).outputText;
const snapshotCompiled = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/data/PictureSnapshot.ets', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const dataSource = fs.readFileSync('harmony/entry/src/main/ets/data/PictureData.ts', 'utf8');
const dataCompiled = ts.transpileModule(dataSource, { compilerOptions: { target: ts.ScriptTarget.ES2021,
  module: ts.ModuleKind.CommonJS } }).outputText;
const pictureDataModule = { exports: {} };
new Function('module', 'exports', dataCompiled)(pictureDataModule, pictureDataModule.exports);
const retention = 7 * 24 * 60 * 60 * 1000;
const imageUrl = 'https://images.example.test/image.png';
// Generated synthetic 1 × 1 images; no remote image data.
const pngFixtures = {
  "0": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgiNoCAAFsAQ9vNFbfAAAAAElFTkSuQmCC",
  "1": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQidoCAAGoASP3Q8frAAAAAElFTkSuQmCC",
  "2": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQiNoCAAHkATfgdGTkAAAAAElFTkSuQmCC",
  "3": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOwidoCAAIgAUutHUm7AAAAAElFTkSuQmCC",
  "7": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPoidoCAAMQAZt+k/r0AAAAAElFTkSuQmCC"
};
const png = (seed = 0) => [...Buffer.from(pngFixtures[seed], 'base64')];
const otherImageFixtures = {
  "jpeg": "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQgJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlKKKK+1Pnz//Z",
  "gif": "R0lGODdhAQABAIEAAChatAAAAAAAAAAAACwAAAAAAQABAAAIBAABBAQAOw==",
  "webp": "UklGRjwAAABXRUJQVlA4IDAAAADwAQCdASoBAAEAAUAmJaACdLoB+AAETAAA/vDXA/9Js8TZ4mz5JH/xZyMR2XgAAAA=",
  "avif": "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAADybWV0YQAAAAAAAAAoaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAGxpYmF2aWYAAAAADnBpdG0AAAAAAAEAAAAeaWxvYwAAAABEAAABAAEAAAABAAABGgAAAB8AAAAoaWluZgAAAAAAAQAAABppbmZlAgAAAAABAABhdjAxQ29sb3IAAAAAamlwcnAAAABLaXBjbwAAABRpc3BlAAAAAAAAAAEAAAABAAAAEHBpeGkAAAAAAwgICAAAAAxhdjFDgQAMAAAAABNjb2xybmNseAABAA0ABoAAAAAXaXBtYQAAAAAAAAABAAEEAQKDBAAAACdtZGF0EgAKCBgABggIaDQgMhEUAAMMMMQAAHlM4Z6mR+yDEg=="
};
const image = (bytes = png()) => ({ responseCode: 200, header: { 'Content-Type': 'image/png; charset=binary' },
  result: new Uint8Array(bytes).buffer });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(respond = async () => image(), { committedReads = false } = {}) {
  const directory = committedReads ? fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-picture-budget-')) : null;
  const filename = directory ? path.join(directory, 'synthetic.db') : ':memory:';
  const sqlite = new DatabaseSync(filename);
  if (committedReads) sqlite.exec('PRAGMA journal_mode=WAL');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const reader = committedReads ? new DatabaseSync(filename, { readOnly: true }) : sqlite;
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = reader.prepare(sql); statement.setReturnArrays(true);
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
  new Function('require', 'module', 'exports', 'AppStorage', compiled)(name => {
    if (name === '@kit.NetworkKit') return { http };
    if (name === './MailCacheModel') return { MAIL_RETENTION_MS: retention };
    if (name === './PictureData') return pictureDataModule.exports;
    throw new Error(`Unexpected dependency ${name}`);
  }, module, module.exports, { setOrCreate() {} });
  const { PictureCache } = module.exports;
  const snapshotModule = { exports: {} };
  new Function('require', 'module', 'exports', snapshotCompiled)(name => {
    assert.equal(name, './PictureCache'); return module.exports;
  }, snapshotModule, snapshotModule.exports);
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  await PictureCache.initialize(db);
  const cache = new PictureCache(db, queue);
  return { db, cache, reopen: () => new PictureCache(db, queue), calls, sqlite, reader,
    snapshot: (urls, retry = false, owner = cache, account = 'a', key = 'message', scope, observer) =>
      snapshotModule.exports.loadPictureSnapshot(owner, account, key, urls, retry, scope, observer),
    close: () => { if (reader !== sqlite) reader.close(); sqlite.close(); if (directory) fs.rmSync(directory, { recursive: true }); },
    initialize: () => PictureCache.initialize(db), destroyed: () => destroyed };
}

test('Completed snapshot failures persist across reopening until explicit retry, and successful bytes stay unchanged', async () => {
  let online = false;
  const f = await fixture(async () => { if (!online) throw new Error('synthetic connection failure'); return image(); });
  try {
    for (let index = 0; index < 10; index++) {
      const result = await f.snapshot([imageUrl], false, f.reopen());
      assert.equal(result.saved, true); assert.equal(result.cancelled, false);
      assert.equal(result.resources[0].failure, 'network');
    }
    assert.equal(f.calls.length, 1);
    online = true;
    const recovered = await f.snapshot([imageUrl], true);
    assert.equal(f.calls.length, 2); assert.equal(recovered.resources[0].failure, '');
    assert.ok(recovered.resources[0].picture);
    const saved = f.sqlite.prepare('SELECT data, saved_at FROM picture_cache').get();
    online = false;
    for (let index = 0; index < 10; index++) {
      const result = await f.snapshot([imageUrl], index % 2 === 0, f.reopen());
      assert.ok(result.resources[0].picture); assert.equal(result.resources[0].failure, '');
    }
    assert.equal(f.calls.length, 2);
    assert.deepEqual(f.sqlite.prepare('SELECT data, saved_at FROM picture_cache').get(), saved);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Cached newsletter content remains complete when hidden pixels fail, including a visible shared URL', async () => {
  const { mailDocument } = require('../.tools/test-output/mail/html/HtmlDocument.js');
  const photo = 'https://images.example.test/photo.png', invisible = 'https://images.example.test/open.gif';
  const source = `<img src="${photo}" width="400" height="300"><img src="${photo}" width="1" height="1">` +
    `<img src="${invisible}" width="1" height="1"><img src="${invisible}?hidden" style="display:none!important">`;
  let online = true;
  const f = await fixture(async url => {
    if (!online || url !== photo) throw new Error('synthetic unavailable tracker');
    return image();
  });
  try {
    await f.cache.allow('a', 'newsletter');
    const urls = [...mailDocument(source, true).matchAll(/<img\b[^>]*\bsrc="([^"]+)"/g)].map(match => match[1]);
    assert.deepEqual(urls, [photo], 'filter elements without blacklisting a URL used visibly');
    const render = async cache => {
      const result = await f.snapshot(urls, false, cache, 'a', 'newsletter');
      assert.equal(result.saved, true);
      assert.ok(result.resources.every(resource => resource.picture && !resource.failure));
    };
    await render(f.cache);
    const saved = f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache').all();
    online = false; await render(f.reopen());
    assert.deepEqual(f.calls.map(call => call.url), [photo]);
    assert.deepEqual(f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache').all(), saved);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Picture consent is per message/account, survives reopening, and serves downloaded bytes offline without HTTP', async () => {
  let online = true;
  const f = await fixture(async () => { if (!online) throw new Error('offline'); return image(); });
  try {
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    assert.equal(f.calls.length, 0);
    await f.cache.allow('a', 'message');
    const downloaded = await f.cache.load('a', 'message', imageUrl);
    assert.equal(downloaded.mimeType, 'image/png');
    assert.deepEqual([...new Uint8Array(downloaded.data)], png());
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

test('Snapshot retry downloads only missing pictures and complete messages reopen without HTTP', async () => {
  let missingOnline = false, online = true;
  const urls = Array.from({ length: 5 }, (_, i) => `${imageUrl}?image=${i}`);
  const f = await fixture(async url => {
    if (!online || (!missingOnline && urls.indexOf(url) >= 3)) throw new Error('synthetic connection failed');
    return image();
  });
  try {
    const first = await f.snapshot(urls);
    assert.equal(f.calls.length, 5); assert.equal(first.resources.filter(resource => resource.failure).length, 2);
    const original = f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache ORDER BY url').all();
    await f.snapshot(urls, false, f.reopen()); assert.equal(f.calls.length, 5, 'failed attempts are remembered');
    await f.snapshot(urls, true);
    assert.equal(f.calls.length, 7, 'only the two missing pictures retry');
    assert.deepEqual(f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache ORDER BY url').all(), original);
    missingOnline = true;
    const complete = await f.snapshot(urls, true);
    assert.equal(f.calls.length, 9); assert.ok(complete.resources.every(resource => resource.picture && !resource.failure));
    assert.deepEqual(f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache WHERE url < ? ORDER BY url').all(urls[3]), original);
    const completed = f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache ORDER BY url').all();
    online = false;
    await f.snapshot(urls, true);
    const reopened = await f.snapshot(urls, false, f.reopen());
    assert.ok(reopened.resources.every(resource => resource.picture && !resource.failure));
    assert.equal(f.calls.length, 9);
    assert.deepEqual(f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache ORDER BY url').all(), completed);
  } finally { await f.cache.whenIdle(); f.close(); }
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
  const one = await fixture(async () => image(png(1))), two = await fixture(async () => image(png(2)));
  try {
    await Promise.all([one.cache.allow('a', 'message'), two.cache.allow('a', 'message')]);
    const results = await Promise.all([one.cache.load('a', 'message', imageUrl), two.cache.load('a', 'message', imageUrl)]);
    assert.deepEqual(results.map(value => [...new Uint8Array(value.data)]), [png(1), png(2)]);
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

test('Backgrounding drains active pictures but skips queued loads and queued refreshes without losing consent or saved bytes', async () => {
  const gate = deferred(), fourStarted = deferred(); let started = 0;
  const f = await fixture(async () => {
    if (++started === 4) fourStarted.resolve();
    await gate.promise; return image();
  });
  try {
    await f.cache.allow('a', 'message');
    const urls = Array.from({ length: 7 }, (_, i) => `${imageUrl}?background=${i}`);
    const pending = urls.map(url => f.cache.loadWithStatus('a', 'message', url));
    await fourStarted.promise;
    const retry = f.cache.loadWithStatus('a', 'message', urls[0], true);
    f.cache.constructor.setForeground(false);
    let idle = false; const closed = f.cache.whenIdle().then(() => idle = true);
    await Promise.resolve(); assert.equal(idle, false);
    gate.resolve();
    const results = await Promise.all(pending); await closed;
    assert.equal(f.calls.length, 4, 'queued images and the queued explicit refresh must open no socket');
    assert.ok(results.slice(0, 4).every(result => result.picture));
    assert.ok(results.slice(4).every(result => result.picture === null && result.failure === ''));
    assert.ok((await retry).picture, 'cancelled retry retains the just-saved active download');
    assert.equal((await retry).failure, '');
    assert.equal(await f.cache.allowed('a', 'message'), true);
    const before = f.sqlite.prepare('SELECT saved_at FROM picture_cache WHERE url = ?').get(urls[0]).saved_at;
    assert.ok(await f.cache.load('a', 'message', urls[0]), 'cached bytes remain available while backgrounded');
    assert.equal(await f.cache.load('a', 'message', urls[4]), null);
    assert.equal(f.calls.length, 4);
    f.cache.constructor.setForeground(true);
    assert.ok(await f.cache.load('a', 'message', urls[0]));
    assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache WHERE url = ?').get(urls[0]).saved_at, before);
    assert.ok(await f.cache.load('a', 'message', urls[4]), 'skipped work remains retryable on resume');
    assert.equal(f.calls.length, 5);
  } finally { gate.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Reader cancellation affects only that message, preserving another visible card and renewed requests', async () => {
  const gate = deferred(), fourStarted = deferred(); let started = 0;
  const f = await fixture(async () => { if (++started === 4) fourStarted.resolve(); await gate.promise; return image(); });
  try {
    await f.cache.allow('a', 'first'); await f.cache.allow('a', 'second');
    const active = Array.from({ length: 4 }, (_, i) => f.cache.load('a', 'first', `${imageUrl}?active=${i}`));
    await fourStarted.promise;
    const abandoned = f.cache.loadWithStatus('a', 'first', `${imageUrl}?queued`);
    const other = f.cache.load('a', 'second', `${imageUrl}?other`);
    f.cache.cancelPending('a', 'first');
    const reopened = f.cache.load('a', 'first', `${imageUrl}?queued`);
    gate.resolve();
    await Promise.all(active);
    assert.deepEqual(await abandoned, { picture: null, failure: '', status: 0 });
    assert.ok(await other); assert.ok(await reopened);
    assert.equal(f.calls.length, 6);
    assert.equal(f.calls.filter(call => call.url.endsWith('?queued')).length, 1, 'new reader must not join cancelled old work');
  } finally { gate.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('A quick background and foreground transition cannot restart old queued picture requests', async () => {
  const gate = deferred(), fourStarted = deferred(); let started = 0;
  const f = await fixture(async () => { if (++started === 4) fourStarted.resolve(); await gate.promise; return image(); });
  try {
    await f.cache.allow('a', 'message');
    const active = Array.from({ length: 4 }, (_, i) => f.cache.load('a', 'message', `${imageUrl}?active=${i}`));
    await fourStarted.promise;
    const skipped = f.cache.loadWithStatus('a', 'message', `${imageUrl}?skipped`);
    f.cache.constructor.setForeground(false); f.cache.constructor.setForeground(true);
    const resumed = f.cache.load('a', 'message', `${imageUrl}?skipped`);
    gate.resolve(); await Promise.all(active);
    assert.equal((await skipped).picture, null); assert.ok(await resumed);
    assert.equal(f.calls.length, 5);
  } finally { gate.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Background cancellation is rechecked after the last consent read before opening HTTP', async () => {
  const consent = deferred(), held = deferred(); const f = await fixture();
  try {
    await f.cache.allow('a', 'message');
    const query = f.db.querySql; let reads = 0;
    f.db.querySql = async (sql, args) => {
      if (sql.startsWith('SELECT 1 FROM picture_consent') && ++reads === 2) { held.resolve(); await consent.promise; }
      return query(sql, args);
    };
    const pending = f.cache.loadWithStatus('a', 'message', imageUrl);
    await held.promise; f.cache.constructor.setForeground(false); consent.resolve();
    assert.deepEqual(await pending, { picture: null, failure: '', status: 0 });
    assert.equal(f.calls.length, 0); await f.cache.whenIdle();
  } finally { consent.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Saving small pictures reads one budget scalar without transferring the account image inventory', async () => {
  const f = await fixture();
  try {
    await f.cache.allow('a', 'message');
    const insert = f.sqlite.prepare('INSERT INTO picture_cache VALUES (?, ?, ?, ?, ?, ?)');
    const now = Date.now(), bytes = new Uint8Array(png());
    f.sqlite.exec('BEGIN');
    for (let index = 0; index < 4000; index++) {
      insert.run('a', `old-${index}`, `${imageUrl}?old=${index}`, 'image/png', bytes, now);
    }
    f.sqlite.exec('COMMIT');
    let inventories = 0, totals = 0, values = 0;
    const query = f.db.querySql;
    f.db.querySql = async (sql, args) => {
      if (sql.startsWith('SELECT message_key, url, length(data)')) inventories++;
      const result = await query(sql, args);
      if (sql.startsWith('SELECT COALESCE(SUM(length(data))')) {
        totals++; const get = result.getLong;
        result.getLong = column => { values++; return get(column); };
      }
      return result;
    };
    for (let index = 0; index < 16; index++) {
      assert.ok(await f.cache.load('a', 'message', `${imageUrl}?new=${index}`));
    }
    assert.equal(inventories, 0, 'An under-budget save must not retrieve/sort thousands of image identities');
    assert.equal(totals, 16); assert.equal(values, 16);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 4016);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Pooled budget eviction reads only required oldest victims and excludes the incoming replacement', async () => {
  const f = await fixture(async () => image(), { committedReads: true });
  try {
    f.reader.function('length', _bytes => 1024 * 1024);
    await f.cache.allow('a', 'message'); await f.cache.allow('b', 'message');
    const insert = f.sqlite.prepare('INSERT INTO picture_cache VALUES (?, ?, ?, ?, ?, ?)');
    const now = Date.now() - 1000, bytes = new Uint8Array(png());
    f.sqlite.exec('BEGIN');
    for (let index = 0; index < 128; index++) {
      insert.run('a', 'old', `${imageUrl}?old=${String(index).padStart(3, '0')}`, 'image/png', bytes, now);
    }
    insert.run('a', 'expired', imageUrl, 'image/png', bytes, now - retention);
    insert.run('b', 'message', imageUrl, 'image/png', bytes, now);
    f.sqlite.exec('COMMIT');
    let inventories = 0, transferred = 0;
    const query = f.db.querySql;
    f.db.querySql = async (sql, args) => {
      const result = await query(sql, args);
      if (sql.startsWith('SELECT message_key, url, length(data)')) {
        inventories++; const next = result.goToNextRow;
        result.goToNextRow = () => { const ready = next(); if (ready) transferred++; return ready; };
      }
      return result;
    };
    assert.ok(await f.cache.load('a', 'message', imageUrl));
    assert.equal(inventories, 1); assert.equal(transferred, 1);
    assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM picture_cache WHERE account_id='a'").get().n, 128);
    assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM picture_cache WHERE account_id='a' AND url=?").get(`${imageUrl}?old=000`).n, 0);
    assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM picture_cache WHERE account_id='b'").get().n, 1);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.ok(await f.cache.load('a', 'message', imageUrl, true));
    assert.equal(inventories, 1, 'A replacement contributes its incoming bytes once and must not evict itself');
    assert.equal(transferred, 1);
  } finally { await f.cache.whenIdle(); f.close(); }
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

test('Picture budget includes the incoming bytes when native-style pooled readers only see committed rows', async () => {
  const f = await fixture(async () => image(), { committedReads: true });
  try {
    // Two committed virtual 64 MiB rows exactly fill the budget. A third
    // incoming image must evict one even though querySql cannot see its INSERT.
    f.reader.function('length', _bytes => 64 * 1024 * 1024);
    await f.cache.allow('a', 'message');
    for (let i = 0; i < 3; i++) {
      assert.ok(await f.cache.load('a', 'message', `${imageUrl}?pooled=${i}`));
      f.sqlite.prepare('UPDATE picture_cache SET saved_at = ? WHERE url = ?')
        .run(Date.now() - 10000 + i, `${imageUrl}?pooled=${i}`);
    }
    assert.deepEqual(f.sqlite.prepare('SELECT url FROM picture_cache ORDER BY url').all().map(row => row.url),
      [`${imageUrl}?pooled=1`, `${imageUrl}?pooled=2`]);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    const count = f.calls.length;
    assert.ok(await f.reopen().load('a', 'message', `${imageUrl}?pooled=2`));
    assert.equal(f.calls.length, count);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Explicit picture refresh replaces only its account/message bytes and subsequent reopen stays offline', async () => {
  let next = 1;
  const f = await fixture(async () => image(png(next++)));
  try {
    await f.cache.allow('a', 'message'); await f.cache.allow('b', 'message');
    await f.cache.load('a', 'message', imageUrl); await f.cache.load('b', 'message', imageUrl);
    assert.deepEqual([...new Uint8Array((await f.cache.load('a', 'message', imageUrl, true)).data)], png(3));
    const reopened = f.reopen();
    assert.deepEqual([...new Uint8Array((await reopened.load('a', 'message', imageUrl)).data)], png(3));
    assert.deepEqual([...new Uint8Array((await reopened.load('b', 'message', imageUrl)).data)], png(2));
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
    return image(png(7));
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
    if (++count === 1) { oldStarted.resolve(); await old.promise; return image(png(1)); }
    freshStarted.resolve(); await fresh.promise; return image(png(2));
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
    assert.deepEqual([...new Uint8Array((await f.reopen().load('a', 'message', imageUrl)).data)], png(2));
    assert.equal(f.calls.length, 2);
  } finally { f.sqlite.close(); }
});

test('A server error page labelled PNG cannot replace cached bytes or extend their retention', async () => {
  let mode = 'ok';
  const f = await fixture(async () => {
    if (mode === 'offline') throw new Error('offline');
    return mode === 'error-page' ? image(Buffer.from('<html>Temporary image service error</html>')) : image();
  });
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const savedAt = f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at;
    mode = 'error-page';
    assert.deepEqual(await f.cache.load('a', 'message', imageUrl, true), original);
    assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at, savedAt);
    mode = 'offline';
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), original);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.equal(f.calls.length, 2);
  } finally { f.sqlite.close(); }
});

test('A mislabeled first response saves nothing and a valid explicit retry keeps the original consent', async () => {
  let response = image(Buffer.from('<html>Temporary image service error</html>'));
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    response = image();
    const recovered = await f.cache.load('a', 'message', imageUrl, true);
    assert.deepEqual([...new Uint8Array(recovered.data)], png());
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), recovered);
    assert.equal(f.calls.length, 2);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_consent').get().n, 1);
  } finally { f.sqlite.close(); }
});

test('An older cached MIME mismatch is ignored so a normal reopen can recover the image', async () => {
  const f = await fixture();
  try {
    await f.cache.allow('a', 'message');
    f.sqlite.prepare('INSERT INTO picture_cache VALUES (?, ?, ?, ?, ?, ?)')
      .run('a', 'message', imageUrl, 'image/png', Buffer.from('<html>Old failed response</html>'), Date.now() - 1000);
    const recovered = await f.cache.load('a', 'message', imageUrl);
    assert.deepEqual([...new Uint8Array(recovered.data)], png());
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), recovered);
    assert.equal(f.calls.length, 1);
  } finally { f.sqlite.close(); }
});

test('Real synthetic raster, SVG and AVIF fixtures retain their exact bytes through download and offline reopen', async () => {
  const gif87 = Buffer.from(otherImageFixtures.gif, 'base64');
  const gif89 = Buffer.from(gif87); gif89[4] = '9'.charCodeAt(0);
  const samples = [
    ['image/png', png()],
    ['image/jpeg', Buffer.from(otherImageFixtures.jpeg, 'base64')],
    ['image/gif', gif87], ['image/gif', gif89],
    ['image/webp', Buffer.from(otherImageFixtures.webp, 'base64')],
    ['image/svg+xml', Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="#285ab4"/></svg>')],
    ['image/avif', Buffer.from(otherImageFixtures.avif, 'base64')]
  ];
  let response;
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    for (const [index, [mimeType, bytes]] of samples.entries()) {
      response = { ...image(bytes), header: { 'Content-Type': mimeType } };
      const url = `${imageUrl}?format=${index}`;
      const downloaded = await f.cache.load('a', 'message', url);
      assert.ok(downloaded, mimeType);
      assert.equal(downloaded.mimeType, mimeType);
      assert.deepEqual([...new Uint8Array(downloaded.data)], [...bytes]);
      assert.deepEqual(await f.reopen().load('a', 'message', url), downloaded);
    }
    assert.equal(f.calls.length, samples.length);
  } finally { f.sqlite.close(); }
});

test('Common raster MIME mismatches and incomplete signatures are rejected without caching', async () => {
  let response;
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const samples = [
      ['image/png', [137, 80, 78, 71]], ['image/jpeg', [255, 216]],
      ['image/gif', [...Buffer.from('GIF89')]],
      ['image/webp', [...Buffer.from('RIFF0000WAVE')]]
    ];
    for (const [mimeType, prefix] of samples) {
      for (const bytes of [prefix, Buffer.from('<html>Temporary service error</html>')]) {
        response = { ...image(bytes), header: { 'Content-Type': mimeType } };
        assert.equal(await f.cache.load('a', 'message', imageUrl, true), null, mimeType);
      }
    }
    assert.equal(f.calls.length, samples.length * 2);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
  } finally { f.sqlite.close(); }
});

test('Explicit refresh can download after a picture-byte cache read failure while consent checks remain required', async () => {
  let seed = 1;
  const f = await fixture(async () => image(png(seed)));
  try {
    await f.cache.allow('a', 'message');
    await f.cache.load('a', 'message', imageUrl);
    const query = f.db.querySql;
    let failures = 2;
    f.db.querySql = async (sql, args) => {
      if (sql.startsWith('SELECT p.data') && failures-- > 0) throw new Error('synthetic cache read failure');
      return query(sql, args);
    };
    assert.equal(await f.cache.load('a', 'message', imageUrl), null);
    assert.equal(f.calls.length, 1);
    seed = 2;
    const recovered = await f.cache.load('a', 'message', imageUrl, true);
    assert.deepEqual([...new Uint8Array(recovered.data)], png(2));
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), recovered);
    assert.equal(f.calls.length, 2);
    assert.equal(await f.cache.load('a', 'unapproved', imageUrl, true), null);
    assert.equal(f.calls.length, 2);
  } finally { f.sqlite.close(); }
});

test('Downloaded images still display when cache writing fails without replacing the saved offline copy', async () => {
  let seed = 1;
  const f = await fixture(async () => image(png(seed)));
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const savedAt = f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at;
    f.sqlite.exec("CREATE TRIGGER reject_picture_write BEFORE INSERT ON picture_cache BEGIN SELECT RAISE(ABORT, 'synthetic cache write failure'); END");
    seed = 2;
    const refreshed = await f.cache.load('a', 'message', imageUrl, true);
    assert.deepEqual([...new Uint8Array(refreshed.data)], png(2));
    assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at, savedAt);
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), original);
    const uncached = await f.cache.load('a', 'message', `${imageUrl}?new`);
    assert.deepEqual([...new Uint8Array(uncached.data)], png(2));
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 1);
    assert.equal(await f.cache.allowed('a', 'message'), true);
    assert.equal(f.calls.length, 3);
  } finally { f.sqlite.close(); }
});

test('Extensionless binary image responses use their raster signatures and reopen offline with the correct MIME type', async () => {
  let response;
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const samples = [
      ['image/png', png()],
      ['image/jpeg', Buffer.from(otherImageFixtures.jpeg, 'base64')],
      ['image/gif', Buffer.from(otherImageFixtures.gif, 'base64')],
      ['image/webp', Buffer.from(otherImageFixtures.webp, 'base64')]
    ];
    for (const [index, [mimeType, bytes]] of samples.entries()) {
      const url = `https://images.example.test/${index}/local.path`;
      response = { ...image(bytes), header: { 'Content-Type': 'Application/Octet-Stream; charset=binary' } };
      const downloaded = await f.cache.load('a', 'message', url);
      assert.ok(downloaded, mimeType);
      assert.equal(downloaded.mimeType, mimeType);
      assert.deepEqual([...new Uint8Array(downloaded.data)], [...bytes]);
      assert.equal(f.sqlite.prepare('SELECT mime_type FROM picture_cache WHERE url = ?').get(url).mime_type, mimeType);
      assert.deepEqual(await f.reopen().load('a', 'message', url), downloaded);
    }
    assert.equal(f.calls.length, samples.length);
  } finally { f.sqlite.close(); }
});

test('Binary refresh replaces valid images but unrecognized binary content preserves the saved image and timestamp', async () => {
  let response = image(png(1));
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    await f.cache.load('a', 'message', imageUrl);
    response = { ...image(png(2)), header: { 'Content-Type': 'application/octet-stream' } };
    const refreshed = await f.cache.load('a', 'message', imageUrl, true);
    assert.deepEqual([...new Uint8Array(refreshed.data)], png(2));
    assert.equal(refreshed.mimeType, 'image/png');
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const savedAt = f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at;
    for (const bytes of [Buffer.from('<html>Unavailable</html>'), Buffer.from('%PDF-1.7'), [137, 80, 78, 71]]) {
      response = { ...image(bytes), header: { 'Content-Type': 'application/octet-stream' } };
      assert.deepEqual(await f.cache.load('a', 'message', imageUrl, true), refreshed);
      assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at, savedAt);
    }
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), refreshed);
    assert.equal(await f.cache.allowed('a', 'message'), true);
  } finally { f.sqlite.close(); }
});

test('Missing MIME headers require a recognized raster signature and explicit non-image types stay blocked', async () => {
  let response = { ...image(), header: {} };
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const downloaded = await f.cache.load('a', 'message', imageUrl);
    assert.equal(downloaded.mimeType, 'image/png');
    for (const type of ['text/html', 'text/plain', 'application/pdf']) {
      response = { ...image(), header: { 'Content-Type': type } };
      assert.equal(await f.cache.load('a', 'message', `${imageUrl}?blocked=${type}`), null);
    }
    for (const header of [{}, { 'Content-Type': 'application/octet-stream' }]) {
      response = { ...image(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>')), header };
      assert.equal(await f.cache.load('a', 'message', `${imageUrl}?unknown`), null);
    }
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 1);
  } finally { f.sqlite.close(); }
});

test('Legacy picture loads and status loads share one flight and the exact returned image', async () => {
  for (const statusFirst of [false, true]) {
    const gate = deferred(), started = deferred();
    const f = await fixture(async () => { started.resolve(); await gate.promise; return image(png(2)); });
    try {
      await f.cache.allow('a', 'message');
      const first = statusFirst ? f.cache.loadWithStatus('a', 'message', imageUrl) : f.cache.load('a', 'message', imageUrl);
      const status = f.cache.loadWithStatus('a', 'message', imageUrl);
      const legacy = f.cache.load('a', 'message', imageUrl);
      assert.equal(statusFirst ? status : legacy, first);
      assert.equal(f.cache.loadWithStatus('a', 'message', imageUrl), status);
      assert.equal(f.cache.load('a', 'message', imageUrl), legacy);
      await started.promise; assert.equal(f.calls.length, 1);
      gate.resolve();
      const [result, picture] = await Promise.all([status, legacy]);
      assert.equal(result.picture, picture);
      assert.equal(result.failure, ''); assert.equal(result.status, 0);
      assert.deepEqual([...new Uint8Array(picture.data)], png(2));
      await f.cache.whenIdle(); assert.equal(f.destroyed(), 1);
    } finally { gate.resolve(); await f.cache.whenIdle(); f.sqlite.close(); }
  }
});

test('Status refresh queues behind a normal load and both APIs share its cached fallback', async () => {
  const firstGate = deferred(), firstStarted = deferred(), refreshGate = deferred(), refreshStarted = deferred();
  let calls = 0;
  const f = await fixture(async () => {
    if (++calls === 1) { firstStarted.resolve(); await firstGate.promise; return image(png(1)); }
    refreshStarted.resolve(); await refreshGate.promise; return { ...image(), responseCode: 503 };
  });
  try {
    await f.cache.allow('a', 'message');
    const initial = f.cache.load('a', 'message', imageUrl); await firstStarted.promise;
    const status = f.cache.loadWithStatus('a', 'message', imageUrl, true);
    const legacy = f.cache.load('a', 'message', imageUrl, true);
    assert.equal(f.cache.loadWithStatus('a', 'message', imageUrl, true), status);
    assert.equal(f.calls.length, 1);
    firstGate.resolve(); const original = await initial; await refreshStarted.promise;
    assert.equal(f.calls.length, 2); refreshGate.resolve();
    const [result, fallback] = await Promise.all([status, legacy]);
    assert.equal(result.picture, fallback); assert.deepEqual(fallback, original);
    assert.equal(result.failure, 'server'); assert.equal(result.status, 503);
    assert.deepEqual(await f.reopen().load('a', 'message', imageUrl), original);
    assert.equal(f.calls.length, 2);
  } finally { firstGate.resolve(); refreshGate.resolve(); await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Picture status distinguishes server network format and size failures without losing offline bytes', async () => {
  let outcome = () => image(png(1));
  const f = await fixture(async () => outcome());
  const unsafe = 'https://private.example.test/picture?token=do-not-report';
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const savedAt = f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at;
    const cases = [
      ['server', 403, () => ({ ...image(), responseCode: 403, result: `Forbidden ${unsafe}` })],
      ['server', 503, () => ({ ...image(), responseCode: 503, result: `Unavailable ${unsafe}` })],
      ['network', 0, () => { const error = new Error(`Provider error at ${unsafe}`); error.url = unsafe; throw error; }],
      ['format', 0, () => ({ ...image(), result: `Decoded provider error at ${unsafe}` })],
      ['format', 0, () => ({ ...image(), result: new ArrayBuffer(0) })],
      ['format', 0, () => ({ ...image(), header: { 'content-type': `text/html; source=${unsafe}` } })],
      ['format', 0, () => image(Buffer.from(`<html>${unsafe}</html>`))],
      ['size', 0, () => { const error = new Error(`NetworkKit maxLimit at ${unsafe}`); error.code = 2300063; throw error; }],
      ['size', 0, () => ({ ...image(), result: new ArrayBuffer(8 * 1024 * 1024 + 1) })]
    ];
    for (const [failure, status, respond] of cases) {
      outcome = respond;
      const result = await f.cache.loadWithStatus('a', 'message', imageUrl, true);
      assert.equal(result.failure, failure); assert.equal(result.status, status);
      assert.deepEqual(result.picture, original);
      assert.deepEqual(Object.keys(result).sort(), ['failure', 'picture', 'status']);
      assert.equal(JSON.stringify(result).includes('private.example.test'), false);
      assert.equal(JSON.stringify(result).includes('do-not-report'), false);
      assert.equal(f.sqlite.prepare('SELECT saved_at FROM picture_cache').get().saved_at, savedAt);
      const missing = await f.cache.loadWithStatus('a', 'message', `${imageUrl}?missing`, true);
      assert.deepEqual(missing, { picture: null, failure, status });
      assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 1);
    }
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Only integer HTTP status codes in the protocol range are exposed in picture results', async () => {
  let code = 403;
  const f = await fixture(async () => ({ ...image(), responseCode: code }));
  try {
    await f.cache.allow('a', 'message');
    for (const [responseCode, expected] of [[100, 100], [599, 599], [99, 0], [600, 0], [503.5, 0], ['503', 0], [Infinity, 0], ['secret-provider-value', 0]]) {
      code = responseCode;
      assert.deepEqual(await f.cache.loadWithStatus('a', 'message', imageUrl), { picture: null, failure: 'server', status: expected });
    }
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('A cache hit and a later successful refresh do not retain an earlier failure status', async () => {
  let response = image(png(1));
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.load('a', 'message', imageUrl);
    response = { ...image(), responseCode: 503 };
    const failed = await f.cache.loadWithStatus('a', 'message', imageUrl, true);
    assert.equal(failed.failure, 'server'); assert.equal(failed.status, 503);
    const count = f.calls.length;
    const cached = await f.cache.loadWithStatus('a', 'message', imageUrl);
    assert.deepEqual(cached, { picture: original, failure: '', status: 0 });
    assert.equal(f.calls.length, count);
    response = image(png(2));
    const refreshed = await f.cache.loadWithStatus('a', 'message', imageUrl, true);
    assert.equal(refreshed.failure, ''); assert.equal(refreshed.status, 0);
    assert.deepEqual([...new Uint8Array(refreshed.picture.data)], png(2));
    const reopened = await f.reopen().loadWithStatus('a', 'message', imageUrl);
    assert.deepEqual(reopened, refreshed); assert.equal(f.calls.length, count + 1);
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Address consent and storage failures report fixed local categories without HTTP or provider text', async () => {
  const f = await fixture();
  try {
    assert.deepEqual(await f.cache.loadWithStatus('a', 'message', 'https://user:secret@example.test/picture'),
      { picture: null, failure: 'address', status: 0 });
    assert.deepEqual(await f.cache.loadWithStatus('a', 'unapproved', imageUrl),
      { picture: null, failure: 'consent', status: 0 });
    await f.cache.allow('a', 'message');
    f.db.querySql = async () => { throw new Error('Storage URL https://private.example.test/?secret'); };
    assert.deepEqual(await f.cache.loadWithStatus('a', 'message', imageUrl),
      { picture: null, failure: 'storage', status: 0 });
    assert.equal(f.calls.length, 0);
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Known raster bytes canonicalize wrong image subtypes and aliases before rendering and persistence', async () => {
  let response;
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const samples = [
      ['image/png', png()],
      ['image/jpeg', Buffer.from(otherImageFixtures.jpeg, 'base64')],
      ['image/gif', Buffer.from(otherImageFixtures.gif, 'base64')],
      ['image/webp', Buffer.from(otherImageFixtures.webp, 'base64')]
    ];
    let index = 0;
    for (const [mimeType, bytes] of samples) {
      for (const declared of ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/jpg', 'image/pjpeg', 'image/x-png']) {
        const url = `${imageUrl}?canonical=${++index}`;
        response = { ...image(bytes), header: { 'Content-Type': declared } };
        const loaded = await f.cache.loadWithStatus('a', 'message', url);
        assert.ok(loaded.picture, `${mimeType} served as ${declared}`);
        assert.equal(loaded.picture.mimeType, mimeType);
        assert.equal(loaded.failure, ''); assert.equal(loaded.status, 0);
        assert.deepEqual([...new Uint8Array(loaded.picture.data)], [...bytes]);
        assert.equal(f.sqlite.prepare('SELECT mime_type FROM picture_cache WHERE url = ?').get(url).mime_type, mimeType);
        assert.deepEqual(await f.reopen().loadWithStatus('a', 'message', url), loaded);
      }
    }
    assert.equal(f.calls.length, index);
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Raster recognition keeps explicit textual content blocked and does not reinterpret SVG XML', () => {
  const bytes = image().result;
  for (const declared of ['text/plain', 'text/html', 'application/xml', 'text/xml', 'application/pdf']) {
    assert.equal(pictureDataModule.exports.pictureMimeType(bytes, declared), '', declared);
  }
  assert.equal(pictureDataModule.exports.pictureMimeType(bytes, 'image/svg+xml'), 'image/svg+xml');
  const svg = image(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>')).result;
  assert.equal(pictureDataModule.exports.pictureMimeType(svg, 'image/svg+xml'), 'image/svg+xml');
});

test('Invalid image alias responses report format failures and preserve saved picture bytes and retention', async () => {
  let response = image(png(2));
  const f = await fixture(async () => response);
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.load('a', 'message', imageUrl);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const saved = f.sqlite.prepare('SELECT data, mime_type, saved_at FROM picture_cache').get();
    for (const alias of ['image/jpg', 'image/pjpeg', 'image/x-png']) {
      response = { ...image(Buffer.from('<html>Synthetic image service error</html>')),
        header: { 'Content-Type': alias } };
      const result = await f.cache.loadWithStatus('a', 'message', imageUrl, true);
      assert.deepEqual(result, { picture: original, failure: 'format', status: 0 }, alias);
      assert.deepEqual(f.sqlite.prepare('SELECT data, mime_type, saved_at FROM picture_cache').get(), saved, alias);
      const requests = f.calls.length;
      assert.deepEqual(await f.reopen().loadWithStatus('a', 'message', imageUrl),
        { picture: original, failure: '', status: 0 }, alias);
      assert.equal(f.calls.length, requests, 'offline reread must use the retained picture');
    }
    assert.equal(f.calls.length, 4);
    assert.equal(await f.cache.allowed('a', 'message'), true);
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Successful downloads report a local save failure while retaining display bytes and the original offline copy', async () => {
  let online = true, seed = 1;
  const f = await fixture(async () => {
    if (!online) throw new Error('Synthetic offline transport');
    return image(png(seed));
  });
  try {
    await f.cache.allow('a', 'message');
    const original = await f.cache.loadWithStatus('a', 'message', imageUrl);
    assert.equal(original.failure, '');
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - 10000);
    const saved = f.sqlite.prepare('SELECT data, mime_type, saved_at FROM picture_cache').get();
    f.sqlite.exec("CREATE TRIGGER reject_picture_write BEFORE INSERT ON picture_cache BEGIN SELECT RAISE(ABORT, 'Synthetic private storage detail'); END");
    seed = 2;
    const missingUrl = `${imageUrl}?unsaved=synthetic`;
    for (const [url, refresh] of [[missingUrl, false], [imageUrl, true]]) {
      const result = await f.cache.loadWithStatus('a', 'message', url, refresh);
      assert.deepEqual(result, { picture: { data: image(png(2)).result, mimeType: 'image/png' }, failure: 'storage', status: 0 });
      assert.deepEqual([...new Uint8Array(result.picture.data)], png(2), 'new bytes remain displayable despite the failed transaction');
      assert.equal(JSON.stringify(result).includes('Synthetic private storage detail'), false);
      assert.deepEqual(f.sqlite.prepare('SELECT data, mime_type, saved_at FROM picture_cache').get(), saved);
    }
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache WHERE url = ?').get(missingUrl).n, 0);
    online = false;
    const requests = f.calls.length;
    assert.deepEqual(await f.reopen().loadWithStatus('a', 'message', imageUrl), original);
    assert.equal(f.calls.length, requests, 'the preserved old copy still opens without network');
    assert.deepEqual(await f.reopen().loadWithStatus('a', 'message', missingUrl), { picture: null, failure: 'network', status: 0 });
    assert.equal(f.calls.length, requests + 1, 'unsaved bytes must not be mistaken for a persisted image');
    assert.equal(await f.cache.allowed('a', 'message'), true);
  } finally { await f.cache.whenIdle(); f.sqlite.close(); }
});

test('Whole snapshot attempts coalesce and expose one result only after all downloads settle', async () => {
  const started = deferred(), release = deferred(); let active = 0, maximum = 0;
  const urls = Array.from({ length: 7 }, (_, index) => `${imageUrl}?batch=${index}`);
  const f = await fixture(async () => {
    active++; maximum = Math.max(maximum, active); if (active === 4) started.resolve();
    await release.promise; active--; return image();
  });
  try {
    const first = f.snapshot(urls), duplicate = f.snapshot(urls);
    assert.equal(first, duplicate);
    let settled = false; first.then(() => { settled = true; });
    await started.promise; assert.equal(settled, false); assert.equal(f.calls.length, 4);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 0);
    release.resolve(); const result = await first;
    assert.equal(maximum, 4); assert.equal(f.calls.length, 7);
    assert.equal(result.saved, true); assert.equal(result.cancelled, false);
    assert.ok(result.resources.every(resource => resource.picture && resource.failure === ''));
    assert.equal(await f.cache.allowed('a', 'message'), true, 'automatic preparation retains the ready-account guard');
    assert.equal(await f.cache.allowed('b', 'message'), false);
  } finally { release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('A progressive attempt delivers cached bytes and each fast result once before a slow sibling settles', async () => {
  const release = deferred(), fast = deferred(), slowStarted = deferred(), events = [];
  const urls = ['cached','fast','slow','failed'].map(value => imageUrl + '?' + value);
  const f = await fixture(async url => {
    if (url === urls[2]) { slowStarted.resolve(); await release.promise; }
    if (url === urls[3]) throw new Error('Synthetic failed resource');
    return image();
  });
  try {
    await f.cache.allow('a','message'); await f.cache.load('a','message',urls[0]);
    const observer = resource => { events.push(resource); if(resource.url === urls[1])fast.resolve(); };
    const pending = f.snapshot(urls,false,f.cache,'a','message',undefined,observer); let finished=false;
    pending.then(()=>{finished=true;}); await slowStarted.promise; await fast.promise;
    assert.equal(finished,false); assert.equal(events[0].url,urls[0]); assert.ok(events[0].picture);
    assert.ok(events.some(resource=>resource.url===urls[1]&&resource.picture));
    assert.ok(!events.some(resource=>resource.url===urls[2]));
    release.resolve(); const result=await pending;
    assert.equal(result.saved,true);assert.equal(events.length,4);assert.equal(new Set(events.map(value=>value.url)).size,4);
    assert.equal(events.find(value=>value.url===urls[3]).failure,'network');assert.equal(f.calls.length,4);
    const replay=[];await f.snapshot(urls,false,f.reopen(),'a','message',undefined,resource=>replay.push(resource));
    assert.equal(replay.length,4);assert.equal(f.calls.length,4);assert.equal(replay.find(value=>value.url===urls[3]).picture,null);
  } finally { release.resolve();await f.cache.whenIdle();f.close(); }
});

test('Detached or throwing progressive observers cannot cause retries or publish late canceled resources', async () => {
  const release=deferred(),started=deferred(),events=[];
  const f=await fixture(async()=>{started.resolve();await release.promise;return image();});
  try {
    let active=true;const scope={active:()=>active,deadline:Date.now()+30000};
    const pending=f.snapshot([imageUrl],false,f.cache,'a','message',scope,resource=>events.push(resource));
    await started.promise;active=false;f.cache.cancelPending('a','message');release.resolve();
    const cancelled=await pending;assert.equal(cancelled.cancelled,true);assert.equal(cancelled.saved,false);assert.deepEqual(events,[]);
    const resumed=await f.snapshot([imageUrl],false,f.cache,'a','message',undefined,()=>{throw new Error('Detached observer');});
    assert.equal(resumed.saved,true);assert.ok(resumed.resources[0].picture);assert.equal(f.calls.length,1);
  } finally { release.resolve();await f.cache.whenIdle();f.close(); }
});

test('A saved attempt survives picture expiry and never starts automatic network requests on reopen', async () => {
  const urls = [imageUrl, `${imageUrl}?missing`];
  const f = await fixture(async url => { if (url !== imageUrl) throw new Error('Synthetic offline'); return image(); });
  try {
    await f.snapshot(urls);
    assert.equal(f.calls.length, 2);
    f.sqlite.prepare('UPDATE picture_cache SET saved_at = ?').run(Date.now() - retention - 1);
    await f.initialize();
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 1);
    const reopened = await f.snapshot(urls, false, f.reopen());
    assert.equal(reopened.saved, true); assert.ok(reopened.resources.every(resource => resource.picture === null));
    assert.equal(f.calls.length, 2);
    await f.snapshot(urls, true); assert.equal(f.calls.length, 4, 'only explicit Retry can recover expired/missing resources');
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('A thirty-second attempt cutoff stops queued requests and remembers unattempted resources', async () => {
  const started = deferred(), release = deferred(), originalNow = Date.now;
  let clock = originalNow(), active = 0;
  const urls = Array.from({ length: 12 }, (_, index) => `${imageUrl}?deadline=${index}`);
  const f = await fixture(async () => { if (++active === 4) started.resolve(); await release.promise; return image(); });
  Date.now = () => clock;
  try {
    const pending = f.snapshot(urls); await started.promise;
    clock += 31000; release.resolve();
    const result = await pending;
    assert.equal(result.saved, true); assert.equal(result.cancelled, false); assert.equal(f.calls.length, 4);
    assert.equal(result.resources.filter(resource => resource.picture).length, 4);
    assert.ok(result.resources.slice(4).every(resource => resource.failure === 'network' && resource.status === 0));
    await f.snapshot(urls, false, f.reopen()); assert.equal(f.calls.length, 4);
    await f.snapshot(urls, true); assert.equal(f.calls.length, 12);
  } finally { Date.now = originalNow; release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Cancelled snapshots retain successful bytes without saving a completed attempt and resume cache-first', async () => {
  const started = deferred(), release = deferred(); let active = 0;
  const urls = Array.from({ length: 9 }, (_, index) => `${imageUrl}?cancelled=${index}`);
  const f = await fixture(async () => { if (++active === 4) started.resolve(); await release.promise; return image(); });
  try {
    const pending = f.snapshot(urls); await started.promise;
    f.cache.constructor.setForeground(false); release.resolve();
    const result = await pending;
    assert.equal(result.cancelled, true); assert.equal(result.saved, false); assert.equal(f.calls.length, 4);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 0);
    const saved = f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache ORDER BY url').all();
    assert.equal(saved.length, 4);
    const cacheOnly = await f.cache.readSnapshot('a', 'message', urls);
    assert.equal(cacheOnly.resources.filter(resource => resource.picture).length, 4, 'local reads do not require foreground');
    assert.equal(f.calls.length, 4);
    f.cache.constructor.setForeground(true);
    const resumed = await f.snapshot(urls);
    assert.equal(resumed.saved, true); assert.equal(resumed.cancelled, false); assert.equal(f.calls.length, 9);
    assert.deepEqual(f.sqlite.prepare('SELECT url, data, saved_at FROM picture_cache WHERE url <= ? ORDER BY url').all(urls[3]), saved);
  } finally { release.resolve(); f.cache.constructor.setForeground(true); await f.cache.whenIdle(); f.close(); }
});

test('Changed resource plans wait for their predecessor and explicit retry loads only their new missing URLs', async () => {
  const started = deferred(), release = deferred();
  const firstUrl = `${imageUrl}?one`, secondUrl = `${imageUrl}?two`;
  const f = await fixture(async () => { started.resolve(); await release.promise; return image(); });
  try {
    const first = f.snapshot([firstUrl]); await started.promise;
    const next = f.snapshot([firstUrl, secondUrl]); assert.notEqual(first, next);
    release.resolve(); await first;
    const result = await next;
    assert.deepEqual(result.resources.map(resource => resource.url), [firstUrl, secondUrl]);
    assert.ok(result.resources[0].picture); assert.equal(result.resources[1].picture, null);
    assert.equal(f.calls.length, 1, 'the saved attempt also prevents automatic downloads introduced by a changed plan');
    const retry = await f.snapshot([firstUrl, secondUrl], true);
    assert.ok(retry.resources.every(resource => resource.picture)); assert.equal(f.calls.length, 2);
  } finally { release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Snapshot cache-read failures never masquerade as an absent attempt or trigger network', async () => {
  const f = await fixture();
  try {
    await f.snapshot([imageUrl]); const query = f.db.querySql;
    f.db.querySql = async () => { throw new Error('Private synthetic database detail'); };
    for (const retry of [false, true]) {
      const result = await f.snapshot([imageUrl], retry);
      assert.equal(result.saved, false); assert.equal(result.resources[0].failure, 'storage');
      assert.equal(f.calls.length, 1); assert.equal(JSON.stringify(result).includes('Private synthetic'), false);
    }
    f.db.querySql = query;
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Unsaved manifest failures retain display bytes and cached successes without refetching them', async () => {
  const f = await fixture();
  try {
    f.sqlite.exec("CREATE TRIGGER reject_snapshot BEFORE INSERT ON picture_snapshot BEGIN SELECT RAISE(ABORT, 'Synthetic private manifest detail'); END");
    const result = await f.snapshot([imageUrl]);
    assert.equal(result.saved, false); assert.ok(result.resources[0].picture);
    assert.equal(f.calls.length, 1); assert.equal(JSON.stringify(result).includes('Synthetic private'), false);
    f.sqlite.exec('DROP TRIGGER reject_snapshot');
    const reopened = await f.snapshot([imageUrl], false, f.reopen());
    assert.equal(reopened.saved, true); assert.ok(reopened.resources[0].picture); assert.equal(f.calls.length, 1);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Native-style pooled readers see a committed manifest and whenIdle waits for its completion', async () => {
  const started = deferred(), release = deferred();
  const f = await fixture(async () => image(), { committedReads: true });
  const execute = f.db.executeSql;
  f.db.executeSql = async (sql, args) => {
    const result = await execute(sql, args);
    if (sql.startsWith('INSERT OR REPLACE INTO picture_snapshot')) { started.resolve(); await release.promise; }
    return result;
  };
  try {
    const pending = f.snapshot([imageUrl]); await started.promise;
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 0);
    let idle = false; const waiting = f.cache.whenIdle().then(() => { idle = true; });
    await Promise.resolve(); assert.equal(idle, false);
    release.resolve(); const result = await pending; await waiting;
    assert.equal(result.saved, true); assert.equal(f.reader.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 1);
    await f.snapshot([imageUrl], false, f.reopen()); assert.equal(f.calls.length, 1);
  } finally { release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Cancellation before manifest commit rolls back the marker while preserving downloaded bytes', async () => {
  const started = deferred(), release = deferred();
  const f = await fixture(async () => image(), { committedReads: true });
  const execute = f.db.executeSql;
  f.db.executeSql = async (sql, args) => {
    const result = await execute(sql, args);
    if (sql.startsWith('INSERT OR REPLACE INTO picture_snapshot')) { started.resolve(); await release.promise; }
    return result;
  };
  try {
    const pending = f.snapshot([imageUrl]); await started.promise;
    f.cache.cancelPending('a', 'message'); release.resolve();
    const result = await pending;
    assert.equal(result.cancelled, true); assert.equal(result.saved, false);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 1);
  } finally { release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Deleted accounts cannot save snapshots and account removal cleans up durable attempt markers', async () => {
  const started = deferred(), release = deferred();
  const f = await fixture(async () => { started.resolve(); await release.promise; return image(); });
  try {
    const pending = f.snapshot([imageUrl]); await started.promise;
    f.sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'; DELETE FROM picture_consent WHERE account_id = 'a'; DELETE FROM accounts WHERE id = 'a'");
    release.resolve(); await pending;
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_snapshot').get().n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM picture_cache').get().n, 0);
    const accountSource = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
    const cleanup = accountSource.slice(accountSource.indexOf('  remove(id: string)'), accountSource.indexOf('\n  close():'));
    assert.match(cleanup, /DELETE FROM picture_snapshot WHERE account_id = \?/);
  } finally { release.resolve(); await f.cache.whenIdle(); f.close(); }
});

test('Snapshot resource plans are capped and deduplicated before starting their bounded downloads', async () => {
  const f = await fixture();
  try {
    const urls = Array.from({ length: 300 }, (_, index) => `${imageUrl}?bounded=${index}`);
    const result = await f.snapshot([urls[0], urls[0], ...urls]);
    assert.equal(result.resources.length, 254);
    assert.equal(f.calls.length, 254);
    assert.equal(new Set(f.calls.map(call => call.url)).size, f.calls.length);
    assert.deepEqual(result.resources.map(resource => resource.url), urls.slice(0, 254));
    assert.equal(result.saved, true);
    await f.snapshot(urls, false, f.reopen());
    assert.equal(f.calls.length, 254, 'a later larger plan must not restart a completed attempt');
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Snapshot workers retain at most 64 MiB and report remaining resources as size failures', async () => {
  const f = await fixture();
  try {
    // Share a synthetic 8 MiB result across transport calls to exercise the
    // retained-byte accounting without allocating a full large newsletter.
    const data = new ArrayBuffer(8 * 1024 * 1024);
    new Uint8Array(data).set(png());
    let reads = 0;
    f.cache.loadForSnapshot = async () => {
      reads++;
      return { picture: { data, mimeType: 'image/png' }, failure: '', status: 0 };
    };
    const urls = Array.from({ length: 20 }, (_, index) => `${imageUrl}?memory=${index}`);
    const result = await f.snapshot(urls);
    assert.equal(result.saved, true);
    assert.equal(result.resources.filter(resource => resource.picture).length, 8);
    assert.equal(result.resources.reduce((total, resource) => total + (resource.picture?.data.byteLength || 0), 0), 64 * 1024 * 1024);
    assert.ok(result.resources.slice(8).every(resource => !resource.picture && resource.failure === 'size'));
    assert.ok(reads <= 11, 'only the at-most-four active workers can cross the memory threshold');
    assert.equal(f.calls.length, 0);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('Snapshot cache reads enforce the byte cap before copying additional RDB blobs', async () => {
  const f = await fixture();
  try {
    await f.cache.allow('a', 'message');
    const urls = Array.from({ length: 10 }, (_, index) => `${imageUrl}?cached-memory=${index}`);
    const insert = f.sqlite.prepare('INSERT INTO picture_cache VALUES (?, ?, ?, ?, ?, ?)');
    for (const url of urls) insert.run('a', 'message', url, 'image/png', Buffer.from(png()), Date.now());
    // The native result adapter exposes virtual lengths and a shared synthetic
    // blob; getBlob must never be called for the ninth/tenth cached resources.
    f.sqlite.function('length', () => 8 * 1024 * 1024);
    const blob = new Uint8Array(8 * 1024 * 1024); blob.set(png());
    let copies = 0;
    const query = f.db.querySql;
    f.db.querySql = async (sql, args) => {
      const rows = await query(sql, args);
      if (sql.startsWith('SELECT p.url, length(p.data)')) rows.getBlob = () => { copies++; return blob; };
      return rows;
    };
    const result = await f.cache.readSnapshot('a', 'message', urls);
    assert.equal(copies, 8); assert.equal(result.resources.filter(resource => resource.picture).length, 8);
    assert.ok(result.resources.slice(8).every(resource => !resource.picture && resource.failure === 'size'));
    assert.equal(f.calls.length, 0);
  } finally { await f.cache.whenIdle(); f.close(); }
});

test('A scoped scheduled job loads pictures while ordinary foreground requests remain blocked', async () => {
  const f = await fixture(); f.cache.constructor.setForeground(false);
  try {
    const scope = { active: () => true, deadline: Date.now() + 60000, permitted: async () => true };
    const result = await f.snapshot([imageUrl], false, f.cache, 'a', 'scheduled', scope);
    assert.equal(result.cancelled, false); assert.equal(result.saved, true); assert.equal(f.calls.length, 1);
    assert.equal(await f.cache.snapshotAttempted('a', 'scheduled'), true);
    await f.cache.allow('a', 'ordinary'); await f.cache.load('a', 'ordinary', imageUrl+'?ordinary');
    assert.equal(f.calls.length, 1, 'a job must not turn global foreground access on');
  } finally { f.cache.constructor.setForeground(true); await f.cache.whenIdle(); f.close(); }
});

test('Revoked job permission cancels rather than saving a failed attempt for pictures never requested', async () => {
  const f = await fixture(); f.cache.constructor.setForeground(false);
  try {
    const scope = { active: () => true, deadline: Date.now() + 60000, permitted: async () => false };
    const result = await f.snapshot([imageUrl], false, f.cache, 'a', 'message', scope);
    assert.equal(result.cancelled, true); assert.equal(result.saved, false); assert.equal(scope.revoked, true);
    assert.equal(f.calls.length, 0); assert.equal(await f.cache.snapshotAttempted('a', 'message'), false);
    f.cache.constructor.setForeground(true);
    const recovered = await f.snapshot([imageUrl]);
    assert.equal(recovered.saved, true); assert.equal(f.calls.length, 1);
  } finally { f.cache.constructor.setForeground(true); await f.cache.whenIdle(); f.close(); }
});

test('A stopped or expired scheduled scope creates no sockets or durable failure marker', async () => {
  for (const scope of [{ active: () => false, deadline: Date.now()+60000 }, { active: () => true, deadline: Date.now()-1 }]) {
    const f = await fixture(); f.cache.constructor.setForeground(false);
    try {
      const result=await f.snapshot([imageUrl],false,f.cache,'a','message',scope);
      assert.equal(result.cancelled,true);assert.equal(f.calls.length,0);assert.equal(await f.cache.snapshotAttempted('a','message'),false);
    } finally { f.cache.constructor.setForeground(true);await f.cache.whenIdle();f.close(); }
  }
});
