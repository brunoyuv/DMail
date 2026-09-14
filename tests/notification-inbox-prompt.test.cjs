const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/NotificationInboxPrompt.ets', 'utf8');
const methods = ['reload', 'activate'].map(name => source.match(new RegExp(`  private async ${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const code = ts.transpileModule(`return class Harness { ${methods} }`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
function fixture() {
  const calls = [], records = new Map();
  const platform = { settings: async () => ({ enabled: true }), requestEnable: async () => {}, openSettings: async () => calls.push('settings') };
  const store = { notificationSettings: async id => records.get(id) || { enabled: false, notificationId: 0 },
    setNotifications: async (id, enabled) => { records.set(id, { enabled, notificationId: 7 }); calls.push(['configure', id]); } };
  const Harness = new Function('NotificationPlatform', 'MailNotificationService', 'AppStorage', code)(platform,
    { settingsChanged: async () => calls.push('service') }, { get:()=>0, setOrCreate:()=>{} });
  const ui = Object.assign(new Harness(), { store, accountId: 'a', revision: 0, active: true, busy: false, failed: false,
    visible: false, blocked: false, getUIContext: () => ({ getHostContext: () => ({}) }) });
  return { ui, records, platform, calls };
}
test('Inbox offers first enable, hides after opt-in, and respects a deliberate account disable', async () => {
  const f = fixture(); await f.ui.reload(); assert.equal(f.ui.visible, true);
  await f.ui.activate(); assert.equal(f.ui.visible, false); assert.equal(f.records.get('a').enabled, true);
  f.records.set('a', { enabled: false, notificationId: 7 }); await f.ui.reload(); assert.equal(f.ui.visible, false);
});
test('Denied OS permission routes the next action to system settings without enabling checks', async () => {
  const f = fixture(); await f.ui.reload(); f.platform.requestEnable = async () => { throw new Error('denied'); };
  await f.ui.activate(); assert.equal(f.ui.visible, true); assert.equal(f.ui.blocked, true);
  assert.equal(f.records.size, 0); await f.ui.activate(); assert.deepEqual(f.calls, ['settings']);
});
test('Account switch during denied permission cannot poison the next account prompt', async () => {
  const f = fixture(); await f.ui.reload(); let reject;
  f.platform.requestEnable = () => new Promise((_, no) => reject = no);
  const old = f.ui.activate(); f.ui.accountId = 'b'; await f.ui.reload(); reject(new Error('denied')); await old;
  assert.equal(f.ui.failed, false); assert.equal(f.ui.blocked, false); assert.equal(f.ui.visible, true);
  assert.equal(f.records.size, 0);
});
