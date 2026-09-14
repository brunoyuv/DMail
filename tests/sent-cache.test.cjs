const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

// Exercise the production cache and its transactions against real SQLite. The
// only substitution is HarmonyOS's RDB result adapter; these fixtures never use
// a provider, device account, or network transport.
async function fixture() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return rows.length > 0; },
        goToNextRow: () => ++index < rows.length, getString: column => rows[index][column],
        getLong: column => rows[index][column], close() {} };
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
    new Function('require', 'module', 'exports', compiled)(name => {
      if (name === '@kit.ArkData') return { relationalStore: {} };
      if (!name.startsWith('.')) throw new Error(`Unexpected dependency ${name}`);
      const base = path.resolve(path.dirname(file), name);
      return load(fs.existsSync(`${base}.ts`) ? `${base}.ts` : `${base}.ets`);
    }, module, module.exports);
    return module.exports;
  }
  const { MailCache } = load(path.resolve('harmony/entry/src/main/ets/data/MailCache.ets'));
  const { sentMailbox } = load(path.resolve('harmony/entry/src/main/ets/mail/smtp/SentMail.ts'));
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  await MailCache.initialize(db);
  return { cache: new MailCache(db, queue), reopen: () => new MailCache(db, queue), sentMailbox, sqlite,
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
function boxes(values, savedAt, roleRevision = 1) {
  return { version: 1, savedAt, boxes: values, readOnly: false, roleRevision };
}
function view(mailboxId, ids, savedAt, nextPosition = null, queryState) {
  return { version: 1, savedAt, mailboxId, ids, nextPosition, queryState };
}

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
    assert.equal(actualBoxes.roleRevision, 2); assert.equal(actualBoxes.readOnly, true);
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
      assert.equal(actual.roleRevision, 2);
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
