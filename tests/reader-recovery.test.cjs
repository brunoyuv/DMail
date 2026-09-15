const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { bindReaderLoader, MailMessageLoadCancelled } = require('./reader-loader-fixture.cjs');
const clone = value => JSON.parse(JSON.stringify(value));
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
function model(file) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compile(fs.readFileSync(file, 'utf8')))(name => {
    if (name === './MailContentFileModel') return require('../.tools/test-output/data/MailContentFileModel.js');
    assert.equal(name, '../mail/MessagePreview');
    return model('harmony/entry/src/main/ets/mail/MessagePreview.ts');
  }, module, module.exports); return module.exports;
}
const cache = model('harmony/entry/src/main/ets/data/MailCacheModel.ts');
const conversations = model('harmony/entry/src/main/ets/mail/Conversation.ts');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['read', 'applyReaderMetadata', 'showError'].map(name => {
  const found = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(found); return found[0];
}).join('\n');
const createHost = new Function('MailOperations', 'conversationMessages', 'stableMessageKey', 'shallowCopyEmail', 'MailMessageLoadCancelled', 'MailInboxUpdates', 'AutomaticMailWork',
  compile(`class Host { ${methods} }; return Host;`));
function message(id = 'old_message', textBody = null) {
  return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds: ['inbox'], keywords: ['$seen'],
    from: [], to: [], cc: [], replyTo: [], references: [], inReplyTo: [], subject: 'Years-old synthetic message',
    preview: 'Downloaded summary', receivedAt: Date.UTC(2001, 0, 1), textBody, htmlBody: null,
    hasAttachment: false, hasHtmlBody: false, bodyTruncated: false, bodyEncodingProblem: false };
}
function fixture() {
  const summary = message(), state = { stored: null, document: null, bodyReads: 0, summaryReads: 0, documentReads: 0,
    networkCalls: 0, changes: 0, pending: false, foreground: true, paths: [], beforeDocument: async () => {} };
  const Host = createHost({ pending: () => state.pending, overlay: (_account, mail) => ({ ...mail }) },
    conversations.conversationMessages, conversations.stableMessageKey, value => ({ ...value }),
    MailMessageLoadCancelled, { isForeground: () => state.foreground }, { cancelInactive() {} });
  const ui = new Host();
  Object.assign(ui, { active: true, account: { id: 'a', serverId: 'server-a' }, generation: 1, mailboxRefreshRevision: 0,
    selected: null, selectedId: '', bodyLoaded: false, busy: false, readOnly: false, refreshRequired: false,
    savedCopyAt: 0, savedCopyFromDirty: false, boxesDirty: false, boxes: [], emails: [summary], conversationIndex: [],
    cacheWarning: false, error: '', label: name => name, paths: {
      getAllPathName: () => state.paths.slice(), pushPathByName: name => state.paths.push(name),
      pop: () => state.paths.pop()
    }, allows: () => false, changeKeyword: async () => { state.changes++; state.pending = true; },
    client: { readEmail: async () => { state.networkCalls++; throw Object.assign(new Error('Synthetic missing body'), { code: 'network' }); },
      mailboxes: async () => { state.networkCalls++; throw new Error('Reader must never fetch folders'); } },
    accountStore: { mail: {
      email: async () => {
        state.bodyReads++;
        if (!state.stored) return null;
        const value = cache.retainedEmail(clone(state.stored)); return value.bodySavedAt === null ? null : value;
      },
      saveEmail: async (_account, mail) => { state.stored = cache.cacheEmail(mail, true, state.stored, Date.now()); },
      emailSummary: async () => { state.summaryReads++; return state.stored ? cache.cachedEmailSummary(clone(state.stored)) : null; }
    }, documents: { read: async () => { state.documentReads++; await state.beforeDocument(); return { document: state.document }; } } }
  });
  bindReaderLoader(ui, state, conversations.stableMessageKey);
  return { ui, state, summary };
}
function save(f, text = 'Saved body', time = Date.now() - 7200000) {
  f.state.stored = cache.cacheEmail(message(f.summary.id, text), true, null, time);
  return time;
}

test('Opening an uncached message delegates once and a failed reader exposes explicit Retry', async () => {
  const f = fixture(); await f.ui.read(f.summary);
  assert.equal(f.ui.bodyLoaded, false); assert.equal(f.ui.selected.id, f.summary.id);
  assert.equal(f.ui.error, 'account_network_error'); assert.equal(f.state.networkCalls, 1);
  assert.equal(f.state.loaderCalls.length, 1);
  assert.match(source, /\.id\('retry-message'\)/);
  assert.match(source, /body_not_saved/);
  assert.doesNotMatch(source, /message_pending_sync/);
});

test('A selected download remains visibly busy until completion and then publishes one fixed body', async () => {
  const f = fixture(); let finish;
  const document = { html: '<p>Downloaded fixed document</p>', pictures: [] };
  f.state.loadMessage = async () => new Promise(resolve => { finish = resolve; });
  const loading = f.ui.read(f.summary);
  assert.equal(f.ui.busy, true); assert.equal(f.ui.bodyLoaded, false);
  for (let index = 0; index < 10; index++) await f.ui.read(f.summary);
  assert.equal(f.state.loaderCalls.length, 1); assert.deepEqual(f.state.paths, ['read']);
  finish({ mail: message(f.summary.id, 'Downloaded requested body'), document }); await loading;
  assert.equal(f.ui.busy, false); assert.equal(f.ui.bodyLoaded, true);
  assert.equal(f.ui.selected.textBody, 'Downloaded requested body'); assert.strictEqual(f.ui.readerDocument, document);
  await f.ui.read(f.summary); assert.equal(f.state.loaderCalls.length, 1);
});

test('Explicit retry after a failed selected load can complete without adding a reader destination', async () => {
  const f = fixture(); await f.ui.read(f.summary); assert.equal(f.ui.bodyLoaded, false);
  f.ui.client.readEmail = async () => { f.state.networkCalls++; return message(f.summary.id, 'Requested retry completed'); };
  const click = source.match(/\.id\('retry-message'\)\s*\.onClick\(\(\) => \{([\s\S]*?)\}\)/);
  assert.ok(click, 'Use the actual retry button action');
  const read = f.ui.read.bind(f.ui); let retry;
  f.ui.read = (...args) => { retry = read(...args); return retry; };
  new Function(click[1]).call(f.ui); assert.ok(retry); await retry;
  assert.equal(f.ui.bodyLoaded, true); assert.equal(f.ui.error, ''); assert.equal(f.ui.busy, false);
  assert.equal(f.ui.selected.textBody, 'Requested retry completed'); assert.equal(f.state.networkCalls, 2);
  assert.deepEqual(f.state.paths, ['read']);
});

test('A fresh saved old or partial body opens without decoder upgrades, downloads or timestamp rewrites', async () => {
  const f = fixture(), savedAt = save(f);
  delete f.state.stored.bodyDecoderRevision; f.state.stored.mail.bodyTruncated = true;
  await f.ui.read(f.summary);
  assert.equal(f.ui.bodyLoaded, true); assert.equal(f.ui.selected.textBody, 'Saved body');
  assert.equal(f.ui.selected.bodyTruncated, true); assert.equal(f.state.stored.bodySavedAt, savedAt);
  assert.equal(f.state.networkCalls, 0); assert.equal(f.state.bodyReads, 1); assert.equal(f.state.summaryReads, 1);
});

test('Prepared HTML including a broken picture is kept exactly while later sync updates storage', async () => {
  const f = fixture(); save(f);
  const document = { html: '<html><img src="https://mail.invalid/picture/saved/missing"></html>', pictures: [] };
  f.state.document = document;
  await f.ui.read(f.summary); assert.strictEqual(f.ui.readerDocument, document);
  save(f, 'Body from later sync'); f.state.document = { html: 'Later saved document', pictures: [] };
  await f.ui.read(f.summary);
  assert.strictEqual(f.ui.readerDocument, document); assert.equal(f.ui.selected.textBody, 'Saved body');
  f.ui.paths.pop(); await f.ui.read(f.summary);
  assert.equal(f.ui.readerDocument.html, 'Later saved document');
  assert.equal(f.state.networkCalls, 0);
});

test('A flag acknowledgement while reading the saved document updates only metadata', async () => {
  const f = fixture(); save(f); f.state.stored.stateDirty = true; f.state.pending = true;
  f.state.beforeDocument = async () => {
    f.state.pending = false; f.state.stored.stateDirty = false;
    f.state.stored.mail.keywords = ['$flagged']; f.state.stored.mail.textBody = 'A later sync body';
    f.state.stored.mail.subject = 'A later sync subject';
  };
  await f.ui.read(f.summary);
  assert.equal(f.ui.selected.textBody, 'Saved body'); assert.equal(f.ui.selected.subject, f.summary.subject);
  assert.deepEqual(f.ui.selected.keywords, ['$flagged']); assert.equal(f.ui.refreshRequired, false);
  assert.equal(f.state.bodyReads, 1); assert.equal(f.state.summaryReads, 1); assert.equal(f.state.networkCalls, 0);
});

test('A loader storage error leaves the reader retryable without publishing a partial result', async () => {
  const f = fixture(); save(f);
  f.state.loadMessage = async () => { throw Object.assign(new Error('Synthetic storage failure'), { code: 'storage' }); };
  await f.ui.read(f.summary);
  assert.equal(f.ui.bodyLoaded, false); assert.equal(f.ui.error, 'account_network_error');
  assert.equal(f.state.stored.mail.textBody, 'Saved body');
  assert.equal(f.ui.readerDocument, null); assert.equal(f.state.networkCalls, 0);
  const broken = fixture(); broken.ui.accountStore.mail.email = async () => { throw new Error('Synthetic storage failure'); };
  await broken.ui.read(broken.summary);
  assert.equal(broken.ui.error, 'account_network_error'); assert.equal(broken.ui.bodyLoaded, false);
  assert.equal(broken.state.networkCalls, 0);
});

test('A late local body read cannot replace a different account or navigated message', async () => {
  const f = fixture(); save(f); let finish;
  f.ui.accountStore.mail.email = () => new Promise(resolve => { finish = resolve; });
  const reading = f.ui.read(f.summary);
  f.ui.generation++; f.ui.account = { id: 'b', serverId: 'server-b' };
  f.ui.selected = message('other', 'Other account body');
  finish(clone(f.state.stored)); await reading;
  assert.equal(f.ui.selected.textBody, 'Other account body'); assert.equal(f.state.documentReads, 0);
});

test('An expired selected body is requested, while opening a saved unread body marks it once', async () => {
  const expired = fixture(); save(expired, 'Expired', Date.now() - cache.MAIL_RETENTION_MS - 1);
  await expired.ui.read(expired.summary);
  assert.equal(expired.ui.bodyLoaded, false); assert.equal(expired.state.networkCalls, 1); assert.equal(expired.ui.error, 'account_network_error');
  for (const pending of [false, true]) {
    const f = fixture(); save(f); f.state.stored.mail.keywords = []; f.state.pending = pending;
    f.ui.allows = () => !f.ui.busy && !f.ui.refreshRequired;
    await f.ui.read(f.summary); await f.ui.read(f.summary);
    assert.equal(f.state.changes, pending ? 0 : 1); assert.equal(f.state.networkCalls, 0);
  }
});

test('A late download cannot replace a newer message or publish after backgrounding', async () => {
  for (const background of [false, true]) {
    const f = fixture(); let finish;
    f.state.loadMessage = async () => new Promise(resolve => { finish = resolve; });
    const loading = f.ui.read(f.summary);
    if (background) f.state.foreground = false;
    else { f.ui.generation++; f.ui.selected = message('new', 'New reader body'); f.ui.selectedId = 'new'; }
    finish({ mail: message(f.summary.id, 'Late body'), document: null }); await loading;
    assert.notEqual(f.ui.selected.textBody, 'Late body'); assert.equal(f.ui.error, '');
  }
});

test('A stalled metadata read cannot keep a downloaded HTML body behind the spinner', async () => {
  const f = fixture(); save(f);
  let finish;
  f.ui.accountStore.mail.emailSummary = () => new Promise(resolve => { finish = resolve; });
  await f.ui.read(f.summary);
  assert.equal(f.ui.busy, false); assert.equal(f.ui.bodyLoaded, true);
  assert.equal(f.ui.selected.textBody, 'Saved body');
  f.ui.generation++; f.ui.selected = message('new', 'Newly selected body'); f.ui.selectedId = 'new';
  finish(cache.cachedEmailSummary(f.state.stored)); await Promise.resolve();
  assert.equal(f.ui.selected.id, 'new'); assert.equal(f.ui.selected.textBody, 'Newly selected body');
});
