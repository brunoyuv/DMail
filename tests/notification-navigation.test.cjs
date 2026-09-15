// Execute the notification route and its existing event retry hook. All data,
// navigation, storage and time are synthetic; no ArkUI or provider is opened.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const names = ['openNotification', 'inboxChanged', 'inboxBlocked', 'retireInboxInteraction'];
const methods = names.map(name => source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const code = ts.transpileModule(`class Host { ${methods} }; return Host;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const flush = async () => { for (let index = 0; index < 35; index++) await Promise.resolve(); };
function fixture() {
  const values = new Map(), timers = new Map(); let nextTimer = 0;
  const state = { foreground: true, paths: [], opened: [], reads: [], cancelled: [], readGate: null,
    cancelGate: null, navigationGate: null, readError: false, cancelError: false, navigationError: false };
  const AppStorage = { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) };
  const Host = new Function('AppStorage', 'MailInboxUpdates', 'NotificationPlatform', 'DeferredSave', 'setTimeout', 'clearTimeout', 'AutomaticMailWork', code)(
    AppStorage, { isForeground: () => state.foreground, revision: () => 0 }, {
      cancel: async id => { state.cancelled.push(id); if (state.cancelGate) await state.cancelGate.promise;
        if (state.cancelError) throw new Error('Synthetic cancellation failure'); }
    }, { flushAll: async () => {} },
    (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; }, id => timers.delete(id),
    { cancelInactive() {} });
  const host = Object.assign(new Host(), { active: true, ready: true, busy: false, openingNotification: false, openInboxOnLaunch: true,
    generation: 7, accounts: [{ id: 'a' }, { id: 'b' }], account: { id: 'a' }, notificationTimer: -1,
    inboxTimer: -1, inboxSwipes: new Set(), inboxRequests: new Map(), inboxCachedUpdates: new Set(), inboxAcknowledged: new Map(),
    boxes: [], client: null, mailboxId: '', paths: { getAllPathName: () => state.paths }, refreshUnreadStatus() {},
    accountStore: { notificationSettings: async id => {
      state.reads.push(id); if (state.readGate) await state.readGate.promise;
      if (state.readError) throw new Error('Synthetic preference read failure');
      return { notificationId: id === 'a' ? 37 : 38 };
    } }
  });
  // Match openAccount's synchronous composer guard and navigation commit. Its
  // longer cache/server work has separate ownership regressions.
  host.openAccount = async account => {
    if (state.paths.includes('compose')) return;
    state.opened.push(account.id); host.account = account; host.generation++; host.busy = true;
    const generation = host.generation;
    if (state.navigationGate) await state.navigationGate.promise;
    if (state.navigationError) throw new Error('Synthetic navigation failure');
    if (generation === host.generation) host.busy = false;
  };
  const tap = id => { values.set('mailNotificationAccountId', id); return host.openNotification(); };
  return { host, state, values, timers, tap };
}

test('A slow notification preference read cannot delay navigation or override a later account selection', async () => {
  const f = fixture(), held = deferred(); f.state.readGate = held;
  const opening = f.tap('a'); await flush();
  assert.deepEqual(f.state.opened, ['a'], 'Route commits before optional preference cleanup');
  await f.host.openAccount({ id: 'b' }); held.resolve(); await opening; await flush();
  assert.deepEqual(f.state.opened, ['a', 'b']); assert.equal(f.host.account.id, 'b');
  assert.deepEqual(f.state.cancelled, [37]);
});

test('Notification cleanup finishing during composition or teardown cannot consume another tap or navigate', async () => {
  for (const teardown of [false, true]) {
    const f = fixture(), held = deferred(); f.state.cancelGate = held;
    await f.tap('a'); await flush(); assert.deepEqual(f.state.cancelled, [37]);
    if (teardown) { f.host.active = false; f.host.generation++; }
    else f.state.paths = ['compose'];
    await f.tap('b'); held.resolve(); await flush();
    assert.deepEqual(f.state.opened, ['a']); assert.equal(f.values.get('mailNotificationAccountId'), 'b');
    if (!teardown) {
      f.state.paths = []; await f.host.openNotification(); await flush();
      assert.deepEqual(f.state.opened, ['a', 'b']);
    }
  }
});

test('Busy and background pending taps schedule no timers and resume once from existing UI events', async () => {
  const f = fixture(); f.host.busy = true; await f.tap('a');
  for (let index = 0; index < 100; index++) await f.host.openNotification();
  assert.equal(f.timers.size, 0); assert.deepEqual(f.state.reads, []);
  f.state.foreground = false; f.host.busy = false; f.host.inboxChanged();
  for (let index = 0; index < 100; index++) await f.host.openNotification();
  assert.equal(f.timers.size, 0); assert.deepEqual(f.state.opened, []);
  assert.equal(f.values.get('mailNotificationAccountId'), 'a');
  f.state.foreground = true; f.host.inboxChanged(); await flush();
  assert.deepEqual(f.state.opened, ['a']);
  for (let index = 0; index < 20; index++) f.host.inboxChanged(); await flush();
  assert.deepEqual(f.state.opened, ['a']); assert.equal(f.timers.size, 0);
});

test('A busy completion handles the latest retained tap without polling or duplicate opens', async () => {
  const f = fixture(); f.host.busy = true; await f.tap('a'); await f.tap('b');
  f.host.busy = false; f.host.inboxChanged(); await flush();
  assert.deepEqual(f.state.opened, ['b']); assert.deepEqual(f.state.reads, ['b']);
  assert.equal(f.values.get('mailNotificationAccountId'), ''); assert.equal(f.timers.size, 0);
});

test('Newer taps arriving during account load are retained and only the last one opens afterward', async () => {
  const f = fixture(), held = deferred(); f.state.navigationGate = held;
  const opening = f.tap('a'); await flush(); await f.tap('a'); await f.tap('b');
  assert.deepEqual(f.state.opened, ['a']); assert.equal(f.values.get('mailNotificationAccountId'), 'b');
  held.resolve(); await opening; await flush();
  assert.deepEqual(f.state.opened, ['a', 'b']); assert.equal(f.host.openingNotification, false);
  assert.equal(f.values.get('mailNotificationAccountId'), '');
});

test('Cleanup failures cannot block a valid tap or start an automatic failure retry loop', async () => {
  for (const failure of ['readError', 'cancelError']) {
    const f = fixture(); f.state[failure] = true; await f.tap('a'); await flush();
    assert.deepEqual(f.state.opened, ['a']); assert.equal(f.host.openingNotification, false);
    assert.equal(f.timers.size, 0); assert.equal(f.state.reads.length, 1);
    for (let index = 0; index < 10; index++) f.host.inboxChanged(); await flush();
    assert.equal(f.state.reads.length, 1);
  }
});

test('An unavailable account consumes only its own tap without opening or dismissing another account', async () => {
  const f = fixture(); await f.tap('removed'); await flush();
  assert.equal(f.values.get('mailNotificationAccountId'), '');
  assert.deepEqual(f.state.opened, []); assert.deepEqual(f.state.reads, []); assert.deepEqual(f.state.cancelled, []);
});
