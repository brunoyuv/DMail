const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const moduleModel = { exports: {} };
new Function('module', 'exports', compile(fs.readFileSync('harmony/entry/src/main/ets/data/CompositionSettings.ts', 'utf8')))(moduleModel, moduleModel.exports);
const { CompositionSettings, normalizeComposition, applyComposition } = moduleModel.exports;
function methods(file, names) {
  const source = fs.readFileSync(file, 'utf8');
  return names.map(name => {
    const match = source.match(new RegExp(`  (?:private )?(?:async )?${name}\\([\\s\\S]*?\\n  }`));
    assert.ok(match, `Actual ${name} method exists`); return match[0];
  }).join('\n');
}
function draft(text = '') { return { id: 'draft', text, senderName: '', compositionApplied: false }; }
const defaults = { senderName: 'Ada 王', signature: 'Best regards,\nAda 王\nExample Company' };

test('Composition settings preserve Unicode and multiline signatures while removing header controls and enforcing bounds', () => {
  assert.deepEqual(normalizeComposition({ senderName: '  Ada\r\n王\t ', signature: '第一行\r\nSecond line\rThird\0' }),
    { senderName: 'Ada  王', signature: '第一行\nSecond line\nThird' });
  assert.throws(() => normalizeComposition({ senderName: 'x'.repeat(201), signature: '' }));
  assert.throws(() => normalizeComposition({ senderName: '', signature: 'x'.repeat(8001) }));
});

test('New messages, replies and forwards receive one signature before quoted content and preserve later manual edits', () => {
  const empty = draft(), reply = draft('\n\nOn yesterday, Sender wrote:\n> Quoted body'), forward = draft('\n\n---------- Forwarded message ----------\nOriginal');
  for (const value of [empty, reply, forward]) {
    const original = value.text;
    applyComposition(value, defaults);
    assert.equal(value.senderName, 'Ada 王'); assert.equal(value.compositionApplied, true);
    assert.equal(value.text, `\n\n${defaults.signature}${original ? `\n\n${original.replace(/^\n+/, '')}` : ''}`);
    const signed = value.text;
    applyComposition(value, defaults); assert.equal(value.text, signed);
    value.text = 'Manually rewritten without the automatic signature';
    applyComposition(value, { senderName: 'New account name', signature: 'New signature' });
    assert.equal(value.text, 'Manually rewritten without the automatic signature'); assert.equal(value.senderName, 'Ada 王');
  }
  const noSignature = draft('Existing quote'); applyComposition(noSignature, { senderName: '', signature: '  \n' });
  assert.equal(noSignature.text, 'Existing quote'); assert.equal(noSignature.compositionApplied, true);
});

function accountFixture() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL); INSERT INTO accounts VALUES ('a', 'ready'), ('b', 'ready')");
  const source = fs.readFileSync('harmony/entry/src/main/ets/data/AccountStore.ets', 'utf8');
  sqlite.exec(source.match(/CREATE TABLE IF NOT EXISTS account_composition[^']+/)[0]);
  sqlite.exec(source.match(/CREATE TABLE IF NOT EXISTS account_mail_actions[^"]+/)[0]);
  const code = compile(`class Host { ${methods('harmony/entry/src/main/ets/data/AccountStore.ets', ['composition', 'saveComposition', 'prepareNewOutgoing', 'mailAction', 'saveMailAction'])} }; return Host;`);
  const Host = new Function('CompositionSettings', 'normalizeComposition', 'applyComposition', code)(CompositionSettings, normalizeComposition, applyComposition);
  const host = new Host(); host.pending = Promise.resolve();
  host.enqueue = operation => { const task = host.pending.catch(() => {}).then(operation); host.pending = task.catch(() => {}); return task; };
  host.database = () => ({ executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => { const statement = sqlite.prepare(sql); statement.setReturnArrays(true); const rows = statement.all(...args);
      return { goToFirstRow: () => rows.length > 0, getString: col => rows[0][col], close() {} }; } });
  return { host, sqlite };
}

test('Sender and signature storage is account-scoped, persistent, ordered, and cannot restore removed accounts', async () => {
  const { host, sqlite } = accountFixture();
  try {
    assert.deepEqual(await host.composition('a'), new CompositionSettings());
    const first = { ...defaults };
    const pending = host.saveComposition('a', first); first.signature = 'Changed after submission'; await pending;
    await host.saveComposition('b', { senderName: 'Bob', signature: 'Bob signature' });
    assert.deepEqual(await host.composition('a'), defaults);
    assert.deepEqual(await host.composition('b'), { senderName: 'Bob', signature: 'Bob signature' });
    await Promise.all([host.saveComposition('a', { senderName: 'Ada', signature: 'Older edit' }), host.saveComposition('a', defaults)]);
    assert.deepEqual(await host.composition('a'), defaults);
    sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'; DELETE FROM account_composition WHERE account_id = 'a'; DELETE FROM accounts WHERE id = 'a'");
    await host.saveComposition('a', defaults);
    assert.deepEqual(await host.composition('a'), new CompositionSettings());
    assert.equal(sqlite.prepare("SELECT count(*) AS n FROM account_composition WHERE account_id = 'a'").get().n, 0);
  } finally { sqlite.close(); }
});

test('Preparing an outgoing draft snapshots its account settings once even if settings later change', async () => {
  const { host, sqlite } = accountFixture();
  try {
    await host.saveComposition('a', defaults); const value = draft();
    await host.prepareNewOutgoing('a', value);
    await host.saveComposition('a', { senderName: 'Changed', signature: 'Changed' });
    await host.prepareNewOutgoing('a', value);
    assert.equal(value.senderName, defaults.senderName); assert.equal(value.text, `\n\n${defaults.signature}`);
    const another = draft(); await host.prepareNewOutgoing('b', another);
    assert.equal(another.senderName, ''); assert.equal(another.text, '');
  } finally { sqlite.close(); }
});

function composeFixture(saved) {
  const code = compile(`class Host { ${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets', ['initialize', 'newDraft', 'cancel'])} }; return Host;`);
  class OutgoingDraft { constructor() { this.id = ''; this.text = ''; this.senderName = ''; this.compositionApplied = false; this.state = 'draft'; this.to = ''; this.cc = ''; this.bcc = ''; this.subject = ''; this.forwardHtml = ''; } }
  const Host = new Function('OutgoingDraft', 'BackgroundSend', 'util', code)(OutgoingDraft, { isSending: () => false, wasAccepted: () => false }, { generateRandomUUID: () => 'synthetic-new-draft' });
  let preparations = 0, closes = 0, prompts = 0;
  const host = new Host();
  Object.assign(host, { active: true, initializeRevision: 0, account: { id: 'a' }, initialText: '', loadRecipients() {}, savedFailureNotice: () => '', label: name => name,
    onClose: () => { closes++; }, getUIContext: () => ({ getPromptAction: () => ({}), showAlertDialog: () => { prompts++; } }),
    store: { outgoing: async () => saved, smtp: async () => ({ endpoint: 'smtp://example.test:587', username: 'synthetic', password: 'synthetic' }),
      prepareNewOutgoing: async (_id, value) => { preparations++; applyComposition(value, defaults); } } });
  return { host, counts: () => ({ preparations, closes, prompts }) };
}

test('Composer initializes signatures for fresh drafts while reopening legacy/manual drafts exactly as saved', async () => {
  const fresh = composeFixture(null); await fresh.host.initialize();
  assert.equal(fresh.host.draft.text, `\n\n${defaults.signature}`); assert.equal(fresh.counts().preparations, 1);
  fresh.host.cancel(); assert.deepEqual(fresh.counts(), { preparations: 1, closes: 1, prompts: 0 });
  fresh.host.draft.text = 'User writing\n\n' + defaults.signature; fresh.host.cancel(); assert.equal(fresh.counts().prompts, 1);
  const legacy = { id: 'saved-legacy', state: 'draft', text: 'Manually written\nMy existing signature', cc: '', bcc: '' };
  const old = composeFixture(legacy); await old.host.initialize();
  assert.equal(old.host.draft, legacy); assert.equal(old.host.draft.text, legacy.text); assert.equal(old.counts().preparations, 0);
});

test('Swipe action defaults to Archive and persists independently per account', async () => {
  const { host, sqlite } = accountFixture();
  try {
    assert.equal(await host.mailAction('a'), 'archive');
    await host.saveMailAction('a', 'delete');
    assert.equal(await host.mailAction('a'), 'delete');
    assert.equal(await host.mailAction('b'), 'archive');
    await host.saveComposition('a', defaults);
    assert.equal(await host.mailAction('a'), 'delete');
    await assert.rejects(host.saveMailAction('a', 'expunge'));
    assert.equal(await host.mailAction('a'), 'delete');
    sqlite.exec("UPDATE accounts SET status = 'deleting' WHERE id = 'a'; DELETE FROM account_mail_actions WHERE account_id = 'a'");
    await host.saveMailAction('a', 'delete');
    assert.equal(await host.mailAction('a'), 'archive');
    assert.equal(sqlite.prepare('SELECT COUNT(*) AS n FROM account_mail_actions').get().n, 0);
  } finally { sqlite.close(); }
});
