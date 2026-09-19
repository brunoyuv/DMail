const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { actualLoaderFixture } = require('./reader-loader-fixture.cjs');
const { automaticMailFixture, flush } = require('./fixtures/automatic-mail-work.cjs');
const model = require('../.tools/test-output/data/MailCacheModel');
const { JmapError } = require('../.tools/test-output/mail/jmap/JmapClient');
const deferred = () => { let resolve; const promise = new Promise(done => resolve = done); return { promise, resolve }; };
function fixture(options = {}) {
  const f = actualLoaderFixture(options), auto = automaticMailFixture();
  const state = { available: true, heat: 0, unsubscribed: false, pageCalls: [], headerSaves: [], summaries: 0 };
  let powerChanged, nextTimer = 10000;
  f.store.mail.emailSummary = async (account, id) => {
    state.summaries++; const cached = f.bodies.get(account + ':' + id);
    return cached ? model.cachedEmailSummary(structuredClone(cached)) : null;
  };
  f.store.mail.saveSyncedEmails = async (account, emails, revision) => {
    state.headerSaves.push([account, emails.map(x => x.id), revision]);
    for (const value of emails) {
      const key = account + ':' + value.id;
      f.bodies.set(key, model.cacheEmail(value, false, f.bodies.get(key) || null, Date.now()));
    }
  };
  f.client.emailPage = async (...args) => {
    state.pageCalls.push(args); return options.page(...args);
  };
  const imports = {
    '../data/MailCache': { MailCache: { mutationRevision: () => 42 } },
    '../data/MailCacheModel': model,
    './jmap/JmapClient': { JmapError },
    './MailMessageLoader': f,
    './AutomaticMailWork': auto,
    './MailSyncPower': { MailSyncPower: { level: () => state.heat,
      subscribe: callback => { powerChanged = callback; return () => state.unsubscribed = true; } } },
    './MailSyncPacing': { mailSyncThermallyAllowed: level => level < 2 }
  };
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/InboxPrefetch.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', 'Date', 'setTimeout', 'clearTimeout', code)(name => {
    assert.ok(name in imports, 'Unexpected prefetch import ' + name); return imports[name];
  }, module, module.exports, auto.Clock,
    (callback, delay) => { const id = nextTimer++; auto.timers.set(id, { callback, due: auto.state.now + delay, delay }); return id; },
    id => auto.timers.delete(id));
  const worker = new module.exports.InboxPrefetch(f.store, () => state.available);
  const update = (emails = [f.mail()], next = null, query = 'head', account = f.account, client = f.client) =>
    worker.update(client, account, 'inbox', emails, next, query, 'Show', 'Hide');
  return { ...f, auto, prefetchState: state, worker, update, powerChanged: () => powerChanged(),
    settle: () => auto.settle(worker.whenIdle()) };
}

test('Active Inbox preloads bodies and prepared HTML before a click, with paced serial requests', async () => {
  const f = fixture(); f.update([f.mail('one'), f.mail('two')]);
  await flush(); assert.deepEqual(f.state.reads, [['server-a', 'one']]);
  await f.auto.advance(2999); assert.equal(f.state.reads.length, 1);
  await f.auto.advance(1); await f.settle();
  assert.deepEqual(f.state.reads, [['server-a', 'one'], ['server-a', 'two']]);
  assert.equal(f.state.scans, 2); assert.equal(f.state.batches.length, 0);
  const read = await f.open(f.mail('two'));
  assert.ok(read.document.html.includes('Body two')); assert.equal(f.state.reads.length, 2); assert.equal(f.state.scans, 2);
  f.update([f.mail('one'), f.mail('two')]); await flush();
  assert.equal(f.auto.timers.size, 0); assert.equal(f.state.reads.length, 2);
  await f.worker.close(); assert.equal(f.prefetchState.unsubscribed, true);
});

test('Existing cached bodies including partial and attachment-only mail skip network and hydration', async () => {
  const f = fixture();
  const emails = [f.mail('normal'), f.mail('partial', { bodyTruncated: true }),
    f.mail('file', { textBody: null, htmlBody: null, hasAttachment: true, attachments: [{ id: '1', name: 'file', contentType: 'text/plain', size: 1, sizeIsEncoded: true }] })];
  for (const value of emails) f.seed('a', value);
  f.update(emails); await f.settle();
  assert.equal(f.state.reads.length, 0); assert.equal(f.state.cacheReads.length, 0); assert.equal(f.auto.timers.size, 0);
  await f.worker.close();
});

test('Traversal continues beyond the first page without replacing the visible Inbox', async () => {
  let f;
  f = fixture({ page: async (account, mailbox, position) => {
    const end = Math.min(105, position + 50);
    return { accountId: account, position, nextPosition: end < 105 ? end : null, queryState: 'head',
      emails: Array.from({ length: end - position }, (_, i) => f.mail('m' + (position + i))) };
  } });
  f.update([f.mail('m0')], 1); await f.auto.advance(400000); await f.settle();
  assert.equal(f.state.reads.length, 105); assert.equal(new Set(f.state.reads.map(x => x[1])).size, 105);
  assert.deepEqual(f.prefetchState.pageCalls.map(x => x[2]), [1, 51, 101]);
  assert.equal(f.prefetchState.headerSaves.length, 3); assert.equal(f.auto.timers.size, 0);
  await f.worker.close();
});

test('Foreground pause cancels waiting work and resumes without refetching completed messages', async () => {
  const f = fixture(); f.update([f.mail('one'), f.mail('two')]); await flush();
  f.prefetchState.available = false; f.update([f.mail('one'), f.mail('two')]); await flush();
  await f.auto.advance(10000); assert.equal(f.state.reads.length, 1); assert.equal(f.auto.timers.size, 0);
  f.prefetchState.available = true; f.update([f.mail('one'), f.mail('two')]); await f.settle();
  assert.equal(f.state.reads.length, 2); await f.worker.close();
});

test('A click during prefetch shares the saved result and never overlaps or duplicates its native read', async () => {
  const gate = deferred(); let f;
  f = fixture({ read: async (_server, id) => { await gate.promise; return f.mail(id); } });
  f.update([f.mail('one'), f.mail('two')]); await flush(); assert.equal(f.state.reads.length, 1);
  f.prefetchState.available = false; f.update([f.mail('one'), f.mail('two')]);
  const selected = f.open(f.mail('one')); await flush(); assert.equal(f.state.reads.length, 1);
  gate.resolve(); assert.equal((await selected).mail.id, 'one'); await f.settle();
  assert.equal(f.state.reads.length, 1); assert.equal(f.state.saves.length, 1);
  await f.worker.close();
});

test('Account switching saves an already received body only to its original owner', async () => {
  const gate = deferred(); let f;
  f = fixture({ read: async (server, id) => { if (server === 'server-a') await gate.promise; return f.mail(id); } });
  f.update(); await flush();
  f.update([f.mail('other')], null, 'other-head', { id: 'b', serverId: 'server-b' });
  await flush(); assert.equal(f.state.reads.length, 1);
  gate.resolve(); await flush(); await f.settle();
  assert.deepEqual(f.state.saves.map(x => x.slice(0, 2)), [['a', 'one'], ['b', 'other']]);
  assert.equal(f.documents.has('b:one@example.test'), false); await f.worker.close();
});

test('A broken body is attempted once per session and other messages wait for cooldown', async () => {
  let f; f = fixture({ read: async (_server, id) => { if (id === 'bad') throw new JmapError('network'); return f.mail(id); } });
  const emails = [f.mail('bad'), f.mail('good')]; f.update(emails); await flush();
  assert.equal(f.state.reads.length, 1); await f.auto.advance(59999); assert.equal(f.state.reads.length, 1);
  await f.auto.advance(1); await f.settle(); assert.equal(f.state.reads.length, 2);
  f.update(emails); await f.auto.advance(120000); assert.equal(f.state.reads.length, 2);
  assert.equal(f.auto.timers.size, 0); assert.equal(f.bodies.has('a:bad'), false); await f.worker.close();
});

test('Authentication rejection stops automatic requests until a new client context is supplied', async () => {
  const f = fixture({ read: async () => { throw new JmapError('authenticationRequired'); } });
  f.update([f.mail('one'), f.mail('two')]); await flush(); await f.auto.advance(3600000);
  assert.equal(f.state.reads.length, 1); assert.equal(f.auto.timers.size, 0);
  f.update([f.mail('one'), f.mail('two')]); await flush(); assert.equal(f.state.reads.length, 1);
  await f.worker.close();
});

test('A superseded page cannot replace the current cursor or enqueue retired headers', async () => {
  const gate = deferred(); let f;
  f = fixture({ page: async (account, mailbox, position) => {
    await gate.promise; return { accountId: account, position, nextPosition: 100, queryState: 'old', emails: [f.mail('stale')] };
  } });
  f.update([], 50, 'old'); await flush();
  f.update([f.mail('fresh')], null, 'new'); gate.resolve(); await f.settle();
  assert.deepEqual(f.state.reads, [['server-a', 'fresh']]); assert.equal(f.prefetchState.headerSaves.length, 0);
  await f.worker.close();
});

test('Invalid pagination terminates instead of fetching the same page forever', async () => {
  const f = fixture({ page: async account => ({ accountId: account, position: 50, nextPosition: 50, queryState: 'head', emails: [] }) });
  f.update([], 50); await f.settle(); await f.auto.advance(3600000);
  assert.equal(f.prefetchState.pageCalls.length, 1); assert.equal(f.auto.timers.size, 0); await f.worker.close();
});

test('Thermal pause and close release pending timers and leave no new work', async () => {
  const f = fixture(); f.update([f.mail('one'), f.mail('two')]); await flush();
  f.prefetchState.heat = 2; f.powerChanged(); await flush();
  await f.auto.advance(10000); assert.equal(f.state.reads.length, 1); assert.equal(f.auto.timers.size, 0);
  f.prefetchState.heat = 0; f.powerChanged(); await f.settle();
  await f.worker.close(); f.update([f.mail('three')]); await f.auto.advance(10000);
  assert.equal(f.state.reads.length, 2); assert.equal(f.auto.timers.size, 0);
});

test('A prefetch deadline retains the automatic lane until native work actually drains', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const gate = deferred(); let f;
  f = fixture({ read: async (_server, id) => { await gate.promise; return f.mail(id); } });
  f.update([f.mail('one'), f.mail('two')]); await flush();
  t.mock.timers.tick(45000); await flush();
  let otherStarted = false;
  const other = f.auto.AutomaticMailWork.run(async () => otherStarted = true);
  await f.auto.advance(30000); assert.equal(otherStarted, false); assert.equal(f.state.reads.length, 1);
  gate.resolve(); await flush(); await f.auto.advance(3000); await other;
  assert.equal(otherStarted, true); assert.equal(f.state.reads.length, 1);
  await f.worker.close(); assert.equal(f.auto.timers.size, 0);
});

test('A changed server cursor restarts from the head after cooldown without losing completed bodies', async () => {
  let f, calls = 0;
  f = fixture({ page: async (account, _mailbox, position, queryState) => {
    if (++calls === 1) throw new JmapError('queryChanged');
    assert.equal(position, 0); assert.equal(queryState, undefined);
    return { accountId: account, position, queryState: 'new', nextPosition: null, emails: [f.mail('cached'), f.mail('fresh')] };
  } });
  f.seed('a', f.mail('cached')); f.update([f.mail('cached')], 50, 'old'); await flush();
  await f.auto.advance(60000); await f.settle();
  assert.deepEqual(f.state.reads, [['server-a', 'fresh']]); assert.equal(calls, 2); await f.worker.close();
});

test('Closing during native work waits for the original save and never starts a successor', async () => {
  const gate = deferred(); let f;
  f = fixture({ read: async (_server, id) => { await gate.promise; return f.mail(id); } });
  f.update([f.mail('one'), f.mail('two')]); await flush();
  let closed = false; const closing = f.worker.close().then(() => closed = true);
  await flush(); assert.equal(closed, false); assert.equal(f.prefetchState.unsubscribed, true);
  gate.resolve(); await closing; await f.auto.advance(100000);
  assert.equal(f.state.reads.length, 1); assert.equal(f.state.saves.length, 1); assert.equal(f.auto.timers.size, 0);
});

test('Repeated scroll/interaction updates do not rescan unchanged headers, but a new snapshot still admits work', async () => {
  const f = fixture(); f.prefetchState.available = false;
  let reads = 0;
  const emails = Array.from({ length: 2000 }, (_, i) => {
    const value = f.mail('scroll-' + i), id = value.id;
    Object.defineProperty(value, 'id', { get() { reads++; return id; } }); return value;
  });
  f.update(emails); const initialReads = reads;
  for (let i = 0; i < 100; i++) f.update(emails);
  assert.equal(reads, initialReads, 'An unchanged list must not be rescanned on each interaction callback');
  assert.equal(f.worker.context.pending.size, 2000);
  f.update(emails, null, 'new-snapshot');
  assert.equal(f.worker.context.pending.size, 2000, 'Snapshot reset must re-admit unattempted headers even with the same array');
  const changed = emails.concat(f.mail('new'));
  f.update(changed, null, 'new-snapshot'); assert.equal(f.worker.context.pending.size, 2001);
  assert.equal(f.state.reads.length, 0); assert.equal(f.prefetchState.summaries, 0);
  await f.worker.close();
});

test('An unchanged header array resumes after scrolling without replaying completed prefetch', async () => {
  const f = fixture(); f.prefetchState.available = false;
  const emails = [f.mail('first'), f.mail('second')]; f.update(emails);
  f.prefetchState.available = true; f.update(emails); await f.settle();
  assert.equal(f.state.reads.length, 2);
  f.prefetchState.available = false; f.update(emails);
  f.prefetchState.available = true; f.update(emails); await f.settle();
  assert.equal(f.state.reads.length, 2); assert.equal(f.auto.timers.size, 0);
  await f.worker.close();
});
