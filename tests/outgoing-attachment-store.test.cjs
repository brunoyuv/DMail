const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
function load(source, imports = {}) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compile(fs.readFileSync(source, 'utf8')))(name => {
    assert.ok(name in imports, name); return imports[name];
  }, module, module.exports);
  return module.exports;
}
const dto = load('harmony/entry/src/main/ets/mail/smtp/OutgoingAttachments.ts');
const model = load('harmony/entry/src/main/ets/mail/attachments/OutgoingAttachmentModel.ts', { '../smtp/OutgoingAttachments': dto });
const { cacheIsFresh } = require('../.tools/test-output/data/MailCacheModel.js');
const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
function method(name) {
  const match = source.match(new RegExp(`  (?:private )?(?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(match, name); return match[0];
}
const Host = new Function('outgoingAccountValid', 'outgoingUUIDValid', 'cacheIsFresh', compile(`class Host {
  ${method('clearOutgoing')}
  ${method('pruneOutgoingFiles')}
}; return Host;`))(model.outgoingAccountValid, model.outgoingUUIDValid, cacheIsFresh);
const first = '11111111-1111-1111-1111-111111111111', second = '22222222-2222-2222-2222-222222222222';
const third = '33333333-3333-3333-3333-333333333333', fourth = '44444444-4444-4444-4444-444444444444';
const week = 7 * 24 * 60 * 60 * 1000;
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dmail-attachment-store-')), file = path.join(root, 'accounts.sqlite');
  const writer = new DatabaseSync(file), reader = new DatabaseSync(file);
  writer.exec(`PRAGMA journal_mode=WAL; CREATE TABLE outgoing_drafts (account_id TEXT PRIMARY KEY, payload TEXT);
    CREATE TABLE mail_cache (account_id TEXT, kind TEXT, cache_key TEXT, payload TEXT);`);
  t.after(() => { reader.close(); writer.close(); fs.rmSync(root, { force: true, recursive: true }); });
  const state = { pruned: [], forgotten: [], queries: [], returnedStrings: [], beforeDelete: null, noJSON: false, deleteFail: false, cleanupFail: false };
  const host = new Host(); let pending = Promise.resolve();
  host.enqueue = operation => { const job = pending.catch(() => {}).then(operation); pending = job.catch(() => {}); return job; };
  host.database = () => ({
    querySql: async (sql, args = []) => {
      state.queries.push(sql); if (state.noJSON && sql.includes('json_')) throw new Error('JSON functions unavailable');
      const stmt = reader.prepare(sql); stmt.setReturnArrays(true); const rows = stmt.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return rows.length > 0; }, goToNextRow: () => ++index < rows.length,
        getString: col => { const value = String(rows[index][col] ?? ''); state.returnedStrings.push(value); assert.ok(value.length <= 128, 'Only bounded owner identifiers may cross the database boundary'); return value; },
        getLong: col => Number(rows[index][col] ?? 0), getDouble: col => Number(rows[index][col]), close() {} };
    },
    executeSql: async (sql, args) => {
      if (state.deleteFail) throw new Error('Synthetic disk failure');
      if (state.beforeDelete) { const callback = state.beforeDelete; state.beforeDelete = null; callback(); }
      writer.prepare(sql).run(...args);
    }
  });
  host.outgoingFiles = {
    prune: async refs => state.pruned.push(refs),
    forgetDraft: async (account, id) => {
      assert.equal(reader.prepare('SELECT 1 FROM outgoing_drafts WHERE account_id = ? AND json_extract(payload, \'$.id\') = ?').get(account, id), undefined,
        'The independent WAL reader must see the committed deletion before cleanup');
      state.forgotten.push([account, id]); if (state.cleanupFail) throw new Error('Synthetic cleanup failure');
    }
  };
  const draft = (account, id, status = 'draft') => writer.prepare('INSERT OR REPLACE INTO outgoing_drafts VALUES (?, ?)').run(account,
    JSON.stringify({ id, state: status, text: 'large draft body '.repeat(100000), attachments: [] }));
  const mail = (account, id, savedAt, cachedSourceId) => writer.prepare('INSERT INTO mail_cache VALUES (?, ?, ?, ?)').run(account, 'email', id,
    JSON.stringify({ bodySavedAt: savedAt, savedAt: Date.now(), mail: { id, cachedSourceId, htmlBody: '<p>large cached body</p>'.repeat(100000) } }));
  return { host, writer, reader, state, draft, mail };
}

test('Startup retention reads complete small ownership projections and preserves all outgoing states plus fresh local Sent origins', async t => {
  const f = fixture(t); f.draft('a', first, 'unconfirmed'); f.draft('b', second, 'sent');
  f.mail('a', 'local_sent_' + third, Date.now());
  f.mail('b', 'server-imap-id', Date.now(), 'local_sent_' + fourth);
  f.mail('expired', 'local_sent_' + first, Date.now() - week - 1);
  f.mail('headers', 'local_sent_' + second, null);
  f.mail('normal', 'ordinary-message', Date.now());
  await f.host.pruneOutgoingFiles();
  assert.deepEqual(f.state.pruned, [[`a/${first}`, `b/${second}`, `a/${third}`, `b/${fourth}`]]);
  assert.equal(f.state.forgotten.length, 0);
  assert.ok(f.state.queries.every(sql => !/SELECT\s+payload|SELECT\s+\*/i.test(sql)));
  assert.ok(f.state.returnedStrings.every(value => !value.includes('body')));
});

test('Missing JSON support or malformed ownership skips the entire startup cleanup without risking draft files', async t => {
  const f = fixture(t); f.draft('a', first);
  f.state.noJSON = true; await assert.rejects(f.host.pruneOutgoingFiles(), /JSON/); f.state.noJSON = false;
  f.draft('b', 'invalid-id'); await f.host.pruneOutgoingFiles(); assert.equal(f.state.pruned.length, 0);
  f.writer.prepare('DELETE FROM outgoing_drafts WHERE account_id = ?').run('b');
  f.mail('a', 'server-id', Date.now(), 'local_sent_invalid'); await f.host.pruneOutgoingFiles(); assert.equal(f.state.pruned.length, 0);
  f.writer.exec('DELETE FROM mail_cache');
  f.writer.prepare('INSERT INTO mail_cache VALUES (?, ?, ?, ?)').run('a', 'email', 'broken', '{broken JSON');
  await f.host.pruneOutgoingFiles(); assert.equal(f.state.pruned.length, 0);
});

test('Explicit discard deletes the exact draft before file cleanup; stale discard and sent or sending rows are preserved', async t => {
  const f = fixture(t); f.draft('a', first); f.draft('b', second);
  await f.host.clearOutgoing('a', second); assert.equal(f.state.forgotten.length, 0);
  assert.ok(f.reader.prepare('SELECT 1 FROM outgoing_drafts WHERE account_id = ?').get('a'));
  await f.host.clearOutgoing('a', first); assert.deepEqual(f.state.forgotten, [['a', first]]);
  assert.ok(f.reader.prepare('SELECT 1 FROM outgoing_drafts WHERE account_id = ?').get('b'));
  for (const state of ['sent', 'sending', 'unconfirmed']) {
    f.draft('a', first, state); await assert.rejects(f.host.clearOutgoing('a', first), /cannot be discarded/);
  }
  assert.equal(f.state.forgotten.length, 1);
  await f.host.clearOutgoing('b'); assert.deepEqual(f.state.forgotten, [['a', first], ['b', second]]);
});

test('Deletion failure or a concurrently started send cannot delete files; cleanup failure leaves no saved dangling reference', async t => {
  const f = fixture(t); f.draft('a', first);
  f.state.deleteFail = true; await assert.rejects(f.host.clearOutgoing('a', first)); f.state.deleteFail = false;
  assert.equal(f.state.forgotten.length, 0);
  f.state.beforeDelete = () => f.draft('a', first, 'sending');
  await assert.rejects(f.host.clearOutgoing('a', first), /changed before discard/); assert.equal(f.state.forgotten.length, 0);
  f.draft('a', first); f.state.cleanupFail = true; await f.host.clearOutgoing('a', first);
  assert.equal(f.reader.prepare('SELECT 1 FROM outgoing_drafts WHERE account_id = ?').get('a'), undefined);
  assert.deepEqual(f.state.forgotten, [['a', first]]);
});
