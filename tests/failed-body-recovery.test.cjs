const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

async function fixture({ nativeWindowLimit = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-failed-body-'));
  const sqlite = new DatabaseSync(path.join(directory, 'cache.db')); sqlite.exec('PRAGMA journal_mode=WAL');
  const reader = new DatabaseSync(path.join(directory, 'cache.db'), { readOnly: true });
  sqlite.exec("CREATE TABLE accounts(id TEXT PRIMARY KEY,status TEXT);INSERT INTO accounts VALUES('a','ready'),('b','ready')");
  const state = { candidateQueries: 0, candidateSizes: [], readsInTransaction: 0, beforeBegin: null, failCommit: false };
  let inTransaction = false;
  const db = {
    executeSql: async (sql, args = []) => sqlite.prepare(sql).run(...args),
    querySql: async (sql, args = []) => {
      if (inTransaction) state.readsInTransaction++;
      const statement = reader.prepare(sql); statement.setReturnArrays(true); const rows = statement.all(...args); let index = -1;
      if (nativeWindowLimit && rows.some(row => row.reduce((bytes, value) => bytes +
        (typeof value === 'string' ? Buffer.byteLength(value) : value instanceof Uint8Array ? value.byteLength : 8), 0) > 2 * 1024 * 1024)) {
        throw new Error('Synthetic RDB shared row exceeds two MiB');
      }
      if (sql.includes('instr(c.payload')) { state.candidateQueries++; state.candidateSizes.push(rows.length); }
      return { goToFirstRow: () => { index = 0; return rows.length > 0; }, goToNextRow: () => ++index < rows.length,
        getString: column => rows[index][column], getLong: column => rows[index][column], getBlob: column => rows[index][column], close() {} };
    },
    beginTransaction: () => { state.beforeBegin?.(); sqlite.exec('BEGIN IMMEDIATE'); inTransaction = true; },
    commit: () => { if (state.failCommit) { state.failCommit = false; throw new Error('fixture interrupted commit'); }
      sqlite.exec('COMMIT'); inTransaction = false; },
    rollBack: () => { sqlite.exec('ROLLBACK'); inTransaction = false; }
  };
  const modules = new Map();
  function load(file) {
    file = path.resolve(file); if (modules.has(file)) return modules.get(file);
    const value = { exports: {} }; modules.set(file, value.exports);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    new Function('require', 'module', 'exports', code)(name => {
      if (name === '@kit.ArkData') return { relationalStore: {} };
      if (name === '@kit.ArkTS') return { util: { TextDecoder: class extends TextDecoder {
        decodeToString(bytes) { return this.decode(bytes); }
      } } };
      assert.ok(name.startsWith('.'), name); const base = path.resolve(path.dirname(file), name);
      return load(fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets');
    }, value, value.exports); return value.exports;
  }
  const base = 'harmony/entry/src/main/ets/';
  const { MailSyncStore } = load(base + 'data/MailSyncStore.ets');
  const { MailCache } = load(base + 'data/MailCache.ets');
  const { PreparedDocumentStore } = load(base + 'data/PreparedDocumentStore.ets');
  const { recoverFailedEmptyBodies } = load(base + 'data/MailSyncRecovery.ets');
  const { stableMessageKey } = load(base + 'mail/Conversation.ts');
  const html = load(base + 'mail/html/HtmlDocument.ts');
  const classification = load(base + 'data/MailCacheModel.ts');
  const snapshots = load(base + 'data/FailedBodyRecovery.ts');
  let tail = Promise.resolve(); const queue = operation => { const task = tail.catch(() => {}).then(operation); tail = task.catch(() => {}); return task; };
  // Represent an old database before the new repair marker exists.
  await MailSyncStore.initialize(db); await MailCache.initialize(db); await PreparedDocumentStore.initialize(db);
  const sync = new MailSyncStore(db, queue), cache = new MailCache(db, queue), documents = new PreparedDocumentStore(db, queue);
  const empty = html.preparedMailDocument(html.plainTextMailHtml(''), false, 0).replace('img-src data:;', 'img-src data: https://mail.invalid;');
  const oldEmpty = empty.replace('iframe,object,embed,input,', 'iframe,object,embed,form,input,');
  async function seed(mail, markup = oldEmpty, pictures = []) {
    await cache.saveEmail('a', mail); const saved = await cache.email('a', mail.id, true);
    await sync.enqueue('a', [mail]); await documents.save('a', stableMessageKey(mail), markup, pictures, saved.bodySavedAt);
    await sync.markPictures('a', mail.id, saved.bodySavedAt, stableMessageKey(mail)); await sync.complete('a', mail.id);
    return saved;
  }
  return { sqlite, reader, state, cache, sync, documents, classification, snapshots, stableMessageKey, empty, oldEmpty, seed,
    recover: () => recoverFailedEmptyBodies(db),
    row: id => JSON.parse(reader.prepare("SELECT payload FROM mail_cache WHERE account_id='a' AND kind='email' AND cache_key=?").get(id).payload),
    job: id => reader.prepare("SELECT * FROM mail_sync_jobs WHERE account_id='a' AND email_id=?").get(id),
    close: () => { reader.close(); sqlite.close(); fs.rmSync(directory, { recursive: true }); } };
}

const mail = (id, fields = {}) => ({ id, threadId: id, mailboxIds: ['inbox'], messageIds: [id + '@example.test'],
  keywords: [], from: [], to: [], replyTo: [], subject: 'Correct title', preview: 'Correct summary', receivedAt: 1000,
  hasAttachment: false, bodyEncodingProblem: true, bodyTruncated: false, hasHtmlBody: false,
  textBody: null, htmlBody: null, ...fields });

test('Only explicit decoder failure with both bodies absent is retryable; valid empty, attachment-only and partial bodies remain complete', async () => {
  const f = await fixture();
  try {
    assert.equal(f.classification.failedEmptyMailBody(mail('failed')), true);
    for (const fields of [{ bodyEncodingProblem: false }, { textBody: '' }, { htmlBody: '' },
      { textBody: '', hasAttachment: true, attachments: [{ id: '2', name: 'file.pdf', contentType: 'application/pdf', size: 10, sizeIsEncoded: true }] },
      { textBody: 'Readable partial body', bodyTruncated: true }, { htmlBody: '<p>Readable partial HTML</p>' }]) {
      assert.equal(f.classification.failedEmptyMailBody(mail('valid', fields)), false);
    }
  } finally { f.close(); }
});

test('One bounded upgrade pass repairs old DONE blank bodies even after a real header refresh, retaining headers and picture attempts', async () => {
  const f = await fixture();
  try {
    for (let i = 0; i < 19; i++) await f.seed(mail('bad-' + i), i % 2 ? f.empty : f.oldEmpty);
    const headers = Array.from({ length: 19 }, (_, i) => mail('bad-' + i, { bodyEncodingProblem: false, keywords: ['$seen'] }));
    await f.cache.saveView('a', 'inbox', headers, null, 'cursor');
    assert.equal(f.row('bad-0').mail.bodyEncodingProblem, true, 'header refresh retains cached decoding state');
    f.sqlite.exec("CREATE TABLE picture_snapshot (account_id TEXT, message_key TEXT, attempted INTEGER);INSERT INTO picture_snapshot VALUES('a','untouched',1)");
    f.state.readsInTransaction = 0;
    await f.recover();
    assert.ok(Math.max(...f.state.candidateSizes) <= 8);
    assert.equal(f.state.readsInTransaction, 0, 'pooled reads observe committed state only');
    for (let i = 0; i < 19; i++) {
      const row = f.row('bad-' + i); assert.equal(row.bodySavedAt, null);
      assert.equal(row.mail.subject, 'Correct title'); assert.equal(row.mail.preview, 'Correct summary');
      assert.deepEqual(row.mail.keywords, ['$seen']); assert.equal(f.job('bad-' + i).stage, 'body');
      assert.equal(await f.cache.email('a', 'bad-' + i, true), null);
      assert.equal((await f.documents.read('a', f.stableMessageKey(row.mail))).document, null);
    }
    assert.equal(f.reader.prepare('SELECT attempted FROM picture_snapshot').get().attempted, 1);
    const queries = f.state.candidateQueries;
    await f.recover(); assert.equal(f.state.candidateQueries, queries, 'later launches never scan completed bodies again');
  } finally { f.close(); }
});

test('Repair preserves legitimate empty bodies, usable partial bodies, and valid shared Message-ID documents', async () => {
  const f = await fixture();
  try {
    for (const [id, fields] of [['empty', { textBody: '', bodyEncodingProblem: false }],
      ['attachment-only', { textBody: '', bodyEncodingProblem: false, hasAttachment: true, attachments: [] }],
      ['partial', { textBody: 'Saved partial body', bodyTruncated: true }], ['html', { htmlBody: '<p>Saved HTML</p>' }]]) {
      await f.seed(mail(id, fields), '<p>Saved document for ' + id + '</p>');
    }
    const shared = mail('failed-copy'); await f.seed(shared, '<p>Valid shared Message-ID snapshot</p>');
    const before = f.reader.prepare("SELECT message_key,payload FROM prepared_documents ORDER BY message_key").all();
    await f.recover();
    assert.deepEqual(f.reader.prepare("SELECT message_key,payload FROM prepared_documents ORDER BY message_key").all(), before);
    for (const id of ['empty', 'attachment-only', 'partial', 'html']) {
      assert.notEqual(f.row(id).bodySavedAt, null); assert.equal(f.job(id).stage, 'done');
    }
    assert.equal(f.row('failed-copy').bodySavedAt, null); assert.equal(f.job('failed-copy').stage, 'body');
  } finally { f.close(); }
});

test('Failed-empty snapshot classification requires exact known markup, original timestamp and no picture map', async () => {
  const f = await fixture();
  try {
    const doc = { bodySavedAt: 100, html: f.oldEmpty, pictures: [] };
    assert.equal(f.snapshots.failedEmptyPreparedDocument(doc, 100), true);
    for (const variant of [{ ...doc, bodySavedAt: 101 }, { ...doc, html: doc.html + '<p>Saved</p>' },
      { ...doc, pictures: [{ id: 'saved', url: 'https://example.test/p.png' }] }]) {
      assert.equal(f.snapshots.failedEmptyPreparedDocument(variant, 100), false);
    }
  } finally { f.close(); }
});

test('Interrupted repair rolls back job, document and body timestamp together and resumes without losing prior backoff', async () => {
  const f = await fixture();
  try {
    const source = mail('interrupted'); await f.seed(source); const before = f.row(source.id);
    f.state.failCommit = true; await assert.rejects(f.recover(), /could not be saved/);
    assert.deepEqual(f.row(source.id), before); assert.equal(f.job(source.id).stage, 'done');
    assert.notEqual((await f.documents.read('a', f.stableMessageKey(source))).document, null);
    assert.equal(f.reader.prepare('SELECT count(*) n FROM mail_sync_repairs').get().n, 0);
    await f.sync.requeueBody('a', source.id); // DONE remains protected.
    f.sqlite.prepare("UPDATE mail_sync_jobs SET stage='body',attempts=3,retry_at=? WHERE email_id=?").run(Date.now() + 60000, source.id);
    const retry = f.job(source.id).retry_at; await f.recover();
    assert.equal(f.job(source.id).attempts, 3); assert.equal(f.job(source.id).retry_at, retry);
    assert.equal(f.row(source.id).bodySavedAt, null);
  } finally { f.close(); }
});

test('A successful concurrent body/document replacement or account removal defeats stale recovery writes', async () => {
  for (const removed of [false, true]) {
    const f = await fixture();
    try {
      const source = mail('raced'); await f.seed(source); const original = f.row(source.id);
      const repaired = { ...original, bodySavedAt: original.bodySavedAt + 1, mail: { ...source, textBody: 'New body', bodyEncodingProblem: false } };
      let newDocument;
      f.state.beforeBegin = () => {
        f.state.beforeBegin = null;
        if (removed) { f.sqlite.exec("UPDATE accounts SET status='deleting' WHERE id='a'"); return; }
        f.sqlite.prepare("UPDATE mail_cache SET payload=? WHERE account_id='a' AND cache_key=?").run(JSON.stringify(repaired), source.id);
        const key = f.stableMessageKey(source);
        newDocument = JSON.parse(f.reader.prepare('SELECT payload FROM prepared_documents WHERE message_key=?').get(key).payload);
        newDocument.html = '<p>New completed document</p>'; newDocument.bodySavedAt = repaired.bodySavedAt;
        f.sqlite.prepare('UPDATE prepared_documents SET payload=?,body_saved_at=? WHERE message_key=?').run(JSON.stringify(newDocument), repaired.bodySavedAt, key);
      };
      await f.recover(); assert.equal(f.job(source.id).stage, 'done');
      assert.deepEqual(f.row(source.id), removed ? original : repaired);
      if (!removed) assert.equal((await f.documents.read('a', f.stableMessageKey(source))).document.html, newDocument.html);
    } finally { f.close(); }
  }
});

test('A competing worker completion timestamp cannot strand a proven failed body during upgrade repair', async () => {
  const f = await fixture();
  try {
    const source = mail('stale-completion'); await f.sync.enqueue('a', [source]);
    await f.cache.saveEmail('a', source); const first = await f.cache.email('a', source.id, true);
    while (Date.now() <= first.bodySavedAt) await new Promise(resolve => setImmediate(resolve));
    await f.cache.saveEmail('a', source); const second = await f.cache.email('a', source.id, true);
    const key = f.stableMessageKey(source);
    await f.documents.save('a', key, f.oldEmpty, [], second.bodySavedAt);
    const winner = await f.documents.save('a', key, f.oldEmpty, [], first.bodySavedAt);
    assert.equal(winner.bodySavedAt, second.bodySavedAt, 'the immutable document keeps its winning timestamp');
    await f.sync.markPictures('a', source.id, first.bodySavedAt, key); await f.sync.complete('a', source.id);
    await f.sync.markPictures('a', source.id, second.bodySavedAt, key); await f.sync.complete('a', source.id);
    assert.notEqual(f.job(source.id).body_saved_at, f.row(source.id).bodySavedAt);
    await f.recover();
    assert.equal(f.row(source.id).bodySavedAt, null); assert.equal((await f.documents.read('a', key)).document, null);
    assert.equal(f.job(source.id).stage, 'body'); assert.equal((await f.sync.next(['a'], 'body')).length, 1);
  } finally { f.close(); }
});

test('Registration repairs already-migrated DONE markers with missing raw bodies without altering shared snapshots or retries', async () => {
  const f = await fixture();
  try {
    await f.recover(); // Installed .24 users already have the version-one marker.
    f.sqlite.exec("CREATE TABLE picture_snapshot(account_id TEXT,message_key TEXT,attempted INTEGER);INSERT INTO picture_snapshot VALUES('a','completed-images',1)");
    for (const registration of ['enqueue', 'seedPage', 'seedCached', 'advance']) {
      const source = mail(registration, { textBody: 'Saved body', bodyEncodingProblem: false });
      await f.seed(source, '<p>Immutable good shared snapshot</p>');
      await f.cache.forgetEmail('a', source.id);
      if (registration !== 'enqueue') {
        await f.cache.saveView('a', 'inbox', [mail(source.id, { bodyEncodingProblem: false })], null, 'new-headers');
        assert.equal(f.row(source.id).bodySavedAt, null);
        const prefix = JSON.stringify(f.row(source.id)).slice(0, 192);
        assert.ok(prefix.startsWith('{"version":1,')); assert.ok(prefix.includes('"bodySavedAt":null,'));
      }
      const before = await f.documents.read('a', f.stableMessageKey(source));
      assert.equal(f.job(source.id).stage, 'done'); await f.recover();
      assert.equal(f.job(source.id).stage, 'done', 'the completed upgrade repair does not scan again');
      f.state.readsInTransaction = 0;
      const page = { position: 0, nextPosition: null, queryState: registration, emails: [source] };
      if (registration === 'enqueue') await f.sync.enqueue('a', [source]);
      if (registration === 'seedPage') await f.sync.seedPage('a', registration, page);
      if (registration === 'seedCached') await f.sync.seedCached('a', registration, { ...page, savedAt: Date.now() });
      if (registration === 'advance') {
        const cursor = await f.sync.seedPage('a', registration, { ...page, emails: [], nextPosition: 1 });
        assert.equal(await f.sync.advance(cursor, { ...page, position: 1 }), true);
      }
      assert.equal(f.job(source.id).stage, 'body');
      assert.deepEqual(await f.documents.read('a', f.stableMessageKey(source)), before);
      await f.sync.defer('a', source.id, Date.now() + 60000); const deferred = f.job(source.id);
      await f.sync.enqueue('a', [source]); assert.deepEqual(f.job(source.id), deferred, 'refresh cannot erase unfinished backoff');
      assert.equal(f.state.readsInTransaction, 0, 'registration guards never depend on uncommitted pooled reads');
    }
    assert.equal(f.reader.prepare('SELECT attempted FROM picture_snapshot').get().attempted, 1);
  } finally { f.close(); }
});


test('Legacy repair can inspect a large partial HTML candidate without exceeding the native row window or erasing it', async () => {
  const f = await fixture({ nativeWindowLimit: true });
  try {
    const value = { version: 1, savedAt: Date.now(), bodySavedAt: Date.now(), bodyDecoderRevision: 1,
      mail: mail('large-partial', { hasHtmlBody: true, htmlBody: '<p>中文 😀</p>'.repeat(180000) }) };
    const payload = JSON.stringify(value);
    assert.ok(Buffer.byteLength(payload) > 2 * 1024 * 1024);
    f.sqlite.prepare("INSERT INTO mail_cache (account_id, kind, cache_key, payload) VALUES ('a', 'email', 'large-partial', ?)").run(payload);
    await f.recover();
    assert.equal(f.reader.prepare("SELECT payload FROM mail_cache WHERE cache_key='large-partial'").get().payload, payload);
    assert.equal(f.job('large-partial'), undefined);
  } finally { f.close(); }
});

test('Legacy empty-body repair preserves file-backed partial-body metadata and its saved timestamp', async () => {
  const f = await fixture();
  try {
    const value = { version: 1, savedAt: Date.now(), bodySavedAt: Date.now(), bodyDecoderRevision: 1,
      bodyFiles: { html: 'a/00000000-0000-4000-8000-000000000001.html' },
      mail: mail('file-partial', { hasHtmlBody: true }) };
    const payload = JSON.stringify(value);
    f.sqlite.prepare("INSERT INTO mail_cache (account_id, kind, cache_key, payload) VALUES ('a', 'email', 'file-partial', ?)").run(payload);
    await f.recover();
    assert.equal(f.reader.prepare("SELECT payload FROM mail_cache WHERE cache_key='file-partial'").get().payload, payload);
    assert.equal(f.job('file-partial'), undefined);
  } finally { f.close(); }
});
