const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const modules = new Map();
function load(filename) {
  filename = path.resolve(filename);
  if (modules.has(filename)) return modules.get(filename).exports;
  const module = { exports: {} }; modules.set(filename, module);
  const js = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', js)(name => {
    if (name === '@kit.ArkTS') return { util: { TextDecoder: class extends TextDecoder {
      decodeToString(bytes) { return this.decode(bytes); }
    } } };
    assert.ok(name.startsWith('.'), 'Unexpected platform dependency ' + name);
    const base = path.resolve(path.dirname(filename), name);
    return load(fs.existsSync(base + '.ts') ? base + '.ts' : base + '.ets');
  }, module, module.exports);
  return module.exports;
}
const { MailCache } = load('harmony/entry/src/main/ets/data/MailCache.ets');
const model = load('harmony/entry/src/main/ets/data/MailCacheModel.ts');
const fileModel = load('harmony/entry/src/main/ets/data/MailContentFileModel.ts');
const { stableMessageKey } = load('harmony/entry/src/main/ets/mail/Conversation.ts');
const mail = (overrides = {}) => ({ id: 'one', threadId: 'thread', mailboxIds: ['inbox'], keywords: [],
  messageIds: [], from: [], to: [], replyTo: [], subject: 'Synthetic', preview: 'Saved preview', receivedAt: 1,
  hasAttachment: false, textBody: 'Body 中文 📬', htmlBody: '<p>Body 中文 📬</p>', hasHtmlBody: true,
  bodyTruncated: false, bodyEncodingProblem: false, ...overrides });
const mailbox = (overrides = {}) => ({ id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox',
  sortOrder: 0, totalEmails: 23, unreadEmails: 7, countsKnown: true,
  maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true, ...overrides });

// The second SQLite connection makes changes outside MailCache's operation
// queue, like another AccountStore handle. No production accounts/files/network.
async function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-raw-files-'));
  const sqlite = new DatabaseSync(path.join(directory, 'cache.db'));
  sqlite.exec("PRAGMA journal_mode=WAL; CREATE TABLE accounts(id TEXT PRIMARY KEY,status TEXT); INSERT INTO accounts VALUES ('a','ready'),('b','ready'),('pending','pending'),('deleting','deleting')");
  const other = new DatabaseSync(path.join(directory, 'cache.db'));
  const state = { reads: 0, writes: 0, maxRow: 0, cursors: 0, afterRead: null, afterWrite: null,
    failWrite: false, values: new Map() };
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      const next = () => {
        if (index >= rows.length) return false;
        const bytes = rows[index].reduce((n, v) => n + (typeof v === 'string' ? Buffer.byteLength(v) :
          v instanceof Uint8Array ? v.length : 8), 0);
        state.maxRow = Math.max(state.maxRow, bytes);
        if (bytes > 2 * 1024 * 1024) throw new Error('Synthetic ResultSet row exceeds 2 MiB');
        return true;
      };
      state.cursors++;
      return { goToFirstRow: () => { index = 0; return next(); }, goToNextRow: () => { index++; return next(); },
        getString: c => rows[index][c], getLong: c => rows[index][c], getBlob: c => rows[index][c],
        close: () => { state.cursors--; } };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK')
  };
  let tail = Promise.resolve();
  const queue = operation => { const task = tail.catch(() => {}).then(operation); tail = task; return task; };
  const files = {
    async write(account, kind, content) {
      if (state.failWrite) throw new Error('Synthetic file failure');
      const ref = `${account}/${randomUUID()}.${kind === 'text' ? 'txt' : 'html'}`;
      state.values.set(ref, content); state.writes++; await state.afterWrite?.(ref); return ref;
    },
    async read(account, ref, max) {
      state.reads++; assert.ok(fileModel.mailContentReferenceValid(account, ref));
      if (!state.values.has(ref)) throw new Error('Synthetic file missing');
      const value = state.values.get(ref); assert.ok(value.length <= max);
      await state.afterRead?.(ref); return value;
    },
    async forgetAccount() {}, async prune() {}
  };
  await MailCache.initialize(db);
  const cache = new MailCache(db, queue, undefined, files);
  return { sqlite, other, db, queue, cache, files, state,
    row: (id = 'one', account = 'a') => sqlite.prepare("SELECT payload,dirty FROM mail_cache WHERE account_id=? AND kind='email' AND cache_key=?").get(account, id),
    insert: (value, account = 'a') => sqlite.prepare("INSERT OR REPLACE INTO mail_cache VALUES (?,'email',?,?,0)").run(account, value.mail.id, JSON.stringify(value)),
    reopen: () => new MailCache(db, queue, undefined, files),
    close: () => { assert.equal(state.cursors, 0); other.close(); sqlite.close(); fs.rmSync(directory, { recursive: true }); } };
}

test('Large Unicode raw bodies use small DB references and hydrate byte-exactly after reopening', async () => {
  const f = await fixture();
  try {
    const source = mail({ textBody: '\ufeff' + 'Physics 中文 😀\n'.repeat(180000),
      htmlBody: '<html>' + '物理学 café 📬'.repeat(200000) + '</html>' });
    assert.ok(Buffer.byteLength(source.textBody + source.htmlBody) > 6 * 1024 * 1024);
    await f.cache.saveEmail('a', source);
    const record = JSON.parse(f.row().payload), savedAt = record.bodySavedAt;
    assert.ok(Buffer.byteLength(f.row().payload) < 1500);
    assert.equal(record.mail.textBody, null); assert.equal(record.mail.htmlBody, null);
    assert.equal(f.state.values.get(record.bodyFiles.text), source.textBody);
    assert.equal(f.state.values.get(record.bodyFiles.html), source.htmlBody);
    const loaded = await f.reopen().email('a', 'one');
    assert.deepEqual(loaded.mail, source); assert.equal(loaded.bodySavedAt, savedAt);
    assert.equal(f.state.writes, 2); assert.equal(f.state.reads, 2); assert.ok(f.state.maxRow < 1500);
  } finally { f.close(); }
});

test('Empty and absent body strings retain their original distinctions', async () => {
  const f = await fixture();
  try {
    for (const [index, bodies] of [[0,{textBody:'',htmlBody:null}], [1,{textBody:null,htmlBody:''}],
      [2,{textBody:null,htmlBody:undefined}], [3,{textBody:'',htmlBody:''}]]) {
      const source = mail({ id: 'empty' + index, ...bodies });
      await f.cache.saveEmail('a', source); const loaded = await f.cache.email('a', source.id);
      assert.equal(loaded.mail.textBody, bodies.textBody); assert.equal(loaded.mail.htmlBody, bodies.htmlBody);
      assert.ok(loaded.bodySavedAt !== null);
    }
    assert.equal(f.state.writes, 4);
  } finally { f.close(); }
});

test('Corrected server timestamps replace cached headers without rewriting downloaded bodies', async () => {
  const f = await fixture();
  try {
    const correct = Date.parse('2026-09-16T08:00:00+09:00');
    await f.cache.saveEmail('a', mail({ receivedAt: correct + 9 * 3600000 }));
    const before = JSON.parse(f.row().payload), writes = f.state.writes;
    await f.cache.saveView('a', 'inbox', [mail({ receivedAt: correct, textBody: null, htmlBody: null })]);
    const after = JSON.parse(f.row().payload);
    assert.equal(after.mail.receivedAt, correct);
    assert.equal(after.bodySavedAt, before.bodySavedAt);
    assert.deepEqual(after.bodyFiles, before.bodyFiles);
    assert.equal(f.state.writes, writes);
    assert.equal((await f.reopen().email('a', 'one')).mail.textBody, mail().textBody);
  } finally { f.close(); }
});

test('Attachment-only cache records survive header refresh and restart without inventing body text or losing attachment metadata', async () => {
  const f = await fixture();
  try {
    const attachments = [{ id: '2', name: '报告 résumé.pdf', contentType: 'application/pdf', size: 42, sizeIsEncoded: false }];
    const variants = [
      { textBody: null, htmlBody: null, hasHtmlBody: false },
      { textBody: '', htmlBody: null, hasHtmlBody: false },
      { textBody: null, htmlBody: '', hasHtmlBody: true },
      { textBody: null, htmlBody: undefined, hasHtmlBody: false }
    ];
    for (let index = 0; index < variants.length; index++) {
      const source = mail({ id: `attachment-only-${index}`, threadId: `attachment-only-${index}`,
        ...variants[index], hasAttachment: true, attachments });
      await f.cache.saveEmail('a', source);
      const before = JSON.parse(f.row(source.id).payload);
      const header = { ...source, subject: 'Updated header', textBody: null, htmlBody: null, attachments: undefined };
      const fileWrites = f.state.writes;
      await f.cache.saveView('a', 'inbox', [header]);
      await MailCache.initialize(f.db, f.files);
      const reopened = f.reopen(), cached = await reopened.email('a', source.id);
      assert.ok(cached); assert.equal(cached.bodySavedAt, before.bodySavedAt);
      assert.equal(cached.mail.subject, header.subject);
      assert.equal(cached.mail.textBody, variants[index].textBody);
      assert.equal(cached.mail.htmlBody, variants[index].htmlBody);
      assert.equal(cached.mail.hasHtmlBody, variants[index].hasHtmlBody);
      assert.deepEqual(cached.mail.attachments, attachments); assert.equal(cached.mail.hasAttachment, true);
      assert.equal(model.failedEmptyMailBody(cached.mail), false);
      assert.equal(model.cacheReadyForReading(cached), true);
      assert.deepEqual((await reopened.view('a', 'inbox')).emails[0].attachments, attachments);
      assert.equal(f.state.writes, fileWrites, 'Header reads and restart never rewrite attachment-only body files');
    }
    assert.equal(f.state.writes, 2, 'Only the two explicitly empty strings require body files');
  } finally { f.close(); }
});

test('The actual loader fetches an attachment-only message once, then opens the real cache offline after restart', async () => {
  const f = await fixture();
  const { actualLoaderFixture } = require('./reader-loader-fixture.cjs');
  const source = mail({ id: 'only-attachment', threadId: 'only-attachment', textBody: null, htmlBody: null,
    hasHtmlBody: false, hasAttachment: true,
    attachments: [{ id: '2', name: '物理学.pdf', contentType: 'application/pdf', size: 1234, sizeIsEncoded: true }] });
  const header = { ...source, attachments: undefined };
  let offline = false;
  const selected = actualLoaderFixture({ read: async () => {
    assert.equal(offline, false, 'A complete attachment-only record must not be downloaded again'); return source;
  } });
  selected.store.mail = f.cache;
  try {
    const first = await selected.open(header); await selected.loader.whenIdle();
    assert.deepEqual(first.mail.attachments, source.attachments);
    assert.equal(first.mail.textBody, null); assert.equal(first.mail.htmlBody, null);
    assert.equal(selected.state.reads.length, 1); assert.equal(selected.state.batches.length, 0);
    const saved = f.row(source.id).payload;
    await f.cache.saveView('a', 'inbox', [header]); await MailCache.initialize(f.db, f.files);
    selected.store.mail = f.reopen(); offline = true;
    const restarted = new selected.MailMessageLoader(selected.store);
    for (let count = 0; count < 3; count++) {
      const result = await restarted.open(selected.client, selected.account, header, 'Show', 'Hide', () => true);
      assert.deepEqual(result.mail.attachments, source.attachments);
      assert.equal(result.mail.textBody, null); assert.equal(result.mail.htmlBody, null);
      assert.deepEqual(result.document, first.document);
    }
    await restarted.whenIdle();
    assert.equal(selected.state.reads.length, 1); assert.equal(selected.state.scans, 1);
    assert.equal(selected.state.batches.length, 0); assert.equal(selected.tracked.size, 0);
    assert.equal(JSON.parse(f.row(source.id).payload).bodySavedAt, JSON.parse(saved).bodySavedAt);
    assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0, 'Metadata-only mail needs no text/HTML file');
  } finally { await selected.loader.whenIdle(); f.close(); }
});

test('Attachment metadata cannot turn a genuine failed-empty decode into a valid cached body', async () => {
  const f = await fixture();
  const { actualLoaderFixture } = require('./reader-loader-fixture.cjs');
  const broken = mail({ id: 'failed-attachment-body', threadId: 'failed-attachment-body', textBody: null, htmlBody: null,
    hasHtmlBody: false, hasAttachment: true, bodyEncodingProblem: true,
    attachments: [{ id: '2', name: 'saved.pdf', contentType: 'application/pdf', size: 4, sizeIsEncoded: false }] });
  const selected = actualLoaderFixture({ read: async () => broken }); selected.store.mail = f.cache;
  try {
    // Seed the old cache shape deliberately; successful attachment-only mail
    // must remain distinguishable from an earlier explicit decoder failure.
    await f.cache.saveEmail('a', broken);
    const record = await f.reopen().email('a', broken.id);
    assert.equal(model.failedEmptyMailBody(record.mail), true); assert.equal(model.cacheReadyForReading(record), false);
    await assert.rejects(selected.open({ ...broken, bodyEncodingProblem: false, attachments: undefined }), error => error.code === 'invalidResponse');
    await selected.loader.whenIdle();
    assert.equal(selected.state.reads.length, 1); assert.equal(selected.state.scans, 0);
    assert.equal(selected.documents.size, 0); assert.equal(selected.state.batches.length, 0);
    assert.equal(model.failedEmptyMailBody((await f.reopen().email('a', broken.id)).mail), true);
  } finally { await selected.loader.whenIdle(); f.close(); }
});

test('Header refresh, flags, dirty state, moves and startup reuse references with no body file I/O', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a', mail()); const original = JSON.parse(f.row().payload);
    f.state.reads = 0; f.state.writes = 0;
    await f.cache.saveView('a', 'inbox', [mail({ textBody:null,htmlBody:null,subject:'New header' })]);
    await f.cache.updateKeyword('a', 'one', '$seen', true);
    await f.cache.updateKeyword('a', 'one', '$flagged', true);
    await f.cache.updateMailboxes('a', 'one', ['archive']);
    await f.cache.markDirty('a', 'one');
    await MailCache.initialize(f.db, f.files);
    const current = JSON.parse(f.row().payload);
    assert.deepEqual(current.bodyFiles, original.bodyFiles); assert.equal(current.bodySavedAt, original.bodySavedAt);
    assert.equal(current.mail.subject, 'New header'); assert.deepEqual(current.mail.keywords, ['$seen','$flagged']);
    assert.deepEqual(current.mail.mailboxIds, ['archive']); assert.equal(f.row().dirty, 1);
    const summary = await f.cache.emailSummary('a', 'one'); assert.equal(summary.mail.cachedBodyAvailable, true);
    assert.equal(summary.mail.textBody, null); assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0);
  } finally { f.close(); }
});

test('Verified archive UID changes preserve offline content, original expiry and attachment origin without file work', async () => {
  const f = await fixture();
  try {
    const source = mail({threadId:'one',hasAttachment:true,attachments:[{id:'2',name:'论文.pdf',contentType:'application/pdf',size:100,sizeIsEncoded:true}]});
    await f.cache.saveEmail('a', source); await f.cache.saveView('a','inbox',[source]);
    const before = JSON.parse(f.row().payload), key = stableMessageKey(before.mail);
    const revision = MailCache.mutationRevision();
    f.state.reads=0;f.state.writes=0;
    await f.cache.moveEmailIdentity('a','one','archived',['archive']);
    const after = JSON.parse(f.row('archived').payload);
    assert.equal(f.row(),undefined);assert.equal(after.mail.id,'archived');assert.equal(after.mail.threadId,'archived');
    assert.equal(after.mail.cachedSourceId,'one');assert.equal(stableMessageKey(after.mail),key);
    assert.deepEqual(after.mail.cachedAttachmentSourceIds,['archived','one']);
    assert.deepEqual(after.bodyFiles,before.bodyFiles);assert.equal(after.bodySavedAt,before.bodySavedAt);
    assert.deepEqual(after.mail.attachments,before.mail.attachments);assert.equal(f.state.reads,0);assert.equal(f.state.writes,0);
    await f.cache.saveView('a','inbox',[source],null,undefined,revision);
    assert.equal(f.row(),undefined,'A header response started before the move cannot resurrect the old UID');
    assert.equal((await f.cache.view('a','inbox')).emails.length,0);
    assert.equal((await f.cache.view('a','archive')).emails[0].id,'archived');
    const reopened=await f.reopen().email('a','archived');assert.equal(reopened.mail.htmlBody,source.htmlBody);
    await f.cache.saveSyncedEmails('a',[mail({id:'archived',mailboxIds:['archive'],textBody:null,htmlBody:null})]);
    assert.equal((await f.cache.email('a','archived')).mail.cachedSourceId,'one');
    await f.cache.moveEmailIdentity('a','archived','restored',['inbox']);
    const restored=await f.cache.email('a','restored');assert.equal(restored.mail.cachedSourceId,'one');
    assert.equal(stableMessageKey(restored.mail),key);assert.equal(restored.bodySavedAt,before.bodySavedAt);
  } finally { f.close(); }
});

test('Archive identity migration preserves a newer destination body and pending target flags', async () => {
  const f=await fixture();
  try {
    await f.cache.saveEmail('a',mail());
    const target=model.cacheEmail(mail({id:'destination',threadId:'destination',mailboxIds:['archive'],textBody:'Newer',htmlBody:null,keywords:['$seen']}),true,null,Date.now());
    f.insert(target);await f.cache.markDirty('a','destination');
    await f.cache.moveEmailIdentity('a','one','destination',['archive']);
    const value=await f.cache.email('a','destination',true);
    assert.equal(value.mail.textBody,'Newer');assert.deepEqual(value.mail.keywords,['$seen']);
    assert.equal(value.mail.cachedSourceId,'destination');assert.equal(f.row('destination').dirty,1);
    assert.deepEqual(value.mail.cachedAttachmentSourceIds,['destination','one']);
  } finally { f.close(); }
});

test('Verified new Archive folder commits with the moved identity and remains available offline after restart', async () => {
  const f = await fixture();
  try {
    const source = mail(), inbox = mailbox({ archiveDestinationId: 'archive', archiveDestinationName: 'Archive' });
    const sent = mailbox({ id: 'sent', name: 'Sent items', role: 'sent', totalEmails: 41, unreadEmails: 0, sortOrder: 3 });
    await f.cache.saveBoxes('a', [inbox, sent], false);
    const previous = JSON.parse(f.sqlite.prepare("SELECT payload FROM mail_cache WHERE account_id='a' AND kind='boxes'").get().payload);
    await f.cache.saveEmail('a', source); await f.cache.saveView('a', 'inbox', [source]);
    const before = JSON.parse(f.row().payload);
    f.state.reads = 0; f.state.writes = 0;
    const receipt = mailbox({ id: 'archive', name: 'Archive', role: 'archive', totalEmails: 99, unreadEmails: 99, sortOrder: 9 });
    const execute = f.db.executeSql;
    let observedPending = 0;
    f.db.executeSql = async (sql, args = []) => {
      await execute(sql, args);
      if (sql.startsWith('INSERT OR REPLACE INTO mail_cache') && args[1] === 'boxes') {
        observedPending++;
        assert.equal(f.other.prepare("SELECT count(*) n FROM mail_cache WHERE account_id='a' AND kind='email' AND cache_key='archived'").get().n, 0);
        const visible = JSON.parse(f.other.prepare("SELECT payload FROM mail_cache WHERE account_id='a' AND kind='boxes'").get().payload);
        assert.deepEqual(visible, previous, 'Another WAL reader sees neither half of the uncommitted move');
      }
    };
    await f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], receipt);
    assert.equal(observedPending, 1); assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0);
    await MailCache.initialize(f.db, f.files);
    const restarted = f.reopen(), folders = await restarted.boxes('a');
    assert.equal(folders.savedAt, previous.savedAt); assert.equal(folders.roleRevision, previous.roleRevision);
    assert.equal(folders.readOnly, false); assert.equal(folders.boxes.length, 3);
    assert.deepEqual(folders.boxes[0], mailbox()); assert.deepEqual(folders.boxes[1], sent);
    assert.deepEqual(folders.boxes[2], { ...receipt, countsKnown: false, totalEmails: 0, unreadEmails: 0 });
    assert.equal((await restarted.view('a', 'inbox')).emails.length, 0);
    assert.equal((await restarted.view('a', 'archive')).emails[0].id, 'archived');
    const cached = await restarted.email('a', 'archived');
    assert.equal(cached.mail.htmlBody, source.htmlBody); assert.equal(cached.bodySavedAt, before.bodySavedAt);
    assert.deepEqual(cached.bodyFiles, before.bodyFiles);
    assert.equal(receipt.totalEmails, 99, 'Receipt arguments remain immutable');
    assert.equal(inbox.archiveDestinationId, 'archive', 'Caller-owned mailbox metadata remains immutable');
  } finally { f.close(); }
});

test('Confirmed existing Archive destination preserves counts, permissions, metadata and the folder envelope', async () => {
  const f = await fixture();
  try {
    const inbox = mailbox({ archiveDestinationId: 'archive', archiveDestinationName: 'Archive' });
    const old = mailbox({ id: 'former', role: 'archive', name: 'Old Archive', parentId: 'parent', totalEmails: 80, unreadEmails: 4 });
    const target = mailbox({ id: 'archive', role: null, name: 'Saved custom title', parentId: 'parent', sortOrder: 31,
      totalEmails: 17, unreadEmails: 5, countsKnown: true, maySetSeen: false, mayAddItems: false });
    await f.cache.saveBoxes('a', [inbox, old, target], true); await f.cache.saveEmail('a', mail());
    const before = JSON.parse(f.sqlite.prepare("SELECT payload FROM mail_cache WHERE account_id='a' AND kind='boxes'").get().payload);
    before.roleRevision = model.MAILBOX_ROLE_REVISION - 1;
    f.sqlite.prepare("UPDATE mail_cache SET payload=? WHERE account_id='a' AND kind='boxes'").run(JSON.stringify(before));
    await f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], mailbox({ id: 'archive', name: 'Protocol title', role: 'archive', countsKnown: false }));
    const after = await f.reopen().boxes('a');
    assert.deepEqual(after, { ...before, boxes: [mailbox(), { ...old, role: null }, { ...target, role: 'archive' }] });
    assert.equal(after.boxes.filter(box => box.role === 'archive').length, 1);
  } finally { f.close(); }
});

test('A folder listing started before Archive completion cannot erase the confirmed folder; a fresh listing stays authoritative', async () => {
  const f = await fixture();
  try {
    const inbox = mailbox({ archiveDestinationId: 'archive', archiveDestinationName: 'Archive' });
    await f.cache.saveBoxes('a', [inbox], false); await f.cache.saveEmail('a', mail());
    const beforeMove = MailCache.mutationRevision();
    await f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], mailbox({ id: 'archive', name: 'Archive', role: 'archive' }));
    const confirmed = await f.reopen().boxes('a');
    f.state.reads = 0; f.state.writes = 0;
    await f.cache.saveBoxes('a', [inbox], true, beforeMove);
    assert.deepEqual(await f.reopen().boxes('a'), confirmed, 'Stale LIST cannot restore a creation hint or discard the confirmed target');
    await f.cache.saveBoxes('b', [mailbox({ name: 'Other account listing' })], false, beforeMove);
    assert.equal((await f.cache.boxes('b')).boxes[0].name, 'Other account listing', 'The gate belongs only to the moved account');
    const fresh = [mailbox({ totalEmails: 22 }), mailbox({ id: 'archive', name: 'Server-renamed Archive', role: 'archive',
      totalEmails: 15, unreadEmails: 3, countsKnown: true })];
    await f.cache.saveBoxes('a', fresh, false, MailCache.mutationRevision());
    assert.deepEqual((await f.reopen().boxes('a')).boxes, fresh);
    assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0);
    assert.equal((await f.reopen().email('a', 'archived')).mail.htmlBody, mail().htmlBody);
  } finally { f.close(); }
});

test('A failed archive cache transaction rolls back the new folder, views and moved body together', async () => {
  const f = await fixture();
  try {
    await f.cache.saveBoxes('a', [mailbox({ archiveDestinationId: 'archive', archiveDestinationName: 'Archive' })], false);
    await f.cache.saveEmail('a', mail()); await f.cache.saveView('a', 'inbox', [mail()]);
    const rows = () => f.sqlite.prepare('SELECT * FROM mail_cache ORDER BY account_id,kind,cache_key').all();
    const before = rows(), revision = MailCache.mutationRevision();
    f.sqlite.exec("CREATE TRIGGER abort_move BEFORE DELETE ON mail_cache WHEN OLD.account_id='a' AND OLD.kind='email' AND OLD.cache_key='one' BEGIN SELECT RAISE(ABORT,'Synthetic move commit failure'); END");
    f.state.reads = 0; f.state.writes = 0;
    await assert.rejects(f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], mailbox({ id: 'archive', role: 'archive' })), /Synthetic move commit failure/);
    assert.deepEqual(rows(), before); assert.equal(MailCache.mutationRevision(), revision);
    assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0);
    assert.equal((await f.reopen().boxes('a')).boxes.length, 1);
    assert.equal((await f.reopen().email('a', 'one')).mail.textBody, mail().textBody);
  } finally { f.close(); }
});

test('Archive receipt rejects mismatched or malformed folders without touching cache', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a', mail());
    const before = f.row().payload;
    for (const receipt of [mailbox({ id: 'other', role: 'archive' }), mailbox({ id: 'archive', role: 'sent' }),
      mailbox({ id: 'archive', role: 'archive', countsKnown: 'false' }), mailbox({ id: '../archive', role: 'archive' })]) {
      await assert.rejects(f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], receipt), /Invalid archive mailbox receipt/);
      assert.equal(f.row().payload, before); assert.equal(f.row('archived'), undefined);
      assert.equal(await f.cache.boxes('a'), null);
    }
  } finally { f.close(); }
});

test('A removed or non-ready account cannot recreate an Archive folder from a late receipt', async () => {
  for (const state of ['pending', 'deleting', 'removed']) {
    const f = await fixture();
    try {
      await f.cache.saveEmail('a', mail());
      const before = f.row().payload;
      if (state === 'removed') f.other.prepare("DELETE FROM accounts WHERE id='a'").run();
      else f.other.prepare("UPDATE accounts SET status=? WHERE id='a'").run(state);
      await assert.rejects(f.cache.moveEmailIdentity('a', 'one', 'archived', ['archive'], mailbox({ id: 'archive', role: 'archive' })), /unavailable/);
      assert.equal(f.row().payload, before); assert.equal(f.row('archived'), undefined);
      assert.equal(f.sqlite.prepare("SELECT count(*) n FROM mail_cache WHERE kind IN ('boxes','view')").get().n, 0);
    } finally { f.close(); }
  }
});

test('Same-identity mailbox changes retain the existing JMAP path without installing receipt folders', async () => {
  const f = await fixture();
  try {
    const inbox = mailbox({ archiveDestinationId: 'archive', archiveDestinationName: 'Archive' });
    await f.cache.saveBoxes('a', [inbox], false); await f.cache.saveEmail('a', mail());
    const before = await f.cache.boxes('a');
    await f.cache.moveEmailIdentity('a', 'one', 'one', ['archive'], mailbox({ id: 'archive', role: 'archive' }));
    assert.deepEqual(await f.cache.boxes('a'), before);
    assert.deepEqual((await f.cache.email('a', 'one')).mail.mailboxIds, ['archive']);
  } finally { f.close(); }
});

test('Confirmed archive without a mapped UID retains an explicit local copy without inventing server identity', async () => {
  const f=await fixture();
  try {
    await f.cache.saveEmail('a',mail({messageIds:['shared@example.test']}));
    await f.cache.moveEmailIdentity('a','one','local_archive_example',['archive']);
    await f.cache.saveView('a','archive',[mail({id:'server_archive',mailboxIds:['archive'],messageIds:['shared@example.test'],textBody:null,htmlBody:null})]);
    const local=(await f.cache.view('a','archive')).emails[0];
    assert.equal(local.id,'local_archive_example');assert.equal(local.maySetSeen,false);
    const server=await f.cache.emailSummary('a','server_archive');assert.equal(server.mail.textBody,null);assert.equal(server.bodySavedAt,null);
    assert.equal((await f.cache.view('a','archive')).emails.length,2,'A header-only match cannot hide the offline copy');
    assert.equal((await f.reopen().email('a',local.id)).mail.textBody,mail().textBody);
    assert.equal(f.row(),undefined);
  } finally { f.close(); }
});

test('Archive rekey cannot cross account boundaries or overwrite missing/removed account data', async () => {
  const f=await fixture();
  try {
    await f.cache.saveEmail('a',mail());
    await assert.rejects(f.cache.moveEmailIdentity('b','one','two',['archive']));
    await assert.rejects(f.cache.moveEmailIdentity('a','one','../two',['archive']));
    assert.ok(f.row());assert.equal(f.row('two','b'),undefined);
    f.other.prepare("UPDATE accounts SET status='deleting' WHERE id='a'").run();
    await assert.rejects(f.cache.moveEmailIdentity('a','one','two',['archive']));
    assert.ok(f.row());assert.equal(f.row('two'),undefined);
  } finally { f.close(); }
});

test('Oversized legacy inline rows migrate once through bounded ResultSets without renewing retention', async () => {
  const f = await fixture();
  try {
    const source = mail({textBody:'Saved 中文 😀'.repeat(340000),htmlBody:null});
    const legacy = model.cacheEmail(source, true, null, Date.now()-1000); f.insert(legacy);
    assert.ok(Buffer.byteLength(f.row().payload) > 2 * 1024 * 1024);
    const first = await f.cache.email('a', 'one'); assert.deepEqual(first.mail, source);
    const pointer = JSON.parse(f.row().payload); assert.ok(pointer.bodyFiles.text);
    assert.equal(pointer.bodySavedAt, legacy.bodySavedAt); assert.equal(pointer.savedAt, legacy.savedAt);
    assert.equal((await f.reopen().email('a','one')).mail.textBody, source.textBody);
    assert.equal(f.state.writes, 1); assert.ok(f.state.maxRow < 300000);
  } finally { f.close(); }
});

test('Missing raw body files cause explicit loader fetch once and then reopen offline', async () => {
  const f = await fixture();
  const { actualLoaderFixture } = require('./reader-loader-fixture.cjs');
  const loader = actualLoaderFixture({ read: async () => mail() }); loader.store.mail = f.cache;
  try {
    await f.cache.saveEmail('a', mail()); f.state.values.clear();
    assert.equal(await f.cache.email('a','one'), null);
    const first = await loader.open(mail()); assert.equal(first.mail.textBody, mail().textBody);
    assert.equal(loader.state.reads.length, 1);
    assert.equal((await loader.open(mail())).mail.textBody, first.mail.textBody);
    assert.equal(loader.state.reads.length, 1); await loader.loader.whenIdle();
  } finally { f.close(); }
});

test('Unknown, pending and deleting accounts create no raw body files', async () => {
  const f = await fixture();
  try {
    for (const account of ['missing','pending','deleting']) await f.cache.saveEmail(account, mail());
    assert.equal(f.state.writes, 0); assert.equal(f.sqlite.prepare('SELECT count(*) n FROM mail_cache').get().n,0);
  } finally { f.close(); }
});

test('A separate handle retiring the account or replacing metadata during file reads prevents stale publication', async () => {
  for (const action of ['remove','pending','replace','dirty']) {
    const f = await fixture();
    try {
      await f.cache.saveEmail('a', mail());
      f.state.afterRead = () => { f.state.afterRead = null;
        if (action === 'remove') f.other.exec("DELETE FROM accounts WHERE id='a'");
        else if (action === 'pending') f.other.exec("UPDATE accounts SET status='pending' WHERE id='a'");
        else if (action === 'dirty') f.other.exec("UPDATE mail_cache SET dirty=1 WHERE account_id='a'");
        else { const replacement = JSON.parse(f.row().payload); replacement.mail.subject = 'Newer metadata';
          f.other.prepare("UPDATE mail_cache SET payload=? WHERE account_id='a' AND kind='email'").run(JSON.stringify(replacement)); }
      };
      assert.equal(await f.cache.email('a','one',true), null, action);
    } finally { f.close(); }
  }
});

test('Legacy file-first migration cannot overwrite a concurrent metadata change and safely retries current data', async () => {
  const f = await fixture();
  try {
    const legacy = model.cacheEmail(mail(),true,null,Date.now()-1000); f.insert(legacy);
    f.state.afterWrite = () => { f.state.afterWrite = null;
      const newer = structuredClone(legacy); newer.mail.subject = 'Concurrent header'; newer.mail.keywords = ['$flagged'];
      f.other.prepare("UPDATE mail_cache SET payload=?,dirty=1 WHERE account_id='a' AND kind='email'").run(JSON.stringify(newer));
    };
    assert.equal(await f.cache.email('a','one',true),null);
    const winner = JSON.parse(f.row().payload); assert.equal(winner.bodyFiles,undefined);
    assert.equal(winner.mail.subject,'Concurrent header'); assert.deepEqual(winner.mail.keywords,['$flagged']);
    const recovered = await f.cache.email('a','one',true); assert.equal(recovered.mail.subject,'Concurrent header');
    assert.equal(recovered.mail.textBody,legacy.mail.textBody); assert.equal(recovered.bodySavedAt,legacy.bodySavedAt);
    assert.equal(f.row().dirty,1); assert.ok(JSON.parse(f.row().payload).bodyFiles);
  } finally { f.close(); }
});

test('A failed legacy file write preserves the complete inline copy without publishing incomplete references', async () => {
  const f = await fixture();
  try {
    const legacy = model.cacheEmail(mail(),true,null,Date.now()); f.insert(legacy); f.state.failWrite = true;
    assert.equal((await f.cache.email('a','one')).mail.textBody,legacy.mail.textBody);
    assert.deepEqual(JSON.parse(f.row().payload),legacy); assert.equal(f.state.writes,0);
  } finally { f.close(); }
});

test('Cross-account references are never read, and expired references do not extend body retention', async () => {
  const f = await fixture();
  try {
    await f.cache.saveEmail('a',mail()); const owned = JSON.parse(f.row().payload);
    f.insert(owned,'b'); assert.equal(await f.cache.email('b','one'),null); assert.equal(f.state.reads,0);
    const expired = structuredClone(owned); expired.bodySavedAt = Date.now()-model.MAIL_RETENTION_MS;
    f.insert(expired); await MailCache.initialize(f.db, f.files);
    const pruned = JSON.parse(f.row().payload); assert.equal(pruned.bodyFiles,undefined); assert.equal(pruned.bodySavedAt,null);
    assert.equal(pruned.mail.subject,owned.mail.subject); assert.equal(f.state.reads,0);
  } finally { f.close(); }
});

test('Server Sent aliases share saved body files without copying or deleting the surviving body', async () => {
  const f = await fixture();
  try {
    const sent = mail({ id:'local_sent_one', mailboxIds:['sent'], messageIds:['same@example.test'] });
    await f.cache.saveEmail('a',sent); const original = JSON.parse(f.row(sent.id).payload);
    f.state.reads = 0; f.state.writes = 0;
    const header = mail({ id:'server_one', mailboxIds:['sent'], messageIds:['same@example.test'],textBody:null,htmlBody:null });
    await f.cache.saveView('a','sent',[header]);
    const alias = JSON.parse(f.row(header.id).payload);
    assert.deepEqual(alias.bodyFiles,original.bodyFiles); assert.equal(alias.bodySavedAt,original.bodySavedAt);
    assert.equal(f.state.reads,0); assert.equal(f.state.writes,0);
    await f.cache.forgetEmail('a',sent.id);
    const loaded = await f.cache.email('a',header.id);
    assert.equal(loaded.mail.textBody,sent.textBody); assert.equal(loaded.mail.htmlBody,sent.htmlBody);
    assert.equal(f.state.values.size,2); assert.equal(f.state.writes,0);
  } finally { f.close(); }
});


test('HTML and text files retain independent bounds without a combined JSON-body rejection', async () => {
  const f = await fixture();
  try {
    const source = mail({ textBody: 't'.repeat(200000), htmlBody: '<p>' + 'h'.repeat(8 * 1024 * 1024 - 10000) + '</p>' });
    assert.ok(JSON.stringify(source).length > 8 * 1024 * 1024);
    await f.cache.saveEmail('a', source);
    assert.ok(f.row().payload.length < 2000);
    const reopened = await f.reopen().email('a', source.id);
    assert.equal(reopened.mail.textBody, source.textBody); assert.equal(reopened.mail.htmlBody, source.htmlBody);
    assert.throws(() => f.cache.saveEmail('a', mail({ id: 'too_large', htmlBody: 'x'.repeat(8 * 1024 * 1024 + 1) })), /Invalid mail cache body/);
    assert.equal(f.row('too_large'), undefined);
  } finally { f.close(); }
});


test('Repeated verified moves bound attachment origins while keeping both current copies and selected body origin', async () => {
  const f=await fixture();
  try {
    await f.cache.saveEmail('a',mail({cachedAttachmentSourceIds:Array.from({length:16},(_,i)=>'older_'+i)}));
    const target=model.cacheEmail(mail({id:'new_target',mailboxIds:['archive'],textBody:'Newer target',htmlBody:null,
      cachedSourceId:'target_body',cachedAttachmentSourceIds:Array.from({length:16},(_,i)=>'target_'+i)}),true,null,Date.now());
    f.insert(target);
    await f.cache.moveEmailIdentity('a','one','new_target',['archive']);
    let saved=await f.cache.email('a','new_target');
    assert.equal(saved.mail.cachedAttachmentSourceIds.length,16);
    assert.equal(new Set(saved.mail.cachedAttachmentSourceIds).size,16);
    assert.deepEqual(saved.mail.cachedAttachmentSourceIds.slice(0,4),['new_target','one','target_body','older_0']);
    await f.cache.saveSyncedEmails('a',[mail({id:'new_target',mailboxIds:['archive'],textBody:null,htmlBody:null})]);
    const again=await f.reopen().email('a','new_target');
    assert.deepEqual(again.mail.cachedAttachmentSourceIds,saved.mail.cachedAttachmentSourceIds);
    await f.cache.moveEmailIdentity('a','new_target','restored',['inbox']);
    saved=await f.cache.email('a','restored');
    assert.equal(saved.mail.cachedAttachmentSourceIds.length,16);
    assert.deepEqual(saved.mail.cachedAttachmentSourceIds.slice(0,4),['restored','new_target','target_body','one']);
  } finally { f.close(); }
});

test('Attachment cache aliases reject traversal, duplicates and excess IDs', () => {
  for(const aliases of [['../another'],['a/b'],['duplicate','duplicate'],Array.from({length:17},(_,i)=>'id_'+i)]) {
    assert.throws(()=>model.cacheEmail(mail({cachedAttachmentSourceIds:aliases}),true,null,Date.now()));
  }
});

test('UUID attachments are valid only for a confirmed local Sent origin and survive server Sent adoption', async () => {
  const draft='123e4567-e89b-42d3-a456-426614174000', attachment='123e4567-e89b-42d3-a456-426614174001';
  const parts=[{id:attachment,name:'附件.pdf',contentType:'application/pdf',size:10,sizeIsEncoded:false}];
  for(const change of [{},{id:'local_sent_not_uuid'},{cachedSourceId:'local_sent_not_uuid'},
    {cachedAttachmentSourceIds:['local_sent_'+draft]}]) {
    assert.throws(()=>model.cacheEmail(mail({...change,hasAttachment:true,attachments:parts}),true,null,Date.now()));
  }
  const f=await fixture();
  try {
    const local=mail({id:'local_sent_'+draft,mailboxIds:['sent'],messageIds:['outgoing@example.test'],hasAttachment:true,attachments:parts});
    await f.cache.saveEmail('a',local);
    await f.cache.saveView('a','sent',[mail({id:'server_sent_uid',mailboxIds:['sent'],messageIds:local.messageIds,
      hasAttachment:true,textBody:null,htmlBody:null})]);
    const adopted=await f.reopen().email('a','server_sent_uid');
    assert.deepEqual(adopted.mail.attachments,parts);assert.equal(adopted.mail.cachedSourceId,local.id);
    assert.deepEqual(adopted.mail.cachedAttachmentSourceIds,[local.id]);
    assert.equal(adopted.mail.textBody,local.textBody);
  } finally { f.close(); }
});

test('Confirmed Trash move preserves body files, attachment origins, Archive role and creation hint', async () => {
  const f = await fixture();
  try {
    const inbox = mailbox({ archiveDestinationId: 'new_archive', archiveDestinationName: 'Archive' });
    const archive = mailbox({ id: 'archive', role: 'archive', name: 'Archive' });
    const trash = mailbox({ id: 'trash', role: 'trash', name: 'Trash' });
    const source = mail({ hasAttachment: true, attachments: [{ id: '2', name: 'report.pdf', contentType: 'application/pdf', size: 10, sizeIsEncoded: true }] });
    await f.cache.saveBoxes('a', [inbox, archive, trash], false);
    await f.cache.saveEmail('a', source); await f.cache.saveView('a', 'inbox', [source]);
    const before = await f.cache.email('a', 'one');
    await f.cache.moveEmailIdentity('a', 'one', 'trashed', ['trash'], trash);
    const after = await f.reopen().email('a', 'trashed');
    assert.equal(after.bodySavedAt, before.bodySavedAt); assert.deepEqual(after.bodyFiles, before.bodyFiles);
    assert.deepEqual(after.mail.attachments, source.attachments);
    assert.equal(after.mail.cachedSourceId, 'one'); assert.equal(after.mail.textBody, source.textBody);
    const boxes = (await f.reopen().boxes('a')).boxes;
    assert.equal(boxes.find(box => box.id === 'archive').role, 'archive');
    assert.equal(boxes.find(box => box.id === 'inbox').archiveDestinationId, 'new_archive');
    assert.equal((await f.reopen().view('a', 'inbox')).emails.length, 0);
    await f.cache.moveEmailIdentity('a', 'trashed', 'restored', ['inbox']);
    const restored = await f.reopen().email('a', 'restored');
    assert.deepEqual(restored.bodyFiles, before.bodyFiles); assert.equal(restored.mail.cachedSourceId, 'one');
  } finally { f.close(); }
});

test('Mailbox count boundaries through 5000 rows preserve exact message bodies and header pagination order', async () => {
  const f = await fixture();
  try {
    const rows = Array.from({ length: 5000 }, (_, index) => mail({ id: `count-${index + 1}`,
      threadId: `count-${index + 1}`, messageIds: [`count-${index + 1}@example.test`],
      textBody: null, htmlBody: null, hasHtmlBody: false }));
    const target = mail({ id: 'count-50', threadId: 'count-50', messageIds: ['count-50@example.test'],
      textBody: null, htmlBody: '<html><body>' + 'Synthetic newsletter 中文 &amp; café '.repeat(1400) + '</body></html>' });
    await f.cache.saveEmail('a', target);
    const original = await f.cache.email('a', target.id);
    for (const count of [49, 50, 51, 63, 64, 65, 199, 200, 201, 999, 1000, 1001, 5000]) {
      const selected = rows.slice(0, count);
      await f.cache.saveView('a', 'inbox', selected);
      const list = await f.reopen().view('a', 'inbox', true, false);
      assert.equal(list.emails.length, count, `header count ${count}`);
      assert.deepEqual(list.emails.map(value => value.id), selected.map(value => value.id));
      const saved = await f.reopen().email('a', target.id);
      assert.equal(saved.mail.htmlBody, target.htmlBody, `target body at count ${count}`);
      assert.equal(saved.bodySavedAt, original.bodySavedAt);
      assert.deepEqual(saved.bodyFiles, original.bodyFiles);
      const last = { ...selected.at(-1), htmlBody: `<p>Exact last body ${count}</p>`, hasHtmlBody: true };
      // Save and reopen a previously missing body at each boundary.
      if (last.id !== target.id) {
        await f.cache.saveEmail('a', last);
        assert.equal((await f.reopen().email('a', last.id)).mail.htmlBody, last.htmlBody);
      }
    }
    assert.equal(f.sqlite.prepare("SELECT COUNT(*) AS n FROM mail_cache WHERE account_id='a' AND kind='email'").get().n, 5000);
  } finally { f.close(); }
});
