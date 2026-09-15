const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');

function compile(source, imports = {}) {
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', code)(name => {
    if (!(name in imports)) throw new Error(`Unexpected dependency ${name}`);
    return imports[name];
  }, module, module.exports);
  return module.exports;
}
const model = compile(fs.readFileSync('harmony/entry/src/main/ets/data/RecipientHistory.ts', 'utf8'));
const sentModel = compile(fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/SentMail.ts', 'utf8'));
const { RecipientStore } = compile(fs.readFileSync('harmony/entry/src/main/ets/data/RecipientStore.ets', 'utf8'), {
  './RecipientHistory': model
});
const contact = (email, name = '', lastUsed = 100) => ({ email, name, lastUsed });
function fixture() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const db = {
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
      const rows = statement.all(...args); let index = -1;
      return { goToNextRow: () => ++index < rows.length, getString: column => rows[index][column],
        getLong: column => rows[index][column], close() {} };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK')
  };
  let pending = Promise.resolve();
  const queue = operation => { const task = pending.catch(() => {}).then(operation); pending = task.catch(() => {}); return task; };
  return { sqlite, db, queue, history: new RecipientStore(db, queue), reopen: () => new RecipientStore(db, queue) };
}

test('Recipient history persists offline by account, deduplicates case-insensitively, and retains a learned name', async () => {
  const f = fixture();
  try {
    await RecipientStore.initialize(f.db);
    await f.history.remember('a', [contact('Ada@example.test', 'Ada 王')]);
    await Promise.all([f.history.remember('a', [contact('ada@EXAMPLE.test', '', 200)]),
      f.history.remember('b', [contact('bob@example.test', 'Bob')])]);
    assert.deepEqual(await f.reopen().list('a'), [contact('ada@EXAMPLE.test', 'Ada 王', 200)]);
    assert.deepEqual(await f.reopen().list('b'), [contact('bob@example.test', 'Bob')]);
    // Re-reading older cached Sent data must not replace a newer spelling/name.
    await f.history.remember('a', [contact('ADA@example.test', 'Old name', 90)]);
    assert.deepEqual(await f.history.list('a'), [contact('ada@EXAMPLE.test', 'Ada 王', 200)]);
  } finally { f.sqlite.close(); }
});

test('Recipient storage cannot resurrect a deleted account and keeps only its 500 most recent addresses', async () => {
  const f = fixture();
  try {
    await RecipientStore.initialize(f.db);
    await f.history.remember('a', Array.from({ length: 520 }, (_, i) => contact(`person${i}@example.test`, '', i)));
    const rows = await f.history.list('a');
    assert.equal(rows.length, 500); assert.equal(rows[0].lastUsed, 519); assert.equal(rows.at(-1).lastUsed, 20);
    f.sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'; DELETE FROM recipient_history WHERE account_id = 'a'; DELETE FROM accounts WHERE id = 'a'");
    await f.history.remember('a', [contact('late@example.test')]);
    assert.deepEqual(await f.history.list('a'), []);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS count FROM recipient_history').get().count, 0);
  } finally { f.sqlite.close(); }
});

test('One changed recipient writes one row, capacity eviction touches two, and repeated backfill writes none', async () => {
  const f = fixture();
  try {
    await RecipientStore.initialize(f.db);
    const rows = Array.from({ length: 500 }, (_, i) => contact(`person${i}@example.test`, '', i));
    await f.history.remember('a', rows);
    const writes = [], execute = f.db.executeSql;
    f.db.executeSql = async (sql, args) => { writes.push([sql, args]); return execute(sql, args); };
    await f.history.remember('a', [contact('person250@example.test', 'Updated', 600)]);
    assert.equal(writes.length, 1);
    assert.match(writes[0][0], /^INSERT OR REPLACE/);
    assert.equal(writes[0][1][1], 'person250@example.test');
    writes.length = 0;
    await f.history.remember('a', [contact('new@example.test', 'New', 700)]);
    assert.equal(writes.length, 2);
    assert.match(writes[0][0], /^DELETE/);
    assert.deepEqual(writes[0][1], ['a', 'person0@example.test']);
    assert.equal((await f.history.list('a')).length, 500);
    writes.length = 0;
    await f.history.remember('a', rows);
    assert.equal(writes.length, 0, 'older cached Sent history must not rewrite the encrypted table');
  } finally { f.sqlite.close(); }
});

test('Recipient writes snapshot their input before waiting for other database work', async () => {
  const f = fixture();
  try {
    await RecipientStore.initialize(f.db);
    let release;
    const held = new Promise(resolve => { release = resolve; });
    f.queue(() => held);
    const added = [contact('original@example.test', 'Original', 200)];
    const write = f.history.remember('a', added);
    added[0].email = 'changed@example.test'; added[0].name = 'Changed'; added.length = 0;
    release(); await write;
    assert.deepEqual(await f.history.list('a'), [contact('original@example.test', 'Original', 200)]);
  } finally { f.sqlite.close(); }
});

function mail(id, mailboxIds, to, keywords = ['$seen']) {
  return { id, mailboxIds, to, cc: [], from: [{ email: 'sender@example.test', name: 'Sender' }], replyTo: [], keywords, receivedAt: 100 };
}
test('Backfill learns only explicitly identified cached Sent mail or locally confirmed copies, never incoming mail or drafts', () => {
  const messages = [mail('incoming', ['inbox'], [{ email: 'incoming-only@example.test', name: 'Incoming' }]),
    mail('server_sent_one', ['sent'], [{ email: 'sent@example.test', name: 'Known Sent' }]),
    mail('draft', ['sent'], [{ email: 'draft@example.test', name: 'Draft' }], ['$draft']),
    mail('ambiguous', ['unclassified'], [{ email: 'unclassified@example.test', name: '' }]),
    mail('local_sent_confirmed', ['local_sent'], [{ email: 'accepted@example.test', name: 'Accepted' }])];
  assert.deepEqual(model.cachedSentRecipients(messages, [{ id: 'sent', role: 'sent' }]).map(v => v.email).sort(),
    ['accepted@example.test', 'sent@example.test']);
  assert.deepEqual(model.cachedSentRecipients(messages, [{ id: 'unclassified', name: 'Sent', role: null }]).map(v => v.email),
    ['accepted@example.test']);
});

test('Confirmed To/Cc/Bcc addresses learn cached labels without learning unrelated incoming correspondents', () => {
  const names = model.knownRecipientNames([mail('incoming', ['inbox'], [], [])
    , { ...mail('second', ['inbox'], []), from: [{ email: 'ada@example.test', name: 'Ada 王' }] }]);
  const result = model.sentRecipients({ to: 'ADA@example.test', cc: 'bob@example.test; ada@example.test', bcc: 'secret@example.test' }, names, 300);
  assert.deepEqual(result.map(v => v.email), ['ada@example.test', 'bob@example.test', 'secret@example.test']);
  assert.equal(result[0].name, 'Ada 王'); assert.ok(result.every(v => v.lastUsed === 300));
});

test('Suggestions match names/email locally, suppress already-addressed recipients across fields, and replace only the active token', () => {
  const history = [contact('ada@example.test', 'Ada 王'), contact('amy@example.test', 'Amy'), contact('bob@example.test', 'Bob')];
  const value = 'bob@example.test; ad; untouched@example.test';
  const caret = value.indexOf('ad;') + 2;
  assert.deepEqual(model.recipientSuggestions(history, value, caret, ['amy@example.test']).map(v => v.email), ['ada@example.test']);
  assert.equal(model.completeRecipient(value, caret, 'ada@example.test'), 'bob@example.test; ada@example.test; untouched@example.test');
  assert.deepEqual(model.recipientSuggestions(history, '王', 1, []).map(v => v.email), ['ada@example.test']);
  assert.equal(model.completeRecipient('bob@example.test, a', 19, 'ada@example.test'), 'bob@example.test, ada@example.test');
  assert.equal(model.completeRecipient('a', 1, 'ada@example.test'), 'ada@example.test');
});

test('AccountStore backfill and confirmed-send learning use only the captured account cache', async () => {
  const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
  const methods = ['recipients', 'rememberRecipients'].map(name => source.match(new RegExp(`  async ${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
  const compiled = ts.transpileModule(`class Host { ${methods} }; return Host`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
  const Host = new Function('cachedSentRecipients', 'knownRecipientNames', 'sentRecipients', compiled)(model.cachedSentRecipients, model.knownRecipientNames, model.sentRecipients);
  const calls = [], stored = [];
  const host = new Host();
  host.recipientStore = { remember: async (id, rows) => stored.push({ id, rows }), list: async id => { calls.push(['list', id]); return []; } };
  host.mail = { cachedMessages: async (id, includeBody) => { calls.push(['cachedMessages', id, includeBody]); return [{ mail: mail('sent', ['sent'], [{ name: 'Ada', email: 'ada@example.test' }]) }]; },
    boxes: async id => { calls.push(['boxes', id]); return { boxes: [{ id: 'sent', role: 'sent' }] }; } };
  await host.recipients('account-a');
  await host.rememberRecipients('account-b', { to: 'ada@example.test', cc: '', bcc: '' }, 500);
  assert.deepEqual(calls, [['cachedMessages', 'account-a', false], ['boxes', 'account-a'], ['list', 'account-a'], ['cachedMessages', 'account-b', false]]);
  assert.deepEqual(stored.map(v => v.id), ['account-a', 'account-b']); assert.equal(stored[1].rows[0].name, 'Ada');
});

async function sendingFixture(outcome, historyFailure = false, saveFailure = false) {
  const learned = [], events = [];
  class SmtpError extends Error { constructor(code) { super(code); this.code = code; } }
  const submission = { accepted: true, messageId: 'sent@example.test', date: 500, textBody: 'Synthetic', sentCopy: 'failed' };
  const native = { SmtpError, submitMail: async (_settings, _from, _draft, validate) => {
    events.push(validate ? 'validate' : 'submit');
    if (outcome === 'preflight') throw new SmtpError('invalidMessage');
    if (validate) return { accepted: false };
    if (outcome === 'rejected') throw new SmtpError('rejected');
    if (outcome === 'uncertain') throw new SmtpError('deliveryUnconfirmed');
    return submission;
  } };
  const code = fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/BackgroundSend.ets', 'utf8');
  // AppStorage is the only UI dependency; synthetic writes stay in memory.
  const appStorage = { setOrCreate() {}, get() { return 0; } };
  const wrapped = `const AppStorage = globalThis.__recipientTestAppStorage;\n${code}`;
  globalThis.__recipientTestAppStorage = appStorage;
  const { BackgroundSend } = compile(wrapped, { './NativeSmtpClient': native, './SentMail': {
    setSendFailure: sentModel.setSendFailure, sendFailureDiagnostic: sentModel.sendFailureDiagnostic,
    sentMailbox: () => ({ id: 'sent' }), sentMessage: () => ({ id: 'synthetic' }),
    sentCompletionLabel: () => 'sent_copy_failed', sendFailureState: (_attempted, code) => code === 'deliveryUnconfirmed' ? 'unconfirmed' : 'draft',
    sendFailureLabel: state => state
  } });
  delete globalThis.__recipientTestAppStorage;
  const store = { saveSmtp: async () => {}, saveOutgoing: async (_id, draft) => {
    events.push(`save:${draft.state}`); if (saveFailure && draft.state === 'sent') throw new Error('synthetic disk failure');
  }, credentials: () => ({ authorization: async () => 'synthetic' }),
    rememberRecipients: async (id, fields, date) => { learned.push({ id, to: fields.to, cc: fields.cc, bcc: fields.bcc, date }); if (historyFailure) throw new Error('optional history failed'); },
    mail: { boxes: async () => ({ boxes: [] }), appendSent: async () => { events.push('saved sent'); } } };
  const account = { id: 'account-a', emailAddress: 'sender@example.test', sessionUrl: 'imaps://example.test', username: 'synthetic' };
  const draft = { id: 'draft', state: 'draft', to: 'ada@example.test', cc: 'bob@example.test', bcc: 'hidden@example.test' };
  const queued = BackgroundSend.queue(account, store, draft, { password: 'synthetic' });
  account.id = 'switched-account'; draft.to = 'changed@example.test';
  await queued.catch(() => {}); await BackgroundSend.whenIdle();
  return { learned, events, notices: BackgroundSend.takeNotices() };
}

test('Only accepted SMTP delivery learns the original To/Cc/Bcc, including a server Sent-copy failure', async () => {
  const sent = await sendingFixture('accepted');
  assert.deepEqual(sent.learned, [{ id: 'account-a', to: 'ada@example.test', cc: 'bob@example.test', bcc: 'hidden@example.test', date: 500 }]);
  assert.deepEqual(sent.notices, [{ accountId: 'account-a', label: 'sent_copy_failed' }]);
  for (const failure of ['preflight', 'rejected', 'uncertain']) {
    assert.deepEqual((await sendingFixture(failure)).learned, [], failure);
  }
});

test('Optional recipient-history failure cannot interrupt accepted-mail persistence; accepted delivery can learn despite later Sent cache failure', async () => {
  const historyFailed = await sendingFixture('accepted', true);
  assert.ok(historyFailed.events.includes('save:sent')); assert.ok(historyFailed.events.includes('saved sent'));
  assert.equal(historyFailed.notices[0].label, 'sent_copy_failed');
  const sentSaveFailed = await sendingFixture('accepted', false, true);
  assert.equal(sentSaveFailed.learned.length, 1); assert.equal(sentSaveFailed.notices[0].label, 'sent_save_error');
});
