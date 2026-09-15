const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

// Exercise the production cache and its transactions against real SQLite. The
// only substitution is HarmonyOS's RDB result adapter; these fixtures never use
// a provider, device account, or network transport.
async function fixture(options = {}) {
  const sqlite = new DatabaseSync(':memory:');
  const reads = [], transfers = [], pruneBatches = [];
  const serialization = { calls: 0, characters: 0 };
  const observedJSON = { parse: JSON.parse, stringify: (...args) => {
    const result = JSON.stringify(...args);
    serialization.calls++; serialization.characters += result?.length || 0;
    return result;
  } };
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      reads.push(sql);
      if (options.noJson && sql.startsWith('SELECT json_set')) throw new Error('Synthetic SQLite without JSON support');
      const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      if (sql.includes('FROM mail_cache WHERE rowid >')) pruneBatches.push(rows.length);
      return { goToFirstRow: () => { index = 0; return rows.length > 0; },
        goToNextRow: () => ++index < rows.length, getString: column => { const value = rows[index][column]; transfers.push(value.length); return value; },
        getLong: column => rows[index][column], getBlob: column => new Uint8Array(rows[index][column]), close() {} };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK')
  };
  const modules = new Map();
  function load(file) {
    if (modules.has(file)) return modules.get(file);
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
      target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
    } }).outputText;
    const module = { exports: {} }; modules.set(file, module.exports);
    new Function('require', 'module', 'exports', 'JSON', compiled)(name => {
      if (name === '@kit.ArkData') return { relationalStore: {} };
      if (name === '@kit.ArkTS') return { util: { TextDecoder: class {
        static create(label, options) { return new this(label, options); }
        constructor(label, options) { this.decoder = new TextDecoder(label, options); }
        decodeToString(bytes) { return this.decoder.decode(bytes); }
      } } };
      if (!name.startsWith('.')) throw new Error(`Unexpected dependency ${name}`);
      const base = path.resolve(path.dirname(file), name);
      return load(fs.existsSync(`${base}.ts`) ? `${base}.ts` : `${base}.ets`);
    }, module, module.exports, observedJSON);
    return module.exports;
  }
  const { MailCache } = load(path.resolve('harmony/entry/src/main/ets/data/MailCache.ets'));
  const { sentMailbox } = load(path.resolve('harmony/entry/src/main/ets/mail/smtp/SentMail.ts'));
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  await MailCache.initialize(db);
  return { cache: new MailCache(db, queue), reopen: () => new MailCache(db, queue), sentMailbox, sqlite, reads, transfers, pruneBatches, serialization,
    initialize: () => MailCache.initialize(db),
    cacheModel: load(path.resolve('harmony/entry/src/main/ets/data/MailCacheModel.ts')),
    seed(account, kind, key, payload, dirty = 0) {
      sqlite.prepare('INSERT OR REPLACE INTO mail_cache (account_id, kind, cache_key, payload, dirty) VALUES (?, ?, ?, ?, ?)')
        .run(account, kind, key, JSON.stringify(payload), dirty);
    },
    row(account, kind, key) {
      const row = sqlite.prepare('SELECT payload, dirty FROM mail_cache WHERE account_id = ? AND kind = ? AND cache_key = ?')
        .get(account, kind, key);
      return row ? { payload: JSON.parse(row.payload), dirty: row.dirty } : null;
    },
    accountRows(account) {
      return sqlite.prepare('SELECT kind, cache_key, payload, dirty FROM mail_cache WHERE account_id = ? ORDER BY kind, cache_key')
        .all(account).map(row => ({ ...row }));
    }
  };
}

const day = 24 * 60 * 60 * 1000;
function box(id, role = null) {
  return { id, name: id === 'local_sent' ? 'Sent' : id === 'server_sent' ? 'Sent Messages' : id,
    parentId: null, role, sortOrder: 2, totalEmails: 20, unreadEmails: 0, countsKnown: true,
    maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true };
}
function mail(id, mailboxIds, receivedAt = Date.now() - day) {
  return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds,
    keywords: ['$seen', '$flagged'], from: [{ name: 'Synthetic Sender', email: 'sender@example.test' }],
    to: [{ name: '', email: 'recipient@example.test' }], cc: [], replyTo: [],
    inReplyTo: ['parent@example.test'], references: ['parent@example.test'], subject: 'Re: cached café 中文',
    preview: 'Downloaded reply', receivedAt, hasAttachment: true,
    attachments: [{ id: '2', name: 'synthetic.pdf', contentType: 'application/pdf', size: 4, sizeIsEncoded: false }],
    textBody: 'Downloaded reply café 中文\n> Previous message', htmlBody: '<p>Downloaded reply café 中文</p><blockquote>Previous message</blockquote>',
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: true, maySetSeen: false, maySetKeywords: false };
}
function cached(mail, savedAt) { return { version: 1, savedAt, bodySavedAt: savedAt, bodyDecoderRevision: 1, mail }; }

test('Automatic traversal saves every page member without replacing navigation or a downloaded body', async () => {
  const f = await fixture(), original = mail('kept', ['inbox']);
  await f.cache.saveView('a', 'inbox', [original], 50, 'visible-cursor');
  await f.cache.saveEmail('a', original);
  const before = f.row('a', 'email', original.id), view = f.row('a', 'view', 'inbox');
  const headers = Array.from({ length: 250 }, (_, i) => ({ ...mail(`page-${i}`, ['inbox']), textBody: null, htmlBody: null, attachments: undefined }));
  headers.push({ ...original, textBody: null, htmlBody: null, attachments: undefined });
  await f.cache.saveSyncedEmails('a', headers);
  assert.deepEqual(f.row('a', 'view', 'inbox'), view);
  assert.equal(f.row('a', 'email', original.id).payload.bodySavedAt, before.payload.bodySavedAt);
  assert.equal(f.row('a', 'email', original.id).payload.mail.htmlBody, original.htmlBody);
  for (let i = 0; i < 250; i++) {
    const saved = f.row('a', 'email', `page-${i}`);
    assert.ok(saved); assert.equal(saved.payload.bodySavedAt, null);
  }
  assert.equal(f.row('b', 'email', 'page-0'), null);
});
function boxes(values, savedAt, roleRevision = 1) {
  return { version: 1, savedAt, boxes: values, readOnly: false, roleRevision };
}
function view(mailboxId, ids, savedAt, nextPosition = null, queryState) {
  return { version: 1, savedAt, mailboxId, ids, nextPosition, queryState };
}

test('Header-only cache reads project body bytes before ArkTS while preserving offline body ownership and ranking', async () => {
  const f = await fixture();
  try {
    const now = Date.now() - 1000;
    const source = { ...mail('large', ['inbox']), textBody: 'Synthetic text '.repeat(40000),
      htmlBody: '<p>Synthetic HTML</p>'.repeat(30000) };
    f.seed('a', 'email', source.id, cached(source, now), 1);
    f.seed('a', 'view', 'inbox', view('inbox', [source.id], now));
    f.seed('b', 'email', 'other', cached(mail('other', ['inbox']), now));
    const index = await f.cache.cachedMessages('a', false);
    const headers = await f.cache.view('a', 'inbox', true, false);
    assert.equal(await f.cache.hasSqlSummaryProjection(), true);
    assert.equal(index.length, 1); assert.equal(index[0].summaryOnly, true);
    assert.equal(index[0].stateDirty, true); assert.equal(headers.stateDirty, true);
    assert.equal(index[0].bodySavedAt, now); assert.equal(index[0].bodyDecoderRevision, 1);
    for (const header of [index[0].mail, headers.emails[0]]) {
      assert.equal(header.textBody, null); assert.equal(header.htmlBody, null);
      assert.equal(header.attachments, undefined); assert.equal(header.cachedBodyAvailable, true);
      assert.deepEqual(header.messageIds, source.messageIds); assert.deepEqual(header.keywords, source.keywords);
    }
    assert.equal(f.cacheModel.cacheReadyForReading(index[0]), false);
    assert.ok(Math.max(...f.transfers) < 5000, 'large body strings must not cross the native result boundary');
    assert.throws(() => f.cache.saveEmail('a', index[0].mail), /Header-only/);
    const full = await f.cache.email('a', source.id, true);
    assert.equal(full.mail.textBody, source.textBody); assert.equal(full.mail.htmlBody, source.htmlBody);
    await f.cache.saveView('a', 'inbox', headers.emails);
    const stored = f.row('a', 'email', source.id).payload;
    assert.equal(stored.mail.textBody, source.textBody); assert.equal(stored.bodySavedAt, now);
    assert.equal(stored.mail.cachedBodyAvailable, undefined); assert.equal(stored.summaryOnly, undefined);
  } finally { f.sqlite.close(); }
});

test('Header-only cache fallback probes once and expired bodies never become available through either read path', async () => {
  for (const noJson of [false, true]) {
    const f = await fixture({ noJson });
    try {
      const now = Date.now() - 1000, expired = now - 8 * day;
      const original = cached(mail('old', ['inbox']), now); original.bodySavedAt = expired;
      f.seed('a', 'email', 'old', original);
      f.seed('a', 'view', 'inbox', view('inbox', ['old'], now));
      const index = await f.cache.cachedMessages('a', false);
      const projected = await f.cache.view('a', 'inbox', false, false);
      assert.equal(index[0].bodySavedAt, null); assert.equal(index[0].mail.cachedBodyAvailable, false);
      assert.equal(projected.emails[0].cachedBodyAvailable, false);
      const fullView = await f.cache.view('a', 'inbox');
      assert.equal(fullView.emails[0].textBody, null); assert.equal(fullView.emails[0].htmlBody, null);
      assert.equal(fullView.emails[0].attachments, undefined);
      f.seed('a', 'email', 'fresh', cached(mail('fresh', ['inbox']), now));
      const fresh = (await f.cache.cachedMessages('a', false)).find(record => record.mail.id === 'fresh');
      assert.equal(fresh.mail.cachedBodyAvailable, true); assert.equal(fresh.mail.textBody, null);
      assert.equal(await f.cache.hasSqlSummaryProjection(), !noJson);
      assert.equal(f.reads.filter(sql => sql.startsWith('SELECT json_set')).length, 1);
      assert.equal(f.row('a', 'email', 'old').payload.mail.textBody, original.mail.textBody, 'projection never mutates stored bytes');
    } finally { f.sqlite.close(); }
  }
});

test('Folder reads batch bounded native queries while preserving order, dirty filtering, membership and offline bodies', async () => {
  const f = await fixture();
  try {
    const now = Date.now() - 1000, ids = [];
    for (let index = 0; index < 70; index++) {
      const id = `batch_${index}`; ids.unshift(id);
      const source = { ...mail(id, index === 3 ? ['archive'] : ['inbox']),
        textBody: 'Synthetic cached body '.repeat(10000) };
      f.seed('a', 'email', id, cached(source, now), index === 4 ? 1 : 0);
    }
    ids.splice(2, 0, 'missing');
    f.seed('b', 'email', 'missing', cached(mail('missing', ['inbox']), now));
    f.seed('a', 'view', 'inbox', view('inbox', ids, now, 71, 'stable-query'));
    await f.cache.hasSqlSummaryProjection();
    f.reads.length = 0; f.transfers.length = 0;
    const clean = await f.cache.view('a', 'inbox', false, false);
    assert.deepEqual(clean.emails.map(item => item.id), ids.filter(id => !['missing', 'batch_3', 'batch_4'].includes(id)));
    assert.equal(clean.stateDirty, false); assert.equal(clean.nextPosition, 71); assert.equal(clean.queryState, 'stable-query');
    assert.equal(f.reads.length, 3, 'one view query and two email batches replace one query per message');
    assert.ok(Math.max(...f.transfers) < 5000, 'body strings must stay behind the native boundary');
    f.reads.length = 0;
    const dirty = await f.cache.view('a', 'inbox', true, false);
    assert.deepEqual(dirty.emails.map(item => item.id), ids.filter(id => !['missing', 'batch_3'].includes(id)));
    assert.equal(dirty.stateDirty, true); assert.equal(f.reads.length, 3);
    const original = await f.cache.email('a', 'batch_4', true);
    assert.equal(original.mail.textBody, 'Synthetic cached body '.repeat(10000));
    assert.equal(original.bodySavedAt, now); assert.equal(original.stateDirty, true);

    const corrupt = cached(mail('different_id', ['inbox']), now);
    f.seed('a', 'email', 'batch_2', corrupt);
    await assert.rejects(f.cache.view('a', 'inbox', true, false), /Invalid mail cache/);
    f.seed('a', 'email', 'batch_2', { ...cached(mail('batch_2', ['inbox']), now), mail: {} });
    await assert.rejects(f.cache.view('a', 'inbox', true, false), /Invalid mail cache/);
  } finally { f.sqlite.close(); }
});

test('Startup pruning bounds body batches, visits rows after deletions, and indexes dirty-account checks', async () => {
  const f = await fixture();
  try {
    const now = Date.now() - 1000, expired = now - 8 * day;
    for (let index = 0; index < 25; index++) {
      const value = cached({ ...mail(`batch_${index}`, ['inbox']), textBody: 'Synthetic body '.repeat(1000) }, index % 3 === 0 ? expired : now);
      if (index % 3 === 1) value.bodySavedAt = expired;
      f.seed('a', 'email', value.mail.id, value, index === 2 ? 1 : 0);
    }
    f.pruneBatches.length = 0;
    await f.initialize();
    assert.ok(f.pruneBatches.length > 2);
    assert.ok(Math.max(...f.pruneBatches) <= 8, 'startup must not retain the whole body table in one batch');
    assert.equal(f.pruneBatches.reduce((sum, count) => sum + count, 0), 25, 'deletion must not skip later rows');
    for (let index = 0; index < 25; index++) {
      const stored = f.row('a', 'email', `batch_${index}`);
      if (index % 3 === 0) assert.equal(stored, null);
      else if (index % 3 === 1) {
        assert.equal(stored.payload.bodySavedAt, null); assert.equal(stored.payload.mail.textBody, null);
      } else assert.equal(stored.payload.bodySavedAt, now);
    }
    const plan = f.sqlite.prepare("EXPLAIN QUERY PLAN SELECT 1 FROM mail_cache WHERE account_id = ? AND kind = 'email' AND dirty != 0 LIMIT 1").all('a');
    assert.ok(plan.some(step => /USING (?:COVERING )?INDEX mail_cache_dirty_email/.test(step.detail)), JSON.stringify(plan));
    assert.equal(f.row('a', 'email', 'batch_2').dirty, 1);
  } finally { f.sqlite.close(); }
});

test('Startup validates fresh bodies without serialization or writes and normalizes only changed retained records', async () => {
  const f = await fixture();
  try {
    const now = Date.now() - 1000, expired = now - 7 * day;
    for (let index = 0; index < 24; index++) {
      const source = { ...mail(`fresh_${index}`, ['inbox']),
        textBody: 'Synthetic cached body '.repeat(4096), htmlBody: '<p>Synthetic cached body</p>'.repeat(4096) };
      f.seed(index < 12 ? 'a' : 'b', 'email', source.id, cached(source, now), index % 2);
    }
    const summary = { ...mail('summary', ['inbox']), textBody: null, htmlBody: null, attachments: undefined, hasAttachment: false };
    f.seed('a', 'email', summary.id, { ...cached(summary, now), bodySavedAt: null });
    const before = f.sqlite.prepare("SELECT account_id,cache_key,payload,dirty FROM mail_cache ORDER BY account_id,cache_key").all();
    const changes = f.sqlite.prepare('SELECT total_changes() AS n').get().n;
    f.serialization.calls = 0; f.serialization.characters = 0;
    await f.initialize();
    assert.equal(f.serialization.calls, 0, 'unchanged bodies and normalized summaries must not be serialized again');
    assert.equal(f.serialization.characters, 0);
    assert.equal(f.sqlite.prepare('SELECT total_changes() AS n').get().n, changes);
    assert.deepEqual(f.sqlite.prepare("SELECT account_id,cache_key,payload,dirty FROM mail_cache ORDER BY account_id,cache_key").all(), before);

    f.seed('a', 'email', 'body_expired', { ...cached({ ...mail('body_expired', ['inbox']), preview: '' }, now), bodySavedAt: expired }, 1);
    f.seed('b', 'email', 'legacy_preview', cached({ ...mail('legacy_preview', ['inbox']), preview: '' }, now), 1);
    f.seed('a', 'email', 'fully_expired', cached(mail('fully_expired', ['inbox']), expired));
    f.seed('b', 'email', 'invalid', { ...cached(mail('invalid', ['inbox']), now), version: 99 });
    f.serialization.calls = 0; f.serialization.characters = 0;
    await f.initialize();
    assert.equal(f.serialization.calls, 2, 'only expired-body normalization and legacy preview repair require serialization');
    const stripped = f.row('a', 'email', 'body_expired');
    assert.equal(stripped.dirty, 1); assert.equal(stripped.payload.savedAt, now); assert.equal(stripped.payload.bodySavedAt, null);
    assert.equal(stripped.payload.mail.textBody, null); assert.equal(stripped.payload.mail.htmlBody, null);
    assert.equal(stripped.payload.mail.attachments, undefined);
    assert.equal(stripped.payload.mail.preview, 'Downloaded reply café 中文 > Previous message', 'preview recovery still precedes expired-body stripping');
    const repaired = f.row('b', 'email', 'legacy_preview');
    assert.equal(repaired.dirty, 1); assert.equal(repaired.payload.bodySavedAt, now); assert.equal(repaired.payload.savedAt, now);
    assert.equal(repaired.payload.mail.preview, stripped.payload.mail.preview);
    assert.equal(repaired.payload.mail.textBody, mail('legacy_preview', ['inbox']).textBody);
    assert.equal(f.row('a', 'email', 'fully_expired'), null); assert.equal(f.row('b', 'email', 'invalid'), null);
    assert.equal(f.row('b', 'email', 'body_expired'), null);
    f.serialization.calls = 0;
    await f.initialize();
    assert.equal(f.serialization.calls, 0, 'normalization is idempotent on later opens');
  } finally { f.sqlite.close(); }
});

test('A page shares one projected local Sent index and reads a large body only for its matching Message-ID', async () => {
  const f = await fixture();
  try {
    const now = Date.now() - 1000;
    const local = { ...mail('local_sent_body', ['server_sent']), messageIds: ['<matched@example.test>'],
      textBody: 'Large synthetic local Sent body '.repeat(10000), htmlBody: '<p>Saved copy</p>'.repeat(10000) };
    f.seed('a', 'email', local.id, cached(local, now));
    const headers = Array.from({ length: 40 }, (_, index) => ({ ...mail(`header_${index}`, ['inbox']),
      messageIds: [`unmatched-${index}@example.test`], textBody: null, htmlBody: null, attachments: undefined }));
    headers.push({ ...mail('matched_server_copy', ['inbox']), messageIds: ['matched@example.test'],
      textBody: null, htmlBody: null, attachments: undefined });
    f.reads.length = 0; f.transfers.length = 0;
    await f.cache.saveView('a', 'inbox', headers);
    assert.equal(f.reads.filter(sql => sql.includes("cache_key LIKE 'local_sent_%'")).length, 1,
      'unmatched headers must share one metadata index');
    assert.equal(f.transfers.filter(length => length > 100000).length, 1,
      'only the matched full body should cross the native result boundary');
    const recovered = await f.cache.email('a', 'matched_server_copy', true);
    assert.equal(recovered.mail.textBody, local.textBody); assert.equal(recovered.mail.htmlBody, local.htmlBody);
    assert.equal(recovered.bodySavedAt, now);
    const savedLocal = await f.cache.email('a', local.id, true);
    assert.equal(savedLocal.mail.id, local.id); assert.equal(savedLocal.mail.textBody, local.textBody);
    for (let index = 0; index < 40; index++) assert.equal(await f.cache.email('a', `header_${index}`, true), null);
  } finally { f.sqlite.close(); }
});

test('Server Sent metadata moves legacy local membership into the real folder without losing body, dirty state, or server pagination', async () => {
  const f = await fixture();
  try {
    const old = Date.now() - 2 * day;
    const localMail = cached(mail('local_sent_one', ['local_sent', 'inbox']), old);
    const serverMail = cached(mail('server_one', ['server_sent']), old - 1000);
    f.seed('a', 'boxes', '', boxes([box('inbox', 'inbox'), box('local_sent', 'sent')], old));
    f.seed('a', 'email', 'local_sent_one', localMail, 1);
    f.seed('a', 'email', 'server_one', serverMail);
    f.seed('a', 'view', 'local_sent', view('local_sent', ['local_sent_one'], old));
    f.seed('a', 'view', 'server_sent', view('server_sent', ['server_one'], old - 1000, 50, 'server-cursor'), 1);
    f.seed('b', 'boxes', '', boxes([box('local_sent', 'sent')], old));
    f.seed('b', 'email', 'local_sent_one', localMail, 1);
    f.seed('b', 'view', 'local_sent', view('local_sent', ['local_sent_one'], old));
    const untouched = f.accountRows('b');

    await f.cache.saveBoxes('a', [box('inbox', 'inbox'), box('server_sent', 'sent')], true);

    const actualBoxes = await f.cache.boxes('a');
    assert.deepEqual(actualBoxes.boxes.map(value => value.id), ['inbox', 'server_sent']);
    assert.equal(actualBoxes.roleRevision, 5); assert.equal(actualBoxes.readOnly, true);
    const moved = f.row('a', 'email', 'local_sent_one');
    assert.equal(moved.dirty, 1);
    assert.deepEqual(moved.payload, { ...localMail, mail: { ...localMail.mail, mailboxIds: ['server_sent', 'inbox'] } });
    assert.deepEqual(f.row('a', 'email', 'server_one').payload, serverMail);
    assert.equal(f.row('a', 'view', 'local_sent'), null);
    const merged = f.row('a', 'view', 'server_sent');
    assert.deepEqual(new Set(merged.payload.ids), new Set(['local_sent_one', 'server_one']));
    assert.equal(merged.payload.savedAt, old - 1000);
    assert.equal(merged.payload.nextPosition, 50); assert.equal(merged.payload.queryState, 'server-cursor');
    assert.equal(merged.dirty, 1);
    const offline = await f.reopen().view('a', 'server_sent', true);
    assert.equal(offline.emails.length, 2); assert.equal(offline.stateDirty, true);
    assert.deepEqual(f.accountRows('b'), untouched);
  } finally { f.sqlite.close(); }
});

test('Opening an existing cache reconciles the ghost Sent folder without renewing the seven-day retention timestamps', async () => {
  const f = await fixture();
  try {
    const old = Date.now() - 6 * day;
    const body = cached(mail('local_sent_old', ['local_sent']), old);
    f.seed('a', 'boxes', '', boxes([box('local_sent', 'sent'), box('server_sent', 'sent')], old));
    f.seed('a', 'email', body.mail.id, body, 1);
    f.seed('a', 'view', 'local_sent', view('local_sent', [body.mail.id], old));

    const reopened = f.reopen();
    const actual = await reopened.boxes('a');
    assert.deepEqual(actual.boxes.map(value => value.id), ['server_sent']);
    assert.equal(actual.savedAt, old);
    assert.equal(f.row('a', 'boxes', '').payload.savedAt, old);
    assert.equal(f.row('a', 'email', body.mail.id).payload.bodySavedAt, old);
    assert.equal(f.row('a', 'email', body.mail.id).payload.savedAt, old);
    assert.equal(f.row('a', 'email', body.mail.id).dirty, 1);
    assert.equal(f.row('a', 'view', 'server_sent').payload.savedAt, old);
    assert.equal(f.row('a', 'view', 'local_sent'), null);
    const first = f.accountRows('a');
    assert.deepEqual(await reopened.boxes('a'), actual);
    assert.deepEqual(f.accountRows('a'), first, 'Repeated cached opens are idempotent');
  } finally { f.sqlite.close(); }
});

test('Local accepted mail remains available and explicitly local while the server Sent destination is unknown or ambiguous', async () => {
  for (const discovered of [[box('inbox', 'inbox')], [box('sent_one', 'sent'), box('sent_two', 'sent')]]) {
    const f = await fixture();
    try {
      const old = Date.now() - day, body = cached(mail('local_sent_pending', ['local_sent']), old);
      f.seed('a', 'boxes', '', boxes([box('local_sent', 'sent')], old));
      f.seed('a', 'email', body.mail.id, body);
      f.seed('a', 'view', 'local_sent', view('local_sent', [body.mail.id], old));
      await f.cache.saveBoxes('a', discovered);
      const actual = await f.reopen().boxes('a');
      const local = actual.boxes.find(value => value.id === 'local_sent');
      assert.ok(local); assert.equal(local.role, null);
      assert.match(local.name, /sent.*(device|local)/i);
      assert.deepEqual(f.row('a', 'email', body.mail.id).payload, body);
      assert.equal((await f.cache.view('a', 'local_sent', true)).emails[0].textBody, body.mail.textBody);
      assert.equal(actual.roleRevision, 5);
    } finally { f.sqlite.close(); }
  }
});

test('An APPEND result identifying the actual Sent mailbox merges earlier local copies before adding the new accepted body', async () => {
  const f = await fixture();
  try {
    const old = Date.now() - day, existing = cached(mail('local_sent_earlier', ['local_sent']), old);
    f.seed('a', 'boxes', '', boxes([box('inbox', 'inbox'), box('local_sent', 'sent')], old));
    f.seed('a', 'email', existing.mail.id, existing, 1);
    f.seed('a', 'view', 'local_sent', view('local_sent', [existing.mail.id], old));
    f.seed('a', 'view', 'server_sent', view('server_sent', [], old, 75, 'append-cursor'));
    const outgoing = mail('local_sent_latest', ['server_sent'], Date.now());

    await f.cache.appendSent('a', outgoing, box('server_sent', 'sent'));

    assert.deepEqual((await f.cache.boxes('a')).boxes.map(value => value.id).sort(), ['inbox', 'server_sent']);
    assert.equal(f.row('a', 'view', 'local_sent'), null);
    const moved = f.row('a', 'email', existing.mail.id);
    assert.equal(moved.dirty, 1); assert.equal(moved.payload.bodySavedAt, old);
    assert.deepEqual(moved.payload.mail.mailboxIds, ['server_sent']);
    const sentView = await f.reopen().view('a', 'server_sent', true);
    assert.deepEqual(new Set(sentView.emails.map(value => value.id)), new Set([outgoing.id, existing.mail.id]));
    assert.equal(sentView.nextPosition, 75); assert.equal(sentView.queryState, 'append-cursor');
    assert.deepEqual((await f.cache.email('a', outgoing.id, true)).mail, outgoing);
  } finally { f.sqlite.close(); }
});

test('A confirmed APPEND destination upgrades an existing unclassified server mailbox without losing its metadata', async () => {
  const f = await fixture();
  try {
    const unclassified = box('server_sent');
    const result = { accepted: true, messageId: 'accepted@example.test', date: Date.now(),
      textBody: 'Accepted reply', htmlBody: null, sentCopy: 'saved', sentMailboxId: unclassified.id };
    const destination = f.sentMailbox([box('local_sent', 'sent'), unclassified], result);
    assert.deepEqual(destination, { ...unclassified, role: 'sent' });
    assert.equal(unclassified.role, null, 'The supplied cached snapshot remains unchanged');
  } finally { f.sqlite.close(); }
});

test('Appending to an authoritative Sent destination replaces an older null role and reconciles prior accepted mail', async () => {
  const f = await fixture();
  try {
    const old = Date.now() - day, existing = cached(mail('local_sent_before_discovery', ['local_sent']), old);
    const unclassified = box('server_sent');
    f.seed('a', 'boxes', '', boxes([box('local_sent', 'sent'), unclassified], old));
    f.seed('a', 'email', existing.mail.id, existing, 1);
    f.seed('a', 'view', 'local_sent', view('local_sent', [existing.mail.id], old));
    f.seed('a', 'view', 'server_sent', view('server_sent', [], old, 100, 'known-folder-cursor'));
    const outgoing = mail('local_sent_after_discovery', ['server_sent'], Date.now());

    await f.cache.appendSent('a', outgoing, { ...unclassified, role: 'sent' });

    const actual = await f.reopen().boxes('a');
    assert.deepEqual(actual.boxes.map(value => value.id), ['server_sent']);
    assert.equal(actual.boxes[0].role, 'sent');
    assert.equal(actual.boxes[0].name, unclassified.name);
    assert.equal(actual.boxes[0].mayRemoveItems, unclassified.mayRemoveItems);
    assert.equal(f.row('a', 'view', 'local_sent'), null);
    const moved = f.row('a', 'email', existing.mail.id);
    assert.equal(moved.dirty, 1); assert.equal(moved.payload.bodySavedAt, old);
    assert.deepEqual(moved.payload.mail.mailboxIds, ['server_sent']);
    const contents = await f.cache.view('a', 'server_sent', true);
    assert.deepEqual(new Set(contents.emails.map(value => value.id)), new Set([existing.mail.id, outgoing.id]));
    assert.equal(contents.nextPosition, 100); assert.equal(contents.queryState, 'known-folder-cursor');
  } finally { f.sqlite.close(); }
});

test('Server headers after reconciliation reuse the accepted MIME body and replace its local list identity without a refetch', async () => {
  const f = await fixture();
  try {
    const old = Date.now() - 3 * day, body = cached(mail('local_sent_confirmed', ['local_sent']), old);
    f.seed('a', 'boxes', '', boxes([box('local_sent', 'sent')], old));
    f.seed('a', 'email', body.mail.id, body);
    f.seed('a', 'view', 'local_sent', view('local_sent', [body.mail.id], old));
    await f.cache.saveBoxes('a', [box('server_sent', 'sent')]);
    const summary = { ...body.mail, id: 'server_uid_42', threadId: 'server_thread', mailboxIds: ['server_sent'],
      messageIds: [`<${body.mail.messageIds[0]}>`], textBody: null, htmlBody: null, attachments: undefined };

    await f.cache.saveView('a', 'server_sent', [summary], 50, 'fresh-state');

    const server = await f.cache.email('a', summary.id, true);
    assert.equal(server.mail.textBody, body.mail.textBody); assert.equal(server.mail.htmlBody, body.mail.htmlBody);
    assert.deepEqual(server.mail.attachments, body.mail.attachments); assert.equal(server.bodySavedAt, old);
    assert.deepEqual(server.mail.mailboxIds, ['server_sent']);
    const actual = await f.cache.view('a', 'server_sent', true);
    assert.deepEqual(actual.emails.map(value => value.id), [summary.id]);
    assert.equal(actual.nextPosition, 50); assert.equal(actual.queryState, 'fresh-state');
  } finally { f.sqlite.close(); }
});

test('Reconciliation never resurrects expired local bodies or writes into a removed account', async () => {
  const f = await fixture();
  try {
    const fresh = Date.now() - day, expired = Date.now() - 8 * day;
    const body = cached(mail('local_sent_expired', ['local_sent']), expired);
    f.seed('a', 'boxes', '', boxes([box('local_sent', 'sent'), box('server_sent', 'sent')], fresh));
    f.seed('a', 'email', body.mail.id, body);
    f.seed('a', 'view', 'local_sent', view('local_sent', [body.mail.id], expired));
    await f.cache.boxes('a');
    assert.equal(await f.cache.email('a', body.mail.id, true), null);
    const stored = f.row('a', 'email', body.mail.id);
    assert.ok(stored === null || stored.payload.bodySavedAt === expired || stored.payload.bodySavedAt === null);
    f.sqlite.exec("DELETE FROM mail_cache WHERE account_id = 'a'; DELETE FROM accounts WHERE id = 'a'");
    await f.cache.saveBoxes('a', [box('server_sent', 'sent')]);
    await f.cache.appendSent('a', mail('local_sent_after_removal', ['server_sent']), box('server_sent', 'sent'));
    assert.deepEqual(f.accountRows('a'), []); assert.equal(await f.cache.boxes('a'), null);
  } finally { f.sqlite.close(); }
});
