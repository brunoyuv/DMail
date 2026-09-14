const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function fixture() {
  const state = { count: 12, writes: [], gate: null, failure: false, readFailure: false, reads: 0 };
  const operations = { overlay: (_account, mail) => mail, pendingEmailIds: () => [] };
  const platform = { setUnreadBadge: async count => {
    state.writes.push(count); if (state.gate) { const gate = state.gate; state.gate = null; await gate; }
    if (state.failure) throw new Error('Synthetic OS failure');
  } };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compile(fs.readFileSync('harmony/entry/src/main/ets/mail/notifications/MailBadgeService.ets', 'utf8')))(name => {
    if (name.endsWith('/MailOperations')) return { MailOperations: operations };
    assert.equal(name, './NotificationPlatform'); return { NotificationPlatform: platform };
  }, module, module.exports);
  const store = { badges: { total: async (overlay, pendingIds) => {
    assert.equal(overlay, operations.overlay); assert.equal(pendingIds, operations.pendingEmailIds);
    state.reads++; if (state.readFailure) throw new Error('Synthetic local read failure'); return state.count;
  } } };
  return { state, store, service: module.exports.MailBadgeService };
}

test('Badge writes preserve numeric totals and reconcile a mute that occurs during an OS write', async () => {
  const f = fixture(), gate = deferred(); f.state.gate = gate.promise;
  const first = f.service.refresh(f.store); await new Promise(setImmediate);
  assert.deepEqual(f.state.writes, [12]);
  f.state.count = 0; gate.resolve(); await first;
  assert.deepEqual(f.state.writes, [12, 0]);
  f.state.count = 173; await f.service.refresh(f.store);
  assert.equal(f.state.writes.at(-1), 173);
});

test('Queued refreshes reread current opt-in totals and recover after a platform failure', async () => {
  const f = fixture(), gate = deferred(); f.state.gate = gate.promise;
  const first = f.service.refresh(f.store); await new Promise(setImmediate);
  const next = f.service.refresh(f.store); f.state.count = 4; gate.resolve();
  await Promise.all([first, next]); assert.deepEqual(f.state.writes, [12, 4, 4]);
  f.state.failure = true; await assert.rejects(f.service.refresh(f.store), /Synthetic OS failure/);
  f.state.failure = false; f.state.count = 0; await f.service.refresh(f.store);
  assert.equal(f.state.writes.at(-1), 0);
});

test('Unknown totals clear an old badge instead of inventing one or showing a partial total', async () => {
  const f = fixture(); await f.service.refresh(f.store); f.state.count = null;
  await f.service.refresh(f.store); assert.deepEqual(f.state.writes, [12, 0]);
});

test('A local count read failure after muting cannot leave the previous account total on the app icon', async () => {
  const f = fixture(); await f.service.refresh(f.store);
  f.state.readFailure = true; await f.service.refresh(f.store);
  assert.deepEqual(f.state.writes, [12, 0]);
  f.state.readFailure = false; f.state.count = 3; await f.service.refresh(f.store);
  assert.equal(f.state.writes.at(-1), 3);
});

test('Inbox cache updates refresh numeric badge even when its in-app unread dot remains true', async () => {
  const f = fixture(), source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
  const methods = ['unreadChanged', 'refreshUnreadStatus'].map(name => {
    const found = source.match(new RegExp(`  private ${name}\\([\\s\\S]*?\\n  }`));
    assert.ok(found); return found[0];
  }).join('\n');
  let dots = 0;
  const Host = new Function('MailBadgeService', 'MailUnreadStatus', compile(`class Host { ${methods} }; return Host;`))(
    f.service, { refresh: async () => { dots++; } });
  const ui = Object.assign(new Host(), { active: true, ready: true, accountStore: f.store, unreadRevision: 0, unreadRefresh: Promise.resolve() });
  ui.refreshUnreadStatus(); await ui.unreadRefresh;
  f.state.count = 11; ui.refreshUnreadStatus(); await ui.unreadRefresh;
  assert.deepEqual(f.state.writes, [12, 11]); assert.equal(dots, 2);
  f.state.count = 0; ui.unreadChanged(); await ui.unreadRefresh;
  assert.equal(f.state.writes.at(-1), 0);
});
