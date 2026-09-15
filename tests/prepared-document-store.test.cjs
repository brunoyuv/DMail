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
const fileModelModule = { exports: {} };
new Function('module', 'exports', compile('harmony/entry/src/main/ets/data/MailContentFileModel.ts'))(fileModelModule, fileModelModule.exports);
const modelModule = { exports: {} };
new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/PreparedDocumentModel.ts'))(name => {
  if (name === './MailContentFileModel') return fileModelModule.exports;
  throw new Error(`Unexpected model dependency ${name}`);
}, modelModule, modelModule.exports);
const textModule = { exports: {} };
new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/RdbText.ets'))(name => {
  if (name === '@kit.ArkTS') return { util: { TextDecoder: class extends TextDecoder {
    decodeToString(bytes) { return this.decode(bytes); }
  } } };
  throw new Error(`Unexpected text helper dependency ${name}`);
}, textModule, textModule.exports);
const storeModule = { exports: {} };
new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/PreparedDocumentStore.ets'))(name => {
  if (name === './PreparedDocumentModel') return modelModule.exports;
  if (name === './MailContentFileModel') return fileModelModule.exports;
  if (name === './RdbText') return textModule.exports;
  if (name === './MailCacheModel') return { MAIL_RETENTION_MS: retention,
    cacheIsFresh: (date, now = Date.now()) => date !== null && date <= now && now - date < retention };
  throw new Error(`Unexpected dependency ${name}`);
}, storeModule, storeModule.exports);
const { PreparedDocumentStore } = storeModule.exports;
const pictures = [{ id: 'https://mail.invalid/picture/0', url: 'https://images.example.test/image.png' }];
const html = '<!doctype html><html><body>Saved 中文 😀<img src="https://mail.invalid/picture/0"></body></html>';
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture({ committedReads = false, initialize = true, rowByteLimit = Infinity, fileMode = false } = {}) {
  const directory = committedReads ? fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-prepared-document-')) : null;
  const sqlite = new DatabaseSync(directory ? path.join(directory, 'synthetic.db') : ':memory:');
  if (committedReads) sqlite.exec('PRAGMA journal_mode=WAL');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready'), ('pending', 'pending')");
  const reader = committedReads ? new DatabaseSync(path.join(directory, 'synthetic.db'), { readOnly: true }) : sqlite;
  let closed = 0, writes = 0, largestRow = 0;
  const db = { version: 5,
    executeSql: async (sql, args = []) => { writes++; sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = reader.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      const accessible = () => {
        if (index >= rows.length) return false;
        const bytes = rows[index].reduce((sum, value) => sum + (typeof value === 'string' ? Buffer.byteLength(value) :
          value instanceof Uint8Array ? value.length : 8), 0);
        largestRow = Math.max(largestRow, bytes);
        if (bytes > rowByteLimit) throw Object.assign(new Error('Synthetic RDB row exceeds ResultSet block'), { code: 14800000 });
        return true;
      };
      return { goToFirstRow: () => { index = 0; return accessible(); }, goToNextRow: () => { index++; return accessible(); },
        getString: column => rows[index][column], getLong: column => rows[index][column], getBlob: column => rows[index][column], close() {} };
    },
    close: () => { closed++; }
  };
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  const fileState = { writes: 0, reads: 0, failWrite: false, afterWrite: null, afterRead: null, values: new Map() };
  const files = {
    async write(accountId, kind, content) {
      if (fileState.failWrite) throw new Error('Synthetic file write failed');
      const ref = `${accountId}/${require('node:crypto').randomUUID()}.${kind === 'html' ? 'html' : 'txt'}`;
      fileState.values.set(ref, content); fileState.writes++; await fileState.afterWrite?.(ref); return ref;
    },
    async read(accountId, ref, maxCharacters) {
      fileState.reads++;
      assert.ok(fileModelModule.exports.mailContentReferenceValid(accountId, ref));
      if (!fileState.values.has(ref)) throw new Error('Synthetic content file missing');
      const value = fileState.values.get(ref); assert.ok(value.length <= maxCharacters);
      await fileState.afterRead?.(ref); return value;
    },
    async forgetAccount() {}, async prune() {}
  };
  if (initialize) await PreparedDocumentStore.initialize(db);
  return { sqlite, reader, db, queue, files, fileState, store: new PreparedDocumentStore(db, queue, fileMode ? files : undefined),
    reopen: () => new PreparedDocumentStore(db, queue, fileMode ? files : undefined), writes: () => writes, closed: () => closed,
    largestRow: () => largestRow,
    close: () => { if (reader !== sqlite) reader.close(); sqlite.close(); if (directory) fs.rmSync(directory, { recursive: true }); } };
}

test('Prepared HTML persists independently of raw bodies and picture bytes, ready before any picture attempt', async () => {
  const f = await fixture();
  try {
    const now = Date.now(), map = structuredClone(pictures);
    const saved = await f.store.save('a', 'message', html, map, now);
    map[0].url = 'https://changed.example.test/';
    assert.equal(saved.attempted, true); assert.equal(saved.failure, '');
    assert.equal(saved.document.html, html); assert.deepEqual(saved.document.pictures, pictures);
    assert.equal(saved.document.bodySavedAt, now); assert.equal(saved.bodySavedAt, now);
    assert.deepEqual(await f.reopen().read('a', 'message'), saved);
    assert.deepEqual(await f.store.read('b', 'message'), { attempted: false, document: null, bodySavedAt: null, failure: '' });
    assert.equal(f.sqlite.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name LIKE 'picture_%'").get().n, 0);
    assert.equal(f.sqlite.prepare('PRAGMA table_info(prepared_documents)').all().some(column => column.type === 'BLOB'), false);
  } finally { f.close(); }
});

test('Large Unicode prepared HTML survives native-sized ResultSet rows, separate WAL readers and reopen', async () => {
  const f = await fixture({ committedReads: true, rowByteLimit: 2 * 1024 * 1024 });
  try {
    const now = Date.now(), largeHtml = '<html><body>' + 'Physics 中文 😀\n'.repeat(350000) + '</body></html>';
    assert.ok(Buffer.byteLength(largeHtml) > 6 * 1024 * 1024);
    const saved = await f.store.save('a', 'large', largeHtml, pictures, now);
    assert.equal(saved.document.html, largeHtml);
    assert.deepEqual(await f.reopen().read('a', 'large'), saved);
    assert.deepEqual(await f.reopen().save('a', 'large', '<p>Must remain immutable</p>', [], now + 1), saved);
    assert.ok(f.largestRow() < 2 * 1024 * 1024, 'every returned native row stays below the byte limit');
  } finally { f.close(); }
});

test('Expired and failed document metadata stays readable without transferring oversized unused payloads', async () => {
  const f = await fixture({ rowByteLimit: 2 * 1024 * 1024 });
  try {
    const now = Date.now(), oversized = 'x'.repeat(3 * 1024 * 1024);
    f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'failed-large', now, 'failed', oversized);
    f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'expired-large', now - retention, 'ready', oversized);
    assert.equal((await f.store.read('a', 'failed-large')).failure, 'failed');
    assert.equal((await f.store.read('a', 'expired-large')).failure, 'expired');
    assert.ok(f.largestRow() < 1024);
  } finally { f.close(); }
});

test('Twenty full pictures and Unicode persist in one immutable HTML file with small database metadata', async () => {
  const f = await fixture({ committedReads: true, rowByteLimit: 2 * 1024 * 1024, fileMode: true });
  try {
    const imageHtml = Array.from({ length: 20 }, (_, index) => '<figure><img src="data:image/png;base64,' +
      fs.readFileSync(`port/swift-smtp/picture-scroll/picture-${index}.png`).toString('base64') +
      `" width="800" height="450"><figcaption>物理学通讯 café 😀 ${index}</figcaption></figure>`).join('');
    const largeHtml = '<html><body>' + imageHtml + '<p>Unicode 中文 😀</p>'.repeat(12000) + '</body></html>';
    assert.ok(Buffer.byteLength(largeHtml) > 6 * 1024 * 1024);
    const now = Date.now(), saved = await f.store.save('a', 'pictures', largeHtml, pictures, now);
    const payload = f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload;
    const record = JSON.parse(payload);
    assert.ok(Buffer.byteLength(payload) < 1024); assert.equal(record.html, undefined);
    assert.match(record.htmlFile, /^a\/[a-f0-9-]+\.html$/);
    assert.equal(f.fileState.values.get(record.htmlFile), largeHtml);
    assert.deepEqual(saved.document.pictures, pictures); assert.equal(saved.document.html, largeHtml);
    assert.deepEqual(await f.reopen().read('a', 'pictures'), saved);
    assert.deepEqual(await f.reopen().save('a', 'pictures', '<p>Unwanted replacement</p>', [], now), saved);
    assert.equal(f.fileState.writes, 1); assert.equal(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload, payload);
    assert.ok(f.largestRow() < 1024);
  } finally { f.close(); }
});

test('Legacy large inline HTML migrates once after a complete file write, preserving original metadata and pictures', async () => {
  const f = await fixture({ committedReads: true, rowByteLimit: 2 * 1024 * 1024, fileMode: true });
  try {
    const now = Date.now(), legacy = { version: 1, messageKey: 'legacy', bodySavedAt: now - 1000, savedAt: now - 500,
      html: '<p>' + 'Saved 中文 😀'.repeat(350000) + '</p>', pictures };
    const payload = modelModule.exports.encodePreparedDocument(legacy);
    f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'legacy', legacy.bodySavedAt, 'ready', payload);
    assert.ok(Buffer.byteLength(payload) > 2 * 1024 * 1024);
    const loaded = await f.store.read('a', 'legacy'); assert.deepEqual(loaded.document, legacy);
    const migrated = JSON.parse(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload);
    assert.equal(migrated.html, undefined); assert.equal(migrated.bodySavedAt, legacy.bodySavedAt);
    assert.equal(migrated.savedAt, legacy.savedAt); assert.deepEqual(migrated.pictures, pictures);
    assert.equal(f.fileState.values.get(migrated.htmlFile), legacy.html);
    assert.deepEqual(await f.reopen().read('a', 'legacy'), loaded); assert.equal(f.fileState.writes, 1);
  } finally { f.close(); }
});

test('Missing completed HTML files stay errors and do not replace the document or repeat picture preparation', async () => {
  const f = await fixture({ fileMode: true });
  try {
    const now = Date.now(); await f.store.save('a', 'message', html, pictures, now);
    const payload = f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload;
    f.fileState.values.clear();
    await assert.rejects(f.reopen().read('a', 'message'), /storage is unavailable/);
    await assert.rejects(f.store.save('a', 'message', '<p>Replacement</p>', [], now), /storage is unavailable/);
    assert.equal(f.fileState.writes, 1); assert.equal(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload, payload);
  } finally { f.close(); }
});

test('A held HTML file read cannot publish after another WAL handle deletes its account or replaces its reference', async () => {
  for (const remove of [false, true]) {
    const f = await fixture({ committedReads: true, fileMode: true });
    const entered = deferred(), release = deferred();
    try {
      await f.store.save('a', 'message', html, pictures, Date.now());
      const record = JSON.parse(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload);
      const reads = f.fileState.reads;
      f.fileState.afterRead = async () => { entered.resolve(); await release.promise; };
      const rejected = assert.rejects(f.reopen().read('a', 'message'), /storage is unavailable/);
      await entered.promise;
      if (remove) f.sqlite.exec("DELETE FROM accounts WHERE id='a'");
      else {
        const reference = await f.files.write('a', 'html', '<p>New committed HTML</p>');
        f.sqlite.prepare('UPDATE prepared_documents SET payload=?').run(JSON.stringify({ ...record, htmlFile: reference }));
      }
      release.resolve(); await rejected;
      assert.equal(f.fileState.reads, reads + 1, 'the rejected read does not loop or rehydrate a winner');
    } finally { release.resolve(); f.close(); }
  }
});

test('Migration failure fallback cannot publish legacy HTML after concurrent account deletion or document replacement', async () => {
  for (const remove of [false, true]) {
    const f = await fixture({ committedReads: true, fileMode: true });
    const entered = deferred(), release = deferred();
    try {
      const now = Date.now(), legacy = { version: 1, messageKey: 'legacy', bodySavedAt: now, savedAt: now, html, pictures };
      f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)')
        .run('a', 'legacy', now, 'ready', modelModule.exports.encodePreparedDocument(legacy));
      f.fileState.afterWrite = async () => {
        entered.resolve(); await release.promise; throw new Error('Synthetic late file write failure');
      };
      const rejected = assert.rejects(f.store.read('a', 'legacy'), /storage is unavailable/);
      await entered.promise;
      if (remove) f.sqlite.exec("DELETE FROM accounts WHERE id='a'");
      else f.sqlite.prepare('UPDATE prepared_documents SET payload=?')
        .run(modelModule.exports.encodePreparedDocument({ ...legacy, html: '<p>New committed snapshot</p>' }));
      release.resolve(); await rejected;
      assert.equal(f.fileState.writes, 1); assert.equal(f.fileState.reads, 0);
    } finally { release.resolve(); f.close(); }
  }
});

test('File write failures preserve legacy inline HTML and never commit a dangling fresh reference', async () => {
  const f = await fixture({ fileMode: true });
  try {
    const now = Date.now(), legacy = { version: 1, messageKey: 'legacy', bodySavedAt: now, savedAt: now, html, pictures };
    const payload = modelModule.exports.encodePreparedDocument(legacy);
    f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'legacy', now, 'ready', payload);
    f.fileState.failWrite = true;
    assert.deepEqual((await f.store.read('a', 'legacy')).document, legacy);
    assert.equal(f.sqlite.prepare("SELECT payload FROM prepared_documents WHERE message_key='legacy'").get().payload, payload);
    await assert.rejects(f.store.save('a', 'fresh', html, pictures, now), /storage is unavailable/);
    assert.equal(f.sqlite.prepare("SELECT count(*) n FROM prepared_documents WHERE message_key='fresh'").get().n, 0);
    assert.equal(f.fileState.writes, 0);
  } finally { f.close(); }
});

test('A failed migration reference commit returns the valid original snapshot and preserves its picture mapping', async () => {
  const f = await fixture({ fileMode: true });
  try {
    const now = Date.now(), legacy = { version: 1, messageKey: 'legacy', bodySavedAt: now, savedAt: now, html, pictures };
    const payload = modelModule.exports.encodePreparedDocument(legacy);
    f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'legacy', now, 'ready', payload);
    f.sqlite.exec("CREATE TRIGGER reject_migration BEFORE UPDATE ON prepared_documents BEGIN SELECT RAISE(ABORT, 'Synthetic reference write failure'); END");
    assert.deepEqual((await f.store.read('a', 'legacy')).document, legacy);
    assert.equal(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload, payload);
    assert.equal(f.fileState.writes, 1);
  } finally { f.close(); }
});

test('A legacy migration cannot overwrite a concurrently changed document or resurrect a removed account', async () => {
  for (const remove of [false, true]) {
    const f = await fixture({ committedReads: true, fileMode: true });
    try {
      const now = Date.now(), legacy = { version: 1, messageKey: 'legacy', bodySavedAt: now, savedAt: now, html, pictures };
      const payload = modelModule.exports.encodePreparedDocument(legacy);
      f.sqlite.prepare('INSERT INTO prepared_documents VALUES (?, ?, ?, ?, ?)').run('a', 'legacy', now, 'ready', payload);
      const winner = { ...legacy, html: '<p>Concurrent committed winner</p>' };
      f.fileState.afterWrite = () => {
        if (remove) f.sqlite.exec("UPDATE accounts SET status='deleting' WHERE id='a'");
        else f.sqlite.prepare('UPDATE prepared_documents SET payload=?').run(modelModule.exports.encodePreparedDocument(winner));
      };
      const loaded = await f.store.read('a', 'legacy');
      if (remove) {
        assert.equal(loaded.attempted, false);
        assert.equal(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload, payload);
      } else {
        assert.deepEqual(loaded.document, winner);
        assert.equal(JSON.parse(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload).html, winner.html);
      }
      assert.equal(f.fileState.writes, 1);
    } finally { f.close(); }
  }
});

test('File records reject traversal, dual body sources, wrong extensions and other account ownership', async () => {
  const f = await fixture({ fileMode: true });
  try {
    const now = Date.now(); await f.store.save('a', 'message', html, pictures, now);
    const record = JSON.parse(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload);
    for (const patch of [{ htmlFile: '../secret.html' }, { html: '<p>Dual</p>' },
      { htmlFile: record.htmlFile.replace('.html', '.txt') }, { htmlFile: record.htmlFile.replace(/^a\//, 'b/') }]) {
      f.sqlite.prepare('UPDATE prepared_documents SET payload=?').run(JSON.stringify({ ...record, ...patch }));
      await assert.rejects(f.store.read('a', 'message'), /storage is unavailable/);
    }
    assert.equal(f.fileState.writes, 1);
  } finally { f.close(); }
});

test('Fresh documents and explicit failed attempts stay frozen across sync, reopen, and competing results', async () => {
  const f = await fixture();
  try {
    const now = Date.now(), first = await f.store.save('a', 'message', html, pictures, now - 1000);
    assert.deepEqual(await f.reopen().save('a', 'message', '<p>Changed</p>', [], now), first);
    assert.deepEqual(await f.store.fail('a', 'message', now), first);
    const failed = await f.store.fail('a', 'failed', now);
    assert.deepEqual(failed, { attempted: true, document: null, bodySavedAt: now, failure: 'failed' });
    assert.deepEqual(await f.reopen().save('a', 'failed', html, pictures, now), failed);
    assert.deepEqual(await f.store.read('a', 'failed'), failed);
  } finally { f.close(); }
});

test('Retention uses original body download time and only a newer downloaded body replaces expired markup', async () => {
  const f = await fixture();
  const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    const bodyTime = clock - retention + 1000;
    await f.store.save('a', 'message', html, pictures, bodyTime);
    clock += 1001;
    const expired = await f.store.read('a', 'message');
    assert.deepEqual(expired, { attempted: true, document: null, bodySavedAt: bodyTime, failure: 'expired' });
    await PreparedDocumentStore.initialize(f.db);
    assert.equal(f.sqlite.prepare('SELECT payload FROM prepared_documents').get().payload, '');
    assert.deepEqual(await f.reopen().read('a', 'message'), expired);
    await assert.rejects(f.store.save('a', 'message', '<p>Old body</p>', [], bodyTime));
    const renewed = await f.store.save('a', 'message', '<p>Newly downloaded</p>', [], clock);
    assert.equal(renewed.document.html, '<p>Newly downloaded</p>'); assert.equal(renewed.bodySavedAt, clock);
    assert.deepEqual(await f.store.save('a', 'message', '<p>Stale completion</p>', [], clock - 1), renewed);
  } finally { Date.now = originalNow; f.close(); }
});

test('An expired failed marker can be replaced by a newly downloaded body, while future timestamps cannot', async () => {
  const f = await fixture();
  const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    await f.store.fail('a', 'message', clock); clock += retention;
    assert.equal((await f.store.read('a', 'message')).failure, 'expired');
    assert.equal((await f.store.save('a', 'message', html, pictures, clock)).document.html, html);
    await assert.rejects(f.store.save('a', 'future', html, pictures, clock + 1));
  } finally { Date.now = originalNow; f.close(); }
});

test('Clock rollback repairs invalid future documents once without replacing the fresh committed repair', async () => {
  const f = await fixture({ committedReads: true });
  const originalNow = Date.now; let clock = originalNow(); Date.now = () => clock;
  try {
    const future = clock + 3600000;
    for (const state of ['ready', 'failed', 'expired']) {
      f.sqlite.prepare('INSERT INTO prepared_documents (account_id, message_key, body_saved_at, state, payload) VALUES (?, ?, ?, ?, ?)')
        .run('a', state, future, state, '');
      assert.equal((await f.reopen().read('a', state)).failure, 'expired');
      const repaired = await f.store.save('a', state, html, pictures, clock - 1000);
      assert.equal(repaired.document.html, html); assert.equal(repaired.bodySavedAt, clock - 1000);
      assert.deepEqual(await f.reopen().save('a', state, '<p>Later sync</p>', [], clock), repaired);
      assert.deepEqual(await f.reopen().fail('a', state, clock), repaired);
    }
    await assert.rejects(f.store.save('a', 'new-future', html, pictures, clock + 1));
  } finally { Date.now = originalNow; f.close(); }
});

test('Atomic first-writer persistence is visible to independent committed WAL readers', async () => {
  const f = await fixture({ committedReads: true });
  try {
    const now = Date.now();
    // Separate queues model independently opened workers sharing the database.
    const other = new PreparedDocumentStore(f.db, operation => operation());
    const [first, second] = await Promise.all([
      f.store.save('a', 'message', '<p>First</p>', pictures, now),
      other.save('a', 'message', '<p>Second</p>', pictures, now)
    ]);
    assert.deepEqual(first, second);
    assert.ok(['<p>First</p>', '<p>Second</p>'].includes(first.document.html));
    assert.equal(f.reader.prepare('SELECT count(*) AS n FROM prepared_documents').get().n, 1);
    assert.deepEqual(await f.reopen().read('a', 'message'), first);
  } finally { f.close(); }
});

test('Pending/deleting accounts are hidden and cannot resurrect saved prepared documents', async () => {
  const f = await fixture();
  try {
    const now = Date.now();
    assert.equal((await f.store.save('pending', 'message', html, pictures, now)).attempted, false);
    await f.store.save('a', 'message', html, pictures, now);
    f.sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'");
    assert.equal((await f.store.read('a', 'message')).attempted, false);
    await f.store.save('a', 'new', html, pictures, now);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM prepared_documents').get().n, 1);
    f.sqlite.exec("DELETE FROM accounts WHERE id = 'a'");
    await PreparedDocumentStore.initialize(f.db);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM prepared_documents').get().n, 0);
  } finally { f.close(); }
});

test('Storage failures and corrupt records are errors, never missing documents or silent rescan permission', async () => {
  const f = await fixture();
  try {
    const now = Date.now(); await f.store.save('a', 'message', html, pictures, now);
    const query = f.db.querySql;
    f.db.querySql = async () => { throw new Error('Synthetic database unavailable'); };
    await assert.rejects(f.store.read('a', 'message'));
    f.db.querySql = query;
    for (const payload of ['not JSON', 'null', '{"version":999}', JSON.stringify({ version: 1, messageKey: 'wrong' })]) {
      f.sqlite.prepare('UPDATE prepared_documents SET payload = ?').run(payload);
      await assert.rejects(f.store.read('a', 'message'), /Prepared document storage is unavailable/);
    }
    f.sqlite.exec("CREATE TRIGGER reject_prepared BEFORE INSERT ON prepared_documents BEGIN SELECT RAISE(ABORT, 'Synthetic failed write'); END");
    await assert.rejects(f.store.fail('a', 'missing', now));
    assert.equal((await f.store.read('a', 'missing')).attempted, false);
  } finally { f.close(); }
});

test('Prepared models enforce bounded HTML/resource identities and preserve Unicode without inspecting HTML', () => {
  const { encodePreparedDocument, decodePreparedDocument, MAX_PREPARED_HTML } = modelModule.exports;
  const document = { version: 1, messageKey: 'message', bodySavedAt: 1, savedAt: 2, html, pictures };
  assert.deepEqual(decodePreparedDocument(encodePreparedDocument(document), 'message'), document);
  for (const patch of [
    { version: 2 }, { html: 'x'.repeat(MAX_PREPARED_HTML + 1) }, { bodySavedAt: -1 },
    { pictures: Array.from({ length: 257 }, (_, i) => ({ id: `https://mail.invalid/picture/${i}`, url: `https://example.test/${i}` })) },
    { pictures: [pictures[0], pictures[0]] },
    { pictures: [{ id: 'https://remote.example.test/image', url: pictures[0].url }] },
    { pictures: [{ id: pictures[0].id, url: 'https://username:password@example.test/image' }] }
  ]) assert.throws(() => encodePreparedDocument({ ...document, ...patch }), /Prepared document storage is invalid/);
  const unusual = { ...document, html: '<a '.repeat(50000) + '文' };
  assert.equal(decodePreparedDocument(encodePreparedDocument(unusual), 'message').html, unusual.html);
});

function accountStore(f) {
  const module = { exports: {} };
  class Cache { static async initialize() { throw new Error('Background must not initialize caches'); } async whenIdle() {} }
  new Function('require', 'module', 'exports', compile('harmony/entry/src/main/ets/data/AccountStore.ets'))(name => {
    if (name === '@kit.ArkData') return { relationalStore: { getRdbStore: async () => f.db, SecurityLevel: { S3: 3 } } };
    if (name === './MailCache') return { MailCache: Cache };
    if (name === './MailContentFiles') return { MailContentFiles: class {
      write(...args) { return f.files.write(...args); } read(...args) { return f.files.read(...args); }
      async prune() {} async forgetAccount() {}
    } };
    if (name === './PictureCache') return { PictureCache: Cache };
    if (name === './PreparedDocumentStore') return storeModule.exports;
    if (name === './MailSyncStore') return { MailSyncStore: Cache };
    if (name === './NotificationStore') return { NotificationStore: class {} };
    if (name === './UnreadBadgeStore') return { UnreadBadgeStore: class {} };
    if (name.endsWith('/NativeBrowserOAuth')) return { NativeBrowserOAuth: class {} };
    return {};
  }, module, module.exports);
  return new module.exports.AccountStore('synthetic.db');
}

function backgroundTables(f) {
  f.sqlite.exec('CREATE TABLE oauth_credentials (id TEXT); CREATE TABLE mail_notifications (id TEXT); CREATE TABLE mail_check_lease (id TEXT); CREATE TABLE oauth_refresh_lease (id TEXT)');
}

test('Background opening attaches existing cache stores without migrations/pruning and detects legacy missing tables', async () => {
  for (const available of [false, true]) {
    const f = await fixture({ initialize: available });
    try {
      backgroundTables(f);
      if (available) f.sqlite.exec('CREATE TABLE mail_cache (id TEXT); CREATE TABLE picture_cache (id TEXT); CREATE TABLE picture_consent (id TEXT); CREATE TABLE picture_snapshot (id TEXT); CREATE TABLE mail_sync_jobs (id TEXT); CREATE TABLE mail_sync_cursors (id TEXT)');
      const writes = f.writes(); const store = accountStore(f);
      await store.openForMailChecks({ cacheDir: '/synthetic' });
      assert.equal(store.mailSyncAvailable, available); assert.equal(f.writes(), writes);
      if (available) assert.equal((await store.documents.read('a', 'missing')).attempted, false);
      else assert.throws(() => store.documents, /unavailable/);
      await store.close(); assert.equal(store.mailSyncAvailable, false); assert.equal(f.closed(), 1);
    } finally { f.close(); }
  }
});

test('Account close drains tracked mail sync before closing storage and cleanup includes prepared documents', async () => {
  const f = await fixture(); const gate = deferred();
  try {
    backgroundTables(f);
    f.sqlite.exec('CREATE TABLE mail_cache (id TEXT); CREATE TABLE picture_cache (id TEXT); CREATE TABLE picture_consent (id TEXT); CREATE TABLE picture_snapshot (id TEXT)');
    const store = accountStore(f); await store.openForMailChecks({ cacheDir: '/synthetic' });
    const work = gate.promise.then(async () => { await store.documents.save('a', 'message', html, pictures, Date.now()); });
    store.trackMailSync(work);
    const closing = store.close(); await Promise.resolve(); await Promise.resolve();
    assert.equal(f.closed(), 0); gate.resolve(); await closing;
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM prepared_documents').get().n, 1);
    assert.equal(f.closed(), 1);
    const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
    assert.match(source.slice(source.indexOf('  remove(id: string)'), source.indexOf('\n  close():')), /DELETE FROM prepared_documents WHERE account_id = \?/);
  } finally { gate.resolve(); f.close(); }
});
