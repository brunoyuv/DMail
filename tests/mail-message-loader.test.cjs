const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { JmapError } = require('../.tools/test-output/mail/jmap/JmapClient');
const model = require('../.tools/test-output/data/MailCacheModel');
const { stableMessageKey } = require('../.tools/test-output/mail/Conversation');
const html = require('../.tools/test-output/mail/html/HtmlDocument');
const plan = require('../.tools/test-output/mail/html/HtmlPicturePlan');
const copy = value => structuredClone(value);
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const mail = (id = 'one', fields = {}) => ({ id, threadId: id, messageIds: [id + '@example.test'], mailboxIds: ['inbox'],
  keywords: [], from: [], to: [], replyTo: [], subject: 'Synthetic ' + id, preview: 'Preview', receivedAt: 100,
  hasAttachment: false, textBody: 'Body ' + id, htmlBody: '<p>Body ' + id + '</p><img src="https://images.example.test/' + id + '.png">',
  bodyEncodingProblem: false, bodyTruncated: false, hasHtmlBody: true, ...fields });

// Also usable by the isolated ConnectedMail method fixture: it can pass the
// real loader a synthetic store without replacing loader ownership/cache logic.
function loadLoaderModule(overrides = {}) {
  const module = { exports: {} };
  const imports = {
    '../data/MailCache': { MailCache: { mutationRevision: () => 42 } },
    '../data/MailCacheModel': model,
    '../data/PictureSnapshot': { loadPictureSnapshot: overrides.loadPictureSnapshot || (async () => { throw new Error('Unexpected picture batch'); }) },
    './jmap/JmapClient': { JmapError }, './Conversation': { stableMessageKey }, './html/HtmlDocument': html,
    './html/HtmlPicturePlan': { prepareStaticMailHtml: overrides.prepareStaticMailHtml || plan.prepareStaticMailHtml }
  };
  const source = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/MailMessageLoader.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', source)(name => {
    assert.ok(name in imports, 'Unexpected loader dependency ' + name); return imports[name];
  }, module, module.exports);
  return module.exports;
}

function fixture(options = {}) {
  const bodies = new Map(), documents = new Map(), attempts = new Set(), tracked = new Set();
  const state = { reads: [], saves: [], scans: 0, batches: [], cancels: [], cacheReads: [], documentReads: [],
    failCache: false, failDocument: false, failSave: false, failAttempt: false };
  const key = (a, id) => a + ':' + id;
  const store = {
    trackMailSync: task => { tracked.add(task); task.finally(() => tracked.delete(task)); },
    get sync() { assert.fail('The selected-message loader must not consult the durable mailbox backlog'); },
    get mailSyncAvailable() { assert.fail('Bulk worker availability must not gate selected mail'); },
    mail: {
      email: async (a, id) => { state.cacheReads.push([a, id]); if (state.failCache) throw new Error('private storage detail');
        return copy(bodies.get(key(a, id)) || null); },
      saveEmail: async (a, value, revision) => { if (state.failSave) throw new Error('private storage detail');
        state.saves.push([a, value.id, revision]); bodies.set(key(a, value.id), model.cacheEmail(value, true, null, Date.now())); }
    },
    documents: {
      read: async (a, k) => { state.documentReads.push([a, k]); if (state.failDocument) throw new Error('private document detail');
        return copy(documents.get(key(a, k)) || { document: null, attempted: false, failure: '', bodySavedAt: null }); },
      save: async (a, k, markup, pictures, bodySavedAt) => { if (state.failDocument) throw new Error('private document detail');
        if (!documents.has(key(a, k))) documents.set(key(a, k), { attempted: true, failure: '', bodySavedAt,
          document: { version: 1, messageKey: k, html: markup, pictures, bodySavedAt, savedAt: Date.now() } });
        return copy(documents.get(key(a, k))); },
      fail: async (a, k, bodySavedAt) => { const value = { attempted: true, failure: 'failed', bodySavedAt, document: null };
        documents.set(key(a, k), value); return copy(value); }
    },
    pictures: {
      snapshotAttempted: async (a, k) => { if (state.failAttempt) throw new Error('private manifest detail'); return attempts.has(key(a, k)); },
      cancelPending: (a, k) => state.cancels.push([a, k])
    }
  };
  const types = loadLoaderModule({ prepareStaticMailHtml: (...args) => { state.scans++;
    if (options.failPreparation) throw new Error('private authored HTML'); return plan.prepareStaticMailHtml(...args); },
    loadPictureSnapshot: async (cache, a, k, urls, retry, scope) => {
      state.batches.push({ a, k, urls, retry, scope }); assert.equal(cache, store.pictures); assert.equal(retry, false);
      const result = options.batch ? await options.batch({ state, scope, a, k }) : { saved: true, cancelled: false };
      if (result.saved && !result.cancelled && scope.active()) attempts.add(key(a, k)); return result;
    } });
  const loader = new types.MailMessageLoader(store), account = { id: 'a', serverId: 'server-a' };
  const client = { readEmail: async (server, id) => { state.reads.push([server, id]);
    return options.read ? options.read(server, id) : mail(id); } };
  const seed = (a, value, ready = true) => {
    const cached = model.cacheEmail(value, true, null, Date.now()); bodies.set(key(a, value.id), cached);
    const k = stableMessageKey(value);
    const snapshot = { version: 1, messageKey: k, bodySavedAt: cached.bodySavedAt, savedAt: Date.now(),
      html: '<p>Fixed original document</p>', pictures: [{ id: 'https://mail.invalid/picture/saved', url: 'https://images.example.test/fixed.png' }] };
    documents.set(key(a, k), { document: snapshot, bodySavedAt: cached.bodySavedAt, attempted: true, failure: '' });
    if (ready) attempts.add(key(a, k)); return snapshot;
  };
  return { ...types, loader, store, state, bodies, documents, attempts, tracked, account, client, seed,
    open: (value = mail(), active = () => true) => loader.open(client, account, value, 'Show', 'Hide', active) };
}

test('A completed cached message opens offline with no scan, save, picture retry, or mailbox job lookup', async () => {
  const f = fixture({ read: async () => assert.fail('Offline') }); const value = mail(); const snapshot = f.seed('a', value);
  const before = copy(f.bodies.get('a:one'));
  for (let i = 0; i < 3; i++) {
    const result = await f.open(); assert.deepEqual(result.mail, before.mail); assert.deepEqual(result.document, snapshot);
  }
  assert.equal(f.state.reads.length, 0); assert.equal(f.state.scans, 0); assert.equal(f.state.saves.length, 0);
  assert.equal(f.state.batches.length, 0); assert.deepEqual(f.bodies.get('a:one'), before); await f.loader.whenIdle();
});

test('Explicit selection returns prepared HTML without starting or waiting for picture work', async () => {
  const f = fixture(); const result = await f.open();
  assert.deepEqual(f.state.reads, [['server-a', 'one']]); assert.deepEqual(f.state.saves, [['a', 'one', 42]]);
  assert.equal(f.state.scans, 1); assert.equal(f.state.batches.length, 0); assert.ok(result.document.html.includes('Body one'));
  assert.equal(result.mail.textBody, 'Body one'); assert.equal(f.attempts.size, 0);
  const again = await f.open(); assert.deepEqual(again.document, result.document);
  assert.equal(f.state.reads.length, 1); assert.equal(f.state.scans, 1); assert.equal(f.state.batches.length, 0);
  await f.loader.whenIdle(); assert.equal(f.tracked.size, 0);
});

test('Concurrent duplicate selections share the exact promise and one native request', async () => {
  const gate = deferred(), f = fixture({ read: async () => { await gate.promise; return mail(); } });
  const first = f.open(), second = f.open(); assert.equal(first, second); await tick(); assert.equal(f.state.reads.length, 1);
  gate.resolve(); assert.deepEqual(await first, await second); assert.equal(f.state.scans, 1);
});

test('Retired in-flight bodies save to the original account; obsolete queued selections never fetch or prepare', async () => {
  const gate = deferred(), f = fixture({ read: async (_a, id) => { if (id === 'first') await gate.promise; return mail(id); } });
  const first = f.open(mail('first')); const firstResult = first.catch(error => error); await tick();
  const second = f.open(mail('obsolete')); const secondResult = second.catch(error => error); await tick();
  const third = f.loader.open(f.client, { id: 'b', serverId: 'server-b' }, mail('latest'), 'Show', 'Hide', () => true);
  let idle = false; const waiting = f.loader.whenIdle().then(() => { idle = true; }); await tick(); assert.equal(idle, false);
  gate.resolve(); const result = await third; await waiting;
  assert.ok(await firstResult instanceof f.MailMessageLoadCancelled); assert.ok(await secondResult instanceof f.MailMessageLoadCancelled);
  assert.deepEqual(f.state.reads, [['server-a', 'first'], ['server-b', 'latest']]);
  assert.deepEqual(f.state.saves.map(row => row.slice(0, 2)), [['a', 'first'], ['b', 'latest']]);
  assert.equal(f.state.scans, 1); assert.equal(f.state.batches.length, 0); assert.equal(result.mail.id, 'latest');
  assert.equal(f.documents.has('a:' + stableMessageKey(mail('first'))), false); assert.equal(f.tracked.size, 0);
});

test('A cached selection remains immediate while an obsolete body request is outstanding', async () => {
  const gate = deferred(), f = fixture({ read: async (_a, id) => { await gate.promise; return mail(id); } });
  const old = f.open(mail('slow')).catch(error => error); await tick(); const cached = mail('cached'); f.seed('a', cached);
  const result = await f.open(cached); assert.equal(result.mail.id, 'cached'); assert.equal(f.state.scans, 0);
  gate.resolve(); assert.ok(await old instanceof f.MailMessageLoadCancelled); await f.loader.whenIdle();
});

test('An unfinished picture attempt does not delay reopening saved HTML or authorize loader HTTP', async () => {
  const f = fixture({ batch: async () => new Promise(() => {}) });
  const value = mail(), original = f.seed('a', value, false);
  Object.defineProperty(f.store, 'pictures', { get: () => assert.fail('The body loader must not access pictures') });
  const result = await f.open(); assert.deepEqual(result.document, original);
  assert.equal(f.state.reads.length, 0); assert.equal(f.state.scans, 0); assert.equal(f.state.batches.length, 0);
});

test('A stalled storage save ends the visible attempt, retains its owner and rejects late publication', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const gate = deferred(), f = fixture(); const save = f.store.mail.saveEmail;
  f.store.mail.saveEmail = async (...args) => { await gate.promise; return save(...args); };
  const result = f.open().catch(error => error); await tick();
  assert.equal(f.state.reads.length, 1); assert.equal(f.tracked.size, 1);
  t.mock.timers.tick(45000); const error = await result;
  assert.equal(error.code, 'network'); assert.equal(f.tracked.size, 1, 'late storage work stays owned');
  gate.resolve(); await f.loader.whenIdle();
  assert.equal(f.state.saves.length, 1); assert.equal(f.state.scans, 0); assert.equal(f.tracked.size, 0);
  const retry = await f.open(); assert.equal(retry.mail.id, 'one'); assert.equal(f.state.reads.length, 1);
});

test('Cancellation returns immediately while an in-flight native body retains bounded serial ownership', async () => {
  const gate = deferred(), f = fixture({ read: async () => { await gate.promise; return mail(); } });
  const result = f.open().catch(error => error); await tick(); f.loader.cancel();
  assert.ok(await result instanceof f.MailMessageLoadCancelled);
  assert.equal(f.tracked.size, 1); assert.equal(f.state.scans, 0);
  gate.resolve(); await f.loader.whenIdle();
  assert.equal(f.state.saves.length, 1); assert.equal(f.state.scans, 0); assert.equal(f.tracked.size, 0);
});

test('Safe native, missing-body, decoding and storage failures reject instead of leaving permanent pending state', async () => {
  for (const [read, code] of [[async () => { throw new Error('token=private-provider-response'); }, 'network'],
    [async () => { throw new JmapError('authenticationRequired'); }, 'authenticationRequired'], [async () => null, 'notFound'],
    [async () => mail('wrong-id'), 'invalidResponse'],
    [async () => mail('one', { textBody: null, htmlBody: null, bodyEncodingProblem: true }), 'invalidResponse']]) {
    const f = fixture({ read }); await assert.rejects(f.open(), error => error.code === code && !error.message.includes('private'));
    assert.equal(f.state.reads.length, 1); assert.equal(f.state.saves.length, 0); assert.equal(f.state.scans, 0);
    await f.loader.whenIdle(); assert.equal(f.tracked.size, 0);
  }
  for (const failure of ['failCache', 'failSave']) {
    const f = fixture(); f.state[failure] = true;
    await assert.rejects(f.open(), error => error.code === 'storage' && !error.message.includes('private'));
    await f.loader.whenIdle();
  }
});

test('Optional document failure preserves raw mail, with no access to picture state', async () => {
  const f = fixture(); f.state.failDocument = true;
  Object.defineProperty(f.store, 'pictures', { get: () => assert.fail('No picture access before HTML is visible') });
  const result = await f.open(); assert.equal(result.mail.textBody, 'Body one');
  assert.equal(result.document, null); assert.equal(f.state.scans, 0); assert.equal(f.state.reads.length, 1);
  await f.open(); assert.equal(f.state.reads.length, 1);
});

test('A later explicit retry may recover a failed body without an automatic retry or changing a valid empty/partial body', async () => {
  let fail = true; const f = fixture({ read: async () => { if (fail) throw new JmapError('network'); return mail(); } });
  await assert.rejects(f.open(), error => error.code === 'network'); await tick(); assert.equal(f.state.reads.length, 1);
  fail = false; await f.open(); assert.equal(f.state.reads.length, 2);
  for (const fields of [{ textBody: '', htmlBody: null, hasHtmlBody: false }, { textBody: null, htmlBody: '', hasHtmlBody: true },
    { textBody: '', htmlBody: null, hasAttachment: true, attachments: [] },
    { textBody: 'Readable partial', htmlBody: null, bodyTruncated: true, bodyEncodingProblem: true }]) {
    const value = mail('valid', fields), g = fixture({ read: async () => value });
    assert.deepEqual((await g.open(value)).mail, model.cacheEmail(value, true, null, Date.now()).mail);
    await g.open(value); assert.equal(g.state.reads.length, 1); assert.equal(g.state.scans, 1);
  }
});

test('Legacy failed-empty raw cache is refetched while a failed document preparation remains terminal with usable raw body', async () => {
  const f = fixture(); f.bodies.set('a:one', model.cacheEmail(mail('one', { textBody: null, htmlBody: null, bodyEncodingProblem: true }), true, null, Date.now()));
  await f.open(); assert.equal(f.state.reads.length, 1); assert.equal(f.bodies.get('a:one').mail.bodyEncodingProblem, false);
  const g = fixture({ failPreparation: true }); const first = await g.open(); assert.equal(first.document, null);
  assert.equal(first.mail.textBody, 'Body one'); const second = await g.open(); assert.equal(second.document, null);
  assert.equal(g.state.scans, 1); assert.equal(g.state.reads.length, 1); assert.equal(g.state.batches.length, 0);
});

test('An inactive selection starts no transport or picture work', async () => {
  const f = fixture(); await assert.rejects(f.open(mail(), () => false), error => error instanceof f.MailMessageLoadCancelled);
  assert.equal(f.state.reads.length, 0); assert.equal(f.state.scans, 0); assert.equal(f.state.batches.length, 0);
});
