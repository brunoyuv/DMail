const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/NotificationSettingsPanel.ets', 'utf8');
function method(name) {
  let start = source.indexOf(`  private async ${name}(`);
  if (start < 0) start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0); return source.slice(start, source.indexOf('\n  }\n', start) + 5).replace('private ', '');
}
const code = ts.transpileModule(`class Harness { ${['apply', 'reload', 'refreshSystem', 'openSystemSettings', 'testNotification', 'recover', 'updateScheduler', 'changeEnabled', 'changeFrequency', 'retrySettings'].map(method).join('\n')} } return Harness;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function fixture() {
  const calls = [], values = new Map(); const state = id => values.get(id) || { enabled: false, foregroundMinutes: 5, backgroundMinutes: 120, notificationId: 0 };
  const platform = { settings: async () => ({ enabled: true }), openSettings: async () => calls.push(['system-settings']),
    publish: async (_, id, accountId) => calls.push(['test', id, accountId]), requestEnable: async () => { calls.push(['permission']); }, cancel: async id => { calls.push(['cancel', id]); } };
  const service = { settingsChanged: async () => { calls.push(['reconcile']); } };
  const store = { notificationSettings: async id => ({ ...state(id) }),
    setNotifications: async (id, enabled) => { calls.push(['configure', id, enabled]); values.set(id, { ...state(id), enabled, notificationId: 7 }); },
    notifications: { frequencies: async (id, foregroundMinutes, backgroundMinutes) => {
      calls.push(['frequency', id, foregroundMinutes, backgroundMinutes]); values.set(id, { ...state(id), foregroundMinutes, backgroundMinutes });
    } }
  };
  const Harness = new Function('NotificationPlatform', 'MailNotificationService', 'AppStorage', code)(platform, service, {get:()=>0, setOrCreate:()=>{}});
  const panel = Object.assign(new Harness(), { accountId: 'a', store, active: true, revision: 0, notificationsOn: false, ready: false, busy: false,
    foregroundMinutes: 5, backgroundMinutes: 120, failed: false, getUIContext: () => ({ getHostContext: () => ({}) }) });
  return { panel, calls, platform, service, store, state };
}
test('Settings load stays opted out and permission precedes persistence on explicit enable', async () => {
  const f = fixture(); await f.panel.reload(); assert.equal(f.calls.length, 0); assert.equal(f.panel.notificationsOn, false);
  const gate = deferred(); f.service.settingsChanged = () => { f.calls.push(['reconcile']); return gate.promise; };
  await f.panel.changeEnabled(true);
  assert.deepEqual(f.calls, [['permission'], ['configure', 'a', true], ['reconcile']]);
  assert.equal(f.panel.notificationsOn, true); assert.equal(f.panel.busy, false); gate.resolve();
});
test('Denied notification permission never enables the account', async () => {
  const f = fixture(); await f.panel.reload(); f.platform.requestEnable = async () => { throw new Error('denied'); };
  await f.panel.changeEnabled(true); assert.equal(f.panel.notificationsOn, false); assert.equal(f.panel.failed, true);
  assert.equal(f.calls.some(call => call[0] === 'configure'), false);
});
test('An approved old account toggle persists its account without changing the newly selected panel', async () => {
  const f = fixture(); await f.panel.reload(); const gate = deferred(); f.platform.requestEnable = () => gate.promise;
  const pending = f.panel.changeEnabled(true); f.panel.accountId = 'b'; await f.panel.reload();
  gate.resolve(); await pending;
  assert.equal(f.state('a').enabled, true); assert.equal(f.panel.accountId, 'b'); assert.equal(f.panel.notificationsOn, false);
  assert.equal(f.panel.ready, true); assert.equal(f.panel.busy, false);
});
test('Frequency edits preserve consent and disabling clears only this account alert', async () => {
  const f = fixture(); await f.panel.reload(); await f.panel.changeEnabled(true); f.calls.length = 0;
  await f.panel.changeFrequency(15, 240);
  assert.equal(f.panel.foregroundMinutes, 15); assert.equal(f.panel.backgroundMinutes, 240);
  assert.equal(f.panel.notificationsOn, true); assert.equal(f.calls.some(call => call[0] === 'permission'), false);
  await f.panel.changeEnabled(false);
  assert.equal(f.panel.notificationsOn, false); assert.ok(f.calls.some(call => call[0] === 'cancel' && call[1] === 7));
});

test('System permission and known banner/badge blocks are surfaced with a working settings action', async () => {
  const f = fixture(); await f.panel.reload();
  f.platform.settings = async () => ({ enabled: false, bannerEnabled: false, badgeEnabled: false });
  await f.panel.refreshSystem();
  assert.equal(f.panel.systemEnabled, false); assert.equal(f.panel.bannerBlocked, true); assert.equal(f.panel.badgeBlocked, true);
  await f.panel.openSystemSettings(); assert.ok(f.calls.some(value => value[0] === 'system-settings'));
  f.platform.settings = async () => ({ enabled: true }); await f.panel.refreshSystem();
  assert.equal(f.panel.bannerBlocked, false); assert.equal(f.panel.badgeBlocked, false);
});
test('A test notification only publishes locally and never enables account/server checking', async () => {
  const f = fixture(); await f.panel.reload(); await f.panel.testNotification();
  assert.equal(f.panel.testSent, true); assert.equal(f.panel.notificationsOn, false);
  assert.deepEqual(f.calls, [['permission'], ['test', 2147483000, 'a']]);
});
